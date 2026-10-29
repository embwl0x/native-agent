import NativeAgentCore
import Foundation
import PersistenceCore
import ToolRegistry
// Blueprint: | `SecurityCenter.swift` | Security decisions including permission-reset approval, audit JSONL, preserved pretrim archive and completion marker; local backup/export/phone exclusions and Security Audit privacy scope declared at the owner; status accepts the facade's checked policy generation without rereading it |

struct OriginAssessment: Sendable {
    var trusted: Bool
    var reason: String
    var isRemote: Bool
}

struct TelegramSecurityAllowlist: Sendable {
    var chatIds: Set<String>
    var userIds: Set<String>
    // The label names the transport in origin decisions.
    var surfaceLabel: String = "telegram"

    var isEmpty: Bool {
        chatIds.isEmpty && userIds.isEmpty
    }

    var count: Int {
        chatIds.union(userIds).count
    }

    func matches(chatId: String?, userId: String?) -> String? {
        if let chatId, chatIds.contains(chatId) {
            return "\(surfaceLabel) chat allowlist matched"
        }
        if let userId, userIds.contains(userId) {
            return "\(surfaceLabel) user allowlist matched"
        }
        // In private Telegram chats, chat.id and from.id are the same. The
        // tool loop usually carries only session/chat id, so let a user-id
        // allowlist prove that private-chat origin without weakening groups.
        // Telegram-only: slack channel/user id namespaces are unrelated, so
        // this fallback must never cross-match them.
        if surfaceLabel == "telegram", userId == nil, let chatId, userIds.contains(chatId) {
            return "telegram private user allowlist matched"
        }
        return nil
    }
}

public actor SwiftNativeSecurityCenter {
    public nonisolated let dataRoot: URL
    let clock: @Sendable () -> Date
    let trustCenter: SwiftNativeTrustCenter

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.clock = clock
        self.trustCenter = SwiftNativeTrustCenter(
            dataRoot: dataRoot,
            clock: clock
        )
    }

    public func status(limit: Int = 8) async throws -> SecurityCenterStatus {
        let policy: Result<[String: JSONValue], any Error>
        do { policy = .success(try await trustCenter.loadTrustPolicyChecked()) }
        catch { policy = .failure(error) }
        return try await status(policy: policy, limit: limit)
    }

    /// Render the caller's checked authority generation without rereading it.
    public func status(policy checkedPolicy: Result<[String: JSONValue], any Error>, limit: Int = 8) async throws -> SecurityCenterStatus {
        // Readability proves only the retained history, not complete recording.
        let history: Result<[JSONValue], any Error>
        do { history = .success(try await SwiftNativePersistenceCore.tailJSONL(auditReceiptsPath, limit: limit, maxBytes: 512 * 1024)) }
        catch { history = .failure(error) }
        let recent = ((try? history.get()) ?? []).compactMap(Self.receiptSummary)
        let policy: [String: JSONValue]
        do {
            policy = try checkedPolicy.get()
        } catch {
            return SecurityCenterStatus(
                status: "blocked",
                mode: "unavailable",
                developerMode: false,
                fullMac: false,
                killSwitchEnabled: true,
                trustedOrigins: 0,
                auditReceiptsPath: auditReceiptsPath.path,
                flags: [SecurityStatusFlag(
                    id: "trust_policy_unavailable",
                    title: "Trust Policy",
                    status: "blocked",
                    detail: "Saved authority state is unavailable: \(error.localizedDescription)",
                    enabled: false
                ), Self.auditFlag(enabled: true, history: history)],
                recentReceipts: recent
            )
        }
        let security = Self.object(policy["securityPolicy"])
        let permission = policy["permissionLevel"]?.scalarText ?? "balanced"
        let developerMode = Self.bool(policy["developerMode"], default: false)
        let fullMac = Self.fullMacActive(policy: policy)
        let trustedOrigins = try await trustedOriginCount()
        let killSwitch = Self.bool(security["killSwitchEnabled"], default: false)
        let flags = [
            SecurityStatusFlag(
                // What this row reads is `killSwitchEnabled`, so it is named
                // and switched by that.
                id: "security_center",
                title: "Kill Switch",
                status: killSwitch ? "blocked" : "off",
                detail: killSwitch ? "Everything is paused — I cannot take any action right now." : "Off, so nothing is paused.",
                enabled: true
            ),
            SecurityStatusFlag(
                id: "origin_trust",
                title: "Origin Trust",
                status: trustedOrigins > 0 ? "configured" : "limited",
                detail: trustedOrigins > 0 ? "\(trustedOrigins) approved remote trust \(trustedOrigins == 1 ? "entry" : "entries") across Telegram, Slack, and paired phones. Each request still needs origin verification." : "No approved remote trust entries. A remote request nobody verified can read; anything else it asks for waits for you.",
                enabled: true
            ),
            SecurityStatusFlag(
                id: "signed_remote_commands",
                title: "Signed Remote Commands",
                status: "unknown",
                detail: "Trusted remote requests normally use the Mac's permission law. With strict signing on and the signature waiver for trusted origins disabled, an unsigned effect waits for you.",
                enabled: Self.bool(security["signedRemoteCommandsRequired"], default: true)
            ),
            Self.auditFlag(enabled: Self.bool(security["auditReceiptsEnabled"], default: true), history: history),
        ]
        return SecurityCenterStatus(
            status: killSwitch ? "blocked" : "unknown",
            mode: permission,
            developerMode: developerMode,
            fullMac: fullMac,
            killSwitchEnabled: killSwitch,
            trustedOrigins: trustedOrigins,
            auditReceiptsPath: auditReceiptsPath.path,
            flags: flags,
            recentReceipts: recent
        )
    }

    private static func auditFlag(enabled: Bool, history: Result<[JSONValue], any Error>) -> SecurityStatusFlag {
        let detail: String
        let status: String
        switch (enabled, history) {
        case (false, _):
            (status, detail) = ("off", "Recording is off, so gated actions are not being logged.")
        case (true, .failure(let error)):
            (status, detail) = ("failed", "security/audit.jsonl did not read (\(error.localizedDescription)), so I cannot show what was recorded.")
        case (true, .success):
            (status, detail) = ("unknown", "The retained audit history reads back; this does not prove every gated action was recorded.")
        }
        return SecurityStatusFlag(id: "audit_receipts", title: "Audit Receipts", status: status, detail: detail, enabled: enabled)
    }

    /// "Pause everything": every door that admits an action reads it here.
    public static func killSwitchRefusal(policy: [String: JSONValue]) -> (reason: String, remedy: JSONValue)? {
        guard bool(object(policy["securityPolicy"])["killSwitchEnabled"], default: false) else { return nil }
        return ("trust/policy.json securityPolicy.killSwitchEnabled=true stops this action.",
                Repair.why(owner: "trust/policy.json securityPolicy.killSwitchEnabled", tap: "Trust > Access > Security Center > Pause everything"))
    }

    public func evaluateTool(
        tool: String,
        input: [String: JSONValue],
        origin: SecurityOriginContext,
        enforceAutonomy: Bool = true
    ) async -> SecurityToolEnvelope {
        do {
            let snapshot = try await trustCenter.loadAuthorizationSnapshotChecked()
            let evaluatedAt = clock()
            return try await evaluateTool(
                tool: tool,
                input: input,
                origin: origin,
                enforceAutonomy: enforceAutonomy,
                snapshot: snapshot,
                evaluatedAt: evaluatedAt
            )
        } catch {
            return unavailablePolicyEnvelope(
                tool: tool,
                input: input,
                origin: origin,
                error: error,
                evaluatedAt: clock()
            )
        }
    }

    private func evaluateTool(
        tool: String,
        input: [String: JSONValue],
        origin: SecurityOriginContext,
        enforceAutonomy: Bool,
        snapshot: TrustPolicyAuthorizationSnapshot,
        evaluatedAt: Date
    ) async throws -> SecurityToolEnvelope {
        let policy = snapshot.policy
        let security = Self.object(policy["securityPolicy"])
        let canonicalTool = Self.policyToolName(tool)
        let trustedRoots = Self.trustedWorkspaceRoots(
            policy: policy,
            filePolicy: Self.object(policy["filePolicy"]),
            dataRoot: dataRoot
        )
        let profile = Self.profile(
            tool: canonicalTool,
            input: input,
            dataRoot: dataRoot,
            trustedWorkspaceRoots: trustedRoots
        )
        // Origin trust is part of this exact authorization generation. In
        // particular, iOS trust lives inside trust/policy.json; rereading that
        // file here could splice Full Mac from generation A with paired-iOS
        // trust from generation B, authorizing a combination that never
        // existed. Connector-owned Telegram/Slack allowlists remain live reads
        // from their own authority domains.
        let originAssessment = try await assessOrigin(origin, policy: policy)
        let fullMacYoloAuthority = Self.fullMacYoloAuthority(
            originAssessment: originAssessment,
            snapshot: snapshot
        )
        // The one decision: User's posture and the class the call declares.
        let (toolClass, autonomyLevel, autonomyReason, autonomyRemedy) = PermissionLaw.answer(
            tool: tool, input: input, policy: policy, capabilities: profile.capabilities)
        // Typed-secret redaction precedes generic redaction so persisted audit previews cannot contain injected secrets.
        let redacted = Self.redactValue(
            .object(MacInjectionArgRedaction.redacted(tool: canonicalTool, input: input))
        )
        let auditEnabled = Self.bool(security["auditReceiptsEnabled"], default: true)

        var decision = SecurityToolDecision.allow
        var reasons: [SecurityReason] = []
        reasons.append(.init(.autonomy, autonomyReason))
        var remedy = autonomyRemedy
        if !originAssessment.trusted {
            reasons.append(.init(.origin, originAssessment.reason))
        }

        if let paused = Self.killSwitchRefusal(policy: policy) {
            decision = .block
            reasons.append(.init(.cause, paused.reason))
            remedy = paused.remedy
        }

        // Safe changes nothing on User's side of the line (the law).
        if decision != .block, autonomyLevel == "blocked" {
            decision = .block
            reasons.append(.init(.cause, autonomyReason))
        }

        if enforceAutonomy, decision != .block, ["send_approval", "confirm", "destructive_strong"].contains(autonomyLevel) {
            decision = .ask
            reasons.append(.init(.cause, autonomyReason))
        }

        // Full Mac is authority selected by the trusted operator; it is not an
        // authentication mechanism for an inbound sender. One rule for a remote
        // origin nobody authenticated (an untrusted peer, a stranger, an
        // unsigned request where signing is required): it reads, and anything
        // else it asks for, on either side of the line, is the person's card.
        // Trusted origins are judged exactly like the Mac. The kill switch stays a hard deny.
        let signatureMissing = !(originAssessment.trusted && Self.bool(security["trustedRemoteHighRiskAllowed"], default: true))
            && Self.bool(security["signedRemoteCommandsRequired"], default: true) && origin.commandSignatureVerified != true
        if decision != .block, originAssessment.isRemote, !originAssessment.trusted || signatureMissing, toolClass != .read {
            decision = .ask
            reasons.append(.init(.cause, originAssessment.trusted
                ? "This remote request has no verified signature, so it needs the person."
                : "\(originAssessment.reason): this request is not authenticated, so it needs the person."))
        }

        let now = Self.isoTimestamp(evaluatedAt)
        return SecurityToolEnvelope(
            id: UUID().uuidString,
            createdAt: now,
            tool: canonicalTool,
            surface: origin.surface,
            origin: origin,
            originTrusted: originAssessment.trusted,
            originTrustReason: originAssessment.reason,
            capabilities: Array(profile.capabilities).sorted(),
            risk: profile.risk.rawValue,
            autonomyLevel: autonomyLevel,
            fullMacYoloAuthority: fullMacYoloAuthority.state,
            decision: decision,
            allowed: decision == .allow,
            requiresApproval: decision == .ask,
            reasons: reasons,
            redactedInputPreview: redacted,
            auditReceiptsEnabled: auditEnabled,
            autonomyReason: autonomyReason,
            remedy: remedy
        )
    }

    private func unavailablePolicyEnvelope(
        tool: String,
        input: [String: JSONValue],
        origin: SecurityOriginContext,
        error: any Error,
        evaluatedAt: Date
    ) -> SecurityToolEnvelope {
        let canonicalTool = Self.policyToolName(tool)
        return SecurityToolEnvelope(
            id: UUID().uuidString,
            createdAt: Self.isoTimestamp(evaluatedAt),
            tool: canonicalTool,
            surface: origin.surface,
            origin: origin,
            originTrusted: false,
            originTrustReason: "saved trust policy is unavailable",
            capabilities: [],
            risk: CanonicalToolRisk.critical.rawValue,
            autonomyLevel: "blocked",
            fullMacYoloAuthority: .unavailable,
            decision: .block,
            allowed: false,
            requiresApproval: false,
            reasons: [.init(.cause, "\(dataRoot.appendingPathComponent("trust/policy.json").path) could not authorize \(canonicalTool): \(error.localizedDescription)")],
            redactedInputPreview: Self.redactValue(
                .object(MacInjectionArgRedaction.redacted(tool: canonicalTool, input: input))
            ),
            auditReceiptsEnabled: true,
            remedy: Repair.remedy(owner: "trust/policy.json", nextCall: nil,
                tap: "Trust > Access and policy > Preserve damaged policy and authorize Safe")
        )
    }

    public func record(_ envelope: SecurityToolEnvelope) async throws {
        guard envelope.auditReceiptsEnabled else { return }
        // Owns security/audit.jsonl (envelope JSONL), audit-archive-<date>.jsonl
        // (preserved bytes) and .audit-pretrim-archive-complete-v1 (completed\n).
        // Deliberately local: no local backup, data export or phone sync.
        // PrivacyMap lists Security Audit. Archive and append share this lock.
        let path = auditReceiptsPath
        let event = envelope.toJSONValue()
        let now = clock()
        try await SwiftNativePersistenceCore.withFileLock(path) {
            try await appendJSONLCapped(
                event,
                to: path,
                maxLines: JSONLLineCaps.securityAudit,
                logLabel: "SecurityCenter.audit",
                trimWhenBytesExceed: JSONLLineCaps.securityAuditTrimTriggerBytes,
                beforePotentialLineCap: { dropped in
                    guard let dropped, !dropped.isEmpty else { return }
                    try Self.archivePreTrimAuditIfNeeded(path: path, now: now)
                }
            )
        }
    }

    /// Archive the complete original once before selected rows are removed; failure aborts trimming.
    private static func archivePreTrimAuditIfNeeded(path: URL, now: Date) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return }
        let dir = path.deletingLastPathComponent()
        let completionMarker = dir.appendingPathComponent(
            ".audit-pretrim-archive-complete-v1"
        )
        guard !fm.fileExists(atPath: completionMarker.path) else { return }
        let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if existing.contains(where: {
            $0.hasPrefix("audit-archive-") && $0.hasSuffix(".jsonl")
        }) {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(
                Data("completed\n".utf8),
                to: completionMarker
            )
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let destination = dir.appendingPathComponent(
            "audit-archive-\(formatter.string(from: now)).jsonl"
        )
        try fm.copyItem(at: path, to: destination)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(
            Data("completed\n".utf8),
            to: completionMarker
        )
    }

    private var auditReceiptsPath: URL {
        dataRoot
            .appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
    }

    func assessOrigin(
        _ origin: SecurityOriginContext,
        policy: [String: JSONValue]
    ) async throws -> OriginAssessment {
        let surfaceProfile = ConversationSurfaceProfile(origin.surface)
        let surface = surfaceProfile.id
        // Known remote surfaces stay remote regardless of caller metadata.
        let remote = surfaceProfile.isRemote || (origin.isRemote == true)
        if !remote {
            return OriginAssessment(trusted: true, reason: "local app surface", isRemote: false)
        }
        // A bridge turn with no untrusted peer left unanswered among its sources
        // is authenticated by the person: a peer he trusts (bound by its verified
        // id), or a command whose one card he answered, named or not.
        if PeerTurnEffectPolicy.isPeerBridge(surface: origin.surface), CapabilityLifecycle.turnWriteCheck()() == nil {
            return OriginAssessment(trusted: true, reason: "a peer the person trusts or a command he answered", isRemote: true)
        }
        if surface == "telegram" || surface == "slack" {
            // Only transport-bound identities prove an allowlisted origin.
            let allowed = try await (surface == "telegram" ? telegramSecurityAllowlist() : slackSecurityAllowlist())
            if let reason = allowed.matches(chatId: origin.chatId, userId: origin.userId) {
                return OriginAssessment(trusted: true, reason: reason, isRemote: true)
            }
            if let unverified = Self.unverifiedRemoteIdentityAssessment(origin, surface: surface == "telegram" ? "Telegram" : "Slack") {
                return unverified
            }
            if allowed.isEmpty {
                return OriginAssessment(trusted: false, reason: "\(surface) allowlist not configured for security proof", isRemote: true)
            }
            return OriginAssessment(trusted: false, reason: "\(surface) origin is not in allowlist", isRemote: true)
        }
        if surfaceProfile.isIOSRemote {
            let iosRemote = Self.object(policy["iosRemotePolicy"])
            // iOS trust requires iosRemotePolicy or transport-verified, signed Full Mac authority.
            let signedFullMac = Self.fullMacActive(policy: policy)
                && origin.commandSignatureVerified == true
            let pairedAllowed = signedFullMac
                || Self.bool(iosRemote["remote_from_ios_allowed"], default: false)
            return OriginAssessment(
                trusted: pairedAllowed,
                reason: pairedAllowed ? "paired iOS remote control enabled" : "iOS remote control not trusted for high-risk actions",
                isRemote: true
            )
        }
        if let unverified = Self.unverifiedRemoteIdentityAssessment(
            origin,
            surface: surfaceProfile.id
        ) {
            return unverified
        }
        return OriginAssessment(trusted: false, reason: "remote origin has no trust root", isRemote: true)
    }

    /// Rejects origins without a bound chat or user identity; otherwise leaves the caller's allowlist verdict intact.
    static func unverifiedRemoteIdentityAssessment(
        _ origin: SecurityOriginContext,
        surface: String
    ) -> OriginAssessment? {
        func bound(_ value: String?) -> Bool {
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !bound(origin.chatId), !bound(origin.userId) else { return nil }
        return OriginAssessment(
            trusted: false,
            reason: "\(surface) turn arrived with no verified chat or user identity — "
                + "its transport bound none, so there is nothing to check against the "
                + "allowlist. Treating it as untrusted.",
            isRemote: true
        )
    }

    private func trustedOriginCount() async throws -> Int {
        let telegram = try await telegramSecurityAllowlist()
        let slack = try await slackSecurityAllowlist()
        let phones = try PairedPhoneAuthority.pairedCountChecked(
            at: dataRoot.appendingPathComponent("paired_phones.json")
        )
        return telegram.count + slack.chatIds.count + slack.userIds.count + phones
    }

    private func slackSecurityAllowlist() async throws -> TelegramSecurityAllowlist {
        let allowed = try TransportAllowlist.slack(dataRoot: dataRoot)
        return TelegramSecurityAllowlist(chatIds: allowed.chatIds, userIds: allowed.userIds, surfaceLabel: "slack")
    }

    /// The turn's verified SENDER is one the person allowlisted by user id
    /// on Telegram or Slack: the allowlists `assessOrigin` trusts, without its
    /// allowed-chat match, which admits anyone in that chat. A private
    /// Telegram chat's id is its sender's. Anything unreadable is not him.
    public func remoteSenderIsAllowlisted(_ origin: SecurityOriginContext) async -> Bool {
        let surface = ConversationSurfaceProfile(origin.surface).id
        guard let allowed = try? await (surface == "telegram" ? telegramSecurityAllowlist()
            : surface == "slack" ? slackSecurityAllowlist() : nil) else { return false }
        if let user = origin.userId { return allowed.userIds.contains(user) }
        return surface == "telegram" && origin.chatId.map(allowed.userIds.contains) == true
    }

    private func telegramSecurityAllowlist() async throws -> TelegramSecurityAllowlist {
        let allowed = try TransportAllowlist.telegram(dataRoot: dataRoot)
        return TelegramSecurityAllowlist(chatIds: allowed.chatIds, userIds: allowed.userIds)
    }
}

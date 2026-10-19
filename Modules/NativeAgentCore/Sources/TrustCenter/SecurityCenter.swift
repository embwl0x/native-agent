import FeedPolicy
import NativeAgentCore
import Foundation
import PersistenceCore
import ToolRegistry

enum SecurityRisk: String, Sendable, Comparable {
    case low
    case medium
    case high
    case critical

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    static func < (lhs: SecurityRisk, rhs: SecurityRisk) -> Bool {
        lhs.rank < rhs.rank
    }
}

struct OriginAssessment: Sendable {
    var trusted: Bool
    var reason: String
    var isRemote: Bool
}

struct TelegramSecurityAllowlist: Sendable {
    var chatIds: Set<String>
    var userIds: Set<String>
    // 2026-07-21 audit: the same allowlist shape now backs slack too; the
    // label keeps reason strings surface-honest (telegram reasons stay
    // byte-identical via the default).
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
    private let persistence: any PersistenceCoreProtocol
    let clock: @Sendable () -> Date
    let trustCenter: SwiftNativeTrustCenter

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.clock = clock
        self.trustCenter = SwiftNativeTrustCenter(
            dataRoot: dataRoot,
            persistence: persistence,
            clock: clock
        )
    }

    public func status(limit: Int = 8) async throws -> SecurityCenterStatus {
        // The history is the audit's evidence: "ready" only when it reads.
        let history: Result<[JSONValue], any Error>
        do { history = .success(try await persistence.tailJSONL(auditReceiptsPath, limit: limit, maxBytes: 512 * 1024)) }
        catch { history = .failure(error) }
        let recent = ((try? history.get()) ?? []).compactMap(Self.receiptSummary)
        let policy: [String: JSONValue]
        do {
            policy = try await trustCenter.loadTrustPolicyChecked()
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
        let permission = Self.string(policy["permissionLevel"]) ?? "balanced"
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
                status: trustedOrigins > 0 ? "ready" : "limited",
                detail: trustedOrigins > 0 ? "\(trustedOrigins) approved remote trust \(trustedOrigins == 1 ? "entry" : "entries") across Telegram, Slack, and paired phones. Each request still needs origin verification." : "No approved remote trust entries. A remote request nobody verified can read; anything else it asks for waits for you.",
                enabled: true
            ),
            SecurityStatusFlag(
                id: "signed_remote_commands",
                title: "Signed Remote Commands",
                status: "ready",
                detail: "With strict signing on, a trusted remote request also needs a signature only your paired devices can produce before it changes anything; otherwise it waits for you.",
                enabled: Self.bool(security["signedRemoteCommandsRequired"], default: true)
            ),
            Self.auditFlag(enabled: Self.bool(security["auditReceiptsEnabled"], default: true), history: history),
        ]
        return SecurityCenterStatus(
            status: killSwitch ? "blocked" : "ready",
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
            (status, detail) = ("ready", "The record of gated actions on this Mac reads back, so you can check what ran.")
        }
        return SecurityStatusFlag(id: "audit_receipts", title: "Audit Receipts", status: status, detail: detail, enabled: enabled)
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
        let fullMac = Self.fullMacActive(policy: policy)
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
        var originAssessment = try await assessOrigin(origin, policy: policy)
        // A bridge turn from a peer the person trusts is authenticated by that
        // trust: no untrusted peer among the turn's sources, verified identity bound.
        if PeerTurnEffectPolicy.isPeerBridge(surface: origin.surface), origin.userId != nil,
           CapabilityLifecycle.turnWriteCheck()() == nil {
            originAssessment = OriginAssessment(trusted: true, reason: "a peer the person trusts", isRemote: true)
        }
        let fullMacYoloAuthority = Self.fullMacYoloAuthority(
            originAssessment: originAssessment,
            snapshot: snapshot
        )
        // The one decision: User's posture and the class the call declares.
        let (toolClass, autonomyLevel, autonomyReason, autonomyRemedy) = PermissionLaw.answer(
            tool: tool, input: input, policy: policy, dataRoot: dataRoot, roots: trustedRoots, capabilities: profile.capabilities)
        // W2/W3-FIX-R2 2 — `redactedInputPreview` is PERSISTED to
        // security/audit.jsonl by `record`, and this class's own redactor only
        // catches secret-NAMED keys and secret-SHAPED strings. The literal
        // characters of `legacy keystroke tool.text` / `legacy AX act tool.value` are neither:
        // "hunter2" is a short ordinary string under an ordinary key. Run the
        // injection-argument redactor first so the typed characters cannot
        // reach the audit file even if a caller hands us the raw body. The
        // gated dispatcher also redacts before calling — this boundary owns its
        // own redaction rather than trusting every present and future caller.
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

        if Self.bool(security["killSwitchEnabled"], default: false) {
            decision = .block
            reasons.append(.init(.cause, "trust/policy.json securityPolicy.killSwitchEnabled=true stops this action."))
            remedy = Repair.why(owner: "trust/policy.json securityPolicy.killSwitchEnabled", tap: "Trust > Access > Security Center > Pause everything")
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
            risk: SecurityRisk.critical.rawValue,
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
        // M6 (2026-07-09): this ledger appended forever. Rotate through the
        // shared capped-append so the newest 20k receipts survive and the file
        // cannot grow without bound.
        //
        // F5 (2026-08-28): the archive check and the capped append run under
        // ONE acquisition of the audit-file lock so a concurrent trim cannot
        // interleave between "worth archiving" and the copy.
        let path = auditReceiptsPath
        let event = envelope.toJSONValue()
        let now = clock()
        let persistence = self.persistence
        try await persistence.withFileLock(path) {
            try await appendJSONLCapped(
                event,
                to: path,
                using: persistence,
                maxLines: JSONLLineCaps.securityAudit,
                logLabel: "SecurityCenter.audit",
                takeLock: false,
                trimWhenBytesExceed: JSONLLineCaps.securityAuditTrimTriggerBytes,
                beforePotentialLineCap: {
                    try Self.archivePreTrimAuditIfNeeded(path: path, now: now)
                }
            )
        }
    }

    /// F5 (2026-08-28): one-time archive before the FIRST trim that could
    /// drop audit rows. The 32→16 MiB trigger change makes the byte-triggered
    /// trim actually fire on a ledger that historically grew unbounded
    /// (23 MiB / 33k rows on the live root); the newest-20k trim would
    /// silently drop the oldest ~13k receipts. Copy the pre-trim file to a
    /// sibling `audit-archive-<date>.jsonl` first — once, ever: any existing
    /// `audit-archive-*.jsonl` means the deliberate one-shot already happened.
    ///
    /// Review fix (gpt-5.5, HIGH): gating on bytes alone left a side door —
    /// stride appends (PersistenceCore F2) enforce the ROW cap with no byte
    /// gate, so a compact over-cap file UNDER the byte trigger gets rows
    /// dropped with no archive taken. The gate is therefore
    /// `bytes >= trigger OR rows > cap` — the union of both conditions under
    /// which any trim path can drop rows. The row count is one bounded read
    /// (< trigger bytes by construction) and only happens while no archive
    /// exists; the exists-check runs first so the read stops forever after
    /// the one-shot.
    ///
    /// The archive is a different filename in the same `security/` dir, so
    /// the trim (which only rewrites `audit.jsonl`) never touches it. A
    /// failed copy throws rather than letting the trim proceed and lose
    /// history silently. Caller holds the audit-file lock.
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
        let attributes = try? fm.attributesOfItem(atPath: path.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        var shouldArchive = size >= JSONLLineCaps.securityAuditTrimTriggerBytes
        if !shouldArchive {
            // An unreadable file must abort the trim like a failed copy does —
            // returning here would let the row-cap trim drop history with no
            // archive (2026-08-28 audit).
            let data = try Data(contentsOf: path)
            var rows = 0
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                for byte in buffer where byte == 0x0A { rows += 1 }
            }
            // This runs before the pending append. Exactly `cap` existing rows
            // become `cap + 1`, so equality is already a trim boundary.
            shouldArchive = rows >= JSONLLineCaps.securityAudit
        }
        guard shouldArchive else { return }
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
        // Defense-in-depth (gpt-5.5 review, 2026-06-09): a KNOWN remote chat
        // surface (telegram/ios/iCloud/phone aliases) can never be downgraded
        // to a local/trusted origin by a caller passing isRemote:false. Only an
        // explicit isRemote:true can ADD remoteness to an otherwise-unknown
        // surface; it can't subtract it from a known-remote one. Matters more
        // now that trusted remote origins get the signed-command waiver above —
        // local==trusted must not be forgeable.
        let remote = surfaceProfile.isRemote || (origin.isRemote == true)
        if !remote {
            return OriginAssessment(trusted: true, reason: "local app surface", isRemote: false)
        }
        if surface == "telegram" {
            // PARSE SITE 1 of 5, DELETED (one-thread-many-surfaces plan §1.2).
            // This used to fall back to `telegramChatId(fromSessionId:)` —
            // reading `telegram:<chatId>` out of the session id string and
            // treating the result as a VERIFIED identity in a TRUST decision.
            //
            // It was already unsound. `chat/sessions.json` carries rows whose
            // ids are `telegram:codex-probe` and
            // `telegram:codex-tool-catalog-probe` with `source: "app"`; the
            // parse yielded "codex-probe" as a chat identity for those. It
            // failed closed only because that string happens to be in nobody's
            // allowlist. A storage key is not evidence, and anything that can
            // choose a session id could choose that evidence.
            //
            // Identity now comes from the transport, bound on the envelope, or
            // the origin fails closed WITH A REASON — never silently.
            let allowed = try await telegramSecurityAllowlist()
            if let reason = allowed.matches(chatId: origin.chatId, userId: origin.userId) {
                return OriginAssessment(trusted: true, reason: reason, isRemote: true)
            }
            if let unverified = Self.unverifiedRemoteIdentityAssessment(origin, surface: "Telegram") {
                return unverified
            }
            if allowed.isEmpty {
                return OriginAssessment(trusted: false, reason: "telegram allowlist not configured for security proof", isRemote: true)
            }
            return OriginAssessment(trusted: false, reason: "telegram origin is not in allowlist", isRemote: true)
        }
        if surface == "slack" {
            // 2026-07-21 audit fix: Slack socket mode has NO request-signature
            // scheme (signing exists only for the HTTP Events API), and the
            // chat handler bound commandSignatureVerified=true UNCONDITIONALLY
            // — every workspace member got trusted-origin high-risk tool
            // access on a forged proof. Trust now roots in an explicit
            // allowlist, mirroring telegram. (The forged binding is removed at
            // the handler; no caller may reintroduce it.)
            let allowed = try await slackSecurityAllowlist()
            if let reason = allowed.matches(chatId: origin.chatId, userId: origin.userId) {
                return OriginAssessment(trusted: true, reason: reason, isRemote: true)
            }
            if let unverified = Self.unverifiedRemoteIdentityAssessment(origin, surface: "Slack") {
                return unverified
            }
            if allowed.isEmpty {
                return OriginAssessment(trusted: false, reason: "slack allowlist not configured for security proof", isRemote: true)
            }
            return OriginAssessment(trusted: false, reason: "slack origin is not in allowlist", isRemote: true)
        }
        if surfaceProfile.isIOSRemote {
            let iosRemote = Self.object(policy["iosRemotePolicy"])
            // 2026-07-21 audit fix: decoupled the mac_control feature flag
            // from the SecurityCenter trust root. The previous
            // (iosRemote || macControl) disjunction meant flipping "remote
            // from iOS" for Mac Control silently made EVERY ios-family origin
            // trusted for ALL high-risk security gates (incl. the
            // signed-remote-command waiver and full-Mac trusted-remote
            // surfaces). Outside an active, cryptographically authenticated
            // Full Mac turn, the trust root remains iosRemotePolicy alone.
            // Full Mac is the operator's grant across authenticated surfaces.
            // A missing legacy iOS switch must not override that grant. The
            // signature is bound by the receiving transport, never metadata.
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

    /// FAIL CLOSED, OUT LOUD (plan §7 Phase 1; sweep item 9 — outcome-unknown
    /// becomes speech).
    ///
    /// Deleting the session-id parses makes explicit identity binding
    /// MANDATORY rather than best-effort. A remote transport that binds
    /// neither a chat identity nor a user identity is not "an origin that
    /// missed the allowlist" — it is an origin nobody checked. Those two
    /// facts deserve different sentences, because only one of them is a bug in
    /// the adapter.
    ///
    /// Surface-generic on purpose: a surface connected next year gets this
    /// refusal for free, in its own name, with no edit here.
    ///
    /// Returns nil when identity WAS bound, leaving the caller's allowlist
    /// verdict to stand.
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
        // Mirrors the slack connector's own config probe
        // (SlackSocketModeConfig.tokenObjects): connectors/slack/auth.json +
        // oauth_tokens/slack.json under the data root. Channel ids are the
        // slack 'chat' id.
        let paths = [
            dataRoot.appendingPathComponent("connectors", isDirectory: true)
                .appendingPathComponent("slack", isDirectory: true)
                .appendingPathComponent("auth.json"),
            dataRoot.appendingPathComponent("oauth_tokens", isDirectory: true)
                .appendingPathComponent("slack.json"),
        ]
        var chatIds: Set<String> = []
        var userIds: Set<String> = []
        for path in paths {
            let raw = try await persistence.readJSON(path, ifMissing: .object([:]))
            let obj = Self.object(raw)
            chatIds.formUnion(Self.stringSet(obj["allowed_channel_ids"]))
            chatIds.formUnion(Self.stringSet(obj["allowedChannelIds"]))
            chatIds.formUnion(Self.stringSet(obj["allowed_chat_ids"]))
            chatIds.formUnion(Self.stringSet(obj["allowedChatIds"]))
            userIds.formUnion(Self.stringSet(obj["allowed_user_ids"]))
            userIds.formUnion(Self.stringSet(obj["allowedUserIds"]))
        }
        return TelegramSecurityAllowlist(chatIds: chatIds, userIds: userIds, surfaceLabel: "slack")
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
        let path = dataRoot
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json")
        let raw = try await persistence.readJSON(path, ifMissing: .object([:]))
        let obj = Self.object(raw)
        return TelegramSecurityAllowlist(
            chatIds: Self.stringSet(obj["allowed_chat_ids"]).union(Self.stringSet(obj["allowedChatIds"])),
            userIds: Self.stringSet(obj["allowed_user_ids"]).union(Self.stringSet(obj["allowedUserIds"]))
        )
    }
}

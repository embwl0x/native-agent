import NativeAgentCore
import Foundation
import PersistenceCore
import ToolRegistry
import Experiences
import NativeAgentShared
// Blueprint: | `SecurityCenter.swift` | Origin-aware checked decisions and retained audit evidence. |

struct OriginAssessment: Sendable {
    var trusted: Bool
    var reason: String
    var isRemote: Bool
}

struct TelegramSecurityAllowlist: Sendable {
    var chatIds: Set<String>
    var userIds: Set<String>
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
        // Telegram private-chat ids identify the user; accept that binding only there because Slack namespaces are unrelated.
        if surfaceLabel == "telegram", userId == nil, let chatId, userIds.contains(chatId) {
            return "telegram private user allowlist matched"
        }
        return nil
    }
}

public actor SwiftNativeSecurityCenter {
    public static let consentDidWrite = Notification.Name("NativeAgent.consentDidWrite")
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
        do {
            let details = try await ExperienceStore.at(dataRoot).details(.init(kinds: ["consent"], limit: limit, newestFirst: true))
            history = .success(try details.reversed().map { try JSONValue.parse($0.row) })
        }
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
                detail: trustedOrigins > 0 ? """
                    \(trustedOrigins) approved remote trust \(trustedOrigins == 1 ? "entry" : "entries") across Telegram, Slack, and paired phones. \
                    Each request still needs origin verification.
                    """ : "No approved remote trust entries. A remote request nobody verified can read; anything else it asks for waits for you.",
                enabled: true
            ),
            SecurityStatusFlag(
                id: "signed_remote_commands",
                title: "Signed Remote Commands",
                status: "unknown",
                detail: """
                    Trusted remote requests normally use the Mac's permission law. With strict signing on and the signature waiver for trusted \
                    origins disabled, an unsigned effect waits for you.
                    """,
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
            (status, detail) = ("failed", "Consent details did not read (\(error.localizedDescription)), so I cannot show what was recorded.")
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
        enforceAutonomy: Bool = true,
        turn: Turn?
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
                evaluatedAt: evaluatedAt,
                turn: turn
            )
        } catch {
            return unavailablePolicyEnvelope(
                tool: tool,
                input: input,
                origin: origin,
                error: error,
                evaluatedAt: clock(),
                turn: turn
            )
        }
    }

    private func evaluateTool(
        tool: String,
        input: [String: JSONValue],
        origin: SecurityOriginContext,
        enforceAutonomy: Bool,
        snapshot: TrustPolicyAuthorizationSnapshot,
        evaluatedAt: Date,
        turn: Turn?
    ) async throws -> SecurityToolEnvelope {
        // A batch's entries re-enter the door separately; an unknown sibling is not the batch's consent decision.
        let batch: Bool = if tool == "app", case .array? = input["actions"] { true } else { false }
        if !batch, let reason = MacInjectionArgRedaction.unknownActionReason(in: .object(input)) {
            throw ToolFailureError(reason, effects: .none, owner: "the action catalog", code: "unknown_action",
                instruction: "Find the action by what it should do; a removed action's replacement is found the same way.")
        }
        if let reason = MacInjectionArgRedaction.withheldArgumentReason(in: .object(input), includingUnknownActions: !batch) {
            throw ToolFailureError(reason, effects: .none, owner: "Action argument contract",
                code: "argument_contract_unavailable",
                instruction: """
                    Repair or identify the current action, then submit its original arguments again. Withheld arguments cannot be executed or \
                    approved.
                    """)
        }
        let policy = snapshot.policy
        let security = Self.object(policy["securityPolicy"])
        let canonicalTool = Self.policyToolName(tool)
        let trustedRoots = Self.trustedWorkspaceRoots(
            filePolicy: Self.object(policy["filePolicy"]),
            dataRoot: dataRoot
        )
        let profile = try Self.profile(
            tool: canonicalTool,
            input: input,
            dataRoot: dataRoot,
            turn: turn,
            trustedWorkspaceRoots: trustedRoots
        )
        // Keep origin trust and Full Mac in the same checked policy generation so no mixed snapshot can invent authority. Connector allowlists retain their own
        // live authority reads.
        let originAssessment = try await assessOrigin(origin, policy: policy, turn: turn)
        let fullMacYoloAuthority = Self.fullMacYoloAuthority(
            originAssessment: originAssessment,
            snapshot: snapshot
        )
        let (toolClass, autonomyLevel, autonomyReason, autonomyRemedy) = try PermissionLaw.answer(
            tool: tool, input: input, policy: policy, capabilities: profile.capabilities, turn: turn)
        // Typed-secret redaction precedes generic redaction so persisted audit previews cannot contain injected secrets.
        let redacted = Self.redactValue(
            .object(MacInjectionArgRedaction.redacted(tool: canonicalTool, input: input, turn: turn))
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

        // Safe posture cannot change the person's side of the boundary.
        if decision != .block, autonomyLevel == "blocked" {
            decision = .block
            reasons.append(.init(.cause, autonomyReason))
        }

        if enforceAutonomy, decision != .block, ["send_approval", "confirm", "destructive_strong"].contains(autonomyLevel) {
            decision = .ask
            reasons.append(.init(.cause, autonomyReason))
        }

        // Full Mac grants autonomy, not sender authentication; unauthenticated origins need a card for every non-read. Trusted origins use ordinary local
        // policy, including the hard kill switch.
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
        evaluatedAt: Date,
        turn: Turn?
    ) -> SecurityToolEnvelope {
        let canonicalTool = Self.policyToolName(tool)
        let failure = error as? ToolFailureError
        return SecurityToolEnvelope(
            id: UUID().uuidString,
            createdAt: Self.isoTimestamp(evaluatedAt),
            tool: canonicalTool,
            surface: origin.surface,
            origin: origin,
            originTrusted: false,
            originTrustReason: "admission evidence is unavailable",
            capabilities: [],
            risk: CanonicalToolRisk.unavailable.rawValue,
            autonomyLevel: "blocked",
            fullMacYoloAuthority: .unavailable,
            decision: .block,
            allowed: false,
            requiresApproval: false,
            reasons: [.init(.cause, failure?.code == "unknown_action" ? error.localizedDescription
                : "\(canonicalTool) could not be authorized: \(error.localizedDescription)")],
            redactedInputPreview: Self.redactValue(
                .object(MacInjectionArgRedaction.redacted(tool: canonicalTool, input: input, turn: turn))
            ),
            auditReceiptsEnabled: true,
            remedy: Repair.remedy(owner: failure?.owner ?? "trust/policy.json", nextCall: nil,
                tap: failure?.tap,
                instruction: failure?.instruction ?? "Preserve the unavailable source and repair the reported cause before retrying.")
        )
    }

    public func record(_ envelope: SecurityToolEnvelope) async throws {
        guard envelope.auditReceiptsEnabled else { return }
        guard let at = NativeTimestampFormat.parseISO8601(envelope.createdAt) else {
            throw PersistenceCoreError.ioFailure("Consent decision \(envelope.id) has an unreadable created_at timestamp")
        }
        // The envelope carries no turn identity; never substitute its decision or session id for a turn.
        try await ExperienceStore.at(dataRoot).note([
            .init(source: "trust", at: at, subject: "", kind: "consent", row: try envelope.toJSONValue().serializedData(pretty: false))
        ])
        NotificationCenter.default.post(name: Self.consentDidWrite, object: nil)
    }

    private var auditReceiptsPath: URL {
        dataRoot.appendingPathComponent("experiences/experiences.sqlite")
    }

    func assessOrigin(
        _ origin: SecurityOriginContext,
        policy: [String: JSONValue],
        turn: Turn?
    ) async throws -> OriginAssessment {
        let surfaceProfile = ConversationSurfaceProfile(origin.surface)
        let surface = surfaceProfile.id
        // Known remote surfaces stay remote regardless of caller metadata.
        let remote = surfaceProfile.isRemote || (origin.isRemote == true)
        if !remote {
            return OriginAssessment(trusted: true, reason: "local app surface", isRemote: false)
        }
        // Verified trusted peers and person-approved commands carry authority only when no untrusted source remains.
        if PeerTurnEffectPolicy.isPeerBridge(surface: origin.surface), CapabilityLifecycle.turnWriteCheck(turn)() == nil {
            return OriginAssessment(trusted: true, reason: "a peer the person trusts or a command the person answered", isRemote: true)
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
            let macControl = Self.object(policy["macControlPolicy"])
            // Only a transport-verified command may use the current phone grant.
            let signedFullMac = Self.fullMacActive(policy: policy)
                && origin.commandSignatureVerified == true
            let pairedAllowed = origin.commandSignatureVerified == true && (signedFullMac
                || Self.bool(macControl["remote_from_ios_allowed"], default: false))
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

    /// User allowlists prove the sender; chat allowlists alone admit anyone in that chat. Unreadable authority throws its cause.
    public func remoteSenderIsAllowlisted(_ origin: SecurityOriginContext) async throws -> Bool {
        let surface = ConversationSurfaceProfile(origin.surface).id
        guard let allowed = try await (surface == "telegram" ? telegramSecurityAllowlist()
            : surface == "slack" ? slackSecurityAllowlist() : nil) else { return false }
        if let user = origin.userId { return allowed.userIds.contains(user) }
        return surface == "telegram" && origin.chatId.map(allowed.userIds.contains) == true
    }

    private func telegramSecurityAllowlist() async throws -> TelegramSecurityAllowlist {
        let allowed = try TransportAllowlist.telegram(dataRoot: dataRoot)
        return TelegramSecurityAllowlist(chatIds: allowed.chatIds, userIds: allowed.userIds)
    }
}

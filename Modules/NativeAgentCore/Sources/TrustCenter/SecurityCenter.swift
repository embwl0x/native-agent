import Foundation
import MacControl
import PersistenceCore

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
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol
    private let clock: @Sendable () -> Date
    private let trustCenter: SwiftNativeTrustCenter

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

    public func status(limit: Int = 8) async -> SecurityCenterStatus {
        let policy: [String: JSONValue]
        do {
            policy = try await trustCenter.loadTrustPolicyChecked()
        } catch {
            let receipts = (try? await persistence.tailJSONL(
                auditReceiptsPath, limit: limit, maxBytes: 512 * 1024
            )) ?? []
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
                )],
                recentReceipts: receipts.compactMap(Self.receiptSummary)
            )
        }
        let security = Self.object(policy["securityPolicy"])
        let permission = Self.string(policy["permissionLevel"]) ?? "balanced"
        let developerMode = Self.bool(policy["developerMode"], default: false)
        let fullMac = Self.fullMacActive(policy: policy, now: clock())
        let receipts = (try? await persistence.tailJSONL(auditReceiptsPath, limit: limit, maxBytes: 512 * 1024)) ?? []
        let recent = receipts.compactMap(Self.receiptSummary)
        let trustedOrigins = await trustedOriginCount()
        let killSwitch = Self.bool(security["killSwitchEnabled"], default: false)
        let auditEnabled = Self.bool(security["auditReceiptsEnabled"], default: true)
        let flags = [
            SecurityStatusFlag(
                id: "security_center",
                title: "Security Center",
                status: killSwitch ? "blocked" : "ready",
                detail: killSwitch ? "Global kill switch is active" : "Swift-native security evaluator is active",
                enabled: true
            ),
            SecurityStatusFlag(
                id: "capability_policy",
                title: "Capability Policy",
                status: "ready",
                detail: "Tool risk is derived from capability class before dispatch",
                enabled: Self.bool(security["capabilityPolicyEnabled"], default: true)
            ),
            SecurityStatusFlag(
                id: "origin_trust",
                title: "Origin Trust",
                status: trustedOrigins > 0 ? "ready" : "limited",
                detail: trustedOrigins > 0 ? "\(trustedOrigins) remote trust root(s) configured" : "Remote high-risk actions require stronger proof",
                enabled: Self.bool(security["originTrustEnabled"], default: true)
            ),
            SecurityStatusFlag(
                id: "signed_remote_commands",
                title: "Signed Remote Commands",
                status: "ready",
                detail: "Remote high-risk commands require a command signature",
                enabled: Self.bool(security["signedRemoteCommandsRequired"], default: true)
            ),
            SecurityStatusFlag(
                id: "prompt_injection_shield",
                title: "Prompt-Injection Shield",
                status: "ready",
                detail: "Tool inputs are scanned for instruction hijacks and exfiltration requests",
                enabled: Self.bool(security["promptInjectionShieldEnabled"], default: true)
            ),
            SecurityStatusFlag(
                id: "danger_gates",
                title: "Danger Gates",
                status: (developerMode || fullMac) ? "armed" : "ready",
                detail: developerMode
                    ? "Developer Mode allows critical local actions"
                    : (fullMac
                        ? "Full Mac (yolo) window grants Developer-Mode access to critical local actions"
                        : "Critical actions are blocked without Developer Mode"),
                enabled: Self.bool(security["dangerGatesEnabled"], default: true)
            ),
            SecurityStatusFlag(
                id: "rollback_by_default",
                title: "Rollback By Default",
                status: "ready",
                detail: "Write/delete capability classes carry backup expectations",
                enabled: Self.bool(security["rollbackByDefault"], default: true)
            ),
            SecurityStatusFlag(
                id: "secret_firewall",
                title: "Secret Firewall",
                status: "ready",
                detail: "Secrets are redacted from receipts and blocked from unsafe egress",
                enabled: Self.bool(security["secretFirewallEnabled"], default: true)
            ),
            SecurityStatusFlag(
                id: "skill_tool_signing",
                title: "Skill/Tool Signing",
                status: "ready",
                detail: "Promoted manifests keep HMAC signatures and unsigned high-risk tools are gated",
                enabled: Self.bool(security["toolSigningRequired"], default: true)
            ),
            SecurityStatusFlag(
                id: "audit_receipts",
                title: "Audit Receipts",
                status: auditEnabled ? "ready" : "off",
                detail: auditReceiptsPath.path,
                enabled: auditEnabled
            ),
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

    public func evaluateTool(
        tool: String,
        input: [String: JSONValue],
        origin: SecurityOriginContext,
        enforceAutonomy: Bool = true
    ) async -> SecurityToolEnvelope {
        let policy: [String: JSONValue]
        do {
            policy = try await trustCenter.loadTrustPolicyChecked()
        } catch {
            let canonicalTool = Self.canonicalToolName(tool)
            return SecurityToolEnvelope(
                id: UUID().uuidString,
                createdAt: Self.isoTimestamp(clock()),
                tool: canonicalTool,
                surface: origin.surface,
                origin: origin,
                originTrusted: false,
                originTrustReason: "saved trust policy is unavailable",
                capabilities: [],
                risk: SecurityRisk.critical.rawValue,
                autonomyLevel: "blocked",
                signedToolKnown: false,
                rollbackRequired: true,
                decision: .block,
                allowed: false,
                requiresApproval: false,
                reasons: ["saved trust policy is unavailable: \(error.localizedDescription)"],
                untrustedInputKeys: Array(Set(Self.promptInjectionKeys(in: .object(input)))).sorted(),
                redactedInputPreview: Self.redactValue(.object(input)),
                auditReceiptsEnabled: true
            )
        }
        let security = Self.object(policy["securityPolicy"])
        let developerMode = Self.bool(policy["developerMode"], default: false)
        let filePolicy = Self.object(policy["filePolicy"])
        let connectorPolicy = Self.object(policy["connectorPolicy"])
        let fullMac = Self.fullMacActive(policy: policy, now: clock())
        let canonicalTool = Self.canonicalToolName(tool)
        let trustedRoots = Self.trustedWorkspaceRoots(
            policy: policy,
            filePolicy: filePolicy,
            dataRoot: dataRoot
        )
        let profile = Self.profile(
            tool: canonicalTool,
            input: input,
            dataRoot: dataRoot,
            trustedWorkspaceRoots: trustedRoots
        )
        let originAssessment = await assessOrigin(origin)
        let trustedLocalAgentBridge =
            Self.localAgentBridgeToolNames.contains(canonicalTool)
            && (!originAssessment.isRemote || originAssessment.trusted)
        // ACCEPTED RISK (2026-07-21 audit, LOW): the trusted-remote half of
        // this carve means an allowlisted Telegram GROUP member's injected
        // text, relayed by Agent into an invoke payload, skips the injection
        // shield. Kept deliberately: the waiver is pinned behavior
        // (SecurityCenter_allows_trustedTelegramCodexMessageWithPATTaskSpec)
        // for the operator's DM-only surface, the shield still fires on
        // flagged payloads from UNtrusted origins, and post-2026-07-21 a
        // security .ask routes to a real approval instead of a dead deny —
        // so flipping this to local-only is a one-line change if group
        // surfaces ever join the allowlist.
        let autonomyLevel = resolveAutonomyLevel(
            tool: canonicalTool,
            policy: policy,
            userOverrides: await trustCenter.userConfiguredAutonomyOverrides(),
            origin: origin,
            originAssessment: originAssessment,
            profile: profile,
            fullMac: fullMac
        )
        let promptInjectionKeys = Self.promptInjectionKeys(in: .object(input))
        let secretKeys = Self.secretKeys(in: .object(input))
        let redacted = Self.redactValue(.object(input))
        let signedToolKnown = await isSignedOrBuiltinTool(canonicalTool)
        let rollbackRequired = profile.capabilities.contains("filesystem_write")
            || profile.capabilities.contains("filesystem_delete")
            || profile.capabilities.contains("destructive")
        let auditEnabled = Self.bool(security["auditReceiptsEnabled"], default: true)

        var decision = SecurityToolDecision.allow
        var reasons: [String] = []
        reasons.append("autonomy: \(autonomyLevel)")
        if !originAssessment.trusted {
            reasons.append(originAssessment.reason)
        }
        if rollbackRequired && Self.bool(security["rollbackByDefault"], default: true) {
            reasons.append("rollback receipt required for write/delete class")
        }
        if !signedToolKnown {
            reasons.append("tool signature not known")
        }
        if !promptInjectionKeys.isEmpty {
            reasons.append("prompt-injection markers in \(promptInjectionKeys.joined(separator: ", "))")
        }
        if !secretKeys.isEmpty {
            reasons.append("secret-shaped input redacted in \(secretKeys.joined(separator: ", "))")
        }

        if Self.bool(security["killSwitchEnabled"], default: false),
           !Self.catalogToolNames.contains(canonicalTool) {
            decision = .block
            reasons.append("security kill switch is active")
        }

        if enforceAutonomy, decision != .block {
            switch autonomyLevel {
            case "blocked":
                decision = .block
                reasons.append("tool autonomy blocks this tool")
            case "send_approval", "confirm", "destructive_strong":
                if !Self.notificationToolNames.contains(canonicalTool),
                   !Self.catalogToolNames.contains(canonicalTool),
                   !profile.capabilities.contains("approval_stage") {
                    decision = Self.maxDecision(decision, .ask)
                    reasons.append("tool autonomy requires approval")
                }
            default:
                break
            }
        }

        if decision != .block,
           profile.risk >= .high,
           originAssessment.isRemote,
           !originAssessment.trusted,
           Self.bool(security["originTrustEnabled"], default: true) {
            decision = .block
            reasons.append("remote high-risk origin is not trusted")
        }

        // Uniform cross-surface access (the user, 2026-06-09): a TRUSTED remote origin
        // (allowlisted Telegram / paired iOS) has already proven provenance via the
        // allowlist/pairing — the same trust root that lets the local Mac surface run
        // high-risk tools. For such origins the signed-command requirement is redundant,
        // so waive it and let trusted remote surfaces behave like the Mac (e.g.
        // invoke_claude works in Telegram, not just Mac chat). Gate 1 above still
        // hard-blocks any UNTRUSTED remote origin, so this never elevates a stranger.
        // the user can restore strict signing by setting trustedRemoteHighRiskAllowed=false.
        let trustedRemoteWaiver = originAssessment.trusted
            && Self.bool(security["trustedRemoteHighRiskAllowed"], default: true)
        if decision != .block,
           profile.risk >= .high,
           originAssessment.isRemote,
           !trustedRemoteWaiver,
           Self.bool(security["signedRemoteCommandsRequired"], default: true),
           origin.commandSignatureVerified != true {
            decision = .block
            reasons.append("remote high-risk command is unsigned")
        }

        // the user 2026-06-13 ("yolo IS dev mode — she can do everything on yolo"):
        // an ACTIVE Full Mac (yolo) window satisfies the Developer-Mode
        // requirement for critical actions (the builder tools shell/git/
        // apply_patch/run_tests profile as .critical) — but with hard
        // limits:
        //   1. Remote origins must be authenticated by their canonical surface
        //      owner (Telegram allowlist, paired iOS identity, verified Slack).
        //      A surface label alone never receives Full Mac authority.
        //   2. NOT self-modification. evolution_propose / self_install profile
        //      as .critical (evolution_write / evolution_apply_trigger); a yolo
        //      window does NOT satisfy their Developer-Mode requirement, so the
        //      dev-mode block still fires for them even locally. Self-modification
        //      keeps maximum defense (this block + confirm autonomy + the
        //      human-approved install card). The claude/codex bridge is open to
        //      these as of 2026-06-13, but the install card is the gate: yolo
        //      never rides the self-evolution surface, and self_install only
        //      stages a card the user resolves.
        // The self-evolution / training-promotion developerMode gates in
        // SelfImprovement read the raw policy flag and are likewise untouched.
        let yoloSatisfiesDevMode = Self.fullMacYoloAllowsAutonomy(
            tool: canonicalTool,
            origin: origin,
            originAssessment: originAssessment,
            profile: profile,
            fullMac: fullMac
        )
        if decision != .block,
           profile.risk == .critical,
           Self.bool(security["criticalRequiresDeveloperMode"], default: true),
           !developerMode,
           !yoloSatisfiesDevMode {
            decision = .block
            reasons.append("critical action requires Developer Mode")
        }

        if decision != .block,
           profile.capabilities.contains("outside_app_data_write"),
           !fullMac {
            decision = .block
            reasons.append("outside-app-data write requires Full Mac access")
        }

        if decision != .block,
           profile.capabilities.contains("external_send"),
           !profile.capabilities.contains("notification"),
           !profile.capabilities.contains("approval_stage"),
           Self.bool(connectorPolicy["sendExternalMessagesRequiresApproval"], default: true) {
            decision = Self.maxDecision(decision, .ask)
            reasons.append("external send requires approval")
        }

        if decision != .block,
           !secretKeys.isEmpty,
           Self.bool(security["secretFirewallEnabled"], default: true),
           !profile.capabilities.contains("notification"),
           (profile.capabilities.contains("external_send")
            || profile.capabilities.contains("network_write")
            || profile.capabilities.contains("shell")) {
            decision = .block
            reasons.append("secret firewall blocks unsafe egress")
        }

        if decision != .block,
           !promptInjectionKeys.isEmpty,
           Self.bool(security["promptInjectionShieldEnabled"], default: true),
           (profile.risk >= .high || profile.capabilities.contains("external_send") || !secretKeys.isEmpty) {
            if trustedLocalAgentBridge {
                reasons.append("trusted local agent bridge allows task handoff text")
            } else {
                decision = Self.maxDecision(decision, .ask)
                reasons.append("prompt-injection shield requires operator review")
            }
        }

        if decision != .block,
           !signedToolKnown,
           profile.risk >= .high,
           Self.bool(security["toolSigningRequired"], default: true) {
            decision = .block
            reasons.append("unsigned high-risk tool is blocked")
        }

        if decision == .ask,
           Self.notificationToolNames.contains(canonicalTool),
           Self.bool(security["allowAppNotifications"], default: true),
           secretKeys.isEmpty,
           promptInjectionKeys.isEmpty {
            decision = .allow
            reasons.append("app notification tool is allowed by security policy")
        }

        let now = Self.isoTimestamp(clock())
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
            signedToolKnown: signedToolKnown,
            rollbackRequired: rollbackRequired,
            decision: decision,
            allowed: decision == .allow,
            requiresApproval: decision == .ask,
            reasons: Self.deduped(reasons),
            untrustedInputKeys: Array(Set(promptInjectionKeys)).sorted(),
            redactedInputPreview: redacted,
            auditReceiptsEnabled: auditEnabled
        )
    }

    public func evaluatePolicyDecision(
        tool: String,
        input: [String: JSONValue],
        origin: SecurityOriginContext,
        enforceAutonomy: Bool = true
    ) async -> UnifiedPolicyDecision {
        let policy = await trustCenter.loadTrustPolicy()
        let envelope = await evaluateTool(
            tool: tool,
            input: input,
            origin: origin,
            enforceAutonomy: enforceAutonomy
        )
        return envelope.unifiedPolicyDecision(
            fullMacActive: Self.fullMacActive(policy: policy, now: clock()),
            developerMode: Self.bool(policy["developerMode"], default: false),
            expiresAt: Self.fullMacExpiresAt(policy: policy)
        )
    }

    public func record(_ envelope: SecurityToolEnvelope) async throws {
        guard envelope.auditReceiptsEnabled else { return }
        // M6 (2026-07-09): this ledger appended forever. Rotate through the
        // shared capped-append so the newest 20k receipts survive and the file
        // cannot grow without bound.
        try await appendJSONLCapped(
            envelope.toJSONValue(),
            to: auditReceiptsPath,
            using: persistence,
            maxLines: JSONLLineCaps.securityAudit,
            logLabel: "SecurityCenter.audit",
            trimWhenBytesExceed: JSONLLineCaps.securityAuditTrimTriggerBytes
        )
    }

    private var auditReceiptsPath: URL {
        dataRoot
            .appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
    }

    private func resolveAutonomyLevel(
        tool: String,
        policy: [String: JSONValue],
        userOverrides: [String: JSONValue],
        origin: SecurityOriginContext,
        originAssessment: OriginAssessment,
        profile: ToolProfile,
        fullMac: Bool
    ) -> String {
        // 2026-07-21 audit fix: an explicit USER-SET "blocked" entry
        // outranks the yolo posture (mirror of the SwiftNativeTrustCenter
        // resolver fix — confirm/send_approval stay flattened by yolo;
        // consult the raw user file so merged code defaults can't
        // masquerade as explicit entries).
        if !SwiftNativeTrustCenter.hasExplicitBlockOverride(tool, overrides: userOverrides),
           Self.fullMacYoloAllowsAutonomy(
            tool: tool,
            origin: origin,
            originAssessment: originAssessment,
            profile: profile,
            fullMac: fullMac
        ) {
            return "auto"
        }
        let overrides = Self.object(policy["toolAutonomy"])
        let defaultLevel = overrides["default"] ?? .string("send_approval")
        return trustCenter.autonomyForTool(
            tool,
            policy: [
                "autonomyOverrides": .object(overrides),
                "autonomyDefault": defaultLevel,
            ]
        )
    }

    private func assessOrigin(_ origin: SecurityOriginContext) async -> OriginAssessment {
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
            let chatId = origin.chatId
                ?? Self.telegramChatId(fromSessionId: origin.sessionId)
            let allowed = await telegramSecurityAllowlist()
            if let reason = allowed.matches(chatId: chatId, userId: origin.userId) {
                return OriginAssessment(trusted: true, reason: reason, isRemote: true)
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
            let chatId = origin.chatId
            let allowed = await slackSecurityAllowlist()
            if let reason = allowed.matches(chatId: chatId, userId: origin.userId) {
                return OriginAssessment(trusted: true, reason: reason, isRemote: true)
            }
            if allowed.isEmpty {
                return OriginAssessment(trusted: false, reason: "slack allowlist not configured for security proof", isRemote: true)
            }
            return OriginAssessment(trusted: false, reason: "slack origin is not in allowlist", isRemote: true)
        }
        if surfaceProfile.isIOSRemote {
            let policy = await trustCenter.loadTrustPolicy()
            let iosRemote = Self.object(policy["iosRemotePolicy"])
            // 2026-07-21 audit fix: decoupled the mac_control feature flag
            // from the SecurityCenter trust root. The previous
            // (iosRemote || macControl) disjunction meant flipping "remote
            // from iOS" for Mac Control silently made EVERY ios-family origin
            // trusted for ALL high-risk security gates (incl. the
            // signed-remote-command waiver and full-Mac trusted-remote
            // surfaces). The security trust root is the iosRemotePolicy flag
            // alone; the live config was migrated to set it (it previously
            // relied on the macControl disjunct).
            let pairedAllowed = Self.bool(iosRemote["remote_from_ios_allowed"], default: false)
            return OriginAssessment(
                trusted: pairedAllowed,
                reason: pairedAllowed ? "paired iOS remote control enabled" : "iOS remote control not trusted for high-risk actions",
                isRemote: true
            )
        }
        return OriginAssessment(trusted: false, reason: "remote origin has no trust root", isRemote: true)
    }

    private func trustedOriginCount() async -> Int {
        await telegramSecurityAllowlist().count
    }

    private func slackSecurityAllowlist() async -> TelegramSecurityAllowlist {
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
            let raw = await persistence.readJSON(path, defaultValue: .object([:]))
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

    private func telegramSecurityAllowlist() async -> TelegramSecurityAllowlist {
        let path = dataRoot
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json")
        let raw = await persistence.readJSON(path, defaultValue: .object([:]))
        let obj = Self.object(raw)
        return TelegramSecurityAllowlist(
            chatIds: Self.stringSet(obj["allowed_chat_ids"]).union(Self.stringSet(obj["allowedChatIds"])),
            userIds: Self.stringSet(obj["allowed_user_ids"]).union(Self.stringSet(obj["allowedUserIds"]))
        )
    }

    private func isSignedOrBuiltinTool(_ tool: String) async -> Bool {
        if Self.builtinToolPrefixes.contains(where: { tool.hasPrefix($0) })
            || Self.builtinToolNames.contains(tool)
            || Self.notificationToolNames.contains(tool)
            || Self.catalogToolNames.contains(tool) {
            return true
        }
        let registryPath = dataRoot
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("registry.json")
        let raw = await persistence.readJSON(registryPath, defaultValue: .object([:]))
        return Self.registryContainsSignedTool(raw, tool: tool)
    }
}

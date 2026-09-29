import ChromeControl
import Privacy
import Foundation
import AttentionRouting
import Agents
import ChatOrchestration
import Cognition
import CognitiveSubstrate
import MacIntegration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import ToolRegistry
import TrustCenter
import DeviceSync

/// Core policy and routing for tools backed by the app's platform ports.
/// Descriptors enter the one lazy catalog through the engine; this executor
/// owns neither a second catalog nor independent load state.
public final class AppToolExecutor: ToolExecutor, @unchecked Sendable {
    /// The same Trust gate the wrapper uses, for reads the app makes on her
    /// behalf after a page act (`chromeFollowUpAllowed`).
    public let chrome: @Sendable () -> ChromeControlRuntime
    public let macPersonAway: @Sendable () -> Bool
    public let motorActionObserver: @Sendable (MotorActionReadModel) async -> Void
    public let quietHost: @MainActor @Sendable () -> (any QuietToolHost)?
    public let presentation: any QuietToolPresentationPort
    public let interactions: any ToolInteractionResolving
    public let securityCenter: SwiftNativeSecurityCenter
    public let enforceAutonomySecurity: Bool
    public let browserActionRunner: @Sendable (String, Bool, [String: JSONValue]) async throws -> JSONValue
    private let mobileNotificationSender: @Sendable (String, String, [String: String]) async throws -> MobileNotificationDeliveryReceipt
    private let macNotificationSender: @Sendable (String, String) async throws -> NativeAgentNotificationPostResult
    /// Production uses the shared persisted authority; injected executors
    /// may carry a hermetic real store without replacing the gate itself.
    private let macIntegrationPermissionStore: MacIntegrationPermissionStore
    private let doctorStatusProvider: @Sendable () async throws -> JSONValue
    private let telegramStatusProvider: @Sendable () async throws -> JSONValue
    private let reflexReviewHandler: @Sendable (
        String,
        OrganismReflexReviewDecision,
        String?,
        String
    ) async -> OrganismReflexReviewApplyOutcome
    private let humanConversationReplyHandler: @Sendable ([String: JSONValue]) async throws -> JSONValue

    public static func defaultReflexReviewerIdentity(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String {
        PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
    }

    public init(
        securityCenter: SwiftNativeSecurityCenter,
        enforceAutonomySecurity: Bool,
        browserActionRunner: @escaping @Sendable (String, Bool, [String: JSONValue]) async throws -> JSONValue,
        chrome: @escaping @Sendable () -> ChromeControlRuntime,
        pageIDs: [String], drawOnlyPageIDs: [String],
        macPersonAway: @escaping @Sendable () -> Bool,
        motorActionObserver: @escaping @Sendable (MotorActionReadModel) async -> Void,
        mobileNotificationSender: @escaping @Sendable (String, String, [String: String]) async throws -> MobileNotificationDeliveryReceipt,
        macNotificationSender: @escaping @Sendable (String, String) async throws -> NativeAgentNotificationPostResult,
        macIntegrationPermissionStore: MacIntegrationPermissionStore,
        doctorStatusProvider: @escaping @Sendable () async throws -> JSONValue,
        telegramStatusProvider: @escaping @Sendable () async throws -> JSONValue,
        reflexReviewHandler: @escaping @Sendable (String, OrganismReflexReviewDecision, String?, String) async -> OrganismReflexReviewApplyOutcome,
        humanConversationReplyHandler: @escaping @Sendable ([String: JSONValue]) async throws -> JSONValue,
        quietHost: @escaping @MainActor @Sendable () -> (any QuietToolHost)?,
        presentation: any QuietToolPresentationPort,
        interactions: any ToolInteractionResolving
    ) {
        self.securityCenter = securityCenter
        self.enforceAutonomySecurity = enforceAutonomySecurity
        self.browserActionRunner = browserActionRunner
        self.descriptors = AppToolExecutor.appToolSchemas(pageIDs: pageIDs, drawOnlyPageIDs: drawOnlyPageIDs).compactMap { schema in
            AppToolExecutor.buckets[schema.name].map { ToolDescriptor(schema: schema, bucket: $0) }
        }.sorted { $0.name < $1.name }

        self.chrome = chrome
        self.macPersonAway = macPersonAway
        self.motorActionObserver = motorActionObserver
        self.mobileNotificationSender = mobileNotificationSender
        self.macNotificationSender = macNotificationSender
        self.macIntegrationPermissionStore = macIntegrationPermissionStore
        self.doctorStatusProvider = doctorStatusProvider
        self.telegramStatusProvider = telegramStatusProvider
        self.reflexReviewHandler = reflexReviewHandler
        self.humanConversationReplyHandler = humanConversationReplyHandler
        self.quietHost = quietHost
        self.presentation = presentation
        self.interactions = interactions
    }

    /// Core's notification tools, run here with Core's schemas.
    public static let notificationToolNames = ["mac_notify", "mobile_notify"]
    public static let browserToolNames = [
        "browser.chrome_setup",
        "browser.chrome_status",
        "browser.status",
        "browser.open_url",
        "browser.read_text",
        "browser.read_links",
        "browser.screenshot",
        "browser.chrome_acquire",
        "browser.chrome_renew",
        "browser.chrome_navigate",
        "browser.chrome_snapshot",
        "browser.chrome_click",
        "browser.chrome_fill",
        "browser.chrome_type",
        "browser.chrome_select",
        "browser.chrome_keypress",
        "browser.chrome_set_checked",
        "browser.chrome_double_click",
        "browser.chrome_drag",
        "browser.chrome_wait",
        "browser.chrome_scroll",
        "browser.chrome_release",
    ]
    public static let healthToolNames = ["doctor_status", "telegram_status"]
    public static let organismToolNames = ["reflex_review"]
    /// Quiet self-administration (0.4.14). Lazy like every other app tool.
    public static let selfAdminToolNames = [
        "app_page_read", "app_page_screenshot", "app_settings_list",
        "app_setting_set", "interaction_act", "chat_reply",
    ]

    /// name → bucket, in family order. Every name is canonical
    /// (ToolNameAliases) and model-visible.
    private static let buckets: [String: ChatToolCatalogBucket] = Dictionary(uniqueKeysWithValues:
        browserToolNames.map { ($0, .browser) }
        + healthToolNames.map { ($0, .system) } + organismToolNames.map { ($0, .core) }
        + selfAdminToolNames.map { ($0, .core) })

    /// Built once: the schemas are constant, and Core reads this on every call.
    /// Name order, as the app's own loader always listed them.
    public let descriptors: [ToolDescriptor]

    public var replacesCoreTools: Set<String> { Set(Self.notificationToolNames) }

    /// Trust decides first, as the full catalog's available_now does: a
    /// blocked app tool is neither ranked nor loaded by a search.
    public func blockedHere(_ tool: String, surface: String) async -> Bool {
        await securityCenter.evaluateTool(
            tool: tool, input: [:],
            origin: AppChatToolDispatcher.securityOrigin(input: [:], surface: surface),
            enforceAutonomy: enforceAutonomySecurity
        ).decision == .block
    }

    public var families: [ToolFamily] {
        [
            ToolFamily(group: "notifications",
                       aliases: ["notification", "notify", "mobile", "ios", "iphone", "apns", "push", "push_notifications"],
                       tools: Set(Self.notificationToolNames)),
            ToolFamily(group: "browser", aliases: ["browsing", "visible_browser", "visible-browser", "web", "webpage", "page"],
                       tools: Set(Self.browserToolNames)),
            // Research is the browser plus web search (SearXNG), not Chrome alone.
            ToolFamily(group: "research", aliases: ["web_search", "search", "news"],
                       tools: Set(Self.browserToolNames).union(ToolPreloadHeuristics.webSearchTools)),
            ToolFamily(group: "health", aliases: ["diagnostics", "system_health", "runtime_health"],
                       tools: Set(Self.healthToolNames)),
            ToolFamily(group: "organism", aliases: ["reflex", "reflexes", "reflex_review"],
                       tools: Set(Self.organismToolNames)),
            ToolFamily(group: "app", aliases: ["app_self", "self_admin", "own_app", "app_pages", "settings"],
                       tools: Set(Self.selfAdminToolNames)),
        ]
    }

    public func execute(
        tool: String, input: [String: JSONValue], surface: String, host: any ToolLoading
    ) async throws -> JSONValue {
        switch tool {
        // B5 (tightness-sweep 2026-07-17) — SINGLE OWNER of notify on app
        // bodies. Core's SwiftToolDispatcher also has `mac_notify` /
        // `mobile_notify` cases, and BOTH ultimately reach the identical
        // backends: `NativeAgentNotifications.postAndReport` (Mac) and
        // `NativeAgentEngine.liveDeviceSync.engine.sendNotificationToPairedDevices` (iOS) — this
        // executor via its injected senders, core via the injected
        // `MacIntegrationBridgeImpl`. There is no second device registry.
        //
        // On a body that carries this executor Core routes these two names
        // here (`replacesCoreTools`), so its own cases never run; they are
        // retained for bodies with a bridge but no app executor. Do NOT add
        // notify logic to only one side — keep the backends and the
        // permission gate in sync across both.
        case "mobile_notify":
            // gpt-5.5 review BLOCKING: this path bypasses the Core dispatcher's
            // MacIntegration gate. Check the gate here so the user's "iPhone
            // Notifications" Write toggle actually denies the call.
            let admission = await securityCenter.fullMacYoloAuthority(
                tool: tool, origin: AppChatToolDispatcher.securityOrigin(input: input, surface: surface))
            let allowed = await macIntegrationPermissionStore.allows(MacIntegrationID.notifyMobile, mode: .write, fullMacAdmitted: admission.admitted)
            guard allowed else {
                return Self.macIntegrationDeniedEnvelope(integration: MacIntegrationID.notifyMobile, mode: "write")
            }
            return try await runMobileNotify(input: input, surface: surface)
        case "mac_notify":
            let admission = await securityCenter.fullMacYoloAuthority(
                tool: tool, origin: AppChatToolDispatcher.securityOrigin(input: input, surface: surface))
            let allowed = await macIntegrationPermissionStore.allows(MacIntegrationID.notifyMac, mode: .write, fullMacAdmitted: admission.admitted)
            guard allowed else {
                return Self.macIntegrationDeniedEnvelope(integration: MacIntegrationID.notifyMac, mode: "write")
            }
            return try await runMacNotify(input: input, surface: surface)
        case _ where Self.browserToolNames.contains(tool):
            return try await runBrowserTool(actionId: tool, input: input, surface: surface, host: host)
        case "doctor_status", "telegram_status":
            return try await runHealthStatusTool(tool: tool, surface: surface)
        case "reflex_review":
            return await runReflexReview(input: input, surface: surface)
        case "chat_reply":
            return try await humanConversationReplyHandler(input)
        case _ where Self.quietSelfAdminToolNames.contains(tool):
            return await runQuietSelfAdminTool(tool: tool, input: input, surface: surface)
        default:
            return .object([
                "status": .string("failed"), "reason": .string("not_in_dispatch_table"), "tool": .string(tool),
            ])
        }
    }

    public static func defaultMobileNotificationSender(
        title: String, body: String, userInfo: [String: String], router: AttentionRouter
    ) async throws -> MobileNotificationDeliveryReceipt {
            // Item 26: one exit, through the router. Owner-waiting (an
            // explicitly invoked notify IS Agent reaching for User), but PINNED
            // to the phone: this tool's name is its contract, and a real APNS
            // receipt is what the caller gets back. Payload unchanged.
            let outcome = try await router.route(
                eventId: userInfo["itemId"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? "mobile_notify:\(AttentionRouter.stableDigest(title + "|" + body))",
                importance: .ownerWaiting,
                title: title,
                body: body,
                userInfo: userInfo,
                pinnedTo: .phone
            )
            return try outcome.requireReceipt()
    }

    // MARK: - Notifications

    private func runMacNotify(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let (title, message) = try NativeAgentNotificationDefaults.parseInput(input, toolName: "mac.notify")
        let result = try await macNotificationSender(title, message)
        var obj = result.deliveryFields()
        obj.merge([
            "tool": .string("mac.notify"),
            "surface": .string(surface),
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "messagePreview": .string(NativeAppSecretRedactor.redactText(String(message.prefix(200)))),
        ]) { _, new in new }
        return .object(obj)
    }

    private func runMobileNotify(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let input = input.filter { $0.value != .string("") }
        let (title, message) = try NativeAgentNotificationDefaults.parseInput(input, toolName: "mobile.notify")
        let screen = Self.inputString(input["screen"]) ?? "inbox"
        let source = Self.inputString(input["source"]) ?? "chat_tool"
        let urgency = Self.inputString(input["urgency"]) ?? "normal"
        var userInfo = [
            "screen": screen,
            "source": source,
            "urgency": urgency,
            "surface": surface,
        ]
        if screen == "chat",
           let sessionId = ChatToolSessionContext.verifiedSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sessionId.isEmpty {
            userInfo["sessionId"] = sessionId
        }
        let receipt = try await mobileNotificationSender(title, message, userInfo)
        var obj = receipt.deliveryFields()
        obj.merge([
            "tool": .string("mobile.notify"),
            "surface": .string(surface),
            "screen": .string(screen),
            "source": .string(source),
            "urgency": .string(urgency),
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "messagePreview": .string(NativeAppSecretRedactor.redactText(String(message.prefix(200)))),
        ]) { _, new in new }
        return .object(obj)
    }

    /// Same envelope shape the Core dispatcher's MacIntegration permission
    /// gate produces — keeps the surface uniform regardless of which path
    /// caught the call.
    private static func macIntegrationDeniedEnvelope(integration: String, mode: String) -> JSONValue {
        // Same change the Core gate got: a permission the person has not
        // granted is a NEED, asked where the work is, not a refusal relayed as
        // prose with a settings path in it. Both paths raise the identical
        // envelope, so a call caught here produces the same card as one caught
        // in Core — which is the only reason this mirror exists.
        if let need = InlineInteractionRegistry.permission(
            [integration],
            why: "I need permission for \(InlineInteractionRegistry.macCapabilityDisplayName(integration)) to do this."
        ) {
            return InlineInteractionNeed.envelope(need)
        }
        return .object([
            "status": .string("denied"),
            "reason": .string("integration_permission_denied"),
            "integration": .string(integration),
            "mode": .string(mode),
            "fix": .string("Toggle \(mode.capitalized) ON for \(integration) in Settings → Mac Integration."),
        ])
    }

    // MARK: - Health

    private func runHealthStatusTool(tool: String, surface: String) async throws -> JSONValue {
        let result = tool == "doctor_status" ? try await doctorStatusProvider() : try await telegramStatusProvider()
        guard case .object(var object) = result else { return result }
        object["tool"] = .string(tool)
        object["runtime"] = .string("swift-native")
        object["surface"] = .string(surface)
        object["read_only"] = .bool(true)
        return .object(object)
    }

    // MARK: - Organism

    private func runReflexReview(input: [String: JSONValue], surface: String) async -> JSONValue {
        let input = input.filter { $0.value != .null && $0.value != .string("") }
        let candidateID = Self.inputString(input["candidate_id"] ?? input["candidateId"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !candidateID.isEmpty else {
            return Self.reflexReviewError(
                status: "invalid_input",
                candidateID: nil,
                decision: nil,
                message: "reflex_review requires candidate_id"
            )
        }
        let rawDecision = Self.inputString(input["decision"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard let decision = OrganismReflexReviewDecision(rawValue: rawDecision),
              decision == .approve || decision == .hold || decision == .reject
        else {
            return Self.reflexReviewError(
                status: "invalid_input",
                candidateID: candidateID,
                decision: rawDecision.isEmpty ? nil : rawDecision,
                message: "decision must be approve, hold, or reject"
            )
        }
        let note = Self.inputString(input["note"])
        let outcome = await reflexReviewHandler(candidateID, decision, note, surface)
        guard outcome.applied,
              let receipt = outcome.receipt,
              let candidate = outcome.candidate
        else {
            return Self.reflexReviewError(
                status: outcome.status.rawValue,
                candidateID: candidateID,
                decision: decision.rawValue,
                message: outcome.error ?? "The reflex review was not applied."
            )
        }
        return .object([
            "status": .string("reviewed"),
            "applied": .bool(true),
            "runtime": .string("swift-native"),
            "candidate_id": .string(candidate.id),
            "decision": .string(decision.rawValue),
            "candidate": Self.reflexCandidateJSON(candidate),
            "receipt": Self.reflexReviewReceiptJSON(receipt),
        ])
    }

    private static func reflexReviewError(
        status: String,
        candidateID: String?,
        decision: String?,
        message: String
    ) -> JSONValue {
        .object([
            "status": .string("error"),
            "applied": .bool(false),
            "runtime": .string("swift-native"),
            "error": .string(status),
            "candidate_id": candidateID.map { .string($0) } ?? .null,
            "decision": decision.map { .string($0) } ?? .null,
            "message": .string(message),
        ])
    }

    private static func reflexCandidateJSON(_ candidate: OrganismReflexCandidate) -> JSONValue {
        let iso = ISO8601DateFormatter()
        return .object([
            "id": .string(candidate.id),
            "pattern": .string(candidate.pattern),
            "trust_class": .string(candidate.trustClass.rawValue),
            "evidence_count": .int(Int64(candidate.evidenceCount)),
            "success_count": .int(Int64(candidate.successCount)),
            "failure_count": .int(Int64(candidate.failureCount)),
            "confidence": .double(candidate.confidence),
            "review_required": .bool(candidate.reviewRequired),
            "auto_activation_allowed": .bool(candidate.autoActivationAllowed),
            "permanently_deliberate": .bool(candidate.isPermanentlyDeliberate),
            "approved_at": candidate.approvedAt.map { .string(iso.string(from: $0)) } ?? .null,
            "rejected_at": candidate.rejectedAt.map { .string(iso.string(from: $0)) } ?? .null,
        ])
    }

    private static func reflexReviewReceiptJSON(_ receipt: OrganismReflexReviewReceipt) -> JSONValue {
        let iso = ISO8601DateFormatter()
        return .object([
            "id": .string(receipt.id),
            "candidate_id": .string(receipt.candidateID),
            "pattern": .string(receipt.pattern),
            "trust_class": .string(receipt.trustClass.rawValue),
            "decision": .string(receipt.decision.rawValue),
            "reviewed_at": .string(iso.string(from: receipt.reviewedAt)),
            "reviewed_by": .string(receipt.reviewedBy),
            "source": .string(receipt.source),
            "note": receipt.note.map { .string($0) } ?? .null,
            "evidence_count": .int(Int64(receipt.evidenceCount)),
            "success_count": .int(Int64(receipt.successCount)),
            "failure_count": .int(Int64(receipt.failureCount)),
            "confidence": .double(receipt.confidence),
            "auto_activation_allowed": .bool(receipt.autoActivationAllowed),
            "permanently_deliberate": .bool(receipt.permanentlyDeliberate),
        ])
    }

    public static func inputString(_ raw: JSONValue?) -> String? {
        switch raw {
        case .string(let s):
            return s
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        default:
            return nil
        }
    }

    public static func extractSessionId(_ input: [String: JSONValue]) -> String {
        for key in ["__session_id", "session_id", "sessionId"] {
            if let raw = AppToolExecutor.inputString(input[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return raw
            }
        }
        return ""
    }
}

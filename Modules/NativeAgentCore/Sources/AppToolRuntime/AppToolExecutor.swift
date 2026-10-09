import ChromeControl
import Privacy
import Foundation
import AttentionRouting
import Agents
import ChatOrchestration
import Cognition
import CognitiveSubstrate
import MacIntegration
import MemoryV2
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
    private let doctorStatusProvider: @Sendable (_ repair: Bool?) async throws -> JSONValue
    private let telegramStatusProvider: @Sendable () async throws -> JSONValue
    private let humanConversationReplyHandler: @Sendable ([String: JSONValue]) async throws -> JSONValue
    /// Deny, or under Full Mac approve (true), a Desk task's waiting step:
    /// execution id in, receipt out.
    private let workshopStepDecider: @Sendable (String, Bool) async throws -> JSONValue

    public init(
        securityCenter: SwiftNativeSecurityCenter,
        enforceAutonomySecurity: Bool,
        browserActionRunner: @escaping @Sendable (String, Bool, [String: JSONValue]) async throws -> JSONValue,
        chrome: @escaping @Sendable () -> ChromeControlRuntime,
        macPersonAway: @escaping @Sendable () -> Bool,
        motorActionObserver: @escaping @Sendable (MotorActionReadModel) async -> Void,
        mobileNotificationSender: @escaping @Sendable (String, String, [String: String]) async throws -> MobileNotificationDeliveryReceipt,
        macNotificationSender: @escaping @Sendable (String, String) async throws -> NativeAgentNotificationPostResult,
        macIntegrationPermissionStore: MacIntegrationPermissionStore,
        doctorStatusProvider: @escaping @Sendable (_ repair: Bool?) async throws -> JSONValue,
        telegramStatusProvider: @escaping @Sendable () async throws -> JSONValue,
        humanConversationReplyHandler: @escaping @Sendable ([String: JSONValue]) async throws -> JSONValue,
        workshopStepDecider: @escaping @Sendable (String, Bool) async throws -> JSONValue,
        quietHost: @escaping @MainActor @Sendable () -> (any QuietToolHost)?,
        presentation: any QuietToolPresentationPort,
        interactions: any ToolInteractionResolving
    ) {
        AppActionPolicy.register(Dictionary(AppActions.all.map { ($0.id, $0.policy) },
                                            uniquingKeysWith: { first, _ in first }))
        // Register a closure, not a static table dependency: app's schema
        // already reads AppActions during descriptor assembly below.
        RunawayOutputDetector.registerAppReadOnlyCalls { input in
            guard input["script"] == nil || input["script"] == .null || input["script"] == .string("") else { return false }
            let action = Self.doorText(input["action"])
            if !action.isEmpty {
                let args: [String: JSONValue] = if case .object(let args)? = input["args"] { args } else { [:] }
                return AppActions.action(action)?.readOnly(args: args) == true
            }
            guard !Self.opensHomeItem(input) else { return false }
            return true // home, page/item reads, and find
        }
        self.securityCenter = securityCenter
        self.enforceAutonomySecurity = enforceAutonomySecurity
        self.browserActionRunner = browserActionRunner
        self.descriptors = AppToolExecutor.appToolSchemas().compactMap { schema in
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
        self.humanConversationReplyHandler = humanConversationReplyHandler
        self.workshopStepDecider = workshopStepDecider
        self.quietHost = quietHost
        self.presentation = presentation
        self.interactions = interactions
    }

    /// Core's notification tools, run here with Core's schemas.
    public static let notificationToolNames = ["mac_notify", "mobile_notify"]
    public static let browserToolNames = [
        "browser.chrome_setup",
        "browser.chrome_status",
        "browser.chrome_reload_extension",
        "browser.status",
        "browser.open_url",
        "browser.read_text",
        "browser.read_links",
        "browser.screenshot",
        "browser.chrome_close_tab",
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
        "browser.chrome_media",
    ]
    /// name → bucket, in family order. Every name is canonical
    /// (ToolNameAliases). The app itself is the one `app` door; the browser
    /// tools and `chat_reply` are its actions (browser.*, chrome.*, chat.reply)
    /// and stay here for internal callers and the membranes that name them.
    private static let buckets: [String: ChatToolCatalogBucket] = Dictionary(uniqueKeysWithValues:
        browserToolNames.map { ($0, .browser) } + [("chat_reply", .core)] + doorToolNames.map { ($0, .alwaysOn) })

    /// Built once: the schemas are constant, and Core reads this on every call.
    /// Name order, as the app's own loader always listed them.
    public let descriptors: [ToolDescriptor]

    public var replacesCoreTools: Set<String> { Set(Self.notificationToolNames) }

    public func execute(
        tool: String, input: [String: JSONValue], surface: String
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
            return try await runBrowserTool(actionId: tool, input: input, surface: surface)
        case "chat_reply":
            return try await humanConversationReplyHandler(input)
        case "app":
            return try await runAppDoor(input: input, surface: surface)
        default:
            return .object([
                "status": .string("failed"), "effects": .string("none"), "reason": .string("not_in_dispatch_table"), "tool": .string(tool),
                "detail": .string("\(tool) has no handler in this build, so nothing ran. app {find} shows what is available."),
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
            "messagePreview": .string(String(NativeAppSecretRedactor.redactText(message).prefix(200))),
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
            "messagePreview": .string(String(NativeAppSecretRedactor.redactText(message).prefix(200))),
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

    /// Doctor's checks or Telegram's status, read and changing nothing: the
    /// `app` door's diagnostics/doctor and telegram/status item reads.
    func healthRead(_ item: String) async throws -> JSONValue {
        item == "doctor" ? try await doctorStatusProvider(nil) : try await telegramStatusProvider()
    }

    private static func healthResult(_ result: JSONValue, surface: String) -> JSONValue {
        guard case .object(var object) = result else { return result }
        object["runtime"] = .string("swift-native")
        object["surface"] = .string(surface)
        return .object(object)
    }

    // MARK: - Actions

    /// One `app` action, in process. `input` is the entry's verb and the
    /// arguments under the names the host's call takes; `action.tool` names
    /// the code it runs (and the Trust key a saved level binds by). Safe
    /// refuses it unless the entry runs in Safe; the host's own call does the rest.
    @MainActor
    func runFolded(_ action: AppAction, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // A folded tool runs as itself: the chain is re-entered under its own
        // name, so its gates, Trust key and cards judge it, and what comes
        // back is its own result. A card it files replays that call, not this one.
        if action.isFold {
            guard let perform = AppDoorReentry.perform else {
                return Self.doorRefusal("door_unavailable",
                    "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing ran.",
                    remedy: "none", "Use app from a chat turn.")
            }
            let call = ChatToolSessionInjection.apply(toolName: action.tool, input: input,
                                                      sessionId: Self.inputString(input["__session_id"]))
            do { return try await perform(action.tool, call) }
            catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
        }
        // A setting and a card hold the posture gate themselves, and say it in
        // their own words (a setting's requested and current values; a card's
        // origin and Full Mac checks).
        if action.tool == "app_setting_set" { return await runAppSettingSet(input: input, surface: surface) }
        if action.isCard { return await runCardAction(input: input, surface: surface) }
        if !action.safe, !action.readOnly(args: input), let refusal = await Self.quietChangesRefusal() { return refusal }
        let verb = Self.inputString(action.input["verb"]) ?? ""
        switch action.tool {
        case "read_file" where action.id == "chrome.history":
            return try await runChromeHistory(input: input, surface: surface)
        case "claude_worklog":
            return AgentConversationView.claudeWorklog(input: input)
        case "photos_read":
            return await runPhotosRead(verb: verb, input: input)
        case "weather_forecast":
            return try await runWeatherForecast(input: input)
        case "sense_act":
            return await runSenseAct(input: input)
        case "sense_make":
            return await runSenseMake(input: input)
        case "app_page_screenshot":
            return await presentation.pageScreenshot(input: input)
        case "make_studio":
            return await runMake(verb: verb, input: input)
        case "doctor_status":
            return Self.healthResult(try await doctorStatusProvider(input["repair"] == .bool(true)), surface: surface)
        case "my_queue":
            return await runMyQueue(verb: verb, input: input, surface: surface)
        case "workshop_reject":
            let id = Self.inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else {
                return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("invalid_input"),
                    "detail": .string("Pass id: the execution id of a Desk task whose status is blocked_on_approval in app workshop.status.")])
            }
            // desk.approve: User's, so only Full Mac reaches it (the door).
            let approve = input["decision"] == .string("approve")
            let result: JSONValue
            do { result = try await workshopStepDecider(id, approve) }
            catch {
                return .object(["status": .string("failed"), "reason": .string("workshop_\(approve ? "approve" : "reject")_failed"),
                    "id": .string(id), "detail": .string(error.localizedDescription + " Nothing was \(approve ? "approved" : "denied"); "
                        + "app workshop.status shows the task's current state.")])
            }
            if approve, case .object(let fields) = result, fields["status"] == .string("approved") {
                HarnessDecidedRow.post(requester: "Full Mac", tool: "desk.approve \(id)",
                                       sessionID: Self.inputString(input["__session_id"]),
                                       dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            }
            return result
        case "list_memories", "rewrite_memory":
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let curation = MemoryCuration(memoryV2: SwiftNativeMemoryV2.resolvedOwner(dataRoot: root), dataRoot: root)
            return action.tool == "list_memories"
                ? try await curation.listMemories(input: input, surface: surface,
                    persona: memoryRecallPersonaFilter(ChatTurnRuntimeContext.current?.personaID))
                : try await curation.rewriteMemory(input: input, surface: surface,
                    persona: memoryRecallPersonaFilter(ChatTurnRuntimeContext.current?.personaID))
        default:
            break
        }
        guard let host = quietHost() else { return Self.unattachedFailure() }
        switch action.tool {
        case "inbox":
            return await host.inbox(verb: verb, input: input)
        case "provider", "connections":
            let answer = action.tool == "provider"
                ? await host.provider(verb: verb, input: input) : await host.connections(verb: verb, input: input)
            guard case .object(var body) = answer else {
                return Self.failure("\(action.tool)_failed", "The app gave no answer for that verb.")
            }
            body["verb"] = .string(verb)
            if action.tool == "connections" { body["decided_by"] = .string("agent") }
            return .object(body)
        case "upkeep", "mind_run", "skill_manage":
            let outcome = switch action.tool {
            case "upkeep": await host.runUpkeep(verb: verb, input: input)
            case "mind_run": await host.runMind(verb: verb, input: input)
            default:
                await host.manageSkill(verb: verb, input: input, steer: Self.skillSteer(surface: surface))
            }
            var body = outcome.fields
            body["status"] = .string(outcome.ok ? "ok" : "failed")
            body["verb"] = .string(verb)
            body["detail"] = .string(outcome.detail)
            return .object(body)
        case "chat_session":
            return await runChatSessionAction(verb: verb, input: input, surface: surface, host: host)
        case "chat_conversations":
            // A read: the sidebar's rows, as chat.list and the chat page show them.
            return await host.runChatSession(verb: "list", input: input, reachesUser: false)
        case "interaction_act" where action.input["target"] == .string("composer"):
            return await runComposerAction(verb: verb, input: input, surface: surface, host: host)
        default:
            return Self.failure("not_folded", "\(action.id) is not run in process.", extra: ["tool": .string(action.tool)])
        }
    }

    /// The peers steering this turn, as `skill_manage` weighs them.
    static func skillSteer(surface: String) -> [String] {
        let steer = PeerDataTaint.carried(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: ChatToolSessionContext.envelope?.verifiedUserId)
        return steer.sources + steer.elevated
    }

    /// What would refuse an action now, asked without running it, for
    /// the door's preview: the checks its real run makes first, through the
    /// same functions (a card's `cardRefusal`, a setting's `settingRefusal`,
    /// Safe, the composer's `composerRefusal`, the app's inbox and chat
    /// fences). Nil when nothing would.
    @MainActor
    func foldedRefusal(_ action: AppAction, input: [String: JSONValue], surface: String) async -> JSONValue? {
        if action.tool == "request_interaction" {
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            if case .object(var refusal) = await SwiftToolDispatcher.requestedInteraction(input: input, dataRoot: root),
               refusal["status"] == .string("failed") {
                if case .string(let path)? = refusal["argument_path"] {
                    refusal["argument_path"] = .string("args" + path.dropFirst())
                }
                return .object(refusal)
            }
        }
        if action.isFold { return await AppDoorReentry.validate?(action.tool, input) }
        if action.isCard { return await cardRefusal(input: input, surface: surface) }
        if action.tool == "app_setting_set" { return await settingRefusal(input: input) }
        if !action.safe, let refusal = await Self.quietChangesRefusal() { return refusal }
        if action.tool == "rewrite_memory" {
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            do {
                _ = try await MemoryCuration(memoryV2: SwiftNativeMemoryV2.resolvedOwner(dataRoot: root), dataRoot: root)
                    .rewriteTarget(input: input, surface: surface,
                        persona: memoryRecallPersonaFilter(ChatTurnRuntimeContext.current?.personaID))
            } catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
        }
        if action.tool == "mind_run", let verb = Self.inputString(action.input["verb"]),
           ["reject", "undo", "revise"].contains(verb),
           case .failure(let refusal) = StudioCanonSeatGate.liveTurnProvenance() {
            return Self.failure(refusal.rawValue,
                "mind.\(verb): \(refusal.spoken). It is done from inside your own conversation, in your own turn.")
        }
        if action.tool == "upkeep" {
            guard let host = quietHost() else { return Self.unattachedFailure() }
            return await host.upkeepFence(verb: Self.inputString(action.input["verb"]) ?? "", input: input)
        }
        // Turning a skill or tool on, back or back a version: whose it is turns
        // on the script's origin, the steer and Trust. The real call's own
        // checks, run as a preview, say whose it is and what it would leave
        // (status `would`, for the door to say).
        if ["skill.enable", "skill.restore", "skill.rollback", "tool.restore", "tool.rollback", "tool.approve"].contains(action.id) {
            guard let host = quietHost() else { return Self.unattachedFailure() }
            let asked = await host.manageSkill(verb: Self.inputString(action.input["verb"]) ?? "",
                                               input: input.merging(["preview": .bool(true)]) { $1 },
                                               steer: Self.skillSteer(surface: surface))
            let would = asked.fields.filter { $0.key.hasPrefix("would_") || ["versions", "tools"].contains($0.key) }
            guard !asked.ok else {
                return .object(would.merging(["status": .string("would"), "detail": .string(asked.detail)]) { $1 })
            }
            return Self.failure(Self.inputString(asked.fields["reason"]) ?? "refused", asked.detail,
                                extra: would.merging(["would_card": .bool(asked.fields["needs_user"] == .bool(true))]) { $1 })
        }
        guard ["inbox", "chat_session", "interaction_act"].contains(action.tool) else { return nil }
        guard let host = quietHost() else { return Self.unattachedFailure() }
        let verb = Self.inputString(action.input["verb"]) ?? ""
        switch action.tool {
        case "inbox": return await host.inboxFence(verb: verb, input: input)
        case "chat_session":
            let root = host.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let fullMac = await Self.freshQuietPosture(dataRoot: root)?.name == Self.fullMacModeName
            let reachesUser = await Self.reachesUser(surface: surface, fullMac: fullMac, dataRoot: root)
            return host.chatSessionFence(verb: verb, input: input, reachesUser: reachesUser)
        default: return await composerRefusal(verb: verb, input: input, surface: surface, host: host)
        }
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

import AuthoredCapabilities
import AgentWorkspace
import ChromeControl
import CryptoKit
import Privacy
import Foundation
import Senses
import AttentionRouting
import Agents
import ChatTurnContracts
import ChatToolRuntime
import AgentConversations
import ChatToolParsing
import Cognition
import CognitiveSubstrate
import MacIntegration
import MacControl
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import PersonaEngine
import ProviderRouting
import StandingBots
import ToolRegistry
import TrustCenter
import DeviceSync
import ChatTurnRuntime
import Transcripts
import TurnTrace
// Blueprint: | `AppToolExecutor.swift` | `AppToolExecutor` class; shared immutable descriptors; `execute`; chat.post routes to the conversation anchor through Reach's existing speech claim/quota; `macPersonAway` callback; a part's home arrival wakes their only through the care crossing, otherwise it waits on the news board and its receipt says so; mobileNotify owns app/bridge notification defaults, verified session binding and previews, while AttentionRouter delivers |

/// Core policy and routing for tools backed by the app's platform ports.
/// Descriptors enter the one lazy catalog through the engine; this executor
/// owns neither a second catalog nor independent load state.
public final class AppToolExecutor: ToolExecutor {
    @TaskLocal static var undoReceipt: JSONValue?
    /// The same Trust gate the wrapper uses, for reads the app makes on her
    /// behalf after a page act (`chromeFollowUpAllowed`).
    public let chrome: @Sendable () -> ChromeControlRuntime
    public let macPersonAway: @Sendable () -> Bool
    public let motorActionObserver: @Sendable (MotorActionReadModel) async -> Void
    public let quietHost: @MainActor @Sendable () -> (any QuietToolHost)?
    public let presentation: any QuietToolPresentationPort
    let actionIndex: SwiftNativeMemoryV2
    public let securityCenter: SwiftNativeSecurityCenter
    public let enforceAutonomySecurity: Bool
    public let browserActionRunner: @Sendable (String, Bool, [String: JSONValue]) async throws -> JSONValue
    private let mobileNotificationSender: @Sendable (String, String, [String: String]) async throws -> MobileNotificationDeliveryReceipt
    private let macNotificationSender: @Sendable (String, String) async throws -> NativeAgentNotificationPostResult
    /// Production uses the shared persisted authority; injected executors
    /// may carry a hermetic real store without replacing the gate itself.
    private let macIntegrationPermissionStore: MacIntegrationPermissionStore
    private let doctorStatusProvider: @Sendable (_ repair: Bool?, _ checkID: String?) async throws -> JSONValue
    private let telegramStatusProvider: @Sendable () async throws -> JSONValue
    private let humanConversationReplyHandler: @Sendable ([String: JSONValue]) async throws -> JSONValue
    private let proactiveSpeechClient: @Sendable (URL) -> SwiftNativeChatOrchestrationClient
    /// Deny, or under Full Mac approve (true), a Desk task's waiting step:
    /// execution id in, receipt out.
    private let workshopStepDecider: @Sendable (String, Bool) async throws -> JSONValue
    /// The one owner that reaches the person: Telegram where he is, else his phone, held in quiet hours.
    private let attention: @Sendable () -> AttentionRouter

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
        doctorStatusProvider: @escaping @Sendable (_ repair: Bool?, _ checkID: String?) async throws -> JSONValue,
        telegramStatusProvider: @escaping @Sendable () async throws -> JSONValue,
        humanConversationReplyHandler: @escaping @Sendable ([String: JSONValue]) async throws -> JSONValue,
        proactiveSpeechClient: @escaping @Sendable (URL) -> SwiftNativeChatOrchestrationClient,
        workshopStepDecider: @escaping @Sendable (String, Bool) async throws -> JSONValue,
        attention: @escaping @Sendable () -> AttentionRouter,
        quietHost: @escaping @MainActor @Sendable () -> (any QuietToolHost)?,
        presentation: any QuietToolPresentationPort
    ) {
        AppActionBinding.register(Dictionary(uniqueKeysWithValues: AppActions.all.map { ($0.id, $0.binding) }),
                                 tools: Array(SwiftToolDispatcher.nativeToolDescriptors.values) + Self.sharedDescriptors,
                                 authorableToolName: SwiftToolDispatcher.isAuthorableToolName,
                                 partPolicy: { id in AppActions.action(id, dataRoot: securityCenter.dataRoot)?.binding },
                                 policyCatalog: { AppActions.policyCatalog(dataRoot: securityCenter.dataRoot) })
        // Register a closure, not a static table dependency: app's schema
        // already reads AppActions during descriptor assembly below.
        RunawayOutputDetector.registerAppReadOnlyCalls(Self.doorReadOnly)
        self.securityCenter = securityCenter
        self.enforceAutonomySecurity = enforceAutonomySecurity
        self.browserActionRunner = browserActionRunner
        self.chrome = chrome
        self.macPersonAway = macPersonAway
        self.motorActionObserver = motorActionObserver
        self.mobileNotificationSender = mobileNotificationSender
        self.macNotificationSender = macNotificationSender
        self.macIntegrationPermissionStore = macIntegrationPermissionStore
        self.doctorStatusProvider = doctorStatusProvider
        self.telegramStatusProvider = telegramStatusProvider
        self.humanConversationReplyHandler = humanConversationReplyHandler
        self.proactiveSpeechClient = proactiveSpeechClient
        self.workshopStepDecider = workshopStepDecider
        self.attention = attention
        self.quietHost = quietHost
        self.presentation = presentation
        let root = securityCenter.dataRoot
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: root)
        self.actionIndex = memory
        let pages: @Sendable () async -> [String: QuietToolPage] = {
            await MainActor.run {
                Dictionary(([Self.doorInbox] + presentation.pages).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
        }
        AgentWorkspacePorts.rankParts { message, root in
            await AppActions.parts(message, pages: await pages(), dataRoot: root, memory: memory)
        }
        Task {
            let paths = ["agents/peers.json", "config/embeddings.json", "ui/layout.json"]
                .map { root.appendingPathComponent($0) }
                + [defaultPersonaRoot(dataRoot: root).appendingPathComponent("skills/bodies")]
            await memory.installActionIndex(paths: paths,
                notifications: [AbilityStore.didChange, BotRunQueue.didChange, UserDefaults.didChangeNotification]) {
                    // The catalog, never the view of the session whose find asked
                    // for this fill: a turn's own actions are embedded with its ask.
                    try await ChatToolSessionContext.$verifiedSessionId.withValue(nil) {
                        let pages = await pages()
                        let inventory = try await AppActions.inventory(dataRoot: root)
                        return try AppActions.actionTexts(inventory.actions, pages: pages,
                            contacts: AgentPeerStore(dataRoot: root).list().map(\.name),
                            helpers: BotDefinitionStore(dataRoot: root).list().map(\.name))
                    }
                }
        }
    }

    /// Whether an app call only reads: home, page/item reads, find, a read
    /// action, or a list of nothing else.
    static func doorReadOnly(_ input: [String: JSONValue]) -> Bool {
        guard input["script"] == nil || input["script"] == .null || input["script"] == .string("") else { return false }
        if case .array(let entries)? = input["actions"], !entries.isEmpty {
            return entries.allSatisfy { if case .object(let call) = $0 { doorReadOnly(call) } else { false } }
        }
        let action = doorText(input["action"])
        if !action.isEmpty {
            let args: [String: JSONValue] = if case .object(let args)? = input["args"] { args } else { [:] }
            return AppActions.action(action)?.readOnly(args: args) == true
        }
        return !opensHomeItem(input)
    }

    /// Core's notification tools, run here with Core's schemas.
    public static let notificationToolNames = ["mac_notify", "mobile_notify"]
    public static let browserToolNames = appToolSchemas(includeDoor: false)
        .map(\.name).filter { $0.hasPrefix("browser.") }
    /// name → bucket, in family order. Every name is canonical
    /// (ToolNameAliases). The app itself is the one `app` door; the browser
    /// tools and `chat_reply` are its actions (browser.*, chrome.*, chat.reply)
    /// and stay here for internal callers and the membranes that name them.
    package static let buckets: [String: ChatToolCatalogBucket] = Dictionary(uniqueKeysWithValues:
        browserToolNames.map { ($0, .browser) } + [("chat_reply", .core)] + doorToolNames.map { ($0, .alwaysOn) })

    /// Built once: the schemas are constant, and Core reads this on every call.
    /// Name order, as the app's own loader always listed them.
    public var descriptors: [ToolDescriptor] { Self.sharedDescriptors }
    private static let sharedDescriptors = appToolSchemas().compactMap { schema in
        buckets[schema.name].map { ToolDescriptor(schema: schema, bucket: $0) }
    }.sorted { $0.name < $1.name }

    public var replacesCoreTools: Set<String> { Set(Self.notificationToolNames) }

    public func execute(
        tool: String, input: [String: JSONValue], surface: String
    ) async throws -> JSONValue {
        switch tool {
        // App bodies route notifications here; bridge-only bodies use Core with the same backends and permission gates.
        case "mobile_notify":
            // Enforce the iPhone Notifications write gate before sending.
            let admission = await securityCenter.fullMacYoloAuthority(
                origin: AppChatToolDispatcher.securityOrigin(surface: surface))
            let allowed = await macIntegrationPermissionStore.allows(MacIntegrationID.notifyMobile, mode: .write, fullMacAdmitted: admission.admitted)
            guard allowed else {
                return try await SwiftToolDispatcher.macIntegrationDeniedEnvelope(
                    integration: MacIntegrationID.notifyMobile, mode: .write, store: macIntegrationPermissionStore)
            }
            return try await Self.mobileNotify(input: input, surface: surface, toolName: "mobile.notify", sender: mobileNotificationSender)
        case "mac_notify":
            let admission = await securityCenter.fullMacYoloAuthority(
                origin: AppChatToolDispatcher.securityOrigin(surface: surface))
            let allowed = await macIntegrationPermissionStore.allows(MacIntegrationID.notifyMac, mode: .write, fullMacAdmitted: admission.admitted)
            guard allowed else {
                return try await SwiftToolDispatcher.macIntegrationDeniedEnvelope(
                    integration: MacIntegrationID.notifyMac, mode: .write, store: macIntegrationPermissionStore)
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

    public static func mobileNotify(input: [String: JSONValue], surface: String, toolName: String,
        sender: (String, String, [String: String]) async throws -> MobileNotificationDeliveryReceipt
    ) async throws -> JSONValue {
        let input = input.filter { $0.value != .string("") }
        let (title, message) = try NativeAgentNotificationDefaults.parseInput(input, toolName: toolName)
        let screen = input["screen"]?.scalarText ?? "inbox"
        let source = input["source"]?.scalarText ?? "chat_tool"
        let urgency = input["urgency"]?.scalarText ?? "normal"
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
        let receipt = try await sender(title, message, userInfo)
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

    // MARK: - Health

    /// Doctor's checks or Telegram's status, read and changing nothing: the
    /// `app` door's diagnostics/doctor and telegram/status item reads.
    func healthRead(_ item: String) async throws -> JSONValue {
        item == "doctor" ? try await doctorStatusProvider(nil, nil) : try await telegramStatusProvider()
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
        try Task.checkCancellation()
        // A folded tool runs as itself: the chain is re-entered under its own
        // name, so its gates, Trust key and cards judge it, and what comes
        // back is its own result. A card it files replays that call, not this one.
        if action.isFold || action.id == "agent.verify" {
            guard let perform = AppDoorReentry.perform else {
                return Self.doorRefusal("door_unavailable",
                    "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing ran.",
                    remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
            }
            // The contact's own send, dry, under agent_message's own gates.
            if action.id == "agent.verify" {
                return try await AgentContactHealth.repair(input["agent"]?.scalarText ?? "",
                    dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                    workspace: input["workspace"]?.scalarText, perform: perform)
            }
            let call = ChatToolSessionInjection.apply(toolName: action.tool, input: input,
                                                      sessionId: input["__session_id"]?.scalarText)
            do {
                let result = try await perform(action.tool, call)
                if action.partAction, OwnedProgramInvocation.valueCall?.id != action.tool,
                   case .object(let fields) = result, let returned = fields["returned"] {
                    var answer: [String: JSONValue] = if case .object(let answer) = returned { answer } else { ["result": returned] }
                    if fields["status"] == .string("ok") || fields["status"] == .string("refused") && answer["status"] == .string("failed") {
                        // The part supplies its payload; only the runner can attest its effects
                        // and how many times it carried itself.
                        for key in ["effects", "calls", "changed", "runs", "handed_back"] { answer[key] = fields[key] }
                        return .object(answer)
                    }
                }
                return result
            }
            catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
        }
        // A setting and a card hold the posture gate themselves, and say it in
        // their own words (a setting's requested and current values; a card's
        // origin and Full Mac checks).
        if action.id == "setting.set" { return await runAppSettingSet(input: input, surface: surface) }
        if action.id == "setting.get" { return await runAppSettingGet(input: input) }
        if action.isCard { return await runCardAction(input: input, surface: surface) }
        try Task.checkCancellation()
        let verb = action.input["verb"]?.scalarText ?? ""
        switch action.tool {
        case "chat_post":
            let root = securityCenter.dataRoot
            guard let destination = ConversationAnchor.currentSessionId(dataRoot: root) else {
                throw ChatOrchestrationError.underlying("The person has no current conversation. Nothing was posted.")
            }
            guard let turn = TurnTraceContext.turnId else {
                throw ChatOrchestrationError.underlying("chat.post requires a current turn. Nothing was posted.")
            }
            let message = input["message"]?.scalarText ?? ""
            // Telling him is a message in HIS thread: stamped with that thread's own route, never the
            // conversation she is in when she says it (10-29: a post made from an agent conversation
            // carried the agent's envelope into User's chat and reached none of Mac, phone or Telegram).
            let route = try? await HumanConversationReader.read(sessionID: destination, dataRoot: root).route
            let result = try await ChatToolSessionContext.$envelope.withValue(route) {
                try await ChatToolSessionContext.withReplyRoute(route?.replyRoute) {
                    try await proactiveSpeechClient(root).speakProactively(
                        content: message, caller: .reachOut,
                        idempotencyKey: SwiftNativeChatOrchestrationClient.proactiveSpeechIdempotencyKey(scope: "chat.post:" + turn, content: message),
                        sessionId: destination)
                }
            }
            switch result {
            case .posted(let session, let run):
                // And it knocks like any reach for him. His Telegram is this same thread, so the knock goes
                // there whenever the thread has a Telegram door (User 10-29: "it should all go here"), else
                // the router's own choice from where he last spoke.
                let telegram = try? await HumanConversationReader.read(sessionID: session, dataRoot: root, surface: "telegram").route
                let knock = try? await attention().route(
                    eventId: "chat.post:" + run, importance: .ownerWaiting, title: "NativeAgent", body: message,
                    userInfo: ["screen": "chat", "sessionId": session],
                    origin: AttentionOrigin(replyRoute: (telegram ?? route)?.replyRoute, sessionId: session))
                return .object(["status": .string("ok"), "effects": .string("occurred"), "session_id": .string(session), "run_id": .string(run),
                                "knock": .string(knock?.deliveryProjection.rawValue ?? "failed")])
            case .duplicate(let session):
                return .object(["status": .string("ok"), "effects": .string("none"), "session_id": .string(session), "duplicate": .bool(true)])
            case .rateLimited(let seconds):
                return .object(["status": .string("refused"), "effects": .string("none"), "reason": .string("rate_limited"), "seconds_remaining": .int(Int64(seconds))])
            }
        case "mac_apps":
            let name = input["name"]?.scalarText ?? ""
            let every = try await MacAppIndex.shared.apps().filter { name.isEmpty || $0.name.localizedCaseInsensitiveContains(name) }
            let all = input["all"] == .bool(true)
            let apps = all ? every : MacAppIndex.installed(every)
            let twice = MacAppIndex.collisions(apps)
            // Two installed apps with one shown name: each goes by its file name, and says so;
            // when the file names tie as well, by its folder ("NativeAgent (~/Applications)").
            var fileNames: [String: Int] = [:]
            for app in apps where twice.contains(app.name.lowercased()) {
                fileNames[app.url.deletingPathExtension().lastPathComponent.lowercased(), default: 0] += 1
            }
            // One bundle id on two different apps (a beta beside its release): a launch by id is a coin flip, so the row says so.
            var ids: [String: Int] = [:]
            for app in apps { ids[app.bundleID ?? "", default: 0] += 1 }
            let rows: [JSONValue] = apps.map { app in
                guard case .object(var fields) = app.json else { return app.json }
                if ids[app.bundleID ?? "", default: 0] > 1 { fields["bundle_id_shared"] = .bool(true) }
                guard twice.contains(app.name.lowercased()) else { return .object(fields) }
                let file = app.url.deletingPathExtension().lastPathComponent
                let folder = UserDisplayFormatters.tildifyPath(app.url.deletingLastPathComponent().standardizedFileURL.path)
                fields["shown_name"] = fields["name"]
                fields["name"] = .string(fileNames[file.lowercased(), default: 0] > 1 ? "\(file) (\(folder))" : file)
                fields["name_collision"] = .bool(true)
                return .object(fields)
            }
            return .object(["status": .string("ok"), "apps": .array(rows), "count": .int(Int64(apps.count)),
                            "other_copies_and_ios": .int(Int64(every.count - MacAppIndex.installed(every).count)),
                            "source": .string("the Mac's app index (Spotlight): the installed copy of each Mac app, as the Apps screen shows them"
                                + (all ? ", plus every other copy (builds, backups) and iOS build the Mac indexes, tagged by kind and platform" : "; all:true lists other copies and iOS builds too")
                                + "; an app on a volume Spotlight does not index is not listed")])
        case "undo":
            return try await doorUndo(input: input)
        case "read_file" where action.id == "reply.attach":
            return await runReplyAttach(input: input)
        case "read_file" where action.id == "chrome.history":
            return try await runChromeHistory(input: input, surface: surface)
        case "claude_worklog":
            return AgentConversationView.claudeWorklog(input: input)
        case "agent_contacts" where action.id == "agent.recipe":
            return AgentRecipeStore.read(host: input["host"]?.scalarText)
        case "agent_connect" where action.id == "agent.recipe_write":
            return AgentRecipeStore.write(host: input["host"]?.scalarText ?? "", document: input["recipe"] ?? .null,
                                          undoing: Self.undoReceipt)
        case "agent_message" where action.id == "agent.reply":
            return try await AgentConversationSession.answer(part: SkillRunContext.ability, agent: input["agent"]?.scalarText,
                exchange: input["exchange"]?.scalarText, text: input["text"]?.scalarText ?? "", done: input["done"] != .bool(false),
                dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        case "agent_connect" where action.id == "agent.rename": return try AgentPeerStore(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()).rename(input["agent"]?.scalarText ?? "", name: input["name"]?.scalarText ?? "")
        case "app_page_read" where action.id == "layout.read":
            return SurfaceLayoutStore.read(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        case "app_setting_set" where action.id == "layout.write":
            return SurfaceLayoutStore.write(input["layout"] ?? .null, expectedVersion: input["layout_version"]?.scalarText ?? "",
                                            dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(), undoing: Self.undoReceipt)
        case "agent_discovery_dismiss":
            return await AgentDiscoverySession.shared.dismiss(name: input["name"]?.scalarText ?? "",
                dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        case "photos_read":
            return await runPhotosRead(verb: verb, input: input)
        case "sense_act":
            return await runSenseAct(input: input)
        case "sense_make":
            return await runSenseMake(input: input)
        case "sense_lifecycle":
            return try await runSenseLifecycle(input: input)
        case "app_page_screenshot":
            let result = await presentation.pageScreenshot(input: input)
            guard case .object(var fields) = result, fields["remedy"] == nil else { return result }
            let page = Self.doorText(input["page"])
            switch Self.doorText(fields["reason"]) {
            case "unknown_tab":
                fields["remedy"] = Repair.remedy(owner: "page \(page) tabs",
                    nextCall: .object(["tool": .string("app"), "input": .object(["page": .string(page)])]), tap: nil,
                    instruction: "Read this page and choose a key from tabs for args.tab; omit tab only to draw the default tab.")
            case "render_failed":
                fields["remedy"] = Repair.remedy(owner: "page \(page) renderer",
                    nextCall: .object(["tool": .string("app"), "input": .object(["page": .string(page)])]), tap: nil,
                    instruction: "Read this page as text; offscreen rendering failed before a PNG could be saved.")
            default: break
            }
            return .object(fields)
        case "make_studio":
            return await runMake(verb: verb, input: input)
        case "studio_intake_read":
            return await runStudioIntakeRead(input: input, surface: surface)
        case "doctor_status":
            return Self.healthResult(try await doctorStatusProvider(input["repair"] == .bool(true), input["check_id"]?.scalarText), surface: surface)
        case "my_queue":
            return await runMyQueue(verb: verb, input: input, surface: surface)
        case "house_file":
            return await runHouseFile(input: input, surface: surface)
        case "repair_let_go":
            return await runRepairLetGo(input: input)
        case "abilities_restore_state":
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let archive = try AbilityStore(dataRoot: root).restoreState(input["state"] ?? .null,
                expectedDigest: input["expected_digest"]?.scalarText ?? "")
            return .object(["status": .string("ok"), "effects": .string("occurred"),
                "preserved": .string(archive.path), "detail": .string("Recovered ability run state was read back. Damaged bytes were preserved; ability files and authority were unchanged.")])
        case "turn_reconcile", "arrival_accept":
            return await runBackgroundRepair(tool: action.tool, input: input)
        case "resident_wake":
            let line = (input["line"]?.scalarText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let part = SkillRunContext.partID else {
                return Self.doorRefusal("not_a_part", "home.arrive is a part's way to you; this call came from no part's run. Nothing was filed.",
                    remedy: "none", "Say it in this turn instead.")
            }
            guard !line.isEmpty else {
                return Self.doorRefusal("invalid_args", "Pass line: what it should tell you. Nothing was filed.",
                    remedy: "correct_arguments", "Call home.arrive with line.")
            }
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd"
            let day = format.string(from: Date())
            let eventKey = input["event_key"]?.scalarText
            if input["event_key"] != nil, eventKey?.isEmpty != false || (eventKey?.utf8.count ?? 0) > 1024 {
                return Self.failure("invalid_args", "event_key must be a nonempty string of at most 1024 bytes.")
            }
            let identity = Data((eventKey ?? line).utf8)
            let digest = SHA256.hash(data: identity).prefix(8).map { String(format: "%02x", $0) }.joined()
            let id = "part:" + part + ":" + (eventKey == nil ? day : "event") + ":" + digest
            guard !ResidentWake.knows(id, dataRoot: root) else {
                return .object(["status": .string("ok"), "effects": .string("none"), "detail": .string("This arrival is already known on your home.")])
            }
            // A line that touches a care, or that nothing can judge, wakes her; the rest waits for her next turn.
            let taint = PeerDataTaint.current.flatMap { $0.isTainted ? $0.sourceDescription : nil }
            let says = part + ": " + line
            let crossed = await SensesHub.shared.crossing?.cross(line, watch: "part:" + part, reason: "what your parts noticed",
                                                               id: id, says: says, agent: taint) ?? .unweighed
            let notKept: JSONValue = .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("not_kept"),
                                       "detail": .string("The arrival could not be kept, so nothing was filed. Call it again.")])
            let waits: String
            switch crossed {
            case .woke(let care):
                return .object(["status": .string("ok"), "effects": .string("occurred"),
                                "detail": .string("It touches your care about \(care): on your home; it wakes you once.")])
            case .notKept: return notKept
            case .unweighed:
                // No judge, so nothing says it does not matter: it wakes her as any arrival.
                // The part's thread carries the hop rule, so a part cannot keep waking her.
                guard ResidentWake.shared.request(dataRoot: root, reason: "what your parts noticed", items: [
                    .init(id: id, line: says, thread: "part:" + part, agent: taint, home: true)
                ]) else { return notKept }
                return .object(["status": .string("ok"), "effects": .string("occurred"),
                                "detail": .string("On your home; it wakes you once.")])
            case .resting(let care):
                waits = "It touches your care about \(care), but this part already woke you about it and the care has not rested since"
            case .untouched:
                waits = "It touches none of your cares"
            }
            await SenseNewsBoard.shared.keep(SenseNews(senseID: "part:" + part, version: 1, address: "home.arrive",
                                                       summary: line, at: Date(), changeID: id))
            return .object(["status": .string("ok"), "effects": .string("occurred"),
                            "detail": .string(waits + ", so it waits for your next turn without waking you.")])
        case "workshop_reject":
            let id = input["id"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
                                       sessionID: input["__session_id"]?.scalarText,
                                       dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            }
            return result
        case "list_memories", "rewrite_memory":
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let curation = MemoryCuration(memoryV2: SwiftNativeMemoryV2.resolvedOwner(dataRoot: root), dataRoot: root)
            return action.tool == "list_memories"
                ? try await curation.listMemories(input: input, surface: surface,
                    persona: nil)
                : try await curation.rewriteMemory(input: input, surface: surface,
                    persona: nil)
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
                return Self.doorRefusal("handler_result_missing", "\(action.id) returned no structured result; its effects are unknown.",
                    remedy: "inspect", "Read the owning page and reconcile the affected state before another change.",
                    next: ["page": .string(action.page)], extra: ["effects": .string("unknown"), "action": .string(action.id), "verb": .string(verb)])
            }
            body["verb"] = .string(verb)
            if action.tool == "connections" { body["decided_by"] = .string("agent") }
            return .object(body)
        case "upkeep", "mind_run", "ability_manage":
            let outcome = switch action.tool {
            case "upkeep": await host.runUpkeep(verb: verb, input: input)
            case "mind_run": await host.runMind(verb: verb, input: input)
            default:
                await host.managePart(verb: verb, input: input, steer: Self.skillSteer(surface: surface))
            }
            var body = outcome.fields
            body["status"] = outcome.ok ? .string("ok") : body["status"] ?? .string("failed")
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

    /// The peers steering this turn, as `ability_manage` weighs them.
    static func skillSteer(surface: String) -> [String] {
        let steer = PeerDataTaint.carried(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: ChatToolSessionContext.envelope?.verifiedUserId)
        return steer.sources + steer.elevated
    }

    /// What would refuse an action now, asked without running it, for
    /// the door's preview: the checks its real run makes first, through the
    /// same functions (a card's `cardRefusal`, a setting's `settingRefusal`,
    /// the composer's `composerRefusal`, the app's inbox and chat fences).
    /// Nil when nothing would.
    @MainActor
    func foldedRefusal(_ action: AppAction, input: [String: JSONValue], surface: String) async -> JSONValue? {
        if action.tool == "request_interaction" {
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            if case .object(var result) = await SwiftToolDispatcher.requestedInteraction(input: input, dataRoot: root) {
                if result["already_done"] == .bool(true) {
                    result["status"] = .string("would")
                    result["would_card"] = .bool(false)
                    result["detail"] = result["summary"]
                    return .object(result)
                }
                if result["status"] == .string("failed") {
                    if case .string(let path)? = result["argument_path"] {
                        result["argument_path"] = .string("args" + path.dropFirst())
                    }
                    return .object(result)
                }
            }
        }
        if action.isFold { return await AppDoorReentry.validate?(action.tool, input) }
        if action.isCard { return await cardRefusal(input: input, surface: surface) }
        if action.id == "setting.set" { return await settingRefusal(input: input) }
        if action.tool == "rewrite_memory" {
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            do {
                _ = try await MemoryCuration(memoryV2: SwiftNativeMemoryV2.resolvedOwner(dataRoot: root), dataRoot: root)
                    .rewriteTarget(input: input, surface: surface,
                        persona: nil)
            } catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
        }
        if action.tool == "mind_run", let verb = action.input["verb"]?.scalarText,
           ["reject", "undo", "revise"].contains(verb),
           case .failure(let refusal) = StudioCanonSeatGate.liveTurnProvenance() {
            return Self.failure(refusal.rawValue,
                "mind.\(verb): \(refusal.spoken). It is done from inside your own conversation, in your own turn.")
        }
        if action.tool == "upkeep" {
            guard let host = quietHost() else { return Self.unattachedFailure() }
            return await host.upkeepFence(verb: action.input["verb"]?.scalarText ?? "", input: input)
        }
        // Turning an ability on, back or back a version: whose it is turns
        // on the script's origin, the steer and Trust. The real call's own
        // checks, run as a preview, say whose it is and what it would leave
        // (status `would`, for the door to say).
        if let lifecycle = action.lifecycle, lifecycle != .drop, lifecycle != .change {
            if action.tool == "sense_lifecycle" {
                do { return try await runSenseLifecycle(input: input.merging(["preview": .bool(true)]) { $1 }) }
                catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
            }
            guard let host = quietHost() else { return Self.unattachedFailure() }
            let asked = await host.managePart(verb: action.input["verb"]?.scalarText ?? "",
                                               input: input.merging(["preview": .bool(true)]) { $1 },
                                               steer: Self.skillSteer(surface: surface))
            let would = asked.fields.filter { $0.key.hasPrefix("would_") || ["versions", "tools"].contains($0.key) }
            guard !asked.ok else {
                return .object(would.merging(["status": .string("would"), "detail": .string(asked.detail)]) { $1 })
            }
            return Self.failure(asked.fields["reason"]?.scalarText ?? "refused", asked.detail,
                                extra: would.merging(["would_card": .bool(asked.fields["needs_owner"] == .bool(true))]) { $1 })
        }
        guard ["inbox", "chat_session", "interaction_act"].contains(action.tool) else { return nil }
        guard let host = quietHost() else { return Self.unattachedFailure() }
        let verb = action.input["verb"]?.scalarText ?? ""
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

}

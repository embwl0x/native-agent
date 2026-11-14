import AuthoredCapabilities
import Experiences
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
// Blueprint: | `AppToolExecutor.swift` | Platform routing and canonical effect owners; phone sends and chat.post knocks tell one matter |

/// Platform executors share the engine's lazy catalog; independent catalogs or load state would drift.
public final class AppToolExecutor: ChatToolExecuting {
    let actionExecution: AppActionExecution
    /// Supplementary page reads clear the same Trust gate as direct calls.
    public let chrome: @Sendable () -> ChromeControlRuntime
    public let motorActionObserver: @Sendable (MotorActionReadModel) async -> Void
    public let quietHost: @MainActor @Sendable () -> (any QuietToolHost)?
    public let presentation: any QuietToolPresentationPort
    private let bindPresentation: (@MainActor @Sendable (Turn) throws -> AppToolPresentationBinding?)?
    var actionIndex: SwiftNativeMemoryV2 {
        get async { await Self.memoryOwner(dataRoot: securityCenter.dataRoot) }
    }
    public let securityCenter: SwiftNativeSecurityCenter
    public let enforceAutonomySecurity: Bool
    public let browserActionRunner: @Sendable (String, Bool, [String: JSONValue], Turn, AppActionExecution) async throws -> JSONValue
    private let mobileNotificationSender: @Sendable (NativeAgentNotificationDefaults.Note, [String: String], Turn) async throws -> AttentionOutcome
    private let macNotificationSender: @Sendable (NativeAgentNotificationDefaults.Note, Turn, ContinuousClock.Instant?) async throws
        -> NativeAgentNotificationPostResult
    /// Executors share persisted authority; injected stores must retain the same gate.
    private let macIntegrationPermissionStore: MacIntegrationPermissionStore
    private let doctorStatusProvider: @Sendable (_ repair: Bool?, _ checkID: String?, _ turn: Turn) async throws -> JSONValue
    private let telegramStatusProvider: @Sendable () async throws -> JSONValue
    private let humanConversationReplyHandler: @Sendable ([String: JSONValue], Turn) async throws -> JSONValue
    private let proactiveSpeechClient: @Sendable (URL) -> SwiftNativeChatOrchestrationClient
    /// One attention owner selects Telegram or phone and holds delivery in quiet hours.
    private let attention: @Sendable () -> AttentionRouter

    public init(
        securityCenter: SwiftNativeSecurityCenter,
        enforceAutonomySecurity: Bool,
        browserActionRunner: @escaping @Sendable (String, Bool, [String: JSONValue], Turn, AppActionExecution) async throws -> JSONValue,
        chrome: @escaping @Sendable () -> ChromeControlRuntime,
        motorActionObserver: @escaping @Sendable (MotorActionReadModel) async -> Void,
        mobileNotificationSender: @escaping @Sendable (NativeAgentNotificationDefaults.Note, [String: String], Turn) async throws -> AttentionOutcome,
        macNotificationSender: @escaping @Sendable (NativeAgentNotificationDefaults.Note, Turn, ContinuousClock.Instant?) async throws
            -> NativeAgentNotificationPostResult,
        macIntegrationPermissionStore: MacIntegrationPermissionStore,
        doctorStatusProvider: @escaping @Sendable (_ repair: Bool?, _ checkID: String?, _ turn: Turn) async throws -> JSONValue,
        telegramStatusProvider: @escaping @Sendable () async throws -> JSONValue,
        humanConversationReplyHandler: @escaping @Sendable ([String: JSONValue], Turn) async throws -> JSONValue,
        proactiveSpeechClient: @escaping @Sendable (URL) -> SwiftNativeChatOrchestrationClient,
        attention: @escaping @Sendable () -> AttentionRouter,
        quietHost: @escaping @MainActor @Sendable () -> (any QuietToolHost)?,
        presentation: any QuietToolPresentationPort,
        actionExecution: AppActionExecution,
        bindPresentation: (@MainActor @Sendable (Turn) throws -> AppToolPresentationBinding?)? = nil
    ) {
        do {
        AppActionBinding.register(Dictionary(uniqueKeysWithValues: try AppActions.seedActions.map { ($0.id, $0.binding) }),
                                 tools: Array(SwiftToolDispatcher.nativeToolDescriptors.values) + Self.sharedDescriptors,
                                 authorableToolName: SwiftToolDispatcher.isAuthorableToolName,
                                 partPolicy: { id, turn in try AppActions.action(id, dataRoot: securityCenter.dataRoot, turn: turn)?.binding },
                                 policyCatalog: { turn in try AppActions.policyCatalog(dataRoot: securityCenter.dataRoot, turn: turn) },
                                 appReadOnly: { input, turn in try Self.doorReadOnly(input, turn: turn) })
        } catch {
            // Preserve the assembly failure at the registry boundary. No action can be admitted against an empty invented catalog.
            let failure = error
            AppActionBinding.register([:], tools: Array(SwiftToolDispatcher.nativeToolDescriptors.values) + Self.sharedDescriptors,
                authorableToolName: SwiftToolDispatcher.isAuthorableToolName,
                partPolicy: { _, _ in throw failure }, policyCatalog: { _ in throw failure }, appReadOnly: { _, _ in throw failure })
        }
        self.actionExecution = actionExecution
        self.securityCenter = securityCenter
        self.enforceAutonomySecurity = enforceAutonomySecurity
        self.browserActionRunner = browserActionRunner
        self.chrome = chrome
        self.motorActionObserver = motorActionObserver
        self.mobileNotificationSender = mobileNotificationSender
        self.macNotificationSender = macNotificationSender
        self.macIntegrationPermissionStore = macIntegrationPermissionStore
        self.doctorStatusProvider = doctorStatusProvider
        self.telegramStatusProvider = telegramStatusProvider
        self.humanConversationReplyHandler = humanConversationReplyHandler
        self.proactiveSpeechClient = proactiveSpeechClient
        self.attention = attention
        self.quietHost = quietHost
        self.presentation = presentation
        self.bindPresentation = bindPresentation
        let root = securityCenter.dataRoot
        let pages: @Sendable () async throws -> [String: QuietToolPage] = {
            try await Dictionary(([Self.doorInbox] + presentation.pages).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        AgentWorkspacePorts.rankParts { message, root, turn in
            do {
                let memory = await Self.memoryOwner(dataRoot: securityCenter.dataRoot)
                return await AppActions.parts(message, pages: try await pages(), dataRoot: root, memory: memory, turn: turn)
            }
            catch { return PreparedWorkspaceGlance("Parts could not be ranked: " + error.localizedDescription) }
        }
        Task.detached {
            let memory = await Self.memoryOwner(dataRoot: root)
            let paths = ["agents/peers.json", "config/embeddings.json", "ui/layout.json"]
                .map { root.appendingPathComponent($0) }
                + [defaultPersonaRoot(dataRoot: root).appendingPathComponent("skills/bodies")]
            await memory.installActionIndex(paths: paths,
                // Catalog text reads parts, guidance, contacts, helpers and page names; no UserDefaults value is an input.
                notifications: [AbilityStore.didChange, BotRunQueue.didChange, .pageCatalogPublished]) {
                    // The catalog, never the view of the session whose find asked for this fill: a turn's own actions are embedded with its ask.
                    let pages = try await pages()
                    let inventory = try await AppActions.inventory(dataRoot: root, turn: nil)
                    return try AppActions.actionTexts(inventory.actions, pages: pages,
                        contacts: AgentPeerStore(dataRoot: root).list().map(\.name),
                        helpers: BotDefinitionStore(dataRoot: root).list().map(\.name))
                }
        }
    }

    /// Scope an existing executor without repeating catalog registration or starting owners.
    public func withExecution(_ execution: AppActionExecution) -> AppToolExecutor {
        AppToolExecutor(copying: self, execution: execution)
    }

    private init(copying owner: AppToolExecutor, execution: AppActionExecution, binding: AppToolPresentationBinding? = nil) {
        actionExecution = execution
        chrome = owner.chrome
        motorActionObserver = owner.motorActionObserver
        quietHost = binding?.host ?? owner.quietHost
        presentation = binding?.presentation ?? owner.presentation
        bindPresentation = binding == nil ? owner.bindPresentation : nil
        securityCenter = owner.securityCenter
        enforceAutonomySecurity = owner.enforceAutonomySecurity
        browserActionRunner = owner.browserActionRunner
        mobileNotificationSender = owner.mobileNotificationSender
        macNotificationSender = owner.macNotificationSender
        macIntegrationPermissionStore = owner.macIntegrationPermissionStore
        doctorStatusProvider = owner.doctorStatusProvider
        telegramStatusProvider = owner.telegramStatusProvider
        humanConversationReplyHandler = owner.humanConversationReplyHandler
        proactiveSpeechClient = owner.proactiveSpeechClient
        attention = owner.attention
    }

    static func doorReadOnly(_ input: [String: JSONValue], turn: Turn?) throws -> Bool {
        guard input["script"] == nil || input["script"] == .null || input["script"] == .string("") else { return false }
        if case .array(let entries)? = input["actions"], !entries.isEmpty {
            return try entries.allSatisfy { if case .object(let call) = $0 { try doorReadOnly(call, turn: turn) } else { false } }
        }
        let action = doorText(input["action"])
        if !action.isEmpty {
            let args: [String: JSONValue] = if case .object(let args)? = input["args"] { args } else { [:] }
            return try AppActions.action(action, turn: turn)?.readOnly(args: args) == true
        }
        return !opensHomeItem(input)
    }

    /// Notification routing uses Core's schemas so app and bridge contracts agree.
    public static let notificationToolNames = ["mac_notify", "mobile_notify"]
    public static let browserToolNames = appToolSchemas(includeDoor: false)
        .map(\.name).filter { $0.hasPrefix("browser.") }
    /// Internal callers retain canonical names for browser/chat actions even though the public door is app.
    package static let buckets: [String: ChatToolCatalogBucket] = Dictionary(uniqueKeysWithValues:
        browserToolNames.map { ($0, .browser) } + [("chat_reply", .core)] + doorToolNames.map { ($0, .alwaysOn) })

    /// Immutable schemas are shared because Core reads them on every call. They hold the door's first drawing, since a registered descriptor never
    /// changes; a turn offers the model `modelSchemas`, the door as the agent's hand is now.
    public var descriptors: [ToolDescriptor] { Self.sharedDescriptors }
    private static let sharedDescriptors = appToolSchemas().compactMap { schema in
        buckets[schema.name].map { ToolDescriptor(schema: schema, bucket: $0) }
    }.sorted { $0.name < $1.name }

    public var replacesCoreTools: Set<String> { Set(Self.notificationToolNames) }

    public func execute(
        tool: String, input: [String: JSONValue], surface: String, turn: Turn
    ) async throws -> JSONValue {
        try await execute(tool: tool, input: input, surface: surface, turn: turn, execution: actionExecution)
    }

    public func execute(tool: String, input: [String: JSONValue], surface: String, turn: Turn,
        invocation: ChatToolInvocation) async throws -> JSONValue {
        let execution = actionExecution.receiving(invocation)
        return try await execute(tool: tool, input: input, surface: surface, turn: turn, execution: execution)
    }

    public func execute(tool: String, input: [String: JSONValue], surface: String, turn: Turn,
        execution: AppActionExecution) async throws -> JSONValue {
        if let bindPresentation, let binding = try await bindPresentation(turn) {
            return try await AppToolExecutor(copying: self, execution: execution, binding: binding)
                .execute(tool: tool, input: input, surface: surface, turn: turn, execution: execution)
        }
        switch tool {
        // App bodies route notifications here; bridge-only bodies use Core with the same backends and permission gates.
        case "mobile_notify", "mac_notify":
            let admission = await securityCenter.fullMacYoloAuthority(
                origin: AppChatToolDispatcher.securityOrigin(turn: turn, surface: surface), turn: turn)
            guard let access = SwiftToolDispatcher.macIntegrationAccess(forTool: tool) else {
                throw ToolFailureError("Mac integration action has no permission declaration: \(tool)", effects: .none)
            }
            let allowed = try await macIntegrationPermissionStore.allows(access.integration, mode: access.mode)
            guard allowed else {
                return try await SwiftToolDispatcher.macIntegrationDeniedEnvelope(
                    invocation: execution.invocation, integration: access.integration, mode: access.mode, store: macIntegrationPermissionStore)
            }
            if tool == "mobile_notify" {
                return try await Self.mobileNotify(input: input, surface: surface, toolName: "mobile.notify", turn: turn, sender: mobileNotificationSender)
            }
            return try await runMacNotify(input: input, surface: surface, turn: turn, execution: execution)
        case _ where Self.browserToolNames.contains(tool):
            return try await runBrowserTool(actionId: tool, input: input, surface: surface, turn: turn, execution: execution)
        case "chat_reply":
            return try await humanConversationReplyHandler(input, turn)
        case "app":
            return try await runAppDoor(input: input, surface: surface, turn: turn, execution: execution)
        default:
            return .object([
                "status": .string("failed"), "effects": .string("none"), "reason": .string("not_in_dispatch_table"), "tool": .string(tool),
                "detail": .string("\(tool) has no handler in this build, so nothing ran. app {find} shows what is available."),
            ])
        }
    }

    public static func defaultMobileNotificationSender(
        _ note: NativeAgentNotificationDefaults.Note, userInfo: [String: String], router: AttentionRouter, turn: Turn
    ) async throws -> AttentionOutcome {
            // Each explicit send is its own happening, even when its words match an earlier send.
            let matter = Matter(id: "mobile_notify:" + UUID().uuidString.lowercased(), form: .words,
                from: userInfo["source"] ?? "mobile_notify", title: note.title, subtitle: note.subtitle, summary: note.message,
                open: turn.verifiedSessionID.map { "chat:" + $0 })
            return try await router.tell(matter, reach: .pinned(.phone, from: nil), turn: turn)
    }

    // MARK: - Notifications

    private func runMacNotify(input: [String: JSONValue], surface: String, turn: Turn,
                              execution: AppActionExecution) async throws -> JSONValue {
        let note = try NativeAgentNotificationDefaults.parseInput(input, toolName: "mac.notify")
        let result = try await macNotificationSender(note, turn, execution.invocation.waitDeadline)
        var obj = result.deliveryFields()
        obj.merge(Self.notificationEcho(note)) { _, new in new }
        obj.merge(["tool": .string("mac.notify"), "surface": .string(surface)]) { _, new in new }
        return .object(obj)
    }

    public static func mobileNotify(input: [String: JSONValue], surface: String, toolName: String, turn: Turn,
        sender: (NativeAgentNotificationDefaults.Note, [String: String], Turn) async throws -> AttentionOutcome
    ) async throws -> JSONValue {
        let input = input.filter { $0.value != .string("") }
        let note = try NativeAgentNotificationDefaults.parseInput(input, toolName: toolName)
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
           let sessionId = turn.verifiedSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sessionId.isEmpty {
            userInfo["sessionId"] = sessionId
        }
        let outcome = try await sender(note, userInfo, turn)
        var obj = try outcome.phoneDeliveryFields()
        obj.merge(Self.notificationEcho(note)) { _, new in new }
        obj.merge([
            "tool": .string("mobile.notify"),
            "surface": .string(surface),
            "screen": .string(screen),
            "source": .string(source),
            "urgency": .string(urgency),
        ]) { _, new in new }
        return .object(obj)
    }

    /// What a notification receipt says back of what it was given: title, subtitle when one was given, and the message's start.
    public static func notificationEcho(_ note: NativeAgentNotificationDefaults.Note) -> [String: JSONValue] {
        var echo: [String: JSONValue] = [
            "title": .string(NativeAppSecretRedactor.redactText(note.title)),
            "messagePreview": .string(String(NativeAppSecretRedactor.redactText(note.message).prefix(200))),
        ]
        if let subtitle = note.subtitle { echo["subtitle"] = .string(NativeAppSecretRedactor.redactText(subtitle)) }
        return echo
    }

    // MARK: - Health

    /// Status reads share diagnostics/doctor and telegram/status without mutation.
    func healthRead(_ item: String, turn: Turn) async throws -> JSONValue {
        item == "doctor" ? try await doctorStatusProvider(nil, nil, turn) : try await telegramStatusProvider()
    }

    private static func healthResult(_ result: JSONValue, surface: String) -> JSONValue {
        guard case .object(var object) = result else { return result }
        object["runtime"] = .string("swift-native")
        object["surface"] = .string(surface)
        return .object(object)
    }

    // MARK: - Actions

    /// Host arguments and Trust keys retain their native names; Safe admits only entries explicitly declared safe.
    @MainActor
    func runFolded(_ action: AppAction, input: [String: JSONValue], surface: String, turn: Turn, execution: AppActionExecution) async throws -> JSONValue {
        try Task.checkCancellation()
        // A folded tool runs as itself: the chain is re-entered under its own name, so its gates, Trust key and cards judge it, and what comes back is its own
        // result. A card it files replays that call, not this one.
        if action.isFold || action.id == "agent.verify" {
            guard let perform = execution.perform else {
                return Self.doorRefusal("door_unavailable",
                    "This call did not come from inside a chat turn, so it has no gate to pass. Nothing ran.",
                    remedy: "correct_arguments", "Call app from inside a chat turn; this caller cannot bind a chat by supplying a session id.")
            }
            // Preview contact sends under agent_message's own gates.
            if action.id == "agent.verify" {
                return try await AgentContactHealth.repair(turn: turn, mac: execution.macOperation(dataRoot: securityCenter.dataRoot),
                    conversation: execution.invocation.conversation, input["agent"]?.scalarText ?? "",
                    dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                    workspace: input["workspace"]?.scalarText, perform: { name, arguments, callTurn, conversation, mac in
                        var execution = execution
                        execution.invocation = execution.invocation.serving(conversation: conversation).serving(mac: mac)
                        return try await perform(name, arguments, callTurn, execution)
                    })
            }
            var call = ChatToolSessionInjection.apply(toolName: action.tool, input: input,
                                                      sessionId: input["__session_id"]?.scalarText)
            // A verb a part answers meets the workspace's names as its native executor did: names it takes are bound before it runs, and the rows it
            // reads are named after.
            let verb = action.partAction ? action.input["verb"]?.stringValue : nil
            let workspace = ChatWorkspaceBinding.operation(turn: turn, invocation: execution.invocation)
            if let verb, AgentWorkspace.takesNames.contains(verb) {
                call = AgentWorkspace.bindMail(workspace: workspace, call, dataRoot: securityCenter.dataRoot)
            }
            do {
                let result = try await perform(action.tool, call, turn, execution)
                // Home does not tell the agent of a Desk change its own mind just made: a turn a model is running, not the person's tap and
                // not another agent's call that reached this tool without her.
                if action.id.hasPrefix("desk."), turn.personAct == nil, turn.admission != nil, case .object(let done) = result,
                   done["status"] == .string("ok"),
                   let handle = done["handle"]?.stringValue {
                    await AgentScreen.sawOwnDeskChange(handle, dataRoot: securityCenter.dataRoot)
                }
                if action.partAction, execution.valueCall?.id != action.tool,
                   case .object(let fields) = result, let returned = fields["returned"] {
                    var answer: [String: JSONValue] = if case .object(let answer) = returned { answer } else { ["result": returned] }
                    if fields["status"] == .string("ok") || fields["status"] == .string("refused") && answer["status"] == .string("failed") {
                        // The part supplies its payload; only the runner can attest its effects and how many times it carried itself.
                        for key in ["effects", "calls", "changed", "runs", "handed_back", "ability_run"] { answer[key] = fields[key] }
                        guard let verb, AgentWorkspace.namesRows.contains(verb) else { return .object(answer) }
                        AgentReadBadges.shared.note(.object(answer), dataRoot: securityCenter.dataRoot)
                        return AgentWorkspace.attachReadReferences(workspace: workspace, tool: verb, input: call, result: .object(answer),
                                                                   dataRoot: securityCenter.dataRoot)
                    }
                }
                return result
            }
            catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
        }
        // A setting and a card hold the posture gate themselves, and say it in their own words (a setting's requested and current values; a card's origin and
        // Full Mac checks).
        if action.id == "setting.set" { return await runAppSettingSet(input: input, surface: surface, turn: turn, execution: execution) }
        if action.id == "setting.get" { return await runAppSettingGet(input: input, turn: turn) }
        if action.isCard { return await runCardAction(input: input, surface: surface, turn: turn) }
        try Task.checkCancellation()
        let verb = action.input["verb"]?.scalarText ?? ""
        switch action.tool {
        case "app_find":
            let what = Self.doorText(input["what"])
            let query = what.isEmpty ? Self.doorText(input["query"]) : what
            guard !query.isEmpty else {
                return Self.doorRefusal("invalid_args", "Discovery needs words in args.what or args.query. Nothing was searched.",
                    remedy: "correct_arguments", "Use app {find:\"what you want to do\"}.", next: ["find": .string("what you want to do")])
            }
            return try await doorFind(query, turn: turn, execution: execution)
        case "chat_post":
            let root = securityCenter.dataRoot
            guard let destination = ConversationAnchor.currentSessionId(dataRoot: root) else {
                throw ChatOrchestrationError.underlying("The person has no current conversation. Nothing was posted.")
            }
            guard !turn.id.isEmpty else {
                throw ChatOrchestrationError.underlying("chat.post requires a current turn. Nothing was posted.")
            }
            let message = input["message"]?.scalarText ?? ""
            // Post into the user's thread with that thread's route so delivery reaches the user's Mac, phone and Telegram.
            let route = try await HumanConversationReader.read(sessionID: destination, dataRoot: root).route
            // Resolve notification provenance before producing the post. An unavailable route is not evidence that this conversation has no Telegram door.
            let telegram = try await HumanConversationReader.read(sessionID: destination, dataRoot: root, surface: "telegram").route
            let result = try await proactiveSpeechClient(root).speakProactively(
                content: message, caller: .reachOut,
                idempotencyKey: SwiftNativeChatOrchestrationClient.proactiveSpeechIdempotencyKey(scope: "chat.post:" + turn.id, content: message),
                sessionId: destination,
                turn: turn.with(\.envelope, route))
            switch result {
            case .posted(let session, let run):
                // Knock at the person's doors, including the target thread's Telegram door when present.
                let knock: AttentionOutcome
                do {
                    knock = try await attention().tell(Matter(id: "chat.post:" + run, form: .words, from: "chat.post",
                        title: NativeAgentNotificationDefaults.agentDisplayName(dataRoot: root), summary: message,
                        open: "chat:" + session),
                        reach: .person(from: AttentionOrigin(replyRoute: (telegram ?? route)?.replyRoute, sessionId: session)), turn: turn)
                } catch {
                    return .object(["status": .string("ok"), "effects": .string("occurred"), "session_id": .string(session),
                        "run_id": .string(run), "knock": .string("failed"), "knock_error": .string(error.localizedDescription)])
                }
                return .object(["status": .string("ok"), "effects": .string("occurred"), "session_id": .string(session), "run_id": .string(run),
                                "knock": .string(knock.deliveryProjection.rawValue),
                                "destinations": .object(knock.destinationFields)])
            case .duplicate(let session):
                return .object(["status": .string("ok"), "effects": .string("none"), "session_id": .string(session), "duplicate": .bool(true)])
            }
        case "mac_apps":
            let name = input["name"]?.scalarText ?? ""
            let inventory = try await MacAppIndex.shared.inventory(context: execution.macOperation(dataRoot: securityCenter.dataRoot))
            let every = inventory.apps.filter { name.isEmpty || $0.name.localizedCaseInsensitiveContains(name) }
            let all = input["all"] == .bool(true)
            let apps = all ? every : MacAppIndex.installed(every)
            let twice = MacAppIndex.collisions(apps)
            // Disambiguate duplicate shown names by file name, then folder, so launch targets remain explicit.
            var fileNames: [String: Int] = [:]
            for app in apps where twice.contains(app.name.lowercased()) {
                fileNames[app.url.deletingPathExtension().lastPathComponent.lowercased(), default: 0] += 1
            }
            // Duplicate bundle ids make id-based launch ambiguous; expose that ambiguity on the row.
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
            let unclassified = every.filter { !$0.classificationFailures.isEmpty }
            let complete = unclassified.isEmpty && inventory.directoryGaps.isEmpty
            return .object(["status": .string(complete ? "ok" : "partial"), "apps": .array(rows), "count": .int(Int64(apps.count)),
                            "classification_complete": .bool(complete),
                            "classification_unavailable": .array(unclassified.map(\.json)),
                            "directory_gaps": .array(inventory.directoryGaps.map(JSONValue.string)),
                            "other_copies_and_ios": .int(Int64(every.filter { $0.kind == "copy" || $0.platform == "ios" }.count)),
                            "source": .string("the Mac's app index (Spotlight): the installed copy of each Mac app, as the Apps screen shows them"
                                + (all ? """
                                    , plus every other copy (builds, backups) and iOS build the Mac indexes, tagged by kind and platform
                                    """ : "; all:true lists other copies and iOS builds too")
                                + """
                                    ; unavailable classification is reported separately and excluded from the installed projection; an app on a volume \
                                    Spotlight does not index is not listed
                                    """)])
        case "undo":
            return try await doorUndo(input: input, turn: turn, execution: execution)
        case "read_file" where action.id == "reply.attach":
            return await runReplyAttach(input: input, turn: turn, execution: execution)
        case "claude_worklog":
            return await AgentConversationView.claudeWorklog(input: input)
        case "chat_working_memory":
            guard let session = turn.verifiedSessionID ?? turn.session,
                  NativeAgentChatSessionID.isSafePathComponent(session), case .string(let text)? = input["text"] else {
                throw ToolFailureError("A private choice needs this turn's conversation and a text string.", effects: .none)
            }
            guard text.count <= ChatSessionScratch.workingMemoryLimit else {
                throw ToolFailureError("Keep the private choice within 1200 characters; nothing was changed.", effects: .none)
            }
            try await ChatSessionScratch.holdWorkingMemory(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                sessionID: session, text: text)
            return .object(["status": .string("ok"), "held": .bool(!text.isEmpty),
                            "detail": .string(text.isEmpty ? "Private working memory cleared." : "Private choice held for this conversation.")])
        case "agent_contacts" where action.id == "agent.recipe":
            return AgentRecipeStore.read(host: input["host"]?.scalarText)
        case "agent_connect" where action.id == "agent.recipe_write":
            return AgentRecipeStore.write(host: input["host"]?.scalarText ?? "", document: input["recipe"] ?? .null,
                                          undoing: execution.undoReceipt)
        case "agent_message" where action.id == "agent.reply":
            return try await AgentConversationSession.answer(part: turn.abilityID, agent: input["agent"]?.scalarText,
                exchange: input["exchange"]?.scalarText, text: input["text"]?.scalarText ?? "", done: input["done"] != .bool(false),
                dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        case "agent_connect" where action.id == "agent.rename": return try AgentPeerStore(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore
            .defaultDataRoot()).rename(input["agent"]?.scalarText ?? "", name: input["name"]?.scalarText ?? "")
        case "app_page_read" where action.id == "layout.read":
            return SurfaceLayoutStore.read(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        case "app_setting_set" where action.id == "layout.write":
            return SurfaceLayoutStore.write(input["layout"] ?? .null, expectedVersion: input["layout_version"]?.scalarText ?? "",
                                            dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(), undoing: execution.undoReceipt)
        case "agent_job" where action.id == "agent.discard":
            return await AgentJobs.discard(input["job"]?.scalarText ?? "", dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        case "agent_job" where action.id == "agent.apply":
            // The merge re-enters the chain as the agent's own git call, so git's gates, Trust key and cards judge it; a card it files replays that git call.
            guard let perform = execution.perform else {
                return Self.doorRefusal("door_unavailable", "This call did not come from inside a chat turn, so it has no git to merge with. Nothing ran.",
                    remedy: "correct_arguments", "Call app from inside a chat turn; this caller cannot bind a chat by supplying a session id.")
            }
            let session = input["__session_id"]?.scalarText
            return await AgentJobs.apply(input["job"]?.scalarText ?? "", dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()) {
                args, cwd in
                let call = ChatToolSessionInjection.apply(toolName: "git", input: ["args": .array(args.map(JSONValue.string)), "cwd": .string(cwd)],
                                                          sessionId: session)
                return try await perform("git", call, turn, execution)
            }
        case "agent_job":
            return await runAgentJob(input: input, surface: surface, turn: turn)
        case "agent_discovery_dismiss":
            return await AgentDiscoverySession.shared.dismiss(name: input["name"]?.scalarText ?? "",
                dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        case "photos_read":
            return await runPhotosRead(verb: verb, input: input)
        case "sense_act":
            return await runSenseAct(input: input, turn: turn, execution: execution)
        case "sense_make":
            return await runSenseMake(input: input, turn: turn, execution: execution)
        case "sense_lifecycle":
            return try await runSenseLifecycle(input: input, turn: turn, execution: execution)
        case "app_page_screenshot":
            let reply = ToolResult(await presentation.pageScreenshot(input: input, imageSink: execution.localImageSink))
            guard case .object(var fields) = reply.payload, reply.remedy == nil else { return reply.payload }
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
            return await runMake(verb: verb, input: input, turn: turn, execution: execution)
        case "studio_intake_read":
            return await runStudioIntakeRead(input: input, surface: surface)
        case "doctor_status":
            return Self.healthResult(try await doctorStatusProvider(input["repair"] == .bool(true), input["check_id"]?.scalarText, turn), surface: surface)
        case "my_queue":
            return await runMyQueue(verb: verb, input: input, surface: surface, turn: turn)
        case "house_file":
            return await runHouseFile(input: input, surface: surface, turn: turn)
        case "repair_let_go":
            return await runRepairLetGo(input: input)
        case "record_read":
            return await runRecordRead(input: input)
        case "abilities_restore_state":
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let archive = try AbilityStore(dataRoot: root).restoreState(input["state"] ?? .null,
                expectedDigest: input["expected_digest"]?.scalarText ?? "", turn: turn)
            return .object(["status": .string("ok"), "effects": .string("occurred"),
                "preserved": .string(archive.path), "detail": .string("""
                    Recovered ability run state was read back. Damaged bytes were preserved; ability files and authority were unchanged.
                    """)])
        case "turn_reconcile":
            return await runTurnReconcile(input: input)
        case "home_arrive":
            let line = (input["line"]?.scalarText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let part = turn.partID else {
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
            // A part's line is a world happening, judged by the agent's weigh and never by this door. Peers that steered the run travel with it, so
            // the thought that reads it carries their authority, never more.
            let happening = Happening(.world, subject: "part:" + part, door: "part:" + part, words: part + ": " + line,
                once: "part:" + part + ":" + (eventKey == nil ? day : "event") + ":" + digest,
                peers: turn.peerSteering?.checkpointSources, elevated: turn.peerSteering?.elevatedSources)
            do {
                guard try await ExperienceStore.at(root).experience(happening.id) == nil else {
                    return .object(["status": .string("ok"), "effects": .string("none"), "detail": .string("This arrival is already known.")])
                }
            } catch {
                return Self.failure("record_unreadable", """
                    The record could not say whether this arrival is already known (\(error.localizedDescription)), so nothing was filed. Call it again \
                    once the record reads.
                    """)
            }
            Attention.post(happening, dataRoot: root)
            return .object(["status": .string("ok"), "effects": .string("occurred"), "detail": .string("""
                In your mind: your weigh judges what it is worth, and worth that gathers on what it means opens a thought.
                """)])
        case "list_memories", "rewrite_memory":
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            return try await Self.curateMemory(tool: action.tool, root: root, input: input, surface: surface,
                                              turn: turn, invocation: execution.toolInvocation)
        default:
            break
        }
        guard let host = quietHost() else { return Self.unattachedFailure() }
        switch action.tool {
        case "inbox":
            return await host.inbox(verb: verb, input: input, turn: turn)
        case "provider", "connections":
            let answer = action.tool == "provider"
                ? await host.provider(verb: verb, input: input, turn: turn) : await host.connections(verb: verb, input: input, turn: turn)
            guard case .object(var body) = answer else {
                return Self.doorRefusal("handler_result_missing", "\(action.id) returned no structured result; its effects are unknown.",
                    remedy: "inspect", "Read the owning page and reconcile the affected state before another change.",
                    next: ["page": .string(action.page)], extra: ["effects": .string("unknown"), "action": .string(action.id), "verb": .string(verb)])
            }
            body["verb"] = .string(verb)
            // Who decided it: the person when their own act admitted this call, the agent otherwise.
            if action.tool == "connections" { body["decided_by"] = .string(turn.personAct == nil ? "agent" : "person") }
            return .object(body)
        case "upkeep", "mind_run", "ability_manage":
            let outcome = switch action.tool {
            case "upkeep": await host.runUpkeep(verb: verb, input: input, turn: turn)
            case "mind_run": await host.runMind(verb: verb, input: input, turn: turn)
            default:
                await host.managePart(verb: verb, input: input, steer: Self.skillSteer(surface: surface, turn: turn),
                    turn: turn, invocation: execution.partInvocation(turn: turn, surface: surface, preview: input["preview"] == .bool(true)))
            }
            var body = outcome.fields
            // Only the turn program's save asks the person this way (needs_person); no other verb's fields, a part run's among them, word
            // the person's card.
            let asks = action.id == "ability.save" && body["status"] == .string("needs_person")
            let named = body["status"].flatMap { $0 == .string("needs_person") ? nil : $0 }
            body["status"] = body["preview"] == .bool(true) ? .string("preview")
                : asks ? .string("needs_person") : outcome.ok ? .string("ok") : named ?? .string("failed")
            body["verb"] = .string(verb)
            body["detail"] = .string(outcome.detail)
            return .object(body)
        case "chat_session":
            return await runChatSessionAction(verb: verb, input: input, surface: surface, host: host, turn: turn)
        case "chat_conversations":
            // Chat reads share the sidebar/chat.list rows.
            return await host.runChatSession(verb: "list", input: input, reachesUser: false, turn: turn)
        case "interaction_act" where action.input["target"] == .string("composer"):
            return await runComposerAction(verb: verb, input: input, surface: surface, host: host, turn: turn)
        default:
            return Self.failure("not_folded", "\(action.id) is not run in process.", extra: ["tool": .string(action.tool)])
        }
    }

    static func skillSteer(surface: String, turn: Turn) -> [String] {
        let steer = PeerDataTaint.carried(turn: turn, peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: turn.envelope?.verifiedUserId)
        return steer.sources + steer.elevated
    }

    /// Owner resolution inspects memory storage; execution and preview must both leave the host's UI executor before resolving it.
    @concurrent private static func memoryOwner(dataRoot: URL) async -> SwiftNativeMemoryV2 {
        SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
    }

    @concurrent private static func curateMemory(tool: String, root: URL, input: [String: JSONValue], surface: String,
                                               turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        let curation = MemoryCuration(memoryV2: SwiftNativeMemoryV2.resolvedOwner(dataRoot: root), dataRoot: root)
        return tool == "list_memories"
            ? try await curation.listMemories(input: input, surface: surface, persona: nil)
            : try await curation.rewriteMemory(turn: turn, invocation: invocation, input: input, surface: surface, persona: nil)
    }

    @concurrent private static func checkMemoryRewrite(root: URL, input: [String: JSONValue], surface: String) async throws {
        _ = try await MemoryCuration(memoryV2: SwiftNativeMemoryV2.resolvedOwner(dataRoot: root), dataRoot: root)
            .rewriteTarget(input: input, surface: surface, persona: nil)
    }

    /// Preview shares execution's read-only card, setting, composer, inbox and chat checks; nil means none refuses.
    @MainActor
    func foldedRefusal(_ action: AppAction, input: [String: JSONValue], surface: String, turn: Turn, execution: AppActionExecution) async -> JSONValue? {
        var input = input
        if action.folded {
            // The host call passes the admission execution gives it on re-entry, against its registered schema or, where it has none, the schema the
            // fold took from that same catalog.
            let tool = CanonicalToolNameDispatcher.canonical(action.tool)
            do {
                input = try ToolArguments.admitted(input, tool: tool, schema: AppActionBinding.declaredSchema(tool) ?? action.schema,
                                                   wake: execution.wake, recordShims: false)
            } catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
        }
        if action.tool == "request_interaction" {
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            if case .object(var result) = await SwiftToolDispatcher.requestedInteraction(invocation: execution.invocation, input: input, dataRoot: root) {
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
        // User-off switches refuse preview and execution identically, regardless of the calling chain's validator.
        if let gate = action.schema?.macIntegration {
            do {
                if let refusal = try await SwiftToolDispatcher.switchRefusal(integration: gate.integration,
                    mode: gate.mode, store: macIntegrationPermissionStore) { return refusal }
            } catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
        }
        if action.isFold { return await execution.validate?(action.tool, input, turn) }
        if action.isCard { return await cardRefusal(input: input, surface: surface, turn: turn) }
        if action.id == "setting.set" { return await settingRefusal(input: input, turn: turn, execution: execution) }
        if action.tool == "rewrite_memory" {
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            do {
                try await Self.checkMemoryRewrite(root: root, input: input, surface: surface)
            } catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
        }
        if action.tool == "mind_run", let verb = action.input["verb"]?.scalarText,
           ["reject", "undo", "revise"].contains(verb),
           case .failure(let refusal) = StudioCanonSeatGate.liveTurnProvenance(turn: turn) {
            return Self.failure(refusal.rawValue,
                "mind.\(verb): \(refusal.spoken). It is done from inside your own conversation, in your own turn.")
        }
        if action.tool == "upkeep" {
            guard let host = quietHost() else { return Self.unattachedFailure() }
            return await host.upkeepFence(verb: action.input["verb"]?.scalarText ?? "", input: input)
        }
        // Origin, steer and Trust decide who may restore an off switch; preview uses the real call's checks and reports its proposed state.
        if let lifecycle = action.lifecycle, lifecycle != .drop, lifecycle != .change {
            if action.tool == "sense_lifecycle" {
                do { return try await runSenseLifecycle(input: input.merging(["preview": .bool(true)]) { $1 }, turn: turn, execution: execution) }
                catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
            }
            guard let host = quietHost() else { return Self.unattachedFailure() }
            let asked = await host.managePart(verb: action.input["verb"]?.scalarText ?? "",
                                               input: input.merging(["preview": .bool(true)]) { $1 },
                                               steer: Self.skillSteer(surface: surface, turn: turn),
                                               turn: turn, invocation: execution.partInvocation(turn: turn, surface: surface, preview: true))
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
        case "inbox": return await host.inboxFence(verb: verb, input: input, turn: turn)
        case "chat_session":
            let root = host.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let fullMac = await Self.freshQuietPosture(dataRoot: root)?.name == Self.fullMacModeName
            let reachesUser: Bool
            do { reachesUser = try await Self.reachesUser(surface: surface, fullMac: fullMac, dataRoot: root, turn: turn) }
            catch { return ChatToolOutcome.failure(error: error, tool: "chat_session", effects: ToolFailureError.Effects.none) }
            return await host.chatSessionFence(verb: verb, input: input, reachesUser: reachesUser, turn: turn)
        default: return await composerRefusal(verb: verb, input: input, surface: surface, host: host, turn: turn)
        }
    }

}

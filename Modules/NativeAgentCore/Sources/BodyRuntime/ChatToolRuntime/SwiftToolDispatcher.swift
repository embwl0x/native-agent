import SenseCore
import MindCore
import Foundation
import Synchronization
import MacNerves
import NativeAgentCore
import PersistenceCore
import DeskCore
import ProviderRouting
// Blueprint: | `SwiftToolDispatcher.swift` | Dispatcher/catalog construction; checked registry revision and selected schema encoding |

public protocol ChatMacIntegrationToolBridge: MacIntegrationToolBridge, PureToolArgumentValidating {
    func serving(turn: Turn, context: MacOperationContext) -> any MacIntegrationToolBridge
}

/// App actions share this catalog and dispatch routes; contributed executors retain their permission and availability checks.
public struct SwiftToolDispatcher: ToolDispatchClient {
    /// Implementations that still own process-global credentials, app lifecycle, or another live-body singleton. Synthetic roots fail closed instead of
    /// reaching across bodies.
    static let canonicalBodyOnlyToolNames: Set<String> = [
        "restart_app", "image_generate",
    ]

    var allowsCanonicalBodyTools: Bool { runtime.allowsCanonicalBodyTools }
    var dataRoot: URL { runtime.dataRoot }
    var bodyField: BodyField? { runtime.bodyField }
    var jobStore: AgentJobStore { runtime.jobStore }
    var dotTransport: ChatGPTDotIPCTransport? { runtime.dotTransport }
    var pageReader: SwiftNativeResearchClient { runtime.pageReader }
    var standingBotRunner: BotRunner? { runtime.standingBotRunner }
    var standingBotRunEnqueue: (@Sendable (UUID, String?, Turn, Set<UUID>) throws -> BotRunReceipt)? { runtime.standingBotRunEnqueue }
    var memoryV2: SwiftNativeMemoryV2 { get throws { try runtime.memoryV2 } }
    var knowledgeGraphPath: URL { runtime.knowledgeGraphPath }
    var providerLifecycleObserver: (any LLMCallLifecycleObserving)? { runtime.providerLifecycleObserver }
    var studioJournalBus: StudioJournalCognitiveBus? { runtime.studioJournalBus }
    public var macIntegrationBridge: (any ChatMacIntegrationToolBridge)? { runtime.macIntegrationBridge }
    var macIntegrationPermissionStore: MacIntegrationPermissionStore { runtime.macIntegrationPermissionStore }
    var agentBridgeConfigRoot: URL? { runtime.agentBridgeConfigRoot }
    var a2aPushConfiguration: (@Sendable (AgentPeerContact) async throws -> JSONValue)? { runtime.a2aPushConfiguration }
    var usesCanonicalBody: Bool { runtime.usesCanonicalBody }
    public var includeAppOwnedTools: Bool { appEnvironment?.includeAppOwnedTools ?? usesCanonicalBody }
    var rootForRead: URL { runtime.rootForRead }

    let runtime: ActionRuntime
    let appTools: AppToolExecutor?
    private let executorDescriptors: [String: ToolDescriptor]
    let appEnvironment: AppActionEnvironment?

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        bodyField: BodyField? = nil,
        allowProcessGlobalTools: Bool = true,
        dotTransport: ChatGPTDotIPCTransport? = nil,
        jobStore: AgentJobStore? = nil,
        providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        studioJournalBus: StudioJournalCognitiveBus? = nil,
        macIntegrationBridge: (any ChatMacIntegrationToolBridge)? = nil,
        macIntegrationPermissionStore: MacIntegrationPermissionStore? = nil,
        appTools: AppToolExecutor? = nil,
        agentBridgeConfigRoot: URL? = nil,
        a2aPushConfiguration: (@Sendable (AgentPeerContact) async throws -> JSONValue)? = nil,
        standingBotRunEnqueue: (@Sendable (UUID, String?, Turn, Set<UUID>) throws -> BotRunReceipt)? = nil,
        standingBotRunner: BotRunner? = nil
    ) {
        self.init(runtime: ActionRuntime(
            dataRoot: dataRoot,
            bodyField: bodyField,
            allowProcessGlobalTools: allowProcessGlobalTools,
            dotTransport: dotTransport,
            jobStore: jobStore,
            providerLifecycleObserver: providerLifecycleObserver,
            studioJournalBus: studioJournalBus,
            macIntegrationBridge: macIntegrationBridge,
            macIntegrationPermissionStore: macIntegrationPermissionStore,
            agentBridgeConfigRoot: agentBridgeConfigRoot,
            a2aPushConfiguration: a2aPushConfiguration,
            standingBotRunEnqueue: standingBotRunEnqueue,
            standingBotRunner: standingBotRunner), appTools: appTools)
    }

    init(runtime: ActionRuntime, appTools: AppToolExecutor?, appEnvironment: AppActionEnvironment? = nil) {
        self.appEnvironment = appEnvironment
        let descriptors = appTools?.descriptors ?? []
        precondition(Set(descriptors.map(\.name)).isDisjoint(with: Self.nativeCanonicalToolNames),
                     "Contributed tools must not shadow Core tools; declare replacements instead.")
        let replacements = appTools?.replacesCoreTools ?? []
        precondition(replacements.isSubset(of: Self.nativeCanonicalToolNames), "Only registered Core tools can be replaced.")
        self.executorDescriptors = Dictionary(uniqueKeysWithValues:
            (descriptors + replacements.compactMap { Self.nativeToolDescriptors[$0] }).map { ($0.name, $0) })
        self.runtime = runtime
        self.appTools = appTools
    }

    public func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        if names == ["app"] {
            return appTools?.modelSchemas.filter { names.contains($0.name) } ?? []
        }
        return try await catalogSnapshot(turn: turn, includeSchemas: true, schemaNames: names, surface: surface).schemas
    }

    public func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await catalogSnapshot(turn: turn, includeSchemas: true, surface: surface).schemas
    }

    func catalogSnapshot(turn: Turn?, includeSchemas: Bool, schemaNames: Set<String>? = nil, surface: String) async throws -> (names: [String],
        schemas: [LLMToolSchema], access: FullMacToolAccess) {
        let records = try readRegistryRecords()
        let access = try await fullMacToolAccess(turn: turn, surface: surface)
        let activity = await activityCaptureEnabled(turn: turn, surface: surface)
        let builtIn = ActionCatalog.current.ordered.compactMap { action -> LLMToolSchema? in
            let schema = action.schema
            guard schemaNames?.contains(schema.name) != false,
                  usesCanonicalBody || !Self.canonicalBodyOnlyToolNames.contains(schema.name) else { return nil }
            switch action.availability {
            case .files where !access.fileOpsAllowed, .system where !access.systemAllowed,
                 .accessibility where !access.accessibilityAllowed, .activity where !activity: return nil
            default: return schema
            }
        }
        // Authored rows cannot shadow a native route or one of its aliases.
        var names = records.filter { $0.fields["status"] == .string("active") }
            .map(\.id)
            .sorted().filter(Self.isAuthorableToolName)
        var seen = Set(names)
        names.append(contentsOf: (builtIn.map(\.name) + (appTools?.descriptors.map(\.name) ?? []))
            .filter { seen.insert($0).inserted })
        var schemas: [LLMToolSchema] = []
        if includeSchemas {
            let registry = try Self.authoredTools(records: records, named: schemaNames).filter { $0.answer == nil }.map(\.schema)
            let combined = builtIn.map { executorDescriptors[$0.name]?.schema ?? $0 } + registry
            schemas = withContributedSchemas(usesCanonicalBody
                ? combined
                : combined.filter { !Self.canonicalBodyOnlyToolNames.contains($0.name) }, named: schemaNames)
        }
        return (names, schemas, access)
    }

    /// Assembly and authored admission reserve every executor-owned name. The schemas offered are the executor's as the model reads them now.
    private func withContributedSchemas(_ native: [LLMToolSchema], named names: Set<String>?) -> [LLMToolSchema] {
        guard let appTools else { return native }
        precondition(Set(native.map(\.name)).isDisjoint(with: contributedToolNames), "Tool ownership collision in catalog.")
        return native + appTools.modelSchemas.filter { contributedToolNames.contains($0.name) && names?.contains($0.name) != false }
            .sorted { $0.name < $1.name }
    }

    var contributedToolNames: Set<String> {
        executorOwnedToolNames.subtracting(Self.nativeCanonicalToolNames)
    }

    /// Every name an executor answers: its own tools and the Core tools it runs in their place.
    var executorOwnedToolNames: Set<String> {
        appTools == nil ? [] : Set(executorDescriptors.keys)
    }

    public func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] {
        try await catalogSnapshot(turn: turn, includeSchemas: false, surface: surface).names
    }

    func registryToolRecord(_ tool: String) throws -> [String: JSONValue]? {
        let rows: [ToolRecord]
        switch Self.authoredRegistry(dataRoot: dataRoot) {
        case .success(let read): rows = read
        case .failure(let error):
            throw ToolFailureError("The agent's ability registry did not read (\(error.localizedDescription)), so '\(tool)' could not be looked up. "
                                   + "Nothing ran.",
                                   effects: .none, owner: "abilities")
        }
        for row in rows where row.id == tool { return row.fields }
        return nil
    }

    private func readRegistryRecords() throws -> [ToolRecord] { try Self.authoredRegistry(dataRoot: dataRoot).get() }

    /// The agent's authored tool registry, or the fault that kept it from reading. A fault is never an empty registry: the catalog offers none of
    /// the agent's tools while it lasts, and the agent's home owes the repair until a read works.
    static func authoredRegistry(dataRoot: URL) -> Result<[ToolRecord], any Error> {
        do {
            let rows = try AbilityStore(dataRoot: dataRoot).checkedToolRecords()
            RepairOwed.settle(dataRoot, operation: "abilities.tool_registry", evidence: .init(source: "abilities", id: UUID().uuidString))
            return .success(rows)
        } catch {
            RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .act, operation: "abilities.tool_registry", owner: "abilities",
                           words: "The agent's tool registry did not read (\(error.localizedDescription)); the agent's own tools"
                               + " are not offered until it reads again.")
            return .failure(error)
        }
    }

    /// Canonical built-in dispatch names stay reserved regardless of gate state; authored tools cannot shadow them or their dotted alias spellings.
    static let nativeCanonicalToolNames = Set(nativeToolDescriptors.keys)

    package static let reservedBuiltInNames = nativeCanonicalToolNames.union(alwaysOnCoreNames)

    static let registryReservedNames: Set<String> = reservedBuiltInNames

    /// A name a tool the agent writes may take: no built-in executor or current door binding.
    public static func isAuthorableToolName(_ id: String) -> Bool {
        !registryReservedNames.contains(id) && AppToolExecutor.buckets[id] == nil
            && CanonicalToolNameDispatcher.canonical(id) == id
    }

    /// The same, for the `app` door's generated `authored.<id>` actions, with the primitive permissions and app dependencies each declares. The store's
    /// canonical revision covers local and external changes. A failed read is not memoized; the key is read before the catalog walk.
    package static func authoredTools(dataRoot: URL) -> [AuthoredTool] {
        switch checkedAuthoredTools(dataRoot: dataRoot) {
        case .success(let tools): return tools
        case .failure: return [] // Unreadable authority offers no executable actions.
        }
    }

    /// Inventory readers retain the fault; execution discovery stays fail-closed.
    package static func checkedAuthoredTools(dataRoot: URL) -> Result<[AuthoredTool], any Error> {
        checkedAuthoredCatalog(dataRoot: dataRoot).map(\.tools)
    }

    /// One checked source snapshot supplies callable contracts and exact stable IDs.
    package struct AuthoredCatalog: Sendable {
        package let tools: [AuthoredTool]
        package let aliases: [String: String]
    }

    package static func checkedAuthoredCatalog(dataRoot: URL) -> Result<AuthoredCatalog, any Error> {
        let store = AbilityStore(dataRoot: dataRoot)
        let revision: [String]
        do { revision = try store.revision() } catch {
            RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .act, operation: "abilities.tool_registry", owner: "abilities",
                           words: """
                               The agent's tool registry's revision did not read (\(error.localizedDescription)); the agent's own tools are not offered \
                               until it reads again.
                               """)
            return .failure(error)
        }
        let key = (dataRoot.path, revision)
        if let memo = authoredToolsMemo.withLock({ $0 }), memo.key == key { return .success(memo.catalog) }
        return authoredRegistry(dataRoot: dataRoot).flatMap { records in
            Result {
                var aliases: [String: String] = [:]
                for record in records { aliases[record.id] = record.id }
                let catalog = try AuthoredCatalog(tools: authoredTools(records: records), aliases: aliases)
                if try store.revision() == revision, try store.inventory().damaged.isEmpty { authoredToolsMemo.withLock { $0 = (key, catalog) } }
                return catalog
            }
        }
    }
    private static let authoredToolsMemo = Mutex<(key: (String, [String]), catalog: AuthoredCatalog)?>(nil)

    /// One callable entry of the agent's parts: a part's own run, or a door verb its header answers.
    package struct AuthoredTool: Sendable {
        package let schema: LLMToolSchema
        package let permissions: [String]
        package let actions: [String]
        package let page: String?
        package let action: String?
        /// The verb's declaration when this entry is a verb the part answers.
        package let answer: [String: JSONValue]?
        /// A part that answers verbs runs only through them; its own entry is the run target and admission schema, never an action of its own.
        package let answering: Bool
        package let bundled: Bool
    }

    static func authoredTools(records: [ToolRecord], named names: Set<String>? = nil) throws -> [AuthoredTool] {
        let active = records
            .filter { $0.fields["status"] == .string("active") && $0.fields["disabledBy"] != .string("owner") }
        var tools: [AuthoredTool] = []
        for row in active {
            let id = row.id
            guard names?.contains(id) != false, isAuthorableToolName(id) else { continue }
            guard row.fields["language"] == .string("javascript") else { continue }
            guard row.fields["callable"] == .bool(true) else { continue }
            guard let digest = row.codeFingerprint, !digest.isEmpty,
                  case .object(let admission)? = row.fields["admission"], admission["candidate"] == .string(digest) else { continue }
            guard case .object(let schemaObject)? = row.fields["inputSchema"], schemaObject["type"] == .string("object") else {
                throw ToolFailureError("The admitted ability \(id) has no valid object inputSchema.", effects: .none,
                    owner: "abilities/\(id).js", instruction: "Repair and validate this ability's parameter declaration before offering it as an action.")
            }
            let schemaData = try JSONValue.object(schemaObject).serializedData(pretty: false)
            let page: String? = if case .object(let face)? = row.fields["face"], case .string(let page)? = face["page"] { page } else { nil }
            let action: String? = if case .object(let face)? = row.fields["face"], case .string(let action)? = face["action"] { action } else { nil }
            let permissions = row.permissions ?? []
            let reach = PermissionLaw.reach(ofPermissions: permissions)
            let toolClass = permissions.map(PermissionLaw.permissionClass).max() ?? (schemaObject["readOnly"] == .bool(true) ? .read : .write)
            let answers: [String: JSONValue] = if case .object(let verbs)? = row.fields["answers"] { verbs } else { [:] }
            let bundled = row.validationStatus == "bundled"
            tools.append(AuthoredTool(schema: LLMToolSchema(name: id, toolClass: toolClass, reach: reach,
                                                            capabilities: [.toolCall, .safeRead], description: row.description,
                                                            parametersJSON: schemaData),
                                      permissions: permissions, actions: row.actions ?? [], page: page, action: action, answer: nil,
                                      answering: !answers.isEmpty, bundled: bundled))
            for (verb, entry) in answers.sorted(by: { $0.key < $1.key }) {
                tools.append(try answeredTool(part: id, verb: verb, entry: entry, permissions: permissions, actions: row.actions ?? [], page: page,
                                              reach: reach, bundled: bundled))
            }
        }
        return tools.sorted { ($0.schema.name, $0.action ?? "") < ($1.schema.name, $1.action ?? "") }
    }

    /// A verb runs as its part, judged by its declared class; its Mac integration switch is the one owning the part's app reach.
    static func answeredTool(part: String, verb: String, entry: JSONValue, permissions: [String], actions: [String], page: String?,
                             reach: ToolReach, bundled: Bool = false) throws -> AuthoredTool {
        guard case .object(let declared) = entry, case .string(let effect)? = declared["class"], case .string(let description)? = declared["description"],
              case .object(var args)? = declared["args"] else {
            throw ToolFailureError("The admitted ability \(part) declares \(verb) without description, class and args.", effects: .none,
                owner: "abilities/\(part).js", instruction: "Repair this ability's answers header before offering its verbs.")
        }
        // A door verb's arguments are closed unless its schema declares them open, as for every native door verb.
        if args["additionalProperties"] == nil { args["additionalProperties"] = .bool(false) }
        let floor = try shippedAnswerFloor.get()[verb]
        let toolClass = max(try answerClass(effect, part: part, verb: verb), floor?.toolClass ?? .read)
        var answer = declared
        if floor?.irreversible == true { answer["irreversible"] = .bool(true) }
        // A shipped seed's verb keeps the seed's app switch whatever reach a revision declares.
        let gate = (floor?.integration ?? integration(of: permissions)).map { MacIntegrationAccess($0, toolClass == .read ? .read : .write) }
        // A verb's capabilities say what its class does where its part reaches: a person-side write changes data outside the app's own.
        let effects: CapabilitySet = switch toolClass {
        case .read: []
        case .write: reach == .person ? [.outsideAppDataWrite] : [.appDataWrite]
        case .send: [.externalSend]
        case .destructive: [.destructive]
        }
        let capabilities = toolClass.baseCapabilities.union(effects)
        return AuthoredTool(schema: LLMToolSchema(name: part, toolClass: toolClass, reach: reach, capabilities: capabilities, macIntegration: gate,
                                                  description: description, parametersJSON: try JSONValue.object(args).serializedData(pretty: false)),
                            permissions: permissions, actions: actions, page: page, action: verb, answer: answer, answering: true, bundled: bundled)
    }

    /// Admission accepts only these four; a header damaged after admission is refused, never read as a write.
    static func answerClass(_ name: String, part: String, verb: String) throws -> ToolClass {
        switch name {
        case "read": return .read
        case "write": return .write
        case "send": return .send
        case "destructive": return .destructive
        default:
            throw ToolFailureError("\(part) declares \(verb) with class \(name); a verb's class is read, write, send or destructive.", effects: .none,
                owner: "abilities/\(part).js", instruction: "Repair this ability's answers header before offering its verbs.")
        }
    }

    /// The one Mac integration a part's app reach names; none when it names no integration app or more than one.
    static func integration(of permissions: [String]) -> String? {
        let apps = Set(permissions.compactMap { permission -> String? in
            let pieces = permission.split(separator: ":", maxSplits: 1).map(String.init)
            return pieces.count == 2 && ["app_read", "app_write"].contains(pieces[0]) ? MacIntegrationID.owning(appBundleID: pieces[1]) : nil
        })
        return apps.count == 1 ? apps.first : nil
    }

    /// A verb the app ships a part for keeps that seed's class, irreversibility and app switch as its floor: a revision may raise them, never lower
    /// them below what the native verb was. Read once from the bundled seeds; an unreadable bundle fails the whole authored catalog, so none of the
    /// agent's parts are offered until the app's own resources read.
    static let shippedAnswerFloor = Result<[String: (toolClass: ToolClass, irreversible: Bool, integration: String?)], any Error> {
        var floor: [String: (toolClass: ToolClass, irreversible: Bool, integration: String?)] = [:]
        for url in try AbilityStore.seedCatalog() {
            let seed = try AbilityStore.decode(url)
            guard case .object(let verbs)? = seed.part["answers"] else { continue }
            let reach: [String] = if case .object(let scope)? = seed.part["reach"], case .array(let names)? = scope["capabilities"] {
                names.compactMap(\.stringValue)
            } else { [] }
            for (verb, entry) in verbs {
                guard case .object(let declared) = entry, case .string(let name)? = declared["class"] else { continue }
                floor[verb] = (try answerClass(name, part: seed.id, verb: verb), declared["irreversible"] == .bool(true), integration(of: reach))
            }
        }
        return floor
    }
}

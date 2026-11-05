import AuthoredCapabilities
import ChatTurnContracts
import Experiences
import CognitiveSubstrate
import Foundation
import StandingBots
import Research
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
// Blueprint: | `SwiftToolDispatcher.swift` | Dispatcher/catalog construction; checked registry revision and selected schema encoding |

// MARK: - SwiftToolDispatcher

/// Integrations bind the originating operation before invoking any backend or retained callback.
public protocol ChatMacIntegrationToolBridge: MacIntegrationToolBridge {
    func serving(turn: Turn, context: MacOperationContext) -> any MacIntegrationToolBridge
}

/// App actions share this catalog and dispatch routes; contributed executors retain their permission and availability checks.
public final class SwiftToolDispatcher: ToolDispatchClient, @unchecked Sendable {
    /// Implementations that still own process-global credentials, app lifecycle, or another live-body singleton. Synthetic roots fail closed instead of
    /// reaching across bodies.
    static let canonicalBodyOnlyToolNames: Set<String> = [
        "restart_app", "image_generate",
    ]

    let allowsCanonicalBodyTools: Bool
    var usesCanonicalBody: Bool { allowsCanonicalBodyTools }

    private struct BuiltInSchemaCacheKey: Hashable {
        let accessFlags: Int
        let standingBotMinimumInterval: TimeInterval?
    }

    let dataRoot: URL
    let pageReader: SwiftNativeResearchClient
    /// Local durable enqueue only: return the accepted request ID after writing, without executing a provider or waiting for a bot run. Supplied by the
    /// runner's app assembly; nil reports unavailable rather than fake success.
    let standingBotSession: BotRunnerSession?
    let standingBotRunEnqueue: (@Sendable (UUID, String?) throws -> BotRunReceipt)?
    /// Exact semantic-memory owner for this dispatcher body. Alternate roots must never fall through to the process-wide production singleton.
    let memoryV2: SwiftNativeMemoryV2
    let knowledgeGraphPath: URL
    let providerLifecycleObserver: (any LLMCallLifecycleObserving)?
    /// The cognition runtime's journal bus; no other dispatcher or global body supplies it.
    let studioJournalBus: StudioJournalCognitiveBus?
    /// Headless contexts have no Mac integration bridge; return bridge_not_wired rather than claim execution.
    public let macIntegrationBridge: (any ChatMacIntegrationToolBridge)?
    /// Permission authority for the Mac integration route. Production uses the shared app-root store; an explicit store keeps a dispatcher assembled for
    /// another root from consulting live permission state.
    let macIntegrationPermissionStore: MacIntegrationPermissionStore
    /// Tools an owner outside Core contributes (the app's browser, pages, health reads): registered in this one catalog and executed there. nil in headless
    /// bodies, which then have none of them.
    let appTools: (any ChatToolExecuting)?
    private let executorDescriptors: [String: ToolDescriptor]
    let agentBridgeConfigRoot: URL?
    let a2aPushConfiguration: (@Sendable (AgentPeerContact) async throws -> JSONValue)?
    /// Rebuildable temporal continuity for the agent-readable screen. This is dispatcher-local perception state, never memory, authority, or a second screen
    /// owner.
    let fourVerbLiveScene = SwiftToolDispatcherFourVerbLiveScene()
    private let builtInSchemaCacheLock = NSLock()
    private var builtInSchemaCache: [BuiltInSchemaCacheKey: [LLMToolSchema]] = [:]

    /// Connector execution context; relative file reads resolve only in the canonical workspace, with an explicit namespace for bundled docs.
    var rootForRead: URL { dataRoot.deletingLastPathComponent().standardizedFileURL }

    /// Requests carry only app; named executors remain behind it or an explicitly declared caller list.
    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        memoryV2: SwiftNativeMemoryV2? = nil,
        knowledgeGraphPath: URL? = nil,
        allowProcessGlobalTools: Bool = true,
        providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        studioJournalBus: StudioJournalCognitiveBus? = nil,
        macIntegrationBridge: (any ChatMacIntegrationToolBridge)? = nil,
        macIntegrationPermissionStore: MacIntegrationPermissionStore? = nil,
        appTools: (any ChatToolExecuting)? = nil,
        agentBridgeConfigRoot: URL? = nil,
        a2aPushConfiguration: (@Sendable (AgentPeerContact) async throws -> JSONValue)? = nil,
        standingBotRunEnqueue: (@Sendable (UUID, String?) throws -> BotRunReceipt)? = nil,
        standingBotSession: BotRunnerSession? = nil
    ) {
        _ = Self.builtInsRegistered
        let descriptors = appTools?.descriptors ?? []
        precondition(Set(descriptors.map(\.name)).isDisjoint(with: Self.nativeCanonicalToolNames),
                     "Contributed tools must not shadow Core tools; declare replacements instead.")
        let replacements = appTools?.replacesCoreTools ?? []
        precondition(replacements.isSubset(of: Self.nativeCanonicalToolNames), "Only registered Core tools can be replaced.")
        self.executorDescriptors = Dictionary(uniqueKeysWithValues:
            (descriptors + replacements.compactMap { Self.nativeToolDescriptors[$0] }).map { ($0.name, $0) })
        AppActionBinding.registerTools(descriptors)
        self.dataRoot = dataRoot
        self.pageReader = SwiftNativeResearchClient(dataRoot: dataRoot)
        self.standingBotRunEnqueue = standingBotRunEnqueue
        self.standingBotSession = standingBotSession
        self.memoryV2 = memoryV2 ?? SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        self.knowledgeGraphPath = knowledgeGraphPath ?? dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        self.allowsCanonicalBodyTools = allowProcessGlobalTools
        self.providerLifecycleObserver = providerLifecycleObserver
        self.studioJournalBus = studioJournalBus
        self.macIntegrationBridge = macIntegrationBridge
        self.macIntegrationPermissionStore = macIntegrationPermissionStore
            ?? (dataRoot == PersistenceCore.defaultDataRoot()
                ? .shared
                : MacIntegrationPermissionStore(dataRoot: dataRoot))
        self.appTools = appTools
        self.agentBridgeConfigRoot = agentBridgeConfigRoot ?? InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        self.a2aPushConfiguration = a2aPushConfiguration
    }

    private func cachedBuiltInToolSchemas(
        includeFullMacFileTools: Bool,
        includeFullMacSystemTools: Bool,
        includeFullMacAccessibilityReadTools: Bool,
        includeFullMacAccessibilityInjectionTools: Bool,
        includeActivityQueryTool: Bool,
        requestedNames: Set<String>? = nil
    ) -> [LLMToolSchema] {
        let accessFlags = (includeFullMacFileTools ? 1 : 0)
            | (includeFullMacSystemTools ? 2 : 0)
            | (includeFullMacAccessibilityReadTools ? 8 : 0)
            | (includeFullMacAccessibilityInjectionTools ? 16 : 0)
            // Include capture preference in cache identity so a toggle cannot serve stale catalog membership.
            | (includeActivityQueryTool ? 32 : 0)
        let key = BuiltInSchemaCacheKey(
            accessFlags: accessFlags,
            standingBotMinimumInterval: BotRunLimits.minimumInterval
        )

        builtInSchemaCacheLock.lock()
        if requestedNames == nil, let cached = builtInSchemaCache[key] {
            builtInSchemaCacheLock.unlock()
            return cached
        }
        builtInSchemaCacheLock.unlock()

        let generated = BuiltInToolSchemaFactory(
            requestedNames: requestedNames,
            standingBotMinimumInterval: key.standingBotMinimumInterval
        ).schemas(
            includeFullMacFileTools: includeFullMacFileTools,
            includeFullMacSystemTools: includeFullMacSystemTools,
            includeFullMacAccessibilityReadTools: includeFullMacAccessibilityReadTools,
            includeFullMacAccessibilityInjectionTools: includeFullMacAccessibilityInjectionTools,
            includeActivityQueryTool: includeActivityQueryTool
        )

        guard requestedNames == nil else { return generated }
        builtInSchemaCacheLock.lock()
        if let cached = builtInSchemaCache[key] {
            builtInSchemaCacheLock.unlock()
            return cached
        }
        if builtInSchemaCache.count >= 64 {
            builtInSchemaCache.remove(at: builtInSchemaCache.startIndex)
        }
        builtInSchemaCache[key] = generated
        builtInSchemaCacheLock.unlock()
        return generated
    }

    public func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        if names == ["app"] {
            return appTools == nil ? [] : executorDescriptors.values.filter { names.contains($0.name) }.map(\.schema)
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
        let builtIn = cachedBuiltInToolSchemas(
            includeFullMacFileTools: access.fileOpsAllowed,
            includeFullMacSystemTools: access.systemAllowed,
            includeFullMacAccessibilityReadTools: access.accessibilityAllowed,
            includeFullMacAccessibilityInjectionTools: access.accessibilityAllowed,
            includeActivityQueryTool: activity,
            requestedNames: schemaNames
        ).filter { usesCanonicalBody || !Self.canonicalBodyOnlyToolNames.contains($0.name) }
        // Authored rows cannot shadow a native route or one of its aliases.
        var names = records.filter { $0.fields["status"] == .string("active") }
            .map(\.id)
            .sorted().filter(Self.isAuthorableToolName)
        var seen = Set(names)
        names.append(contentsOf: (builtIn.map(\.name) + (appTools?.descriptors.map(\.name) ?? []))
            .filter { seen.insert($0).inserted })
        var schemas: [LLMToolSchema] = []
        if includeSchemas {
            let registry = try Self.authoredTools(records: records, named: schemaNames).map(\.schema)
            let combined = builtIn.map { executorDescriptors[$0.name]?.schema ?? $0 } + registry
            schemas = withContributedSchemas(usesCanonicalBody
                ? combined
                : combined.filter { !Self.canonicalBodyOnlyToolNames.contains($0.name) }, named: schemaNames)
        }
        return (names, schemas, access)
    }

    /// Assembly and authored admission reserve every executor-owned name.
    private func withContributedSchemas(_ native: [LLMToolSchema], named names: Set<String>?) -> [LLMToolSchema] {
        guard appTools != nil else { return native }
        precondition(Set(native.map(\.name)).isDisjoint(with: contributedToolNames), "Tool ownership collision in catalog.")
        return native + executorDescriptors.values.filter { contributedToolNames.contains($0.name) && names?.contains($0.name) != false }
            .sorted { $0.name < $1.name }.map(\.schema)
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
            throw ToolFailureError("The agent's tool registry did not read (\(error.localizedDescription)), so '\(tool)' could not be looked up. Nothing ran.",
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

    private static let builtInsRegistered: Void = AppActionBinding.registerTools(Array(nativeToolDescriptors.values))
    package static let reservedBuiltInNames = nativeCanonicalToolNames.union(alwaysOnCoreNames)

    static let registryReservedNames: Set<String> = reservedBuiltInNames

    /// A name a tool the agent writes may take: no built-in executor or current door binding.
    public static func isAuthorableToolName(_ id: String) -> Bool {
        !registryReservedNames.contains(id) && !AppActionBinding.builtInToolName(id)
            && CanonicalToolNameDispatcher.canonical(id) == id
    }

    /// The same, for the `app` door's generated `authored.<id>` actions, with the primitive permissions and app dependencies each declares. The store's lock
    /// and canonical revision cover local and external changes. A failed read is not memoized; the key is read before the catalog walk.
    package static func authoredTools(dataRoot: URL) -> [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)] {
        switch checkedAuthoredTools(dataRoot: dataRoot) {
        case .success(let tools): return tools
        case .failure: return [] // Unreadable authority offers no executable actions.
        }
    }

    /// Inventory readers retain the fault; execution discovery stays fail-closed.
    package static func checkedAuthoredTools(dataRoot: URL) -> Result<[(schema: LLMToolSchema, permissions: [String], actions: [String],
        page: String?, action: String?)], any Error> {
        checkedAuthoredCatalog(dataRoot: dataRoot).map(\.tools)
    }

    /// One checked source snapshot supplies callable contracts and exact stable IDs.
    package struct AuthoredCatalog: Sendable {
        package let tools: [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)]
        package let aliases: [String: String]
    }

    package static func checkedAuthoredCatalog(dataRoot: URL) -> Result<AuthoredCatalog, any Error> {
        AbilityStore.withLock {
            let revision: [String]
            do { revision = try AbilityStore(dataRoot: dataRoot).revision() } catch {
                RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .act, operation: "abilities.tool_registry", owner: "abilities",
                               words: """
                                   The agent's tool registry's revision did not read (\(error.localizedDescription)); the agent's own tools are not offered \
                                   until it reads again.
                                   """)
                return .failure(error)
            }
            let key = (dataRoot.path, revision, AppActionBinding.registeredToolCount)
            if let memo = authoredToolsMemo, memo.key == key { return .success(memo.catalog) }
            return authoredRegistry(dataRoot: dataRoot).flatMap { records in
                Result {
                var aliases: [String: String] = [:]
                for record in records { aliases[record.id] = record.id }
                let catalog = try AuthoredCatalog(tools: authoredTools(records: records), aliases: aliases)
                authoredToolsMemo = (key, catalog)
                return catalog
                }
            }
        }
    }
    nonisolated(unsafe) private static var authoredToolsMemo: (key: (String, [String], Int),
        catalog: AuthoredCatalog)?

    static func authoredTools(records: [ToolRecord], named names: Set<String>? = nil) throws -> [(schema: LLMToolSchema, permissions: [String],
        actions: [String], page: String?, action: String?)] {
        let active = records
            .filter { $0.fields["status"] == .string("active") && $0.fields["disabledBy"] != .string("owner") }
        var tools: [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)] = []
        for row in active {
            let id = row.id
            guard names?.contains(id) != false, isAuthorableToolName(id) else { continue }
            guard row.fields["language"] == .string("javascript") else { continue }
            guard let digest = row.codeFingerprint, !digest.isEmpty,
                  case .object(let admission)? = row.fields["admission"], admission["candidate"] == .string(digest) else { continue }
            guard case .object(let schemaObject)? = row.fields["inputSchema"], schemaObject["type"] == .string("object") else {
                throw ToolFailureError("The admitted ability \(id) has no valid object inputSchema.", effects: .none,
                    owner: "abilities/\(id).js", instruction: "Repair and validate this ability's parameter declaration before offering it as a tool.")
            }
            let schemaData = try JSONValue.object(schemaObject).serializedData(pretty: false)
            let page: String? = if case .object(let face)? = row.fields["face"], case .string(let page)? = face["page"] { page } else { nil }
            let action: String? = if case .object(let face)? = row.fields["face"], case .string(let action)? = face["action"] { action } else { nil }
            let permissions = row.permissions ?? []
            let reach = PermissionLaw.reach(ofPermissions: permissions)
            let toolClass = permissions.map(PermissionLaw.permissionClass).max() ?? (schemaObject["readOnly"] == .bool(true) ? .read : .write)
            tools.append((LLMToolSchema(name: id, toolClass: toolClass, reach: reach,
                                       capabilities: ["tool_call", "safe_read"], description: row.description, parametersJSON: schemaData),
                          permissions, row.actions ?? [],
                          page, action))
        }
        return tools.sorted { $0.schema.name < $1.schema.name }
    }
}

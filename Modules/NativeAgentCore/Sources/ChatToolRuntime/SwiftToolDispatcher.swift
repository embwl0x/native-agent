import AuthoredCapabilities
import Experiences
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
// Blueprint: | `SwiftToolDispatcher.swift` | Native dispatcher construction; capability-filtered schema factory owns native catalog membership; authored projections share AbilityStore's checked ToolRecord projection and exact catalog revision; named schema construction consumes parsed registry rows and selects before encoding |

// MARK: - SwiftToolDispatcher

/// Native ToolDispatchClient for built-in Swift tools and registered tools.
/// Tools contributed by an app executor share this catalog
/// and run in that executor, including the Core tools it explicitly replaces.
/// Chat exposes `app`; its actions reach the underlying dispatch routes, whose
/// permission and availability checks still apply.
public final class SwiftToolDispatcher: ToolDispatchClient, @unchecked Sendable {
    /// Implementations that still own process-global credentials, app
    /// lifecycle, or another live-body singleton. Synthetic roots fail closed
    /// instead of reaching across bodies.
    static let canonicalBodyOnlyToolNames: Set<String> = [
        "restart_app", "agent_swarm", "image_generate",
    ]

    let allowsCanonicalBodyTools: Bool
    var usesCanonicalBody: Bool { allowsCanonicalBodyTools }

    private struct BuiltInSchemaCacheKey: Hashable {
        let accessFlags: Int
        let standingBotMinimumInterval: TimeInterval
    }

    let dataRoot: URL
    let pageReader: SwiftNativeResearchClient
    /// Local durable enqueue only: return the accepted request ID after writing,
    /// without executing a provider or waiting for a bot run. Supplied by the
    /// runner's app assembly; nil reports unavailable rather than fake success.
    let standingBotSession: BotRunnerSession?
    let standingBotRunEnqueue: (@Sendable (UUID, String?) throws -> BotRunReceipt)?
    /// Exact semantic-memory owner for this dispatcher body. Alternate roots
    /// must never fall through to the process-wide production singleton.
    let memoryV2: SwiftNativeMemoryV2
    /// Exact KG projection belonging to `dataRoot`.
    let knowledgeGraphPath: URL
    let swarmChatFactory: any SwarmChatClientFactory
    let providerLifecycleObserver: (any LLMCallLifecycleObserving)?
    /// Parent conversation approval projection reused by inherited swarm
    /// workers. It adds no authority; it only preserves the ordinary CONFIRM
    /// path for the originating surface.
    let swarmApprovalFiler: (any ApprovalFiler)?
    /// App-injected bridge for Mac integration backends (EventKit / notify /
    /// Spotlight). nil in headless contexts — dispatch surfaces a
    /// `bridge_not_wired` error envelope to the LLM in that case.
    public let macIntegrationBridge: (any MacIntegrationToolBridge)?
    /// Permission authority for the Mac integration route. Production uses the
    /// shared app-root store; an explicit store keeps a dispatcher assembled
    /// for another root from consulting live permission state.
    let macIntegrationPermissionStore: MacIntegrationPermissionStore
    /// Tools an owner outside Core contributes (the app's browser, pages,
    /// health reads): registered in this one catalog and
    /// executed there. nil in headless bodies, which then have none of them.
    let appTools: (any ToolExecutor)?
    private let executorDescriptors: [String: ToolDescriptor]
    let agentBridgeConfigRoot: URL?
    let a2aPushConfiguration: (@Sendable (AgentPeerContact) async -> JSONValue?)?
    /// Rebuildable temporal continuity for the agent-readable screen. This is
    /// dispatcher-local perception state, never memory, authority, or a second
    /// screen owner.
    let fourVerbLiveScene = SwiftToolDispatcherFourVerbLiveScene()
    private let builtInSchemaCacheLock = NSLock()
    private var builtInSchemaCache: [BuiltInSchemaCacheKey: [LLMToolSchema]] = [:]

    /// Source-repository anchor for the legacy relative-path allowlist.
    /// resolveTrustedFilePath also accepts workspace aliases, bundled docs,
    /// workspace-relative paths and absolute paths under trusted roots.
    var rootForRead: URL { dataRoot.deletingLastPathComponent().standardizedFileURL }

    /// Her requests carry one tool, `app` (docs/TOOL_LOADING.md); every
    /// other tool here is reached by name through it, or by a lane with its
    /// own declared list.
    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        memoryV2: SwiftNativeMemoryV2? = nil,
        knowledgeGraphPath: URL? = nil,
        allowProcessGlobalTools: Bool = true,
        providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        swarmApprovalFiler: (any ApprovalFiler)? = nil,
        macIntegrationBridge: (any MacIntegrationToolBridge)? = nil,
        macIntegrationPermissionStore: MacIntegrationPermissionStore? = nil,
        appTools: (any ToolExecutor)? = nil,
        agentBridgeConfigRoot: URL? = nil,
        a2aPushConfiguration: (@Sendable (AgentPeerContact) async -> JSONValue?)? = nil,
        standingBotRunEnqueue: (@Sendable (UUID, String?) throws -> BotRunReceipt)? = nil,
        standingBotSession: BotRunnerSession? = nil,
        swarmChatFactory: any SwarmChatClientFactory
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
            .appendingPathComponent("knowledge_graph.json")
        self.allowsCanonicalBodyTools = allowProcessGlobalTools
        self.swarmChatFactory = swarmChatFactory
        self.providerLifecycleObserver = providerLifecycleObserver
        self.swarmApprovalFiler = swarmApprovalFiler
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
            // W7 — the activity-capture toggle is part of the cache identity.
            // Without this bit a catalog built while capture was OFF would be
            // served after the user turned it ON (and vice versa), which is the
            // exact class of staleness the toggle exists to prevent.
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

    public func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        if names == ["app"] {
            return appTools == nil ? [] : executorDescriptors.values.filter { names.contains($0.name) }.map(\.schema)
        }
        return await catalogSnapshot(includeSchemas: true, schemaNames: names).schemas
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        await catalogSnapshot(includeSchemas: true).schemas
    }

    func catalogSnapshot(includeSchemas: Bool, schemaNames: Set<String>? = nil, surface: String = "chat") async -> (names: [String], schemas: [LLMToolSchema], access: FullMacToolAccess) {
        let records = readRegistryRecords()
        let access = await fullMacToolAccess(surface: surface)
        let activity = await activityCaptureEnabled()
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
            let registry = Self.authoredTools(records: records, named: schemaNames).map(\.schema)
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

    /// Names of the contributed tools this catalog actually offers.
    var contributedToolNames: Set<String> {
        executorOwnedToolNames.subtracting(Self.nativeCanonicalToolNames)
    }

    /// Every name an executor answers: its own tools and the Core tools it
    /// runs in their place.
    var executorOwnedToolNames: Set<String> {
        appTools == nil ? [] : Set(executorDescriptors.keys)
    }

    public func listAvailableTools() async throws -> [String] {
        await catalogSnapshot(includeSchemas: false).names
    }

    func registryToolRecord(_ tool: String) throws -> [String: JSONValue]? {
        let rows: [ToolRecord]
        switch Self.authoredRegistry(dataRoot: dataRoot) {
        case .success(let read): rows = read
        case .failure(let error):
            throw ToolFailureError("Her tool registry did not read (\(error.localizedDescription)), so '\(tool)' could not be looked up. Nothing ran.",
                                   effects: .none, owner: "abilities")
        }
        for row in rows where row.id == tool { return row.fields }
        return nil
    }

    private func readRegistryRecords() -> [ToolRecord] { Self.readRegistryRecords(dataRoot: dataRoot) }

    private static func readRegistryRecords(dataRoot: URL) -> [ToolRecord] {
        guard case .success(let rows) = authoredRegistry(dataRoot: dataRoot) else { return [] }
        return rows
    }

    /// Her authored tool registry, or the fault that kept it from reading.
    /// A fault is never an empty registry: the catalog offers none of her
    /// tools while it lasts, and her home owes the repair until a read works.
    static func authoredRegistry(dataRoot: URL) -> Result<[ToolRecord], any Error> {
        do {
            let rows = try AbilityStore(dataRoot: dataRoot).checkedToolRecords()
            RepairOwed.settle(dataRoot, operation: "abilities.tool_registry", evidence: .init(source: "abilities", id: UUID().uuidString))
            return .success(rows)
        } catch {
            RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .act, operation: "abilities.tool_registry", owner: "abilities",
                           words: "Her tool registry did not read (\(error.localizedDescription)); her own tools are not offered until it reads again.")
            return .failure(error)
        }
    }

    /// Canonical built-in dispatch names stay reserved regardless of gate state;
    /// authored tools cannot shadow them or their dotted alias spellings.
    static let nativeCanonicalToolNames = Set(nativeToolDescriptors.keys)

    /// Registered with the policy registry once, the first time a dispatcher is made.
    private static let builtInsRegistered: Void = AppActionBinding.registerTools(Array(nativeToolDescriptors.values))
    package static let reservedBuiltInNames = nativeCanonicalToolNames.union(alwaysOnCoreNames)

    /// Registry ownership must also reserve accepted alias spellings, but the
    /// public built-in inventory remains canonical so catalogs and eval-ledger
    /// enumeration do not advertise every compatibility spelling as a second
    /// tool surface.
    static let registryReservedNames: Set<String> = {
        let dottedAliases = Set(nativeCanonicalToolNames
            .filter { $0.contains("_") }
            .map { $0.replacingOccurrences(of: "_", with: ".") })
        return reservedBuiltInNames.union(dottedAliases)
    }()

    /// A name a tool she writes may take: no built-in's (or its dotted
    /// spelling), nothing an alias rewrites.
    public static func isAuthorableToolName(_ id: String) -> Bool {
        !registryReservedNames.contains(id) && !AppActionBinding.builtInToolName(id)
            && CanonicalToolNameDispatcher.canonical(id) == id
    }

    /// The same, for the `app` door's generated `authored.<id>` actions, with
    /// the primitive permissions and app dependencies each declares.
    /// The store's lock and canonical revision cover local and external changes.
    /// A failed read is not memoized; the key is read before the catalog walk.
    package static func authoredTools(dataRoot: URL) -> [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)] {
        switch checkedAuthoredTools(dataRoot: dataRoot) {
        case .success(let tools): return tools
        case .failure: return [] // Unreadable authority offers no executable actions.
        }
    }

    /// Inventory readers retain the fault; execution discovery stays fail-closed.
    package static func checkedAuthoredTools(dataRoot: URL) -> Result<[(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)], any Error> {
        checkedAuthoredCatalog(dataRoot: dataRoot).map(\.tools)
    }

    /// One checked source snapshot supplies both callable contracts and the
    /// id/name aliases their dependencies can name. No alias reads the store again.
    package struct AuthoredCatalog: Sendable {
        package let tools: [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)]
        package let aliases: [String: String]
    }

    package static func checkedAuthoredCatalog(dataRoot: URL) -> Result<AuthoredCatalog, any Error> {
        AbilityStore.withLock {
            let revision: [String]
            do { revision = try AbilityStore(dataRoot: dataRoot).revision() } catch {
                RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .act, operation: "abilities.tool_registry", owner: "abilities",
                               words: "Her tool registry's revision did not read (\(error.localizedDescription)); her own tools are not offered until it reads again.")
                return .failure(error)
            }
            let key = (dataRoot.path, revision, AppActionBinding.registeredToolCount)
            if let memo = authoredToolsMemo, memo.key == key { return .success(memo.catalog) }
            return authoredRegistry(dataRoot: dataRoot).map { records in
                var aliases: [String: String] = [:]
                for record in records where aliases[record.name.lowercased()] == nil {
                    aliases[record.name.lowercased()] = record.id
                }
                for record in records { aliases[record.id.lowercased()] = record.id }
                let catalog = AuthoredCatalog(tools: authoredTools(records: records), aliases: aliases)
                authoredToolsMemo = (key, catalog)
                return catalog
            }
        }
    }
    nonisolated(unsafe) private static var authoredToolsMemo: (key: (String, [String], Int),
        catalog: AuthoredCatalog)?

    static func authoredTools(records: [ToolRecord], named names: Set<String>? = nil) -> [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)] {
        let active = records
            .filter { $0.fields["status"] == .string("active") && $0.fields["disabledBy"] != .string("owner") }
        var tools: [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)] = []
        for row in active {
            let id = row.id
            guard names?.contains(id) != false, isAuthorableToolName(id) else { continue }
            guard row.fields["language"] == .string("javascript") else { continue }
            guard let digest = row.codeFingerprint, !digest.isEmpty,
                  case .object(let admission)? = row.fields["admission"], admission["candidate"] == .string(digest) else { continue }
            let schemaObject: [String: JSONValue] = if case .object(let schema)? = row.fields["inputSchema"] {
                schema
            } else { ["type": .string("object")] }
            guard let schemaData = try? JSONSerialization.data(withJSONObject: JSONValue.object(schemaObject).foundationObject,
                                                               options: [.sortedKeys]) else {
                continue
            }
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

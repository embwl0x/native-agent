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
import MCPDispatcher
import ProviderRouting
import ToolRegistry
import TrustCenter
import KnowledgeGraph
import XConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

// MARK: - SwiftToolDispatcher

/// Native ToolDispatchClient for built-in Swift tools, registered tools and
/// mounted MCP tools. Tools contributed by an app executor share this catalog
/// and run in that executor, including the Core tools it explicitly replaces.
/// Chat exposes `app`; its actions reach the underlying dispatch routes, whose
/// permission and availability checks still apply.
public final class SwiftToolDispatcher: ToolDispatchClient, @unchecked Sendable {
    /// Implementations that still own process-global credentials, app
    /// lifecycle, or another live-body singleton. Synthetic roots fail closed
    /// instead of reaching across bodies.
    static let canonicalBodyOnlyToolNames: Set<String> = [
        "restart_app", "agent_swarm", "image_generate",
        "market_status", "market_watchlists", "tradingview_watchlist", "market_quote",
        "x_status", "x_me", "x_search", "x_timeline", "x_user_tweets",
        "slack_status", "slack_list_channels", "slack_search_messages", "slack_post_message",
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
    let swarmExecutor: (any AgentSwarmExecuting)?
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

    /// Sandbox anchor for read/list tools. All caller paths resolve under
    /// this URL — the SOURCE-REPO root (= dataRoot's parent in both dev
    /// and bundled-with-REPO_PATH cases).
    ///
    /// Why parent-of-dataRoot:
    ///   - dev: defaultDataRoot() walks up looking for <repo>/data — so
    ///     dataRoot = <repo>/data and .parent = <repo>. SOUL.md, AGENTS.md,
    ///     VOICE.md, GROWTH.md, USER.md all live FLAT at <repo>/persona/*.
    ///   - bundled install with stamped REPO_PATH: defaultDataRoot() step
    ///     2 returns <stampedRepo>/data — so .parent = stampedRepo, same
    ///     layout as dev.
    ///   - bundled AppSupport fallback (NO repo stamp): dataRoot is
    ///     ~/Library/Application Support/NativeAgent (no /data suffix);
    ///     .parent gives ~/Library/Application Support/ which has nothing
    ///     in the allow-list — every read fails closed. That's fine: it's
    ///     a degenerate setup where no source content exists anyway.
    ///
    /// An earlier patch this turn anchored at dataRoot directly (allow-list
    /// = data/-subdirs) which could only see split data-root mirrors instead
    /// of the active persona root — Agent correctly flagged the "two tools,
    /// two roots" seam in her telegram diagnostic.
    /// One tool used PersonaRootResolver (which walks to repo), the other
    /// stayed at dataRoot. Same root for both = one canonical answer.
    var rootForRead: URL { dataRoot.deletingLastPathComponent().standardizedFileURL }

    /// Her requests carry one tool, `app` (docs/TOOL_LOADING.md); every
    /// other tool here is reached by name through it, or by a lane with its
    /// own declared list.
    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        memoryV2: SwiftNativeMemoryV2? = nil,
        knowledgeGraphPath: URL? = nil,
        allowProcessGlobalTools: Bool = true,
        swarmExecutor: (any AgentSwarmExecuting)? = nil,
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
        self.swarmExecutor = swarmExecutor
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

        let generated = builtInToolSchemas(
            includeFullMacFileTools: includeFullMacFileTools,
            includeFullMacSystemTools: includeFullMacSystemTools,
            includeFullMacAccessibilityReadTools: includeFullMacAccessibilityReadTools,
            includeFullMacAccessibilityInjectionTools: includeFullMacAccessibilityInjectionTools,
            includeActivityQueryTool: includeActivityQueryTool,
            standingBotMinimumInterval: key.standingBotMinimumInterval,
            requestedNames: requestedNames
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

    // context_expand is ALWAYS catalogued (2026-09-01). These three walks used
    // to drop it whenever the current packet carried no expandable pointers,
    // which made the advertised contract — and the cached prompt prefix —
    // change shape between turns for a reason the model never asked about. It
    // is in alwaysOnCoreNames; the floor does not move. With nothing to
    // expand, impl_context_expand says so at dispatch, which costs one tool
    // result instead of a whole prefix rewrite.
    public func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        if names == ["app"] {
            return appTools == nil ? [] : executorDescriptors.values.filter { names.contains($0.name) }.map(\.schema)
        }
        return await catalogSnapshot(includeSchemas: true, schemaNames: names).schemas
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        await catalogSnapshot(includeSchemas: true).schemas
    }

    func catalogSnapshot(includeSchemas: Bool, schemaNames: Set<String>? = nil) async -> (names: [String], schemas: [LLMToolSchema], hiddenMCPNames: Set<String>, externalMCPNames: [String]) {
        let records = readRegistryRecords()
        let access = await fullMacToolAccess()
        let activity = await activityCaptureEnabled()
        if includeSchemas { MCPToolCatalogWarmer.shared.kickDetached(dataRoot: dataRoot) }
        let mcp = MCPToolBridge.listMCPTools(dataRoot: dataRoot)
        let names = availableToolNames(records: records, access: access, activity: activity, mcpNames: mcp.map(\.bridgedName))
        var schemas: [LLMToolSchema] = []
        if includeSchemas {
            let builtIn = cachedBuiltInToolSchemas(
                includeFullMacFileTools: access.fileOpsAllowed,
                includeFullMacSystemTools: access.systemAllowed,
                includeFullMacAccessibilityReadTools: access.accessibilityAllowed,
                includeFullMacAccessibilityInjectionTools: access.accessibilityAllowed,
                includeActivityQueryTool: activity,
                requestedNames: schemaNames
            ).map { executorDescriptors[$0.name]?.schema ?? $0 }
            let registry = Self.authoredTools(records: records, named: schemaNames).map(\.schema)
            let combined = builtIn + registry + Self.mcpToolSchemas(mcp.filter {
                $0.serverId != "nativeagent-internal" && schemaNames?.contains($0.bridgedName) != false
            })
            schemas = withContributedSchemas(usesCanonicalBody
                ? combined
                : combined.filter { !Self.canonicalBodyOnlyToolNames.contains($0.name) }, named: schemaNames)
        }
        return (names, schemas, Set(mcp.filter { $0.serverId == "nativeagent-internal" }.map(\.bridgedName)),
                mcp.filter { $0.serverId != "nativeagent-internal" }.map(\.bridgedName))
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

    static func extractSessionId(from input: [String: JSONValue]) -> String {
        for key in ["__session_id", "session_id", "sessionId"] {
            if case .string(let s) = input[key] ?? .null {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    public func listAvailableTools() async throws -> [String] {
        await catalogSnapshot(includeSchemas: false).names
    }

    private func availableToolNames(records: [JSONRow], access: FullMacToolAccess, activity: Bool, mcpNames: [String]) -> [String] {
        // Registry discovery may never advertise a spelling that dispatch
        // resolves to a native/MCP route. Otherwise a disabled built-in such
        // as `shell`, or a dotted alias such as `desk.read`, can leak back
        // into the catalog from registry.json even though its custom manifest
        // can never own the call.
        var names = records
            .filter { $0.fields["status"] == .string("active") }
            .compactMap { (try? $0.string("id")) ?? (try? $0.string("name")) }
            .sorted().filter(Self.isAuthorableToolName)
        // Built-in Swift dispatch-table names always surface, even if
        // No authored ability files exist on fresh installs.
        let existing0 = Set(names)
        names.append(contentsOf: Self.builtInToolNames.filter { !existing0.contains($0) })
        if access.fileOpsAllowed {
            let existing = Set(names)
            names.append(contentsOf: Self.fullMacFileToolNames.filter { !existing.contains($0) })
            let existingBuilder = Set(names)
            names.append(contentsOf: Self.fullMacBuilderToolNames.filter { !existingBuilder.contains($0) })
            let existingRestart = Set(names)
            names.append(contentsOf: Self.fullMacRestartToolNames.filter { !existingRestart.contains($0) })
        }
        if access.systemAllowed {
            let existing = Set(names)
            names.append(contentsOf: Self.fullMacSystemToolNames.filter { !existing.contains($0) })
        }
        if access.accessibilityAllowed {
            let existing = Set(names)
            names.append(contentsOf: Self.fullMacAccessibilityReadToolNames.filter { !existing.contains($0) })
            // fable51 item 30 — the clipboard READ rides the same access
            // signal as the perception reads: it changes nothing and needs the
            // accessibility category plus an active Full Mac window.
            names.append(contentsOf: Self.macClipboardReadToolNames.filter { !existing.contains($0) })
            // fable51 item 29 — the menu WALK is perception on the same signal.
            names.append(contentsOf: Self.macMenuReadToolNames.filter { !existing.contains($0) })
            // fable51 item 33 — the READ organ rides the same signal: it walks
            // the same AX tree and moves a viewport it puts back. When the
            // caller names a `path`, dispatch requires file_ops ON TOP — but
            // the tool itself is reachable at read tier, because its ordinary
            // use is "read what is in front of me" and that needs no file
            // authority at all.
            names.append(contentsOf: Self.macReadToolNames.filter { !existing.contains($0) })
        }
        // fable51 item 30 — the clipboard WRITE rides app control, not the read
        // tier: it replaces what the next paste anywhere will produce.
        if access.accessibilityAllowed {
            let existing = Set(names)
            names.append(contentsOf: Self.macClipboardWriteToolNames.filter { !existing.contains($0) })
            // fable51 item 29 — the menu PRESS runs the app's own handler.
            names.append(contentsOf: Self.macMenuPressToolNames.filter { !existing.contains($0) })
        }
        // W2/W3 — INJECTION. Same category, act tier. Catalog visibility here
        // is not authority: dispatch re-checks the category and MacControl
        // still requires the active Full Mac window AND a body-bound injection
        // capability before a single event is emitted. Standard modes obtain
        // it through approved replay; admitted YOLO obtains it directly for
        // the exact checked call without a per-call prompt.
        if access.accessibilityAllowed {
            let existing = Set(names)
            names.append(contentsOf: Self.fullMacAccessibilityInjectionToolNames.filter { !existing.contains($0) })
        }
        // W7 — activity_query surfaces ONLY when the Trust Center capture
        // toggle is on. Catalog and dispatch must agree: advertising a tool
        // whose every call refuses teaches the model to keep trying it, and
        // advertising it at all when capture is off would tell the model this
        // Mac records activity when it does not.
        if activity {
            let existing = Set(names)
            names.append(contentsOf: Self.activityQueryToolNames.filter { !existing.contains($0) })
        }
        // Surface configured MCP servers' tools under the bridged
        // `mcp__<server>__<tool>` convention. Dispatch for these names routes
        // through SwiftNativeMCPDispatcher.callToolLive for stdio servers.
        if !mcpNames.isEmpty {
            // De-dup: a registry.json entry shadowing a bridged name wins.
            let existing = Set(names)
            names.append(contentsOf: mcpNames.filter { !existing.contains($0) })
            names.sort()
        }
        if !usesCanonicalBody {
            names.removeAll { Self.canonicalBodyOnlyToolNames.contains($0) }
        }
        let existingNames = Set(names)
        names.append(contentsOf: (appTools?.descriptors.map(\.name) ?? []).filter { !existingNames.contains($0) })
        return names
    }

    func registryToolRecord(_ tool: String) throws -> [String: JSONValue]? {
        let rows: [JSONValue]
        switch Self.authoredRegistry(dataRoot: dataRoot) {
        case .success(let read): rows = read
        case .failure(let error):
            throw ToolFailureError("Her tool registry did not read (\(error.localizedDescription)), so '\(tool)' could not be looked up. Nothing ran.",
                                   effects: .none, owner: "abilities")
        }
        for case .object(let row) in rows {
            let name: JSONValue? = if case .string? = row["id"] { row["id"] } else { row["name"] }
            if name == .string(tool) { return row }
        }
        return nil
    }

    private func readRegistryRecords() -> [JSONRow] { Self.readRegistryRecords(dataRoot: dataRoot) }

    private static func readRegistryRecords(dataRoot: URL) -> [JSONRow] {
        guard case .success(let rows) = authoredRegistry(dataRoot: dataRoot) else { return [] }
        let records = rows.compactMap { try? JSONRow($0) }
        return records.count == rows.count ? records : []
    }

    /// Her authored tool registry, or the fault that kept it from reading.
    /// A fault is never an empty registry: the catalog offers none of her
    /// tools while it lasts, and her home owes the repair until a read works.
    static func authoredRegistry(dataRoot: URL) -> Result<[JSONValue], any Error> {
        do {
            let registry = try AbilityStore(dataRoot: dataRoot).registry(kind: .tool)
            guard case .array(let rows) = registry else { throw CocoaError(.fileReadCorruptFile) }
            RepairOwed.settle(dataRoot, operation: "abilities.tool_registry", evidence: .init(source: "abilities", id: UUID().uuidString))
            return .success(rows)
        } catch {
            RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .act, operation: "abilities.tool_registry", owner: "abilities",
                           words: "Her tool registry did not read (\(error.localizedDescription)); her own tools are not offered until it reads again.")
            return .failure(error)
        }
    }

    /// R9 (review finding 2): the FULL built-in dispatch namespace — every
    /// name the dispatch switch or the fullMac catch-alls can match,
    /// regardless of which gates are currently open. Registry custom tools
    /// may never shadow these: the switch matches built-ins first, so a
    /// registry schema under a built-in name would advertise behavior
    /// dispatch can't deliver (e.g. a custom "shell" schema while Full Mac
    /// is off).
    /// Canonical native names: kept as given by alias resolution, and their
    /// dotted spellings are reserved from registry names so a custom `desk.read`
    /// can never sit beside the built-in `desk_read` as a look-alike.
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
    /// spelling), no `mcp__` bridge name, nothing an alias rewrites.
    public static func isAuthorableToolName(_ id: String) -> Bool {
        !registryReservedNames.contains(id) && !AppActionBinding.builtInToolName(id)
            && !id.hasPrefix("mcp__") && CanonicalToolNameDispatcher.canonical(id) == id
    }

    /// The same, for the `app` door's generated `authored.<id>` actions, with
    /// the primitive permissions and app dependencies each declares.
    /// The store's lock and canonical revision cover local and external changes.
    /// A failed read is not memoized; the key is read before the catalog walk.
    package static func authoredTools(dataRoot: URL) -> [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)] {
        AbilityStore.withLock {
            let revision: [String]
            do { revision = try AbilityStore(dataRoot: dataRoot).revision() } catch {
                RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .act, operation: "abilities.tool_registry", owner: "abilities",
                               words: "Her tool registry's revision did not read (\(error.localizedDescription)); her own tools are not offered until it reads again.")
                return []
            }
            let key = (dataRoot.path, revision, AppActionBinding.registeredToolCount)
            if let memo = authoredToolsMemo, memo.key == key { return memo.tools }
            guard case .success(let rows) = authoredRegistry(dataRoot: dataRoot) else { return [] }
            let records = rows.compactMap { try? JSONRow($0) }
            guard records.count == rows.count else { return [] }
            let tools = authoredTools(records: records)
            authoredToolsMemo = (key, tools)
            return tools
        }
    }
    nonisolated(unsafe) private static var authoredToolsMemo: (key: (String, [String], Int),
        tools: [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)])?

    private static func authoredTools(records: [JSONRow], named names: Set<String>? = nil) -> [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)] {
        let active = records
            .filter { $0.fields["status"] == .string("active") && $0.fields["disabledBy"] != .string("owner") }
        var tools: [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)] = []
        // mcp__-prefixed ids are excluded too: dispatch's default case parses
        // that prefix as an MCP bridge name BEFORE consulting the registry, so
        // a registry schema under it would advertise a route that never fires.
        for row in active {
            guard let id = (try? row.string("id")) ?? (try? row.string("name")),
                  names?.contains(id) != false, isAuthorableToolName(id) else { continue }
            guard row.fields["language"] == .string("javascript") else { continue }
            guard let digest = try? row.string("codeFingerprint"), !digest.isEmpty,
                  case .object(let admission)? = row.fields["admission"], admission["candidate"] == .string(digest) else { continue }
            let description = (try? row.string("description"))
                ?? "Custom registry tool \(id)."
            let schemaObject: [String: JSONValue] = if case .object(let schema)? = row.fields["inputSchema"] {
                schema
            } else { ["type": .string("object")] }
            guard let schemaData = try? JSONSerialization.data(withJSONObject: JSONValue.object(schemaObject).foundationValue,
                                                               options: [.sortedKeys]) else {
                continue
            }
            let page: String? = if case .object(let face)? = row.fields["face"], case .string(let page)? = face["page"] { page } else { nil }
            let action: String? = if case .object(let face)? = row.fields["face"], case .string(let action)? = face["action"] { action } else { nil }
            tools.append((LLMToolSchema(name: id, description: description, parametersJSON: schemaData),
                          (try? row.strings("permissions")) ?? [], (try? row.strings("actions")) ?? [],
                          page, action))
        }
        return tools.sorted { $0.schema.name < $1.schema.name }
    }
}

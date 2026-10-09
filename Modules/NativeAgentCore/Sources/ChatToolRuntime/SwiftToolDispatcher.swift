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
        let requestedNames: [String]?
        let standingBotMinimumInterval: TimeInterval
    }

    let dataRoot: URL
    let pageReader: any ResearchClientProtocol
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
    /// Test-only observation of the default swarm provider assembly. It never
    /// replaces the provider client or alters an agent_swarm execution.
    let swarmProviderAssemblyObserver: (@Sendable (SwarmProviderAssembly) -> Void)?
    /// Test-only observation of the inherited worker chat factory's Codex
    /// environment. The default worker remains the ordinary chat factory.
    let swarmWorkerCodexEnvironmentObserver: (@Sendable ([String: String]?) -> Void)?
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
    /// App-injected bridge for the self-evolution chat tools (propose / status
    /// / self_install). nil in headless / restricted contexts — dispatch
    /// surfaces a `bridge_not_wired` error envelope to the LLM in that case.
    public let evolutionBridge: (any EvolutionToolBridge)?
    /// Tools an owner outside Core contributes (the app's browser, pages,
    /// health reads): registered in this one catalog and
    /// executed there. nil in headless bodies, which then have none of them.
    private let appToolPort: (any ToolExecutor)?
    /// A swarm worker sees Core's own catalog only, as it did before the
    /// app's tools joined it (`AgentSwarmInheritedToolScope`).
    @TaskLocal static var withoutAppTools = false
    var appTools: (any ToolExecutor)? { Self.withoutAppTools ? nil : appToolPort }
    let agentBridgeConfigRoot: URL?
    let a2aPushConfiguration: (@Sendable (AgentPeerContact) async -> JSONValue?)?
    let codexMessageNotificationPermissionOverride: Bool?
    let codexMessageWakeupHelperOverride: URL?
    let codexMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)?
    let ompMessageWakeupHelperOverride: URL?
    let ompMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)?
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
        pageReader: (any ResearchClientProtocol)? = nil,
        memoryV2: SwiftNativeMemoryV2? = nil,
        knowledgeGraphPath: URL? = nil,
        allowProcessGlobalTools: Bool = true,
        swarmExecutor: (any AgentSwarmExecuting)? = nil,
        swarmProviderAssemblyObserver: (@Sendable (SwarmProviderAssembly) -> Void)? = nil,
        swarmWorkerCodexEnvironmentObserver: (@Sendable ([String: String]?) -> Void)? = nil,
        providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        swarmApprovalFiler: (any ApprovalFiler)? = nil,
        macIntegrationBridge: (any MacIntegrationToolBridge)? = nil,
        macIntegrationPermissionStore: MacIntegrationPermissionStore? = nil,
        evolutionBridge: (any EvolutionToolBridge)? = nil,
        appTools: (any ToolExecutor)? = nil,
        agentBridgeConfigRoot: URL? = nil,
        a2aPushConfiguration: (@Sendable (AgentPeerContact) async -> JSONValue?)? = nil,
        codexMessageNotificationPermissionOverride: Bool? = nil,
        codexMessageWakeupHelperOverride: URL? = nil,
        codexMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)? = nil,
        ompMessageWakeupHelperOverride: URL? = nil,
        ompMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)? = nil,
        standingBotRunEnqueue: (@Sendable (UUID, String?) throws -> BotRunReceipt)? = nil,
        standingBotSession: BotRunnerSession? = nil,
        swarmChatFactory: any SwarmChatClientFactory
    ) {
        self.dataRoot = dataRoot
        self.pageReader = pageReader ?? SwiftNativeResearchClient(dataRoot: dataRoot)
        self.standingBotRunEnqueue = standingBotRunEnqueue
        self.standingBotSession = standingBotSession
        self.memoryV2 = memoryV2 ?? SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        self.knowledgeGraphPath = knowledgeGraphPath ?? dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("knowledge_graph.json")
        self.allowsCanonicalBodyTools = allowProcessGlobalTools
        self.swarmExecutor = swarmExecutor
        self.swarmChatFactory = swarmChatFactory
        self.swarmProviderAssemblyObserver = swarmProviderAssemblyObserver
        self.swarmWorkerCodexEnvironmentObserver = swarmWorkerCodexEnvironmentObserver
        self.providerLifecycleObserver = providerLifecycleObserver
        self.swarmApprovalFiler = swarmApprovalFiler
        self.macIntegrationBridge = macIntegrationBridge
        self.macIntegrationPermissionStore = macIntegrationPermissionStore
            ?? (dataRoot == PersistenceCore.defaultDataRoot()
                ? .shared
                : MacIntegrationPermissionStore(dataRoot: dataRoot))
        self.evolutionBridge = evolutionBridge
        self.appToolPort = appTools
        self.agentBridgeConfigRoot = agentBridgeConfigRoot ?? InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        self.a2aPushConfiguration = a2aPushConfiguration
        self.codexMessageNotificationPermissionOverride = codexMessageNotificationPermissionOverride
        self.codexMessageWakeupHelperOverride = codexMessageWakeupHelperOverride
        self.codexMessageWakeupOverride = codexMessageWakeupOverride
        self.ompMessageWakeupHelperOverride = ompMessageWakeupHelperOverride
        self.ompMessageWakeupOverride = ompMessageWakeupOverride
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
            requestedNames: requestedNames.map { $0.sorted() },
            standingBotMinimumInterval: BotRunLimits.minimumInterval
        )

        builtInSchemaCacheLock.lock()
        if let cached = builtInSchemaCache[key] {
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
            requestedNames: requestedNames,
            standingBotMinimumInterval: key.standingBotMinimumInterval
        )

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
            return appTools?.descriptors.filter { names.contains($0.name) }.map(\.schema) ?? []
        }
        return try await listAvailableToolSchemas().filter { names.contains($0.name) }
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        let access = await fullMacToolAccess()
        let builtIn = cachedBuiltInToolSchemas(
            includeFullMacFileTools: access.fileOpsAllowed,
            includeFullMacSystemTools: access.systemAllowed,
            includeFullMacAccessibilityReadTools: access.accessibilityReadAllowed,
            includeFullMacAccessibilityInjectionTools: access.accessibilityInjectionAllowed,
            includeActivityQueryTool: await activityCaptureEnabled()
        )
        // R9: registry custom-tool schemas ride the eager catalog. Built-in
        // names win on collision — provider APIs reject duplicate tool names,
        // and the dispatch switch matches built-in cases first anyway.
        let builtInNames = Set(builtIn.map(\.name))
        let registry = registryToolSchemas().filter { !builtInNames.contains($0.name) }
        let combined = builtIn + registry + mcpToolSchemas()
        return withContributedSchemas(usesCanonicalBody
            ? combined
            : combined.filter { !Self.canonicalBodyOnlyToolNames.contains($0.name) })
    }

    /// Contributed schemas follow Core's own, and a Core, registry or MCP
    /// name always wins: one name, one tool.
    private func withContributedSchemas(_ native: [LLMToolSchema]) -> [LLMToolSchema] {
        guard let appTools else { return native }
        let existing = Set(native.map(\.name))
        return native + appTools.descriptors.map(\.schema).filter {
            !existing.contains($0.name)
        }
    }

    /// Names of the contributed tools this catalog actually offers.
    var contributedToolNames: Set<String> {
        Set(appTools?.descriptors.map(\.name) ?? [])
    }

    /// Every name an executor answers: its own tools and the Core tools it
    /// runs in their place.
    var executorOwnedToolNames: Set<String> {
        contributedToolNames.union(appTools?.replacesCoreTools ?? [])
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
        // Registry discovery may never advertise a spelling that dispatch
        // resolves to a native/MCP route. Otherwise a disabled built-in such
        // as `shell`, or a dotted alias such as `desk.read`, can leak back
        // into the catalog from registry.json even though its custom manifest
        // can never own the call.
        var names = readRegistryRecords()
            .filter { ($0["status"] as? String) == "active" }
            .compactMap { $0["id"] as? String ?? $0["name"] as? String }
            .sorted().filter {
                !Self.registryReservedNames.contains($0) && !$0.hasPrefix("mcp__")
                    && CanonicalToolNameDispatcher.canonical($0) == $0
            }
        // Built-in Swift dispatch-table names always surface, even if
        // data/tools/registry.json is missing or empty (fresh installs).
        let existing0 = Set(names)
        names.append(contentsOf: Self.builtInToolNames.filter { !existing0.contains($0) })
        let access = await fullMacToolAccess()
        if access.fileOpsAllowed {
            let existing = Set(names)
            names.append(contentsOf: Self.fullMacFileToolNames.filter { !existing.contains($0) })
            let existingBuilder = Set(names)
            names.append(contentsOf: Self.fullMacBuilderToolNames.filter { !existingBuilder.contains($0) })
            let existingRestart = Set(names)
            names.append(contentsOf: Self.fullMacRestartToolNames.filter { !existingRestart.contains($0) })
            let existingEvolution = Set(names)
            names.append(contentsOf: Self.fullMacEvolutionToolNames.filter { !existingEvolution.contains($0) })
        }
        if access.systemAllowed {
            let existing = Set(names)
            names.append(contentsOf: Self.fullMacSystemToolNames.filter { !existing.contains($0) })
        }
        // W1b — READ-ONLY accessibility perception. Same category, read tier;
        // surfaced under its own access flag so a future read/act split moves
        // this block without touching app control.
        if access.accessibilityReadAllowed {
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
        if access.appControlAllowed {
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
        if access.accessibilityInjectionAllowed {
            let existing = Set(names)
            names.append(contentsOf: Self.fullMacAccessibilityInjectionToolNames.filter { !existing.contains($0) })
        }
        // W7 — activity_query surfaces ONLY when the Trust Center capture
        // toggle is on. Catalog and dispatch must agree: advertising a tool
        // whose every call refuses teaches the model to keep trying it, and
        // advertising it at all when capture is off would tell the model this
        // Mac records activity when it does not.
        if await activityCaptureEnabled() {
            let existing = Set(names)
            names.append(contentsOf: Self.activityQueryToolNames.filter { !existing.contains($0) })
        }
        // Surface configured MCP servers' tools under the bridged
        // `mcp__<server>__<tool>` convention. Dispatch for these names routes
        // through SwiftNativeMCPDispatcher.callToolLive for stdio servers.
        let mcpNames = MCPToolBridge.listMCPToolNames(dataRoot: dataRoot)
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

    // R9: internal (not private) — the dispatch route in
    // SwiftToolDispatcher+Dispatch.swift consults registry membership too.
    func readRegistryNames() -> [String] {
        readRegistryRecords().compactMap { $0["id"] as? String ?? $0["name"] as? String }.sorted()
    }

    private func readRegistryRecords() -> [[String: Any]] { Self.readRegistryRecords(dataRoot: dataRoot) }

    private static func readRegistryRecords(dataRoot: URL) -> [[String: Any]] {
        let path = dataRoot
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("registry.json")
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        if let arr = parsed as? [[String: Any]] {
            return arr
        }
        if let obj = parsed as? [String: Any] {
            if let arr = obj["tools"] as? [[String: Any]] {
                return arr
            }
            // Object keyed by tool id — synthesize minimal records.
            return obj.keys.sorted().map { ["id": $0] }
        }
        return []
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
    static let nativeCanonicalToolNames: Set<String> = Set(builtInToolNames)
        .union(fullMacAccessibilityReadToolNames)
        .union(activityQueryToolNames)
        .union(fullMacAccessibilityInjectionToolNames)
        .union(macClipboardToolNames)
        .union(macMenuToolNames)
        .union(macReadToolNames)

    package static let reservedBuiltInNames: Set<String> = Set(builtInToolNames)
        .union(alwaysOnCoreNames)
        .union(fullMacFileToolNames)
        .union(fullMacSystemToolNames)
        .union(fullMacAccessibilityReadToolNames)
        .union(activityQueryToolNames)
        .union(fullMacAccessibilityInjectionToolNames)
        .union(fullMacBuilderToolNames)
        .union(fullMacRestartToolNames)
        .union(fullMacEvolutionToolNames)
        .union(macClipboardToolNames)
        .union(macMenuToolNames)
        .union(macReadToolNames)

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

    /// R9 (review finding 3): the chat lane requires a signed tool. Returns
    /// the codeFingerprint from the registry record, falling back to the
    /// active manifest — nil/empty means unsigned and dispatch fails closed.
    func registryToolFingerprint(_ tool: String) -> String? {
        if let record = readRegistryRecords().first(where: {
            ($0["id"] as? String ?? $0["name"] as? String) == tool
        }), let fp = record["codeFingerprint"] as? String, !fp.isEmpty {
            return fp
        }
        let manifestURL = dataRoot
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("active", isDirectory: true)
            .appendingPathComponent(tool, isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let fp = manifest["codeFingerprint"] as? String, !fp.isEmpty else {
            return nil
        }
        return fp
    }

    /// R9: schemas for custom tools promoted into `data/tools/registry.json`.
    /// Registry names were already catalog-visible via `readRegistryNames()`,
    /// but with no schema and no dispatch route the LLM could see and load a
    /// custom tool yet never call it — the activation gap. Built from each
    /// ACTIVE tool's `tools/active/<id>/manifest.json`
    /// (description/inputSchema); non-active entries are not discoverable.
    func registryToolSchemas() -> [LLMToolSchema] { Self.authoredTools(dataRoot: dataRoot).map(\.schema) }

    /// A name a tool she writes may take: no built-in's (or its dotted
    /// spelling), no `mcp__` bridge name, nothing an alias rewrites.
    public static func isAuthorableToolName(_ id: String) -> Bool {
        !registryReservedNames.contains(id) && !id.hasPrefix("mcp__") && CanonicalToolNameDispatcher.canonical(id) == id
    }

    /// The same, for the `app` door's generated `authored.<id>` actions, with
    /// the permissions each declares (its action's flags come from them).
    package static func authoredTools(dataRoot: URL) -> [(schema: LLMToolSchema, permissions: [String])] {
        let activeIds = readRegistryRecords(dataRoot: dataRoot)
            .filter { ($0["status"] as? String) == "active" }
            .compactMap { $0["id"] as? String ?? $0["name"] as? String }
        guard !activeIds.isEmpty else { return [] }
        let activeRoot = dataRoot
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("active", isDirectory: true)
        var tools: [(schema: LLMToolSchema, permissions: [String])] = []
        // mcp__-prefixed ids are excluded too: dispatch's default case parses
        // that prefix as an MCP bridge name BEFORE consulting the registry, so
        // a registry schema under it would advertise a route that never fires.
        for id in Set(activeIds).sorted() where isAuthorableToolName(id) {
            let manifestURL = activeRoot
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            let description = (manifest["description"] as? String)
                ?? "Custom registry tool \(id)."
            let schemaObject = (manifest["inputSchema"] as? [String: Any]) ?? ["type": "object"]
            guard let schemaData = try? JSONSerialization.data(withJSONObject: schemaObject, options: [.sortedKeys]) else {
                continue
            }
            tools.append((LLMToolSchema(name: id, description: description, parametersJSON: schemaData),
                          manifest["permissions"] as? [String] ?? []))
        }
        return tools
    }
}

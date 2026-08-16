import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

// MARK: - SwiftToolDispatcher (minimal default)

/// Minimal SwiftNative ToolDispatchClient used when the convenience factory
/// must auto-construct a tool surface from the runtime alone. It enumerates
/// tool ids from `<dataRoot>/tools/registry.json` (best-effort) and, on
/// dispatch, currently refuses with a clear "not yet wired in Swift" error.
/// The chat path tolerates this: the tool loop only fires if the LLM emits a
/// tool call, and the dispatcher's deny is recorded as a tool-result error
/// rather than tearing down the turn.
public final class SwiftToolDispatcher: ToolDispatchClient, ActiveToolsStoreProviding, @unchecked Sendable {
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
    }

    let dataRoot: URL
    public let activeToolsStore: ActiveToolsStore
    /// Exact semantic-memory owner for this dispatcher body. Alternate roots
    /// must never fall through to the process-wide production singleton.
    let memoryV2: SwiftNativeMemoryV2
    /// Exact KG projection belonging to `dataRoot`.
    let knowledgeGraphPath: URL
    let swarmExecutor: (any AgentSwarmExecuting)?
    let providerLifecycleObserver: (any LLMCallLifecycleObserving)?
    /// Parent conversation approval projection reused by inherited swarm
    /// workers. It adds no authority; it only preserves the ordinary CONFIRM
    /// path for the originating surface.
    let swarmApprovalFiler: (any ApprovalFiler)?
    /// App-injected bridge for Mac integration backends (EventKit / notify /
    /// Spotlight). nil in headless contexts — dispatch surfaces a
    /// `bridge_not_wired` error envelope to the LLM in that case.
    public let macIntegrationBridge: (any MacIntegrationToolBridge)?
    /// App-injected bridge for the self-evolution chat tools (propose / status
    /// / self_install). nil in headless / restricted contexts — dispatch
    /// surfaces a `bridge_not_wired` error envelope to the LLM in that case.
    public let evolutionBridge: (any EvolutionToolBridge)?
    let agentBridgeConfigRoot: URL?
    let codexMessageNotificationPermissionOverride: Bool?
    let codexMessageWakeupHelperOverride: URL?
    let codexMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)?
    let claudeMessageWakeupHelperOverride: URL?
    let claudeMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)?
    let ompMessageWakeupHelperOverride: URL?
    let ompMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)?
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

    /// Lazy-tool-loading: schemas always shipped to the LLM every turn.
    /// Discovery (tool_catalog/list_tools/tool_load/tool_unload) plus the
    /// memory/skill/clock primitives. Everything else is loaded on demand
    /// via `tool_load(session_id:..., names:[...])`. See
    /// docs/build_plans/lazy-tool-skill-loading.md.
    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        activeToolsStore: ActiveToolsStore? = nil,
        memoryV2: SwiftNativeMemoryV2? = nil,
        knowledgeGraphPath: URL? = nil,
        allowProcessGlobalTools: Bool = true,
        swarmExecutor: (any AgentSwarmExecuting)? = nil,
        providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        swarmApprovalFiler: (any ApprovalFiler)? = nil,
        macIntegrationBridge: (any MacIntegrationToolBridge)? = nil,
        evolutionBridge: (any EvolutionToolBridge)? = nil,
        agentBridgeConfigRoot: URL? = nil,
        codexMessageNotificationPermissionOverride: Bool? = nil,
        codexMessageWakeupHelperOverride: URL? = nil,
        codexMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)? = nil,
        claudeMessageWakeupHelperOverride: URL? = nil,
        claudeMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)? = nil,
        ompMessageWakeupHelperOverride: URL? = nil,
        ompMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)? = nil
    ) {
        self.dataRoot = dataRoot
        self.activeToolsStore = activeToolsStore
            ?? (dataRoot == PersistenceCore.defaultDataRoot()
                ? .shared
                : ActiveToolsStore(dataRoot: dataRoot))
        self.memoryV2 = memoryV2 ?? SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        self.knowledgeGraphPath = knowledgeGraphPath ?? dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("knowledge_graph.json")
        self.allowsCanonicalBodyTools = allowProcessGlobalTools
        self.swarmExecutor = swarmExecutor
        self.providerLifecycleObserver = providerLifecycleObserver
        self.swarmApprovalFiler = swarmApprovalFiler
        self.macIntegrationBridge = macIntegrationBridge
        self.evolutionBridge = evolutionBridge
        self.agentBridgeConfigRoot = agentBridgeConfigRoot
        self.codexMessageNotificationPermissionOverride = codexMessageNotificationPermissionOverride
        self.codexMessageWakeupHelperOverride = codexMessageWakeupHelperOverride
        self.codexMessageWakeupOverride = codexMessageWakeupOverride
        self.claudeMessageWakeupHelperOverride = claudeMessageWakeupHelperOverride
        self.claudeMessageWakeupOverride = claudeMessageWakeupOverride
        self.ompMessageWakeupHelperOverride = ompMessageWakeupHelperOverride
        self.ompMessageWakeupOverride = ompMessageWakeupOverride
    }

    private func cachedBuiltInToolSchemas(
        includeFullMacFileTools: Bool,
        includeFullMacSystemTools: Bool,
        includeFullMacAppTools: Bool,
        includeFullMacAccessibilityReadTools: Bool,
        includeFullMacAccessibilityInjectionTools: Bool,
        includeActivityQueryTool: Bool,
        requestedNames: Set<String>? = nil
    ) -> [LLMToolSchema] {
        let accessFlags = (includeFullMacFileTools ? 1 : 0)
            | (includeFullMacSystemTools ? 2 : 0)
            | (includeFullMacAppTools ? 4 : 0)
            | (includeFullMacAccessibilityReadTools ? 8 : 0)
            | (includeFullMacAccessibilityInjectionTools ? 16 : 0)
            // W7 — the activity-capture toggle is part of the cache identity.
            // Without this bit a catalog built while capture was OFF would be
            // served after the user turned it ON (and vice versa), which is the
            // exact class of staleness the toggle exists to prevent.
            | (includeActivityQueryTool ? 32 : 0)
        let key = BuiltInSchemaCacheKey(
            accessFlags: accessFlags,
            requestedNames: requestedNames.map { $0.sorted() }
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
            includeFullMacAppTools: includeFullMacAppTools,
            includeFullMacAccessibilityReadTools: includeFullMacAccessibilityReadTools,
            includeFullMacAccessibilityInjectionTools: includeFullMacAccessibilityInjectionTools,
            includeActivityQueryTool: includeActivityQueryTool,
            requestedNames: requestedNames
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

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        let access = await fullMacToolAccess()
        var builtIn = cachedBuiltInToolSchemas(
            includeFullMacFileTools: access.fileOpsAllowed,
            includeFullMacSystemTools: access.systemAllowed,
            includeFullMacAppTools: access.appControlAllowed,
            includeFullMacAccessibilityReadTools: access.accessibilityReadAllowed,
            includeFullMacAccessibilityInjectionTools: access.accessibilityInjectionAllowed,
            includeActivityQueryTool: activityCaptureEnabled()
        )
        if FluidContextToolScope.current?.packet.expandablePointers.isEmpty != false {
            builtIn.removeAll { $0.name == "context_expand" }
        }
        // R9: registry custom-tool schemas ride the eager catalog. Built-in
        // names win on collision — provider APIs reject duplicate tool names,
        // and the dispatch switch matches built-in cases first anyway.
        let builtInNames = Set(builtIn.map(\.name))
        let registry = registryToolSchemas().filter { !builtInNames.contains($0.name) }
        let combined = builtIn + registry + mcpToolSchemas()
        return usesCanonicalBody
            ? combined
            : combined.filter { !Self.canonicalBodyOnlyToolNames.contains($0.name) }
    }

    /// Lazy-tool-loading overload. When `activeTools` is non-nil the returned
    /// schemas are filtered to `alwaysOnCoreNames ∪ activeTools` (plus MCP).
    /// nil preserves the eager catalog for Tools-tab UI and other legacy
    /// callers. See docs/build_plans/lazy-tool-skill-loading.md.
    public func listAvailableToolSchemas(activeTools: Set<String>?) async throws -> [LLMToolSchema] {
        guard let activeTools else {
            return try await listAvailableToolSchemas()
        }
        let access = await fullMacToolAccess()
        let allowed = Self.alwaysOnCoreNames.union(activeTools)
        var builtIn = cachedBuiltInToolSchemas(
            includeFullMacFileTools: access.fileOpsAllowed,
            includeFullMacSystemTools: access.systemAllowed,
            includeFullMacAppTools: access.appControlAllowed,
            includeFullMacAccessibilityReadTools: access.accessibilityReadAllowed,
            includeFullMacAccessibilityInjectionTools: access.accessibilityInjectionAllowed,
            includeActivityQueryTool: activityCaptureEnabled(),
            requestedNames: allowed
        )
        if FluidContextToolScope.current?.packet.expandablePointers.isEmpty != false {
            builtIn.removeAll { $0.name == "context_expand" }
        }
        // R9: registry custom tools are lazy — schemas appear only once the
        // session has tool_load'ed them (never in the always-on core).
        let builtInNames = Set(builtIn.map(\.name))
        let registry = registryToolSchemas().filter {
            !builtInNames.contains($0.name) && activeTools.contains($0.name)
        }
        let combined = builtIn + registry + mcpToolSchemas()
        return usesCanonicalBody
            ? combined
            : combined.filter { !Self.canonicalBodyOnlyToolNames.contains($0.name) }
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
        var names = readRegistryNames()
        // Built-in Swift dispatch-table names always surface, even if
        // data/tools/registry.json is missing or empty (fresh installs).
        let existing0 = Set(names)
        names.append(contentsOf: Self.builtInToolNames.filter { !existing0.contains($0) })
        if FluidContextToolScope.current?.packet.expandablePointers.isEmpty != false {
            names.removeAll { $0 == "context_expand" }
        }
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
        if access.appControlAllowed {
            let existing = Set(names)
            names.append(contentsOf: Self.fullMacAppToolNames.filter { !existing.contains($0) })
        }
        // W1b — READ-ONLY accessibility perception. Same category, read tier;
        // surfaced under its own access flag so a future read/act split moves
        // this block without touching app control.
        if access.accessibilityReadAllowed {
            let existing = Set(names)
            names.append(contentsOf: Self.fullMacAccessibilityReadToolNames.filter { !existing.contains($0) })
            // W7 — mac_nudge rides the SAME access signal deliberately: one
            // bare mouse move needs the accessibility category and an active
            // Full Mac window, and nothing above that.
            names.append(contentsOf: Self.fullMacNudgeToolNames.filter { !existing.contains($0) })
        }
        // W2/W3 — INJECTION. Same category, act tier. Catalog visibility here
        // is not authority: dispatch re-checks the category and MacControl
        // still requires the active Full Mac window AND the approval
        // attestation before a single event is emitted.
        if access.accessibilityInjectionAllowed {
            let existing = Set(names)
            names.append(contentsOf: Self.fullMacAccessibilityInjectionToolNames.filter { !existing.contains($0) })
        }
        // W7 — activity_query surfaces ONLY when the Trust Center capture
        // toggle is on. Catalog and dispatch must agree: advertising a tool
        // whose every call refuses teaches the model to keep trying it, and
        // advertising it at all when capture is off would tell the model this
        // Mac records activity when it does not.
        if activityCaptureEnabled() {
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
        return names
    }

    // R9: internal (not private) — the dispatch route in
    // SwiftToolDispatcher+Dispatch.swift consults registry membership too.
    func readRegistryNames() -> [String] {
        readRegistryRecords().compactMap { $0["id"] as? String ?? $0["name"] as? String }.sorted()
    }

    private func readRegistryRecords() -> [[String: Any]] {
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
    static let reservedBuiltInNames: Set<String> = Set(builtInToolNames)
        .union(alwaysOnCoreNames)
        .union(fullMacFileToolNames)
        .union(fullMacSystemToolNames)
        .union(fullMacAppToolNames)
        .union(fullMacAccessibilityReadToolNames)
        .union(fullMacNudgeToolNames)
        .union(activityQueryToolNames)
        .union(fullMacAccessibilityInjectionToolNames)
        .union(fullMacBuilderToolNames)
        .union(fullMacRestartToolNames)
        .union(fullMacEvolutionToolNames)

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
    /// (description/inputSchema); non-active registry entries stay name-only
    /// so the model isn't handed a schema for a tool that will refuse to run.
    func registryToolSchemas() -> [LLMToolSchema] {
        let activeIds = readRegistryRecords()
            .filter { ($0["status"] as? String) == "active" }
            .compactMap { $0["id"] as? String ?? $0["name"] as? String }
        guard !activeIds.isEmpty else { return [] }
        let activeRoot = dataRoot
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("active", isDirectory: true)
        var schemas: [LLMToolSchema] = []
        // mcp__-prefixed ids are excluded too: dispatch's default case parses
        // that prefix as an MCP bridge name BEFORE consulting the registry, so
        // a registry schema under it would advertise a route that never fires.
        for id in Set(activeIds).sorted()
        where !Self.reservedBuiltInNames.contains(id) && !id.hasPrefix("mcp__") {
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
            guard let schemaData = try? JSONSerialization.data(withJSONObject: schemaObject) else {
                continue
            }
            schemas.append(LLMToolSchema(name: id, description: description, parametersJSON: schemaData))
        }
        return schemas
    }
}

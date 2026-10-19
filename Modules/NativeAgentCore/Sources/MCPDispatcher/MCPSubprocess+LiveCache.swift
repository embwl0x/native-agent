import Foundation
import NativeAgentCore
import PersistenceCore
import Research
import KnowledgeGraph
import CapabilityFoundry

// 2026-09-06: server IDs are registry-local, including subprocess ownership.
private final class MCPRegistryPools: @unchecked Sendable {
    static let shared = MCPRegistryPools()
    private let lock = NSLock()
    private var pools: [String: MCPSubprocessPool] = [:]

    func pool(for root: URL) -> MCPSubprocessPool {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        lock.lock()
        defer { lock.unlock() }
        if let pool = pools[key] { return pool }
        let pool = MCPSubprocessPool()
        pools[key] = pool
        return pool
    }

    func allPools() -> [MCPSubprocessPool] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pools.values)
    }
}

private actor MCPHTTPRegistryTransports {
    static let shared = MCPHTTPRegistryTransports()
    private struct Row {
        let identity: String
        let transport: MCPHTTPTransport
    }
    private var configurations: [String: [String: String]] = [:]
    private var rows: [String: [String: Row]] = [:]

    private func registryKey(_ root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func reconcile(servers: [MCPServer], root: URL) async {
        let key = registryKey(root)
        var identities: [String: String] = [:]
        for server in servers where server.transport == "http" && server.id != "searxng-local" {
            identities[server.id] = try? server.executionIdentity()
        }
        configurations[key] = identities
        var retired: [MCPHTTPTransport] = []
        for (id, row) in rows[key] ?? [:] where identities[id] != row.identity {
            rows[key]?[id] = nil
            retired.append(row.transport)
        }
        for transport in retired { await transport.close() }
    }

    func transport(for server: MCPServer, endpoint: URL, root: URL) throws -> MCPHTTPTransport {
        let key = registryKey(root)
        let identity = try server.executionIdentity()
        guard configurations[key]?[server.id] == identity else {
            throw MCPDispatcherError.malformedResponse("MCP server changed before HTTP dispatch; refresh the connection")
        }
        if let row = rows[key]?[server.id], row.identity == identity { return row.transport }
        let transport = MCPHTTPTransport(serverId: server.id, endpoint: endpoint)
        rows[key, default: [:]][server.id] = Row(identity: identity, transport: transport)
        return transport
    }

    func stop(serverId: String, root: URL) async {
        if let row = rows[registryKey(root)]?.removeValue(forKey: serverId) {
            await row.transport.close()
        }
    }

    func stopAll() async {
        let retired = rows.values.flatMap { $0.values.map(\.transport) }
        rows.removeAll()
        for transport in retired { await transport.close() }
    }
}

// MARK: - Cached live MCP queries on the SwiftNative dispatcher

/// 60-second TTL cache row. Matches the daemon's behavior of stamping a
/// `cache/tools.json` entry on every successful `list_mcp_tools` call.
private struct MCPLiveCacheRow: Sendable {
    let storedAt: Date
    let value: [JSONValue]
}

/// Orders disk publications across dispatcher instances. Reserving an ordinal
/// does not invalidate a fetch: only a closure that actually fetches activates it.
private actor MCPToolsCachePublications {
    static let shared = MCPToolsCachePublications()
    private var nextGeneration: UInt64 = 0
    private var latest: [String: UInt64] = [:]

    func reserve() -> UInt64 {
        nextGeneration += 1
        return nextGeneration
    }

    func begin(key: String, generation: UInt64) {
        latest[key] = max(latest[key] ?? 0, generation)
    }

    func isCurrent(key: String, generation: UInt64) -> Bool {
        latest[key] == generation
    }
}

/// Process-wide cache for `listToolsLive` / `listResourcesLive`. Keyed by
/// registry, query kind and server implementation. An actor serializes refills.
public actor MCPLiveCache {
    public static let shared = MCPLiveCache()
    private var rows: [String: MCPLiveCacheRow] = [:]
    /// Concurrent misses share one request per key.
    private var inflight: [String: Task<[JSONValue], Error>] = [:]
    /// A force refresh reserves its generation before awaiting cancellation;
    /// older callers may return a result but cannot overwrite the current slot.
    private var keyGenerations: [String: UUID] = [:]
    private let ttl: TimeInterval = 60

    public init() {}

    private func pruneExpiredRows() {
        let now = Date()
        rows = rows.filter { now.timeIntervalSince($0.value.storedAt) <= ttl }
    }

    func get(_ key: String) -> [JSONValue]? {
        pruneExpiredRows()
        guard let row = rows[key] else { return nil }
        return row.value
    }

    func put(_ key: String, value: [JSONValue]) {
        pruneExpiredRows()
        rows[key] = MCPLiveCacheRow(storedAt: Date(), value: value)
    }

    /// Return a fresh value, join an existing refill, or start one request.
    func getOrFill(
        _ key: String,
        fill: @escaping @Sendable () async throws -> [JSONValue]
    ) async throws -> [JSONValue] {
        try Task.checkCancellation()
        if let hit = get(key) { return hit }
        if let existing = inflight[key] {
            return try await Self.cancellableValue(existing)
        }
        let task = Task<[JSONValue], Error> {
            try await fill()
        }
        inflight[key] = task
        // Clear only our task on either outcome, allowing retry after failure.
        do {
            let value = try await Self.cancellableValue(task)
            // A force refresh may have replaced us during the await.
            if let current = inflight[key], current == task {
                inflight[key] = nil
                put(key, value: value)
            }
            return value
        } catch {
            if let current = inflight[key], current == task {
                inflight[key] = nil
            }
            throw error
        }
    }

    /// Bypass the cached value, cancel and drain a pending refill, and publish
    /// only if this generation still owns the key after each suspension.
    func forceFill(
        _ key: String,
        fill: @escaping @Sendable () async throws -> [JSONValue]
    ) async throws -> [JSONValue] {
        try Task.checkCancellation()
        pruneExpiredRows()
        let myGen = UUID()
        keyGenerations[key] = myGen
        defer {
            if keyGenerations[key] == myGen { keyGenerations[key] = nil }
        }

        if let existing = inflight[key] {
            existing.cancel()
            if let current = inflight[key], current == existing {
                inflight[key] = nil
            }
            // Drain even when cancellation fails to interrupt the request.
            _ = try? await existing.value
        }

        // A superseded caller can return its result without publishing it.
        try Task.checkCancellation()
        if keyGenerations[key] != myGen {
            return try await fill()
        }

        let myTask = Task<[JSONValue], Error> {
            try await fill()
        }
        inflight[key] = myTask
        // Check both generation and task identity for cleanup and publication.
        defer {
            if keyGenerations[key] == myGen,
               let current = inflight[key], current == myTask {
                inflight[key] = nil
            }
        }
        let value = try await Self.cancellableValue(myTask)
        if keyGenerations[key] == myGen,
           let current = inflight[key], current == myTask {
            put(key, value: value)
        }
        return value
    }

    // 2026-09-06: Stop must reach the shared fetch, including pagination.
    // Other waiters observe the cancellation and may retry a fresh refill.
    private static func cancellableValue(_ task: Task<[JSONValue], Error>) async throws -> [JSONValue] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            task.cancel()
        }
    }

}

extension SwiftNativeMCPDispatcher {
    // 2026-09-06: equal server IDs in different registries/implementations must
    // not share a catalog or an in-flight fetch. Length framing avoids path/ID
    // delimiter collisions without restricting valid filesystem paths.
    private func liveCacheKey(kind: String, server: MCPServer, executionIdentity: String, pool: MCPSubprocessPool?) -> String {
        Self.cacheIdentity([
            root.standardizedFileURL.resolvingSymlinksInPath().path, kind, server.id,
            executionIdentity,
            pool.map { String(describing: ObjectIdentifier($0)) } ?? "shared",
        ])
    }

    private static func cacheIdentity(_ parts: [String]) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// Live stdio or generic HTTP discovery, cached for 60 seconds. Built-in
    /// bridges retain their dedicated catalogs. `cached: false` forces discovery.
    public func listToolsLive(
        forServer serverId: String,
        cached: Bool = true,
        pool: MCPSubprocessPool? = nil
    ) async throws -> [JSONValue] {
        try await listCatalogLive(kind: "tools", serverId: serverId, cached: cached, pool: pool)
    }

    /// Live `resources/list` with the same transport and caching contract.
    public func listResourcesLive(
        forServer serverId: String,
        cached: Bool = true,
        pool: MCPSubprocessPool? = nil
    ) async throws -> [JSONValue] {
        try await listCatalogLive(kind: "resources", serverId: serverId, cached: cached, pool: pool)
    }

    private func listCatalogLive(
        kind: String, serverId: String, cached: Bool, pool: MCPSubprocessPool?
    ) async throws -> [JSONValue] {
        let servers = try await listServers()
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw MCPDispatcherError.serverNotFound(serverId)
        }
        guard server.transport == "stdio" || (server.transport == "http" && server.id != "searxng-local") else {
            return try await kind == "tools"
                ? cachedToolJSON(forServer: serverId)
                : cachedResourcesJSON(forServer: serverId)
        }
        let expectedIdentity = try server.executionIdentity()
        let cacheKey = liveCacheKey(kind: kind, server: server, executionIdentity: expectedIdentity, pool: pool)
        let publicationKey = Self.cacheIdentity([toolsCachePath.standardizedFileURL.path, serverId])
        let generation = kind == "tools" ? await MCPToolsCachePublications.shared.reserve() : nil
        let request: @Sendable () async throws -> [JSONValue]
        if server.transport == "stdio" {
            let activePool: MCPSubprocessPool
            if let p = pool { activePool = p }
            else { activePool = await Self.ensurePool(for: servers, root: root) }
            request = {
                let proc = try await activePool.get(serverId: serverId)
                guard proc.executionIdentity == expectedIdentity,
                      try server.executionIdentity() == expectedIdentity else {
                    throw MCPDispatcherError.malformedResponse("MCP implementation changed before catalog discovery")
                }
                return try await MCPHTTPTransport.collectCatalogPages(key: kind, serverId: serverId) { params in
                    try await proc.request(method: "\(kind)/list", params: params)
                }
            }
        } else {
            let transport = try await genericHTTPTransport(for: server)
            request = {
                try await kind == "tools" ? transport.listTools() : transport.listResources()
            }
        }
        // Only a tools round-trip may publish the model's on-disk catalog;
        // memory hits and superseded fetches must not replace it.
        let didFetch = generation == nil ? nil : _MCPLiveFetchFlag()
        let fetch: @Sendable () async throws -> [JSONValue] = {
            didFetch?.mark()
            if let generation {
                await MCPToolsCachePublications.shared.begin(key: publicationKey, generation: generation)
            }
            return try await request()
        }
        let items = try await cached
            ? MCPLiveCache.shared.getOrFill(cacheKey, fill: fetch)
            : MCPLiveCache.shared.forceFill(cacheKey, fill: fetch)
        if let generation, didFetch?.value == true {
            try await persistToolsCache(
                serverId: serverId, tools: items,
                publicationKey: publicationKey, generation: generation
            )
        }
        return items
    }

    /// Force a live `tools/list` handshake and stamp `mcp/cache/tools.json`.
    /// Returns the descriptor count that landed in the cache.
    ///
    /// F-B3: the entry point for a startup / server-add warm sweep. Without a
    /// caller of this (or of `listToolsLive`) an stdio server stays invisible
    /// to the model — which is exactly the state the app shipped in.
    @discardableResult
    public func refreshToolsCache(
        forServer serverId: String,
        pool: MCPSubprocessPool? = nil
    ) async throws -> Int {
        // `listToolsLive(cached: false)` always performs a real round-trip and
        // stamps the cache on the way out — no second write needed here.
        try await listToolsLive(forServer: serverId, cached: false, pool: pool).count
    }

    /// Merge one server's live descriptors into `mcp/cache/tools.json`.
    /// The path lock spans the whole read-modify-write across instances; the
    /// refresh ordinal prevents an older same-server result replacing a newer one.
    private func persistToolsCache(
        serverId: String, tools: [JSONValue], publicationKey: String, generation: UInt64
    ) async throws {
        let path = toolsCachePath
        let persistence = persistence
        let stamp = Self.isoTimestamp(Date())
        do {
            try await persistence.withFileLock(path) {
                let existing = try await persistence.readJSON(path, ifMissing: .object([:]))
                var dict: [String: JSONValue]
                if case .object(let obj) = existing { dict = obj } else { dict = [:] }
                guard await MCPToolsCachePublications.shared.isCurrent(
                    key: publicationKey, generation: generation
                ) else { throw CancellationError() }
                dict[serverId] = .object([
                    "createdAt": .string(stamp),
                    "tools": .array(tools),
                ])
                try await persistence.writeJSON(.object(dict), to: path)
            }
        } catch {
            // FAIL LOUD: a failed cache stamp means the model silently loses
            // this server's tools on the next turn.
            FileHandle.standardError.write(Data(
                "MCPDispatcher: FAILED to write mcp/cache/tools.json for server '\(serverId)': \(error)\n".utf8
            ))
            throw error
        }
    }
}

/// One-shot "the fill closure actually ran" flag. The closure is `@Sendable`
/// and runs detached inside `MCPLiveCache`, so the dispatcher can't observe a
/// memory-cache hit vs. a real round-trip any other way.
final class _MCPLiveFetchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func mark() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

extension SwiftNativeMCPDispatcher {

    /// Live `tools/call` against an stdio server. Sends a JSON-RPC
    /// `tools/call` and returns the raw `result` object exactly as the child
    /// emits it. Servers with transport != "stdio" get no pool spec (see
    /// `ensurePool`, stdio-only) so the pool throws
    /// `MCPDispatcherError.serverNotFound`.
    ///
    /// IMPORTANT — this is a GATE-FREE transport primitive only. It deliberately
    /// does NOT replicate the execution gate (risk-class branching, approval
    /// request creation for external_write/external_send servers, pending-action
    /// replay registration). That gate must be
    /// applied in Swift before calling this primitive. NEVER cached: tool
    /// execution is side-effecting and must run every call.
    public func callToolLive(
        forServer serverId: String,
        toolName: String,
        arguments: JSONValue = .object([:]),
        pool: MCPSubprocessPool? = nil
    ) async throws -> JSONValue {
        let servers = try await _readServersUncached()
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw MCPDispatcherError.serverNotFound(serverId)
        }
        switch server.transport {
        case "stdio":
            break
        case "native":
            return try await callNativeAgentInternalTool(toolName: toolName, arguments: arguments)
        case "http":
            // searxng-local keeps its dedicated built-in bridge FIRST for
            // byte-compat; every other http server routes to the generic
            // streamable-HTTP transport.
            if server.id == "searxng-local" {
                return try await callBuiltInHTTPTool(server: server, toolName: toolName, arguments: arguments)
            }
            return try await callGenericHTTPTool(server: server, toolName: toolName, arguments: arguments)
        default:
            throw MCPSubprocessError.unsupportedTransport(server.transport)
        }
        let activePool: MCPSubprocessPool
        if let p = pool { activePool = p }
        else { activePool = await Self.ensurePool(for: servers, root: root) }
        let proc = try await activePool.get(serverId: serverId)
        return try await proc.request(
            method: "tools/call",
            params: .object(["name": .string(toolName), "arguments": arguments])
        )
    }

    /// Live session statuses. Mirrors `Runtime.list_mcp_session_statuses()`:
    /// one row per CONFIGURED server (not just running ones), pid + started
    /// stamped on running rows. http/native rows just get an "idle" row.
    public func listSessions(pool: MCPSubprocessPool? = nil) async throws -> [MCPSessionStatus] {
        let servers = try await listServers()
        let activePool: MCPSubprocessPool
        if let p = pool { activePool = p }
        else { activePool = await Self.ensurePool(for: servers, root: root) }
        // Ask the pool for what it knows.
        let poolRows = await activePool.sessionStatuses()
        let poolById = Dictionary(uniqueKeysWithValues: poolRows.map { ($0.serverId, $0) })
        var out: [MCPSessionStatus] = []
        for server in servers {
            if let row = poolById[server.id] {
                var enriched = row
                enriched.serverName = server.name
                enriched.transport = server.transport
                enriched.toolCount = server.toolCount
                enriched.resourceCount = server.resourceCount
                out.append(enriched)
            } else {
                // Server isn't stdio (no pool spec) — emit an idle row.
                out.append(MCPSessionStatus(
                    id: server.id,
                    serverId: server.id,
                    serverName: server.name,
                    transport: server.transport,
                    status: server.status,
                    healthStatus: server.healthStatus,
                    toolCount: server.toolCount,
                    resourceCount: server.resourceCount
                ))
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    private func cachedToolJSON(forServer serverId: String) async throws -> [JSONValue] {
        let tools = try await listTools(forServer: serverId)
        return tools.map { tool in
            var obj: [String: JSONValue] = [
                "name": .string(tool.name),
            ]
            if let desc = tool.description { obj["description"] = .string(desc) }
            if let schema = tool.inputSchema { obj["inputSchema"] = schema }
            if let risk = tool.riskClass { obj["riskClass"] = .string(risk) }
            return .object(obj)
        }
    }

    private func cachedResourcesJSON(forServer serverId: String) async throws -> [JSONValue] {
        let path = root
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("resources.json")
        let raw = try await persistence.readJSON(path, ifMissing: .object([:]))
        guard case .object(let dict) = raw,
              case .object(let entry) = dict[serverId] ?? .null,
              case .array(let resources) = entry["resources"] ?? .null
        else { return [] }
        return resources
    }

    private func callNativeAgentInternalTool(
        toolName: String,
        arguments: JSONValue
    ) async throws -> JSONValue {
        switch toolName {
        case "capabilities.summary":
            let summary = try await SwiftNativeCapabilityFoundryClient(root: root).capabilityFoundrySummary()
            return Self.okMCPResult(Self.compactCapabilitySummaryJSON(summary))
        case "graph.search":
            let query = Self.stringArgument(arguments, key: "query")
            guard !query.isEmpty else {
                throw MCPSubprocessError.malformedResponse("graph.search requires query")
            }
            let graphPath = root.appendingPathComponent("memory/knowledge_graph.json")
            let reader = makeKnowledgeGraphReader(graphPath: graphPath)
            let result = try await reader.searchChecked(q: query)
            return Self.okMCPResult(KnowledgeGraphSearchProjection.bounded(result))
        case "agent.operating_map":
            let servers = try await listServers()
            var serverRows: [JSONValue] = []
            for server in servers {
                serverRows.append(server.toJSON())
            }
            return Self.okMCPResult(.object([
                "runtime": .string("swift-native"),
                "pythonDaemon": .string("retired"),
                "internalProtocols": .array([
                    .string("direct Swift actors/services"),
                    .string("MCP stdio subprocesses"),
                    .string("built-in native/http MCP bridges"),
                ]),
                "servers": .array(serverRows),
                "memory": .object([
                    "backend": .string("Swift MemoryV2"),
                    // gpt-5.5 review-3 NEEDS_FIX: was "CoreML MiniLM with mock
                    // fallback" — runtime now fails closed instead of falling
                    // back. Explicit mock is opt-in via config or env var.
                    "semanticEmbeddings": .string("CoreML MiniLM (fails closed; explicit mock available via config or NATIVE_AGENT_EMBEDDING_MOCK)"),
                ]),
            ]))
        case "production.summary":
            return Self.okMCPResult(.object([
                "runtime": .string("NativeAgentApp"),
                "daemon": .string("retired"),
                "pythonRuntime": .string("not required by app runtime"),
                "releaseGuard": .string("zero Python artifact scans"),
                "status": .string("swift-native"),
            ]))
        case "native.actions":
            return Self.okMCPResult(.object([
                "status": .string("ready"),
                "actions": .array([
                    .string("memory.recall"),
                    .string("knowledge_graph.search"),
                    .string("persona.read_doc"),
                    .string("skills.list"),
                    .string("research.search"),
                    .string("research.fetch"),
                    .string("telegram.poll"),
                ]),
            ]))
        default:
            throw MCPSubprocessError.malformedResponse("unknown native MCP tool: \(toolName)")
        }
    }

    private func callBuiltInHTTPTool(
        server: MCPServer,
        toolName: String,
        arguments: JSONValue
    ) async throws -> JSONValue {
        guard server.id == "searxng-local" else {
            throw MCPSubprocessError.unsupportedTransport(server.transport)
        }
        let client = SwiftNativeResearchClient(dataRoot: root)
        switch toolName {
        case "search":
            let query = Self.stringArgument(arguments, key: "query")
            guard !query.isEmpty else {
                throw MCPSubprocessError.malformedResponse("search needs query: the words to search for.")
            }
            let categories = Self.stringArgument(arguments, key: "categories")
            let timeRange = Self.stringArgument(arguments, key: "time_range")
            return await WebSearchRoutes.search(query: query, categories: categories, timeRange: timeRange, dataRoot: root) {
                try await client.search(query: query, categories: categories.isEmpty ? nil : categories,
                                        timeRange: timeRange.isEmpty ? nil : timeRange)
            }
        default:
            throw MCPSubprocessError.malformedResponse("unknown SearXNG MCP tool: \(toolName)")
        }
    }

    /// Route an http server (other than the searxng-local built-in) through the
    /// generic MCP streamable-HTTP transport. Uses `server.endpoint`; a clear
    /// error is thrown when the endpoint is empty/unparseable — NEVER a silent
    /// fallthrough to another transport. The tools/call result is wrapped in the
    /// same `okMCPResult` envelope the searxng path returns.
    private func callGenericHTTPTool(
        server: MCPServer,
        toolName: String,
        arguments: JSONValue
    ) async throws -> JSONValue {
        let transport = try await genericHTTPTransport(for: server)
        let result = try await transport.callTool(name: toolName, arguments: arguments)
        return Self.okMCPResult(result)
    }

    private func genericHTTPTransport(for server: MCPServer) async throws -> MCPHTTPTransport {
        // Refresh registry ownership before accepting even a cached catalog's spec.
        let servers = try await _readServersUncached()
        guard let current = servers.first(where: { $0.id == server.id }),
              try current.executionIdentity() == server.executionIdentity() else {
            throw MCPDispatcherError.malformedResponse("MCP server changed before HTTP dispatch; refresh the connection")
        }
        let raw = server.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else {
            throw MCPSubprocessError.httpTransport(
                serverId: server.id, status: nil,
                detail: "http transport requires a non-empty endpoint URL (got \"\(server.endpoint)\")"
            )
        }
        return try await MCPHTTPRegistryTransports.shared.transport(for: server, endpoint: url, root: root)
    }

    private static func okMCPResult(_ result: JSONValue) -> JSONValue {
        .object([
            "status": .string("ok"),
            "result": result,
        ])
    }

    /// MCP callers need aggregate capability truth, not the potentially large
    /// review/artifact payloads used by richer app surfaces.
    private static func compactCapabilitySummaryJSON(
        _ result: CapabilityFoundryResult
    ) -> JSONValue {
        let maximumMetadataRows = 16
        return .object([
            "status": .string(result.status),
            "detail": .string(String(result.detail.prefix(1_000))),
            "principle": .string(String(result.principle.prefix(1_000))),
            "hotPathContract": result.hotPathContract.toJSON(),
            "summary": result.summary.toJSON(),
            "lanes": .array(result.lanes.prefix(maximumMetadataRows).map { $0.toJSON() }),
            "laneCount": .int(Int64(result.lanes.count)),
            "reviewQueue": .array([]),
            "reviewQueueCount": .int(Int64(result.reviewQueue.count)),
            "recentArtifacts": .array([]),
            "recentArtifactCount": .int(Int64(result.recentArtifacts.count)),
            "readouts": .array(result.readouts.prefix(maximumMetadataRows).map { $0.toJSON() }),
            "readoutCount": .int(Int64(result.readouts.count)),
            "createdAt": .string(result.createdAt),
        ])
    }

    private static func stringArgument(_ arguments: JSONValue, key: String) -> String {
        guard case .object(let obj) = arguments,
              case .string(let value) = obj[key] ?? .null
        else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Pool resolution

    public func stopSubprocess(serverId: String) async {
        await MCPRegistryPools.shared.pool(for: root).stop(serverId: serverId)
        await MCPHTTPRegistryTransports.shared.stop(serverId: serverId, root: root)
    }

    public static func stopAllSharedPools() async {
        for pool in MCPRegistryPools.shared.allPools() { await pool.stopAll() }
        await MCPHTTPRegistryTransports.shared.stopAll()
    }

    func reconcileHTTPTransports(for servers: [MCPServer]) async {
        await MCPHTTPRegistryTransports.shared.reconcile(servers: servers, root: root)
    }

    /// Refresh only this canonical registry's stdio specs.
    static func ensurePool(for servers: [MCPServer], root: URL = defaultDataRoot()) async -> MCPSubprocessPool {
        let pool = MCPRegistryPools.shared.pool(for: root)
        let specs: [MCPSubprocessPool.Spec] = servers.compactMap { srv in
            guard srv.transport == "stdio",
                  let cmd = srv.command, !cmd.isEmpty else { return nil }
            return MCPSubprocessPool.Spec(
                serverId: srv.id, command: cmd,
                executionIdentity: try? srv.executionIdentity()
            )
        }
        await pool.updateSpecs(specs)
        return pool
    }

}

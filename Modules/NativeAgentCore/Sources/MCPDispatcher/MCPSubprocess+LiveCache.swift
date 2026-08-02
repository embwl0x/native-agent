import Foundation
import NativeAgentCore
import PersistenceCore
import Research
import KnowledgeGraph
import CapabilityFoundry

// MARK: - Cached live MCP queries on the SwiftNative dispatcher

/// 60-second TTL cache row. Matches the daemon's behavior of stamping a
/// `cache/tools.json` entry on every successful `list_mcp_tools` call.
private struct MCPLiveCacheRow: Sendable {
    let storedAt: Date
    let value: [JSONValue]
}

/// Process-wide cache for `listToolsLive` / `listResourcesLive`. Keyed by
/// "<kind>:<serverId>". An actor so we can serialize check/refill cleanly.
public actor MCPLiveCache {
    public static let shared = MCPLiveCache()
    private var rows: [String: MCPLiveCacheRow] = [:]
    /// In-flight refill tasks keyed by cache key — used by `getOrFill` to
    /// coalesce concurrent misses into a single subprocess request (avoids
    /// the thundering-herd where N callers each spawn N round-trips during
    /// the brief window between miss and put).
    private var inflight: [String: Task<[JSONValue], Error>] = [:]
    /// Round 5 Bug B fix (2026-05-31): per-key generation token. The
    /// PREVIOUS `forceFill` cleared `inflight[key]` BEFORE its drain await
    /// — leaving an empty slot that a newer `forceFill` could fill with
    /// its own task. The older caller then resumed and unconditionally
    /// installed `inflight[key] = myTask`, clobbering the newer slot. The
    /// older's value won the cache and the newer's write was lost. Now:
    /// every `forceFill` bumps `keyGenerations[key]` at entry and captures
    /// `myGen` synchronously. After the drain await, an older caller whose
    /// `myGen` no longer matches the slot drops out — no slot install, no
    /// put. The newer (highest-gen) caller wins the cache.
    private var keyGenerations: [String: Int] = [:]
    public var ttl: TimeInterval = 60

    public init() {}

    func get(_ key: String) -> [JSONValue]? {
        guard let row = rows[key] else { return nil }
        if Date().timeIntervalSince(row.storedAt) > ttl {
            rows.removeValue(forKey: key)
            return nil
        }
        return row.value
    }

    func put(_ key: String, value: [JSONValue]) {
        rows[key] = MCPLiveCacheRow(storedAt: Date(), value: value)
    }

    /// Returns a cached value if fresh; otherwise starts (or joins) an
    /// in-flight refill via `fill`. Multiple concurrent callers for the
    /// same key all await the same Task, so the underlying subprocess sees
    /// exactly one request per (key, refill window). The `fill` closure is
    /// `@Sendable` because the Task runs detached from the original caller.
    func getOrFill(
        _ key: String,
        fill: @escaping @Sendable () async throws -> [JSONValue]
    ) async throws -> [JSONValue] {
        if let hit = get(key) { return hit }
        if let existing = inflight[key] {
            return try await existing.value
        }
        let task = Task<[JSONValue], Error> {
            try await fill()
        }
        inflight[key] = task
        // Bug B fix (2026-05-31, 4th-round review): the prior version did
        // NOT wrap `try await task.value` in do/catch. If `fill` threw,
        // the slot-clear path was skipped and `inflight[key]` stayed
        // pinned to the failed Task — every future caller for this key
        // awaited the same failed task and saw the same error forever.
        // Identity-clear on both success AND error paths.
        do {
            let value = try await task.value
            // Bug 3 fix (2026-05-31, 3rd-round review): only commit our
            // value and clear our inflight slot if the slot still belongs
            // to OUR task. If a concurrent `forceFill` cancelled-and-
            // replaced the inflight task while we were awaiting, the
            // newer task owns the cache write; clobbering it with our
            // (now-stale) value would overwrite the fresh forceFill
            // result with the cancelled-but-completed slow result.
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

    /// Bug 7 fix (2026-05-31): force-fresh path that bypasses the
    /// cached read but coordinates with any in-flight `getOrFill` for
    /// the SAME key. Previously the `cached: false` branch in
    /// `listToolsLive` / `listResourcesLive` ran its own request entirely
    /// outside the cache actor — if a slow in-flight fill was already
    /// running, the force-fresh call could complete first, write the
    /// cache, then the older in-flight fill would land and clobber the
    /// newer value with a stale one. This method cancels the in-flight
    /// task (best-effort; awaits its completion either way), runs the
    /// supplied `fill` synchronously inside the actor's serialized
    /// queue, then writes the result. Concurrent force-fresh callers
    /// for the same key serialize naturally through the actor's mailbox.
    func forceFill(
        _ key: String,
        fill: @escaping @Sendable () async throws -> [JSONValue]
    ) async throws -> [JSONValue] {
        // Round 5 Bug B fix: bump + capture generation synchronously at
        // entry. After every suspension point we re-check `myGen` against
        // `keyGenerations[key]`; a NEWER `forceFill` that ran during one
        // of our awaits will have bumped past us, and we drop out of
        // shared-state updates so the newer caller owns the cache write.
        let myGen = (keyGenerations[key] ?? 0) + 1
        keyGenerations[key] = myGen

        if let existing = inflight[key] {
            existing.cancel()
            // Clear the slot identity-compared so we don't wipe a newer
            // call that displaced this one between our enter and now.
            if let current = inflight[key], current == existing {
                inflight[key] = nil
            }
            // Drain the cancelled task so we don't race its `put`. Errors
            // are expected here (cancellation throws CancellationError on
            // most code paths); swallow them.
            _ = try? await existing.value
        }

        // Re-check after the drain await — a newer forceFill may have
        // entered while we were suspended and bumped the gen. If so, we
        // skip every shared-state write: just run our fill, return our
        // value to the caller, leave the cache for the newer caller.
        if keyGenerations[key] != myGen {
            return try await fill()
        }

        let myTask = Task<[JSONValue], Error> {
            try await fill()
        }
        inflight[key] = myTask
        // Bug C fix (4th-round review): identity-compare in BOTH defer-
        // clear and the cache `put` so an overlapping later forceFill that
        // already replaced our slot wins the cache write. Combined with
        // the Round 5 gen check above, this gives belt-and-suspenders.
        defer {
            if keyGenerations[key] == myGen,
               let current = inflight[key], current == myTask {
                inflight[key] = nil
            }
        }
        let value = try await myTask.value
        if keyGenerations[key] == myGen,
           let current = inflight[key], current == myTask {
            put(key, value: value)
        }
        return value
    }

    /// Test seam — clear all rows.
    public func _clear() {
        rows.removeAll()
        inflight.removeAll()
        keyGenerations.removeAll()
    }

    /// Test seam — set the TTL from outside the actor.
    public func _setTTL(_ seconds: TimeInterval) {
        ttl = seconds
    }
}

extension SwiftNativeMCPDispatcher {
    /// Live `tools/list` against an stdio server. Spawns the subprocess on
    /// first call via the shared pool. Cached for 60s (mirroring the daemon's
    /// cache stamp). Pass `cached: false` to force a fresh roundtrip.
    /// Servers with transport != "stdio" throw `unsupportedTransport`.
    public func listToolsLive(
        forServer serverId: String,
        cached: Bool = true,
        pool: MCPSubprocessPool? = nil
    ) async throws -> [JSONValue] {
        let servers = try await listServers()
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw MCPDispatcherError.serverNotFound(serverId)
        }
        guard server.transport == "stdio" else {
            return try await cachedToolJSON(forServer: serverId)
        }
        let cacheKey = "tools:\(serverId)"
        // Resolve the pool BEFORE handing off to getOrFill so the fill
        // closure stays Sendable (no captured async-call to listServers).
        let activePool: MCPSubprocessPool
        if let p = pool { activePool = p }
        else { activePool = await Self.ensurePool(for: servers) }
        // F-B3 (2026-08-02): `mcp/cache/tools.json` is the ONLY producer of
        // `mcp__<server>__<tool>` descriptors for the model (MCPToolBridge),
        // and after the daemon was retired NOTHING wrote it — a working MCP
        // server contributed zero tools with no error and no log. The
        // handshake result is now stamped back to disk exactly where the
        // daemon used to stamp it (see this file's header contract). `didFetch`
        // makes the write happen on a REAL round-trip only, not on a memory
        // cache hit.
        let didFetch = _MCPLiveFetchFlag()
        let tools: [JSONValue]
        if !cached {
            // Bug 7 fix (2026-05-31): route force-fresh through the cache
            // actor's `forceFill` so it cancels/awaits any in-flight
            // `getOrFill` for the same key before writing. Previously
            // bypassing the cache entirely allowed a slow in-flight fill
            // to clobber the newer force-fresh result on completion.
            tools = try await MCPLiveCache.shared.forceFill(cacheKey) {
                didFetch.mark()
                let proc = try await activePool.get(serverId: serverId)
                let result = try await proc.request(method: "tools/list", params: .object([:]))
                return Self.extractArray(result, key: "tools")
            }
        } else {
            tools = try await MCPLiveCache.shared.getOrFill(cacheKey) {
                didFetch.mark()
                let proc = try await activePool.get(serverId: serverId)
                let result = try await proc.request(method: "tools/list", params: .object([:]))
                return Self.extractArray(result, key: "tools")
            }
        }
        if didFetch.value {
            await persistToolsCache(serverId: serverId, tools: tools)
        }
        return tools
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

    /// Warm `mcp/cache/tools.json` for every bridgeable server. Per-server
    /// failures are collected, NOT swallowed: the result maps serverId →
    /// tool count on success or the error text on failure, and every failure
    /// is also logged loudly to stderr. Never throws for one bad server —
    /// one broken MCP server must not blind the model to the other five.
    @discardableResult
    public func refreshAllToolsCaches(
        pool: MCPSubprocessPool? = nil
    ) async -> [String: String] {
        let servers = (try? await listServers()) ?? []
        var report: [String: String] = [:]
        for server in servers where server.status != "needs_setup" && server.status != "error" {
            do {
                let count = try await refreshToolsCache(forServer: server.id, pool: pool)
                report[server.id] = "\(count)"
                if count == 0 {
                    FileHandle.standardError.write(Data(
                        "MCPDispatcher: server '\(server.id)' completed tools/list but advertised ZERO tools — it will contribute no mcp__\(server.id)__* descriptors to the model.\n".utf8
                    ))
                }
            } catch {
                report[server.id] = "error: \(error)"
                FileHandle.standardError.write(Data(
                    "MCPDispatcher: tools-cache refresh FAILED for server '\(server.id)': \(error) — its tools stay invisible to the model.\n".utf8
                ))
            }
        }
        return report
    }

    /// Merge one server's live descriptors into `mcp/cache/tools.json`.
    /// Actor-isolated, so concurrent per-server refreshes serialize their
    /// read-modify-write against the shared file instead of clobbering.
    private func persistToolsCache(serverId: String, tools: [JSONValue]) async {
        let existing = await persistence.readJSON(toolsCachePath, defaultValue: .object([:]))
        var dict: [String: JSONValue]
        if case .object(let obj) = existing { dict = obj } else { dict = [:] }
        dict[serverId] = .object([
            "createdAt": .string(Self.isoTimestamp(clockNow)),
            "tools": .array(tools),
        ])
        do {
            try await persistence.writeJSON(.object(dict), to: toolsCachePath)
        } catch {
            // FAIL LOUD: a failed cache stamp means the model silently loses
            // this server's tools on the next turn.
            FileHandle.standardError.write(Data(
                "MCPDispatcher: FAILED to write mcp/cache/tools.json for server '\(serverId)': \(error)\n".utf8
            ))
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

    /// Live `resources/list` against an stdio server. Same caching contract
    /// as `listToolsLive`.
    public func listResourcesLive(
        forServer serverId: String,
        cached: Bool = true,
        pool: MCPSubprocessPool? = nil
    ) async throws -> [JSONValue] {
        let servers = try await listServers()
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw MCPDispatcherError.serverNotFound(serverId)
        }
        guard server.transport == "stdio" else {
            return await cachedResourcesJSON(forServer: serverId)
        }
        let cacheKey = "resources:\(serverId)"
        let activePool: MCPSubprocessPool
        if let p = pool { activePool = p }
        else { activePool = await Self.ensurePool(for: servers) }
        if !cached {
            // Bug 7 fix (2026-05-31): see listToolsLive — same fix.
            return try await MCPLiveCache.shared.forceFill(cacheKey) {
                let proc = try await activePool.get(serverId: serverId)
                let result = try await proc.request(method: "resources/list", params: .object([:]))
                return Self.extractArray(result, key: "resources")
            }
        }
        return try await MCPLiveCache.shared.getOrFill(cacheKey) {
            let proc = try await activePool.get(serverId: serverId)
            let result = try await proc.request(method: "resources/list", params: .object([:]))
            return Self.extractArray(result, key: "resources")
        }
    }

    /// Live `tools/call` against an stdio server. Sends a JSON-RPC
    /// `tools/call` and returns the raw `result` object exactly as the child
    /// emits it. Servers with transport != "stdio" get no pool spec (see
    /// `ensurePool`, stdio-only) so the pool throws
    /// `MCPDispatcherError.serverNotFound`.
    ///
    /// IMPORTANT — this is a GATE-FREE transport primitive only. It deliberately
    /// does NOT replicate the execution gate (risk-class branching, approval
    /// request creation for external_write/external_send servers, pending-action
    /// replay registration, or low-risk consent auto-grant). That gate must be
    /// applied in Swift before calling this primitive. NEVER cached: tool
    /// execution is side-effecting and must run every call.
    public func callToolLive(
        forServer serverId: String,
        toolName: String,
        arguments: JSONValue = .object([:]),
        pool: MCPSubprocessPool? = nil
    ) async throws -> JSONValue {
        let servers = try await listServers()
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
        else { activePool = await Self.ensurePool(for: servers) }
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
        else { activePool = await Self.ensurePool(for: servers) }
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

    private func cachedResourcesJSON(forServer serverId: String) async -> [JSONValue] {
        let path = root
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("resources.json")
        let raw = await persistence.readJSON(path, defaultValue: .object([:]))
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
            let summary = try await makeCapabilityFoundryClient(root: root).capabilityFoundrySummary()
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
        let client = makeResearchClient()
        switch toolName {
        case "search":
            let query = Self.stringArgument(arguments, key: "query")
            guard !query.isEmpty else {
                throw MCPSubprocessError.malformedResponse("searxng search requires query")
            }
            let response = try await client.search(query: query)
            return Self.okMCPResult(response.toJSON())
        case "fetch":
            let url = Self.stringArgument(arguments, key: "url")
            guard !url.isEmpty else {
                throw MCPSubprocessError.malformedResponse("searxng fetch requires url")
            }
            let response = try await client.fetchURL(url)
            return Self.okMCPResult(response.toJSON())
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
        let raw = server.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else {
            throw MCPSubprocessError.httpTransport(
                serverId: server.id, status: nil,
                detail: "http transport requires a non-empty endpoint URL (got \"\(server.endpoint)\")"
            )
        }
        let transport = MCPHTTPTransport(serverId: server.id, endpoint: url)
        let result = try await transport.callTool(name: toolName, arguments: arguments)
        return Self.okMCPResult(result)
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

    /// Singleton pool shared across the SwiftNative dispatcher's live calls.
    /// Lazily built from the on-disk servers.json so tests can override by
    /// passing their own `pool:` parameter.
    private static let _sharedPool = MCPSubprocessPool()
    public static var sharedPool: MCPSubprocessPool { _sharedPool }

    /// Refresh the shared pool's specs from the current server list (stdio
    /// only). Idempotent — same input → same pool state.
    static func ensurePool(for servers: [MCPServer]) async -> MCPSubprocessPool {
        let specs: [MCPSubprocessPool.Spec] = servers.compactMap { srv in
            guard srv.transport == "stdio",
                  let cmd = srv.command, !cmd.isEmpty else { return nil }
            return MCPSubprocessPool.Spec(serverId: srv.id, command: cmd)
        }
        await _sharedPool.updateSpecs(specs)
        return _sharedPool
    }

    static func extractArray(_ result: JSONValue, key: String) -> [JSONValue] {
        if case .object(let obj) = result, case .array(let arr) = obj[key] ?? .null {
            return arr
        }
        if case .array(let arr) = result { return arr }
        return []
    }
}

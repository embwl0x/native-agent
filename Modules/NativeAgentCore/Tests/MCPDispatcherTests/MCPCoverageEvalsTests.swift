import Testing
import Foundation
import os
@testable import MCPDispatcher
import NativeAgentCore
import PersistenceCore

// ============================================================================
// Coverage-ledger evals — fence core.toolexec (docs/evals/ledger.json).
//
// Rows closed here:
//   • feed.mcp.servers
//   • feed.mcp.cache.resources
//   • mcp.liveCache.listResourcesLive
//   • mcp.liveCache.listSessions
//   • mcp.searxng.tools
//   • mcp.dispatcher.perCallInstantiation
//   • mcp.dispatcher.invalidateCacheHook
//   • mcp.dispatcher.configPath
//   • mcp.subprocess.childEnvironment
//
// Every fixture is hermetic (temp root). Nothing reads or writes the live
// data/ tree.
// ============================================================================

// MARK: - Fixtures

private func evalTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MCPCoverageEvals-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeServersJSON(_ root: URL, _ servers: [JSONValue]) throws {
    let mcpDir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
    try JSONValue.array(servers).serializedData(pretty: true)
        .write(to: mcpDir.appendingPathComponent("servers.json"))
}

private func stdioServerRecord(id: String, name: String, command: String) -> JSONValue {
    .object([
        "id": .string(id),
        "name": .string(name),
        "transport": .string("stdio"),
        "endpoint": .string(""),
        "command": .string(command),
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "toolCount": .int(0),
        "resourceCount": .int(0),
        "riskClass": .string("app_data_read"),
        "createdAt": .string("2026-08-23T00:00:00+00:00"),
        "updatedAt": .string("2026-08-23T00:00:00+00:00"),
    ])
}

/// A python3 MCP stdio server. Chosen over `/usr/bin/env swift` deliberately:
/// ~30 ms startup, no toolchain contention under a parallel suite (see the
/// hang-proof subprocess convention). Speaks newline-delimited JSON-RPC and
/// answers initialize / tools/list / resources/list / tools/call.
///
/// When `envDumpPath` is set the child writes its FULL environment there
/// before the handshake, which is how the childEnvironment eval observes what
/// actually crosses into an MCP server process.
private func writePythonMCPHelper(
    resourceCount: Int = 2,
    toolCount: Int = 2,
    envDumpPath: String? = nil
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-py-helper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("server.py")
    let dumpLiteral = envDumpPath.map { "\"\($0)\"" } ?? "None"
    let script = """
    import sys, json, os

    ENV_DUMP = \(dumpLiteral)
    RESOURCE_COUNT = \(resourceCount)
    TOOL_COUNT = \(toolCount)

    if ENV_DUMP:
        with open(ENV_DUMP, "w") as fh:
            json.dump(dict(os.environ), fh)

    def send(msg):
        sys.stdout.write(json.dumps(msg) + "\\n")
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid,
                  "result": {"protocolVersion": "2024-11-05",
                             "serverInfo": {"name": "py-eval-helper", "version": "1.0"},
                             "capabilities": {}}})
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid,
                  "result": {"tools": [{"name": "tool.%d" % i, "description": "Tool %d" % i}
                                        for i in range(TOOL_COUNT)]}})
        elif method == "resources/list":
            send({"jsonrpc": "2.0", "id": mid,
                  "result": {"resources": [{"uri": "resource://%d" % i,
                                            "name": "Resource %d" % i,
                                            "mimeType": "text/plain"}
                                           for i in range(RESOURCE_COUNT)]}})
        elif method == "tools/call":
            params = msg.get("params") or {}
            send({"jsonrpc": "2.0", "id": mid,
                  "result": {"calledTool": params.get("name"),
                             "echoArgs": params.get("arguments")}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid,
                  "error": {"code": -32601, "message": "unknown method %s" % method}})
    """
    try Data(script.utf8).write(to: path)
    return path
}

private func pythonHelperCommand(_ script: URL, extraArg: String? = nil) -> String {
    if let extraArg { return "/usr/bin/python3 \(script.path) \(extraArg)" }
    return "/usr/bin/python3 \(script.path)"
}

// MARK: - mcp.liveCache.listResourcesLive
//
// SILENT ZERO: no test in the repo named listResourcesLive. A break returns an
// empty resource list indistinguishable from a server that simply has none.
// This eval pins the POSITIVE direction (N advertised → N returned) plus the
// caching contract, so an empty result can never pass for healthy.

@Test func evalMCPListResourcesLive_populatedServerYieldsRowsAndCaches() async throws {
    let script = try writePythonMCPHelper(resourceCount: 3)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let root = try evalTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let command = pythonHelperCommand(script)
    try writeServersJSON(root, [
        stdioServerRecord(id: "res-helper", name: "Resource Helper", command: command)
    ])

    let dispatcher = SwiftNativeMCPDispatcher(root: root)
    let pool = MCPSubprocessPool()
    // e8fd9ab8 binds resource discovery to the registered implementation too.
    let registered = try #require(try await dispatcher.listServers().first(where: { $0.id == "res-helper" }))
    await pool.updateSpecs([MCPSubprocessPool.Spec(
        serverId: "res-helper", command: command,
        executionIdentity: try registered.executionIdentity()
    )])
    await MCPLiveCache.shared._clear()
    defer { Task { await pool.stopAll() } }

    let resources = try await dispatcher.listResourcesLive(forServer: "res-helper", pool: pool)
    #expect(
        resources.count == 3,
        "a server advertising 3 resources must yield 3 rows — got \(resources.count). A zero here is the silent-zero this eval exists to catch."
    )
    // Row shape is passed through verbatim (the hub renders uri/name).
    guard case .object(let first)? = resources.first else {
        Issue.record("resource row was not an object")
        return
    }
    #expect(first["uri"] == .string("resource://0"))
    #expect(first["name"] == .string("Resource 0"))

    // Second call inside the TTL returns the same list (the caching contract
    // listToolsLive is already pinned on — asserted here so a cache break in
    // the resources arm is not invisible).
    let again = try await dispatcher.listResourcesLive(forServer: "res-helper", pool: pool)
    #expect(again.count == 3)

    // An UNKNOWN server is a NAMED error, never an empty list.
    do {
        _ = try await dispatcher.listResourcesLive(forServer: "ghost-server", pool: pool)
        Issue.record("an unknown server must throw serverNotFound, not return []")
    } catch MCPDispatcherError.serverNotFound(let id) {
        #expect(id == "ghost-server")
    } catch {
        Issue.record("wrong error for unknown server: \(error)")
    }
    await pool.stopAll()
}

// MARK: - feed.mcp.cache.resources
//
// SILENT ZERO: a shape change or missing server key returns [] with no error,
// so "no resources" and "reader broke" read identically. The non-stdio branch
// of listResourcesLive retains the file reader for native transports.

@Test func evalMCPResourcesCacheFeed_populatedVsBrokenVsAbsent() async throws {
    let root = try evalTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDir = root
        .appendingPathComponent("mcp", isDirectory: true)
        .appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    // f30338d2 gives generic HTTP servers live resource discovery. Use the
    // native cache lane for populated, shape-broken, and absent cache records.
    try writeServersJSON(root, ["good", "broken", "unlisted"].map { id in
        .object([
            "id": .string(id),
            "name": .string(id),
            "transport": .string("native"),
            "endpoint": .string("nativeagent://\(id)"),
            "status": .string("ready"),
            "healthStatus": .string("ok"),
            "toolCount": .int(0),
            "resourceCount": .int(0),
            "riskClass": .string("network_read"),
            "createdAt": .string("2026-08-23T00:00:00+00:00"),
            "updatedAt": .string("2026-08-23T00:00:00+00:00"),
        ])
    })
    let cache: JSONValue = .object([
        "good": .object([
            "createdAt": .string("2026-08-23T00:00:00+00:00"),
            "resources": .array([
                .object(["uri": .string("res://a"), "name": .string("A")]),
                .object(["uri": .string("res://b"), "name": .string("B")]),
            ]),
        ]),
        "broken": .object([
            "createdAt": .string("2026-08-23T00:00:00+00:00"),
            "resources": .object(["oops": .string("shape drift")]),
        ]),
    ])
    try cache.serializedData(pretty: true)
        .write(to: cacheDir.appendingPathComponent("resources.json"))

    let dispatcher = SwiftNativeMCPDispatcher(root: root)
    let good = try await dispatcher.listResourcesLive(forServer: "good")
    #expect(good.count == 2, "the populated server must read back 2 resources — got \(good.count)")

    // KNOWN COLLAPSE (ledger row feed.mcp.cache.resources): a shape-broken
    // entry and an entry that is simply absent BOTH read as 0. The reader has
    // no error channel, so the hub cannot tell "no resources" from "reader
    // broke". Pinned so the day the reader grows a distinguishable failure
    // this expectation must change.
    let broken = try await dispatcher.listResourcesLive(forServer: "broken")
    let unlisted = try await dispatcher.listResourcesLive(forServer: "unlisted")
    #expect(broken.isEmpty)
    #expect(unlisted.isEmpty)
    #expect(
        broken.count == unlisted.count,
        "KNOWN COLLAPSE changed: shape-broken and absent no longer read identically. If the reader gained an error channel, update this eval."
    )

    // The positive control is what keeps this eval non-vacuous: if the reader
    // regressed to always-[], `good` above would have caught it.
    let rawFile = try Data(contentsOf: cacheDir.appendingPathComponent("resources.json"))
    #expect(!rawFile.isEmpty, "the fixture file must exist — an absent file is 'source absent', never a healthy 0")
}

// MARK: - mcp.liveCache.listSessions
//
// STALE UI: the merge that enriches pool rows with serverName / transport /
// toolCount and emits idle rows for non-stdio servers is untested; a regression
// shows every server as an unnamed idle row and reads as "nothing running".

@Test func evalMCPListSessions_oneRowPerConfiguredServer_enrichedAndSorted() async throws {
    let script = try writePythonMCPHelper()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let root = try evalTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let command = pythonHelperCommand(script)
    var stdioRecord: [String: JSONValue] = [:]
    if case .object(let o) = stdioServerRecord(id: "zz-stdio", name: "ZZ Stdio", command: command) {
        stdioRecord = o
    }
    stdioRecord["toolCount"] = .int(7)
    stdioRecord["resourceCount"] = .int(4)
    try writeServersJSON(root, [.object(stdioRecord)])

    let dispatcher = SwiftNativeMCPDispatcher(root: root)
    let pool = MCPSubprocessPool()
    await pool.updateSpecs([MCPSubprocessPool.Spec(serverId: "zz-stdio", command: command)])
    // Warm the stdio child so the pool has a RUNNING row to enrich.
    _ = try await pool.get(serverId: "zz-stdio")
    defer { Task { await pool.stopAll() } }

    let sessions = try await dispatcher.listSessions(pool: pool)

    // One row per CONFIGURED server — the two auto-merged defaults
    // (nativeagent-internal, searxng-local) plus our stdio server.
    let ids = sessions.map(\.id)
    #expect(
        ids == ids.sorted(),
        "listSessions must be sorted by id — got \(ids)"
    )
    #expect(Set(ids) == ["nativeagent-internal", "searxng-local", "zz-stdio"],
            "one row per configured server, running or not — got \(ids)")

    guard let stdioRow = sessions.first(where: { $0.id == "zz-stdio" }) else {
        Issue.record("no row for the configured stdio server")
        return
    }
    // ENRICHMENT: the pool row alone carries none of these.
    #expect(stdioRow.serverName == "ZZ Stdio")
    #expect(stdioRow.transport == "stdio")
    #expect(stdioRow.toolCount == 7, "toolCount must come from the SERVER record, not the pool row")
    #expect(stdioRow.resourceCount == 4)
    #expect(stdioRow.pid != nil, "a warmed stdio server must carry a live pid")

    // IDLE ROWS: the non-stdio defaults have no pool spec and must still
    // appear, named and typed — otherwise the hub reads as empty.
    guard let nativeRow = sessions.first(where: { $0.id == "nativeagent-internal" }) else {
        Issue.record("the native default server produced no row")
        return
    }
    #expect(nativeRow.transport == "native")
    #expect(nativeRow.pid == nil)
    #expect(!(nativeRow.serverName ?? "").isEmpty, "an idle row must still be NAMED")
    await pool.stopAll()
}

// MARK: - feed.mcp.servers
//
// STALE / UNMEASURED: no eval tier reads servers.json. This pins the envelope
// every consumer depends on — transport / status / healthStatus present on
// every row — and pins the toolCount-vs-cache DIVERGENCE as a real, deliberate
// property rather than an assumed reconciliation.

@Test func evalMCPServersFeed_everyRowCarriesTransportStatusHealth_andToolCountIsUnreconciled() async throws {
    let root = try evalTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDir = root
        .appendingPathComponent("mcp", isDirectory: true)
        .appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    var record: [String: JSONValue] = [:]
    if case .object(let o) = stdioServerRecord(id: "drift-srv", name: "Drift", command: "/bin/true") {
        record = o
    }
    record["toolCount"] = .int(5)          // what the record CLAIMS
    try writeServersJSON(root, [.object(record)])
    // …while the tool cache holds only 3 names for the same server.
    try JSONValue.object([
        "drift-srv": .object([
            "createdAt": .string("2026-08-23T00:00:00+00:00"),
            "tools": .array((0..<3).map { .object(["name": .string("t\($0)")]) }),
        ]),
    ]).serializedData(pretty: true)
        .write(to: cacheDir.appendingPathComponent("tools.json"))

    let dispatcher = SwiftNativeMCPDispatcher(root: root)
    let servers = try await dispatcher.listServers()

    // Envelope: EVERY row (including the two auto-merged defaults) carries a
    // non-empty transport / status / healthStatus. A row missing any of these
    // renders as an unclassifiable entry in the hub.
    #expect(servers.count == 3, "auto-merged defaults + the saved record — got \(servers.map(\.id))")
    for server in servers {
        #expect(!server.transport.isEmpty, "\(server.id) has no transport")
        #expect(!server.status.isEmpty, "\(server.id) has no status")
        #expect(!server.healthStatus.isEmpty, "\(server.id) has no healthStatus")
        #expect(!server.id.isEmpty)
    }
    #expect(Set(servers.map(\.transport)).isSubset(of: ["stdio", "http", "native"]),
            "transport vocabulary drifted: \(Set(servers.map(\.transport)).sorted())")

    // The record's toolCount and the cached tool list are INDEPENDENT — the
    // dispatcher does not reconcile them. Pinned, because the live 3-vs-5
    // drift the ledger flags is this property, not a bug in the reader.
    let drift = servers.first { $0.id == "drift-srv" }
    let cachedTools = try await dispatcher.listTools(forServer: "drift-srv")
    #expect(drift?.toolCount == 5, "the record's own toolCount is passed through verbatim")
    #expect(cachedTools.count == 3, "the tool cache is the second, independent source")
    #expect(
        drift?.toolCount != cachedTools.count,
        "KNOWN DIVERGENCE changed: listServers now reconciles toolCount against the tool cache. Good — update this eval."
    )
}

// MARK: - mcp.dispatcher.configPath
//
// A file OUTSIDE the mcp/ tree decides whether the agent has web search.
// Losing or renaming `searxng_base_url` flips searxng-local to needs_setup and
// web search vanishes from the model's tool catalog with nothing saying why.
// The existing test covers the PROMOTION; this covers the DEMOTION.

@Test func evalMCPConfigPath_searxngDemotesWhenBaseURLIsMissingOrRenamed() async throws {
    func searxRow(_ root: URL) async throws -> MCPServer? {
        try await SwiftNativeMCPDispatcher(root: root).listServers()
            .first { $0.id == "searxng-local" }
    }

    // (a) config.json absent entirely → needs_setup, zero tools.
    let bare = try evalTempRoot()
    defer { try? FileManager.default.removeItem(at: bare) }
    let absent = try await searxRow(bare)
    #expect(absent?.status == "needs_setup")
    #expect(absent?.healthStatus == "needs_setup")
    #expect(absent?.toolCount == 0, "a demoted searxng server must advertise ZERO tools, not a stale count")
    #expect(absent?.endpoint == "")

    // (b) config.json present but the KEY was renamed → identical demotion.
    //     This is the failure mode the row names: the file is there, the agent
    //     just silently stops searching.
    let renamed = try evalTempRoot()
    defer { try? FileManager.default.removeItem(at: renamed) }
    let researchDir = renamed.appendingPathComponent("research", isDirectory: true)
    try FileManager.default.createDirectory(at: researchDir, withIntermediateDirectories: true)
    try JSONValue.object(["searxngBaseURL": .string("http://127.0.0.1:8888")])
        .serializedData(pretty: true)
        .write(to: researchDir.appendingPathComponent("config.json"))
    let renamedRow = try await searxRow(renamed)
    #expect(
        renamedRow?.status == "needs_setup",
        "a renamed key must demote — the reader keys on `searxng_base_url` exactly"
    )
    #expect(renamedRow?.toolCount == 0)

    // (c) Positive control — the correct key promotes. Without this the two
    //     assertions above would pass even if the reader were entirely dead.
    let ok = try evalTempRoot()
    defer { try? FileManager.default.removeItem(at: ok) }
    let okResearch = ok.appendingPathComponent("research", isDirectory: true)
    try FileManager.default.createDirectory(at: okResearch, withIntermediateDirectories: true)
    try JSONValue.object(["searxng_base_url": .string("http://127.0.0.1:8888")])
        .serializedData(pretty: true)
        .write(to: okResearch.appendingPathComponent("config.json"))
    let okRow = try await searxRow(ok)
    #expect(okRow?.status == "ready")
    #expect(okRow?.healthStatus == "ok")
    #expect(okRow?.toolCount == 2, "search + fetch")
    #expect(okRow?.endpoint == "http://127.0.0.1:8888")

    // The dispatcher exposes the path it keys on, so a relocation is visible.
    let configPath = await SwiftNativeMCPDispatcher(root: ok).configPath
    #expect(configPath.path == ok.appendingPathComponent("research/config.json").path)
}

// MARK: - mcp.searxng.tools
//
// SILENT CAPABILITY LOSS: the built-in SearXNG bridge is guarded by
// `server.id == "searxng-local"`. A server-id rename in servers.json routes
// both tools somewhere else entirely.

@Test func evalMCPSearxngTools_missingArgumentsAreNamedErrors_notEmptyResults() async throws {
    let root = try evalTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let researchDir = root.appendingPathComponent("research", isDirectory: true)
    try FileManager.default.createDirectory(at: researchDir, withIntermediateDirectories: true)
    try JSONValue.object(["searxng_base_url": .string("http://127.0.0.1:1")])
        .serializedData(pretty: true)
        .write(to: researchDir.appendingPathComponent("config.json"))
    let dispatcher = SwiftNativeMCPDispatcher(root: root)

    // Missing `query` / `url` must be a NAMED error before any network work.
    for (tool, needle) in [("search", "query"), ("fetch", "url")] {
        do {
            _ = try await dispatcher.callToolLive(
                forServer: "searxng-local", toolName: tool, arguments: .object([:])
            )
            Issue.record("\(tool) with no \(needle) must throw, not return an empty result")
        } catch MCPSubprocessError.malformedResponse(let detail) {
            #expect(detail.contains(needle), "the error must NAME the missing argument; got \(detail)")
        } catch {
            Issue.record("wrong error for \(tool): \(error)")
        }
    }

    // An unknown tool name on the built-in bridge is also named, never silent.
    do {
        _ = try await dispatcher.callToolLive(
            forServer: "searxng-local", toolName: "teleport", arguments: .object([:])
        )
        Issue.record("an unknown SearXNG tool must throw")
    } catch MCPSubprocessError.malformedResponse(let detail) {
        #expect(detail.contains("teleport"))
    } catch {
        Issue.record("wrong error for unknown tool: \(error)")
    }
}

@Test func evalMCPSearxngTools_serverIdRenameLeavesTheBuiltInBridge() async throws {
    // The bridge is id-guarded. A rename does not "fall back" — it routes to
    // the GENERIC http transport, whose failure is at least NAMED (httpTransport
    // carrying the server id). This eval pins that the rename is observable and
    // that no path silently succeeds with a different backend.
    let root = try evalTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeServersJSON(root, [.object([
        "id": .string("searxng-renamed"),
        "name": .string("SearXNG (renamed)"),
        "transport": .string("http"),
        "endpoint": .string(""),          // empty endpoint → the generic path refuses loudly
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "toolCount": .int(2),
        "resourceCount": .int(0),
        "riskClass": .string("network_read"),
        "createdAt": .string("2026-08-23T00:00:00+00:00"),
        "updatedAt": .string("2026-08-23T00:00:00+00:00"),
    ])])
    let dispatcher = SwiftNativeMCPDispatcher(root: root)
    do {
        _ = try await dispatcher.callToolLive(
            forServer: "searxng-renamed",
            toolName: "search",
            arguments: .object(["query": .string("hello")])
        )
        Issue.record("a renamed searxng server must NOT reach the built-in bridge")
    } catch MCPSubprocessError.httpTransport(let serverId, _, let detail) {
        // The important part: the error NAMES the server, so 'she stopped
        // searching the web' has a traceable cause instead of a generic failure.
        #expect(serverId == "searxng-renamed")
        #expect(detail.contains("endpoint"))
    } catch {
        Issue.record("a rename must fail through the generic http transport, got: \(error)")
    }
}

// MARK: - mcp.dispatcher.perCallInstantiation
//
// `_serversCacheRow` / `_inflightListServers` are ACTOR-INSTANCE state behind a
// per-call factory, so in production the 60s listServers cache never survives a
// call. The existing cache tests hold ONE instance and therefore prove a
// property production never exercises. This states the disk-read count for N
// factory-built dispatchers explicitly.

private final class _EvalReadCountingPersistence: PersistenceCoreProtocol, @unchecked Sendable {
    let inner = SwiftNativePersistenceCore()
    private let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
    var serversReadCount: Int { counter.withLock { $0 } }
    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        if path.lastPathComponent == "servers.json" { counter.withLock { $0 += 1 } }
        return await inner.readJSON(path, defaultValue: defaultValue)
    }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try await inner.writeJSON(value, to: path)
    }
    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        try await inner.appendJSONL(record, to: path)
    }
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await inner.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }
    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await inner.readJSONL(path)
    }
}

@Test func evalMCPDispatcher_cacheIsInstanceScoped_soEachFactoryBuildRereadsDisk() async throws {
    let root = try evalTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeServersJSON(root, [stdioServerRecord(id: "a", name: "A", command: "/bin/true")])
    let counting = _EvalReadCountingPersistence()

    // ONE instance, two calls inside the TTL → ONE disk read. This is the
    // property the existing cache tests prove.
    let single = SwiftNativeMCPDispatcher(root: root, persistence: counting)
    _ = try await single.listServers()
    _ = try await single.listServers()
    #expect(counting.serversReadCount == 1,
            "the in-actor TTL cache must absorb the second read on the SAME instance — got \(counting.serversReadCount)")

    // A SECOND dispatcher over the same root re-reads. Production builds a
    // fresh actor per call site, so this — not the number above — is the count
    // a hub interaction actually pays.
    let second = SwiftNativeMCPDispatcher(root: root, persistence: counting)
    _ = try await second.listServers()
    #expect(counting.serversReadCount == 2,
            "a fresh dispatcher instance starts COLD — the cache is instance-scoped, not process-global")

    let third = SwiftNativeMCPDispatcher(root: root, persistence: counting)
    _ = try await third.listServers()
    #expect(
        counting.serversReadCount == 3,
        "N factory-built dispatchers cost N disk reads. If this ever drops below N a shared cache appeared — update this eval and the ledger row."
    )

    // The factory itself hands back a DISTINCT actor every call (no IO here —
    // makeMCPDispatcher() resolves the host data root, which we never read).
    let f1 = makeMCPDispatcher()
    let f2 = makeMCPDispatcher()
    #expect(
        ObjectIdentifier(f1 as AnyObject) != ObjectIdentifier(f2 as AnyObject),
        "makeMCPDispatcher() returns a fresh actor per call — that is WHY the cache never survives in production"
    )
}

// MARK: - mcp.dispatcher.invalidateCacheHook
//
// DEAD CONTROL: `_invalidateListServersCache` and `_setListServersTTL` are both
// `public`, documented "test seam", and have no production caller. There is no
// hook by which adding a server in the MCP Hub invalidates the dispatcher's
// server cache. Today that is masked by the per-call instantiation above; the
// moment anyone caches a dispatcher for perf, a just-added server is invisible
// for up to 60 s.

@Test func evalMCPDispatcher_underscoreSeams_haveNoProductionCaller() throws {
    guard let repoRoot = evalRepositoryRoot() else {
        Issue.record("could not locate the repository root from #filePath")
        return
    }
    let seams = ["_invalidateListServersCache", "_setListServersTTL"]
    var callersByName: [String: [String]] = [:]
    for seam in seams { callersByName[seam] = [] }

    let searchRoots = ["Sources", "Modules", "iOS", "tests", "script"]
        .map { repoRoot.appendingPathComponent($0, isDirectory: true) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }

    for base in searchRoots {
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil
        ) else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let isTest = url.path.contains("/Tests/") || url.path.contains("/tests/")
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                for seam in seams where line.contains(seam) {
                    // Skip the declaration itself and doc comments.
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("///") || trimmed.hasPrefix("//") { continue }
                    if trimmed.contains("public func \(seam)") { continue }
                    if isTest { continue }
                    callersByName[seam, default: []].append(
                        "\(url.lastPathComponent):\(index + 1)"
                    )
                }
            }
        }
    }

    // KNOWN DEAD SEAM. Both are public with zero non-test callers — the MCP
    // Hub has no way to invalidate the dispatcher's server cache. When a
    // production owner is wired (or the seams are made internal), this fails
    // and the ledger row flips.
    #expect(
        callersByName["_invalidateListServersCache"] == [],
        "a production caller appeared for _invalidateListServersCache: \(callersByName["_invalidateListServersCache"] ?? []) — the seam now has an owner; update the ledger row."
    )
    #expect(
        callersByName["_setListServersTTL"] == [],
        "a production caller appeared for _setListServersTTL: \(callersByName["_setListServersTTL"] ?? [])"
    )

    // Non-vacuity: the scan must actually have walked Swift sources. Without
    // this, a broken path would report "no callers" for the wrong reason.
    var swiftFilesSeen = 0
    for base in searchRoots {
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil
        ) else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" {
            swiftFilesSeen += 1
        }
    }
    #expect(swiftFilesSeen > 100, "the source scan walked only \(swiftFilesSeen) Swift files — it is not reaching the tree")
}

/// Walks up from this source file to the repository root (the directory holding
/// the root `Package.swift` next to `Modules/`).
func evalRepositoryRoot() -> URL? {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        let manifest = directory.appendingPathComponent("Package.swift")
        let modules = directory.appendingPathComponent("Modules", isDirectory: true)
        if FileManager.default.fileExists(atPath: manifest.path),
           FileManager.default.fileExists(atPath: modules.path) {
            return directory
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { return nil }
        directory = parent
    }
    return nil
}

// MARK: - mcp.subprocess.childEnvironment
//
// Every stdio MCP child inherits the app's FULL environment and the per-server
// `env` dict merges OVER it. There is no allowlist and no scrub. Two quiet
// consequences: any secret in the app's environment reaches every configured
// MCP server binary, and a server configured with NO env dict is
// indistinguishable from one configured with an EMPTY one.

@Test func evalMCPSubprocessChildEnvironment_perServerValuesWinOverInherited() async throws {
    let marker = "NATIVE_AGENT_MCP_EVAL_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    setenv(marker, "inherited", 1)
    defer { unsetenv(marker) }

    func dumpEnvironment(env: [String: String]?) async throws -> [String: String] {
        let dumpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-env-dump-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
        let dumpPath = dumpDir.appendingPathComponent("env.json")
        let script = try writePythonMCPHelper(envDumpPath: dumpPath.path)
        let proc = try MCPSubprocess.fromServerCommand(
            serverId: "env-probe",
            command: pythonHelperCommand(script),
            env: env
        )
        try await proc.start()
        _ = try await proc.request(method: "tools/list", params: .object([:]))
        await proc.stop()
        let data = try Data(contentsOf: dumpPath)
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
        try? FileManager.default.removeItem(at: dumpDir)
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        return parsed
    }

    // (a) NO env dict — the merge branch never runs; the child gets the raw
    //     inherited environment.
    let inheritedOnly = try await dumpEnvironment(env: nil)
    #expect(
        inheritedOnly[marker] == "inherited",
        "an stdio MCP child inherits the app's FULL environment. If a scrub or allowlist was added, update this eval and the ledger row."
    )
    #expect(inheritedOnly["PATH"] != nil, "PATH must survive — the merge exists to keep it")

    // (b) EMPTY env dict — the merge branch DOES run, but with nothing to
    //     apply. Structurally indistinguishable from (a): "this server should
    //     run clean" is not expressible in the config.
    let emptyDict = try await dumpEnvironment(env: [:])
    #expect(
        emptyDict[marker] == "inherited",
        "KNOWN GAP: an empty per-server env dict does NOT scrub the inherited environment — it is indistinguishable from omitting the key."
    )

    // (c) PER-SERVER VALUES WIN. If the merge order ever inverted, every
    //     per-server override would be silently ignored and the server would
    //     just behave oddly.
    let overridden = try await dumpEnvironment(env: [marker: "per-server", "MCP_EVAL_FRESH": "yes"])
    #expect(
        overridden[marker] == "per-server",
        "the per-server env dict must merge OVER the inherited environment — got \(overridden[marker] ?? "nil")"
    )
    #expect(overridden["MCP_EVAL_FRESH"] == "yes", "a key absent from the parent must be added")
    #expect(overridden["PATH"] != nil, "the merge must not drop inherited keys the child needs")
}

import Foundation
import Testing
@testable import MCPDispatcher
import NativeAgentCore
import PersistenceCore

// F-B3 / F-B4 (2026-08-02) — two silent-capability-loss bugs in the MCP lane.
//
// F-B3: `mcp/cache/tools.json` is the SOLE producer of `mcp__<server>__<tool>`
//       descriptors for the model (MCPToolBridge), and after the Python daemon
//       was retired NOTHING in the app wrote it — only test fixtures did. A
//       working MCP server therefore contributed zero tools, with no error and
//       no log. Canonical cutover residue.
//
// F-B4: the MCP child's stderr pipe was assigned and never read. A server that
//       logs past the ~64KB pipe buffer blocks in write(2), stops answering
//       JSON-RPC, gets evicted as wedged, respawns, and repeats — and the bytes
//       explaining why were discarded.

// MARK: - stdio MCP server fixture

/// Writes a newline-delimited-JSON MCP server in Python. Options let a test
/// flood stderr or die with a traceback.
private func writeStdioServer(
    toolNames: [String],
    stderrFloodBytes: Int = 0,
    dieAfterInitialize: Bool = false
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("server.py")
    let toolsJSON = toolNames
        .map { #"{"name": "\#($0)", "description": "d-\#($0)", "inputSchema": {"type": "object", "properties": {}}}"# }
        .joined(separator: ", ")
    let script = """
    import sys, json

    FLOOD = \(stderrFloodBytes)
    DIE = \(dieAfterInitialize ? "True" : "False")

    # The flood happens BEFORE we ever read stdin. With an undrained stderr pipe
    # this blocks in write(2) at ~64KB and the initialize handshake never lands.
    if FLOOD > 0:
        chunk = "MCP-FIXTURE-STDERR-NOISE " * 40 + "\\n"
        written = 0
        while written < FLOOD:
            sys.stderr.write(chunk)
            written += len(chunk)
        sys.stderr.write("MCP-FIXTURE-TAIL-MARKER\\n")
        sys.stderr.flush()

    TOOLS = [\(toolsJSON)]

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            sys.stdout.write(json.dumps({
                "jsonrpc": "2.0", "id": mid,
                "result": {"protocolVersion": "2024-11-05", "capabilities": {}}
            }) + "\\n")
            sys.stdout.flush()
            continue
        if mid is None:
            if DIE:
                sys.stderr.write("Traceback (most recent call last):\\n")
                sys.stderr.write("RuntimeError: MCP-FIXTURE-FATAL\\n")
                sys.stderr.flush()
                sys.exit(3)
            continue
        if method == "tools/list":
            sys.stdout.write(json.dumps({
                "jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}
            }) + "\\n")
        else:
            sys.stdout.write(json.dumps({
                "jsonrpc": "2.0", "id": mid,
                "error": {"code": -32601, "message": "unknown"}
            }) + "\\n")
        sys.stdout.flush()
    """
    try Data(script.utf8).write(to: path)
    return path
}

private func seedServers(_ servers: [JSONValue], root: URL) throws {
    let dir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONValue.array(servers)
        .serializedData(pretty: true)
        .write(to: dir.appendingPathComponent("servers.json"))
}

private func stdioServerRecord(id: String, command: String) -> JSONValue {
    .object([
        "id": .string(id),
        "name": .string(id),
        "transport": .string("stdio"),
        "endpoint": .string(""),
        "command": .string(command),
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "riskClass": .string("network_read"),
    ])
}

private func tempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-root-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - F-B3: the tools cache has a producer again

@Suite(.serialized)
struct MCPToolsCacheProducerTests {

    /// THE bug: a live, working stdio server contributed ZERO descriptors to
    /// the model because nothing ever stamped `mcp/cache/tools.json`.
    /// PRE-FIX this fails at the final assertion — `listMCPToolNames` is empty
    /// even though `listToolsLive` returned three tools.
    @Test func liveHandshakeStampsToolsCacheAndSurfacesBridgedNames() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try writeStdioServer(toolNames: ["alpha", "beta", "gamma"])
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let command = "/usr/bin/python3 \(script.path)"
        try seedServers([stdioServerRecord(id: "fixture-srv", command: command)], root: root)

        let pool = MCPSubprocessPool()
        await pool.updateSpecs([.init(serverId: "fixture-srv", command: command)])
        defer { Task { await pool.stopAll() } }

        let dispatcher = SwiftNativeMCPDispatcher(root: root)
        await MCPLiveCache.shared._clear()
        let live = try await dispatcher.listToolsLive(
            forServer: "fixture-srv", cached: false, pool: pool
        )
        #expect(live.count == 3)

        // The cache file must now exist and carry the handshake result.
        let cachePath = root
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("tools.json")
        #expect(FileManager.default.fileExists(atPath: cachePath.path))

        // ...and, crucially, the MODEL-FACING bridge now sees the tools.
        MCPToolBridge._resetEmptyServerWarnings()
        let names = MCPToolBridge.listMCPToolNames(dataRoot: root)
        #expect(names == [
            "mcp__fixture-srv__alpha",
            "mcp__fixture-srv__beta",
            "mcp__fixture-srv__gamma",
        ])
        // The descriptor must carry the upstream inputSchema through, not just
        // the name — a nil schema forces a permissive fallback provider-side.
        let descriptors = MCPToolBridge.listMCPTools(dataRoot: root)
        #expect(descriptors.first?.inputSchema != nil)
        #expect(descriptors.first?.description == "d-alpha")
        #expect(MCPToolBridge.emptyServerWarnings.isEmpty)
    }

    /// `refreshAllToolsCaches()` is the startup/warm entry point. It must not
    /// let one broken server blind the model to the working ones.
    @Test func refreshAllToolsCaches_reportsPerServerAndSurvivesABadServer() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try writeStdioServer(toolNames: ["ok1", "ok2"])
        defer { try? FileManager.default.removeItem(at: good.deletingLastPathComponent()) }

        let goodCommand = "/usr/bin/python3 \(good.path)"
        let badCommand = "/usr/bin/python3 /nonexistent/definitely-not-here.py"
        try seedServers([
            stdioServerRecord(id: "good-srv", command: goodCommand),
            stdioServerRecord(id: "bad-srv", command: badCommand),
        ], root: root)

        let pool = MCPSubprocessPool()
        await pool.updateSpecs([
            .init(serverId: "good-srv", command: goodCommand),
            .init(serverId: "bad-srv", command: badCommand),
        ])
        defer { Task { await pool.stopAll() } }

        let dispatcher = SwiftNativeMCPDispatcher(root: root)
        await MCPLiveCache.shared._clear()
        let report = await dispatcher.refreshAllToolsCaches(pool: pool)

        #expect(report["good-srv"] == "2")
        #expect(report["bad-srv"]?.hasPrefix("error:") == true)

        MCPToolBridge._resetEmptyServerWarnings()
        let names = MCPToolBridge.listMCPToolNames(dataRoot: root)
        #expect(names == ["mcp__good-srv__ok1", "mcp__good-srv__ok2"])
        // The broken server must be LOUD, not silent.
        #expect(MCPToolBridge.emptyServerWarnings == ["bad-srv"])
    }

    /// FAIL LOUD: a configured server with no cache entry — the exact state
    /// every stdio server shipped in — must record a warning rather than
    /// vanishing. PRE-FIX `listMCPTools` just `continue`d.
    @Test func configuredServerWithNoCacheEntryWarnsLoudly() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedServers([
            stdioServerRecord(id: "ghost-srv", command: "/usr/bin/true"),
        ], root: root)

        MCPToolBridge._resetEmptyServerWarnings()
        let descriptors = MCPToolBridge.listMCPTools(dataRoot: root)
        #expect(descriptors.isEmpty)
        #expect(MCPToolBridge.emptyServerWarnings == ["ghost-srv"])

        // Deduped: the tool list is rebuilt every chat turn; the warning is
        // once per server, not once per turn.
        _ = MCPToolBridge.listMCPTools(dataRoot: root)
        _ = MCPToolBridge.listMCPTools(dataRoot: root)
        #expect(MCPToolBridge.emptyServerWarnings == ["ghost-srv"])
    }

    /// An entry that exists but lists zero tools is the same silent loss.
    @Test func cacheEntryWithZeroToolsAlsoWarns() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedServers([
            stdioServerRecord(id: "empty-srv", command: "/usr/bin/true"),
        ], root: root)
        let cacheDir = root
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try JSONValue.object([
            "empty-srv": .object(["createdAt": .string("now"), "tools": .array([])]),
        ]).serializedData(pretty: true)
            .write(to: cacheDir.appendingPathComponent("tools.json"))

        MCPToolBridge._resetEmptyServerWarnings()
        _ = MCPToolBridge.listMCPTools(dataRoot: root)
        #expect(MCPToolBridge.emptyServerWarnings == ["empty-srv"])
    }
}

// MARK: - F-B4: stderr is drained and its tail survives

@Suite(.serialized)
struct MCPSubprocessStderrDrainTests {

    /// THE bug: >64KB of stderr fills the pipe, the child blocks in write(2)
    /// before it can answer `initialize`, and `start()` times out.
    /// PRE-FIX this test hangs on the handshake and then fails; POST-FIX the
    /// child streams 512KB happily and still serves tools/list.
    @Test func chatteryServerOnStderrDoesNotWedge() async throws {
        let script = try writeStdioServer(
            toolNames: ["alpha"],
            stderrFloodBytes: 512 * 1024
        )
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let proc = try MCPSubprocess.fromServerCommand(
            serverId: "chatty-srv",
            command: "/usr/bin/python3 \(script.path)"
        )
        try await proc.start()
        let result = try await proc.request(method: "tools/list", params: .object([:]))
        #expect(SwiftNativeMCPDispatcher.extractArray(result, key: "tools").count == 1)

        // Bounded ring: we keep the TAIL, not 512KB of noise.
        let tail = await proc.stderrTailSnapshot()
        #expect(!tail.isEmpty)
        #expect(tail.utf8.count <= _MCPStderrTail.limit + 8)
        #expect(tail.contains("MCP-FIXTURE-TAIL-MARKER"))

        await proc.stop()
    }

    /// The death reason must carry the stderr tail so the eviction record says
    /// WHY. PRE-FIX the reason was a bare "exited (status=3)".
    @Test func unexpectedDeathReasonCarriesStderrTail() async throws {
        let script = try writeStdioServer(toolNames: ["alpha"], dieAfterInitialize: true)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let proc = try MCPSubprocess.fromServerCommand(
            serverId: "dying-srv",
            command: "/usr/bin/python3 \(script.path)"
        )
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _reason: String?
            var reason: String? { lock.lock(); defer { lock.unlock() }; return _reason }
            func set(_ value: String) { lock.lock(); _reason = value; lock.unlock() }
        }
        let box = Box()
        // The fixture exits on the first NOTIFICATION it sees, which is
        // `notifications/initialized` — i.e. during start(), before the
        // handshake returns. Either surface (thrown spawnFailed or the
        // termination reason) must carry the tail.
        await proc.onUnexpectedTermination { _, reason in box.set(reason) }
        var thrownMessage: String?
        do {
            try await proc.start()
        } catch let error as MCPSubprocessError {
            if case .spawnFailed(let message) = error { thrownMessage = message }
        }

        // Give the terminationHandler a beat to land.
        for _ in 0..<50 where box.reason == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let surfaced = [thrownMessage, box.reason].compactMap { $0 }.joined(separator: " | ")
        #expect(surfaced.contains("MCP-FIXTURE-FATAL"), "death reason lost the stderr tail: \(surfaced)")

        await proc.stop()
    }

    /// The ring must be bounded even under a huge flood — memory safety, not
    /// just liveness.
    @Test func stderrTailIsBounded() {
        let ring = _MCPStderrTail()
        for index in 0..<200 {
            ring.append(Data(String(repeating: "x", count: 1_024).utf8))
            if index == 199 { ring.append(Data("FINAL-MARKER".utf8)) }
        }
        let snapshot = ring.snapshot()
        #expect(snapshot.utf8.count <= _MCPStderrTail.limit + 8)
        #expect(snapshot.hasSuffix("FINAL-MARKER"))
        #expect(snapshot.hasPrefix("…"), "a truncated tail must say so")
    }
}

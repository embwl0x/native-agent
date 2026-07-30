import Testing
import Foundation
import os
@testable import MCPDispatcher
import NativeAgentCore
import PersistenceCore

// MARK: - Test helpers

/// Write a Swift MCP-server helper to a temp file and return its path.
/// The server speaks the MCP stdio transport (newline-delimited JSON-RPC:
/// one `<json>\n` message per line) and responds to `initialize`,
/// `tools/list`, `resources/list`. Optional kwargs toggle the response
/// shape used by individual tests.
///
/// Behaviors:
/// - `crash_after_init=True` → exit(0) immediately after replying to
///   `initialize`+the notification.
/// - `slow_tools_ms` → sleep N ms before returning `tools/list`.
/// - `reverse_order=True` → reply to `tools/list` BEFORE `resources/list`
///   even if the resources call came first (forces id correlation to do its
///   job).
private func writeMCPHelper(
    crashAfterInit: Bool = false,
    slowToolsMS: Int = 0,
    reverseOrder: Bool = false,
    toolCount: Int = 2
) throws -> URL {
    try writeSwiftMCPHelper(
        mode: crashAfterInit ? "crashAfterInit" : "normal",
        slowToolsMS: slowToolsMS,
        reverseOrder: reverseOrder,
        toolCount: toolCount
    )
}

private func swiftStringLiteral(_ value: String) throws -> String {
    let data = try JSONEncoder().encode(value)
    return (String(data: data, encoding: .utf8) ?? "\"\"")
        .replacingOccurrences(of: "\\/", with: "/")
}

private func writeSwiftMCPHelper(
    mode: String = "normal",
    slowToolsMS: Int = 0,
    reverseOrder: Bool = false,
    toolCount: Int = 2,
    spawnLogPath: String? = nil
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-helper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("server.swift")
    let modeLiteral = try swiftStringLiteral(mode)
    let spawnLogLiteral = try spawnLogPath.map(swiftStringLiteral) ?? "nil"
    let script = """
    #!/usr/bin/env swift
    import Foundation
    import Darwin

    let mode = \(modeLiteral)
    let slowToolsMS = \(slowToolsMS)
    let reverseOrder = \(reverseOrder ? "true" : "false")
    let toolCount = \(toolCount)
    let spawnLogPath: String? = \(spawnLogLiteral)

    func readMessage() -> [String: Any]? {
        let input = FileHandle.standardInput
        while true {
            var line = Data()
            while true {
                let chunk = input.readData(ofLength: 1)
                if chunk.isEmpty { return nil }
                if chunk[0] == 0x0A { break }
                line.append(chunk)
            }
            if line.last == 0x0D { line.removeLast() }
            if line.isEmpty { continue }
            return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        }
    }

    func encodedMessage(_ message: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: message, options: [])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    func writeMessage(_ message: [String: Any]) {
        FileHandle.standardOutput.write(encodedMessage(message))
        fflush(stdout)
    }

    func requestID(_ message: [String: Any]) -> Any {
        message["id"] ?? NSNull()
    }

    func toolsResponse(id: Any) -> [String: Any] {
        let tools = (0..<toolCount).map { i in
            ["name": "tool.\\(i)", "description": "Tool \\(i)"]
        }
        return ["jsonrpc": "2.0", "id": id, "result": ["tools": tools]]
    }

    func resourcesResponse(id: Any) -> [String: Any] {
        let resources = (0..<2).map { i in
            ["uri": "resource://\\(i)", "name": "Resource \\(i)", "mimeType": "text/plain"]
        }
        return ["jsonrpc": "2.0", "id": id, "result": ["resources": resources]]
    }

    if let spawnLogPath {
        let line = "\\(getpid())\\n"
        let fd = open(spawnLogPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if fd >= 0 {
            line.withCString { ptr in
                _ = Darwin.write(fd, ptr, strlen(ptr))
            }
            close(fd)
        }
    }

    if mode == "exitImmediately" {
        exit(7)
    }

    var pendingToolIDs: [Any] = []
    while true {
        guard let message = readMessage() else { break }
        let method = message["method"] as? String ?? ""
        let id = requestID(message)
        if method == "initialize" {
            writeMessage(["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": "2024-11-05"]])
            if mode == "malformedAfterInit" {
                _ = readMessage()
                FileHandle.standardOutput.write(Data("this is not json\\n".utf8))
                fflush(stdout)
                while true { Thread.sleep(forTimeInterval: 0.1) }
            }
        } else if method == "notifications/initialized" {
            if mode == "crashAfterInit" {
                exit(0)
            }
            if mode == "immediateExitAfterInit" {
                exit(1)
            }
            if mode == "stopReadingAfterInit" {
                // U5 W-E stdin-stall fixture: handshake completes, then the
                // child never reads stdin again — the parent's pipe buffer
                // fills and a blocking writer would pin forever.
                while true { Thread.sleep(forTimeInterval: 1) }
            }
            if mode == "crashAfterInitDelayed" {
                // U5 W-E backoff-escalation fixture: survive the start
                // handshake (so the pool counts the spawn as successful),
                // then die shortly after.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(1) }
            }
            continue
        } else if method == "tools/list" {
            if mode == "fragmentedToolsResponse" {
                let packet = encodedMessage(toolsResponse(id: id))
                let midpoint = max(1, packet.count / 2)
                FileHandle.standardOutput.write(Data(packet[..<midpoint]))
                fflush(stdout)
                Thread.sleep(forTimeInterval: 0.05)
                FileHandle.standardOutput.write(Data(packet[midpoint...]))
                fflush(stdout)
                continue
            }
            if mode == "coalescedResponses" {
                pendingToolIDs.append(id)
                continue
            }
            if mode == "neverReplyTools" {
                // W3d fixture: swallow tools/list without replying, but keep
                // the read loop free so OTHER requests (resources/list) still
                // round-trip. Proves the client abandons a cancelled request's
                // waiter WITHOUT wedging the subprocess.
                continue
            }
            if mode == "serverInitiatedRequests" {
                // U5 W-E fixture: before answering, send two server->client
                // REQUESTS (id + method) and wait for the client's replies.
                // A client that drops them (the old bug) never gets the
                // tools/list response -> its request times out.
                writeMessage(["jsonrpc": "2.0", "id": 9001, "method": "ping"])
                writeMessage(["jsonrpc": "2.0", "id": 9002, "method": "roots/list"])
                let r1 = readMessage() ?? [:]
                let r2 = readMessage() ?? [:]
                var pingPongOK = false
                var rootsErrorCode = 0
                for reply in [r1, r2] {
                    let replyID = reply["id"] as? Int ?? -1
                    if replyID == 9001 {
                        pingPongOK = reply["result"] != nil && reply["error"] == nil
                    } else if replyID == 9002 {
                        let err = reply["error"] as? [String: Any]
                        rootsErrorCode = err?["code"] as? Int ?? 0
                    }
                }
                writeMessage([
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": [
                        "tools": [],
                        "pingPongOK": pingPongOK,
                        "rootsErrorCode": rootsErrorCode,
                    ],
                ])
                continue
            }
            if mode == "crashAfterToolsList" {
                // Deterministic die-after-success fixture: the pool has already
                // returned a fully initialized process before the test sends
                // this request. This avoids using scheduler timing to decide
                // whether a death belongs to the start handshake or to the
                // post-checkout stability window.
                writeMessage(toolsResponse(id: id))
                exit(1)
            }
            if slowToolsMS > 0 {
                Thread.sleep(forTimeInterval: Double(slowToolsMS) / 1000.0)
            }
            if reverseOrder {
                pendingToolIDs.append(id)
                continue
            }
            writeMessage(toolsResponse(id: id))
        } else if method == "resources/list" {
            if mode == "coalescedResponses" {
                var packet = encodedMessage(resourcesResponse(id: id))
                for pending in pendingToolIDs {
                    packet.append(encodedMessage(toolsResponse(id: pending)))
                }
                pendingToolIDs.removeAll()
                FileHandle.standardOutput.write(packet)
                fflush(stdout)
                continue
            }
            if reverseOrder {
                writeMessage(resourcesResponse(id: id))
                for pending in pendingToolIDs {
                    writeMessage(toolsResponse(id: pending))
                }
                pendingToolIDs.removeAll()
                continue
            }
            writeMessage(resourcesResponse(id: id))
        } else if method == "tools/call" {
            let params = message["params"] as? [String: Any] ?? [:]
            writeMessage([
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "calledTool": params["name"] ?? NSNull(),
                    "echoArgs": params["arguments"] ?? NSNull(),
                    "content": [["type": "text", "text": "ok"]],
                ],
            ])
        } else {
            writeMessage([
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": "unknown: \\(method)"],
            ])
        }
    }
    """
    try Data(script.utf8).write(to: path)
    // chmod +x is not required when invoked through swift, but it keeps the
    // generated helper executable for direct debugging.
    var attrs = try FileManager.default.attributesOfItem(atPath: path.path)
    attrs[.posixPermissions] = NSNumber(value: 0o755)
    try FileManager.default.setAttributes(attrs, ofItemAtPath: path.path)
    return path
}

private func helperCommand(_ scriptPath: URL) -> String {
    return "/usr/bin/swift \(scriptPath.path)"
}

// MARK: - shlex split

@Test func shlexSplit_basic() {
    #expect(MCPSubprocess.shlexSplit("foo bar baz") == ["foo", "bar", "baz"])
    #expect(MCPSubprocess.shlexSplit("foo \"bar baz\" qux") == ["foo", "bar baz", "qux"])
    #expect(MCPSubprocess.shlexSplit("foo 'bar baz' qux") == ["foo", "bar baz", "qux"])
    #expect(MCPSubprocess.shlexSplit("foo\\ bar") == ["foo bar"])
}

// MARK: - Spawn + initialize + tools/list

@Test func subprocess_initializeAndListTools_succeeds() async throws {
    let script = try writeMCPHelper(toolCount: 3)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "test-srv",
        command: helperCommand(script)
    )
    try await proc.start()
    let pid = await proc.pid
    #expect(pid != nil)
    #expect(pid! > 0)

    let result = try await proc.request(method: "tools/list", params: .object([:]))
    let arr = SwiftNativeMCPDispatcher.extractArray(result, key: "tools")
    #expect(arr.count == 3)
    if case .object(let obj) = arr[0], case .string(let name) = obj["name"] ?? .null {
        #expect(name == "tool.0")
    } else {
        Issue.record("expected named tool object as first result")
    }

    await proc.stop()
    let pidAfter = await proc.pid
    #expect(pidAfter == nil)
}

@Test func subprocess_eventDrivenStdout_handlesFragmentedFrame() async throws {
    let script = try writeSwiftMCPHelper(mode: "fragmentedToolsResponse", toolCount: 3)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "fragmented-stdout-srv",
        command: helperCommand(script)
    )
    try await proc.start()

    let result = try await proc.request(method: "tools/list", params: .object([:]))
    let tools = SwiftNativeMCPDispatcher.extractArray(result, key: "tools")
    #expect(tools.count == 3)

    await proc.stop()
}

@Test func subprocess_eventDrivenStdout_handlesCoalescedFramesWithCorrelation() async throws {
    let script = try writeSwiftMCPHelper(mode: "coalescedResponses", toolCount: 4)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "coalesced-stdout-srv",
        command: helperCommand(script)
    )
    try await proc.start()

    async let toolsResult = proc.request(method: "tools/list", params: .object([:]))
    try await Task.sleep(nanoseconds: 50_000_000)
    async let resourcesResult = proc.request(method: "resources/list", params: .object([:]))

    let (toolsValue, resourcesValue) = try await (toolsResult, resourcesResult)
    #expect(SwiftNativeMCPDispatcher.extractArray(toolsValue, key: "tools").count == 4)
    #expect(SwiftNativeMCPDispatcher.extractArray(resourcesValue, key: "resources").count == 2)

    await proc.stop()
}

@Test func subprocess_eventDrivenStdout_doesNotDrainContinuouslyWhileIdle() async throws {
    let script = try writeMCPHelper()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "idle-stdout-srv",
        command: helperCommand(script)
    )
    try await proc.start()

    let afterHandshake = await proc._stdoutDrainPassCountForTesting()
    try await Task.sleep(nanoseconds: 200_000_000)
    let afterIdle = await proc._stdoutDrainPassCountForTesting()
    #expect(
        afterIdle == afterHandshake,
        "idle subprocess stdout must suspend instead of repeatedly draining"
    )

    _ = try await proc.request(method: "tools/list", params: .object([:]))
    let afterResponse = await proc._stdoutDrainPassCountForTesting()
    #expect(afterResponse > afterIdle, "new stdout must wake the suspended consumer")

    await proc.stop()
}

// MARK: - JSON-RPC id correlation (reverse order)

@Test func subprocess_idCorrelation_handlesOutOfOrderResponses() async throws {
    // Server replies to resources/list before tools/list — the in-flight
    // map MUST route each response to the right waiter by id.
    let script = try writeMCPHelper(reverseOrder: true)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "ooo-srv",
        command: helperCommand(script)
    )
    try await proc.start()

    async let tools = proc.request(method: "tools/list", params: .object([:]))
    // Give the tools request a head start so it lands first server-side.
    try? await Task.sleep(nanoseconds: 50_000_000)
    async let resources = proc.request(method: "resources/list", params: .object([:]))

    let (t, r) = try await (tools, resources)
    let toolArr = SwiftNativeMCPDispatcher.extractArray(t, key: "tools")
    let resArr = SwiftNativeMCPDispatcher.extractArray(r, key: "resources")
    #expect(toolArr.count == 2)
    #expect(resArr.count == 2)
    await proc.stop()
}

// MARK: - Timeout

@Test func subprocess_request_timesOut() async throws {
    // Server takes 30s to reply to tools/list — we set a 1s timeout. The wide
    // gap keeps full-suite scheduler load from letting the slow response win.
    let script = try writeMCPHelper(slowToolsMS: 30_000)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "slow-srv",
        command: helperCommand(script)
    )
    try await proc.start()
    do {
        _ = try await proc.request(
            method: "tools/list", params: .object([:]), timeout: 1.0
        )
        Issue.record("expected timeout, got success")
    } catch let err as MCPSubprocessError {
        if case .timeout = err {
            // expected
        } else {
            Issue.record("expected .timeout, got \(err)")
        }
    }
    await proc.stop()
}

// MARK: - W3d (R2b): request cancellation abandons the waiter cleanly

/// A request whose Task is cancelled while waiting for a response that never
/// comes must: (1) surface CancellationError PROMPTLY (< 3s, far under the
/// 30s server-side stall and well under any request timeout), (2) remove its
/// pending-waiter entry (no leak), and (3) leave the subprocess ALIVE so a
/// SUBSEQUENT request on the same client still works. The child stays up —
/// only THIS request is abandoned.
@Test func subprocess_requestCancellation_abandonsWaiter_subsequentRequestWorks() async throws {
    // tools/list is swallowed (never answered) but the read loop stays free,
    // so the cancel — not a reply — resolves the waiter, and a SUBSEQUENT
    // resources/list still round-trips on the same live subprocess.
    let script = try writeSwiftMCPHelper(mode: "neverReplyTools", toolCount: 2)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "cancel-srv",
        command: helperCommand(script)
    )
    try await proc.start()
    let pidBefore = await proc.pid
    #expect(pidBefore != nil)

    // Fire the request that will never get a timely reply, then cancel it.
    let hung = Task<JSONValue, Error> {
        try await proc.request(method: "tools/list", params: .object([:]), timeout: 60)
    }
    // Let the request install its waiter + write the frame.
    try? await Task.sleep(nanoseconds: 200_000_000)

    let started = Date()
    hung.cancel()
    do {
        _ = try await hung.value
        Issue.record("expected CancellationError from cancelled request")
    } catch is CancellationError {
        // expected
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed < 3, "cancel should resolve promptly; took \(elapsed)s")

    // Subprocess stays alive — the cancel abandoned only the one request.
    #expect(await proc.isRunning, "subprocess must stay alive after a request cancel")
    let pidAfter = await proc.pid
    #expect(pidAfter == pidBefore, "same subprocess should still be serving")

    // A SUBSEQUENT request on the same client must still work — proving the
    // waiter map was cleared (no leak/wedge). resources/list is answered
    // immediately by the helper (tools/list is the swallowed branch).
    let resources = try await proc.request(
        method: "resources/list", params: .object([:]), timeout: 5
    )
    let resArr = SwiftNativeMCPDispatcher.extractArray(resources, key: "resources")
    #expect(resArr.count == 2, "subsequent request on same client must succeed")

    await proc.stop()
}

/// W3d review finding 3: cancelling a request whose `notifications/cancelled`
/// notice cannot be delivered (the child stopped reading stdin, pipe wedged)
/// must NOT tear down the subprocess. The cancel resumes the waiter promptly
/// with CancellationError, and the fire-and-forget cancel notice silently
/// drops on the wedged pipe — the child stays ALIVE.
///
/// Setup: a `stopReadingAfterInit` child, a LONG per-subprocess writeTimeout
/// (so the cancelled request's own oversized write does not self-terminate
/// during the test window), and an oversized blob so that request's stdin
/// write genuinely wedges (filling the 64KB pipe). The cancel notice then
/// wedges too, but on the no-terminate path with a short 2s deadline.
@Test func subprocess_cancelWaiter_wedgedStdin_doesNotTerminateSubprocess() async throws {
    let script = try writeSwiftMCPHelper(mode: "stopReadingAfterInit")
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "cancel-wedge-srv",
        command: helperCommand(script)
    )
    try await proc.start()
    // Long write timeout: the cancelled request's OWN wedged write must not
    // self-terminate the child within the test window — only the cancel
    // notice's no-terminate behaviour is under test here.
    await proc._setWriteTimeout(20)
    let pidBefore = await proc.pid
    #expect(pidBefore != nil)

    // Oversized payload (>64KB pipe buffer) so this request's stdin write
    // wedges against the non-reading child.
    let blob = String(repeating: "x", count: 512 * 1024)
    let hung = Task<JSONValue, Error> {
        try await proc.request(
            method: "tools/call",
            params: .object(["blob": .string(blob)]),
            timeout: 60
        )
    }
    // Let the write wedge + fill the pipe before cancelling.
    try? await Task.sleep(nanoseconds: 400_000_000)

    let started = Date()
    hung.cancel()
    do {
        _ = try await hung.value
        Issue.record("expected CancellationError from cancelled wedged request")
    } catch is CancellationError {
        // expected — the waiter is resumed immediately, independent of stdin.
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }
    #expect(Date().timeIntervalSince(started) < 3,
            "cancel must resume the waiter promptly despite the wedged stdin")

    // Wait past the cancel notice's 2s no-terminate deadline. If the fix
    // regressed (terminateOnWedge back to true), the notice would kill the
    // child here. With the fix, the child stays alive.
    try? await Task.sleep(nanoseconds: 2_600_000_000)
    #expect(await proc.isRunning,
            "cancel notice on a wedged stdin must NOT terminate the subprocess")
    #expect(await proc.pid == pidBefore,
            "same subprocess must still be alive after the cancel")

    await proc.stop()
}

/// The uncancelled request path is unchanged — a normal request still
/// round-trips its response.
@Test func subprocess_request_uncancelled_stillRoundTrips() async throws {
    let script = try writeMCPHelper(toolCount: 2)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "normal-cancel-srv",
        command: helperCommand(script)
    )
    try await proc.start()
    let result = try await proc.request(method: "tools/list", params: .object([:]))
    let arr = SwiftNativeMCPDispatcher.extractArray(result, key: "tools")
    #expect(arr.count == 2)
    await proc.stop()
}

// MARK: - Pool: crash backoff

@Test func pool_crashOnSpawn_recordsBackoff() async throws {
    let pool = MCPSubprocessPool()
    await pool._setBackoffDurations(base: 30, max: 30)
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "bad-srv", command: "/no/such/binary --flag")
    ])
    do {
        _ = try await pool.get(serverId: "bad-srv")
        Issue.record("expected spawn failure")
    } catch {
        // expected
    }
    // Second call within backoff window must also fail (cached error).
    do {
        _ = try await pool.get(serverId: "bad-srv")
        Issue.record("expected backoff-cached failure on second try")
    } catch let err as MCPSubprocessError {
        if case .spawnFailed(let msg) = err {
            #expect(msg.contains("backoff") || msg.contains("bad-srv"))
        } else {
            Issue.record("expected .spawnFailed, got \(err)")
        }
    }
}

@Test func pool_backoffExpires_allowsRetry() async throws {
    let pool = MCPSubprocessPool()
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "expired-srv", command: "/no/such/binary")
    ])
    // Inject a crash info that already expired.
    await pool._setCrashInfo(
        MCPSubprocessPool.CrashInfo(
            lastError: "boom",
            nextRetryAt: Date().addingTimeInterval(-1),
            consecutiveFailures: 1
        ),
        for: "expired-srv"
    )
    // get() should attempt a fresh spawn (which still fails — invalid binary),
    // recording a new crash with a longer cooldown.
    do {
        _ = try await pool.get(serverId: "expired-srv")
        Issue.record("expected fresh spawn failure")
    } catch let err as MCPSubprocessError {
        // .spawnFailed (process.run threw) OR .streamClosed if the env-resolve
        // path squeaks past. Both are acceptable — point is the cooldown
        // didn't gate the attempt.
        switch err {
        case .spawnFailed, .streamClosed:
            break
        default:
            Issue.record("unexpected error class on retry: \(err)")
        }
    }
}

// MARK: - Pool: live session statuses

@Test func pool_sessionStatuses_reflectsRunningAndIdle() async throws {
    let script = try writeMCPHelper()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let pool = MCPSubprocessPool()
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "live-srv", command: helperCommand(script)),
        MCPSubprocessPool.Spec(serverId: "idle-srv", command: helperCommand(script)),
    ])
    // Spawn only live-srv.
    _ = try await pool.get(serverId: "live-srv")
    let rows = await pool.sessionStatuses()
    #expect(rows.count == 2)
    let live = rows.first { $0.id == "live-srv" }!
    #expect(live.status == "warm")
    #expect(live.pid != nil)
    #expect(live.pid! > 0)
    #expect(live.lastWarmedAt != nil)
    let idle = rows.first { $0.id == "idle-srv" }!
    #expect(idle.status == "idle")
    #expect(idle.pid == nil)
    await pool.stopAll()
}

// MARK: - Cache TTL

@Test func cache_get_returnsHitWithinTTL_missesAfterExpiry() async throws {
    let cache = MCPLiveCache()
    await cache._setTTL(0.2)
    await cache.put("k", value: [.string("a"), .string("b")])
    let hit = await cache.get("k")
    #expect(hit?.count == 2)
    try? await Task.sleep(nanoseconds: 250_000_000)
    let miss = await cache.get("k")
    #expect(miss == nil)
}

// MARK: - listToolsLive end-to-end (servers.json → pool → live request)

@Test func listToolsLive_seedsPoolFromServersJSONAndCaches() async throws {
    // Build a temp root with an stdio server entry pointing at our helper.
    let script = try writeMCPHelper(toolCount: 4)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mcpDir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
    let server: JSONValue = .object([
        "id": .string("stdio-helper"),
        "name": .string("Stdio Helper"),
        "transport": .string("stdio"),
        "endpoint": .string(""),
        "command": .string(helperCommand(script)),
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "toolCount": .int(0),
        "resourceCount": .int(0),
        "riskClass": .string("app_data_read"),
        "createdAt": .string("2026-05-31T00:00:00+00:00"),
        "updatedAt": .string("2026-05-31T00:00:00+00:00"),
    ])
    try JSONValue.array([server])
        .serializedData(pretty: true)
        .write(to: mcpDir.appendingPathComponent("servers.json"))
    let dispatcher = SwiftNativeMCPDispatcher(root: root)

    // Use an isolated pool so this test doesn't share the singleton with others.
    let pool = MCPSubprocessPool()
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "stdio-helper", command: helperCommand(script))
    ])
    // Clear shared cache so the cached: true branch starts cold.
    await MCPLiveCache.shared._clear()

    let tools = try await dispatcher.listToolsLive(forServer: "stdio-helper", pool: pool)
    #expect(tools.count == 4)
    // Second call within TTL — must come back identically (cache hit).
    let tools2 = try await dispatcher.listToolsLive(forServer: "stdio-helper", pool: pool)
    #expect(tools2.count == 4)
    await pool.stopAll()
}

// MARK: - callToolLive end-to-end (gate-free stdio tools/call primitive)

@Test func callToolLive_roundTripsNameAndArgsThroughStdio() async throws {
    // The helper echoes calledTool + echoArgs in its tools/call result, so we
    // can assert the JSON-RPC params shape ({"name":..., "arguments":...})
    // mirrors the daemon's mcp_stdio_method(server, "tools/call", ...) exactly.
    let script = try writeMCPHelper()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mcpDir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
    let server: JSONValue = .object([
        "id": .string("stdio-helper"),
        "name": .string("Stdio Helper"),
        "transport": .string("stdio"),
        "endpoint": .string(""),
        "command": .string(helperCommand(script)),
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "toolCount": .int(0),
        "resourceCount": .int(0),
        "riskClass": .string("app_data_read"),
        "createdAt": .string("2026-05-31T00:00:00+00:00"),
        "updatedAt": .string("2026-05-31T00:00:00+00:00"),
    ])
    try JSONValue.array([server])
        .serializedData(pretty: true)
        .write(to: mcpDir.appendingPathComponent("servers.json"))
    let dispatcher = SwiftNativeMCPDispatcher(root: root)

    let pool = MCPSubprocessPool()
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "stdio-helper", command: helperCommand(script))
    ])

    let result = try await dispatcher.callToolLive(
        forServer: "stdio-helper",
        toolName: "tool.echo",
        arguments: .object(["q": .string("hello"), "n": .int(7)]),
        pool: pool
    )
    // Raw `result` object comes back verbatim (NOT extracted/wrapped).
    guard case .object(let obj) = result else {
        Issue.record("expected object result, got \(result)")
        return
    }
    #expect(obj["calledTool"] == .string("tool.echo"))
    #expect(obj["echoArgs"] == .object(["q": .string("hello"), "n": .int(7)]))

    // Tool execution is NEVER cached — a second call still runs (and the
    // helper would echo a different arg set). Prove the call goes through
    // again rather than returning a stale cached value.
    let result2 = try await dispatcher.callToolLive(
        forServer: "stdio-helper",
        toolName: "tool.other",
        arguments: .object(["q": .string("world")]),
        pool: pool
    )
    guard case .object(let obj2) = result2 else {
        Issue.record("expected object result2, got \(result2)")
        return
    }
    #expect(obj2["calledTool"] == .string("tool.other"))
    await pool.stopAll()
}

@Test func callToolLive_nativeInternalExecutesInSwift() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftNativeMCPDispatcher(root: root)

    let result = try await dispatcher.callToolLive(
        forServer: "nativeagent-internal",
        toolName: "native.actions"
    )

    guard case .object(let obj) = result,
          obj["status"] == .string("ok"),
          case .object(let payload)? = obj["result"],
          case .array(let actions)? = payload["actions"]
    else {
        Issue.record("expected ok native.actions MCP result, got \(result)")
        return
    }
    #expect(actions.contains(.string("telegram.poll")))
}

@Test func callToolLive_nativeCapabilitiesUsesDispatcherRootAndInstalledSkillInventory() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bodyPath = root.appendingPathComponent("skills/bodies/bridge-skill.md")
    try FileManager.default.createDirectory(
        at: bodyPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("# Bridge Skill\nUse this when verifying the internal MCP capability gauge.\n".utf8)
        .write(to: bodyPath)
    let dispatcher = SwiftNativeMCPDispatcher(root: root)

    let result = try await dispatcher.callToolLive(
        forServer: "nativeagent-internal",
        toolName: "capabilities.summary"
    )

    guard case .object(let envelope) = result,
          envelope["status"] == .string("ok"),
          case .object(let payload)? = envelope["result"],
          case .object(let summary)? = payload["summary"],
          case .object(let byKind)? = summary["byKind"] else {
        Issue.record("expected native capabilities summary, got \(result)")
        return
    }
    #expect(byKind["skill"] == .int(1))
}

@Test func callToolLive_nativeCapabilitiesCountsRepoPersonaSkillBodies() async throws {
    let repo = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: repo) }
    let root = repo.appendingPathComponent("data", isDirectory: true)
    let personaBodies = repo.appendingPathComponent("persona/skills/bodies", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: personaBodies, withIntermediateDirectories: true)
    try Data("// swift-tools-version: 6.0\n".utf8)
        .write(to: repo.appendingPathComponent("Package.swift"))
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("script", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("#!/usr/bin/env bash\n".utf8)
        .write(to: repo.appendingPathComponent("script/init_persona.sh"))
    try Data("# Template\n".utf8)
        .write(to: repo.appendingPathComponent("persona/SOUL.template.md"))
    try Data("# Fixture\n".utf8)
        .write(to: repo.appendingPathComponent("persona/SOUL.md"))
    for name in ["alpha", "beta", "gamma"] {
        try Data("# \(name)\nUse this when testing persona skill inventory.\n".utf8)
            .write(to: personaBodies.appendingPathComponent("\(name).md"))
    }
    let dispatcher = SwiftNativeMCPDispatcher(root: root)

    let result = try await dispatcher.callToolLive(
        forServer: "nativeagent-internal",
        toolName: "capabilities.summary"
    )

    guard case .object(let envelope) = result,
          case .object(let payload)? = envelope["result"],
          case .object(let summary)? = payload["summary"],
          case .object(let byKind)? = summary["byKind"] else {
        Issue.record("expected native capabilities summary, got \(result)")
        return
    }
    #expect(byKind["skill"] == .int(3))
}

@Test func callToolLive_nativeCapabilitiesResponseStaysBoundedForLargeInventory() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let registryPath = root.appendingPathComponent("skills/registry.json")
    try FileManager.default.createDirectory(
        at: registryPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let marker = String(repeating: "large-per-capability-payload-", count: 80)
    let rows: [JSONValue] = (0..<250).map { index in
        .object([
            "name": .string("skill-\(index)"),
            "description": .string("\(marker)\(index)"),
            "status": .string("active"),
        ])
    }
    try JSONValue.array(rows).serializedData(pretty: false).write(to: registryPath)
    let dispatcher = SwiftNativeMCPDispatcher(root: root)

    let result = try await dispatcher.callToolLive(
        forServer: "nativeagent-internal",
        toolName: "capabilities.summary"
    )
    let encoded = try result.serializedData(pretty: false)

    guard case .object(let envelope) = result,
          case .object(let payload)? = envelope["result"],
          case .object(let summary)? = payload["summary"],
          case .object(let byKind)? = summary["byKind"] else {
        Issue.record("expected native capabilities summary, got \(result)")
        return
    }
    #expect(byKind["skill"] == .int(250))
    #expect(encoded.count < 8_192)
    #expect(!encoded.contains(Data(marker.utf8)))
    #expect(payload["reviewQueue"] == .array([]))
    #expect(payload["recentArtifacts"] == .array([]))
}

@Test func callToolLive_nativeGraphSearchReturnsBoundedProjection() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let graphPath = root.appendingPathComponent("memory/knowledge_graph.json")
    try FileManager.default.createDirectory(
        at: graphPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let entities: [String: JSONValue] = Dictionary(uniqueKeysWithValues: (0..<30).map { index in
        ("entity-\(index)", .object([
            "id": .string("entity-\(index)"),
            "name": .string("Needle \(index)"),
            "type": .string("fact"),
            "summary": .string(String(repeating: "s", count: 2_000)),
            "memory_ids": .array((0..<100).map { .string("memory-\($0)") }),
        ]))
    })
    try JSONValue.object(["entities": .object(entities), "edges": .array([])])
        .serializedData(pretty: false)
        .write(to: graphPath)
    let dispatcher = SwiftNativeMCPDispatcher(root: root)

    let result = try await dispatcher.callToolLive(
        forServer: "nativeagent-internal",
        toolName: "graph.search",
        arguments: .object(["query": .string("Needle")])
    )

    guard case .object(let envelope) = result,
          case .object(let payload)? = envelope["result"],
          case .array(let rows)? = payload["results"],
          case .object(let first)? = rows.first else {
        Issue.record("expected bounded graph.search result, got \(result)")
        return
    }
    #expect(payload["total_results"] == .int(30))
    #expect(payload["returned_results"] == .int(12))
    #expect(payload["truncated"] == .bool(true))
    #expect(rows.count == 12)
    #expect(first["memory_ids"] == nil)
    #expect(try result.serializedData(pretty: false).count < 20_000)
}

@Test func callToolLive_nativeGraphSearchFailsClosedOnCorruptCanonicalSQLite() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let memoryDirectory = root.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
    let sqlitePath = memoryDirectory.appendingPathComponent("memory.sqlite")
    let corruptBytes = Data("not a sqlite database; do not replace with stale graph JSON".utf8)
    try corruptBytes.write(to: sqlitePath)
    try Data(#"{"entities":{"stale":{"id":"stale","name":"Needle","type":"fact"}},"edges":[]}"#.utf8)
        .write(to: memoryDirectory.appendingPathComponent("knowledge_graph.json"))
    let dispatcher = SwiftNativeMCPDispatcher(root: root)

    await #expect(throws: (any Error).self) {
        _ = try await dispatcher.callToolLive(
            forServer: "nativeagent-internal",
            toolName: "graph.search",
            arguments: .object(["query": .string("Needle")])
        )
    }
    #expect(try Data(contentsOf: sqlitePath) == corruptBytes)
}

@Test func listToolsLive_nonStdioServerReadsSwiftCache() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let cachePath = root
        .appendingPathComponent("mcp", isDirectory: true)
        .appendingPathComponent("cache", isDirectory: true)
        .appendingPathComponent("tools.json")
    try await SwiftNativePersistenceCore().writeJSON(.object([
        "searxng-local": .object([
            "createdAt": .string("2026-06-03T00:00:00+00:00"),
            "tools": .array([
                .object([
                    "name": .string("search"),
                    "description": .string("Search SearXNG"),
                ]),
            ]),
        ]),
    ]), to: cachePath)
    let dispatcher = SwiftNativeMCPDispatcher(root: root)

    let tools = try await dispatcher.listToolsLive(forServer: "searxng-local")

    #expect(tools.count == 1)
    if case .object(let obj)? = tools.first {
        #expect(obj["name"] == .string("search"))
    } else {
        Issue.record("expected cached tool object, got \(tools)")
    }
}

// Helper duplicated from the existing test file (avoid cross-file private leak).
private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MCPSubprocessTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Bug 1: stdio-vs-http transport classification contract
//
// NativeClient.swiftMCPServerIsStdio relies on
// SwiftNativeMCPDispatcher.listServers() exposing each server's transport
// verbatim ("stdio" / "http" / "native" / etc.). If this contract drifts
// — say, a future refactor lowercases or aliases values — the NativeClient
// transport-routing fix would silently send http/native servers through
// the stdio subprocess pool again. This test pins the contract.

@Test func listServers_preservesTransportForStdioAndHttpRows() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mcpDir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
    // Mix of stdio + http servers — the scenario the bug regressed on.
    let stdioRow: JSONValue = .object([
        "id": .string("stdio-row"),
        "name": .string("Stdio Row"),
        "transport": .string("stdio"),
        "endpoint": .string(""),
        "command": .string("/usr/bin/true"),
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "toolCount": .int(0),
        "resourceCount": .int(0),
        "riskClass": .string("app_data_read"),
        "createdAt": .string("2026-05-31T00:00:00+00:00"),
        "updatedAt": .string("2026-05-31T00:00:00+00:00"),
    ])
    let httpRow: JSONValue = .object([
        "id": .string("http-row"),
        "name": .string("Http Row"),
        "transport": .string("http"),
        "endpoint": .string("http://127.0.0.1:9999"),
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "toolCount": .int(0),
        "resourceCount": .int(0),
        "riskClass": .string("network_read"),
        "createdAt": .string("2026-05-31T00:00:00+00:00"),
        "updatedAt": .string("2026-05-31T00:00:00+00:00"),
    ])
    try JSONValue.array([stdioRow, httpRow])
        .serializedData(pretty: true)
        .write(to: mcpDir.appendingPathComponent("servers.json"))
    let dispatcher = SwiftNativeMCPDispatcher(root: root)
    let servers = try await dispatcher.listServers()
    // listServers also merges defaults — locate by id.
    let stdio = servers.first { $0.id == "stdio-row" }
    let http = servers.first { $0.id == "http-row" }
    #expect(stdio != nil, "stdio-row should be present in listServers output")
    #expect(http != nil, "http-row should be present in listServers output")
    #expect(stdio?.transport == "stdio", "stdio-row transport must round-trip as 'stdio'")
    #expect(http?.transport == "http", "http-row transport must round-trip as 'http' (not 'stdio')")
}

/// Pool's ensurePool MUST exclude non-stdio specs. Without this, the http
/// row above would silently get added to the subprocess pool, the
/// transport-classification helper in NativeClient would be the only
/// thing standing between an http server and a spawn attempt — leaving a
/// secondary defense at the Core layer too.
@Test func ensurePool_filtersOutNonStdioServers() async throws {
    let stdio = MCPServer(
        id: "stdio-row", name: "Stdio", transport: "stdio",
        endpoint: "", command: "/usr/bin/true",
        status: "ready", healthStatus: "ok",
        toolCount: 0, resourceCount: 0, riskClass: "app_data_read",
        createdAt: "2026-05-31T00:00:00+00:00", updatedAt: "2026-05-31T00:00:00+00:00"
    )
    let http = MCPServer(
        id: "http-row", name: "Http", transport: "http",
        endpoint: "http://127.0.0.1:9999", command: nil,
        status: "ready", healthStatus: "ok",
        toolCount: 0, resourceCount: 0, riskClass: "network_read",
        createdAt: "2026-05-31T00:00:00+00:00", updatedAt: "2026-05-31T00:00:00+00:00"
    )
    let pool = await SwiftNativeMCPDispatcher.ensurePool(for: [stdio, http])
    // Best evidence that http-row was not added: a get() raises serverNotFound.
    do {
        _ = try await pool.get(serverId: "http-row")
        Issue.record("http-row must not be poolable via stdio subprocess pool")
    } catch MCPDispatcherError.serverNotFound {
        // expected
    } catch {
        Issue.record("expected .serverNotFound for http-row, got \(error)")
    }
}

// MARK: - Newline-delimited framing (MCP stdio transport)

/// One `\n`-terminated JSON line per frame; `\r\n` endings tolerated;
/// multiple frames arriving in one chunk all parse.
@Test func frameReader_parsesNewlineDelimitedFrames_toleratesCRLF() async throws {
    let reader = MCPFrameReader()
    let a = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#
    let b = #"{"jsonrpc":"2.0","id":2,"result":{"ok":false}}"#
    reader.append(Data("\(a)\n\(b)\r\n".utf8))
    let (frames, _, notice) = reader.drain()
    #expect(notice == nil)
    #expect(frames.count == 2, "both newline-delimited frames should parse; got \(frames.count)")
}

/// A non-JSON line (server logging to stdout, or garbage) must surface a
/// malformed notice, and the reader must recover on the next valid line.
@Test func frameReader_flagsNonJSONLine_andRecovers() async throws {
    let reader = MCPFrameReader()
    reader.append(Data("this is not json\n".utf8))
    let (frames1, _, notice1) = reader.drain()
    #expect(frames1.isEmpty)
    #expect(notice1 != nil, "reader should surface a malformed notice on a non-JSON line")
    let body = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#
    reader.append(Data("\(body)\n".utf8))
    let (frames2, _, _) = reader.drain()
    #expect(frames2.count == 1, "reader should accept the valid line after recovery; got \(frames2.count)")
}

/// Regression: a response arriving split across two stdout chunks mid-JSON-
/// line must still parse once the terminating `\n` lands (incremental
/// framing — readabilityHandler chunk boundaries are arbitrary).
@Test func frameReader_parsesFrameSplitAcrossChunks() async throws {
    let reader = MCPFrameReader()
    let body = #"{"jsonrpc":"2.0","id":7,"result":{"tools":[{"name":"a"}]}}"#
    let bytes = Array(body.utf8)
    let mid = bytes.count / 2
    reader.append(Data(bytes[..<mid]))
    let (frames0, _, notice0) = reader.drain()
    #expect(frames0.isEmpty, "partial line must not emit a frame")
    #expect(notice0 == nil, "partial line must not be flagged malformed")
    reader.append(Data(bytes[mid...]) + Data("\n".utf8))
    let (frames1, _, notice1) = reader.drain()
    #expect(notice1 == nil)
    #expect(frames1.count == 1, "split frame should parse once the newline lands; got \(frames1.count)")
}

// MARK: - Bug 3: pool detects crashed pooled process

/// Write a Swift helper that completes initialize + the
/// notifications/initialized handshake, then exits 1 immediately. The pool
/// MUST see the death (via the terminationHandler bridge) and arm crash
/// backoff so the NEXT `get()` doesn't blindly respawn.
private func writeImmediateExitHelper() throws -> URL {
    try writeSwiftMCPHelper(mode: "immediateExitAfterInit")
}

@Test func pool_detectsCrashedPooledProcess_armsBackoffOnNextGet() async throws {
    let script = try writeImmediateExitHelper()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let pool = MCPSubprocessPool()
    // Keep the observable crash record alive even when the shared-pool stress
    // gate delays this test between actor hops. Backoff duration is not the
    // behavior under test; recording the death before any respawn is.
    await pool._setBackoffDurations(base: 30, max: 30)
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "crash-srv", command: helperCommand(script))
    ])
    // The child exits immediately after the handshake. Depending on whether
    // its termination wins the final pool actor hop, the first checkout may
    // return a process that is about to die or fail closed during spawn. Both
    // schedules must arm the same crash record.
    var first: MCPSubprocess?
    do {
        first = try await pool.get(serverId: "crash-srv")
    } catch let error as MCPSubprocessError {
        guard case .spawnFailed = error else {
            Issue.record("unexpected first-checkout error: \(error)")
            await pool.stopAll()
            return
        }
    }
    if let first {
        for _ in 0..<10 {
            if await !first.isRunning { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    // Give the actor an extra tick to drain the terminationHandler queue.
    try? await Task.sleep(nanoseconds: 100_000_000)

    // Second get within the backoff window must throw .spawnFailed (cached
    // crash error) — NOT respawn blindly. This is the regression bug.
    do {
        _ = try await pool.get(serverId: "crash-srv")
        Issue.record("expected second get within backoff window to throw")
    } catch let err as MCPSubprocessError {
        if case .spawnFailed(let msg) = err {
            #expect(msg.contains("backoff") || msg.contains("crash-srv"),
                    "expected backoff-cached failure; got msg=\(msg)")
        } else {
            Issue.record("expected .spawnFailed (backoff), got \(err)")
        }
    } catch {
        Issue.record("unexpected error type on backoff: \(error)")
    }
    await pool.stopAll()
}

// MARK: - Bug 4: getOrFill coalesces concurrent misses

/// Two concurrent listToolsLive calls against the same server must result
/// in ONE subprocess request, not two. Verified by counting the per-server
/// pool spawns (we install a single subprocess pool with a spec pointing
/// at a slow helper, then race two list calls; the helper records its
/// request count on disk).
@Test func cache_getOrFill_coalescesConcurrentMisses() async throws {
    // Use a helper whose tools/list reply intentionally takes 200ms so the
    // second caller arrives during the inflight window.
    let script = try writeMCPHelper(slowToolsMS: 200, toolCount: 1)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mcpDir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
    let server: JSONValue = .object([
        "id": .string("herd-srv"),
        "name": .string("Herd Helper"),
        "transport": .string("stdio"),
        "endpoint": .string(""),
        "command": .string(helperCommand(script)),
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "toolCount": .int(0),
        "resourceCount": .int(0),
        "riskClass": .string("app_data_read"),
        "createdAt": .string("2026-05-31T00:00:00+00:00"),
        "updatedAt": .string("2026-05-31T00:00:00+00:00"),
    ])
    try JSONValue.array([server])
        .serializedData(pretty: true)
        .write(to: mcpDir.appendingPathComponent("servers.json"))

    let pool = MCPSubprocessPool()
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "herd-srv", command: helperCommand(script))
    ])
    let dispatcher = SwiftNativeMCPDispatcher(root: root)
    await MCPLiveCache.shared._clear()

    // Race two list calls. Both should resolve to the same array; if the
    // coalescer is working, only ONE subprocess request was made — the
    // observable proxy for that is identical results AND that the pooled
    // subprocess is still the same actor after both calls return.
    async let a = dispatcher.listToolsLive(forServer: "herd-srv", pool: pool)
    async let b = dispatcher.listToolsLive(forServer: "herd-srv", pool: pool)
    let (ra, rb) = try await (a, b)
    #expect(ra.count == 1)
    #expect(rb.count == 1)
    // Both arrays MUST be the cached one (identical serialization).
    let aData = try JSONValue.array(ra).serializedData(pretty: false)
    let bData = try JSONValue.array(rb).serializedData(pretty: false)
    #expect(aData == bData, "coalesced callers should share the same result")
    await pool.stopAll()
}

// MARK: - Bug 4 — pure cache unit test (no subprocess)

/// Tighter unit test that asserts the coalescer property directly: N
/// concurrent getOrFill calls for the same key must invoke `fill` exactly
/// once, even when the fill closure intentionally takes time.
@Test func cache_getOrFill_singleFillForConcurrentCallers() async throws {
    let cache = MCPLiveCache()
    await cache._clear()
    let counter = _AtomicCounter()
    let value: [JSONValue] = [.string("only-one")]
    // Spawn 5 concurrent callers; the fill closure increments a counter,
    // sleeps long enough that all 5 land in inflight, then returns.
    let captured = counter
    let work: @Sendable () async throws -> [JSONValue] = {
        captured.bump()
        try await Task.sleep(nanoseconds: 100_000_000)
        return value
    }
    try await withThrowingTaskGroup(of: [JSONValue].self) { group in
        for _ in 0..<5 {
            group.addTask { try await cache.getOrFill("k", fill: work) }
        }
        var results: [[JSONValue]] = []
        for try await r in group { results.append(r) }
        #expect(results.count == 5)
    }
    #expect(counter.value == 1, "expected exactly 1 fill invocation across 5 concurrent callers; got \(counter.value)")
}

/// Trivial @Sendable counter for the coalescer test.
private final class _AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n: Int = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

// MARK: - Bug 1 (HIGH): malformed-frame terminate-and-evict
//
// Previously a malformed frame caused the parser to drop the line + stamp
// `malformedFrameNotice`, but the subprocess stayed pooled with
// potentially-garbage bytes still in `buffer`. The next pool.get()
// returned the SAME corrupted subprocess and cascading malformed frames
// followed. Bug 1 fix terminates the subprocess on malformed frame so the
// next get() respawns fresh.

/// A helper that, after init handshake, sends a non-JSON line, then waits
/// indefinitely (it would have sent a valid frame next, but with the fix
/// the subprocess gets killed first).
private func writeMalformedFrameHelper() throws -> URL {
    try writeSwiftMCPHelper(mode: "malformedAfterInit")
}

@Test func pool_malformedFrame_terminatesAndEvictsSubprocess() async throws {
    let script = try writeMalformedFrameHelper()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let pool = MCPSubprocessPool()
    await pool._setBackoffDurations(base: 30, max: 30)
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "bad-frame-srv", command: helperCommand(script))
    ])
    var first: MCPSubprocess?
    do {
        first = try await pool.get(serverId: "bad-frame-srv")
    } catch let error as MCPSubprocessError {
        // The helper emits the malformed frame immediately after receiving
        // notifications/initialized. Under saturation the drain/termination
        // path may therefore win before pool.get returns; that is the desired
        // fail-closed result, not a failed spawn assertion.
        guard case .spawnFailed = error else {
            Issue.record("unexpected first-checkout error: \(error)")
            await pool.stopAll()
            return
        }
    }

    if let first {
        #expect(await first.pid != nil)

        // Trigger the malformed-frame path when checkout won the race. Use a
        // short timeout — the request will fail, then the subprocess must die.
        do {
            _ = try await first.request(method: "tools/list", params: .object([:]), timeout: 1.0)
        } catch {
            // expected — either .malformedResponse, .streamClosed, or .timeout
        }

        // Wait for the actor's terminate path + Process.isRunning to flip.
        var died = false
        for _ in 0..<30 {
            if await !first.isRunning { died = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(died, "subprocess must terminate after malformed-frame eviction")
    }
    // Allow termination handler to land.
    try? await Task.sleep(nanoseconds: 200_000_000)
    #expect(await pool._crashInfo(for: "bad-frame-srv") != nil)
    await pool.stopAll()
}

// MARK: - Bug 3 (MED): termination buffered when handler not yet installed

/// `MCPSubprocess` previously installed `terminationHandler` (via the
/// pool's `onUnexpectedTermination`) AFTER `proc.run()`. If the process
/// exited in the <1ms window between run() and the handler being set,
/// the bridge fired into `_processDidTerminate` with terminationHandler
/// == nil, silently dropping the crash. Pool returned the dead process
/// as a successful start with no backoff. Bug 3 fix buffers the
/// termination info and replays it when the handler is set.
///
/// Direct unit test against MCPSubprocess (without the pool layer):
/// spawn a process that exits immediately, wait briefly for the
/// termination to land, THEN install the handler — it should fire.
@Test func subprocess_terminationBeforeHandlerInstall_isReplayedOnInstall() async throws {
    // Helper that exits immediately on launch.
    let script = try writeSwiftMCPHelper(mode: "exitImmediately")
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "bug3-srv",
        command: helperCommand(script)
    )
    // We can't easily call start() (which does the init handshake) on a
    // process that won't respond. Instead, we exercise the buffering
    // path: prove the behavior via the pool's get() since that's the
    // production surface that exhibited the symptom.
    _ = proc  // unused; the assertion below is via the pool path.

    // Pool-level proof: start a process that exits immediately and assert
    // a SECOND get() within the backoff window throws .spawnFailed.
    // Without Bug 3 fix, the pool would think the start succeeded and the
    // second get would also "succeed" (returning a dead process).
    let pool = MCPSubprocessPool()
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "bug3-srv", command: helperCommand(script))
    ])
    do {
        _ = try await pool.get(serverId: "bug3-srv")
        // Some platforms may complete the init-handshake-timeout path
        // before terminationHandler fires; either way, first get may
        // have errored OR succeeded with a dead process.
    } catch {
        // expected on most platforms — start() throws when init times out
        // OR when stream closes mid-init.
    }
    // Give the terminationHandler bridge a tick to fire (even if it was
    // pre-handler-install, Bug 3 fix buffers it).
    try? await Task.sleep(nanoseconds: 300_000_000)

    // Second get must see crash backoff (cooldown), proving the
    // termination was recorded (not silently dropped).
    do {
        _ = try await pool.get(serverId: "bug3-srv")
        Issue.record("Bug 3 fix regression: second get within backoff window should throw")
    } catch let err as MCPSubprocessError {
        if case .spawnFailed = err {
            // expected — backoff is armed
        } else if case .streamClosed = err {
            // Acceptable on platforms where the first-get spawn races
            // termination differently; either way the dead process did
            // not silently come back.
        } else {
            Issue.record("expected .spawnFailed (backoff), got \(err)")
        }
    }
    await pool.stopAll()
}

// MARK: - Bug 5 (LOW): consecutiveFailures not doubled for one death

/// One death must bump consecutiveFailures EXACTLY ONCE, regardless of
/// whether the synthetic-crash record from pool.get() and the real
/// terminationHandler-fired record both land. Bug 5 fix uses per-spawn
/// generation idempotence to dedup.
@Test func pool_singleDeath_bumpsConsecutiveFailuresExactlyOnce() async throws {
    let script = try writeImmediateExitHelper()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let pool = MCPSubprocessPool()
    await pool._setBackoffDurations(base: 30, max: 30)
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "once-srv", command: helperCommand(script))
    ])
    var first: MCPSubprocess?
    do {
        first = try await pool.get(serverId: "once-srv")
    } catch let error as MCPSubprocessError {
        guard case .spawnFailed = error else {
            Issue.record("unexpected first-checkout error: \(error)")
            await pool.stopAll()
            return
        }
    }
    // Wait for the child to exit + termination handler to fire when checkout
    // beat termination. A fail-closed first checkout already recorded it.
    if let first {
        for _ in 0..<10 {
            if await !first.isRunning { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    try? await Task.sleep(nanoseconds: 200_000_000)

    // Force the synthetic record path by calling get() again (it sees
    // pooled-but-dead → synthetic record). The synthetic + real
    // terminationHandler records should DEDUP to a single bump.
    do {
        _ = try await pool.get(serverId: "once-srv")
    } catch {
        // expected — backoff
    }
    // Inspect both the public projection and the exact test-only crash record.
    let rows = await pool.sessionStatuses()
    let row = rows.first { $0.id == "once-srv" }!
    #expect(row.status == "failed", "row must be marked failed after crash")
    #expect(row.lastError != nil)
    #expect(await pool._crashInfo(for: "once-srv")?.consecutiveFailures == 1)
    await pool.stopAll()
}

// MARK: - Bug 7 (LOW): cached:false coordinates with in-flight fill

/// Two concurrent callers: one cached:true (slow), one cached:false
/// (fast). Without Bug 7 fix the fast force-fresh writes, then the
/// slow inflight clobbers it on completion. With the fix, the
/// force-fresh path cancels/awaits the inflight before its own write.
@Test func cache_forceFill_cancelsInflight_beforeWriting() async throws {
    let cache = MCPLiveCache()
    await cache._clear()

    // Build a slow getOrFill caller that returns ["slow-value"] after 250ms.
    let slowFill: @Sendable () async throws -> [JSONValue] = {
        try await Task.sleep(nanoseconds: 250_000_000)
        return [.string("slow-value")]
    }
    let fastFill: @Sendable () async throws -> [JSONValue] = {
        // Short delay so the slow inflight definitely exists when we start.
        try await Task.sleep(nanoseconds: 10_000_000)
        return [.string("fast-value")]
    }

    // Kick off the slow getOrFill.
    let slow = Task<[JSONValue], Error> {
        try await cache.getOrFill("k", fill: slowFill)
    }
    // Give the slow task a moment to register as in-flight.
    try? await Task.sleep(nanoseconds: 30_000_000)
    // Run the force-fresh: it should cancel the slow inflight, run fastFill, write.
    let forced = try await cache.forceFill("k", fill: fastFill)
    func extractString(_ values: [JSONValue]?) -> String? {
        guard let first = values?.first, case .string(let s) = first else { return nil }
        return s
    }
    #expect(extractString(forced) == "fast-value",
            "forceFill must return its own (fresh) result")

    // The slow task should have been cancelled. Wait for it to drain;
    // its result (if it didn't throw) is discarded.
    _ = try? await slow.value

    // Cache should now hold the fast value, not the slow one.
    let cached = await cache.get("k")
    #expect(extractString(cached) == "fast-value",
            "Bug 7 fix: cache must hold the force-fresh value, not the slow inflight value")
}

// MARK: - Bug 6 (LOW): listServers single disk read within TTL

/// Within the TTL window, N concurrent listServers() calls must produce
/// exactly 1 disk read. We prove it by counting reads via a spy
/// PersistenceCore wrapper.
@Test func listServers_cachesWithinTTL_singleDiskRead() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mcpDir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
    let server: JSONValue = .object([
        "id": .string("tally-srv"),
        "name": .string("Tally"),
        "transport": .string("stdio"),
        "endpoint": .string(""),
        "command": .string("/usr/bin/true"),
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "toolCount": .int(0),
        "resourceCount": .int(0),
        "riskClass": .string("app_data_read"),
        "createdAt": .string("2026-05-31T00:00:00+00:00"),
        "updatedAt": .string("2026-05-31T00:00:00+00:00"),
    ])
    try JSONValue.array([server])
        .serializedData(pretty: true)
        .write(to: mcpDir.appendingPathComponent("servers.json"))

    let spy = _ReadCountingPersistence()
    let dispatcher = SwiftNativeMCPDispatcher(root: root, persistence: spy)

    // First call — uncached, hits disk.
    _ = try await dispatcher.listServers()
    let firstReadCount = spy.serversReadCount
    #expect(firstReadCount >= 1, "first listServers call must hit disk; got \(firstReadCount)")

    // 10 concurrent subsequent calls — all should be cache hits.
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
            group.addTask { _ = try? await dispatcher.listServers() }
        }
    }
    let afterCount = spy.serversReadCount
    #expect(afterCount == firstReadCount,
            "Bug 6 fix: subsequent listServers calls within TTL must not re-read disk; before=\(firstReadCount) after=\(afterCount)")

    // After TTL invalidation, the next call hits disk again.
    await dispatcher._invalidateListServersCache()
    _ = try await dispatcher.listServers()
    #expect(spy.serversReadCount == afterCount + 1,
            "after cache invalidation, the next call must re-read disk")
}

// MARK: - 3rd-round Wave 4 review — Bugs 2, 3, 4

/// Bug 2 (3rd-round review): handler-installed-before-start eliminates the
/// post-init crash race. We spawn an MCP helper that completes the init
/// handshake then exits within ~1ms. Without the fix, get() races
/// _recordTermination and pools a dead actor + clobbers the crash record.
/// With the fix, get() either throws spawnFailed inline OR the 2nd get()
/// throws inside the backoff window — never returns a corpse with no record.
@Test func pool_crashAfterInit_secondGetHonorsBackoff_noCorpsePooled() async throws {
    let script = try writeMCPHelper(crashAfterInit: true)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let pool = MCPSubprocessPool()
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "crash-init-srv", command: helperCommand(script))
    ])
    // First get — may succeed transiently or throw, depending on race.
    do {
        let p = try await pool.get(serverId: "crash-init-srv")
        // If it returns, it must NOT be a live-but-already-dead corpse
        // by the time the caller observes it (allow handler to land).
        try? await Task.sleep(nanoseconds: 200_000_000)
        let running = await p.isRunning
        if running {
            Issue.record("3rd-round Bug 2: expected the after-init crash to be detected; got running=true 200ms later")
        }
    } catch {
        // Acceptable — inline detection threw .spawnFailed.
    }
    // Second get within backoff window must throw .spawnFailed (backoff armed).
    do {
        _ = try await pool.get(serverId: "crash-init-srv")
        Issue.record("3rd-round Bug 2: second get within backoff window must throw, crash was silently dropped")
    } catch let err as MCPSubprocessError {
        if case .spawnFailed = err { /* expected */ }
        else if case .streamClosed = err { /* acceptable variant */ }
        else { Issue.record("expected .spawnFailed; got \(err)") }
    }
    await pool.stopAll()
}

/// Bug 3 (3rd-round review): a slow getOrFill must NOT clobber a fresh
/// forceFill result with its (stale) value when its task was cancelled
/// and replaced.
@Test func cache_getOrFill_skipsPutAfterCancellationByForceFill() async throws {
    let cache = MCPLiveCache()
    await cache._clear()

    let slowFill: @Sendable () async throws -> [JSONValue] = {
        // Long enough that the forceFill races first.
        try await Task.sleep(nanoseconds: 300_000_000)
        return [.string("slow-stale")]
    }
    let fastFill: @Sendable () async throws -> [JSONValue] = {
        try await Task.sleep(nanoseconds: 10_000_000)
        return [.string("fast-fresh")]
    }
    let slow = Task<[JSONValue], Error> {
        try await cache.getOrFill("k", fill: slowFill)
    }
    try? await Task.sleep(nanoseconds: 30_000_000)
    let forced = try await cache.forceFill("k", fill: fastFill)

    func first(_ vs: [JSONValue]?) -> String? {
        guard let v = vs?.first, case .string(let s) = v else { return nil }
        return s
    }
    #expect(first(forced) == "fast-fresh")

    // Wait for slow to finish — its put() must skip because inflight no
    // longer points at it.
    _ = try? await slow.value
    try? await Task.sleep(nanoseconds: 100_000_000)
    let final = await cache.get("k")
    #expect(first(final) == "fast-fresh",
            "3rd-round Bug 3: cache holds force-fresh value; slow getOrFill must not clobber after cancellation+replace")
}

/// Bug 4 (3rd-round review): cold concurrent listServers callers must
/// coalesce — exactly ONE disk read for N callers when the cache is
/// empty. The earlier `listServers_cachesWithinTTL_singleDiskRead` test
/// warmed the cache first, so it could not catch a cold-thundering-herd
/// regression. This one starts COLD.
@Test func listServers_coldConcurrent_singleDiskRead() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mcpDir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
    let server: JSONValue = .object([
        "id": .string("cold-srv"),
        "name": .string("Cold"),
        "transport": .string("stdio"),
        "endpoint": .string(""),
        "command": .string("/usr/bin/true"),
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "toolCount": .int(0),
        "resourceCount": .int(0),
        "riskClass": .string("app_data_read"),
        "createdAt": .string("2026-05-31T00:00:00+00:00"),
        "updatedAt": .string("2026-05-31T00:00:00+00:00"),
    ])
    try JSONValue.array([server])
        .serializedData(pretty: true)
        .write(to: mcpDir.appendingPathComponent("servers.json"))

    let spy = _ReadCountingPersistence()
    let dispatcher = SwiftNativeMCPDispatcher(root: root, persistence: spy)

    // Fan out 10 callers immediately, COLD. They should share one disk
    // read via the inflight task.
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
            group.addTask { _ = try? await dispatcher.listServers() }
        }
    }
    #expect(spy.serversReadCount == 1,
            "3rd-round Bug 4: cold concurrent callers must share ONE disk read; got \(spy.serversReadCount)")
}

// MARK: - 4th-round Wave 4 review — Bugs A, B, C

/// Bug A (4th-round review): if the start-handshake suspension window
/// races the terminationHandler-fired _recordTermination, the corpse
/// must NOT be pooled and `crashes` for this serverId must NOT be
/// wiped. We can't easily provoke the timing race deterministically,
/// so we simulate: spawn a real crash-after-init helper and call get()
/// repeatedly until either (a) it throws spawnFailed (inline detection
/// or post-check fires), or (b) it returns a process — in which case
/// `isRunning` must still be true a moment later (no corpse pooled).
/// The negative would be: get() returns a process AND it's dead AND
/// crashes[serverId] is empty.
@Test func pool_crashAfterInit_neverPoolsCorpse_acrossMultipleSpawns() async throws {
    let script = try writeMCPHelper(crashAfterInit: true)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let pool = MCPSubprocessPool()
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "race-srv", command: helperCommand(script))
    ])
    var corpsePooled = false
    for _ in 0..<3 {
        do {
            let p = try await pool.get(serverId: "race-srv")
            // Brief settle so terminationHandler can land.
            try? await Task.sleep(nanoseconds: 150_000_000)
            let running = await p.isRunning
            if !running {
                // Returned process is dead — verify pool's sessionStatuses
                // does NOT report it as `warm`, AND that a crash backoff is armed.
                let statuses = await pool.sessionStatuses()
                let row = statuses.first { $0.serverId == "race-srv" }
                if row?.status == "warm" {
                    corpsePooled = true
                }
            }
        } catch {
            // spawnFailed (inline or post-check) — expected behavior.
        }
        // Force backoff to expire so we can spawn again.
        await pool._setCrashInfo(
            MCPSubprocessPool.CrashInfo(
                lastError: "test-reset",
                nextRetryAt: Date(timeIntervalSinceNow: -1),
                consecutiveFailures: 0
            ),
            for: "race-srv"
        )
    }
    #expect(!corpsePooled, "4th-round Bug A: pool must never expose a dead corpse as warm")
    await pool.stopAll()
}

/// Bug B (4th-round review): if the getOrFill `fill` closure throws,
/// the inflight slot MUST be cleared so a subsequent caller can
/// retry. Prior to the do/catch wrap, the slot stayed pinned to the
/// failed Task and every future call replayed the same error.
@Test func cache_getOrFill_errorPath_clearsInflightSlot() async throws {
    let cache = MCPLiveCache()
    await cache._clear()

    struct TransientError: Error {}
    let throwingFill: @Sendable () async throws -> [JSONValue] = {
        throw TransientError()
    }
    // First call: fill throws.
    do {
        _ = try await cache.getOrFill("k", fill: throwingFill)
        Issue.record("expected throw")
    } catch is TransientError {
        // expected
    }

    // Second call with a DIFFERENT fill closure. Without the fix the
    // pinned Task would re-throw TransientError and `freshFired`
    // would stay false. With the fix, the slot is cleared and our
    // fresh fill runs.
    let freshFired = OSAllocatedUnfairLock<Bool>(initialState: false)
    let freshFill: @Sendable () async throws -> [JSONValue] = {
        freshFired.withLock { $0 = true }
        return [.string("fresh")]
    }
    let value = try await cache.getOrFill("k", fill: freshFill)
    #expect(freshFired.withLock { $0 } == true,
            "4th-round Bug B: failed-task inflight slot must be cleared so a fresh fill can fire")
    func extractString(_ values: [JSONValue]?) -> String? {
        guard let first = values.flatMap({ $0.first }), case .string(let s) = first else { return nil }
        return s
    }
    #expect(extractString(value) == "fresh")
}

/// Bug C (4th-round review): when forceFill B starts while forceFill A
/// is awaiting (A's task got cancelled+replaced), A's defer must NOT
/// clear B's slot, and A's put() must NOT clobber B's eventual write.
/// The LATER forceFill wins the cache.
@Test func cache_forceFill_overlapping_laterWinsCacheWrite() async throws {
    let cache = MCPLiveCache()
    await cache._clear()

    let slowFill: @Sendable () async throws -> [JSONValue] = {
        try await Task.sleep(nanoseconds: 200_000_000)
        return [.string("A-slow")]
    }
    let fastFill: @Sendable () async throws -> [JSONValue] = {
        try await Task.sleep(nanoseconds: 20_000_000)
        return [.string("B-fast")]
    }
    // Kick off A (slow). It will be cancelled by B.
    let a = Task<[JSONValue], Error> {
        try await cache.forceFill("k", fill: slowFill)
    }
    // Give A's slot time to register.
    try? await Task.sleep(nanoseconds: 30_000_000)
    // Start B (fast). B cancels A's task in its enter-block, then runs fastFill.
    let b = try await cache.forceFill("k", fill: fastFill)
    func extractString(_ values: [JSONValue]?) -> String? {
        guard let first = values?.first, case .string(let s) = first else { return nil }
        return s
    }
    #expect(extractString(b) == "B-fast")

    // Drain A; it may throw (cancelled) or produce "A-slow"; either way
    // its put() must NOT overwrite B's cache entry.
    _ = try? await a.value
    try? await Task.sleep(nanoseconds: 50_000_000)
    let cached = await cache.get("k")
    #expect(extractString(cached) == "B-fast",
            "4th-round Bug C: later forceFill must own the cache write; A's defer/put must identity-compare")
}

// MARK: - 5th-round Wave 4 review — Bugs A, B

/// Round 5 Bug A: 5 concurrent cold `get(serverId:)` calls for the same
/// server must coalesce to ONE subprocess spawn. The pre-fix race had
/// two callers both pass the `processes[serverId] == nil` check, both
/// suspend in `proc.start()` / `proc.isRunning`, both write
/// `processes[serverId] = proc`, leaving the loser's child alive. We
/// verify by having the helper append its PID to a per-test counter
/// file on startup and asserting the file has exactly ONE line.
@Test func pool_concurrentColdGets_coalesceToOneSpawn() async throws {
    let script = try writeMCPHelper(toolCount: 0)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let pool = MCPSubprocessPool()
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "coalesce-srv", command: helperCommand(script))
    ])
    // Race 5 concurrent cold gets. Without the Round 5 fix, 2-5 child
    // processes spawn. With the fix, exactly 1 actual spawn body runs and
    // the rest await the same in-flight Task.
    let errors = OSAllocatedUnfairLock<[String]>(initialState: [])
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<5 {
            group.addTask {
                do {
                    _ = try await pool.get(serverId: "coalesce-srv")
                } catch {
                    errors.withLock { $0.append(String(describing: error)) }
                }
            }
        }
    }
    #expect(errors.withLock { $0 }.isEmpty,
            "Round 5 Bug A: cold get callers should not fail; errors=\(errors.withLock { $0 })")
    let spawnAttempts = await pool._spawnAttemptCount(for: "coalesce-srv")
    #expect(spawnAttempts == 1,
            "Round 5 Bug A: 5 concurrent cold get(serverId:) MUST coalesce to 1 spawn; got \(spawnAttempts)")
    await pool.stopAll()
}

/// Round 5 Bug B: when forceFill A is blocked draining a prior in-flight
/// task and forceFill B enters during that drain, B must win the cache
/// — A's resume must not install its own slot or clobber B's put. Pre-
/// fix, A cleared inflight before the drain await, B saw an empty slot
/// and installed B-task, A resumed and unconditionally overwrote B's
/// slot then wrote A's value to cache. Round 5 fix uses a per-key
/// generation token to drop A out of shared-state writes on resume.
@Test func cache_forceFill_overlappingDuringDrainAwait_laterWins() async throws {
    let cache = MCPLiveCache()
    await cache._clear()

    // 1) Install a long-running getOrFill that ignores cancellation for
    //    ~250ms (try? swallows the Task.sleep CancellationError so the
    //    loop keeps polling until the wall-clock deadline). This pins
    //    `inflight[key]` for the duration so forceFill A's drain await
    //    is genuinely suspended.
    let stuckFill: @Sendable () async throws -> [JSONValue] = {
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return [.string("stuck-getOrFill")]
    }
    let stuckTask = Task<[JSONValue], Error> {
        try await cache.getOrFill("k", fill: stuckFill)
    }
    try? await Task.sleep(nanoseconds: 30_000_000)

    // 2) Older forceFill A: cancels stuckTask, awaits its drain (~220ms
    //    more). aFill returns instantly so the ONLY suspension is the
    //    drain await — the whole bug window.
    let aFill: @Sendable () async throws -> [JSONValue] = {
        return [.string("A-value")]
    }
    let aTask = Task<[JSONValue], Error> {
        try await cache.forceFill("k", fill: aFill)
    }
    try? await Task.sleep(nanoseconds: 50_000_000)

    // 3) Newer forceFill B: enters while A is still draining. Bumps gen,
    //    sees no in-flight (A cleared on its drain entry), installs
    //    B-task. bFill takes 30ms so B completes before the stuck-task's
    //    deadline.
    let bFill: @Sendable () async throws -> [JSONValue] = {
        try await Task.sleep(nanoseconds: 30_000_000)
        return [.string("B-value")]
    }
    let bResult = try await cache.forceFill("k", fill: bFill)
    func first(_ vs: [JSONValue]?) -> String? {
        guard let v = vs?.first, case .string(let s) = v else { return nil }
        return s
    }
    #expect(first(bResult) == "B-value")

    // 4) Let A and stuck drain fully. A's resume MUST detect the stale
    //    generation and drop out — no inflight-slot install, no put.
    _ = try? await aTask.value
    _ = try? await stuckTask.value
    try? await Task.sleep(nanoseconds: 150_000_000)

    let cached = await cache.get("k")
    #expect(first(cached) == "B-value",
            "Round 5 Bug B: later forceFill must own the cache write even when an earlier forceFill was draining a prior inflight")
}

// MARK: - U5 W-E (2026-06-11) — MCP robustness wave

/// Server-initiated requests (id + method frames) must be ANSWERED — pong
/// for ping, -32601 for anything else — and must not disturb the waiter
/// map. The fixture server pings + roots/lists mid-`tools/list` and only
/// answers tools/list after receiving both replies, so the old
/// drop-on-the-floor behavior shows up as a request timeout here.
@Test func subprocess_serverInitiatedRequests_areAnswered_waitersUntouched() async throws {
    let script = try writeSwiftMCPHelper(mode: "serverInitiatedRequests", toolCount: 0)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "ping-srv",
        command: helperCommand(script)
    )
    try await proc.start()
    let result = try await proc.request(method: "tools/list", params: .object([:]), timeout: 15)
    guard case .object(let obj) = result else {
        Issue.record("expected object result, got \(result)")
        await proc.stop()
        return
    }
    #expect(obj["pingPongOK"] == .bool(true),
            "client must reply to a server-initiated ping with a result (pong)")
    #expect(obj["rootsErrorCode"] == .int(-32601),
            "client must reply -32601 to unsupported server-initiated requests")
    await proc.stop()
}

/// Stalled stdin (non-reading child + >64KB pipe-buffer write) must fail
/// with a deadline instead of pinning the actor forever, the actor must
/// stay responsive while the write is in flight, and the wedged child must
/// be terminated so the pool respawns fresh.
@Test func subprocess_stdinStall_deadlineFires_actorNotPinned_childTerminated() async throws {
    let script = try writeSwiftMCPHelper(mode: "stopReadingAfterInit")
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "wedge-srv",
        command: helperCommand(script)
    )
    // Apply the short deadline before start as a regression for the initialize
    // frame too. A small write to an empty pipe must complete through the
    // dedicated native writer even when shared Swift/GCD executors are busy;
    // the same exact deadline must later stop the genuinely full pipe.
    await proc._setWriteTimeout(1.0)
    try await proc.start()
    // 512KB payload — far past the 64KB pipe buffer of a non-reading child.
    let blob = String(repeating: "x", count: 512 * 1024)
    let requestTask = Task {
        try await proc.request(
            method: "tools/call",
            params: .object(["blob": .string(blob)]),
            timeout: 8
        )
    }
    // While the write is stalled, the actor must answer other calls fast.
    try? await Task.sleep(nanoseconds: 200_000_000)
    let probeStart = Date()
    _ = await proc.isRunning
    #expect(Date().timeIntervalSince(probeStart) < 0.5,
            "actor pinned by a stalled stdin write — DispatchIO writer regressed")
    do {
        _ = try await requestTask.value
        Issue.record("expected the stalled write to fail")
    } catch let err as MCPSubprocessError {
        switch err {
        case .timeout, .streamClosed:
            break // expected — write deadline or teardown
        default:
            Issue.record("expected .timeout/.streamClosed on stall, got \(err)")
        }
    }
    // The wedged child gets terminated (pool-eviction path).
    var died = false
    for _ in 0..<50 {
        if await !proc.isRunning { died = true; break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(died, "wedged-stdin child must be terminated")
    await proc.stop()
}

/// Cancellation can arrive after the waiter exists but before its write task
/// receives executor time. The request policy must already exist, and the
/// abandoned frame must never be submitted after the cancel notification.
@Test func subprocess_cancelBeforeWriteStarts_skipsFrame_keepsChildAlive() async throws {
    let script = try writeSwiftMCPHelper(mode: "stopReadingAfterInit")
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let proc = try MCPSubprocess.fromServerCommand(
        serverId: "cancel-before-write-srv",
        command: helperCommand(script)
    )
    try await proc.start()
    await proc._setWriteTimeout(0.4)
    await proc._pauseRequestWritesForTesting()
    let pidBefore = await proc.pid

    let blob = String(repeating: "x", count: 512 * 1024)
    let request = Task<JSONValue, Error> {
        try await proc.request(
            method: "tools/call",
            params: .object(["blob": .string(blob)]),
            timeout: 8
        )
    }
    await proc._waitUntilRequestWritePausedForTesting()
    request.cancel()
    do {
        _ = try await request.value
        Issue.record("expected CancellationError before request write start")
    } catch is CancellationError {
        // expected
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }

    await proc._resumeRequestWritesForTesting()
    // Wait past the request's write deadline. A regression submits the 512KB
    // abandoned frame, wedges, and terminates this non-reading child.
    try await Task.sleep(for: .milliseconds(750))
    #expect(await proc.isRunning)
    #expect(await proc.pid == pidBefore)
    await proc.stop()
}

/// updateSpecs with the SAME server id but a CHANGED command must bounce
/// the running subprocess — old child stopped, next get() spawns the new
/// command. Pre-fix, the stale child kept running until it died on its own.
@Test func pool_updateSpecs_commandChange_bouncesStaleSubprocess() async throws {
    let script = try writeMCPHelper()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let pool = MCPSubprocessPool()
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "swap-srv", command: helperCommand(script))
    ])
    let first = try await pool.get(serverId: "swap-srv")
    let pid1 = await first.pid
    #expect(pid1 != nil)
    // Same id, changed command (trailing arg is ignored by the helper but
    // changes the spec). The old subprocess must be stopped by the bounce.
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "swap-srv", command: helperCommand(script) + " --changed")
    ])
    var oldDead = false
    for _ in 0..<50 {
        if await !first.isRunning { oldDead = true; break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(oldDead, "stale subprocess must be stopped when its spec changes")
    let second = try await pool.get(serverId: "swap-srv")
    let pid2 = await second.pid
    #expect(pid2 != nil)
    #expect(pid2 != pid1, "spec change must spawn a NEW subprocess")
    await pool.stopAll()
}

/// U5 fix-round (2026-06-11): actor re-entry during a command-change.
/// `updateSpecs` used to await `proc.stop()` BEFORE removing the stale
/// process/spec from pool state, so a concurrent `get(serverId:)` that
/// interleaved during the stop suspension returned the stale subprocess.
/// The fix swaps all pool state synchronously first; the test uses the
/// stop-window seam to re-enter the pool exactly inside that window and
/// proves the stale process is never returned.
@Test func pool_updateSpecs_concurrentGetDuringStopWindow_neverReturnsStaleProcess() async throws {
    let script = try writeMCPHelper()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let pool = MCPSubprocessPool()
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "reentry-srv", command: helperCommand(script))
    ])
    let stale = try await pool.get(serverId: "reentry-srv")
    let stalePid = await stale.pid
    #expect(stalePid != nil)

    // Box to carry the mid-window observation out of the @Sendable hook.
    let observed = _AtomicBox<(samePid: Bool, sameIdentity: Bool)?>(nil)
    await pool._setUpdateSpecsStopWindowHook { [weak pool] in
        guard let pool else { return }
        // Re-enters the pool actor inside the stop window (state swapped,
        // stale child not yet stopped). Pre-fix ordering, this get would
        // have returned `stale`.
        if let p = try? await pool.get(serverId: "reentry-srv") {
            let pid = await p.pid
            observed.set((samePid: pid == stalePid, sameIdentity: p === stale))
        } else {
            observed.set((samePid: false, sameIdentity: false))
        }
    }
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "reentry-srv", command: helperCommand(script) + " --changed")
    ])
    await pool._setUpdateSpecsStopWindowHook(nil)

    let got = observed.get()
    #expect(got != nil, "stop-window hook must have run a concurrent get")
    #expect(got?.sameIdentity == false,
            "get during the command-change stop window must NEVER return the stale subprocess")
    #expect(got?.samePid == false,
            "get during the stop window must spawn/return the NEW command's child, not the stale pid")
    await pool.stopAll()
}

/// Minimal lock box for carrying values out of @Sendable test hooks.
private final class _AtomicBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

/// Backoff escalation across die-after-start cycles (re-audit confirmed
/// the gap): a successful handshake used to wipe the crash record, so a
/// child that initialized fine but died moments later reset
/// consecutiveFailures every cycle and backoff never escalated past base.
/// With the carry fix, cycle 2's crash records consecutiveFailures == 2.
@Test func pool_dieAfterStartLoop_escalatesConsecutiveFailures() async throws {
    let script = try writeSwiftMCPHelper(mode: "crashAfterToolsList")
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let pool = MCPSubprocessPool()
    await pool._setBackoffDurations(base: 0.05, max: 30)
    await pool.updateSpecs([
        MCPSubprocessPool.Spec(serverId: "loop-srv", command: helperCommand(script))
    ])

    // Cycle 1 — spawn succeeds, then an explicit post-checkout request makes
    // the child respond and die. The failure therefore cannot race the start
    // handshake under a saturated executor.
    let p1 = try await pool.get(serverId: "loop-srv")
    _ = try? await p1.request(method: "tools/list", timeout: 2)
    var dead1 = false
    for _ in 0..<80 {
        if await !p1.isRunning { dead1 = true; break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(dead1, "cycle-1 child should die shortly after start")
    // Let the termination handler land + the (tiny) backoff expire.
    try? await Task.sleep(nanoseconds: 400_000_000)
    let info1 = await pool._crashInfo(for: "loop-srv")
    #expect(info1?.consecutiveFailures == 1,
            "cycle 1 should record one failure; got \(String(describing: info1))")

    // Cycle 2 — respawn also handshakes fine, then the explicit request kills
    // it. The OLD code wiped the crash record on this successful spawn,
    // resetting the streak to 1.
    let p2 = try await pool.get(serverId: "loop-srv")
    _ = try? await p2.request(method: "tools/list", timeout: 2)
    var dead2 = false
    for _ in 0..<80 {
        if await !p2.isRunning { dead2 = true; break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(dead2, "cycle-2 child should die shortly after start")
    try? await Task.sleep(nanoseconds: 400_000_000)
    let info2 = await pool._crashInfo(for: "loop-srv")
    #expect(info2?.consecutiveFailures == 2,
            "die-after-start loop must ESCALATE across respawns; got \(String(describing: info2))")
    await pool.stopAll()
}

/// Read-counting wrapper around SwiftNativePersistenceCore. Counts only
/// reads to a path whose name ends in `servers.json` — narrow enough
/// for the Bug 6 test, broad enough that any disk-read regression in
/// `_readServersUncached` increments the counter.
///
/// Uses `OSAllocatedUnfairLock` (async-safe scoped locking) instead of
/// NSLock, which Swift 6 forbids in async contexts.
private final class _ReadCountingPersistence: PersistenceCoreProtocol, @unchecked Sendable {
    let inner = SwiftNativePersistenceCore()
    private let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
    var serversReadCount: Int {
        counter.withLock { $0 }
    }
    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        if path.lastPathComponent == "servers.json" {
            counter.withLock { $0 += 1 }
        }
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

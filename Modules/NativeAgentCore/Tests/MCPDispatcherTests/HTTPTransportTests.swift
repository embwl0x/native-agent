import Testing
import Foundation
import Network
@testable import MCPDispatcher
import NativeAgentCore
import PersistenceCore

// MARK: - Hermetic HTTP/SSE MCP server helper
//
// An in-process Swift NWListener bound to an ephemeral loopback port. It
// implements the MCP verbs the transport speaks (initialize, tools/list,
// tools/call, notifications/initialized) in four selectable modes:
//   - "json"         : direct application/json JSON-RPC responses
//   - "sse"          : text/event-stream responses (a decoy frame precedes the
//                      real one, so we exercise "parse until matching id")
//   - "json_session" : like json, but every post-initialize request MUST carry
//                      the Mcp-Session-Id assigned at initialize or gets a
//                      JSON-RPC error — proves the client replays the header
//   - "hang"         : accepts the connection but never replies — the timeout path
//
// Hangproof discipline: readiness is bounded by a semaphore, stop() cancels
// the listener and every accepted connection, and hang-mode connections are
// intentionally left open until the URLSession request times out.

private final class HTTPHelper: @unchecked Sendable {
    private struct Request: Sendable {
        var headers: [String: String]
        var body: Data
    }

    private static let sessionID = "sess-http-xyz"

    private let mode: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "NativeAgent.HTTPTransportTests.HTTPHelper")
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var resolvedPort = 0
    private var startupError: Error?
    private var connections: [NWConnection] = []

    var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return resolvedPort
    }

    init(mode: String, timeout: TimeInterval = 20) throws {
        self.mode = mode
        self.listener = try NWListener(using: .tcp)

        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + timeout) == .success else {
            listener.cancel()
            throw NSError(domain: "HTTPHelper", code: -1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Swift HTTP helper (mode=\(mode)) did not become ready within \(timeout)s"
            ])
        }

        lock.lock()
        let port = resolvedPort
        let error = startupError
        lock.unlock()
        if let error {
            throw error
        }
        guard port > 0 else {
            throw NSError(domain: "HTTPHelper", code: -2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Swift HTTP helper (mode=\(mode)) became ready without an assigned port"
            ])
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let active = connections
        connections.removeAll()
        lock.unlock()
        for connection in active {
            connection.cancel()
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = Int(listener.port?.rawValue ?? 0)
            lock.lock()
            resolvedPort = port
            lock.unlock()
            ready.signal()
        case .failed(let error):
            lock.lock()
            startupError = error
            lock.unlock()
            ready.signal()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()

        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            var next = buffer
            if let data, !data.isEmpty {
                next.append(data)
            }

            if let request = self.parseRequest(next) {
                self.handle(request, on: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, buffer: next)
        }
    }

    private func parseRequest(_ data: Data) -> Request? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        var headers: [String: String] = [:]
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        return Request(
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        guard let parsed = try? JSONValue.parse(request.body),
              case .object(let object) = parsed,
              case .string(let method)? = object["method"] else {
            sendStatus(400, on: connection)
            return
        }

        if method == "notifications/initialized" {
            sendStatus(202, on: connection)
            return
        }

        if mode == "hang" {
            return
        }

        let requestID = object["id"] ?? .null
        let sessionID = request.headers["mcp-session-id"]

        if mode == "json_session", method != "initialize", sessionID != Self.sessionID {
            let error: JSONValue = .object([
                "jsonrpc": .string("2.0"),
                "id": requestID,
                "error": .object([
                    "code": .int(-32001),
                    "message": .string("missing or wrong Mcp-Session-Id"),
                ]),
            ])
            sendJSON(error, assignSession: false, on: connection)
            return
        }

        let response: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": requestID,
            "result": makeResult(method: method, request: object),
        ])
        let assignSession = method == "initialize"
        if mode == "sse" {
            sendSSE(response, assignSession: assignSession, on: connection)
        } else {
            sendJSON(response, assignSession: assignSession, on: connection)
        }
    }

    private func makeResult(method: String, request: [String: JSONValue]) -> JSONValue {
        if method == "initialize" {
            return .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "serverInfo": .object(["name": .string("swift-helper")]),
            ])
        }
        if method == "tools/list" {
            return .object([
                "tools": .array([
                    .object(["name": .string("echo"), "description": .string("echo tool")]),
                    .object(["name": .string("ping"), "description": .string("ping tool")]),
                ]),
            ])
        }
        if method == "tools/call" {
            let params: [String: JSONValue]
            if case .object(let object)? = request["params"] {
                params = object
            } else {
                params = [:]
            }
            return .object([
                "content": .array([.object(["type": .string("text"), "text": .string("ok")])]),
                "isError": .bool(false),
                "calledTool": params["name"] ?? .null,
                "echoArgs": params["arguments"] ?? .null,
            ])
        }
        return .object([:])
    }

    private func sendStatus(_ status: Int, on connection: NWConnection) {
        sendRaw(status: status, headers: [], body: Data(), on: connection)
    }

    private func sendJSON(_ value: JSONValue, assignSession: Bool, on connection: NWConnection) {
        guard let body = try? value.serializedData(pretty: false) else {
            sendStatus(500, on: connection)
            return
        }
        var headers = [("Content-Type", "application/json")]
        if assignSession {
            headers.append(("Mcp-Session-Id", Self.sessionID))
        }
        sendRaw(status: 200, headers: headers, body: body, on: connection)
    }

    private func sendSSE(_ value: JSONValue, assignSession: Bool, on connection: NWConnection) {
        let decoy: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/progress"),
            "params": .object(["note": .string("warming")]),
        ])
        guard
            let decoyJSON = try? String(decoding: decoy.serializedData(pretty: false), as: UTF8.self),
            let valueJSON = try? String(decoding: value.serializedData(pretty: false), as: UTF8.self)
        else {
            sendStatus(500, on: connection)
            return
        }

        let body = Data("event: message\ndata: \(decoyJSON)\n\nevent: message\ndata: \(valueJSON)\n\n".utf8)
        var headers = [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
        ]
        if assignSession {
            headers.append(("Mcp-Session-Id", Self.sessionID))
        }
        sendRaw(status: 200, headers: headers, body: body, on: connection)
    }

    private func sendRaw(status: Int, headers: [(String, String)], body: Data, on connection: NWConnection) {
        var responseHeaders = headers
        responseHeaders.append(("Content-Length", String(body.count)))
        responseHeaders.append(("Connection", "close"))

        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 500: reason = "Internal Server Error"
        default: reason = "Status"
        }

        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in responseHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class ImmediateTimeoutURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }

    override func stopLoading() {}
}

private func startHTTPHelper(mode: String, timeout: TimeInterval = 20) throws -> HTTPHelper {
    try HTTPHelper(mode: mode, timeout: timeout)
}

private func stopHTTPHelper(_ h: HTTPHelper) {
    h.stop()
}

private func endpointURL(_ h: HTTPHelper) -> URL {
    URL(string: "http://127.0.0.1:\(h.port)/")!
}

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HTTPTransportTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Direct JSON round-trip

@Test func httpTransport_directJSON_toolCallRoundTrip() async throws {
    let helper = try startHTTPHelper(mode: "json")
    defer { stopHTTPHelper(helper) }

    let transport = MCPHTTPTransport(serverId: "http-json", endpoint: endpointURL(helper), timeout: 10)
    let result = try await transport.callTool(
        name: "echo",
        arguments: .object(["q": .string("hello"), "n": .int(7)])
    )
    guard case .object(let obj) = result else {
        Issue.record("expected object result, got \(result)")
        return
    }
    #expect(obj["calledTool"] == .string("echo"))
    #expect(obj["echoArgs"] == .object(["q": .string("hello"), "n": .int(7)]))
    #expect(obj["isError"] == .bool(false))
}

// MARK: - SSE round-trip

@Test func httpTransport_sse_toolCallRoundTrip() async throws {
    let helper = try startHTTPHelper(mode: "sse")
    defer { stopHTTPHelper(helper) }

    let transport = MCPHTTPTransport(serverId: "http-sse", endpoint: endpointURL(helper), timeout: 10)
    // tools/list first to exercise the SSE parse on a list response too.
    let tools = try await transport.listTools()
    #expect(tools.count == 2)

    let result = try await transport.callTool(
        name: "ping",
        arguments: .object(["v": .int(1)])
    )
    guard case .object(let obj) = result else {
        Issue.record("expected object result, got \(result)")
        return
    }
    #expect(obj["calledTool"] == .string("ping"))
    #expect(obj["echoArgs"] == .object(["v": .int(1)]))
}

// MARK: - Session-id header replay

@Test func httpTransport_replaysSessionIdHeader() async throws {
    // In json_session mode the server rejects any post-initialize request that
    // does NOT carry the Mcp-Session-Id assigned at initialize. Two successful
    // post-initialize requests (tools/list + tools/call) therefore PROVE the
    // transport captured and replayed the header on both.
    let helper = try startHTTPHelper(mode: "json_session")
    defer { stopHTTPHelper(helper) }

    let transport = MCPHTTPTransport(serverId: "http-session", endpoint: endpointURL(helper), timeout: 10)
    let tools = try await transport.listTools()
    #expect(tools.count == 2)

    let result = try await transport.callTool(name: "echo", arguments: .object(["k": .string("v")]))
    guard case .object(let obj) = result else {
        Issue.record("expected object result, got \(result)")
        return
    }
    #expect(obj["calledTool"] == .string("echo"))
    #expect(obj["echoArgs"] == .object(["k": .string("v")]))
}

// MARK: - Timeout path

@Test func httpTransport_timesOutWhenServerNeverReplies() async throws {
    let helper = try startHTTPHelper(mode: "hang")
    defer { stopHTTPHelper(helper) }

    let timeout: TimeInterval = 1.5
    let transport = MCPHTTPTransport(serverId: "http-hang", endpoint: endpointURL(helper), timeout: timeout)

    do {
        _ = try await transport.callTool(name: "echo", arguments: .object([:]))
        Issue.record("expected a timeout throw, but callTool returned")
    } catch let error as MCPSubprocessError {
        guard case .timeout(_, let seconds) = error else {
            Issue.record("expected .timeout, got \(error)")
            return
        }
        #expect(seconds == timeout)
    }
    // Do not measure when this suspended test task gets another executor turn:
    // full-suite saturation may delay caller resumption after URLSession has
    // already enforced the request/resource deadline. The live never-reply
    // helper proves the operation cannot succeed; the deterministic protocol
    // test below proves native timeout normalization.
}

@Test func httpTransport_mapsNativeURLTimeoutIntoDomainTimeout() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ImmediateTimeoutURLProtocol.self]
    let timeout: TimeInterval = 7
    let transport = MCPHTTPTransport(
        serverId: "http-native-timeout",
        endpoint: URL(string: "https://timeout.invalid/mcp")!,
        timeout: timeout,
        session: URLSession(configuration: configuration)
    )

    do {
        _ = try await transport.callTool(name: "echo", arguments: .object([:]))
        Issue.record("expected native URL timeout to map into MCP timeout")
    } catch let error as MCPSubprocessError {
        guard case .timeout(let method, let seconds) = error else {
            Issue.record("expected .timeout, got \(error)")
            return
        }
        #expect(method == "initialize")
        #expect(seconds == timeout)
    }
}

// MARK: - callToolLive routes a non-searxng http server to the generic transport

@Test func callToolLive_routesNonSearxngHTTPToGenericTransport() async throws {
    let helper = try startHTTPHelper(mode: "json")
    defer { stopHTTPHelper(helper) }

    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mcpDir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
    let server: JSONValue = .object([
        "id": .string("http-remote"),
        "name": .string("Remote HTTP MCP"),
        "transport": .string("http"),
        "endpoint": .string("http://127.0.0.1:\(helper.port)/"),
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "toolCount": .int(2),
        "resourceCount": .int(0),
        "riskClass": .string("network_read"),
        "createdAt": .string("2026-07-01T00:00:00+00:00"),
        "updatedAt": .string("2026-07-01T00:00:00+00:00"),
    ])
    try JSONValue.array([server])
        .serializedData(pretty: true)
        .write(to: mcpDir.appendingPathComponent("servers.json"))

    let dispatcher = SwiftNativeMCPDispatcher(root: root)
    let result = try await dispatcher.callToolLive(
        forServer: "http-remote",
        toolName: "echo",
        arguments: .object(["hello": .string("world")])
    )
    // Wrapped in the okMCPResult envelope the searxng path uses.
    guard case .object(let obj) = result,
          obj["status"] == .string("ok"),
          case .object(let payload)? = obj["result"]
    else {
        Issue.record("expected ok-wrapped MCP result, got \(result)")
        return
    }
    #expect(payload["calledTool"] == .string("echo"))
    #expect(payload["echoArgs"] == .object(["hello": .string("world")]))
}

// MARK: - Empty endpoint fails loudly (no silent fallthrough)

@Test func callToolLive_httpEmptyEndpointThrows() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mcpDir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
    let server: JSONValue = .object([
        "id": .string("http-noendpoint"),
        "name": .string("Broken HTTP MCP"),
        "transport": .string("http"),
        "endpoint": .string(""),
        "status": .string("ready"),
        "healthStatus": .string("ok"),
        "toolCount": .int(0),
        "resourceCount": .int(0),
        "riskClass": .string("network_read"),
        "createdAt": .string("2026-07-01T00:00:00+00:00"),
        "updatedAt": .string("2026-07-01T00:00:00+00:00"),
    ])
    try JSONValue.array([server])
        .serializedData(pretty: true)
        .write(to: mcpDir.appendingPathComponent("servers.json"))

    let dispatcher = SwiftNativeMCPDispatcher(root: root)
    await #expect(throws: MCPSubprocessError.self) {
        _ = try await dispatcher.callToolLive(forServer: "http-noendpoint", toolName: "echo")
    }
}

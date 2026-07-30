import Foundation
import PersistenceCore

// MARK: - Generic MCP streamable-HTTP transport

/// A generic MCP client speaking the "streamable HTTP" transport from the
/// MCP spec: JSON-RPC 2.0 over HTTP POST, where the server may reply with
/// EITHER a direct `application/json` body OR a `text/event-stream` (SSE)
/// where `data:` lines carry the JSON-RPC frames.
///
/// This is the generic sibling of the hardcoded `searxng-local` bridge — it
/// works against any MCP server that exposes an HTTP endpoint. It is an actor
/// because it owns mutable session state (the `Mcp-Session-Id` captured at
/// `initialize` and replayed on every subsequent request, plus the JSON-RPC
/// id counter).
///
/// Lifecycle: the first outward call runs the `initialize` handshake exactly
/// once (capturing `Mcp-Session-Id` and emitting the `notifications/initialized`
/// notification per spec), then the requested `tools/list` / `tools/call`.
///
/// No silent fallbacks: every failure — non-2xx status, empty endpoint, timeout,
/// malformed SSE, JSON-RPC error object — surfaces as a thrown error naming the
/// server id (and HTTP status where applicable). A caller must never mistake a
/// transport failure for "route to a different transport".
public actor MCPHTTPTransport {
    public static let defaultTimeout: TimeInterval = 60

    private let serverId: String
    private let endpoint: URL
    private let requestTimeout: TimeInterval
    private let session: URLSession

    /// Captured from the `initialize` response's `Mcp-Session-Id` header and
    /// replayed on every later request per the streamable-HTTP spec. `nil`
    /// until the server assigns one (servers may omit it — session-less mode).
    private var sessionId: String?
    /// Monotonic JSON-RPC request id.
    private var idCounter: Int64 = 0
    /// Single-flight `initialize` + `notifications/initialized` handshake.
    /// Installed synchronously before the first network await so concurrent
    /// first callers join the same handshake; cleared on failure for retry.
    private var initTask: Task<Void, Error>?

    public init(
        serverId: String,
        endpoint: URL,
        timeout: TimeInterval = MCPHTTPTransport.defaultTimeout,
        session: URLSession? = nil
    ) {
        self.serverId = serverId
        self.endpoint = endpoint
        self.requestTimeout = timeout
        if let s = session {
            self.session = s
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    private func nextId() -> Int64 {
        idCounter += 1
        return idCounter
    }

    // MARK: Public MCP verbs

    /// Runs the `initialize` handshake if it hasn't run yet: sends
    /// `initialize`, captures the session id, then sends the
    /// `notifications/initialized` notification. Idempotent AND single-flight
    /// (final review, HIGH): the handshake suspends on network awaits, so
    /// under actor re-entrancy a second first-time caller could otherwise see
    /// the un-set flag and run a duplicate initialize, racing the session-id
    /// capture. The in-flight Task is installed synchronously before the
    /// first await; concurrent callers join it. A failed handshake clears the
    /// slot so the next caller retries cleanly.
    public func initializeIfNeeded() async throws {
        if let inflight = initTask {
            return try await inflight.value
        }
        let task = Task { try await self.performInitialize() }
        initTask = task
        do {
            try await task.value
        } catch {
            if let current = initTask, current == task {
                initTask = nil
            }
            throw error
        }
    }

    private func performInitialize() async throws {
        let initParams: JSONValue = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("NativeAgent"),
                "version": .string("1.0.0"),
            ]),
        ])
        _ = try await sendRequest(method: "initialize", params: initParams, expectsResponse: true)
        // notifications/initialized is a *notification*: no id, no response.
        _ = try await sendRequest(
            method: "notifications/initialized",
            params: .object([:]),
            expectsResponse: false
        )
    }

    /// `tools/list` — returns the raw `tools` array from the JSON-RPC result.
    /// A malformed result THROWS (final review, MEDIUM): silently returning
    /// [] would make a broken HTTP MCP server indistinguishable from an
    /// empty one — the no-silent-fallback contract applies to shapes too.
    public func listTools() async throws -> [JSONValue] {
        try await initializeIfNeeded()
        let result = try await sendRequest(method: "tools/list", params: .object([:]), expectsResponse: true)
        guard case .object(let obj) = result ?? .null,
              case .array(let arr) = obj["tools"] ?? .null else {
            throw MCPSubprocessError.httpTransport(
                serverId: serverId, status: nil,
                detail: "tools/list result missing a 'tools' array"
            )
        }
        return arr
    }

    /// `tools/call` — returns the raw JSON-RPC `result` object exactly as the
    /// server emits it (typically an MCP tool-result `{content:[...], isError}`).
    public func callTool(name: String, arguments: JSONValue) async throws -> JSONValue {
        try await initializeIfNeeded()
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments,
        ])
        guard let result = try await sendRequest(method: "tools/call", params: params, expectsResponse: true) else {
            throw MCPSubprocessError.httpTransport(
                serverId: serverId, status: nil,
                detail: "tools/call returned no JSON-RPC result"
            )
        }
        return result
    }

    // MARK: Request core (actor-isolated; delegates network I/O to a
    // nonisolated static so the timeout race stays Sendable-clean)

    private func sendRequest(
        method: String,
        params: JSONValue,
        expectsResponse: Bool
    ) async throws -> JSONValue? {
        let id: Int64? = expectsResponse ? nextId() : nil
        // Snapshot actor state into locals so the @Sendable timeout closure
        // never captures the actor.
        let sess = session
        let ep = endpoint
        let sid = serverId
        let to = requestTimeout
        let currentSessionId = sessionId
        let outcome = try await Self.withTimeout(to, serverId: sid, method: method) {
            try await Self.httpRPC(
                session: sess,
                endpoint: ep,
                serverId: sid,
                method: method,
                params: params,
                id: id,
                sessionId: currentSessionId,
                expectsResponse: expectsResponse,
                timeout: to
            )
        }
        if let newSid = outcome.sessionId, !newSid.isEmpty {
            sessionId = newSid
        }
        return outcome.result
    }

    // MARK: Nonisolated network primitives

    /// One JSON-RPC POST. Returns the parsed `result` (nil for notifications)
    /// plus any `Mcp-Session-Id` header the server assigned.
    private nonisolated static func httpRPC(
        session: URLSession,
        endpoint: URL,
        serverId: String,
        method: String,
        params: JSONValue,
        id: Int64?,
        sessionId: String?,
        expectsResponse: Bool,
        timeout: TimeInterval
    ) async throws -> (result: JSONValue?, sessionId: String?) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sid = sessionId, !sid.isEmpty {
            req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
        var bodyObj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]
        if let id = id { bodyObj["id"] = .int(id) }
        req.httpBody = try JSONValue.object(bodyObj).serializedData(pretty: false)

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            // Drain so the connection is released before we bail.
            for try await _ in bytes {}
            throw MCPSubprocessError.httpTransport(
                serverId: serverId, status: nil, detail: "non-HTTP response"
            )
        }
        let newSid = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        guard (200..<300).contains(http.statusCode) else {
            for try await _ in bytes {}
            throw MCPSubprocessError.httpTransport(
                serverId: serverId, status: http.statusCode,
                detail: "HTTP \(http.statusCode) from \(endpoint.absoluteString) (method \(method))"
            )
        }

        // Notifications carry no response body worth parsing (spec: 202
        // Accepted, empty). Drain and return the session id only.
        if !expectsResponse {
            for try await _ in bytes {}
            return (nil, newSid)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            let result = try await parseSSE(
                bytes, serverId: serverId, matchingId: id, method: method
            )
            return (result, newSid)
        } else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            let result = try parseJSONRPC(
                data, serverId: serverId, matchingId: id, method: method
            )
            return (result, newSid)
        }
    }

    /// Consume an SSE stream, parsing each event's accumulated `data:` payload
    /// as a JSON-RPC frame. Returns the `result` of the first frame whose id
    /// matches; stops reading immediately once matched. Throws if the stream
    /// ends without the matching response.
    private nonisolated static func parseSSE(
        _ bytes: URLSession.AsyncBytes,
        serverId: String,
        matchingId id: Int64?,
        method: String
    ) async throws -> JSONValue {
        // R15: SSEEventStream owns framing (data:-with/without-space, comments,
        // multi-line payload joins, blank-line dispatch, EOF flush of a
        // trailing unterminated event). Byte-level line splitting makes event
        // boundaries reliable, so the old parse-after-every-data-line
        // heuristic (bytes.lines swallowing blank separator lines) is gone.
        // Each complete event's payload is tried as ONE JSON-RPC frame;
        // non-JSON payloads and non-matching frames (server notifications /
        // decoys) are skipped.
        for try await sse in SSEEventStream(bytes) {
            try Task.checkCancellation()
            guard let msg = try? JSONValue.parse(Data(sse.data.utf8)) else { continue }
            if idMatches(msg, id) {
                return try extractResult(msg, serverId: serverId, method: method)
            }
        }
        throw MCPSubprocessError.httpTransport(
            serverId: serverId, status: nil,
            detail: "SSE stream closed before a response with the matching id arrived (method \(method))"
        )
    }

    private nonisolated static func parseJSONRPC(
        _ data: Data,
        serverId: String,
        matchingId id: Int64?,
        method: String
    ) throws -> JSONValue {
        guard let msg = try? JSONValue.parse(data) else {
            throw MCPSubprocessError.httpTransport(
                serverId: serverId, status: nil,
                detail: "response body was not valid JSON (method \(method))"
            )
        }
        guard idMatches(msg, id) else {
            throw MCPSubprocessError.httpTransport(
                serverId: serverId, status: nil,
                detail: "JSON-RPC response id did not match request (method \(method))"
            )
        }
        return try extractResult(msg, serverId: serverId, method: method)
    }

    /// True when `msg` is a JSON-RPC object whose `id` equals `id`. A `nil`
    /// expected id (notification path) matches any object — unused on the
    /// response paths (they always pass a concrete id).
    private nonisolated static func idMatches(_ msg: JSONValue, _ id: Int64?) -> Bool {
        guard let id = id else { return true }
        guard case .object(let obj) = msg else { return false }
        switch obj["id"] ?? .null {
        case .int(let mid): return mid == id
        case .double(let d): return Int64(d) == id
        case .string(let s): return s == String(id)
        default: return false
        }
    }

    /// Pull `result` out of a JSON-RPC response, or throw on a JSON-RPC `error`.
    private nonisolated static func extractResult(
        _ msg: JSONValue,
        serverId: String,
        method: String
    ) throws -> JSONValue {
        guard case .object(let obj) = msg else {
            throw MCPSubprocessError.httpTransport(
                serverId: serverId, status: nil,
                detail: "JSON-RPC frame was not an object (method \(method))"
            )
        }
        if case .object(let err) = obj["error"] ?? .null {
            let code: Int
            if case .int(let c) = err["code"] ?? .null { code = Int(c) } else { code = -1 }
            let message: String
            if case .string(let m) = err["message"] ?? .null {
                message = m
            } else {
                message = "unknown JSON-RPC error"
            }
            throw MCPSubprocessError.rpcError(code: code, message: "[\(serverId)] \(message)")
        }
        if let result = obj["result"] { return result }
        throw MCPSubprocessError.httpTransport(
            serverId: serverId, status: nil,
            detail: "JSON-RPC response had neither result nor error (method \(method))"
        )
    }

    // MARK: Timeout race

    /// Run `operation` with a hard deadline. Guarantees a bounded throw even
    /// when a server accepts the connection but never sends the response body
    /// (the SSE never-reply case).
    private nonisolated static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        serverId: String,
        method: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw MCPSubprocessError.timeout(method: method, seconds: seconds)
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain,
                   nsError.code == NSURLErrorTimedOut {
                    throw MCPSubprocessError.timeout(method: method, seconds: seconds)
                }
                throw error
            }
        }
    }
}

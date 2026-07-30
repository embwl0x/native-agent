// BridgeCore — shared server tissue for the resident loopback HTTP bridges
// (ClaudeBridge on 8771, MacControlBridge on 8770). Before C5 the two bridges
// copy-pasted ~11 server concerns with ASYMMETRIC hardening: ClaudeBridge had
// header-size caps + EOF handling that MacControlBridge lacked; MacControlBridge
// had a UUID-gated read deadline (ObjectIdentifier-reuse resistant) that
// ClaudeBridge lacked; each had a slightly different writeJSON status table and
// its own verbatim copy of the constant-time bearer compare. This module carries
// the BEST-OF-BOTH once, so neither copy can drift again.
//
// Deliberately NOT owned here (they diverge per bridge and stay bridge-local):
//   - the NWListener + its ready/terminated/stop lifecycle (MacControlBridge
//     gates admission behind durable-operation recovery and kills exec children
//     on stop; ClaudeBridge manages SSE subscribers + Codex reply recovery),
//   - token storage + the on-disk descriptor path/format,
//   - the connection registry itself (each bridge keeps it under its own single
//     lock so accept/terminate/stop stay atomic against token mutation) — but
//     both now use the SHARED `BridgeReadDeadlineState` value type + the shared
//     read/parse/auth/response statics below.
//
// Each bridge conforms to `BridgeHTTPServer` and delegates request reading, the
// content-length parse, the bearer-auth decision, and the JSON response to the
// statics here; it keeps only its route table + per-endpoint semantics.

import Foundation
import Darwin
import Network
import Security

/// Identity-gated state for one accepted connection's exact request-read
/// deadline. The token prevents a late deadline work item from cancelling a
/// DIFFERENT connection if an `ObjectIdentifier` is ever reused after the
/// original connection deallocated. Shared by both bridges as of C5 (was
/// MacControlBridge-only; ClaudeBridge previously relied on a plain
/// `[weak conn]` timer keyed by ObjectIdentifier).
struct BridgeReadDeadlineState: Sendable, Equatable {
    let token: UUID
    var routed: Bool = false

    func shouldCancel(firingToken: UUID) -> Bool {
        token == firingToken && !routed
    }
}

/// Outcome of the shared bearer-token auth decision.
enum BridgeAuthDecision: Equatable {
    /// Bearer matched the live token — dispatch the route.
    case authorized
    /// The live token is empty (the listener was terminated between accept and
    /// route). Answer 503 rather than leaking that race as a 200 to a peer that
    /// sent "Authorization: Bearer " (which string-equals an empty token).
    case serverStopping
    /// Bearer present but did not match — answer 401.
    case unauthorized
}

/// A loopback HTTP bridge that reads requests through `BridgeCore`. `route` is
/// invoked exactly once, after a full request (headers + Content-Length body)
/// has been read. Held weakly by the receive chain so a dead bridge stops the
/// read loop.
protocol BridgeHTTPServer: AnyObject, Sendable {
    func route(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data)
}

/// Shared, stateless server tissue. All members are `static` — there is no
/// per-instance state here; the stateful pieces (listener, token, connection
/// registry) stay with each bridge.
enum BridgeCore {
    /// Ceiling on the header block, enforced BOTH before the `\r\n\r\n`
    /// terminator (bounds pre-auth RAM against a peer that never terminates the
    /// header block) AND on a terminated-but-oversized block. 64KB is far above
    /// any legitimate request header set. (ClaudeBridge's cap, now shared so
    /// MacControlBridge gains it.)
    static let headerByteCap = 65_536

    // MARK: - Endpoint

    /// True for loopback peers (localhost / 127.0.0.1 / ::1). A non-hostPort
    /// endpoint (should not occur on a loopback-required listener) is treated as
    /// loopback rather than dropped.
    static func endpointIsLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return true }
        let value = "\(host)".lowercased()
        return value == "localhost"
            || value == "127.0.0.1"
            || value == "::1"
            || value.contains("127.0.0.1")
            || value.contains("::1")
    }

    // MARK: - Token

    /// 24 cryptographically-random bytes, base64url with no padding. Returns nil
    /// only when the OS RNG fails; callers treat that as a failed startup.
    static func generateToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Auth

    /// Constant-time bearer-token compare. XOR-OR every byte and return at the
    /// end — a length mismatch sets `diff` non-zero up front and STILL walks the
    /// loop so wall-clock timing can't be used to recover the token byte-by-byte
    /// or leak its length via a short-circuit return.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let aCount = aBytes.count
        let bCount = bBytes.count
        var diff: UInt8 = (aCount == bCount) ? 0 : 1
        let limit = max(aCount, bCount, 1)
        for i in 0..<limit {
            let av = i < aCount ? aBytes[i] : 0
            let bv = i < bCount ? bBytes[i] : 0
            diff |= av ^ bv
        }
        return diff == 0
    }

    /// Shared bearer-auth decision. Empty live token → `.serverStopping` (the
    /// listener was terminated mid-flight); otherwise a constant-time compare
    /// against `Bearer <liveToken>`.
    static func authorize(authorizationHeader: String?, liveToken: String) -> BridgeAuthDecision {
        guard !liveToken.isEmpty else { return .serverStopping }
        let auth = authorizationHeader ?? ""
        return constantTimeEquals(auth, "Bearer \(liveToken)") ? .authorized : .unauthorized
    }

    // MARK: - HTTP request reading

    /// Parse Content-Length. Absent/empty header → 0 (no body). A non-numeric,
    /// negative, or over-`maxBytes` value → nil (the caller answers 413).
    static func parseContentLength(_ headers: [String: String], maxBytes: Int) -> Int? {
        guard let raw = headers["content-length"], !raw.isEmpty else { return 0 }
        guard let length = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              length >= 0,
              length <= maxBytes
        else {
            return nil
        }
        return length
    }

    /// Read one HTTP request: accumulate until the `\r\n\r\n` terminator (capped
    /// at `headerByteCap` both pre- and post-terminator), parse the request line
    /// + headers, then read exactly Content-Length body bytes. Cancels the
    /// connection on transport error or premature EOF (peer closed before the
    /// promised bytes arrived). On a fully-read request, invokes `server.route`.
    static func readRequest<Server: BridgeHTTPServer>(
        _ conn: NWConnection,
        buffered: Data,
        maxBodyBytes: Int,
        server: Server
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak server] data, _, isComplete, error in
            guard let server else { return }
            if error != nil { conn.cancel(); return }
            var buf = buffered
            if let d = data { buf.append(d) }

            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                // Bound pre-terminator accumulation: a peer streaming unbounded
                // header bytes (never sending the terminator) would otherwise
                // grow `buf` until the read deadline — pre-auth RAM exhaustion.
                if buf.count > headerByteCap { conn.cancel(); return }
                if isComplete {
                    conn.cancel()
                } else {
                    readRequest(conn, buffered: buf, maxBodyBytes: maxBodyBytes, server: server)
                }
                return
            }

            // Enforce the cap on TERMINATED blocks too — without this a single
            // oversized-but-valid header section bypasses the pre-terminator cap.
            guard headerEnd.lowerBound <= headerByteCap else { conn.cancel(); return }

            let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerStr = String(data: headerData, encoding: .utf8) else { conn.cancel(); return }

            let lines = headerStr.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else { conn.cancel(); return }
            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            let method = parts[0]
            let path = parts[1].components(separatedBy: "?").first ?? parts[1]

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    let k = String(line[..<colon]).lowercased()
                    let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    headers[k] = v
                }
            }

            guard let contentLength = parseContentLength(headers, maxBytes: maxBodyBytes) else {
                writeJSON(conn, status: 413, obj: ["error": "invalid_content_length"])
                return
            }
            let bodyStart = headerEnd.upperBound
            let bodyAlready = buf.subdata(in: bodyStart..<buf.count)

            if bodyAlready.count >= contentLength {
                let body = Data(bodyAlready.prefix(contentLength))
                server.route(conn: conn, method: method, path: path, headers: headers, body: body)
            } else {
                readBody(conn, have: bodyAlready, need: contentLength, method: method, path: path, headers: headers, server: server)
            }
        }
    }

    /// Read the remaining Content-Length body bytes. Cancels on transport error
    /// or premature EOF (`isComplete` before `need` bytes); the per-connection
    /// read deadline is the final backstop against a peer that simply stalls.
    static func readBody<Server: BridgeHTTPServer>(
        _ conn: NWConnection,
        have: Data,
        need: Int,
        method: String,
        path: String,
        headers: [String: String],
        server: Server
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: max(1, need - have.count)) { [weak server] data, _, isComplete, error in
            guard let server else { return }
            if error != nil { conn.cancel(); return }
            var acc = have
            if let d = data { acc.append(d) }
            if acc.count >= need {
                let body = Data(acc.prefix(need))
                server.route(conn: conn, method: method, path: path, headers: headers, body: body)
            } else if isComplete {
                // Peer closed before the promised body arrived — abandon.
                conn.cancel()
            } else {
                readBody(conn, have: acc, need: need, method: method, path: path, headers: headers, server: server)
            }
        }
    }

    // MARK: - HTTP response

    /// Reason phrase for the status codes both bridges emit (union of the two
    /// prior tables). Unknown codes fall back to "Internal Server Error".
    static func statusText(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default:  return "Internal Server Error"
        }
    }

    /// Serialize `obj` and send a single `Connection: close` JSON response, then
    /// cancel the connection. A payload that is not JSON-serializable falls back
    /// to a small error body rather than dropping the response entirely
    /// (ClaudeBridge's safety, now shared — MacControlBridge previously just
    /// cancelled the socket on that impossible path).
    static func writeJSON(_ conn: NWConnection, status: Int, obj: [String: Any]) {
        let data: Data
        if JSONSerialization.isValidJSONObject(obj),
           let d = try? JSONSerialization.data(withJSONObject: obj) {
            data = d
        } else {
            data = Data("{\"error\":\"serialization_failed\"}".utf8)
        }
        let header = "HTTP/1.1 \(status) \(statusText(for: status))\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var resp = Data(header.utf8)
        resp.append(data)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }
}

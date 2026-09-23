import Foundation
import Darwin
import PersistenceCore

private enum LinkFailure: Error {
    case invalidArguments, descriptor, transport, response, http(Int)
    var label: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .descriptor: "bridge_descriptor_unavailable_or_unsafe"
        case .transport: "transport_outcome_unknown"
        case .response: "invalid_or_oversized_response"
        case .http(let status): "http_\(status)_outcome_unconfirmed"
        }
    }
}

/// Credentials never enter command arguments, stdout, logs, or persisted state.
private struct BridgeDescriptor {
    let endpoint: URL
    let token: String
    /// THIS CONNECTION'S OWN SECRET, when the app set this entry up itself.
    ///
    /// It comes from the environment of the entry the app wrote into the other
    /// agent's settings (with NATIVE_AGENT_PEER_ID), is sent as the bearer, and
    /// the bridge resolves it to the contact that owns it. Absent — every
    /// hand-made entry — the descriptor's main token is used as before.
    ///
    /// Environment, never an argument: arguments are readable by every process
    /// on the Mac.
    let peerSecret: String?

    static func load(pathOverride: String? = nil, bearer: String? = nil) throws -> Self {
        let path = pathOverride ?? ProcessInfo.processInfo.environment["NATIVE_AGENT_BRIDGE_DESCRIPTOR"]
            ?? InstallPaths.current.bridgeConfigRoot.appendingPathComponent("claude-bridge/bridge.json").path
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw LinkFailure.descriptor }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 65_536
        else { throw LinkFailure.descriptor }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, data.count + count <= 65_536 else { throw LinkFailure.descriptor }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = object["url"] as? String,
              var url = URLComponents(string: address), url.scheme == "http",
              ["127.0.0.1", "::1", "[::1]"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let port = url.port, (1...65535).contains(port)
        else { throw LinkFailure.descriptor }
        url.path = "/agent/mcp"
        guard let endpoint = url.url else { throw LinkFailure.descriptor }
        let environment = ProcessInfo.processInfo.environment
        func identity(_ name: String) -> String? {
            guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, raw.utf8.count <= 8192,
                  // Header-safe and log-safe: printable ASCII only, so a value
                  // someone pasted in by hand can never inject a second header.
                  raw.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e })
            else { return nil }
            return raw
        }
        let peerID = identity("NATIVE_AGENT_PEER_ID")
        let peerSecret = identity("NATIVE_AGENT_PEER_SECRET")
        // 2026-09-22: a connection with its own identity sends its SECRET as
        // the bearer and no identity headers; the bridge maps it on contact
        // paths, so the main token is never read or sent. Half an identity is
        // still no identity.
        if let bearer { return Self(endpoint: endpoint, token: bearer, peerSecret: nil) }
        if peerID != nil, let peerSecret {
            return Self(endpoint: endpoint, token: peerSecret, peerSecret: peerSecret)
        }
        guard let token = object["token"] as? String, !token.isEmpty, token.utf8.count <= 8192,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw LinkFailure.descriptor }
        return Self(endpoint: endpoint, token: token, peerSecret: nil)
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum BridgeHTTP {
    static func initialize(descriptor: BridgeDescriptor) async throws {
        let id = UUID().uuidString
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "capabilities": [String: String](),
                       "clientInfo": ["name": "nativeagent-link", "version": "1.0"]]]
        guard let response = try await post(payload, descriptor: descriptor),
              response["jsonrpc"] as? String == "2.0", response["id"] as? String == id,
              response["error"] == nil, let result = response["result"] as? [String: Any],
              result["protocolVersion"] as? String == "2025-11-25" else { throw LinkFailure.response }
        guard try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], descriptor: descriptor) == nil
        else { throw LinkFailure.response }
    }

    /// One POST only. A lost acknowledgement must be recovered by IDs, never resent.
    static func post(_ payload: [String: Any], descriptor: BridgeDescriptor) async throws -> [String: Any]? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: descriptor.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("Bearer \(descriptor.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { throw LinkFailure.transport }
        guard let http = response as? HTTPURLResponse else { throw LinkFailure.response }
        guard (200...299).contains(http.statusCode) else { throw LinkFailure.http(http.statusCode) }
        if http.statusCode == 202 { return nil }
        guard http.mimeType == "application/json", http.expectedContentLength <= 1_048_576 else {
            throw LinkFailure.response
        }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < 1_048_576 else { throw LinkFailure.response }
                data.append(byte)
            }
        } catch let failure as LinkFailure { throw failure }
        catch { throw LinkFailure.transport }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LinkFailure.response
        }
        // Defensive removal even if a compromised local server echoes a secret
        // back. This connection's own key is scrubbed alongside the bearer.
        var scrubbed = scrub(object, token: descriptor.token)
        if let secret = descriptor.peerSecret { scrubbed = scrub(scrubbed, token: secret) }
        return scrubbed as? [String: Any]
    }

    private static func scrub(_ value: Any, token: String) -> Any {
        if let text = value as? String { return text.replacingOccurrences(of: token, with: "[redacted]") }
        if let values = value as? [Any] { return values.map { scrub($0, token: token) } }
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { output, entry in
                output[entry.key.replacingOccurrences(of: token, with: "[redacted]")] = scrub(entry.value, token: token)
            }
        }
        return value
    }
}

@main
private struct NativeAgentLink {
    static func exactUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value.lowercased()
    }

    static let usage = """
    nativeagent-link message <text> [--session id] [--request id]
    nativeagent-link reply --session id --request id [--offset n]
    nativeagent-link reply --contact id < reply.json
    nativeagent-link mcp

    Connects to the running NativeAgent on this Mac. Message returns enqueue
    acknowledgement, not a final answer. Keep both IDs and use reply to recover.
    Never automatically resend an uncertain message. The mcp command relays
    newline-delimited MCP JSON-RPC over stdio; configure it as an MCP server command.
    """

    static func output(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] || args == ["-h"] { print(usage); return }
        if args == ["mcp"] { await relay(); return }
        if args.count == 3, args[0] == "reply", args[1] == "--contact" {
            await submitReply(peer: args[2]); return
        }
        var recovery: [String: Any] = [:]
        do {
            guard let operation = args.first, ["message", "reply"].contains(operation) else {
                throw LinkFailure.invalidArguments
            }
            var remaining = Array(args.dropFirst())
            var arguments: [String: Any] = [:]
            if operation == "message" {
                guard let text = remaining.first, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 64_000,
                      !text.hasPrefix("--") else { throw LinkFailure.invalidArguments }
                arguments["text"] = text
                remaining.removeFirst()
            }
            var seen = Set<String>()
            while !remaining.isEmpty {
                guard remaining.count >= 2 else { throw LinkFailure.invalidArguments }
                let key = remaining.removeFirst(), value = remaining.removeFirst()
                guard seen.insert(key).inserted else { throw LinkFailure.invalidArguments }
                switch key {
                case "--session", "--request":
                    if key == "--session" {
                        guard value.hasPrefix("mcp-"), exactUUID(String(value.dropFirst(4))) else {
                            throw LinkFailure.invalidArguments
                        }
                    } else if !exactUUID(value) { throw LinkFailure.invalidArguments }
                    arguments[key == "--session" ? "session_id" : "request_id"] = value
                case "--offset":
                    guard operation == "reply", let offset = Int(value), (0...1_048_576).contains(offset) else { throw LinkFailure.invalidArguments }
                    arguments["offset"] = offset
                default: throw LinkFailure.invalidArguments
                }
            }
            if operation == "message" {
                arguments["session_id"] = arguments["session_id"] ?? ("mcp-" + UUID().uuidString.lowercased())
                arguments["request_id"] = arguments["request_id"] ?? UUID().uuidString
            }
            guard let session = arguments["session_id"], let request = arguments["request_id"] else {
                throw LinkFailure.invalidArguments
            }
            recovery = ["session_id": session, "request_id": request,
                        "read_with": ["command": "nativeagent-link", "arguments": ["reply", "--session", session, "--request", request]]]
            let descriptor = try BridgeDescriptor.load()
            try await BridgeHTTP.initialize(descriptor: descriptor)
            let rpcID = UUID().uuidString
            let payload: [String: Any] = ["jsonrpc": "2.0", "id": rpcID, "method": "tools/call",
                "params": ["name": "agent_\(operation)", "arguments": arguments]]
            guard let response = try await BridgeHTTP.post(payload, descriptor: descriptor),
                  response["jsonrpc"] as? String == "2.0",
                  response["id"] as? String == rpcID else { throw LinkFailure.response }
            if let error = response["error"] {
                recovery["error"] = error
                recovery["automatically_resent"] = false
                output(recovery)
                Darwin.exit(1)
            }
            guard let result = response["result"] as? [String: Any] else { throw LinkFailure.response }
            if result["isError"] as? Bool == true {
                recovery["result"] = result
                recovery["automatically_resent"] = false
                output(recovery)
                Darwin.exit(1)
            }
            output(result)
        } catch {
            recovery["error"] = (error as? LinkFailure)?.label ?? "request_failed"
            recovery["automatically_resent"] = false
            output(recovery)
            Darwin.exit(1)
        }
    }

    /// The app owns all MCP semantics. This adapter only changes framing and auth.
    static func submitReply(peer: String) async {
        do {
            guard exactUUID(peer), peer == peer.lowercased() else { throw LinkFailure.invalidArguments }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 && errno == EINTR { continue }
                guard count > 0, data.count + count <= GrokReplyInput.maximumBytes else { throw LinkFailure.invalidArguments }
                data.append(contentsOf: buffer.prefix(count))
            }
            let reply = try GrokReplyInput.parse(data)
            let credential = try GrokLinkCredential.read(peer: peer)
            let local = try BridgeDescriptor.load(pathOverride: credential.descriptorPath, bearer: credential.replyToken)
            let endpoint = local.endpoint.deletingLastPathComponent().appendingPathComponent("grok-reply")
            // Only the contact's bearer crosses loopback. The main token and
            // credentials never go to Grok, stdout or process arguments.
            let descriptor = BridgeDescriptor(endpoint: endpoint, token: credential.replyToken, peerSecret: nil)
            _ = try await BridgeHTTP.post(["message_id": reply.message_id, "text": reply.text], descriptor: descriptor)
            output(["status": "reply_received", "automatically_resent": false])
        } catch {
            output(["error": "reply_refused_or_delivery_unconfirmed", "automatically_resent": false])
            Darwin.exit(1)
        }
    }

    /// The app owns all MCP semantics. This adapter only changes framing and auth.
    /// Sequential requests, bounded input, no background process and no transcript.
    static func relay() async {
        var line = Data()
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count == 0 { return }
            if count < 0 { if errno == EINTR { continue }; return }
            if byte != 10 {
                guard line.count < 1_048_576 else {
                    output(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "MCP input exceeds limit"]])
                    return
                }
                line.append(byte)
                continue
            }
            defer { line.removeAll(keepingCapacity: true) }
            if line.isEmpty { continue }
            guard let payload = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                output(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid JSON object"]])
                continue
            }
            let id = payload["id"]
            do {
                let descriptor = try BridgeDescriptor.load()
                let response = try await BridgeHTTP.post(payload, descriptor: descriptor)
                if let id {
                    guard let response, response["jsonrpc"] as? String == "2.0",
                          let responseID = response["id"] as? NSObject,
                          responseID.isEqual(id) else { throw LinkFailure.response }
                    output(response)
                }
                // Notifications (HTTP 202) never produce a JSON-RPC response.
            } catch {
                if let id {
                    output(["jsonrpc": "2.0", "id": id,
                            "error": ["code": -32000, "message": (error as? LinkFailure)?.label ?? "request_failed"]])
                }
            }
        }
    }
}

import Foundation
import NativeAgentCore
import Darwin
import PersistenceCore

// Blueprint: | `NativeAgentLink.swift` | `NativeAgentLink`: authenticated local bridge client for host stdio relay and explicit replies; credentials stay out of arguments, output and persisted state |

private enum LinkFailure: Error {
    /// No descriptor, or nothing listening on its port: the app is quit or
    /// restarting, and the request never left this process.
    case invalidArguments, descriptor(String, String), bridgeAbsent, transport, response, http(Int)
    var label: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .bridgeAbsent: "nativeagent_not_running_nothing_sent"
        case .descriptor: "bridge_descriptor_unavailable_or_unsafe"
        case .transport: "transport_outcome_unknown"
        case .response: "invalid_or_oversized_response"
        case .http(let status): "http_\(status)_outcome_unconfirmed"
        }
    }

    /// Local owner evidence goes to stderr; rejected HTTP callers still learn nothing.
    func diagnose() {
        let detail: String, remedy: JSONValue
        switch self {
        case .descriptor(let path, let failed):
            detail = path + ": " + failed
            remedy = .object(["kind": .string("inspect"), "instruction": .string(detail),
                "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("files.info"), "args": .object(["path": .string(path)])])])])
        case .http(401):
            guard let peer = ProcessInfo.processInfo.environment["NATIVE_AGENT_PEER_ID"], UUID(uuidString: peer) != nil else { return }
            detail = "The local connector's credential was rejected. Connect this same contact to repair its entry, then reconcile the retained request_id; do not resend an uncertain message."
            remedy = Repair.remedy(owner: "Keychain peer:" + peer, nextCall: .object(["tool": .string("app"),
                "input": .object(["action": .string("agent.connect"), "args": .object(["name": .string("peer:" + peer)])])]), tap: nil)
        default: return
        }
        let value = JSONValue.object(["detail": .string(detail), "remedy": remedy])
        if let data = try? value.serializedData(pretty: false) { FileHandle.standardError.write(data + Data([10])) }
    }
}

/// Credentials never enter command arguments, stdout, logs, or persisted state.
private struct BridgeDescriptor {
    let endpoint: URL
    /// The selected bearer: an explicit contact key, the connector's environment
    /// key, or the shared descriptor token. Environment keys never enter arguments.
    let token: String

    static var path: String {
        ProcessInfo.processInfo.environment["NATIVE_AGENT_BRIDGE_DESCRIPTOR"]
            ?? InstallPaths.current.bridgeConfigRoot.appendingPathComponent("claude-bridge/bridge.json").path
    }

    static func load(pathOverride: String? = nil, bearer: String? = nil) throws -> Self {
        let path = pathOverride ?? Self.path
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            // The app removes its descriptor when it quits.
            if errno == ENOENT { throw LinkFailure.bridgeAbsent }
            throw LinkFailure.descriptor(path, "Descriptor open failed (errno \(errno)); the file must not be a symlink.")
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw LinkFailure.descriptor(path, "Descriptor fstat failed (errno \(errno)).") }
        guard info.st_uid == getuid() else { throw LinkFailure.descriptor(path, "Descriptor owner must be the current uid.") }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw LinkFailure.descriptor(path, "Descriptor must be a regular file.") }
        guard info.st_mode & 0o077 == 0 else { throw LinkFailure.descriptor(path, "Descriptor permissions must exclude group and other access (0600).") }
        guard info.st_size > 0, info.st_size <= 65_536 else { throw LinkFailure.descriptor(path, "Descriptor size must be 1...65536 bytes.") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, data.count + count <= 65_536 else { throw LinkFailure.descriptor(path, "Descriptor read failed or exceeded 65536 bytes.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = object["url"] as? String,
              var url = URLComponents(string: address), url.scheme == "http",
              ["127.0.0.1", "::1", "[::1]"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let port = url.port, (1...65535).contains(port)
        else { throw LinkFailure.descriptor(path, "Descriptor JSON url must be an exact loopback HTTP origin with a valid port and no credentials, path, query or fragment.") }
        url.path = "/agent/mcp"
        guard let endpoint = url.url else { throw LinkFailure.descriptor(path, "Descriptor url could not form the MCP endpoint.") }
        let environment = ProcessInfo.processInfo.environment
        if let bearer { return Self(endpoint: endpoint, token: bearer) }
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
        if (environment["NATIVE_AGENT_PEER_ID"] != nil || environment["NATIVE_AGENT_PEER_SECRET"] != nil),
           peerID == nil || peerSecret == nil {
            throw LinkFailure.descriptor(path, "Connector identity is incomplete or invalid. Repair NATIVE_AGENT_PEER_ID and NATIVE_AGENT_PEER_SECRET together with agent.connect; the shared bearer was not used.")
        }
        // A connector sends its own bearer without identity headers or the shared token.
        if peerID != nil, let peerSecret {
            return Self(endpoint: endpoint, token: peerSecret)
        }
        guard let token = object["token"] as? String, !token.isEmpty, token.utf8.count <= 8192,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw LinkFailure.descriptor(path, "Descriptor token is missing or invalid; regenerate it through the bridge owner. No credential value was logged.") }
        return Self(endpoint: endpoint, token: token)
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
    /// An SSE answer (agent_message waiting for its reply) hands each
    /// notification to `forward` as it arrives and returns the final response.
    static func post(_ payload: [String: Any], descriptor: BridgeDescriptor,
                     forward: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> [String: Any]? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        // agent_message may hold the call open for its reply for up to the
        // app's maximum wait (300 s) without sending a byte.
        configuration.timeoutIntervalForRequest = 330
        configuration.timeoutIntervalForResource = 330
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
        // Declare that the relay reads SSE answers.
        request.setValue("1", forHTTPHeaderField: "X-NativeAgent-Relay-SSE")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch let error as URLError where error.code == .cannotConnectToHost { throw LinkFailure.bridgeAbsent }
        catch { throw LinkFailure.transport }
        guard let http = response as? HTTPURLResponse else { throw LinkFailure.response }
        guard (200...299).contains(http.statusCode) else { throw LinkFailure.http(http.statusCode) }
        if http.statusCode == 202 { return nil }
        func clean(_ object: [String: Any]) -> [String: Any]? {
            // Remove the selected bearer even if a compromised local server echoes it.
            scrub(object, token: descriptor.token) as? [String: Any]
        }
        if http.mimeType == "text/event-stream" {
            var parser = SSEEventParser()
            do {
                for try await byte in bytes {
                    guard let event = try parser.consume(byte: byte, maximumBytes: 1_048_576),
                          let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
                          let message = clean(object) else { continue }
                    if message["method"] != nil { forward?(message) } else { return message }
                }
            } catch let failure as LinkFailure { throw failure }
            catch is CocoaError { throw LinkFailure.response }
            catch { throw LinkFailure.transport }
            throw LinkFailure.response
        }
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
        return clean(object)
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
    nativeagent-link message <text> [--session id] [--request id] [--contact id]
    nativeagent-link reply --session id --request id [--offset n] [--contact id]
    nativeagent-link reply --contact id < reply.json
    nativeagent-link mcp

    Connects to the running NativeAgent on this Mac. Message waits up to 25 s
    for the reply; if it is still in progress it returns the enqueue
    acknowledgement (status enqueued). Keep both IDs and use reply to recover.
    Never automatically resend an uncertain message. The mcp command relays
    newline-delimited MCP JSON-RPC over stdio; configure it as an MCP server command.
    """

    private static let outputLock = NSLock()

    /// One whole line per write, so concurrent relay requests never interleave.
    static func output(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(10)
        outputLock.withLock { FileHandle.standardOutput.write(data) }
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
            var contact: String?
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
                case "--contact":
                    // A contact (Grok Bot) speaks with its own credential, read here
                    // from the keychain: it never crosses arguments, stdout or Grok.
                    guard exactUUID(value), value == value.lowercased() else { throw LinkFailure.invalidArguments }
                    contact = value
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
                        "read_with": ["command": "nativeagent-link", "arguments": ["reply", "--session", session, "--request", request]
                            + (contact.map { ["--contact", $0] } ?? [])]]
            let descriptor: BridgeDescriptor
            if let contact {
                let credential = try GrokLinkCredential.read(peer: contact)
                descriptor = try BridgeDescriptor.load(pathOverride: credential.descriptorPath, bearer: credential.replyToken)
            } else {
                descriptor = try BridgeDescriptor.load()
            }
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
            (error as? LinkFailure)?.diagnose()
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
            let descriptor = BridgeDescriptor(endpoint: endpoint, token: credential.replyToken)
            _ = try await BridgeHTTP.post(["message_id": reply.message_id, "text": reply.text], descriptor: descriptor)
            output(["status": "reply_received", "automatically_resent": false])
        } catch {
            (error as? LinkFailure)?.diagnose()
            output(["error": "reply_refused_or_delivery_unconfirmed", "automatically_resent": false])
            Darwin.exit(1)
        }
    }

    /// The app owns all MCP semantics. This adapter only changes framing and auth.
    /// Each request runs concurrently (agent_message may wait minutes for its
    /// reply while the host pings or calls again); bounded input, no background
    /// process and no transcript. Input ending still waits for every answer.
    static func relay() async {
        await withDiscardingTaskGroup { group in
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
                let request = line
                group.addTask { await relayOne(request) }
            }
        }
    }

    private static func relayOne(_ request: Data) async {
        guard let payload = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else {
            output(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid JSON object"]])
            return
        }
        let id = payload["id"]
        do {
            // A notification is not held for a restart; a request is.
            let response = try await id == nil ? postToBridge(payload) : postWhenBridgeReturns(payload)
            if let id {
                guard let response, response["jsonrpc"] as? String == "2.0",
                      let responseID = response["id"] as? NSObject,
                      responseID.isEqual(id) else { throw LinkFailure.response }
                output(response)
            }
            // Notifications (HTTP 202) never produce a JSON-RPC response.
        } catch LinkFailure.bridgeAbsent {
            guard let id else { return }
            let text = "NativeAgent is not running (or restarting); nothing was sent — try again in a moment."
            output(payload["method"] as? String == "tools/call"
                ? ["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "isError": true]]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": text]])
        } catch {
            (error as? LinkFailure)?.diagnose()
            if let id {
                output(["jsonrpc": "2.0", "id": id,
                        "error": ["code": -32000, "message": (error as? LinkFailure)?.label ?? "request_failed"]])
            }
        }
    }

    private static func postToBridge(_ payload: [String: Any]) async throws -> [String: Any]? {
        // Progress notifications for this call go straight to the host.
        try await BridgeHTTP.post(payload, descriptor: BridgeDescriptor.load(), forward: { output($0) })
    }

    /// The app quits and relaunches itself (updates, permission grants) while
    /// this process and the host's session stay up. A request made meanwhile
    /// waits for the relaunch to republish the descriptor (the port may
    /// differ) and then goes through. The bound keeps the host listening when
    /// the call lands: an established call stays inside the MCP SDK's 60 s
    /// request timeout, `initialize` inside Claude's 30 s startup timeout.
    private static func postWhenBridgeReturns(_ payload: [String: Any]) async throws -> [String: Any]? {
        do { return try await postToBridge(payload) } catch LinkFailure.bridgeAbsent {}
        // Its initial edge retries once armed, so a relaunch in between is not missed.
        let changes = FileChangeEvents(paths: [URL(fileURLWithPath: BridgeDescriptor.path)])
        let budget: Duration = payload["method"] as? String == "initialize" ? .seconds(20) : .seconds(30)
        let deadline = Task { try? await Task.sleep(for: budget); changes.cancel() }
        defer { deadline.cancel(); changes.cancel() }
        for await _ in changes.stream {
            do { return try await postToBridge(payload) } catch LinkFailure.bridgeAbsent {}
        }
        throw LinkFailure.bridgeAbsent
    }
}

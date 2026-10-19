import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ToolRegistry
import Senses
import Network
import Security
import ProviderRouting
import CFNetwork
import MacControl

/// Declared-reach primitives for the shared JavaScript executor.
actor ToolPrimitiveBroker {
    static let readOperations = Set(AuthoredToolEffects.primitiveCapabilities.compactMap { $0.value.contains("safe_read") ? $0.key : nil })
    static let operations = Set(AuthoredToolEffects.primitiveCapabilities.keys.filter { $0.hasPrefix("network.") })
        .union(["model.call", "fetch", "screen.watch"]).union(frameOperations).union(AuthoredToolEffects.handOperations)
    /// Reads inside the run's admitted watch: no admission and no receipt of their own.
    static let frameOperations: Set<String> = ["screen.next", "frame.read"]
    static func knownPermission(_ permission: String) -> Bool {
        AbilityStore.knownReach(permission)
    }
    static func readOnly(_ operation: String, _ arguments: JSONValue) -> Bool {
        operation == "model.call" || AuthoredToolEffects.primitiveEffect(operation, arguments: arguments).capabilities.contains("safe_read")
    }
    private let permissions: Set<String>
    private let host: any OwnedProgramToolHost
    private let abilityID: String
    private var connections: [String: NWConnection] = [:]
    private var listeners: [String: (NWListener, AsyncThrowingStream<String, Error>, AsyncThrowingStream<String, Error>.Continuation)] = [:]
    private let queue = DispatchQueue(label: "nativeagent.authored.network")
    private(set) var closed = false
    private static let byteLimit = 4 * 1024 * 1024
    /// The run's one watch (a second replaces the first), and the receipts of those that ended.
    private var watch: MacScreenWatch?
    private var watched: [JSONValue] = []
    private var abilityObserver: (any NSObjectProtocol)?

    init(permissions: Set<String>, host: any OwnedProgramToolHost, abilityID: String) {
        self.permissions = permissions
        self.host = host; self.abilityID = abilityID
    }

    func check(_ operation: String, arguments: JSONValue) throws {
        try Task.checkCancellation()
        guard !closed, Self.operations.contains(operation), case .object(let args) = arguments else {
            throw SenseFailure(code: "bad_input", message: "A known primitive and named arguments are required.")
        }
        if operation.hasPrefix("screen.") || operation.hasPrefix("frame.") || operation.hasPrefix("hand.") {
            let reach = operation.hasPrefix("hand.") ? "hands" : "screen.watch"
            guard permissions.contains(reach) else {
                throw SenseFailure(code: "undeclared", message: "Declare reach \(reach) to call \(operation).")
            }
            if operation == "screen.watch" { _ = try MacScreenWatch.Request(args) }
        } else if operation == "model.call" || operation == "fetch" {
            let reach: String
            if operation == "model.call" { reach = "model" }
            else {
                if let connector = args["connector"] {
                    guard case .string(let id) = connector, Self.knownPermission("connector:" + id) else {
                        throw SenseFailure(code: "bad_input", message: "connector must name a supported connector.")
                    }
                    reach = "connector:" + id
                } else { reach = "network_public" }
            }
            guard permissions.contains(reach) else {
                throw SenseFailure(code: "undeclared", message: "Declare reach \(reach) to call \(operation).")
            }
            if operation == "fetch", reach == "network_public" {
                guard let url = URL(string: try text(args, "url")), let host = url.host, !Self.loopback(host) else {
                    throw denied("network_public fetch requires a public host.")
                }
            }
            if operation == "fetch" { _ = try SwiftNativeToolExecution.fetchRequest(args) }
        } else {
            guard !permissions.isDisjoint(with: ["network", "network_public", "network_localhost"]) else {
                throw denied("Declare the network permission this operation needs.")
            }
            if operation == "network.connect" || operation == "network.listen" {
                let local = Self.loopback(try text(args, "host"))
                guard permissions.contains("network") || local && permissions.contains("network_localhost")
                    || operation == "network.connect" && !local && permissions.contains("network_public") else {
                    throw denied("This network host or listening operation is outside the declared reach.")
                }
                _ = try port(args, zero: operation == "network.listen")
            }
        }
    }

    func perform(_ operation: String, arguments: JSONValue) async throws -> JSONValue {
        try check(operation, arguments: arguments)
        let args = SwiftNativeToolExecution.fields(arguments)
        if operation == "model.call" { return try await model(args) }
        if operation != "screen.watch", operation.hasPrefix("screen.") || operation.hasPrefix("frame.") || operation.hasPrefix("hand.") {
            guard let watch else { throw SenseFailure(code: "no_watch", message: "Call screen.watch({app}) before \(operation).") }
            switch operation {
            case "screen.next":
                let timeout: Double? = switch args["timeout"] { case .int(let n)?: Double(n); case .double(let n)?: n; default: nil }
                return try await watch.next(timeout: timeout)
            case "frame.read":
                guard case .int(let generation)? = args["watch"], case .int(let seq)? = args["seq"],
                      case .array(let queries)? = args["queries"] else {
                    throw SenseFailure(code: "bad_input", message: "Read a frame through the frame screen.next() returns: frame.read([...]).")
                }
                return try await watch.read(watch: Int(generation), seq: Int(seq), queries: queries)
            default: return try await watch.hand(String(operation.dropFirst("hand.".count)), args)
            }
        }
        if operation == "screen.watch" {
            guard let open = MacScreenWatch.open else {
                throw SenseFailure(code: "unavailable", message: "screen.watch needs the app door of a conversation or wake run.")
            }
            let opened = try await open(try MacScreenWatch.Request(args), permissions.contains("hands"))
            guard !closed else { opened.end("run_ended"); throw CancellationError() }
            endWatch("replaced")
            watch = opened
            // A part changed or replaced mid-run stops watching with its old self.
            let id = abilityID
            abilityObserver = NotificationCenter.default.addObserver(forName: AbilityStore.didChange, object: nil, queue: nil) { change in
                if (change.object as? String).map({ URL(fileURLWithPath: $0).lastPathComponent }) == id { opened.end("part_changed") }
            }
            return opened.opened
        }
        do {
            if operation == "fetch" {
                let result = args["connector"] == nil ? try await fetch(args)
                    : try await host.performReach(operation, arguments: arguments)
                if case .int(let status)? = SwiftNativeToolExecution.fields(result)["status"], status == 429 || (500...599).contains(status) {
                    throw SenseFailure(code: "network", message: "fetch returned HTTP \(status).")
                }
                return result
            }
            return try await network(operation, args: args)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            let code = (error as? SenseFailure)?.code
            if error is URLError || error is NWError || code == "world_error" {
                throw SenseFailure(code: "network", message: error.localizedDescription)
            }
            throw error
        }
    }

    private func model(_ args: [String: JSONValue]) async throws -> JSONValue {
        let purpose = try text(args, "purpose").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !purpose.isEmpty else { throw SenseFailure(code: "bad_input", message: "purpose is required.") }
        guard let client = LLMCallContext.client, let model = LLMCallContext.admittedModel else {
            throw SenseFailure(code: "unavailable", message: "model.call needs the part run's admitted model.")
        }
        var messages: [LLMMessage]
        if args["prompt"] != nil, args["messages"] == nil { messages = [.user(try text(args, "prompt"))] }
        else if args["prompt"] == nil, case .array(let rows)? = args["messages"], !rows.isEmpty {
            messages = try rows.map { row in
                let fields = SwiftNativeToolExecution.fields(row)
                guard let role = LLMMessage.Role(rawValue: try text(fields, "role")) else {
                    throw SenseFailure(code: "bad_input", message: "messages use user, assistant or system roles and string content.")
                }
                return LLMMessage(role: role, content: [.text(try text(fields, "content"))])
            }
        } else { throw SenseFailure(code: "bad_input", message: "Give prompt or a nonempty messages array, exclusively.") }
        if let schema = args["schema"] {
            messages.append(.user("Return only JSON matching this schema: " + String(decoding: try schema.serializedData(pretty: false), as: UTF8.self)))
        }
        let signal = SwiftNativeToolExecution.fields(SkillRunContext.input ?? .null)["signal"]
        let suffix = if case .string(let signal)? = signal { [signal] } else { [String]() }
        let auditPurpose = (["ability", abilityID, purpose] + suffix).joined(separator: ":")
        let reply = try await LLMCallContext.$purpose.withValue(auditPurpose) {
            try await LLMCallContext.$turnTokenBudget.withValue(nil) {
            try await LLMCallContext.$botOutputTokenLimit.withValue(nil) {
            try await LLMCallContext.$systemSegments.withValue(nil) {
            try await ConversationPrefixTelemetry.$sink.withValue(.unmeasuredRequestShape) {
                var reply = ""
                for try await event in client.streamMessages(messages: messages, system: nil, model: model,
                    surface: LLMCallContext.surface ?? "chat", tools: nil) {
                    if case .textDelta(let text) = event { reply += text }
                }
                return reply
            }
            }
            }
            }
        }
        guard let schema = args["schema"] else { return .string(reply) }
        let value = try JSONValue.parse(Data(reply.utf8))
        try value.validate(schema: schema)
        return value
    }

    private func fetch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let request = try SwiftNativeToolExecution.fetchRequest(args)
        let url = request.url!, host = url.host!, tls = url.scheme?.lowercased() == "https"
        let connected = try await network("network.connect", args: ["host": .string(host),
            "port": .int(Int64(url.port ?? (tls ? 443 : 80))), "tls": .bool(tls), "publicOnly": .bool(true)])
        let id = try text(SwiftNativeToolExecution.fields(connected), "id")
        defer { connections.removeValue(forKey: id)?.cancel() }
        let message = CFHTTPMessageCreateRequest(nil, (request.httpMethod! as CFString), url as CFURL, kCFHTTPVersion1_1).takeRetainedValue()
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            CFHTTPMessageSetHeaderFieldValue(message, key as CFString, value as CFString)
        }
        CFHTTPMessageSetHeaderFieldValue(message, "Host" as CFString, (url.port == nil ? host : "\(host):\(url.port!)") as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Connection" as CFString, "close" as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Accept-Encoding" as CFString, "identity" as CFString)
        if let body = request.httpBody {
            CFHTTPMessageSetBody(message, body as CFData)
            CFHTTPMessageSetHeaderFieldValue(message, "Content-Length" as CFString, String(body.count) as CFString)
        }
        guard let wire = CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data? else {
            throw SenseFailure(code: "bad_input", message: "fetch could not encode this HTTP request.")
        }
        _ = try await network("network.send", args: ["id": .string(id), "base64": .string(wire.base64EncodedString())])
        var received = Data()
        while true {
            let reply = SwiftNativeToolExecution.fields(try await network("network.receive", args: ["id": .string(id)]))
            guard let encoded = SwiftNativeToolExecution.string(reply, "base64"), let chunk = Data(base64Encoded: encoded),
                  received.count + chunk.count <= Self.byteLimit else {
                throw SenseFailure(code: "output_limit", message: "fetch response exceeds the 4 MiB primitive limit.")
            }
            received.append(chunk)
            if reply["eof"] == .bool(true) { break }
        }
        guard !received.isEmpty else { throw SenseFailure(code: "bad_output", message: "fetch received no HTTP response.") }
        var response = CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
        while true {
            let parsed = received.withUnsafeBytes { bytes in
                CFHTTPMessageAppendBytes(response, bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count)
            }
            guard parsed, CFHTTPMessageIsHeaderComplete(response) else {
                throw SenseFailure(code: "bad_output", message: "fetch received an incomplete HTTP response.")
            }
            if CFHTTPMessageGetResponseStatusCode(response) >= 200 { break }
            guard CFHTTPMessageGetResponseStatusCode(response) != 101,
                  let rest = CFHTTPMessageCopyBody(response)?.takeRetainedValue() as Data?, !rest.isEmpty else {
                throw SenseFailure(code: "bad_output", message: "fetch requires a final HTTP response, without a protocol upgrade.")
            }
            received = rest; response = CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
        }
        let headers = CFHTTPMessageCopyAllHeaderFields(response)?.takeRetainedValue() as? [String: String] ?? [:]
        let lower = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $0 + ", " + $1 })
        let status = CFHTTPMessageGetResponseStatusCode(response)
        let body = CFHTTPMessageCopyBody(response)?.takeRetainedValue() as Data? ?? Data()
        var data = body
        if request.httpMethod == "HEAD" || status == 204 || status == 304 { data = Data() }
        else if lower["transfer-encoding"]?.lowercased() == "chunked" {
            data = Data(); var cursor = body.startIndex
            while true {
                guard let line = body.range(of: Data("\r\n".utf8), in: cursor..<body.endIndex),
                      let sizeText = String(decoding: body[cursor..<line.lowerBound], as: UTF8.self).split(separator: ";").first,
                      let size = Int(sizeText, radix: 16),
                      size >= 0, size <= body.endIndex - line.upperBound else {
                    throw SenseFailure(code: "bad_output", message: "fetch received invalid chunk framing.")
                }
                if size == 0 {
                    let trailers = body[line.upperBound...]
                    guard trailers.starts(with: Data("\r\n".utf8)) || trailers.range(of: Data("\r\n\r\n".utf8)) != nil else {
                        throw SenseFailure(code: "bad_output", message: "fetch received incomplete HTTP trailers.")
                    }
                    break
                }
                cursor = line.upperBound
                data.append(body[cursor..<cursor + size]); cursor += size
                guard body.endIndex - cursor >= 2, body[cursor..<cursor + 2] == Data("\r\n".utf8) else {
                    throw SenseFailure(code: "bad_output", message: "fetch received incomplete chunk framing.")
                }
                cursor += 2
            }
        } else if let length = lower["content-length"], Int(length) != data.count {
            throw SenseFailure(code: "bad_output", message: "fetch received an incomplete HTTP body.")
        }
        return try SwiftNativeToolExecution.fetchReply(status: status, headers: lower, data: data)
    }

    private func denied(_ detail: String) -> SenseFailure { SenseFailure(code: "permission_denied", message: detail) }
    private func text(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard case .string(let text)? = args[key], !text.isEmpty else { throw SenseFailure(code: "bad_input", message: "\(key) is required.") }
        return text
    }
    private func port(_ args: [String: JSONValue], zero: Bool) throws -> NWEndpoint.Port {
        guard case .int(let value)? = args["port"], value >= (zero ? 0 : 1), let raw = UInt16(exactly: value),
              let port = NWEndpoint.Port(rawValue: raw) else { throw SenseFailure(code: "bad_input", message: "Pass a valid network port.") }
        return port
    }
    private static func data(_ args: [String: JSONValue]) throws -> Data {
        guard case .string(let base64)? = args["base64"], let data = Data(base64Encoded: base64), data.count <= byteLimit else {
            throw SenseFailure(code: "bad_input", message: "Pass base64 bytes of at most 4 MiB.")
        }
        return data
    }
    private static func loopback(_ host: String) -> Bool {
        host.lowercased() == "localhost" || host == "::1" || host.hasPrefix("127.") || host.hasPrefix("::ffff:127.")
    }

    private func address(_ host: String, publicOnly: Bool = false) throws -> String {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0, let start = first else {
            throw SenseFailure(code: "world_error", message: "Network host could not be resolved.")
        }
        defer { freeaddrinfo(start) }
        var cursor: UnsafeMutablePointer<addrinfo>? = start, addresses: [String] = []
        while let at = cursor {
            var bytes = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(at.pointee.ai_addr, at.pointee.ai_addrlen, &bytes, socklen_t(bytes.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            cursor = at.pointee.ai_next
        }
        guard !publicOnly || addresses.allSatisfy({ !Self.loopback($0) }),
              let chosen = addresses.first, permissions.contains("network")
            || addresses.allSatisfy({ Self.loopback($0) ? permissions.contains("network_localhost") : permissions.contains("network_public") }) else {
            throw denied("The resolved address is outside the declared network reach.")
        }
        return chosen
    }

    private func network(_ operation: String, args: [String: JSONValue]) async throws -> JSONValue {
        switch operation {
        case "network.connect", "network.listen":
            let host = try text(args, "host"), address = try address(host, publicOnly: args["publicOnly"] == .bool(true)), port = try port(args, zero: operation == "network.listen")
            let parameters: NWParameters
            if args["transport"] == .string("udp") { parameters = .udp }
            else if args["tls"] == .bool(true), operation == "network.connect" {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
                parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else { parameters = .tcp }
            let id = UUID().uuidString
            if operation == "network.connect" {
                let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: parameters)
                connections[id] = connection
                try await ready(connection)
                return .object(["id": .string(id)])
            }
            guard permissions.contains("network") || Self.loopback(address) && permissions.contains("network_localhost") else {
                throw denied("Listening requires the declared inbound network reach.")
            }
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
            let listener = try NWListener(using: parameters, on: port)
            let stream = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingOldest(OwnedProgramRunner.actionLimit))
            listeners[id] = (listener, stream.stream, stream.continuation)
            listener.newConnectionHandler = { connection in Task { await self.incoming(connection, listener: id) } }
            try await networkReply(cancel: { listener.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
                listener.stateUpdateHandler = { state in
                    if case .ready = state { done.yield(()); done.finish() }
                    if case .failed(let error) = state { done.finish(throwing: error); stream.continuation.finish(throwing: error) }
                    if case .cancelled = state { done.finish(throwing: CancellationError()); stream.continuation.finish(throwing: CancellationError()) }
                }
                listener.start(queue: self.queue)
            }
            return .object(["id": .string(id), "port": .int(Int64(listener.port?.rawValue ?? port.rawValue))])
        case "network.accept":
            let id = try text(args, "id")
            guard let slot = listeners[id] else { throw denied("This invocation does not own that listener.") }
            let accepted = try await withTaskCancellationHandler {
                var iterator = slot.1.makeAsyncIterator()
                return try await iterator.next()
            } onCancel: { slot.2.finish(throwing: CancellationError()); slot.0.cancel() }
            guard let accepted, let connection = connections[accepted] else { throw CancellationError() }
            try await ready(connection)
            return .object(["id": .string(accepted)])
        case "network.send", "network.receive":
            let id = try text(args, "id")
            guard let connection = connections[id] else { throw denied("This invocation does not own that connection.") }
            if operation == "network.send" {
                let data = try Self.data(args)
                try await networkReply(cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error { done.finish(throwing: error) } else { done.yield(()); done.finish() }
                    })
                }
                return .object(["bytes": .int(Int64(data.count))])
            }
            return try await networkReply(cancel: { connection.cancel() }) { (done: AsyncThrowingStream<JSONValue, Error>.Continuation) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: Self.byteLimit) { data, _, complete, error in
                    if let error { done.finish(throwing: error) }
                    else {
                        done.yield(.object(["base64": .string((data ?? Data()).base64EncodedString()),
                                            "bytes": .int(Int64(data?.count ?? 0)), "eof": .bool(complete)])); done.finish()
                    }
                }
            }
        case "network.close":
            let id = try text(args, "id")
            if let connection = connections.removeValue(forKey: id) { connection.cancel() }
            else if let slot = listeners.removeValue(forKey: id) { slot.0.cancel(); slot.2.finish() }
            else { throw denied("This invocation does not own that network handle.") }
            return .object(["id": .string(id)])
        default: throw SenseFailure(code: "unsupported", message: "Unknown network primitive.")
        }
    }

    private func incoming(_ connection: NWConnection, listener id: String) {
        guard !closed, let slot = listeners[id] else { connection.cancel(); return }
        let key = UUID().uuidString
        connections[key] = connection
        if case .dropped = slot.2.yield(key) { connections.removeValue(forKey: key); connection.cancel() }
    }

    private func ready(_ connection: NWConnection) async throws {
        try await networkReply(cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
            connection.stateUpdateHandler = { state in
                if case .ready = state { done.yield(()); done.finish() }
                if case .failed(let error) = state { done.finish(throwing: error) }
                if case .cancelled = state { done.finish(throwing: CancellationError()) }
            }
            connection.start(queue: self.queue)
        }
    }

    private func networkReply<T: Sendable>(cancel: @escaping @Sendable () -> Void,
                                  start: (AsyncThrowingStream<T, Error>.Continuation) -> Void) async throws -> T {
        let stream = AsyncThrowingStream<T, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        try Task.checkCancellation()
        start(stream.continuation)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var iterator = stream.stream.makeAsyncIterator()
            guard let value = try await iterator.next() else { throw CancellationError() }
            ProviderStreamContext.activity?()
            return value
        } onCancel: { stream.continuation.finish(throwing: CancellationError()); cancel() }
    }

    /// Ends the run's reach; returns the receipts of its watches.
    @discardableResult func close() -> [JSONValue] {
        closed = true
        for connection in connections.values { connection.cancel() }
        for slot in listeners.values { slot.0.cancel(); slot.2.finish() }
        connections.removeAll(); listeners.removeAll()
        endWatch("run_ended")
        return watched
    }

    private func endWatch(_ reason: String) {
        guard let watch else { return }
        watch.end(reason)
        watched.append(watch.summary)
        if let abilityObserver { NotificationCenter.default.removeObserver(abilityObserver) }
        self.watch = nil; abilityObserver = nil
    }

}

extension SwiftNativeToolExecution {
    public nonisolated static func fetchRequest(_ args: [String: JSONValue]) throws -> URLRequest {
        let fields = JSONValue.object(args).stringFields
        guard let raw = fields["url"], let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              args["method"] == nil || fields["method"] != nil else {
            throw SenseFailure(code: "bad_input", message: "fetch requires an http(s) URL without credentials or a fragment, and a string method.")
        }
        let method = fields["method"]?.uppercased() ?? "GET"
        guard !method.isEmpty, method.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw SenseFailure(code: "bad_input", message: "method must be an HTTP method.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let headers = args["headers"] {
            guard case .object(let entries) = headers, entries.count == headers.stringFields.count,
                  entries.keys.allSatisfy({ !["authorization", "proxy-authorization", "cookie", "host", "connection", "content-length", "transfer-encoding"].contains($0.lowercased())
                      && !$0.contains("\r") && !$0.contains("\n") }),
                  headers.stringFields.values.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }) else {
                throw SenseFailure(code: "bad_input", message: "headers must be strings; credentials, Host and HTTP framing are supplied by the app.")
            }
            request.allHTTPHeaderFields = headers.stringFields
        }
        if let body = args["body"] {
            if case .string(let text) = body { request.httpBody = Data(text.utf8) }
            else {
                request.httpBody = try body.serializedData(pretty: false)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        }
        guard (request.httpBody?.count ?? 0) <= 4 * 1024 * 1024, try JSONValue.object(args).serializedData(pretty: false).count <= 4 * 1024 * 1024 else {
            throw SenseFailure(code: "output_limit", message: "fetch input exceeds the 4 MiB primitive limit.")
        }
        return request
    }

    public nonisolated static func fetchReply(status: Int, headers: [String: String], data: Data, credential: String? = nil) throws -> JSONValue {
        func clean(_ text: String) -> String {
            guard let credential, !credential.isEmpty else { return text }
            return text.replacingOccurrences(of: credential, with: "[redacted]")
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw SenseFailure(code: "bad_output", message: "fetch response body must be UTF-8 text.")
        }
        let safe = headers.reduce(into: [String: JSONValue]()) { result, entry in
            if !["set-cookie", "authorization", "proxy-authenticate"].contains(entry.key.lowercased()) {
                result[clean(entry.key.lowercased())] = .string(clean(entry.value))
            }
        }
        let result: JSONValue = .object(["status": .int(Int64(status)), "headers": .object(safe), "body": .string(clean(body))])
        guard try result.serializedData(pretty: false).count <= 4 * 1024 * 1024 else {
            throw SenseFailure(code: "output_limit", message: "fetch response exceeds the 4 MiB primitive limit.")
        }
        return result
    }
}

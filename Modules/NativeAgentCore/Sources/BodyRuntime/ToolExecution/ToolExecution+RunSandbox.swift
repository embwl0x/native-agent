import CoreFoundation
import Darwin
import Dispatch
import Synchronization
import SenseCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import Network
import Security
import ProviderRouting
import CFNetwork
import MacNerves
import CryptoKit
// Blueprint: | `ToolExecution+RunSandbox.swift` | `ToolPrimitiveBroker`, `held`: declared reach; retained transport settlement |

actor ToolPrimitiveBroker {
    static let readOperations = Set(AuthoredToolEffects.primitiveCapabilities.compactMap { $0.value.contains(.safeRead) ? $0.key : nil })
    static let operations = Set(AuthoredToolEffects.primitiveCapabilities.keys.filter { $0.hasPrefix("network.") || $0.hasPrefix("program.") })
        .union(["model.call", "fetch", "screen.watch", MacAXQuery.operation]).union(OwnedProgramRunner.layeredHostPrimitives)
        .union(frameOperations).union(AuthoredToolEffects.handOperations)
    /// Reads inside the run's admitted watch: no admission and no receipt of their own.
    static let frameOperations: Set<String> = ["screen.next", "frame.read"]
    /// Reading or ending a program it started: inside its admitted start, no ledger row of its own. A send is an effect and is recorded as one.
    static let programOperations: Set<String> = ["program.receive", "program.close"]
    static let streamOpenOperations: Set<String> = ["network.websocket.open", "fetch.sse.open"]
    final class StreamRun: Sendable {
        fileprivate let active = Mutex(true)
    }
    static func readOnly(_ operation: String, _ arguments: JSONValue) -> Bool {
        if operation == "model.call" {
            let tools = Parts.fields(arguments)["tools"]
            return tools == nil || tools == .array([])
        }
        return AuthoredToolEffects.primitiveEffect(operation, arguments: arguments).capabilities.contains(.safeRead)
    }
    let permissions: Set<PartReachGrant>
    private let readPaths: [String]
    private let abilityID: String
    private let dataRoot: URL
    /// Held reach outlives individual runs and its arrivals wake the resident ability.
    private let held: AbilityStore?
    private var connections: [String: NWConnection] = [:]
    private var listeners: [String: NWListener] = [:]
    private let queue = DispatchQueue(label: "nativeagent.authored.network")
    /// One ordered buffer owns unread arrivals; retain only one unread connection piece and repeat terminal evidence.
    private var inbox: [String: [Arrival]] = [:]
    private var ended: [String: Arrival] = [:]
    private final class Read {
        let done = ScopedWaiter()
        var result: Result<Arrival, Error>?
    }
    private var readers: [String: (token: Int, read: Read)] = [:]

    private func complete(_ read: Read, _ result: Result<Arrival, Error>) {
        read.result = result
        read.done.resume()
    }
    private var reads = 0, running = 0
    private var pumping: Set<String> = []

    private enum Arrival: Sendable {
        case bytes(Data, stream: String?, eof: Bool), exit(Int32), accepted(String), failed(any Error)
        var ends: Bool {
            switch self {
            case .bytes(_, _, let eof): eof
            case .exit, .failed: true
            case .accepted: false
            }
        }
    }
    private(set) var closed = false
    private var lookups: [UUID: (once: ContinuationOnce<Result<[String], Error>>, fetch: Bool)] = [:]
    /// Admitted requests own their transport and settlement beyond the run's response wait.
    private var fetches: [UUID: Task<Void, Never>] = [:]
    private var fetchConnections: Set<String> = []
    private var runStreams: [String: RunStream] = [:]
    private let streamConnections = Mutex<[String: (run: StreamRun, connection: NWConnection)]?>([:])
    private var streamObserver: (any NSObjectProtocol)?
    private static let maxConnections = 8
    private static let byteLimit = 4 * 1024 * 1024
    /// A run owns one current watch; keep receipts when it ends.
    private var watch: MacScreenWatch?
    private var watched: [JSONValue] = []
    private var abilityObserver: (any NSObjectProtocol)?
    /// All inserted secrets must be redacted from readback, including connection and stream forms.
    private var redactor = SecretRedactor()

    func anatomyRedactor() -> SecretRedactor { redactor }

    func anatomyRedactorIsCurrent(_ revision: Int) -> Bool { !closed && redactor.values.count == revision }

    func checkNotebook(_ value: Data) throws {
        guard redactor.whole(value) == value else {
            throw AbilityStore.notebookSecretFailure
        }
    }
    private var hosts: [String: String] = [:]
    private var streams: [String: SecretStream] = [:]
    private var programs: [String: Program] = [:]

    /// Programs live only while their run or resident owner holds them.
    private final class Program {
        let process: ManagedProcess, input: FileHandle, path: String, identity: String
        let launched: ProcessTreeSnapshot, backlog: Backlog
        /// Keep terminal cause after the resource ends.
        private(set) var ended = false
        /// Program exit must release its pending send.
        var sending: AsyncThrowingStream<Void, Error>.Continuation?
        static let gone = SenseFailure(code: "program_ended", message: "The program ended and takes no more input.", remedy: Repair.terminal(instruction: """
            This handle cannot accept more input. Inspect already returned output and effects before deciding whether new work needs program.start; do \
            not resend the previous input.
            """))
        init(process: ManagedProcess, input: FileHandle, path: String, identity: String, launched: ProcessTreeSnapshot, backlog: Backlog) {
            self.process = process; self.input = input; self.path = path; self.identity = identity
            self.launched = launched; self.backlog = backlog
        }
        /// Terminate the identity-checked launch tree like a shell; detached sessions have independent lifetime.
        func end() {
            ended = true
            ProcessTreeReaper.quiesceAndKill(ProcessTreeReaper.snapshot(rootPID: process.processIdentifier, retaining: launched))
            input.writeabilityHandler = nil
            let failure = process.terminationError.map { SenseFailure(code: "termination_incomplete", message: $0) } ?? Self.gone
            sending?.finish(throwing: failure); sending = nil
            try? input.close()
        }

        /// Bound unread output and terminate overflow; the next read retains its cause.
        final class Backlog: Sendable {
            private let state = Mutex((bytes: 0, over: false))
            /// Stop retaining pieces once the output bound is exceeded.
            func keep(_ count: Int, bound: Int) -> (keep: Bool, crossed: Bool) {
                state.withLock {
                    guard !$0.over else { return (false, false) }
                    $0.bytes += count
                    $0.over = $0.bytes > bound
                    return (!$0.over, $0.over)
                }
            }
            func read(_ count: Int) { state.withLock { $0.bytes -= count } }
        }
    }

    init(permissions: Set<PartReachGrant>, abilityID: String, dataRoot: URL, readPaths: [String], held: AbilityStore? = nil) {
        self.permissions = permissions
        self.readPaths = readPaths
        self.dataRoot = dataRoot
        self.abilityID = abilityID; self.held = held
    }

    func check(_ operation: String, arguments: JSONValue, run: StreamRun, fixtureOwnsStream: Bool = false) throws {
        try Task.checkCancellation()
        guard !closed, Self.operations.contains(operation), case .object(let args) = arguments else {
            if closed { throw CancellationError() }
            throw Self.inputFailure("invalid_primitive", field: "operation/arguments",
                accepted: "operation: \(Self.operations.sorted().joined(separator: ", ")); arguments: a JSON object")
        }
        if ["fetch", "fetch.sse.open", "network.receive", "network.accept", "network.send", "program.receive", "program.send"].contains(operation),
           args["wait"] != nil {
            throw Self.inputFailure("unsupported_wait", field: "wait", accepted: "omitted; cancel an unfinished operation explicitly")
        }
        if let name = Keyring.names(in: arguments).first(where: { !permissions.contains(.secret($0)) }) {
            throw Parts.revisionFailure("undeclared", "Declare reach.capabilities secret:\(name) to use {{secret:\(name)}} in ability \(abilityID).",
                id: abilityID)
        }
        if ["model.call", "fetch", "fetch.sse.open"].contains(operation), args["connector"] != nil {
            throw Self.inputFailure(
                "unsupported_connector_argument",
                field: "connector",
                accepted: "omitted",
                detail: operation == "model.call"
                    ? """
                    model.call takes no connector argument; remove it to use the run's admitted model or an existing \
                    routing surface.
                    """
                    : """
                    fetch takes no connector argument. Use {{secret:<name>}} where the key belongs and declare reach secret:<name>; \
                    an unsaved key is requested once on a card.
                    """)
        }
        if operation == MacAXQuery.operation {
            let query = try MacAXQuery(arguments)
            guard query.declaresApp(permissions) || permissions.contains(.flag(.screenWatch)) else { throw axQueryReachFailure(query) }
        } else if OwnedProgramRunner.layeredHostPrimitives.contains(operation) {
            try checkStream(operation, args: args, run: run, fixtureOwnsStream: fixtureOwnsStream)
        } else if operation.hasPrefix("program.") {
            guard permissions.contains(.flag(.shell)) else {
                throw Parts.revisionFailure("undeclared", "Declare reach.capabilities shell to call \(operation) in ability \(abilityID).", id: abilityID)
            }
            if operation == "program.start" { _ = try text(args, "command") }
        } else if operation.hasPrefix("screen.") || operation.hasPrefix("frame.") || operation.hasPrefix("hand.") {
            let reach: PartReachGrant.StaticFlag = operation.hasPrefix("hand.") ? .hands : .screenWatch
            guard permissions.contains(.flag(reach)) else {
                throw Parts.revisionFailure("undeclared", "Declare reach.capabilities \(reach.rawValue) to call \(operation) in ability \(abilityID).", id: abilityID)
            }
            if operation == "screen.watch" { _ = try MacScreenWatch.Request(args) }
            if operation.hasPrefix("hand."), let refusal = watch?.handRefusal { throw refusal }
        } else if operation == "model.call" || operation == "fetch" {
            // A fetch to this Mac's own loopback (a local agent's endpoint) is reached as localhost is, and its secret may go there as network.send's does.
            let reach: PartReachGrant.StaticFlag
            if operation == "model.call" {
                reach = .model
            } else {
                let url = try Self.destination(args)
                reach = NetworkAddress.loopback(Self.hostName(url)) ? .networkLocalhost : .networkPublic
            }
            try requireReach(reach, operation: operation)
        } else {
            guard !permissions.isDisjoint(with: [.flag(.network), .flag(.networkPublic), .flag(.networkLocalhost)]) else {
                throw denied("\(operation) has no declared network reach.",
                    "Declare network_localhost for loopback, network_public for public outbound connections, or network for inbound and outbound reach.")
            }
            if operation == "network.connect", args["path"] != nil {
                _ = try socketPath(args)
                guard args["host"] == nil, args["port"] == nil, args["tls"] == nil, args["transport"] == nil else {
                    throw Self.inputFailure("invalid_socket_arguments", field: "path", accepted: "{path: string}, without host, port, tls or transport")
                }
            } else if operation == "network.connect" || operation == "network.listen" {
                let local = NetworkAddress.loopback(try text(args, "host"))
                guard permissions.contains(.flag(.network)) || local && permissions.contains(.flag(.networkLocalhost))
                    || operation == "network.connect" && !local && permissions.contains(.flag(.networkPublic)) else {
                    throw denied("\(operation) host is outside the declared reach.", """
                        Declare network_localhost for loopback, network_public for public outbound connections, or network for listening beyond loopback; \
                        keep the reviewed version.
                        """)
                }
                _ = try port(args, zero: operation == "network.listen")
                guard !(args["transport"] == .string("udp") && args["tls"] == .bool(true)) else {
                    throw Self.inputFailure("invalid_tls_transport", field: "tls/transport", accepted: "tls:true over TCP, or transport:udp without tls:true")
                }
            }
        }
    }

    private func axQueryWatch(_ query: MacAXQuery) -> MacScreenWatch? {
        guard permissions.contains(.flag(.screenWatch)), let watch, watch.axQueryActive,
              watch.axQueryBundleID.flatMap(OpenURLClassification.normalizedBundleID) == query.bundleID else { return nil }
        return watch
    }

    private func axQueryReachFailure(_ query: MacAXQuery) -> SenseFailure {
        SenseFailure(code: "undeclared_target", message: """
            Declare app_read:\(query.bundleID) or app_write:\(query.bundleID), or use an admitted, active screen.watch for this app.
            """)
    }

    private func readAXQuery(_ query: MacAXQuery, context: MacOperationContext) async throws -> JSONValue {
        try Task.checkCancellation()
        let watchOnly = !query.declaresApp(permissions)
        let watch = axQueryWatch(query)
        let scope: MacScreenWatch.AXQueryScope?
        if let watch {
            scope = await watch.axQueryScope()
            try Task.checkCancellation()
            guard scope != nil, axQueryWatch(query) === watch else {
                if watchOnly { throw axQueryReachFailure(query) }
                return MacAXQuery.status("withheld", "watch_scope_changed")
            }
        } else {
            if watchOnly { throw axQueryReachFailure(query) }
            scope = nil
        }
        guard !closed else { throw CancellationError() }
        let scrub = redactor
        let result = try await query.read(context: context, watch: scope, watchOnly: watchOnly) { scrub($0) }
        try Task.checkCancellation()
        if let watch, await watch.axQueryScope() != scope {
            return MacAXQuery.status("withheld", "watch_scope_changed")
        }
        guard !closed, !Task.isCancelled else { throw CancellationError() }
        guard axQueryWatch(query) === watch else { return MacAXQuery.status("withheld", "watch_scope_changed") }
        guard redactor.values.count == scrub.values.count else { return MacAXQuery.status("withheld", "redaction_scope_changed") }
        return result
    }

    /// Every primitive must pass its run's gated host.
    func perform(_ operation: String, arguments: JSONValue, run: StreamRun, host: any OwnedProgramToolHost,
                 profile: (any OwnedProgramHostProfile)? = nil, execution: OwnedProgramExecution,
                 openScreenWatch: (@Sendable (MacScreenWatch.Request, Bool) async throws -> MacScreenWatch)?) async throws -> JSONValue {
        try check(operation, arguments: arguments, run: run)
        let args = Parts.fields(arguments)
        if operation == MacAXQuery.operation {
            let query = try MacAXQuery(arguments)
            let context = execution.macOperation(dataRoot: dataRoot)
            do {
                return try await OperationWaitBudget.withDeadline(seconds: 2, budget: context.waitBudget) { budget in
                    var bounded = context
                    bounded.deadline = budget.deadline
                    return try await self.readAXQuery(query, context: bounded)
                }
            } catch is OperationWaitBudget.Exceeded {
                return MacAXQuery.status("withheld", "time_budget", truncated: true)
            }
        }
        if operation == "model.call" {
            if abilityID == DreamPart.id {
                guard let dream = execution.turn?[DreamPart.Key.self] else {
                    throw SenseFailure(code: "dream_needs_night", message: "The dream cycle needs the dream or REM owner's model route.")
                }
                guard NativeAgentSecretRedactor.secretPath(arguments) == nil else {
                    throw SenseFailure(code: "secret_in_input", message: "The dream cycle's model input carries a credential.")
                }
                do { return ToolHost.receipt(try await dream.judge(args), effects: "none") }
                catch let problem as PartCallError {
                    throw SenseFailure(code: problem.code == "bad_dream_policy" ? "validation_failed" : problem.code, message: problem.message)
                }
            }
            if abilityID == MindMemoryJudgment.DigestPart.id {
                guard let digest = execution.turn?[MindMemoryJudgment.DigestPart.Key.self] else {
                    throw SenseFailure(code: "digest_needs_moment", message: "The turn digest needs its recorded moment and Memory route.")
                }
                guard NativeAgentSecretRedactor.secretPath(arguments) == nil else {
                    throw SenseFailure(code: "secret_in_input", message: "The turn digest's model input carries a credential.")
                }
                do { return ToolHost.receipt(try await digest.judge(args), effects: "none") }
                catch let problem as PartCallError {
                    return ToolHost.failure("validation_failed", problem.message, effects: "none", execution: "not_run", status: "failed")
                }
            }
            return try await model(args, host: host, profile: profile, execution: execution)
        }
        if operation != "screen.watch", operation.hasPrefix("screen.") || operation.hasPrefix("frame.") || operation.hasPrefix("hand.") {
            guard let watch else { throw SenseFailure(code: "no_watch", message: "Call screen.watch({app}) before \(operation).") }
            switch operation {
            case "screen.next":
                let timeout: Double? = switch args["timeout"] { case .int(let n)?: Double(n); case .double(let n)?: n; default: nil }
                return try await watch.next(timeout: timeout)
            case "frame.read":
                guard case .int(let generation)? = args["watch"], case .int(let seq)? = args["seq"],
                      case .array(let queries)? = args["queries"] else {
                    throw Self.inputFailure("invalid_frame_read", field: "watch/seq/queries",
                        accepted: "integer watch and seq with an array of queries; call frame.read([...]) on the frame returned by screen.next()")
                }
                let read = try await watch.read(watch: Int(generation), seq: Int(seq), queries: queries)
                let scrub = redactor
                return read.mapStrings { scrub($0) }
            default: return try await watch.hand(String(operation.dropFirst("hand.".count)), args,
                context: execution.macOperation(dataRoot: dataRoot))
            }
        }
        if operation == "screen.watch" {
            guard let open = openScreenWatch else {
                throw SenseFailure(code: "unavailable", message: "screen.watch needs the app door of a conversation or wake run.")
            }
            let opened = try await open(try MacScreenWatch.Request(args), permissions.contains(.flag(.hands)))
            guard !closed else { opened.end("run_ended"); throw CancellationError() }
            endWatch("replaced")
            watch = opened
            // A changed/disabled part cannot keep watching under an earlier admission.
            let id = abilityID
            abilityObserver = NotificationCenter.default.observeSynchronously(for: AbilityStore.DidChange.self) { change in
                if URL(fileURLWithPath: change.path).lastPathComponent == id { opened.end("part_changed") }
            }
            return opened.opened
        }
        do {
            if OwnedProgramRunner.layeredHostPrimitives.contains(operation) {
                let budget = OperationWaitBudget(deadline: execution.deadline)
                guard let limit = try Self.streamTimeout(operation, args) else {
                    return try await stream(operation, args: args, run: run, opening: nil, budget: budget, execution: execution)
                }
                let opening = Self.streamOpenOperations.contains(operation) ? UUID().uuidString : nil
                do {
                    return try await OperationWaitBudget.withDeadline(seconds: limit, budget: budget) { budget in
                        try await self.stream(operation, args: args, run: run, opening: opening, budget: budget, execution: execution)
                    }
                } catch {
                    if let opening { endStream(opening) }
                    else if error is OperationWaitBudget.Exceeded, let id = args["id"]?.stringValue, runStreams[id]?.run === run { endStream(id) }
                    throw error
                }
            }
            if operation == "fetch" {
                let target = try Self.destination(args), host = Self.hostName(target).lowercased()
                let destination = Keyring.Destination.host(host), keys = ["url", "headers", "body", "multipart"]
                func send(_ given: [String: JSONValue]) async throws -> JSONValue {
                    try await self.sendFetch(given, to: target, execution: execution)
                }
                let given = try await inserting(args, keys, to: destination)
                return try await send(given)
            }
            if operation.hasPrefix("program.") { return try await program(operation, args: args, host: host, execution: execution) }
            if operation == "network.receive" {
                return Self.networkReadback(try await receive(args, onActivity: execution.onActivity))
            }
            var given = args
            if operation == "network.send", given["text"] != nil {
                if !Keyring.names(in: .object(args)).isEmpty {
                    guard let host = hosts[try text(args, "id")] else {
                        throw denied(
                            "A secret needs an established TLS connection or admitted TCP loopback. Open one with network.connect before sending it.",
                                "Use network.connect with tls:true or an admitted loopback TCP host; send only on the id it returns.")
                    }
                    given = try await inserting(args, ["text"], to: .host(host))
                }
                given["base64"] = .string(try Self.outgoing(given).base64EncodedString())
            }
            let result = try await network(operation, args: given, onActivity: execution.onActivity)
            guard operation == "network.connect", case .string(let id)? = Parts.fields(result)["id"] else { return result }
            // A secret goes out only on a connection that established TLS, as the transport reports it (or to this Mac by host); udp carries none.
            if let host = args["host"]?.stringValue, args["transport"] != .string("udp"),
               connections[id]?.metadata(definition: NWProtocolTLS.definition) != nil || NetworkAddress.loopback(host) { hosts[id] = host.lowercased() }
            pump(id)
            return result
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            // What the agent reads of a failure never carries a value the run inserted.
            throw contextualFailure(error, operation: operation)
        }
    }

    /// Resolve the host with two secret stand-ins: secrets may neither select their own destination nor leave unencrypted.
    private static func destination(_ args: [String: JSONValue], websocket: Bool = false) throws -> URL {
        if !websocket { try Parts.checkFetchSecretFields(args) }
        let fixedOrigin = "a fixed scheme, host and port; place {{secret:<name>}} only in the path or query"
        if websocket, let raw = args["url"]?.stringValue, let separator = raw.range(of: "://") {
            let scheme = raw[..<separator.lowerBound]
            let authority = raw[separator.upperBound...].prefix { !"/?#".contains($0) }
            let hostPort = authority.lastIndex(of: "@").map { authority[authority.index(after: $0)...] } ?? authority
            guard Keyring.names(in: .string("\(scheme)://\(hostPort)")).isEmpty else {
                throw inputFailure("secret_cannot_alter_host", field: "url", accepted: fixedOrigin)
            }
        }
        let names = Keyring.names(in: .object(args))
        let urls = try ["secret", "other"].map { stand in
            let values = Dictionary(uniqueKeysWithValues: names.map { ($0, stand) })
            if websocket {
                var given = args
                for key in ["url", "headers"] { given[key] = args[key]?.mapStrings { insertingSecrets($0, values, url: key == "url") } }
                return try websocketRequest(given).url!
            }
            return try Parts.fetchRequest(args.mapValues { $0.mapStrings { insertingSecrets($0, values, url: true) } }).url!
        }
        let url = urls[0]
        guard sameOrigin(url, urls[1]) else {
            throw Self.inputFailure(websocket ? "secret_cannot_alter_host" : "secret_in_url_host", field: "url", accepted: fixedOrigin)
        }
        guard names.isEmpty || url.scheme?.lowercased() == "https" || NetworkAddress.loopback(hostName(url)) else {
            let secure = websocket ? "wss" : "https", local = websocket ? "ws" : "http"
            throw Self.inputFailure(websocket ? "secret_requires_tls" : "secret_transport_required", field: "url",
                accepted: "\(secure), or \(local) to admitted loopback on this Mac",
                detail: "Use an \(secure) URL for a secret, or \(local) to admitted loopback on this Mac.")
        }
        return url
    }

    static func literalNetworkReach(_ url: String, websocket: Bool) throws -> PartReachGrant.StaticFlag? {
        let host = hostName(try destination(["url": .string(url)], websocket: websocket))
        if NetworkAddress.loopback(host) { return .networkLocalhost }
        return NetworkAddress.privateNetwork(host) ? nil : .networkPublic
    }

    private func requireReach(_ reach: PartReachGrant.StaticFlag, operation: String, fullNetwork: Bool = false) throws {
        guard permissions.contains(.flag(reach)) || fullNetwork && permissions.contains(.flag(.network)) else {
            throw Parts.revisionFailure("undeclared", "Declare reach.capabilities \(reach.rawValue) to call \(operation) in ability \(abilityID).", id: abilityID)
        }
    }

    /// Insert secrets only toward their granted destination and retain their values for redaction.
    private func inserting(_ args: [String: JSONValue], _ keys: [String], to destination: Keyring.Destination) async throws -> [String: JSONValue] {
        let names = Keyring.names(in: .object(args.filter { keys.contains($0.key) }))
        guard !names.isEmpty else { return args }
        let values = try await Keyring.values(names, to: destination).values
        redactor.add(values)
        var given = args
        for key in keys { given[key] = given[key]?.mapStrings { insertingSecrets($0, values, url: key == "url") } }
        return given
    }

    /// Connections and programs must expose the same output shape.
    private func receive(_ args: [String: JSONValue], onActivity: (@Sendable () -> Void)?) async throws -> JSONValue {
        let id = try text(args, "id")
        guard connections[id] != nil else { throw denied("This ability does not own that connection.",
            "Use an id returned to this ability by network.connect or network.accept; a closed or replaced handle cannot be reused.") }
        while true {
            let arrival = try await next(id, onActivity: onActivity)
            switch arrival {
            case .bytes(let data, _, let end):
                if var piece = piece(id, data, end: end) { piece["eof"] = .bool(end); return .object(piece) }
                if end { return .object(["text": .string(""), "eof": .bool(true)]) }
            case .failed(let error): throw error
            default: throw CancellationError()
            }
        }
    }

    /// Expose UTF-8 as text and other bytes as base64; no available output remains nil.
    private func piece(_ key: String, _ data: Data, end: Bool) -> [String: JSONValue]? {
        let data = streams[key, default: SecretStream()].characters(data, end: end, redactor)
        if data.isEmpty { return nil }
        if let text = String(data: data, encoding: .utf8) { return ["text": .string(text)] }
        return ["base64": .string(data.base64EncodedString()), "binary": .bool(true)]
    }

    /// Program launch shares shell access, sandbox and working-folder checks. Use login PATH plus explicit env, never the app environment; secrets require
    /// executable-bound grants.
    private func program(_ operation: String, args: [String: JSONValue], host: any OwnedProgramToolHost,
        execution: OwnedProgramExecution) async throws -> JSONValue {
        let onActivity = execution.onActivity
        if operation == "program.start" {
            let command = try text(args, "command")
            guard let path = AgentHostCommandLines.resolveCommand(command) else {
                throw SenseFailure(code: "program_not_found", message: """
                    \(command) is not an executable path or a program on the login PATH. Set program.start command to the installed executable's absolute \
                    path, or install the required program first.
                    """)
            }
            // Record executable identity at launch so secret grants cannot follow a changed path.
            guard let identity = AgentHostCommandLines.identity(ofExecutable: path) else {
                throw SenseFailure(code: "program_unreadable", message: """
                    Executable \(path) could not be read. Inspect that file's existence and permissions; repair them or select the intended installed \
                    executable in program.start command.
                    """)
            }
            let given = try await inserting(args, ["args", "env"], to: .program(path: path, identity: identity))
            guard case .array(let rows) = given["args"] ?? .array([]), case .object(let env) = given["env"] ?? .object([:]),
                  JSONValue.stringArray(.array(rows)).count == rows.count, JSONValue.object(env).stringFields.count == env.count else {
                throw Self.inputFailure("invalid_program_arguments", field: "args/env", accepted: "args: [string], env: {name: string}")
            }
            var launching: [String: JSONValue] = ["executable": .string(path), "args": .array(rows)]
            launching["cwd"] = args["cwd"]
            let launch = Parts.fields(try await host.performReach("program.launch", arguments: .object(launching), execution: execution))
            guard let executable = launch["executable"]?.stringValue, let cwd = launch["cwd"]?.stringValue else {
                throw SenseFailure(code: "program_launch_plan_missing", message: """
                    program.launch returned no executable or cwd for \(path). Inspect the shell admission failure; repair that launch plan before \
                    starting the program.
                    """)
            }
            var environment = AgentHostCommandLines.scrubbedEnvironment().merging(JSONValue.object(env).stringFields) { $1 }
            if let prefix = launch["path_prefix"]?.stringValue { environment["PATH"] = prefix + ":" + (environment["PATH"] ?? "/usr/bin:/bin") }
            // Cancellation or closure during waits must prevent spawn.
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            // Recheck identity after waits so a changed executable cannot start under the recorded grant.
            guard AgentHostCommandLines.identity(ofExecutable: path) == identity else {
                throw SenseFailure(code: "program_changed", message: """
                    \(path) changed before launch; this program did not start. Inspect the executable now at that path before deciding whether to start \
                    it.
                    """)
            }
            let process = ManagedProcess(), input = Pipe(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = JSONValue.stringArray(launch["arguments"])
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            // An exited child turns writes into errors, never app signals; non-reading children must not block the broker.
            let writing = input.fileHandleForWriting.fileDescriptor
            _ = fcntl(writing, F_SETNOSIGPIPE, 1)
            _ = fcntl(writing, F_SETFL, fcntl(writing, F_GETFL) | O_NONBLOCK)
            let arrivals = AsyncStream<Arrival>.makeStream(), backlog = Program.Backlog()
            let bound = Self.byteLimit
            func kept(_ stream: String) -> @Sendable (Data) -> Void {
                { data in
                    let kept = backlog.keep(data.count, bound: bound)
                    if kept.keep { arrivals.continuation.yield(.bytes(data, stream: stream, eof: false)) }
                    else if kept.crossed {
                        arrivals.continuation.yield(.failed(SenseFailure(code: "output_limit",
                            message: "The program wrote more than 4 MiB that was not read yet, so it was ended. "
                            + "Read its output as it comes (program.receive), or have it write less.")))
                    }
                }
            }
            let out = try ProcessPipeDrain(handle: output.fileHandleForReading, onData: kept("stdout"))
            let err = try ProcessPipeDrain(handle: errors.fileHandleForReading, onData: kept("stderr"))
            let repairRoot = dataRoot, partID = abilityID
            process.terminationHandler = { process in
                // Keep produced output without waiting for EOF held by a background descendant.
                out.stopAndWait(); err.stopAndWait()
                // Only complete process termination settles the operation; a PID is evidence alone.
                let operation = "part.program.termination:" + partID
                if let failure = process.terminationError {
                    arrivals.continuation.yield(.failed(SenseFailure(code: "termination_incomplete", message: failure)))
                    RepairOwed.owe(repairRoot, id: UUID().uuidString.lowercased(), kind: .act,
                        operation: operation, owner: "Part " + partID + " program",
                        words: "Process group " + String(process.processIdentifier) + ": " + failure,
                        lever: "Reconcile this program's existing effects and repair its retained process group before repeating the part.")
                } else {
                    RepairOwed.settle(repairRoot, operation: operation, evidence: .init(source: "part.program", id: String(process.processIdentifier)))
                }
                arrivals.continuation.yield(.exit(process.terminationStatus)); arrivals.continuation.finish()
            }
            do { try process.run() } catch { out.stop(); err.stop(); throw error }
            let launched = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
            let id = UUID().uuidString
            programs[id] = Program(process: process, input: input.fileHandleForWriting, path: path, identity: identity, launched: launched, backlog: backlog)
            // Output and exit must enter the shared buffer in order.
            Task.detached { for await arrival in arrivals.stream { await self.arrive(id, arrival) } }
            return .object(["id": .string(id), "pid": .int(Int64(process.processIdentifier))])
        }
        let id = try text(args, "id")
        guard let program = programs[id] else { throw denied("This ability does not own that program.",
            "Use the id returned to this ability by program.start; a closed or replaced program cannot be reused.") }
        // Recheck shell authority on every interaction so lost permission ends the program.
        do { _ = try await host.performReach("program.access", arguments: .object([:]), execution: execution) }
        catch { endProgram(id); throw error }
        // A receive waits on the program: it is what the call waits on while the receive lasts.
        let watched = operation == "program.receive" ? execution.turn?.enclosingCall.flatMap { watch in
            program.process.callLife(what: "the program \(URL(fileURLWithPath: program.path).lastPathComponent)").map { (watch, watch.attach($0)) }
        } : nil
        defer { if case let (watch, id)? = watched { watch.detach(id) } }
        switch operation {
        case "program.send":
            let data = try Self.outgoing(try await inserting(args, ["text"], to: .program(path: program.path, identity: program.identity)))
            try await write(data, to: id, onActivity: onActivity)
            return .object(["bytes": .int(Int64(data.count))])
        case "program.receive":
            while true {
                let arrival = try await next(id, onActivity: onActivity)
                switch arrival {
                case .bytes(let data, let stream?, _):
                    program.backlog.read(data.count)
                    if var piece = piece(id + stream, data, end: false) {
                        piece["stream"] = .string(stream); piece["eof"] = .bool(false)
                        return .object(piece)
                    }
                case .exit(let status):
                    // Flush held character/secret prefixes before terminal evidence; terminal reads remain repeatable.
                    for stream in ["stdout", "stderr"] {
                        if var piece = piece(id + stream, Data(), end: true) {
                            inbox[id, default: []].insert(.exit(status), at: 0)
                            piece["stream"] = .string(stream); piece["eof"] = .bool(false)
                            return .object(piece)
                        }
                    }
                    return .object(["text": .string(""), "eof": .bool(true), "exit_code": .int(Int64(status))])
                case .failed(let error): endProgram(id); throw error
                default: throw CancellationError()
                }
            }
        default:
            endProgram(id)
            let process = program.process
            await Task.detached { process.waitForSettlement() }.value
            if let failure = process.terminationError { throw SenseFailure(code: "termination_incomplete", message: failure) }
            return .object(["id": .string(id)])
        }
    }

    /// Exited programs cannot accept input.
    private func write(_ data: Data, to id: String, onActivity: (@Sendable () -> Void)?) async throws {
        guard let program = programs[id], !program.ended else { throw Program.gone }
        let input = program.input
        try await networkReply(onActivity: onActivity, cancel: { input.writeabilityHandler = nil }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
            program.sending = done
            nonisolated(unsafe) var rest = data[...]
            input.writeabilityHandler = { handle in
                let wrote = unsafe rest.withUnsafeBytes { unsafe Darwin.write(handle.fileDescriptor, $0.baseAddress, $0.count) }, failure = errno
                if wrote < 0, failure != EAGAIN, failure != EINTR {
                    handle.writeabilityHandler = nil
                    return done.finish(throwing: POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO))
                }
                unsafe rest = rest.dropFirst(max(wrote, 0))
                if unsafe rest.isEmpty { handle.writeabilityHandler = nil; done.yield(()); done.finish() }
            }
        }
    }

    private func endProgram(_ id: String) {
        programs.removeValue(forKey: id)?.end()
        forget(id)
    }

    /// Bound send input to 4 MiB whether text or base64.
    private static func outgoing(_ args: [String: JSONValue]) throws -> Data {
        guard args["text"] != nil else { return try data(args) }
        guard case .string(let text)? = args["text"], !text.isEmpty, text.utf8.count <= byteLimit else {
            throw Self.inputFailure("invalid_send_text", field: "text", accepted: "a nonempty UTF-8 string of at most 4 MiB; omit text to send base64 bytes")
        }
        return Data(text.utf8)
    }

    private func model(_ args: [String: JSONValue], host: any OwnedProgramToolHost, profile: (any OwnedProgramHostProfile)?,
        execution: OwnedProgramExecution) async throws -> JSONValue {
        // Model primitives own their envelope: both returned data and errors retain the effects of the nested tools, including schema failures.
        var effects = "none"
        do {
        let purpose = try text(args, "purpose").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !purpose.isEmpty else { throw Self.inputFailure("missing_model_purpose", field: "purpose",
            accepted: "a nonempty string describing why this model call is needed") }
        // Tool thinking admits its requested surface through the canonical owner. It must not require an unrelated Chat pick first.
        if args["tools"] == nil, args["surface"] == nil,
           execution.turn?.client == nil || execution.turn?.admission == nil {
            var admitted = execution
            admitted.turn = try await host.admitModel(turn: execution.turn)
            guard admitted.turn?.client != nil, admitted.turn?.admission != nil else {
                throw SenseFailure(code: "unavailable", message: "The part host did not admit a model and client for model.call.")
            }
            return try await self.model(args, host: host, profile: profile, execution: admitted)
        }
        var messages: [LLMMessage]
        if args["prompt"] != nil, args["messages"] == nil { messages = [.user(try text(args, "prompt"))] }
        else if args["prompt"] == nil, case .array(let rows)? = args["messages"], !rows.isEmpty {
            messages = try rows.map { row in
                let fields = Parts.fields(row)
                guard let role = LLMMessage.Role(rawValue: try text(fields, "role")) else {
                    throw Self.inputFailure("invalid_model_message", field: "messages", accepted: "[{role: user|assistant|system, content: string}]")
                }
                return LLMMessage(role: role, content: [.text(try text(fields, "content"))])
            }
        } else { throw Self.inputFailure("invalid_model_input", field: "prompt/messages",
            accepted: "a string prompt or a nonempty messages array, exclusively") }
        if let schema = args["schema"] {
            messages.append(.user(try completionPolicy("authored-thought", arguments: [
                String(decoding: try schema.serializedData(pretty: false), as: UTF8.self)])))
        }
        let signal = Parts.fields(execution.input ?? .null)["signal"]
        let suffix = if case .string(let signal)? = signal { [signal] } else { [String]() }
        let auditPurpose = (["ability", abilityID, purpose] + suffix).joined(separator: ":")
        let toolNames = try Parts.declaredStrings(args["tools"], name: "model.call tools")
        let surface = args["surface"]?.stringValue
        if args["surface"] != nil, surface?.isEmpty != false {
            throw Self.inputFailure("invalid_model_surface", field: "surface", accepted: "a nonempty existing model-routing surface")
        }
        if let surface, !MODEL_SURFACES.contains(canonicalRoutingSurface(surface)) {
            throw Self.inputFailure("unknown_model_surface", field: "surface", accepted: MODEL_SURFACES.sorted().joined(separator: ", "))
        }
        let (reply, cut) = try await { () async throws -> (String, LLMToolBoundaryReason?) in
            if args["tools"] != nil || args["surface"] != nil {
                guard let profile else {
                    throw SenseFailure(code: "unavailable", message: "model.call with tools or a surface requires the part's restricted host.")
                }
                let thought = await host.think(messages: messages, tools: toolNames, surface: surface, host: profile, execution: execution,
                    purpose: auditPurpose)
                effects = thought.effects
                return (try thought.output.get(), nil as LLMToolBoundaryReason?)
            }
            guard let client = execution.turn?.client, let model = execution.turn?.admission?.model else {
                throw SenseFailure(code: "unavailable", message: "model.call needs the part run's admitted model.")
            }
            var call = LLMCall(turn: execution.turn, surface: execution.surface, purpose: auditPurpose)
            call.preview = execution.preview
            return try await { () async throws -> (String, LLMToolBoundaryReason?) in
                var reply = ""
                var cut: LLMToolBoundaryReason?
                for try await event in client.streamMessages(messages: messages, system: purpose, model: model,
                    tools: nil, call: call) {
                    switch event {
                    case .textDelta(let text): reply += text
                    case .toolBoundary(let reason): cut = cut ?? reason
                    default: break
                    }
                }
                return (reply, cut)
            }()
        }()
        // A stream cut retains incomplete evidence; partial output cannot become an answer.
        if let cut {
            throw SenseFailure(code: "incomplete", message: "model.call stopped early (\(cut.rawValue)) after \(reply.count) characters; "
                + "the partial reply is not returned as an answer. Ask for less, or split the request.")
        }
        guard let schema = args["schema"] else { return ToolHost.receipt(.string(reply), effects: effects) }
        let value = try JSONValue.parse(Data(reply.utf8))
        try value.validate(schema: schema)
        return ToolHost.receipt(value, effects: effects)
        } catch {
            var failure = Parts.fields(ToolHost.failure(Task.isCancelled || error is CancellationError ? CancellationError() : contextualFailure(error,
                operation: "model.call"), effects: effects, execution: "attempted"))
            // A typed error describes its own effects; the thought also owns everything its nested tools already did or left unconfirmed.
            let reported = failure["effects"]
            failure["effects"] = .string(["unknown", "partial", "occurred"].first {
                effects == $0 || reported == .string($0)
            } ?? "none")
            return .object(failure)
        }
    }

    /// The admitted request owns transport and durable settlement through completion or cancellation.
    private func sendFetch(_ args: [String: JSONValue], to destination: URL, execution: OwnedProgramExecution) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let token = UUID(), reply = ContinuationOnce<Result<JSONValue, Error>>()
        let id = "fetch:" + token.uuidString.lowercased()
        let keepsRecord = !["GET", "HEAD"].contains((args["method"]?.stringValue ?? "GET").uppercased())
            || args["body_base64"] != nil || args["multipart"] != nil
        if keepsRecord { beginFetchRecord(id, execution: execution) }
        let transport = Task.detached {
            let outcome: Result<JSONValue, Error>
            do { outcome = .success(try await self.fetch(args, to: destination, onActivity: execution.onActivity)) }
            catch { outcome = .failure(error) }
            let settled = await settle { await self.settleFetch(outcome, id: id, keepsRecord: keepsRecord) }
            reply.resume(settled)
            await self.finishedFetch(token)
        }
        fetches[token] = transport
        // Stop ends her wait, never the admitted request (STOP.md): the request runs to its own end, with no time limit, and settles its receipt.
        return try await reply.wait(cancellingWith: .failure(CancellationError())).get()
    }

    private func finishedFetch(_ token: UUID) { fetches[token] = nil }

    private func beginFetchRecord(_ id: String, execution: OwnedProgramExecution) {
        let cause = execution.turn.map { [$0.id] } ?? [], part = abilityID
        ExperienceStore.record(dataRoot, id) { store in
            try await store.begin(Experience(id: id, kind: .act, cause: cause,
                face: .init(words: "Fetch for ability \(part) is awaiting its transport outcome.", artifacts: []),
                owes: ["finish": .init(to: "self")],
                claims: RepairDebt(owner: "ability " + part, operation: id).claims))
        }
    }

    private func settleFetch(_ outcome: Result<JSONValue, Error>, id: String, keepsRecord: Bool) async -> Result<JSONValue, Error> {
        guard keepsRecord else { return outcome.mapError { contextualFailure($0, operation: "fetch") } }
        let result: Result<JSONValue, Error>
        let receipt: JSONValue
        let status: String
        switch outcome {
        case .success(let value):
            result = .success(value); receipt = ToolHost.receipt(value, effects: "unknown"); status = "response_received"
        case .failure(let error):
            let failure = contextualFailure(error, operation: "fetch")
            result = .failure(failure)
            receipt = ToolHost.failure(failure, effects: "unknown", execution: "attempted")
            status = "failed"
        }
        do {
            let file = dataRoot.appendingPathComponent("ability_fetches/" + String(id.dropFirst("fetch:".count)) + ".json")
            try SwiftNativePersistenceCore.writeDataAtomicDurable(try receipt.serializedData(pretty: false), to: file)
            let evidence = Experience.Ref(source: "file", id: file.path)
            let words = """
                Fetch \(id) for ability \(abilityID): \(status). Its receipt is at \(file.path); inspect service state before repeating a modifying \
                request.
                """
            let changes: [ExperienceStore.Change] = [
                .evidence(evidence), .face(.init(words: words, artifacts: [evidence])),
                .outcome(.init(domain: "fetch", status: status, effects: .unknown)),
                .obligation(key: "finish", phase: .accepted, evidence: evidence)
            ]
            await ExperienceStore.record(dataRoot, id) { store in try await store.append(changes, to: id) }.value
            return result
        } catch {
            let words = redactor(error.localizedDescription)
            await RepairOwed.owe(dataRoot, id: UUID().uuidString.lowercased(), kind: .act,
                operation: id, owner: "ability " + abilityID, words: "Fetch settlement \(id) could not be saved: \(words)",
                lever: "Repair experience persistence and reconcile the existing service operation before another request.").value
            return .failure(SenseFailure(code: "fetch_settlement_failed",
                message: """
                    Fetch \(id) reached its transport outcome but its receipt could not be saved: \(words). Inspect service state \
                    before another request.
                    """))
        }
    }

    /// `destination` is the host its grant was checked for: the request with its secrets inserted goes there or nowhere.
    private func fetch(_ args: [String: JSONValue], to destination: URL, onActivity: (@Sendable () -> Void)?) async throws -> JSONValue {
        let request = try Parts.fetchRequest(args)
        let url = request.url!, host = Self.hostName(url), tls = url.scheme?.lowercased() == "https"
        guard Self.sameOrigin(destination, url) else { throw denied("With its secrets in, this fetch no longer goes to \(Self.hostName(destination)); nothing was sent.",
            "Keep the destination host fixed; put secret placeholders in the URL path, query, headers or body.") }
        let connected = try await network("network.connect", args: ["host": .string(host),
            "port": .int(Int64(url.port ?? (tls ? 443 : 80))), "tls": .bool(tls), "publicOnly": .bool(!NetworkAddress.loopback(host))], fetch: true,
                onActivity: onActivity)
        let id = try text(Parts.fields(connected), "id")
        defer { connections.removeValue(forKey: id)?.cancel(); fetchConnections.remove(id) }
        guard let connection = connections[id] else { throw CancellationError() }
        let newBody = args["body_base64"] != nil || args["multipart"] != nil
        try await sendHTTP(request, to: connection, newBody: newBody, onActivity: onActivity)
        if args["response_encoding"] == .string("base64") {
            return try await readBinaryResponse(connection, method: request.httpMethod, onActivity: onActivity)
        }
        let received = try await readHTTP(connection, onActivity: onActivity)
        return try fetchResponse(received, method: request.httpMethod)
    }

    private func sendHTTP(_ request: URLRequest, to connection: NWConnection, newBody: Bool = false,
                          onActivity: (@Sendable () -> Void)?) async throws {
        guard let method = request.httpMethod, let url = request.url else {
            throw SenseFailure(code: "http_method_missing", message: "The fetch request has no HTTP method.")
        }
        let host = Self.hostName(url)
        let message = unsafe CFHTTPMessageCreateRequest(nil, method as CFString, url as CFURL, kCFHTTPVersion1_1).takeRetainedValue()
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            CFHTTPMessageSetHeaderFieldValue(message, key as CFString, value as CFString)
        }
        let named = host.contains(":") ? "[\(host)]" : host
        let hostField = url.port.map { "\(named):\($0)" } ?? named
        CFHTTPMessageSetHeaderFieldValue(message, "Host" as CFString, hostField as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Connection" as CFString, "close" as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Accept-Encoding" as CFString, "identity" as CFString)
        if let body = request.httpBody {
            CFHTTPMessageSetBody(message, body as CFData)
            CFHTTPMessageSetHeaderFieldValue(message, "Content-Length" as CFString, String(body.count) as CFString)
        }
        guard let wire = unsafe CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data? else {
            throw SenseFailure(code: "http_request_encoding",
                message: "fetch could not encode this HTTP request. Correct its URL, method, headers and body in the fetch call.")
        }
        guard newBody || wire.count <= Self.byteLimit else { throw Self.sendLimitFailure }
        try await sendBytes(wire, to: connection, onActivity: onActivity)
    }

    private func readHTTP(_ connection: NWConnection, onActivity: (@Sendable () -> Void)?) async throws -> Data {
        var received = Data()
        while true {
            guard case .bytes(let chunk, _, let eof) = try await receive(connection, onActivity: onActivity) else { throw CancellationError() }
            guard received.count + chunk.count <= Self.byteLimit else {
                throw SenseFailure(code: "output_limit",
                    message: "fetch response exceeds 4 MiB. Request a smaller page or range; inspect service state before another modifying request.")
            }
            received.append(chunk)
            if eof { break }
        }
        return received
    }

    private func fetchResponse(_ bytes: Data, method: String?) throws -> JSONValue {
        var received = bytes
        guard !received.isEmpty else { throw SenseFailure(code: "http_response_empty",
            message: "fetch received no HTTP response. Check that the endpoint serves HTTP and inspect service state before another request.") }
        var response = unsafe CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
        while true {
            let parsed = unsafe received.withUnsafeBytes { bytes in
                unsafe CFHTTPMessageAppendBytes(response, bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count)
            }
            guard parsed, CFHTTPMessageIsHeaderComplete(response) else {
                throw SenseFailure(code: "http_response_incomplete", message: """
                    fetch received an incomplete HTTP response. Repair the endpoint's HTTP framing or premature close; inspect service state before \
                    another request.
                    """)
            }
            if CFHTTPMessageGetResponseStatusCode(response) >= 200 { break }
            guard CFHTTPMessageGetResponseStatusCode(response) != 101,
                  let rest = unsafe CFHTTPMessageCopyBody(response)?.takeRetainedValue() as Data?, !rest.isEmpty else {
                throw SenseFailure(code: "http_upgrade_unsupported", message: """
                    fetch received no final HTTP response or a protocol upgrade. Use a final HTTP endpoint, or implement the upgraded protocol with \
                    network primitives.
                    """)
            }
            received = rest; response = unsafe CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
        }
        let headers = unsafe CFHTTPMessageCopyAllHeaderFields(response)?.takeRetainedValue() as? [String: String] ?? [:]
        let lower = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $0 + ", " + $1 })
        let status = CFHTTPMessageGetResponseStatusCode(response)
        let body = unsafe CFHTTPMessageCopyBody(response)?.takeRetainedValue() as Data? ?? Data()
        var data = body
        if method == "HEAD" || status == 204 || status == 304 { data = Data() }
        else if lower["transfer-encoding"]?.lowercased() == "chunked" {
            data = Data(); var cursor = body.startIndex
            while true {
                guard let line = body.range(of: Data("\r\n".utf8), in: cursor..<body.endIndex),
                      let sizeText = String(decoding: body[cursor..<line.lowerBound], as: UTF8.self).split(separator: ";").first,
                      let size = Int(sizeText, radix: 16),
                      size >= 0, size <= body.endIndex - line.upperBound else {
                    throw SenseFailure(code: "http_chunk_invalid", message: """
                        fetch received invalid chunk framing. Repair the service's chunk sizes and CRLF framing; inspect service state before another \
                        request.
                        """)
                }
                if size == 0 {
                    let trailers = body[line.upperBound...]
                    guard trailers.starts(with: Data("\r\n".utf8)) || trailers.range(of: Data("\r\n\r\n".utf8)) != nil else {
                        throw SenseFailure(code: "http_trailers_incomplete", message: """
                            fetch received incomplete HTTP trailers. Repair the service's trailer terminator; inspect service state before another \
                            request.
                            """)
                    }
                    break
                }
                cursor = line.upperBound
                data.append(body[cursor..<cursor + size]); cursor += size
                guard body.endIndex - cursor >= 2, body[cursor..<cursor + 2] == Data("\r\n".utf8) else {
                    throw SenseFailure(code: "http_chunk_incomplete", message: """
                        fetch received incomplete chunk framing. Repair the service's chunk lengths and premature close; inspect service state before \
                        another request.
                        """)
                }
                cursor += 2
            }
        } else if let length = lower["content-length"], Int(length) != data.count {
            throw SenseFailure(code: "http_body_length_mismatch", message: """
                fetch body length does not match Content-Length. Repair the service's body length or framing; inspect service state before another \
                request.
                """)
        }
        // Header names too, in any case: a service can echo a value back as one.
        return try Parts.fetchReply(status: status, headers: lower, data: data, name: { redactor.name($0) }) { redactor($0) }
    }

    private static func networkReadback(_ result: JSONValue) -> JSONValue {
        guard case .object(var fields) = result else { return result }
        fields["data_trust"] = .string("untrusted_network")
        return .object(fields)
    }

    private func denied(_ detail: String, _ fix: String, code: String = "permission_denied") -> SenseFailure {
        SenseFailure(code: code, message: detail, remedy: Repair.remedy(owner: "ability \(abilityID)",
            nextCall: Parts.readCall(abilityID), tap: nil, instruction: fix
                + " Read this ability before revising its code or reach with ability.save and keeping the reviewed version."))
    }
    static func inputFailure(_ code: String, field: String, accepted: String, detail: String? = nil) -> ToolFailureError {
        ToolFailureError(detail ?? "\(field) must be \(accepted).", argumentPath: field, accepted: accepted, effects: .none,
            code: code, status: .refused, instruction: "Correct \(field) in this primitive call to match accepted.", recovery: .correctArguments)
    }

    private func contextualFailure(_ error: Error, operation: String) -> Error {
        if let owned = error as? ToolFailureError {
            return ToolFailureError(redactor(owned.message), argumentPath: owned.argumentPath.map { redactor($0) }, accepted: owned.accepted.map { redactor(
                $0) }, effects: owned.effects,
                owner: owned.owner.map { redactor($0) }, nextCall: owned.nextCall.map { redactor($0) }, tap: owned.tap.map { redactor($0) },
                    personDecides: owned.personDecides,
                code: owned.code, status: owned.status, instruction: owned.instruction.map { redactor($0) }, recovery: owned.recovery)
        }
        let transport = error is URLError || error is NWError
        let code = (error as? Keyring.Refusal)?.code ?? (transport ? "network_transport_failed"
            : operation.hasPrefix("program.") ? "program_io_failed" : "primitive_execution_failed")
        var failure = (error as? SenseFailure) ?? SenseFailure(code: code, message: error.localizedDescription)
        failure.message = redactor(failure.message)
        if let remedy = failure.remedy { failure.remedy = remedy.mapStrings { redactor($0) } }
        else {
            let fix = transport ? "Check the target host, port, service and network access. "
                : operation.hasPrefix("program.") ? "Inspect the program's command, retained output and exit before further input. "
                    : "Apply the correction named in the failure. "
            failure.remedy = Repair.reconcile(instruction: fix + """
                Read ability \(abilityID)'s \(operation) call; revise its code or reach with ability.save and keep the reviewed version. Check external \
                state before repeating an operation with uncertain effects.
                """, nextCall: Parts.readCall(abilityID))
        }
        return failure
    }
    private func text(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard case .string(let text)? = args[key], !text.isEmpty else { throw Self.inputFailure("missing_primitive_field", field: key,
            accepted: "a nonempty string") }
        return text
    }
    private func port(_ args: [String: JSONValue], zero: Bool) throws -> NWEndpoint.Port {
        guard case .int(let value)? = args["port"], value >= (zero ? 0 : 1), let raw = UInt16(exactly: value),
              let port = NWEndpoint.Port(rawValue: raw) else { throw Self.inputFailure("invalid_network_port", field: "port",
                  accepted: "an integer from \(zero ? 0 : 1) to 65535") }
        return port
    }
    private static func data(_ args: [String: JSONValue]) throws -> Data {
        guard case .string(let base64)? = args["base64"], let data = Data(base64Encoded: base64), data.count <= byteLimit else {
            throw sendLimitFailure
        }
        return data
    }
    private static var sendLimitFailure: ToolFailureError {
        inputFailure("invalid_send_base64", field: "base64", accepted: "a base64 string decoding to at most 4 MiB; alternatively pass nonempty text")
    }
    private func address(_ host: String, publicOnly: Bool = false, fetch: Bool = false) async throws -> String {
        try Task.checkCancellation()
        guard !closed || fetch else { throw CancellationError() }
        let id = UUID()
        let once = ContinuationOnce<Result<[String], Error>>()
        lookups[id] = (once, fetch)
        defer { lookups.removeValue(forKey: id) }
        DispatchQueue.global(qos: .utility).async {
            guard once.isPending else { return }
            let result: Result<[String], Error>
            do { result = .success(try Self.resolve(host)) }
            catch { result = .failure(error) }
            _ = once.resume(result)
        }
        let addresses = try await once.wait(cancellingWith: .failure(CancellationError())).get()
        try Task.checkCancellation()
        // A run closing ends ordinary lookups, while an admitted fetch still owns its one request.
        guard !closed || fetch else { throw CancellationError() }
        // Loopback resolves only to this Mac; public fetches cannot reach private networks either.
        guard !publicOnly || addresses.allSatisfy({
            !NetworkAddress.loopback($0) && !NetworkAddress.privateNetwork($0) && !NetworkAddress.isIPv4MappedIPv6($0)
        }),
              !NetworkAddress.loopback(host) || addresses.allSatisfy(NetworkAddress.loopback),
              let chosen = addresses.first, permissions.contains(.flag(.network))
            || addresses.allSatisfy({ NetworkAddress.loopback($0) ? permissions.contains(.flag(.networkLocalhost))
                : !NetworkAddress.privateNetwork($0) && permissions.contains(.flag(.networkPublic)) }) else {
            throw denied("The resolved address for \(host) is outside the declared network reach.", """
                Check the host's DNS addresses; use a matching loopback or public host and declare its network reach. The public destination check \
                excludes loopback, private networks and IPv4-mapped IPv6 addresses.
                """)
        }
        return chosen
    }

    private static func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard unsafe getaddrinfo(host, nil, &hints, &first) == 0, let start = unsafe first else {
            throw SenseFailure(code: "dns_resolution_failed",
                message: "Network host \(host) could not be resolved. Correct the host or repair DNS/network access before connecting.")
        }
        defer { unsafe freeaddrinfo(start) }
        var cursor: UnsafeMutablePointer<addrinfo>? = unsafe start, addresses: [String] = []
        while let at = unsafe cursor {
            var bytes = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if unsafe getnameinfo(at.pointee.ai_addr, at.pointee.ai_addrlen, &bytes, socklen_t(bytes.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            cursor = unsafe at.pointee.ai_next
        }
        return addresses
    }

    private func socketPath(_ args: [String: JSONValue]) throws -> String {
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        }
        let raw = try text(args, "path"), path = resolved(raw), root = resolved(dataRoot.path)
        guard permissions.contains(.flag(.network)), raw.hasPrefix("/") || raw.hasPrefix("~/"), !raw.utf8.contains(0),
              readPaths.contains(where: { resolved($0) == path }), path != root, !path.hasPrefix(root + "/") else {
            throw denied("Socket reach is undeclared or targets NativeAgent's data root.",
                "Declare reach.capabilities network and this exact socket in reach.readPaths; NativeAgent's data root sockets cannot be opened.")
        }
        return path
    }

    private func network(_ operation: String, args: [String: JSONValue], fetch: Bool = false, onActivity: (@Sendable () -> Void)?) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !closed || fetch else { throw CancellationError() }
        switch operation {
        case "network.connect" where args["path"] != nil:
            try checkConnectionCapacity()
            let id = UUID().uuidString
            connections[id] = NWConnection(to: .unix(path: try socketPath(args)), using: .tcp)
            try await ready(id, onActivity: onActivity)
            guard !closed, connections[id] != nil else { throw CancellationError() }
            return .object(["id": .string(id)])
        case "network.connect", "network.listen":
            let host = try text(args, "host"), address = try await address(host, publicOnly: args["publicOnly"] == .bool(true), fetch: fetch),
                port = try port(args, zero: operation == "network.listen")
            try Task.checkCancellation()
            guard !closed || fetch else { throw CancellationError() }
            let parameters: NWParameters
            if args["transport"] == .string("udp") { parameters = .udp }
            else { parameters = Self.tcpParameters(host: host, secure: args["tls"] == .bool(true) && operation == "network.connect") }
            let id = UUID().uuidString
            if operation == "network.connect" {
                try checkConnectionCapacity()
                connections[id] = NWConnection(host: NWEndpoint.Host(address), port: port, using: parameters)
                if fetch { fetchConnections.insert(id) }
                try await ready(id, onActivity: onActivity)
                guard !closed || fetch, connections[id] != nil else { throw CancellationError() }
                return .object(["id": .string(id)])
            }
            guard permissions.contains(.flag(.network)) || NetworkAddress.loopback(address) && permissions.contains(.flag(.networkLocalhost)) else {
                throw denied("Listening requires the declared inbound network reach.",
                    "Declare network_localhost for a loopback listener or network for a listener beyond loopback.")
            }
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
            let listener = try NWListener(using: parameters, on: port)
            listeners[id] = listener
            listener.newConnectionHandler = { connection in Task { await self.incoming(connection, listener: id) } }
            try await networkReply(onActivity: onActivity, cancel: { listener.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
                listener.stateUpdateHandler = { state in
                    if case .ready = state { done.yield(()); done.finish() }
                    if case .failed(let error) = state { done.finish(throwing: error); Task { await self.arrive(id, .failed(error)) } }
                    if case .cancelled = state { done.finish(throwing: CancellationError()) }
                }
                listener.start(queue: self.queue)
            }
            guard !closed, listeners[id] != nil else { throw CancellationError() }
            return .object(["id": .string(id), "port": .int(Int64(listener.port?.rawValue ?? port.rawValue))])
        case "network.accept":
            let id = try text(args, "id")
            guard listeners[id] != nil else { throw denied("This ability does not own that listener.",
                "Use the id returned to this ability by network.listen; a closed listener cannot be reused.") }
            let arrival = try await next(id, onActivity: onActivity)
            switch arrival {
            case .accepted(let accepted):
                try await ready(accepted, onActivity: onActivity)
                pump(accepted)
                return .object(["id": .string(accepted)])
            case .failed(let error): throw error
            default: throw CancellationError()
            }
        case "network.send":
            let id = try text(args, "id")
            guard let connection = connections[id] else { throw denied("This ability does not own that connection.",
                "Use an id returned to this ability by network.connect or network.accept; a closed connection cannot be reused.") }
            let data = try Self.data(args)
            try await sendBytes(data, to: connection, onActivity: onActivity)
            return .object(["bytes": .int(Int64(data.count))])
        case "network.close":
            let id = try text(args, "id")
            if let connection = connections.removeValue(forKey: id) { connection.cancel() }
            else if let listener = listeners.removeValue(forKey: id) {
                listener.cancel()
                // Unaccepted connections must close with their listener.
                for case .accepted(let key) in inbox[id] ?? [] { connections.removeValue(forKey: key)?.cancel() }
            }
            else { throw denied("This ability does not own that network handle.",
                "Use a connection or listener id opened by this ability; a closed handle cannot be reused.") }
            hosts[id] = nil; forget(id)
            return .object(["id": .string(id)])
        default: throw Self.inputFailure("unknown_network_primitive", field: "operation", accepted: "network.connect, listen, accept, send, receive or close")
        }
    }

    private func sendBytes(_ data: Data, to connection: NWConnection, context: NWConnection.ContentContext = .defaultMessage,
                           onActivity: (@Sendable () -> Void)?) async throws {
        try await networkReply(onActivity: onActivity, cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { done.finish(throwing: error) } else { done.yield(()); done.finish() }
            })
        }
    }

    private func incoming(_ connection: NWConnection, listener id: String) {
        guard !closed, listeners[id] != nil, connections.count + runStreams.count < Self.maxConnections,
              (inbox[id] ?? []).count < OwnedProgramRunner.actionLimit else { connection.cancel(); return }
        let key = UUID().uuidString
        connections[key] = connection
        arrive(id, .accepted(key))
    }

    /// Failed connection opens must cancel and release their resource.
    private func ready(_ id: String, onActivity: (@Sendable () -> Void)?) async throws {
        guard let connection = connections[id] else { throw CancellationError() }
        do {
            try await startConnection(connection, onActivity: onActivity)
        } catch {
            connections.removeValue(forKey: id)?.cancel()
            fetchConnections.remove(id)
            throw error
        }
    }

    private func startConnection(_ connection: NWConnection, streamID: String? = nil, onActivity: (@Sendable () -> Void)?) async throws {
        try await networkReply(onActivity: onActivity, cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
            connection.stateUpdateHandler = { state in
                if case .ready = state { done.yield(()); done.finish() }
                if case .waiting(let error) = state { done.finish(throwing: error) }
                if case .failed(let error) = state { done.finish(throwing: error) }
                if case .cancelled = state { done.finish(throwing: CancellationError()) }
            }
            if let streamID {
                streamConnections.withLock {
                    if $0?[streamID] != nil { connection.start(queue: self.queue) }
                    else { done.finish(throwing: CancellationError()) }
                }
            } else {
                connection.start(queue: self.queue)
            }
        }
    }

    private func networkReply<T: Sendable>(onActivity: (@Sendable () -> Void)?, cancel: @escaping @Sendable () -> Void,
                                  start: (AsyncThrowingStream<T, Error>.Continuation) -> Void) async throws -> T {
        let stream = AsyncThrowingStream<T, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        try Task.checkCancellation()
        start(stream.continuation)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var iterator = stream.stream.makeAsyncIterator()
            guard let value = try await iterator.next() else { throw CancellationError() }
            onActivity?()
            return value
        } onCancel: { stream.continuation.finish(throwing: CancellationError()); cancel() }
    }

    // MARK: - What it holds, and what arrives on it

    /// One arrival wakes the resident holder and any pending reader through the same bounded buffer; duplicate wake news coalesces.
    private func arrive(_ id: String, _ arrival: Arrival) {
        guard !closed, connections[id] != nil || programs[id] != nil || listeners[id] != nil else { return }
        // Overflow ends the program and retains failure for its next read.
        if case .failed = arrival { programs[id]?.end() }
        announce(id)
        if let waiting = readers.removeValue(forKey: id) { return complete(waiting.read, .success(arrival)) }
        inbox[id, default: []].append(arrival)
    }

    private func announce(_ id: String) {
        let kind = programs[id] != nil ? "program" : listeners[id] != nil ? "listener" : "connection"
        held?.signal("held", part: abilityID, ["id": .string(id), "kind": .string(kind)])
    }

    /// Arrivals stay ordered; only data, terminal evidence or cancellation releases a reader.
    private func next(_ id: String, onActivity: (@Sendable () -> Void)?) async throws -> Arrival {
        let arrival: Arrival
        if let first = inbox[id]?.first {
            inbox[id]?.removeFirst()
            arrival = first
        } else if let end = ended[id] { return end }
        else {
            guard readers[id] == nil else { throw SenseFailure(code: "busy", message: "Another read of \(id) is already waiting.") }
            pump(id)
            reads += 1
            let token = reads
            if closed || Task.isCancelled { throw CancellationError() }
            let read = Read()
            readers[id] = (token, read)
            await read.done.park()
            endRead(id, token, CancellationError())
            guard let result = read.result else {
                throw SenseFailure(code: "read_unsettled", message: "The stream reader woke without its result.")
            }
            arrival = try result.get()
        }
        onActivity?()
        if arrival.ends { ended[id] = arrival } else { pump(id) }
        return arrival
    }

    private func endRead(_ id: String, _ token: Int, _ error: Error) {
        guard readers[id]?.token == token, let waiting = readers.removeValue(forKey: id) else { return }
        complete(waiting.read, .failure(error))
    }

    /// Keep one read outstanding only while no connection piece waits unread, bounding held input.
    private func pump(_ id: String) {
        guard let connection = connections[id], !pumping.contains(id), ended[id] == nil, inbox[id]?.isEmpty ?? true else { return }
        pumping.insert(id)
        Task.detached { await self.pumped(id, connection) }
    }

    private func pumped(_ id: String, _ connection: NWConnection) async {
        let arrival: Arrival
        do { arrival = try await receive(connection, onActivity: nil) } catch { arrival = .failed(error) }
        pumping.remove(id)
        arrive(id, arrival)
    }

    private func receive(_ connection: NWConnection, maximum: Int = ToolPrimitiveBroker.byteLimit,
                         onActivity: (@Sendable () -> Void)?) async throws -> Arrival {
        try await networkReply(onActivity: onActivity, cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Arrival, Error>.Continuation) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                if let error { done.finish(throwing: error) } else { done.yield(.bytes(data ?? Data(), stream: nil, eof: complete)); done.finish() }
            }
        }
    }

    /// Closing held reach releases its waiters.
    private func forget(_ id: String) {
        inbox[id] = nil; ended[id] = nil; pumping.remove(id)
        for key in [id, id + "stdout", id + "stderr"] { streams[key] = nil }
        if let waiting = readers.removeValue(forKey: id) { complete(waiting.read, .failure(CancellationError())) }
    }

    /// Each run must own its own watch.
    func begin() { running += 1 }

    /// Run exit settles watches and nonresident reach; resident resources remain held.
    @discardableResult func finish(run: StreamRun) -> [JSONValue] {
        cancelStreams(run)
        runStreams = runStreams.filter { $0.value.run !== run }
        guard held != nil else { return close() }
        running -= 1
        guard running == 0 else { return [] }
        endWatch("run_ended")
        defer { watched = [] }
        return watched
    }

    /// Only the holding ability may end its named program.
    func end(_ arguments: JSONValue) {
        if let id = Parts.fields(arguments)["id"]?.stringValue, programs[id] != nil { endProgram(id) }
    }

    /// Closing held reach must preserve admitted fetch ownership through its original transport settlement.
    @discardableResult func close() -> [JSONValue] {
        closed = true
        for lookup in lookups.values where !lookup.fetch { _ = lookup.once.resume(.failure(CancellationError())) }
        for (id, connection) in connections where !fetchConnections.contains(id) { connection.cancel() }
        for listener in listeners.values { listener.cancel() }
        for program in programs.values { program.end() }
        for waiting in readers.values { complete(waiting.read, .failure(CancellationError())) }
        connections = connections.filter { fetchConnections.contains($0.key) }
        runStreams.removeAll()
        invalidateStreams()
        stopObservingStreams()
        listeners.removeAll(); programs.removeAll(); readers.removeAll(); inbox.removeAll(); ended.removeAll()
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

extension ToolPrimitiveBroker {
    private static let messageLimit = 1_048_576
    private static let headLimit = 16_384
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let lineEnd = Data("\r\n".utf8)

    private final class RunStream {
        enum Kind { case websocket, events }
        let kind: Kind
        let run: StreamRun
        var busy = false
        var secretHost: String?
        var events: ServerEvents?

        init(_ kind: Kind, run: StreamRun) { self.kind = kind; self.run = run }
    }

    private static func tcpParameters(host: String, secure: Bool, websocket: Bool = false) -> NWParameters {
        guard secure || websocket else { return .tcp }
        let tcp = NWProtocolTCP.Options()
        if websocket { tcp.connectionTimeout = 15 }
        let tls = secure ? NWProtocolTLS.Options() : nil
        if let tls {
            unsafe sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            if websocket { sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12) }
        }
        return NWParameters(tls: tls, tcp: tcp)
    }

    private func checkConnectionCapacity() throws {
        guard connections.count + runStreams.count < Self.maxConnections else {
            throw SenseFailure(code: "connection_limit", message: "This ability already holds eight network connections. Close one before opening another.")
        }
    }

    private static func streamTimeout(_ operation: String, _ args: [String: JSONValue]) throws -> Double? {
        guard streamOpenOperations.contains(operation) || ["network.websocket.receive", "fetch.sse.next"].contains(operation) else { return nil }
        guard let value = args["timeout_ms"] else { return operation == "network.websocket.receive" ? 10 : 15 }
        guard case .int(let milliseconds) = value else {
            throw inputFailure("invalid_timeout", field: "timeout_ms", accepted: "integer milliseconds (clamped to 50–60000)")
        }
        return Double(max(50, min(60_000, milliseconds))) / 1000
    }

    private static func token(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || "!#$%&'*+-.^_`|~".utf8.contains($0) }
    }

    private static func websocketRequest(_ args: [String: JSONValue]) throws -> URLRequest {
        guard let raw = args["url"]?.stringValue, var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["ws", "wss"].contains(scheme),
              args["method"] == nil, ["body", "body_base64", "multipart", "connector"].allSatisfy({ args[$0] == nil }) else {
            throw inputFailure("invalid_websocket_url", field: "url", accepted: "ws or wss URL without credentials or fragment; no body, method or connector")
        }
        components.scheme = scheme == "wss" ? "https" : "http"
        guard let url = components.url, let host = url.host(percentEncoded: false), Keyring.host(host) != nil,
              url.port.map({ (1...65535).contains($0) }) != false else {
            throw inputFailure("invalid_websocket_url", field: "url", accepted: "a fixed host and valid port")
        }
        let headers = args["headers"]?.stringFields ?? [:]
        let keys = headers.keys.map { $0.lowercased() }
        let reserved: Set<String> = ["host", "connection", "upgrade", "content-length", "transfer-encoding",
            "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions", "sec-websocket-protocol"]
        guard Set(keys).count == keys.count, Set(keys).isDisjoint(with: reserved), headers.keys.allSatisfy(token),
              headers.values.allSatisfy({ $0.utf8.allSatisfy { $0 == 9 || $0 >= 32 && $0 < 127 } }) else {
            throw inputFailure("invalid_websocket_headers", field: "headers", accepted: "distinct HTTP header names and values; omit upgrade and framing headers")
        }
        var http = args
        http["url"] = .string(url.absoluteString)
        return try Parts.fetchRequest(http)
    }

    private static func hostName(_ url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? ""
        return host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && hostName(lhs).lowercased() == hostName(rhs).lowercased()
            && (lhs.port ?? (lhs.scheme?.lowercased() == "https" ? 443 : 80)) == (rhs.port ?? (rhs.scheme?.lowercased() == "https" ? 443 : 80))
    }

    private static func socketProtocols(_ args: [String: JSONValue]) throws -> [String] {
        guard let field = args["subprotocols"] else { return [] }
        let offered = JSONValue.stringArray(field)
        guard case .array(let rows) = field, rows.count == offered.count, Set(offered).count == offered.count,
              offered.allSatisfy(token), offered.joined(separator: ", ").utf8.count <= 4096 else {
            throw inputFailure("invalid_websocket_subprotocols", field: "subprotocols", accepted: "distinct HTTP tokens, at most 4096 bytes")
        }
        return offered
    }

    private func checkStream(_ operation: String, args: [String: JSONValue], run: StreamRun, fixtureOwnsStream: Bool) throws {
        _ = try Self.streamTimeout(operation, args)
        guard streamConnections.withLock({ $0 != nil }), run.active.withLock({ $0 }) else { throw CancellationError() }
        switch operation {
        case "network.websocket.open":
            let url = try Self.destination(args, websocket: true)
            try requireReach(NetworkAddress.loopback(Self.hostName(url)) ? .networkLocalhost : .networkPublic, operation: operation, fullNetwork: true)
            _ = try Self.socketProtocols(args)
        case "fetch.sse.open":
            guard ["body_base64", "multipart", "response_encoding"].allSatisfy({ args[$0] == nil }) else {
                throw Self.inputFailure("invalid_sse_arguments", field: "arguments", accepted: "url, method?, headers?, body?, timeout_ms?; no connector or binary options")
            }
            let host = Self.hostName(try Self.destination(args))
            let reach: PartReachGrant.StaticFlag = NetworkAddress.loopback(host) ? .networkLocalhost : .networkPublic
            try requireReach(reach, operation: operation)
        default:
            let id = try text(args, "id")
            let websocket = operation.hasPrefix("network.websocket.")
            guard fixtureOwnsStream || runStreams[id].map({ $0.run === run && $0.kind == (websocket ? .websocket : .events) }) == true else {
                throw denied("This run does not own that stream.", "Use a live id from the corresponding open call in this run.")
            }
            let allowed = operation == "network.websocket.send" ? Set(["text"]) : Set<String>()
            guard Keyring.names(in: .object(args.filter { !allowed.contains($0.key) })).isEmpty else {
                throw Self.inputFailure("invalid_stream_secret", field: "arguments", accepted: "a secret placeholder only in WebSocket send text")
            }
            if operation == "network.websocket.send" { _ = try Self.socketPayload(args) }
            if operation == "network.websocket.close" { _ = try Self.socketClose(args) }
        }
    }

    private static func socketPayload(_ args: [String: JSONValue]) throws -> (NWProtocolWebSocket.Opcode, Data) {
        if let text = args["text"]?.stringValue, args["base64"] == nil, text.utf8.count <= messageLimit { return (.text, Data(text.utf8)) }
        if args["text"] == nil, let text = args["base64"]?.stringValue, text.utf8.count <= 1_398_104,
           let data = Data(base64Encoded: text), data.count <= messageLimit { return (.binary, data) }
        throw inputFailure("invalid_websocket_message", field: "text/base64", accepted: "exactly one text or base64 message, at most 1 MiB decoded")
    }

    private static func socketClose(_ args: [String: JSONValue]) throws -> (NWProtocolWebSocket.CloseCode, Data) {
        let raw = args["code"] ?? .int(1000), reason = args["reason"] ?? .string("")
        guard case .int(let code) = raw, [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011].contains(code) || (3000...4999).contains(code),
              case .string(let text) = reason, text.utf8.count <= 123 else {
            throw inputFailure("invalid_websocket_close", field: "code/reason", accepted: "a valid outgoing close code and a UTF-8 reason of at most 123 bytes")
        }
        return (try NWProtocolWebSocket.CloseCode(rawValue: UInt16(code)), Data(text.utf8))
    }

    func observeStreams() {
        guard !closed, streamObserver == nil else { return }
        let path = AbilityStore(dataRoot: dataRoot).root.appendingPathComponent(abilityID).path
        streamObserver = NotificationCenter.default.observeSynchronously(for: AbilityStore.DidChange.self) { [weak self] change in
            if change.path == path { self?.invalidateStreams() }
        }
    }

    private nonisolated func invalidateStreams() {
        streamConnections.withLock { connections in
            connections?.values.forEach { $0.connection.cancel() }
            connections = nil
        }
    }

    nonisolated func cancelStreams(_ run: StreamRun) {
        run.active.withLock { active in
            active = false
            streamConnections.withLock { connections in
                let ids = connections?.compactMap { $0.value.run === run ? $0.key : nil } ?? []
                for id in ids { connections?.removeValue(forKey: id)?.connection.cancel() }
            }
        }
    }

    private func stopObservingStreams() {
        if let streamObserver { NotificationCenter.default.removeObserver(streamObserver) }
        streamObserver = nil
    }

    private func endStream(_ id: String) {
        guard runStreams.removeValue(forKey: id) != nil else { return }
        streamConnections.withLock {
            if let connection = $0?.removeValue(forKey: id)?.connection { connection.cancel() }
        }
    }

    private func stream(_ operation: String, args: [String: JSONValue], run: StreamRun, opening: String?, budget: OperationWaitBudget,
                        execution: OwnedProgramExecution) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !closed, streamConnections.withLock({ $0 != nil }), run.active.withLock({ $0 }), !budget.expired else { throw budget.cancellationError }
        if let opening {
            return try await openStream(operation, args: args, run: run, id: opening, budget: budget, execution: execution)
        }
        let onActivity = execution.onActivity
        let id = try text(args, "id")
        guard let stream = runStreams[id], stream.run === run, let connection = streamConnections.withLock({ $0?[id]?.connection }) else {
            throw SenseFailure(code: "stream_ended", message: "This run no longer owns that stream.")
        }
        guard !stream.busy else { throw SenseFailure(code: "busy", message: "This stream already has a call in progress.") }
        stream.busy = true
        defer { stream.busy = false }
        do {
            switch operation {
            case "fetch.sse.close":
                endStream(id)
                return .object(["id": .string(id), "closed": .bool(true)])
            case "fetch.sse.next":
                guard let events = stream.events else { throw CancellationError() }
                let value = try await nextEvent(events, connection: connection, onActivity: onActivity)
                if value.objectValue?["done"] == .bool(true) {
                    endStream(id)
                    return value
                }
                return Self.networkReadback(value)
            case "network.websocket.send":
                var given = args
                if !Keyring.names(in: .object(args)).isEmpty {
                    guard let host = stream.secretHost else {
                        throw denied("A secret needs established TLS or admitted loopback.",
                            "Use a wss or admitted loopback WebSocket before sending a secret.", code: "secret_requires_tls")
                    }
                    given = try await inserting(args, ["text"], to: .host(host))
                    try Task.checkCancellation()
                    guard streamConnections.withLock({ $0?[id] != nil }), !budget.expired else { throw budget.cancellationError }
                }
                let (opcode, payload) = try Self.socketPayload(given)
                try await sendSocket(payload, metadata: .init(opcode: opcode), connection: connection, onActivity: onActivity)
                return .object(["bytes": .int(Int64(payload.count))])
            case "network.websocket.close":
                let (code, reason) = try Self.socketClose(args)
                let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
                metadata.closeCode = code
                try await sendSocket(reason, metadata: metadata, connection: connection, onActivity: onActivity)
                endStream(id)
                return .object(["id": .string(id), "closed": .bool(true)])
            default:
                let value = try await receiveSocket(connection, onActivity: onActivity)
                if value.objectValue?["closed"] == .bool(true) { endStream(id) }
                return Self.networkReadback(value)
            }
        } catch {
            endStream(id)
            throw error
        }
    }

    private func openStream(_ operation: String, args: [String: JSONValue], run: StreamRun, id: String, budget: OperationWaitBudget,
                            execution: OwnedProgramExecution) async throws -> JSONValue {
        let onActivity = execution.onActivity
        let socket = operation == "network.websocket.open"
        let destination = try Self.destination(args, websocket: socket), host = Self.hostName(destination).lowercased()
        var request: URLRequest
        if socket {
            request = try Self.websocketRequest(try await inserting(args, ["url", "headers"], to: .host(host)))
        } else {
            request = try Parts.fetchRequest(try await inserting(args, ["url", "headers", "body"], to: .host(host)))
            if request.value(forHTTPHeaderField: "Accept") == nil { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        }
        let url = request.url!
        guard Self.sameOrigin(destination, url) else {
            throw denied("The stream destination changed with its secrets inserted.", "Use a fixed scheme, host and port.",
                code: socket ? "secret_cannot_alter_host" : "permission_denied")
        }
        try Task.checkCancellation()
        guard !closed, streamObserver != nil, streamConnections.withLock({ $0 != nil }), run.active.withLock({ $0 }), !budget.expired else {
            throw budget.cancellationError
        }
        let local = NetworkAddress.loopback(host), secure = url.scheme?.lowercased() == "https"
        let pinned = try await address(host, publicOnly: !local)
        try Task.checkCancellation()
        guard !budget.expired else { throw budget.cancellationError }
        try checkConnectionCapacity()
        if !socket, runStreams.values.filter({ $0.kind == .events }).count >= 4 {
            throw SenseFailure(code: "sse_limit", message: "This ability already holds four SSE streams. Close one before opening another.")
        }
        let port = try self.port(["port": .int(Int64(url.port ?? (secure ? 443 : 80)))], zero: false)
        let parameters = Self.tcpParameters(host: host, secure: secure, websocket: socket)
        let upgrade: SocketUpgrade? = if socket { try SocketUpgrade(request, protocols: Self.socketProtocols(args)) } else { nil }
        if let upgrade {
            let options = NWProtocolFramer.Options(definition: UpgradeFramer.definition)
            options["upgrade"] = upgrade
            let websocket = NWProtocolWebSocket.Options()
            websocket.skipHandshake = true; websocket.autoReplyPing = true; websocket.maximumMessageSize = Self.messageLimit
            parameters.defaultProtocolStack.applicationProtocols = [websocket, options]
        }
        let connection = NWConnection(host: NWEndpoint.Host(pinned), port: port, using: parameters)
        let registered = run.active.withLock { active in
            guard active, !Task.isCancelled else { return false }
            return streamConnections.withLock { connections in
                guard connections != nil else { return false }
                connections?[id] = (run, connection)
                return true
            }
        }
        guard registered else { connection.cancel(); throw CancellationError() }
        let stream = RunStream(socket ? .websocket : .events, run: run)
        runStreams[id] = stream
        var keep = false
        defer { if !keep { endStream(id) } }
        do { try await startConnection(connection, streamID: id, onActivity: onActivity) }
        catch let error as NWError where socket && error == .posix(.EPROTO) {
            throw SenseFailure(code: "websocket_upgrade_failed", message: "The pinned service did not return a valid WebSocket upgrade. No redirect was followed.")
        }
        try Task.checkCancellation()
        guard streamConnections.withLock({ $0?[id] != nil }), !budget.expired else { throw budget.cancellationError }
        if socket {
            if local || secure && connection.metadata(definition: NWProtocolTLS.definition) != nil { stream.secretHost = host }
            if secure, stream.secretHost == nil { throw SenseFailure(code: "tls_missing", message: "The WebSocket did not establish TLS.") }
            keep = true
            return .object(["id": .string(id)])
        }
        let keepsRecord = !["GET", "HEAD"].contains(request.httpMethod ?? "GET")
        let record = "fetch:" + id.lowercased()
        if keepsRecord { beginFetchRecord(record, execution: execution) }
        let outcome: Result<JSONValue, Error>
        do { outcome = .success(try await openEvents(request, id: id, connection: connection, budget: budget, onActivity: onActivity)) }
        catch { outcome = .failure(error) }
        let value: JSONValue
        if keepsRecord {
            let settled = await settle { await self.settleFetch(outcome, id: record, keepsRecord: true) }
            value = try settled.get()
        } else { value = try outcome.get() }
        try Task.checkCancellation()
        guard streamConnections.withLock({ $0?[id] != nil }), !budget.expired else { throw budget.cancellationError }
        keep = stream.events != nil
        return value
    }

    private func openEvents(_ request: URLRequest, id: String, connection: NWConnection, budget: OperationWaitBudget,
                            onActivity: (@Sendable () -> Void)?) async throws -> JSONValue {
        try await sendHTTP(request, to: connection, onActivity: onActivity)
        let (head, bytes, eof) = try await readHead(connection, onActivity: onActivity)
        try Task.checkCancellation()
        guard let stream = runStreams[id], streamConnections.withLock({ $0?[id] != nil }), !budget.expired else { throw budget.cancellationError }
        let mime = head.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard (200...299).contains(head.status), head.status != 204, request.httpMethod != "HEAD", mime == "text/event-stream" else {
            let bounded = try await readNonStream(head, bytes: bytes, eof: eof, method: request.httpMethod, connection: connection, onActivity: onActivity)
            return try fetchResponse(bounded, method: request.httpMethod)
        }
        guard head.headers["content-encoding"] == nil || head.tokens("content-encoding") == ["identity"] else {
            throw SenseFailure(code: "sse_content_encoding", message: "SSE requires an uncompressed UTF-8 response.")
        }
        stream.events = try ServerEvents(head: head, bytes: Data(bytes.dropFirst(head.length)), eof: eof)
        return .object(["id": .string(id), "status": .int(Int64(head.status))])
    }

    private func sendSocket(_ data: Data, metadata: NWProtocolWebSocket.Metadata, connection: NWConnection,
                            onActivity: (@Sendable () -> Void)?) async throws {
        try await sendBytes(data, to: connection, context: .init(identifier: "websocket", metadata: [metadata]), onActivity: onActivity)
    }

    private func receiveSocket(_ connection: NWConnection, onActivity: (@Sendable () -> Void)?) async throws -> JSONValue {
        var message = Data(), kind: NWProtocolWebSocket.Opcode?
        while true {
            let (piece, metadata, complete): (Data, NWProtocolWebSocket.Metadata?, Bool) = try await networkReply(onActivity: onActivity,
                cancel: { connection.cancel() }) { done in
                connection.receiveMessage { data, context, complete, error in
                    if let error { done.finish(throwing: error) }
                    else {
                        done.yield((data ?? Data(), context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata, complete))
                        done.finish()
                    }
                }
            }
            guard let metadata else {
                guard complete, kind == nil, piece.isEmpty else {
                    throw SenseFailure(code: "websocket_incomplete", message: "The WebSocket message ended incomplete.")
                }
                return .object(["type": .string("close"), "closed": .bool(true), "close_code": .int(1006), "reason": .string("")])
            }
            switch metadata.opcode {
            case .pong, .ping: continue
            case .close:
                let code = switch metadata.closeCode {
                case .protocolCode(let code): code.rawValue
                case .applicationCode(let code), .privateCode(let code): code
                @unknown default: UInt16(1006)
                }
                return .object(["type": .string("close"), "closed": .bool(true), "close_code": .int(Int64(code)),
                                "reason": .string(redactor(String(decoding: piece, as: UTF8.self)))])
            case .text, .binary:
                guard kind == nil || kind == metadata.opcode else { throw Self.invalidSocketMessage }
                kind = metadata.opcode
            case .cont:
                guard kind != nil else { throw Self.invalidSocketMessage }
            @unknown default: throw Self.invalidSocketMessage
            }
            guard piece.count <= Self.messageLimit - message.count else { throw Self.readbackLimit }
            message.append(piece)
            if !complete { continue }
            if kind == .binary {
                let safe = try cleanBinary(message, limit: Self.messageLimit)
                return .object(["type": .string("binary"), "base64": .string(safe.base64EncodedString()), "bytes": .int(Int64(safe.count)), "closed": .bool(false)])
            }
            guard let value = String(data: message, encoding: .utf8) else {
                throw SenseFailure(code: "websocket_text_invalid", message: "The WebSocket text message is not UTF-8.")
            }
            let text = redactor(value)
            guard text.utf8.count <= Self.byteLimit else { throw Self.readbackLimit }
            return .object(["type": .string("text"), "text": .string(text), "closed": .bool(false)])
        }
    }

    private static var invalidSocketMessage: SenseFailure { .init(code: "websocket_message_invalid", message: "The WebSocket message framing is invalid.") }
    private static var readbackLimit: SenseFailure { .init(code: "output_limit", message: "The redacted response exceeds its readback limit.") }

    private func cleanBinary(_ bytes: Data, limit: Int) throws -> Data {
        let data = redactor.whole(bytes)
        guard data.count <= limit else { throw Self.readbackLimit }
        return data
    }

    private struct HTTPHead: Sendable {
        let status: Int
        let length: Int
        let headers: [String: String]

        init?(_ bytes: Data, length: Int) {
            let lines = String(decoding: bytes.prefix(length - 4), as: UTF8.self).components(separatedBy: "\r\n")
            guard let statusLine = lines.first else { return nil }
            let status = statusLine.split(separator: " ", maxSplits: 2)
            guard status.count >= 2, status[0] == "HTTP/1.1" || status[0] == "HTTP/1.0", status[1].count == 3,
                  let code = Int(status[1]), (100...599).contains(code) else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let delimiter = line.firstIndex(of: ":") else { return nil }
                let key = String(line[..<delimiter]).lowercased()
                let value = line[line.index(after: delimiter)...].trimmingCharacters(in: .whitespaces)
                guard ToolPrimitiveBroker.token(key), value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else { return nil }
                if let previous = headers[key] { headers[key] = previous + ", " + value } else { headers[key] = value }
            }
            self.status = code; self.length = length; self.headers = headers
        }

        func tokens(_ field: String) -> [String] {
            (headers[field] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
    }

    private struct SocketUpgrade: Sendable {
        let request: Data
        let accept: String
        let protocols: [String]

        init(_ request: URLRequest, protocols: [String]) throws {
            let url = request.url!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let host = ToolPrimitiveBroker.hostName(url)
            let named = host.contains(":") ? "[\(host)]" : host
            let authority = url.port.map { "\(named):\($0)" } ?? named
            let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
            let target = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            var random = SystemRandomNumberGenerator()
            let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &random) }).base64EncodedString()
            var rows = ["GET \(target) HTTP/1.1", "Host: \(authority)", "Upgrade: websocket", "Connection: Upgrade",
                        "Sec-WebSocket-Key: \(key)", "Sec-WebSocket-Version: 13"]
            if !protocols.isEmpty { rows.append("Sec-WebSocket-Protocol: " + protocols.joined(separator: ", ")) }
            for (name, value) in request.allHTTPHeaderFields ?? [:] { rows.append("\(name): \(value)") }
            let wire = Data((rows.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            guard wire.count <= ToolPrimitiveBroker.headLimit else {
                throw ToolPrimitiveBroker.inputFailure("websocket_head_limit", field: "url/headers", accepted: "an upgrade request head of at most 16 KiB")
            }
            let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            self.request = wire; self.accept = Data(digest).base64EncodedString(); self.protocols = protocols
        }

        func accepted(_ head: HTTPHead) -> Bool {
            head.status == 101 && head.tokens("upgrade") == ["websocket"] && head.tokens("connection").contains("upgrade")
                && head.headers["sec-websocket-accept"] == accept && head.headers["sec-websocket-extensions"] == nil
                && (head.headers["sec-websocket-protocol"].map(protocols.contains) ?? true)
        }
    }

    private final class UpgradeFramer: NWProtocolFramerImplementation {
        static let label = "NativeAgent WebSocket Upgrade"
        static let definition = NWProtocolFramer.Definition(implementation: UpgradeFramer.self)
        private let upgrade: SocketUpgrade?

        init(framer: NWProtocolFramer.Instance) { upgrade = framer.options["upgrade"] as? SocketUpgrade }

        func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
            guard let upgrade else { framer.markFailed(error: .posix(.EPROTO)); return .willMarkReady }
            framer.writeOutput(data: upgrade.request)
            return .willMarkReady
        }

        func handleInput(framer: NWProtocolFramer.Instance) -> Int {
            guard let upgrade else { framer.markFailed(error: .posix(.EPROTO)); return 0 }
            var next = 1, accepted = false, failed = false
            _ = unsafe framer.parseInput(minimumIncompleteLength: 1, maximumLength: ToolPrimitiveBroker.headLimit) { buffer, complete in
                guard let buffer else { failed = complete; return 0 }
                let data = unsafe Data(buffer)
                if let end = data.range(of: ToolPrimitiveBroker.headerEnd) {
                    let length = end.upperBound - data.startIndex
                    accepted = HTTPHead(data, length: length).map(upgrade.accepted) == true
                    failed = !accepted
                    return length
                }
                next = data.count + 1
                failed = complete || data.count == ToolPrimitiveBroker.headLimit
                return 0
            }
            if failed { framer.markFailed(error: .posix(.EPROTO)) }
            if accepted {
                framer.passThroughInput(); framer.passThroughOutput(); framer.markReady()
            }
            return accepted || failed ? 0 : next
        }

        func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
            do { try framer.writeOutputNoCopy(length: messageLength) } catch { framer.markFailed(error: .posix(.EIO)) }
        }
        func wakeup(framer: NWProtocolFramer.Instance) {}
        func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
        func cleanup(framer: NWProtocolFramer.Instance) {}
    }

    private func readHead(_ connection: NWConnection, onActivity: (@Sendable () -> Void)?) async throws -> (HTTPHead, Data, Bool) {
        var received = Data(), eof = false, interim = 0
        while true {
            if let marker = received.range(of: Self.headerEnd) {
                let length = marker.upperBound - received.startIndex
                guard length <= Self.headLimit, let head = HTTPHead(received, length: length) else { break }
                if head.status >= 200 { return (head, received, eof) }
                guard head.status != 101, interim < 8 else { break }
                interim += 1
                received.removeFirst(length)
                continue
            }
            guard !eof, received.count < Self.headLimit else { break }
            guard case .bytes(let chunk, _, let done) = try await receive(connection, maximum: Self.headLimit, onActivity: onActivity) else {
                throw CancellationError()
            }
            received.append(chunk); eof = done
        }
        throw SenseFailure(code: "http_response_incomplete", message: "Fetch did not receive a valid bounded final HTTP response head.")
    }

    private func readBinaryResponse(_ connection: NWConnection, method: String?, onActivity: (@Sendable () -> Void)?) async throws -> JSONValue {
        let (head, bytes, eof) = try await readHead(connection, onActivity: onActivity)
        var data = Data()
        if method != "HEAD", head.status != 204, head.status != 304 {
            let body = try HTTPBody(head: head, bytes: Data(bytes.dropFirst(head.length)), eof: eof)
            while true {
                if let piece = try body.take() {
                    guard piece.count <= Self.byteLimit - data.count else { throw Self.readbackLimit }
                    data.append(piece)
                } else if body.done {
                    break
                } else {
                    guard case .bytes(let chunk, _, let eof) = try await receive(connection, maximum: Self.headLimit, onActivity: onActivity) else {
                        throw CancellationError()
                    }
                    body.wire.append(chunk); body.eof = eof
                }
            }
            data = try cleanBinary(data, limit: Self.byteLimit)
        }
        return try Parts.fetchReply(status: head.status, headers: head.headers, data: data, binary: true, name: { redactor.name($0) }) { redactor($0) }
    }

    private func readNonStream(_ head: HTTPHead, bytes: Data, eof: Bool, method: String?, connection: NWConnection,
                               onActivity: (@Sendable () -> Void)?) async throws -> Data {
        if method == "HEAD" || head.status == 204 || head.status == 304 || eof { return bytes }
        let body = try HTTPBody(head: head, bytes: Data(bytes.dropFirst(head.length)), eof: false)
        var received = bytes
        while true {
            while try body.take() != nil {}
            if body.done { return received }
            guard case .bytes(let chunk, _, let done) = try await receive(connection, maximum: Self.headLimit, onActivity: onActivity) else {
                throw CancellationError()
            }
            guard received.count + chunk.count <= Self.byteLimit else { throw Self.readbackLimit }
            received.append(chunk); body.wire.append(chunk); body.eof = done
        }
    }

    private final class HTTPBody {
        enum Framing { case eof, fixed(Int), chunkSize, chunk(Int), chunkEnd, trailers, done }
        var wire: Data
        var eof: Bool
        var framing: Framing
        private static var malformed: SenseFailure { .init(code: "http_body_framing", message: "The fetch response has incomplete or invalid HTTP body framing.") }
        var done: Bool { if case .done = framing { true } else { false } }

        init(head: HTTPHead, bytes: Data, eof: Bool) throws {
            self.wire = bytes; self.eof = eof
            if head.headers["transfer-encoding"] != nil {
                guard head.tokens("transfer-encoding") == ["chunked"], head.headers["content-length"] == nil else { throw Self.malformed }
                framing = .chunkSize
            } else if let length = head.headers["content-length"] {
                guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length) else { throw Self.malformed }
                framing = .fixed(count)
            } else { framing = .eof }
        }

        func take() throws -> Data? {
            while true {
                switch framing {
                case .done: return nil
                case .eof:
                    if eof { framing = .done }
                    return wire.isEmpty ? nil : remove(wire.count)
                case .fixed(let remaining), .chunk(let remaining):
                    let chunk: Bool = if case .chunk = framing { true } else { false }
                    if remaining == 0 {
                        guard chunk || wire.isEmpty else { throw Self.malformed }
                        framing = chunk ? .chunkEnd : .done
                        continue
                    }
                    let count = min(remaining, wire.count)
                    if count == 0 { if eof { throw Self.malformed }; return nil }
                    framing = chunk ? .chunk(remaining - count) : .fixed(remaining - count)
                    return remove(count)
                case .chunkEnd:
                    guard wire.count >= 2 else { if eof { throw Self.malformed }; return nil }
                    guard wire.starts(with: ToolPrimitiveBroker.lineEnd) else { throw Self.malformed }
                    wire.removeFirst(2); framing = .chunkSize
                case .chunkSize:
                    guard let end = wire.range(of: ToolPrimitiveBroker.lineEnd) else {
                        if eof || wire.count > ToolPrimitiveBroker.headLimit { throw Self.malformed }; return nil
                    }
                    let line = remove(end.upperBound - wire.startIndex)
                    guard line.count <= ToolPrimitiveBroker.headLimit else { throw Self.malformed }
                    let size = line.dropLast(2).prefix { $0 != 59 }
                    guard !size.isEmpty, size.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                          let count = Int(String(decoding: size, as: UTF8.self), radix: 16) else { throw Self.malformed }
                    framing = count == 0 ? .trailers : .chunk(count)
                case .trailers:
                    if wire.starts(with: ToolPrimitiveBroker.lineEnd) || wire.range(of: ToolPrimitiveBroker.headerEnd) != nil {
                        framing = .done; continue
                    }
                    if eof || wire.count > ToolPrimitiveBroker.headLimit { throw Self.malformed }
                    return nil
                }
            }
        }

        private func remove(_ count: Int) -> Data {
            let data = Data(wire.prefix(count))
            wire.removeFirst(count)
            return data
        }
    }

    private final class ServerEvents {
        let body: HTTPBody
        var total = 0
        var transportBytes: Int
        var redacting = SecretStream()
        var lines = Data()
        var first = true, skipLF = false
        var eventSize = 0
        var data: [String] = []
        var name = "", lastID = ""
        var retry: Int64?
        var limited = false, flushed = false

        init(head: HTTPHead, bytes: Data, eof: Bool) throws {
            body = try HTTPBody(head: head, bytes: bytes, eof: eof)
            transportBytes = bytes.count
        }

        func event(_ redactor: SecretRedactor) throws -> JSONValue? {
            while true {
                if skipLF, let byte = lines.first {
                    if byte == 10 { lines.removeFirst() }
                    skipLF = false
                }
                guard let end = lines.firstIndex(where: { $0 == 10 || $0 == 13 }) else {
                    guard eventSize + lines.count <= 262_144 else { throw ToolPrimitiveBroker.readbackLimit }
                    return nil
                }
                var line = String(decoding: lines[..<end], as: UTF8.self)
                skipLF = lines[end] == 13
                let length = end - lines.startIndex + 1
                lines.removeFirst(length)
                eventSize += length
                guard eventSize <= 262_144 else { throw ToolPrimitiveBroker.readbackLimit }
                if first { first = false; if line.hasPrefix("\u{FEFF}") { line.removeFirst() } }
                if line.isEmpty {
                    let type = name.isEmpty ? "message" : name
                    defer { name = ""; data.removeAll(keepingCapacity: true); eventSize = 0 }
                    if data.isEmpty { continue }
                    return .object(["done": .bool(false), "event": .string(redactor(type)), "id": .string(redactor(lastID)),
                                    "retry_ms": retry.map(JSONValue.int) ?? .null, "data": .string(redactor(data.joined(separator: "\n")))])
                }
                let delimiter = line.firstIndex(of: ":") ?? line.endIndex
                let field = line[..<delimiter]
                var value = delimiter == line.endIndex ? "" : String(line[line.index(after: delimiter)...])
                if value.first == " " { value.removeFirst() }
                switch field {
                case "data": data.append(value)
                case "event": name = value
                case "id" where !value.utf8.contains(0): lastID = value
                case "retry" where !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }):
                    if let milliseconds = Int64(value) { retry = milliseconds }
                default: break
                }
            }
        }
    }

    private func nextEvent(_ events: ServerEvents, connection: NWConnection, onActivity: (@Sendable () -> Void)?) async throws -> JSONValue {
        let limit = 16 * 1024 * 1024
        while true {
            try Task.checkCancellation()
            if let result = try events.event(redactor) { return result }
            if events.limited { return .object(["done": .bool(true), "reason": .string("byte_limit")]) }
            if let bytes = try events.body.take() {
                let count = min(bytes.count, limit - events.total)
                events.total += count
                events.limited = events.total == limit
                events.lines.append(events.redacting.characters(Data(bytes.prefix(count)), end: false, redactor))
            } else if events.body.done {
                if events.flushed { return .object(["done": .bool(true), "reason": .string("eof")]) }
                events.flushed = true
                events.lines.append(events.redacting.characters(Data(), end: true, redactor))
            } else {
                guard case .bytes(let chunk, _, let eof) = try await receive(connection, maximum: Self.headLimit, onActivity: onActivity) else {
                    throw CancellationError()
                }
                events.transportBytes += chunk.count
                if events.transportBytes > 2 * limit { events.limited = true; continue }
                events.body.wire.append(chunk); events.body.eof = eof
            }
        }
    }
}

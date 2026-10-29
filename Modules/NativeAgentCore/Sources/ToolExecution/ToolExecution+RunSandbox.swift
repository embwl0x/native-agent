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
// Blueprint: | `ToolExecution+RunSandbox.swift` | `ToolPrimitiveBroker`: declared model/network/program/secret reach, one raw receive for fetch and held connections, programs over stdio, keyring secrets inserted at the edge and reply redaction (stream-piece boundaries may expose up to three leading secret bytes before the remainder is redacted), admitted-model thoughts (optional app tools and an existing routing surface, canonical tool-turn owner, same restricted host and caller limits) and fetch, the run's one screen watch and its hands; DNS handles remain owned until actual synchronous exit after cancellation/close, late results open nothing, and fetch timeout reports an unknown outcome; one arrival buffer per held thing that program and network reads take (one text-or-base64 shape), each arrival on which posts a resident ability's `held` signal; no file executor |

/// Declared-reach primitives for the shared JavaScript executor.
actor ToolPrimitiveBroker {
    static let readOperations = Set(AuthoredToolEffects.primitiveCapabilities.compactMap { $0.value.contains("safe_read") ? $0.key : nil })
    static let operations = Set(AuthoredToolEffects.primitiveCapabilities.keys.filter { $0.hasPrefix("network.") || $0.hasPrefix("program.") })
        .union(["model.call", "fetch", "screen.watch"]).union(frameOperations).union(AuthoredToolEffects.handOperations)
    /// Reads inside the run's admitted watch: no admission and no receipt of their own.
    static let frameOperations: Set<String> = ["screen.next", "frame.read"]
    /// Reading or ending a program it started: inside its admitted start, no ledger row of its own. A send is an effect and is recorded as one.
    static let programOperations: Set<String> = ["program.receive", "program.close"]
    static func readOnly(_ operation: String, _ arguments: JSONValue) -> Bool {
        if operation == "model.call" {
            let tools = Parts.fields(arguments)["tools"]
            return tools == nil || tools == .array([])
        }
        return AuthoredToolEffects.primitiveEffect(operation, arguments: arguments).capabilities.contains("safe_read")
    }
    private let permissions: Set<String>
    private let abilityID: String
    /// The store whose signal wakes a resident ability: what it holds outlives each run, and what arrives on it between runs wakes it (`held`).
    private let held: AbilityStore?
    private var connections: [String: NWConnection] = [:]
    private var listeners: [String: NWListener] = [:]
    private let queue = DispatchQueue(label: "nativeagent.authored.network")
    /// What reached each held thing and was not read yet, in order: the one buffer its reads take from. A connection reads its next piece only once the last was taken; what ended a thing reads again.
    private var inbox: [String: [Arrival]] = [:]
    private var ended: [String: Arrival] = [:]
    private var readers: [String: (token: Int, reader: CheckedContinuation<Arrival?, Error>)] = [:]
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
    /// Non-cooperative system DNS stays accounted for until getaddrinfo exits, including after the caller's response deadline or broker close.
    private var lookups: [UUID: Task<[String], Error>] = [:]
    private static let byteLimit = 4 * 1024 * 1024
    /// The run's one watch (a second replaces the first), and the receipts of those that ended.
    private var watch: MacScreenWatch?
    private var watched: [JSONValue] = []
    private var abilityObserver: (any NSObjectProtocol)?
    /// Every secret value this run inserted, redacted from all it reads back; the host each of its connections reached; each stream's redaction.
    private var redactor = SecretRedactor()
    private var hosts: [String: String] = [:]
    private var streams: [String: SecretStream] = [:]
    private var programs: [String: Program] = [:]

    /// A program the ability started, alive until it closes it or what holds it ends (the run, or a resident ability's residency).
    private final class Program {
        let process: Process, input: FileHandle, path: String, identity: String
        let launched: ProcessTreeSnapshot, backlog: Backlog
        /// Ended (closed, or past its output bound) while its entry still says why.
        private(set) var ended = false
        /// The send writing to it, answered when it ends: no run waits on a program that is gone.
        var sending: AsyncThrowingStream<Void, Error>.Continuation?
        static let gone = SenseFailure(code: "program_ended", message: "The program ended and takes no more input.", remedy: Repair.terminal(instruction: "This handle cannot accept more input. Inspect already returned output and effects before deciding whether new work needs program.start; do not resend the previous input."))
        init(process: Process, input: FileHandle, path: String, identity: String, launched: ProcessTreeSnapshot, backlog: Backlog) {
            self.process = process; self.input = input; self.path = path; self.identity = identity
            self.launched = launched; self.backlog = backlog
        }
        /// Ended as the shell ends a command it stops: the tree from its launch, rescanned and killed under the reaper's identity checks. A program that detached into its own session outlives it, as from the shell.
        func end() {
            ended = true
            ProcessTreeReaper.quiesceAndKill(ProcessTreeReaper.snapshot(rootPID: process.processIdentifier, retaining: launched))
            input.writeabilityHandler = nil
            sending?.finish(throwing: Self.gone); sending = nil
            try? input.close()
        }

        /// Output written and not yet read, bounded: past the bound nothing more is kept, the program ends, and the next read says so.
        final class Backlog: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes = 0, over = false
            /// Whether to keep this piece; false once the bound was passed.
            func keep(_ count: Int, bound: Int) -> (keep: Bool, crossed: Bool) {
                lock.withLock {
                    guard !over else { return (false, false) }
                    bytes += count
                    over = bytes > bound
                    return (!over, over)
                }
            }
            func read(_ count: Int) { lock.withLock { bytes -= count } }
        }
    }

    init(permissions: Set<String>, abilityID: String, held: AbilityStore? = nil) {
        self.permissions = permissions
        self.abilityID = abilityID; self.held = held
    }

    func check(_ operation: String, arguments: JSONValue) throws {
        try Task.checkCancellation()
        guard !closed, Self.operations.contains(operation), case .object(let args) = arguments else {
            if closed { throw CancellationError() }
            throw Self.inputFailure("invalid_primitive", field: "operation/arguments", accepted: "operation: \(Self.operations.sorted().joined(separator: ", ")); arguments: a JSON object")
        }
        if let name = Keyring.names(in: arguments).first(where: { !permissions.contains("secret:" + $0) }) {
            throw Parts.revisionFailure("undeclared", "Declare reach.capabilities secret:\(name) to use {{secret:\(name)}} in ability \(abilityID).", id: abilityID)
        }
        if operation.hasPrefix("program.") {
            guard permissions.contains("shell") else {
                throw Parts.revisionFailure("undeclared", "Declare reach.capabilities shell to call \(operation) in ability \(abilityID).", id: abilityID)
            }
            if operation == "program.start" { _ = try text(args, "command") }
        } else if operation.hasPrefix("screen.") || operation.hasPrefix("frame.") || operation.hasPrefix("hand.") {
            let reach = operation.hasPrefix("hand.") ? "hands" : "screen.watch"
            guard permissions.contains(reach) else {
                throw Parts.revisionFailure("undeclared", "Declare reach.capabilities \(reach) to call \(operation) in ability \(abilityID).", id: abilityID)
            }
            if operation == "screen.watch" { _ = try MacScreenWatch.Request(args) }
        } else if operation == "model.call" || operation == "fetch" {
            // Connector credentials are not attached by this broker.
            guard args["connector"] == nil else {
                throw Self.inputFailure("unsupported_connector_argument", field: "connector", accepted: "omitted", detail: operation == "model.call" ? "model.call takes no connector argument; remove it to use the run's admitted model or an existing routing surface." : "fetch takes no connector argument. Use {{secret:<name>}} where the key belongs and declare reach secret:<name>; an unsaved key is requested once on a card.")
            }
            // A fetch to this Mac's own loopback (a local agent's endpoint) is reached as localhost is, and its secret may go there as network.send's does.
            let local = try operation == "fetch" && Self.loopback(Self.destination(args))
            let reach = operation == "model.call" ? "model" : local ? "network_localhost" : "network_public"
            guard permissions.contains(reach) else {
                throw Parts.revisionFailure("undeclared", "Declare reach.capabilities \(reach) to call \(operation) in ability \(abilityID).", id: abilityID)
            }
        } else {
            guard !permissions.isDisjoint(with: ["network", "network_public", "network_localhost"]) else {
                throw denied("\(operation) has no declared network reach.", "Declare network_localhost for loopback, network_public for public outbound connections, or network for inbound and outbound reach.")
            }
            if operation == "network.connect", args["path"] != nil {
                // A socket path is a stream on this Mac, reached as localhost is.
                _ = try text(args, "path")
                guard !permissions.isDisjoint(with: ["network", "network_localhost"]) else {
                    throw denied("A socket path needs loopback reach.", "Declare reach.capabilities network_localhost before opening this socket path.")
                }
                guard args["host"] == nil, args["port"] == nil, args["tls"] == nil, args["transport"] == nil else {
                    throw Self.inputFailure("invalid_socket_arguments", field: "path", accepted: "{path: string}, without host, port, tls or transport")
                }
            } else if operation == "network.connect" || operation == "network.listen" {
                let local = Self.loopback(try text(args, "host"))
                guard permissions.contains("network") || local && permissions.contains("network_localhost")
                    || operation == "network.connect" && !local && permissions.contains("network_public") else {
                    throw denied("\(operation) host is outside the declared reach.", "Declare network_localhost for loopback, network_public for public outbound connections, or network for listening beyond loopback; keep the reviewed version.")
                }
                _ = try port(args, zero: operation == "network.listen")
                guard !(args["transport"] == .string("udp") && args["tls"] == .bool(true)) else {
                    throw Self.inputFailure("invalid_tls_transport", field: "tls/transport", accepted: "tls:true over TCP, or transport:udp without tls:true")
                }
            }
        }
    }

    /// One primitive, through the door of the run that called it.
    func perform(_ operation: String, arguments: JSONValue, host: any OwnedProgramToolHost,
                 profile: (any OwnedProgramHostProfile)? = nil) async throws -> JSONValue {
        try check(operation, arguments: arguments)
        let args = Parts.fields(arguments)
        if operation == "model.call" { return try await model(args, host: host, profile: profile) }
        if operation != "screen.watch", operation.hasPrefix("screen.") || operation.hasPrefix("frame.") || operation.hasPrefix("hand.") {
            guard let watch else { throw SenseFailure(code: "no_watch", message: "Call screen.watch({app}) before \(operation).") }
            switch operation {
            case "screen.next":
                let timeout: Double? = switch args["timeout"] { case .int(let n)?: Double(n); case .double(let n)?: n; default: nil }
                return try await watch.next(timeout: timeout)
            case "frame.read":
                guard case .int(let generation)? = args["watch"], case .int(let seq)? = args["seq"],
                      case .array(let queries)? = args["queries"] else {
                    throw Self.inputFailure("invalid_frame_read", field: "watch/seq/queries", accepted: "integer watch and seq with an array of queries; call frame.read([...]) on the frame returned by screen.next()")
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
                let host = try Self.destination(args), destination = Keyring.Destination.host(host), keys = ["url", "headers", "body"]
                // The deadline bounds the reply. Outstanding DNS remains owned through actual exit, and its late result opens nothing.
                let wait = try Self.wait(args, default: 120)
                func send(_ given: [String: JSONValue]) async throws -> JSONValue {
                    do { return try await TurnDeadline.withThrowingDeadline(seconds: wait) { try await self.fetch(given, to: host) } }
                    catch is TurnDeadline.DeadlineExceeded {
                        throw SenseFailure(code: "fetch_timeout", message: "fetch had no complete answer from \(host) within \(String(format: "%g", wait)) seconds. Its outcome is unknown; cancellation was requested and outstanding work may still be settling. "
                            + "Inspect the service's state before another request; set wait (seconds, up to 86400) when revising for a slower service.")
                    }
                }
                let (given, sent, grants, _) = try await inserting(args, keys, to: destination)
                var result = try await send(given)
                // A signed-in secret answered 401 is renewed once (unless another run already did) and the request sent once more, under the same grant only: never under one the person made meanwhile.
                if Parts.fields(result)["status"] == .int(401), !sent.isEmpty {
                    let (again, _, _, renewed) = try await inserting(args, keys, to: destination, rejected: sent, grants: grants)
                    if renewed { result = try await send(again) }
                }
                if case .int(let status)? = Parts.fields(result)["status"], status == 429 || (500...599).contains(status) {
                    throw SenseFailure(code: "http_\(status)", message: "fetch returned HTTP \(status) from \(host). Inspect the service's response and state; for 429 reduce request rate, for 5xx address the service failure before another request.")
                }
                return result
            }
            if operation.hasPrefix("program.") { return try await program(operation, args: args, host: host) }
            if operation == "network.receive" { return try await receive(args) }
            var given = args
            if operation == "network.send", given["text"] != nil {
                if !Keyring.names(in: .object(args)).isEmpty {
                    guard let host = hosts[try text(args, "id")] else {
                        throw denied("A secret needs an established TLS connection or admitted TCP loopback. Open one with network.connect before sending it.", "Use network.connect with tls:true or an admitted loopback TCP host; send only on the id it returns.")
                    }
                    given = try await inserting(args, ["text"], to: .host(host)).args
                }
                given["base64"] = .string(try Self.outgoing(given).base64EncodedString())
            }
            if operation == "network.send" {
                // A peer that stops reading never holds a send for good: one it has not taken by `wait` fails, and its connection closes (as a program's ends).
                let wait = try Self.wait(args), id = try text(args, "id"), sending = given
                do { return try await TurnDeadline.withThrowingDeadline(seconds: wait) { try await self.network(operation, args: sending) } }
                catch is TurnDeadline.DeadlineExceeded {
                    _ = try? await network("network.close", args: ["id": .string(id)])
                    throw SenseFailure(code: "timeout", message: "The connection did not take all of this within \(String(format: "%g", wait)) seconds, so it was closed. "
                        + "Pass wait (seconds, up to 86400) for a peer that reads slowly.")
                }
            }
            let result = try await network(operation, args: given)
            guard operation == "network.connect", case .string(let id)? = Parts.fields(result)["id"] else { return result }
            // A secret goes out only on a connection that established TLS, as the transport reports it (or to this Mac by host); udp carries none.
            if let host = Parts.string(args, "host"), args["transport"] != .string("udp"),
               connections[id]?.metadata(definition: NWProtocolTLS.definition) != nil || Self.loopback(host) { hosts[id] = host.lowercased() }
            pump(id)
            return result
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            // What she reads of a failure never carries a value the run inserted.
            throw contextualFailure(error, operation: operation)
        }
    }

    /// The host a fetch goes to, read with each secret's place held. A secret leaves this Mac only encrypted, and never names the host it goes to: read with two stand-ins, the host must be the same.
    private static func destination(_ args: [String: JSONValue]) throws -> String {
        let names = Keyring.names(in: .object(args))
        let urls = try ["secret", "other"].map { stand in
            try Parts.fetchRequest(args.mapValues { $0.mapStrings { insertingSecrets($0, Dictionary(uniqueKeysWithValues: names.map { ($0, stand) }), url: true) } }).url!
        }
        let url = urls[0]
        guard urls[1].host == url.host else {
            throw Self.inputFailure("secret_in_url_host", field: "url", accepted: "a fixed host; place {{secret:<name>}} only in the path or query")
        }
        guard names.isEmpty || url.scheme == "https" || loopback(url.host!) else {
            throw Self.inputFailure("secret_transport_required", field: "url", accepted: "https, or http to admitted loopback on this Mac", detail: "Use an https URL for a secret, or http to admitted loopback on this Mac.")
        }
        return url.host!.lowercased()
    }

    /// Her request with each secret it names inserted, toward one destination its grant names, the values inserted (they join what the run redacts) and their grants, and whether a `rejected` one was renewed under its grant.
    private func inserting(_ args: [String: JSONValue], _ keys: [String], to destination: Keyring.Destination,
                           rejected: [String: String] = [:], grants: [String: Date] = [:]) async throws
        -> (args: [String: JSONValue], values: [String: String], grants: [String: Date], renewed: Bool) {
        let names = Keyring.names(in: .object(args.filter { keys.contains($0.key) }))
        guard !names.isEmpty else { return (args, [:], [:], false) }
        let (values, granted, renewed) = try await Keyring.values(names, to: destination, rejected: rejected, grants: grants)
        redactor.add(values)
        var given = args
        for key in keys { given[key] = given[key]?.mapStrings { insertingSecrets($0, values, url: key == "url") } }
        return (given, values, granted, renewed)
    }

    /// A connection's next piece, in the shape a program's output reads in.
    private func receive(_ args: [String: JSONValue]) async throws -> JSONValue {
        let id = try text(args, "id")
        guard connections[id] != nil else { throw denied("This ability does not own that connection.", "Use an id returned to this ability by network.connect or network.accept; a closed or replaced handle cannot be reused.") }
        let deadline = try Self.deadline(args)
        while true {
            guard let arrival = try await next(id, until: deadline) else { return Self.pending }
            switch arrival {
            case .bytes(let data, _, let end):
                if var piece = piece(id, data, end: end) { piece["eof"] = .bool(end); return .object(piece) }
                if end { return .object(["text": .string(""), "eof": .bool(true)]) }
            case .failed(let error): throw error
            default: throw CancellationError()
            }
        }
    }

    /// A wait that ended with nothing new. What a stream holds back (a split character, the start of a secret) stays held, its matching with it, until the next piece or the end: a timeout never splits a secret.
    private static let pending: JSONValue = .object(["pending": .bool(true), "eof": .bool(false)])

    /// How long a call waits: `wait` seconds, else its default. A read waits that long (30) for something new; a send (30), for its program or connection to take it; a fetch (120), for its whole answer.
    private static func wait(_ args: [String: JSONValue], default given: Double = 30) throws -> Double {
        let wait: Double = switch args["wait"] { case nil: given; case .int(let n)?: Double(n); case .double(let n)?: n; default: -1 }
        guard wait >= 0, wait <= 86_400 else { throw Self.inputFailure("invalid_wait", field: "wait", accepted: "a number of seconds from 0 to 86400") }
        return wait
    }
    private static func deadline(_ args: [String: JSONValue]) throws -> ContinuousClock.Instant { .now + .seconds(try wait(args)) }

    /// One piece read back, redacted, the same from a program and a connection: `text` when it is UTF-8, else `base64` with `binary: true`; nil while there is nothing to show yet.
    private func piece(_ key: String, _ data: Data, end: Bool) -> [String: JSONValue]? {
        let data = streams[key, default: SecretStream()].characters(data, end: end, redactor)
        if data.isEmpty { return nil }
        if let text = String(data: data, encoding: .utf8) { return ["text": .string(text)] }
        return ["base64": .string(data.base64EncodedString()), "binary": .bool(true)]
    }

    /// A program she names, talked to over its standard input and output for as long as she holds it. It launches as any command line does (the shell's access check, its sandbox and the folder it may start in), from the login shell's PATH
    /// and the few variables a command needs (never this app's own environment) plus `env`; a secret goes only to a program its grant names.
    private func program(_ operation: String, args: [String: JSONValue], host: any OwnedProgramToolHost) async throws -> JSONValue {
        if operation == "program.start" {
            let command = try text(args, "command")
            guard let path = AgentHostCommandLines.resolveCommand(command) else {
                throw SenseFailure(code: "program_not_found", message: "\(command) is not an executable path or a program on the login PATH. Set program.start command to the installed executable's absolute path, or install the required program first.")
            }
            // What runs is recorded now, secret or not: a secret goes to a program only as the file it was launched from, as granted.
            guard let identity = AgentHostCommandLines.identity(ofExecutable: path) else {
                throw SenseFailure(code: "program_unreadable", message: "Executable \(path) could not be read. Inspect that file's existence and permissions; repair them or select the intended installed executable in program.start command.")
            }
            let given = try await inserting(args, ["args", "env"], to: .program(path: path, identity: identity)).args
            guard case .array(let rows) = given["args"] ?? .array([]), case .object(let env) = given["env"] ?? .object([:]),
                  Parts.strings(.array(rows)).count == rows.count, JSONValue.object(env).stringFields.count == env.count else {
                throw Self.inputFailure("invalid_program_arguments", field: "args/env", accepted: "args: [string], env: {name: string}")
            }
            var launching: [String: JSONValue] = ["executable": .string(path), "args": .array(rows)]
            launching["cwd"] = args["cwd"]
            let launch = Parts.fields(try await host.performReach("program.launch", arguments: .object(launching)))
            guard let executable = Parts.string(launch, "executable"), let cwd = Parts.string(launch, "cwd") else {
                throw SenseFailure(code: "program_launch_plan_missing", message: "program.launch returned no executable or cwd for \(path). Inspect the shell admission failure; repair that launch plan before starting the program.")
            }
            var environment = AgentHostCommandLines.scrubbedEnvironment().merging(JSONValue.object(env).stringFields) { $1 }
            if let prefix = Parts.string(launch, "path_prefix") { environment["PATH"] = prefix + ":" + (environment["PATH"] ?? "/usr/bin:/bin") }
            // Closed or cancelled during the waits (the ability off or replaced): nothing starts.
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            // Read again after the waits, just before it runs: a file replaced meanwhile never starts as the one recorded.
            guard AgentHostCommandLines.identity(ofExecutable: path) == identity else {
                throw SenseFailure(code: "program_changed", message: "\(path) changed before launch; this program did not start. Inspect the executable now at that path before deciding whether to start it.")
            }
            let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Parts.strings(launch["arguments"])
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            // A write to a program that exited fails as an error, never a signal to the app; one that stops reading never blocks a write (program.send waits instead).
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
                        arrivals.continuation.yield(.failed(SenseFailure(code: "output_limit", message: "The program wrote more than 4 MiB that was not read yet, so it was ended. "
                            + "Read its output as it comes (program.receive), or have it write less.")))
                    }
                }
            }
            let out = try ProcessPipeDrain(handle: output.fileHandleForReading, onData: kept("stdout"))
            let err = try ProcessPipeDrain(handle: errors.fileHandleForReading, onData: kept("stderr"))
            process.terminationHandler = { process in
                // As the shell's runner: what was written is kept, no EOF a background child holds is awaited.
                out.stopAndWait(); err.stopAndWait()
                arrivals.continuation.yield(.exit(process.terminationStatus)); arrivals.continuation.finish()
            }
            do { try process.run() } catch { out.stop(); err.stop(); throw error }
            ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(process.processIdentifier)
            let launched = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
            let id = UUID().uuidString
            programs[id] = Program(process: process, input: input.fileHandleForWriting, path: path, identity: identity, launched: launched, backlog: backlog)
            // What it writes and its exit reach the one buffer in order.
            Task.detached { for await arrival in arrivals.stream { await self.arrive(id, arrival) } }
            return .object(["id": .string(id), "pid": .int(Int64(process.processIdentifier))])
        }
        let id = try text(args, "id")
        guard let program = programs[id] else { throw denied("This ability does not own that program.", "Use the id returned to this ability by program.start; a closed or replaced program cannot be reused.") }
        // Each talk asks the shell's access again: a posture that no longer lets a command line run ends the program.
        do { _ = try await host.performReach("program.access", arguments: .object([:])) }
        catch { endProgram(id); throw error }
        switch operation {
        case "program.send":
            let data = try Self.outgoing(try await inserting(args, ["text"], to: .program(path: program.path, identity: program.identity)).args)
            let wait = try Self.wait(args)
            // One that has not taken all of it by `wait` fails the send, and a failed send ends it (ToolHost.primitive).
            do { try await TurnDeadline.withThrowingDeadline(seconds: wait) { try await self.write(data, to: id) } }
            catch is TurnDeadline.DeadlineExceeded {
                throw SenseFailure(code: "timeout", message: "The program did not take all of this input within \(String(format: "%g", wait)) seconds, so it was ended. "
                    + "Pass wait (seconds, up to 86400) for a program that reads its input slowly.")
            }
            return .object(["bytes": .int(Int64(data.count))])
        case "program.receive":
            let deadline = try Self.deadline(args)
            while true {
                guard let arrival = try await next(id, until: deadline) else { return Self.pending }
                switch arrival {
                case .bytes(let data, let stream?, _):
                    program.backlog.read(data.count)
                    if var piece = piece(id + stream, data, end: false) {
                        piece["stream"] = .string(stream); piece["eof"] = .bool(false)
                        return .object(piece)
                    }
                case .exit(let status):
                    // What a stream held back (a split character, the start of a secret) reads before the exit, which then reads again.
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
            return .object(["id": .string(id)])
        }
    }

    /// A send's input, written as the program takes it; one that ended takes none.
    private func write(_ data: Data, to id: String) async throws {
        guard let program = programs[id], !program.ended else { throw Program.gone }
        let input = program.input
        try await networkReply(cancel: { input.writeabilityHandler = nil }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
            program.sending = done
            nonisolated(unsafe) var rest = data[...]
            input.writeabilityHandler = { handle in
                let wrote = rest.withUnsafeBytes { Darwin.write(handle.fileDescriptor, $0.baseAddress, $0.count) }, failure = errno
                if wrote < 0, failure != EAGAIN, failure != EINTR {
                    handle.writeabilityHandler = nil
                    return done.finish(throwing: POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO))
                }
                rest = rest.dropFirst(max(wrote, 0))
                if rest.isEmpty { handle.writeabilityHandler = nil; done.yield(()); done.finish() }
            }
        }
    }

    private func endProgram(_ id: String) {
        programs.removeValue(forKey: id)?.end()
        forget(id)
    }

    /// What a send writes: its text, or its base64 bytes, at most 4 MiB.
    private static func outgoing(_ args: [String: JSONValue]) throws -> Data {
        guard args["text"] != nil else { return try data(args) }
        guard case .string(let text)? = args["text"], !text.isEmpty, text.utf8.count <= byteLimit else {
            throw Self.inputFailure("invalid_send_text", field: "text", accepted: "a nonempty UTF-8 string of at most 4 MiB; omit text to send base64 bytes")
        }
        return Data(text.utf8)
    }

    private func model(_ args: [String: JSONValue], host: any OwnedProgramToolHost, profile: (any OwnedProgramHostProfile)?) async throws -> JSONValue {
        // Model primitives own their envelope: both returned data and errors retain the effects of the nested tools, including schema failures.
        var effects = "none"
        do {
        let purpose = try text(args, "purpose").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !purpose.isEmpty else { throw Self.inputFailure("missing_model_purpose", field: "purpose", accepted: "a nonempty string describing why this model call is needed") }
        // Tool thinking admits its requested surface through the canonical owner. It must not require an unrelated Chat pick first.
        if args["tools"] == nil, args["surface"] == nil,
           LLMCallContext.client == nil || LLMCallContext.admittedModel == nil {
            if let admit = SkillRunContext.admitModel { return try await admit { try await self.model(args, host: host, profile: profile) } }
            throw SenseFailure(code: "unavailable", message: "model.call needs the part run's admitted model.")
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
        } else { throw Self.inputFailure("invalid_model_input", field: "prompt/messages", accepted: "a string prompt or a nonempty messages array, exclusively") }
        if let schema = args["schema"] {
            messages.append(.user(try completionPolicy("authored-thought", arguments: [
                String(decoding: try schema.serializedData(pretty: false), as: UTF8.self)])))
        }
        let signal = Parts.fields(SkillRunContext.input ?? .null)["signal"]
        let suffix = if case .string(let signal)? = signal { [signal] } else { [String]() }
        let auditPurpose = (["ability", abilityID, purpose] + suffix).joined(separator: ":")
        let toolNames = try Parts.declaredStrings(args["tools"], name: "model.call tools")
        let surface = Parts.string(args, "surface")
        if args["surface"] != nil, surface?.isEmpty != false {
            throw Self.inputFailure("invalid_model_surface", field: "surface", accepted: "a nonempty existing model-routing surface")
        }
        if let surface, !MODEL_SURFACES.contains(canonicalRoutingSurface(surface)) {
            throw Self.inputFailure("unknown_model_surface", field: "surface", accepted: MODEL_SURFACES.sorted().joined(separator: ", "))
        }
        let (reply, cut) = try await LLMCallContext.$purpose.withValue(auditPurpose) {
            if args["tools"] != nil || args["surface"] != nil {
                guard let profile else { throw SenseFailure(code: "unavailable", message: "Tool-capable thinking requires the part's restricted host.") }
                let thought = await host.think(messages: messages, tools: toolNames, surface: surface, host: profile)
                effects = thought.effects
                return (try thought.output.get(), nil as LLMToolBoundaryReason?)
            }
            guard let client = LLMCallContext.client, let model = LLMCallContext.admittedModel else {
                throw SenseFailure(code: "unavailable", message: "model.call needs the part run's admitted model.")
            }
            return try await LLMCallContext.$systemSegments.withValue(nil) {
            try await ConversationPrefixTelemetry.$sink.withValue(.unmeasuredRequestShape) {
                var reply = ""
                var cut: LLMToolBoundaryReason?
                for try await event in client.streamMessages(messages: messages, system: purpose, model: model,
                    surface: LLMCallContext.surface ?? "chat", tools: nil) {
                    switch event {
                    case .textDelta(let text): reply += text
                    case .toolBoundary(let reason): cut = cut ?? reason
                    default: break
                    }
                }
                return (reply, cut)
            }
            }
        }
        // A reply the stream cut short is not an answer: it comes back as incomplete.
        if let cut {
            throw SenseFailure(code: "incomplete", message: "model.call stopped early (\(cut.rawValue)) after \(reply.count) characters; "
                + "the partial reply is not returned as an answer. Ask for less, or split the request.")
        }
        guard let schema = args["schema"] else { return ToolHost.receipt(.string(reply), effects: effects) }
        let value = try JSONValue.parse(Data(reply.utf8))
        try value.validate(schema: schema)
        return ToolHost.receipt(value, effects: effects)
        } catch {
            var failure = Parts.fields(ToolHost.failure(Task.isCancelled || error is CancellationError ? CancellationError() : contextualFailure(error, operation: "model.call"), effects: effects, execution: "attempted"))
            // A typed error describes its own effects; the thought also owns everything its nested tools already did or left unconfirmed.
            let reported = failure["effects"]
            failure["effects"] = .string(["unknown", "partial", "occurred"].first {
                effects == $0 || reported == .string($0)
            } ?? "none")
            return .object(failure)
        }
    }

    /// `destination` is the host its grant was checked for: the request with its secrets inserted goes there or nowhere.
    private func fetch(_ args: [String: JSONValue], to destination: String) async throws -> JSONValue {
        let request = try Parts.fetchRequest(args)
        let url = request.url!, host = url.host!, tls = url.scheme?.lowercased() == "https"
        guard host.lowercased() == destination else { throw denied("With its secrets in, this fetch no longer goes to \(destination); nothing was sent.", "Keep the destination host fixed; put secret placeholders in the URL path, query, headers or body.") }
        let connected = try await network("network.connect", args: ["host": .string(host),
            "port": .int(Int64(url.port ?? (tls ? 443 : 80))), "tls": .bool(tls), "publicOnly": .bool(!Self.loopback(host))])
        let id = try text(Parts.fields(connected), "id")
        defer { connections.removeValue(forKey: id)?.cancel() }
        let message = CFHTTPMessageCreateRequest(nil, (request.httpMethod! as CFString), url as CFURL, kCFHTTPVersion1_1).takeRetainedValue()
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            CFHTTPMessageSetHeaderFieldValue(message, key as CFString, value as CFString)
        }
        // An IPv6 literal goes in brackets (RFC 7230 §5.4): URL.host gives it bare.
        let named = host.contains(":") ? "[\(host)]" : host
        CFHTTPMessageSetHeaderFieldValue(message, "Host" as CFString, (url.port == nil ? named : "\(named):\(url.port!)") as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Connection" as CFString, "close" as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Accept-Encoding" as CFString, "identity" as CFString)
        if let body = request.httpBody {
            CFHTTPMessageSetBody(message, body as CFData)
            CFHTTPMessageSetHeaderFieldValue(message, "Content-Length" as CFString, String(body.count) as CFString)
        }
        guard let wire = CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data? else {
            throw SenseFailure(code: "http_request_encoding", message: "fetch could not encode this HTTP request. Correct its URL, method, headers and body in the fetch call.")
        }
        _ = try await network("network.send", args: ["id": .string(id), "base64": .string(wire.base64EncodedString())])
        guard let connection = connections[id] else { throw CancellationError() }
        var received = Data()
        while true {
            guard case .bytes(let chunk, _, let eof) = try await receive(connection) else { throw CancellationError() }
            guard received.count + chunk.count <= Self.byteLimit else {
                throw SenseFailure(code: "output_limit", message: "fetch response exceeds 4 MiB. Request a smaller page or range; inspect service state before another modifying request.")
            }
            received.append(chunk)
            if eof { break }
        }
        guard !received.isEmpty else { throw SenseFailure(code: "http_response_empty", message: "fetch received no HTTP response. Check that the endpoint serves HTTP and inspect service state before another request.") }
        var response = CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
        while true {
            let parsed = received.withUnsafeBytes { bytes in
                CFHTTPMessageAppendBytes(response, bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count)
            }
            guard parsed, CFHTTPMessageIsHeaderComplete(response) else {
                throw SenseFailure(code: "http_response_incomplete", message: "fetch received an incomplete HTTP response. Repair the endpoint's HTTP framing or premature close; inspect service state before another request.")
            }
            if CFHTTPMessageGetResponseStatusCode(response) >= 200 { break }
            guard CFHTTPMessageGetResponseStatusCode(response) != 101,
                  let rest = CFHTTPMessageCopyBody(response)?.takeRetainedValue() as Data?, !rest.isEmpty else {
                throw SenseFailure(code: "http_upgrade_unsupported", message: "fetch received no final HTTP response or a protocol upgrade. Use a final HTTP endpoint, or implement the upgraded protocol with network primitives.")
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
                    throw SenseFailure(code: "http_chunk_invalid", message: "fetch received invalid chunk framing. Repair the service's chunk sizes and CRLF framing; inspect service state before another request.")
                }
                if size == 0 {
                    let trailers = body[line.upperBound...]
                    guard trailers.starts(with: Data("\r\n".utf8)) || trailers.range(of: Data("\r\n\r\n".utf8)) != nil else {
                        throw SenseFailure(code: "http_trailers_incomplete", message: "fetch received incomplete HTTP trailers. Repair the service's trailer terminator; inspect service state before another request.")
                    }
                    break
                }
                cursor = line.upperBound
                data.append(body[cursor..<cursor + size]); cursor += size
                guard body.endIndex - cursor >= 2, body[cursor..<cursor + 2] == Data("\r\n".utf8) else {
                    throw SenseFailure(code: "http_chunk_incomplete", message: "fetch received incomplete chunk framing. Repair the service's chunk lengths and premature close; inspect service state before another request.")
                }
                cursor += 2
            }
        } else if let length = lower["content-length"], Int(length) != data.count {
            throw SenseFailure(code: "http_body_length_mismatch", message: "fetch body length does not match Content-Length. Repair the service's body length or framing; inspect service state before another request.")
        }
        // Header names too, in any case: a service can echo a value back as one.
        return try Parts.fetchReply(status: status, headers: lower, data: data, name: { redactor.name($0) }) { redactor($0) }
    }

    private func denied(_ detail: String, _ fix: String) -> SenseFailure {
        SenseFailure(code: "permission_denied", message: detail, remedy: Repair.remedy(owner: "ability \(abilityID)",
            nextCall: Parts.readCall(abilityID), tap: nil, instruction: fix + " Read this ability before revising its code or reach with ability.save and keeping the reviewed version."))
    }
    static func inputFailure(_ code: String, field: String, accepted: String, detail: String? = nil) -> ToolFailureError {
        ToolFailureError(detail ?? "\(field) must be \(accepted).", argumentPath: field, accepted: accepted, effects: .none,
            code: code, status: .refused, instruction: "Correct \(field) in this primitive call to match accepted.", recovery: .correctArguments)
    }

    private func contextualFailure(_ error: Error, operation: String) -> Error {
        if let owned = error as? ToolFailureError {
            return ToolFailureError(redactor(owned.message), argumentPath: owned.argumentPath.map { redactor($0) }, accepted: owned.accepted.map { redactor($0) }, effects: owned.effects,
                owner: owned.owner.map { redactor($0) }, nextCall: owned.nextCall.map { redactor($0) }, tap: owned.tap.map { redactor($0) }, personDecides: owned.personDecides,
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
                : operation.hasPrefix("program.") ? "Inspect the program's command, retained output and exit before further input. " : "Apply the correction named in the failure. "
            failure.remedy = Repair.reconcile(instruction: fix + "Read ability \(abilityID)'s \(operation) call; revise its code or reach with ability.save and keep the reviewed version. Check external state before repeating an operation with uncertain effects.", nextCall: Parts.readCall(abilityID))
        }
        return failure
    }
    private func text(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard case .string(let text)? = args[key], !text.isEmpty else { throw Self.inputFailure("missing_primitive_field", field: key, accepted: "a nonempty string") }
        return text
    }
    private func port(_ args: [String: JSONValue], zero: Bool) throws -> NWEndpoint.Port {
        guard case .int(let value)? = args["port"], value >= (zero ? 0 : 1), let raw = UInt16(exactly: value),
              let port = NWEndpoint.Port(rawValue: raw) else { throw Self.inputFailure("invalid_network_port", field: "port", accepted: "an integer from \(zero ? 0 : 1) to 65535") }
        return port
    }
    private static func data(_ args: [String: JSONValue]) throws -> Data {
        guard case .string(let base64)? = args["base64"], let data = Data(base64Encoded: base64), data.count <= byteLimit else {
            throw Self.inputFailure("invalid_send_base64", field: "base64", accepted: "a base64 string decoding to at most 4 MiB; alternatively pass nonempty text")
        }
        return data
    }
    /// This Mac's own loopback: exactly localhost, or a loopback IP literal (127.0.0.0/8, ::1, ::ffff:127.x.x.x); never a name that only looks like one.
    private static func loopback(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        return bytes == Array(repeating: 0, count: 15) + [1] || bytes.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] && bytes[12] == 127
    }

    /// DNS runs off the broker. Its requesting call and this handle retain it through actual exit; cancellation cannot interrupt synchronous DNS. A response deadline bounds the answer, and a late lookup connects nowhere.
    private func address(_ host: String, publicOnly: Bool = false) async throws -> String {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let id = UUID()
        let lookup = Task.detached {
            try Task.checkCancellation()
            let addresses = try Self.resolve(host)
            try Task.checkCancellation()
            return addresses
        }
        lookups[id] = lookup
        defer { lookups.removeValue(forKey: id) }
        let addresses = try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() }
        try Task.checkCancellation()
        // Closed while it looked (the ability off or replaced): nothing opens on it.
        guard !closed else { throw CancellationError() }
        // A local destination resolves to this Mac alone; a public one never reaches it.
        guard !publicOnly || addresses.allSatisfy({ !Self.loopback($0) }), !Self.loopback(host) || addresses.allSatisfy(Self.loopback),
              let chosen = addresses.first, permissions.contains("network")
            || addresses.allSatisfy({ Self.loopback($0) ? permissions.contains("network_localhost") : permissions.contains("network_public") }) else {
            throw denied("The resolved address for \(host) is outside the declared network reach.", "Check the host's DNS addresses; use a matching loopback or public host and declare its network reach. A public fetch cannot target loopback.")
        }
        return chosen
    }

    private static func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0, let start = first else {
            throw SenseFailure(code: "dns_resolution_failed", message: "Network host \(host) could not be resolved. Correct the host or repair DNS/network access before connecting.")
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
        return addresses
    }

    private func network(_ operation: String, args: [String: JSONValue]) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        switch operation {
        case "network.connect" where args["path"] != nil:
            let id = UUID().uuidString
            connections[id] = NWConnection(to: .unix(path: try text(args, "path")), using: .tcp)
            try await ready(id)
            guard !closed, connections[id] != nil else { throw CancellationError() }
            return .object(["id": .string(id)])
        case "network.connect", "network.listen":
            let host = try text(args, "host"), address = try await address(host, publicOnly: args["publicOnly"] == .bool(true)), port = try port(args, zero: operation == "network.listen")
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let parameters: NWParameters
            if args["transport"] == .string("udp") { parameters = .udp }
            else if args["tls"] == .bool(true), operation == "network.connect" {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
                parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else { parameters = .tcp }
            let id = UUID().uuidString
            if operation == "network.connect" {
                connections[id] = NWConnection(host: NWEndpoint.Host(address), port: port, using: parameters)
                try await ready(id)
                guard !closed, connections[id] != nil else { throw CancellationError() }
                return .object(["id": .string(id)])
            }
            guard permissions.contains("network") || Self.loopback(address) && permissions.contains("network_localhost") else {
                throw denied("Listening requires the declared inbound network reach.", "Declare network_localhost for a loopback listener or network for a listener beyond loopback.")
            }
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
            let listener = try NWListener(using: parameters, on: port)
            listeners[id] = listener
            listener.newConnectionHandler = { connection in Task { await self.incoming(connection, listener: id) } }
            try await networkReply(cancel: { listener.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
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
            guard listeners[id] != nil else { throw denied("This ability does not own that listener.", "Use the id returned to this ability by network.listen; a closed listener cannot be reused.") }
            guard let arrival = try await next(id, until: try Self.deadline(args)) else { return .object(["pending": .bool(true)]) }
            switch arrival {
            case .accepted(let accepted):
                try await ready(accepted)
                pump(accepted)
                return .object(["id": .string(accepted)])
            case .failed(let error): throw error
            default: throw CancellationError()
            }
        case "network.send":
            let id = try text(args, "id")
            guard let connection = connections[id] else { throw denied("This ability does not own that connection.", "Use an id returned to this ability by network.connect or network.accept; a closed connection cannot be reused.") }
            let data = try Self.data(args)
            try await networkReply(cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { done.finish(throwing: error) } else { done.yield(()); done.finish() }
                })
            }
            return .object(["bytes": .int(Int64(data.count))])
        case "network.close":
            let id = try text(args, "id")
            if let connection = connections.removeValue(forKey: id) { connection.cancel() }
            else if let listener = listeners.removeValue(forKey: id) {
                listener.cancel()
                // Connections it received and no accept took go with it.
                for case .accepted(let key) in inbox[id] ?? [] { connections.removeValue(forKey: key)?.cancel() }
            }
            else { throw denied("This ability does not own that network handle.", "Use a connection or listener id opened by this ability; a closed handle cannot be reused.") }
            hosts[id] = nil; forget(id)
            return .object(["id": .string(id)])
        default: throw Self.inputFailure("unknown_network_primitive", field: "operation", accepted: "network.connect, listen, accept, send, receive or close")
        }
    }

    private func incoming(_ connection: NWConnection, listener id: String) {
        guard !closed, listeners[id] != nil, (inbox[id] ?? []).count < OwnedProgramRunner.actionLimit else { connection.cancel(); return }
        let key = UUID().uuidString
        connections[key] = connection
        arrive(id, .accepted(key))
    }

    /// Opens a connection; one that does not open is cancelled and let go.
    private func ready(_ id: String) async throws {
        guard let connection = connections[id] else { throw CancellationError() }
        do {
            try await networkReply(cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
                connection.stateUpdateHandler = { state in
                    if case .ready = state { done.yield(()); done.finish() }
                    // Nothing there to reach (refused, no such socket) fails now rather than waiting on.
                    if case .waiting(let error) = state { done.finish(throwing: error) }
                    if case .failed(let error) = state { done.finish(throwing: error) }
                    if case .cancelled = state { done.finish(throwing: CancellationError()) }
                }
                connection.start(queue: self.queue)
            }
        } catch {
            connections.removeValue(forKey: id)?.cancel()
            throw error
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

    // MARK: - What it holds, and what arrives on it

    /// Something reached a held thing: an ability that holds it across runs is woken (EnginePartWake runs it one at a time and folds the same news waiting twice into one). A read waiting on it takes it; else it waits in the buffer reads
    /// take from.
    private func arrive(_ id: String, _ arrival: Arrival) {
        guard !closed, connections[id] != nil || programs[id] != nil || listeners[id] != nil else { return }
        // A program fails only past its output bound: it ends now, the failure kept for its next read.
        if case .failed = arrival { programs[id]?.end() }
        announce(id)
        if let waiting = readers.removeValue(forKey: id) { return waiting.reader.resume(returning: arrival) }
        inbox[id, default: []].append(arrival)
    }

    private func announce(_ id: String) {
        let kind = programs[id] != nil ? "program" : listeners[id] != nil ? "listener" : "connection"
        held?.signal("held", part: abilityID, ["id": .string(id), "kind": .string(kind)])
    }

    /// The next arrival on a held thing, in order, waiting for one until `deadline` (nil when it passed with nothing new); once it ended, what ended it, again.
    private func next(_ id: String, until deadline: ContinuousClock.Instant) async throws -> Arrival? {
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
            var timer: Task<Void, Never>?
            defer { timer?.cancel() }
            let came = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (reader: CheckedContinuation<Arrival?, Error>) in
                    if closed || Task.isCancelled { return reader.resume(throwing: CancellationError()) }
                    readers[id] = (token, reader)
                    // The caller's own wait: the read answers when something comes or it ends.
                    timer = Task { try? await Task.sleep(until: deadline, clock: .continuous); self.endRead(id, token, nil) }
                }
            } onCancel: { Task { await self.endRead(id, token, CancellationError()) } }
            guard let came else { return nil }
            arrival = came
        }
        ProviderStreamContext.activity?()
        if arrival.ends { ended[id] = arrival } else { pump(id) }
        return arrival
    }

    private func endRead(_ id: String, _ token: Int, _ error: Error?) {
        guard readers[id]?.token == token, let waiting = readers.removeValue(forKey: id) else { return }
        if let error { waiting.reader.resume(throwing: error) } else { waiting.reader.resume(returning: nil) }
    }

    /// A connection she holds keeps one read outstanding while nothing of it waits unread, so what comes on it arrives, bounded to one piece.
    private func pump(_ id: String) {
        guard let connection = connections[id], !pumping.contains(id), ended[id] == nil, inbox[id]?.isEmpty ?? true else { return }
        pumping.insert(id)
        Task.detached { await self.pumped(id, connection) }
    }

    private func pumped(_ id: String, _ connection: NWConnection) async {
        let arrival: Arrival
        do { arrival = try await receive(connection) } catch { arrival = .failed(error) }
        pumping.remove(id)
        arrive(id, arrival)
    }

    private func receive(_ connection: NWConnection) async throws -> Arrival {
        try await networkReply(cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Arrival, Error>.Continuation) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.byteLimit) { data, _, complete, error in
                if let error { done.finish(throwing: error) } else { done.yield(.bytes(data ?? Data(), stream: nil, eof: complete)); done.finish() }
            }
        }
    }

    /// A held thing closed: what waited on it goes with it.
    private func forget(_ id: String) {
        inbox[id] = nil; ended[id] = nil; pumping.remove(id)
        for key in [id, id + "stdout", id + "stderr"] { streams[key] = nil }
        readers.removeValue(forKey: id)?.reader.resume(throwing: CancellationError())
    }

    /// A run of the ability began: the watch it opens is its own.
    func begin() { running += 1 }

    /// A run ended; returns the receipts of its watches. What a resident ability holds stays held; anything else's reach ends with the run.
    @discardableResult func finish() -> [JSONValue] {
        guard held != nil else { return close() }
        running -= 1
        guard running == 0 else { return [] }
        endWatch("run_ended")
        defer { watched = [] }
        return watched
    }

    /// Ends the program a call names, when the ability holds one.
    func end(_ arguments: JSONValue) {
        if let id = Parts.string(Parts.fields(arguments), "id"), programs[id] != nil { endProgram(id) }
    }

    /// Ends everything it holds; returns the receipts of its watches.
    @discardableResult func close() -> [JSONValue] {
        closed = true
        for lookup in lookups.values { lookup.cancel() }
        for connection in connections.values { connection.cancel() }
        for listener in listeners.values { listener.cancel() }
        for program in programs.values { program.end() }
        for waiting in readers.values { waiting.reader.resume(throwing: CancellationError()) }
        connections.removeAll(); listeners.removeAll(); programs.removeAll(); readers.removeAll(); inbox.removeAll(); ended.removeAll()
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

import AuthoredCapabilities
import Foundation
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
import ToolRegistry
import Senses
import Network
import Security
import ProviderRouting
import CFNetwork
import MacControl
// Blueprint: | `ToolExecution+RunSandbox.swift` | `ToolPrimitiveBroker`, `held`: declared reach; retained transport settlement |

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
        var result: Result<Arrival?, Error>?
    }
    private var readers: [String: (token: Int, read: Read)] = [:]

    private func complete(_ read: Read, _ result: Result<Arrival?, Error>) {
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
    /// Non-cooperative system DNS stays accounted for until getaddrinfo exits, including after the caller's response deadline or broker close.
    private var lookups: [UUID: (task: Task<[String], Error>, fetch: Bool)] = [:]
    /// Admitted requests own their transport and settlement beyond the run's response wait.
    private var fetches: [UUID: Task<Void, Never>] = [:]
    private var fetchConnections: Set<String> = []
    private static let byteLimit = 4 * 1024 * 1024
    /// A run owns one current watch; keep receipts when it ends.
    private var watch: MacScreenWatch?
    private var watched: [JSONValue] = []
    private var abilityObserver: (any NSObjectProtocol)?
    /// All inserted secrets must be redacted from readback, including connection and stream forms.
    private var redactor = SecretRedactor()
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
        final class Backlog: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes = 0, over = false
            /// Stop retaining pieces once the output bound is exceeded.
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

    init(permissions: Set<String>, abilityID: String, dataRoot: URL, held: AbilityStore? = nil) {
        self.permissions = permissions
        self.dataRoot = dataRoot
        self.abilityID = abilityID; self.held = held
    }

    func check(_ operation: String, arguments: JSONValue) throws {
        try Task.checkCancellation()
        guard !closed, Self.operations.contains(operation), case .object(let args) = arguments else {
            if closed { throw CancellationError() }
            throw Self.inputFailure("invalid_primitive", field: "operation/arguments",
                accepted: "operation: \(Self.operations.sorted().joined(separator: ", ")); arguments: a JSON object")
        }
        if let name = Keyring.names(in: arguments).first(where: { !permissions.contains("secret:" + $0) }) {
            throw Parts.revisionFailure("undeclared", "Declare reach.capabilities secret:\(name) to use {{secret:\(name)}} in ability \(abilityID).",
                id: abilityID)
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
            if operation.hasPrefix("hand."), let refusal = watch?.handRefusal { throw refusal }
        } else if operation == "model.call" || operation == "fetch" {
            // Connector credentials cannot be attached implicitly.
            guard args["connector"] == nil else {
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
            // A fetch to this Mac's own loopback (a local agent's endpoint) is reached as localhost is, and its secret may go there as network.send's does.
            let local = try operation == "fetch" && Self.loopback(Self.destination(args))
            let reach = operation == "model.call" ? "model" : local ? "network_localhost" : "network_public"
            guard permissions.contains(reach) else {
                throw Parts.revisionFailure("undeclared", "Declare reach.capabilities \(reach) to call \(operation) in ability \(abilityID).", id: abilityID)
            }
        } else {
            guard !permissions.isDisjoint(with: ["network", "network_public", "network_localhost"]) else {
                throw denied("\(operation) has no declared network reach.",
                    "Declare network_localhost for loopback, network_public for public outbound connections, or network for inbound and outbound reach.")
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

    /// Every primitive must pass its run's gated host.
    func perform(_ operation: String, arguments: JSONValue, host: any OwnedProgramToolHost,
                 profile: (any OwnedProgramHostProfile)? = nil, execution: OwnedProgramExecution,
                 openScreenWatch: (@Sendable (MacScreenWatch.Request, Bool) async throws -> MacScreenWatch)?) async throws -> JSONValue {
        try check(operation, arguments: arguments)
        let args = Parts.fields(arguments)
        if operation == "model.call" { return try await model(args, host: host, profile: profile, execution: execution) }
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
                return try await watch.read(watch: Int(generation), seq: Int(seq), queries: queries)
            default: return try await watch.hand(String(operation.dropFirst("hand.".count)), args,
                context: execution.macOperation(dataRoot: dataRoot))
            }
        }
        if operation == "screen.watch" {
            guard let open = openScreenWatch else {
                throw SenseFailure(code: "unavailable", message: "screen.watch needs the app door of a conversation or wake run.")
            }
            let opened = try await open(try MacScreenWatch.Request(args), permissions.contains("hands"))
            guard !closed else { opened.end("run_ended"); throw CancellationError() }
            endWatch("replaced")
            watch = opened
            // A changed/disabled part cannot keep watching under an earlier admission.
            let id = abilityID
            abilityObserver = NotificationCenter.default.addObserver(forName: AbilityStore.didChange, object: nil, queue: nil) { change in
                if (change.object as? String).map({ URL(fileURLWithPath: $0).lastPathComponent }) == id { opened.end("part_changed") }
            }
            return opened.opened
        }
        do {
            if operation == "fetch" {
                let host = try Self.destination(args), destination = Keyring.Destination.host(host), keys = ["url", "headers", "body"]
                let wait = try Self.wait(args, default: 120)
                func send(_ given: [String: JSONValue]) async throws -> JSONValue {
                    try await self.sendFetch(given, to: host, wait: wait, execution: execution)
                }
                let (given, sent, grants, _) = try await inserting(args, keys, to: destination)
                var result = try await send(given)
                // Renew/retry a rejected secret only once under the same unchanged grant; another account's concurrent grant cannot authorize resend.
                if Parts.fields(result)["status"] == .int(401), !sent.isEmpty {
                    let (again, _, _, renewed) = try await inserting(args, keys, to: destination, rejected: sent, grants: grants)
                    if renewed { result = try await send(again) }
                }
                if case .int(let status)? = Parts.fields(result)["status"], status == 429 || (500...599).contains(status) {
                    throw SenseFailure(code: "http_\(status)", message: """
                        fetch returned HTTP \(status) from \(host). Inspect the service's response and state; for 429 reduce request rate, for 5xx \
                        address the service failure before another request.
                        """)
                }
                return result
            }
            if operation.hasPrefix("program.") { return try await program(operation, args: args, host: host, execution: execution) }
            if operation == "network.receive" { return try await receive(args, onActivity: execution.onActivity) }
            var given = args
            if operation == "network.send", given["text"] != nil {
                if !Keyring.names(in: .object(args)).isEmpty {
                    guard let host = hosts[try text(args, "id")] else {
                        throw denied(
                            "A secret needs an established TLS connection or admitted TCP loopback. Open one with network.connect before sending it.",
                                "Use network.connect with tls:true or an admitted loopback TCP host; send only on the id it returns.")
                    }
                    given = try await inserting(args, ["text"], to: .host(host)).args
                }
                given["base64"] = .string(try Self.outgoing(given).base64EncodedString())
            }
            if operation == "network.send" {
                // Bound sends to non-reading peers and close their connection when the wait expires.
                let wait = try Self.wait(args), id = try text(args, "id"), sending = given
                do { return try await TurnDeadline.withThrowingDeadline(seconds: wait, deadlines: execution.deadlines) { _ in
                    try await self.network(operation, args: sending, onActivity: execution.onActivity)
                } }
                catch is TurnDeadline.DeadlineExceeded {
                    _ = try? await network("network.close", args: ["id": .string(id)], onActivity: execution.onActivity)
                    throw SenseFailure(code: "timeout",
                        message: "The connection did not take all of this within \(String(format: "%g", wait)) seconds, so it was closed. "
                        + "Pass wait (seconds, up to 86400) for a peer that reads slowly.")
                }
            }
            let result = try await network(operation, args: given, onActivity: execution.onActivity)
            guard operation == "network.connect", case .string(let id)? = Parts.fields(result)["id"] else { return result }
            // A secret goes out only on a connection that established TLS, as the transport reports it (or to this Mac by host); udp carries none.
            if let host = Parts.string(args, "host"), args["transport"] != .string("udp"),
               connections[id]?.metadata(definition: NWProtocolTLS.definition) != nil || Self.loopback(host) { hosts[id] = host.lowercased() }
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
    private static func destination(_ args: [String: JSONValue]) throws -> String {
        let names = Keyring.names(in: .object(args))
        let urls = try ["secret", "other"].map { stand in
            try Parts.fetchRequest(args.mapValues { $0.mapStrings { insertingSecrets($0, Dictionary(uniqueKeysWithValues: names.map { ($0, stand) }),
                url: true) } }).url!
        }
        let url = urls[0]
        guard urls[1].host == url.host else {
            throw Self.inputFailure("secret_in_url_host", field: "url", accepted: "a fixed host; place {{secret:<name>}} only in the path or query")
        }
        guard names.isEmpty || url.scheme == "https" || loopback(url.host!) else {
            throw Self.inputFailure("secret_transport_required", field: "url", accepted: "https, or http to admitted loopback on this Mac",
                detail: "Use an https URL for a secret, or http to admitted loopback on this Mac.")
        }
        return url.host!.lowercased()
    }

    /// Insert secrets only toward their granted destination and retain values/grants for redaction and same-grant renewal checks.
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

    /// Connections and programs must expose the same output shape.
    private func receive(_ args: [String: JSONValue], onActivity: (@Sendable () -> Void)?) async throws -> JSONValue {
        let id = try text(args, "id")
        guard connections[id] != nil else { throw denied("This ability does not own that connection.",
            "Use an id returned to this ability by network.connect or network.accept; a closed or replaced handle cannot be reused.") }
        let deadline = try Self.deadline(args)
        while true {
            guard let arrival = try await next(id, until: deadline, onActivity: onActivity) else { return Self.pending }
            switch arrival {
            case .bytes(let data, _, let end):
                if var piece = piece(id, data, end: end) { piece["eof"] = .bool(end); return .object(piece) }
                if end { return .object(["text": .string(""), "eof": .bool(true)]) }
            case .failed(let error): throw error
            default: throw CancellationError()
            }
        }
    }

    /// A read timeout must retain split characters and secret prefixes until more bytes or terminal evidence arrives.
    private static let pending: JSONValue = .object(["pending": .bool(true), "eof": .bool(false)])

    /// Response waits are bounded: read/send default to 30 seconds and whole fetches to 120.
    private static func wait(_ args: [String: JSONValue], default given: Double = 30) throws -> Double {
        let wait: Double = switch args["wait"] { case nil: given; case .int(let n)?: Double(n); case .double(let n)?: n; default: -1 }
        guard wait >= 0, wait <= 86_400 else { throw Self.inputFailure("invalid_wait", field: "wait", accepted: "a number of seconds from 0 to 86400") }
        return wait
    }
    private static func deadline(_ args: [String: JSONValue]) throws -> ContinuousClock.Instant { .now + .seconds(try wait(args)) }

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
            let given = try await inserting(args, ["args", "env"], to: .program(path: path, identity: identity)).args
            guard case .array(let rows) = given["args"] ?? .array([]), case .object(let env) = given["env"] ?? .object([:]),
                  Parts.strings(.array(rows)).count == rows.count, JSONValue.object(env).stringFields.count == env.count else {
                throw Self.inputFailure("invalid_program_arguments", field: "args/env", accepted: "args: [string], env: {name: string}")
            }
            var launching: [String: JSONValue] = ["executable": .string(path), "args": .array(rows)]
            launching["cwd"] = args["cwd"]
            let launch = Parts.fields(try await host.performReach("program.launch", arguments: .object(launching), execution: execution))
            guard let executable = Parts.string(launch, "executable"), let cwd = Parts.string(launch, "cwd") else {
                throw SenseFailure(code: "program_launch_plan_missing", message: """
                    program.launch returned no executable or cwd for \(path). Inspect the shell admission failure; repair that launch plan before \
                    starting the program.
                    """)
            }
            var environment = AgentHostCommandLines.scrubbedEnvironment().merging(JSONValue.object(env).stringFields) { $1 }
            if let prefix = Parts.string(launch, "path_prefix") { environment["PATH"] = prefix + ":" + (environment["PATH"] ?? "/usr/bin:/bin") }
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
            process.arguments = Parts.strings(launch["arguments"])
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
        switch operation {
        case "program.send":
            let data = try Self.outgoing(try await inserting(args, ["text"], to: .program(path: program.path, identity: program.identity)).args)
            let wait = try Self.wait(args)
            // A send timeout fails the send and ends its program.
            do { try await TurnDeadline.withThrowingDeadline(seconds: wait, deadlines: execution.deadlines) { _ in
                try await self.write(data, to: id, onActivity: onActivity)
            } }
            catch is TurnDeadline.DeadlineExceeded {
                throw SenseFailure(code: "timeout",
                    message: "The program did not take all of this input within \(String(format: "%g", wait)) seconds, so it was ended. "
                    + "Pass wait (seconds, up to 86400) for a program that reads its input slowly.")
            }
            return .object(["bytes": .int(Int64(data.count))])
        case "program.receive":
            let deadline = try Self.deadline(args)
            while true {
                guard let arrival = try await next(id, until: deadline, onActivity: onActivity) else { return Self.pending }
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
        let surface = Parts.string(args, "surface")
        if args["surface"] != nil, surface?.isEmpty != false {
            throw Self.inputFailure("invalid_model_surface", field: "surface", accepted: "a nonempty existing model-routing surface")
        }
        if let surface, !MODEL_SURFACES.contains(canonicalRoutingSurface(surface)) {
            throw Self.inputFailure("unknown_model_surface", field: "surface", accepted: MODEL_SURFACES.sorted().joined(separator: ", "))
        }
        let (reply, cut) = try await { () async throws -> (String, LLMToolBoundaryReason?) in
            if args["tools"] != nil || args["surface"] != nil {
                guard let profile else { throw SenseFailure(code: "unavailable", message: "Tool-capable thinking requires the part's restricted host.") }
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

    /// The response wait never owns the request. Only its wall-clock transport ceiling cancels it; actual exit and the one durable outcome are joined even
    /// when DNS cannot be interrupted.
    private func sendFetch(_ args: [String: JSONValue], to destination: String, wait: Double, execution: OwnedProgramExecution) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let token = UUID(), reply = ContinuationOnce<Result<JSONValue, Error>>()
        let id = "fetch:" + token.uuidString.lowercased(), root = dataRoot, part = abilityID
        let transportLimit = max(600, wait)
        // Reads leave no durable effect receipt; writes need one so an unknown outcome cannot be blindly repeated.
        let keepsRecord = !["GET", "HEAD"].contains((args["method"]?.stringValue ?? "GET").uppercased())
        let cause = execution.turn.map { [$0.id] } ?? []
        // Experience is the advisory projection; the request owns its raw receipt below.
        if keepsRecord {
            ExperienceStore.record(root, id) { store in
                try await store.begin(Experience(id: id, kind: .act, cause: cause,
                    face: .init(words: "Fetch for ability \(part) is awaiting its transport outcome.", artifacts: []),
                    owes: ["finish": .init(to: "self")],
                    claims: RepairDebt(owner: "ability " + part, operation: id).claims))
            }
        }
        // No suspension between admission and handing ownership to the retained task.
        fetches[token] = Task.detached {
            let body = TurnBodyLifetime<JSONValue>()
            let outcome: Result<JSONValue, Error>
            do {
                // The retained transport owns its ceiling independently of the caller's response wait.
                let value = try await TurnDeadline.withThrowingDeadline(seconds: transportLimit, clock: .wallClock, deadlines: .init()) { _ in
                    try await body.run { try await self.fetch(args, to: destination, onActivity: execution.onActivity) }
                }
                outcome = .success(value)
            } catch {
                let failure = error
                let actual = await body.finish()
                switch actual {
                case .success(let value)?: outcome = .success(value)
                case .failure(let error)? where !(error is CancellationError): outcome = .failure(error)
                default:
                    outcome = .failure(failure is TurnDeadline.DeadlineExceeded
                        ? SenseFailure(code: "fetch_transport_timeout", message: """
                            Fetch \(id) reached its \(String(format: "%g", transportLimit))-second transport ceiling. Its transport was cancelled and \
                            joined; service effects remain unknown. Inspect its receipt and service state before another request.
                            """)
                        : failure)
                }
            }
            let settled = await settle {
                await self.settleFetch(outcome, id: id, keepsRecord: keepsRecord)
            }
            reply.resume(settled)
            await self.finishedFetch(token)
        }
        do {
            return try await TurnDeadline.withThrowingDeadline(seconds: wait, clock: .wallClock, deadlines: execution.deadlines) { _ in
                let budget = OperationWaitBudget(deadline: execution.deadline)
                return try await reply.wait(budget: budget, cancellingWith: .failure(budget.cancellationError)).get()
            }
        } catch is TurnDeadline.DeadlineExceeded where !keepsRecord {
            throw SenseFailure(code: "fetch_timeout", message: """
                The read from \(destination) had no complete answer within \(String(format: "%g", wait)) seconds. A read changes nothing, so it is safe \
                to repeat; set wait (seconds, up to 86400) for a slower service.
                """)
        } catch is TurnDeadline.DeadlineExceeded {
            throw SenseFailure(code: "fetch_timeout", message: """
                fetch had no complete answer from \(destination) within \(String(format: "%g", wait)) seconds. Its outcome is unknown; the request \
                remains owned under its \(String(format: "%g", transportLimit))-second transport limit.\u{20}
                """
                + """
                    Read experience \(id) for its eventual response or failure and inspect service state before another request. Set wait (seconds, up to \
                    86400) for a slower service.
                    """)
        } catch is CancellationError {
            throw SenseFailure(code: "fetch_wait_cancelled", message: """
                The fetch response wait ended. Its outcome is unknown; the admitted request still owns settlement. Read experience \(id) and inspect \
                service state before another request.
                """)
        } catch is OperationWaitBudget.Exceeded {
            throw SenseFailure(code: "fetch_timeout", message: """
                The enclosing call's response deadline ended. The fetch outcome is unknown; the admitted request still owns settlement. Read experience \
                \(id) and inspect service state before another request.
                """)
        }
    }

    private func finishedFetch(_ token: UUID) { fetches[token] = nil }

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
    private func fetch(_ args: [String: JSONValue], to destination: String, onActivity: (@Sendable () -> Void)?) async throws -> JSONValue {
        let request = try Parts.fetchRequest(args)
        let url = request.url!, host = url.host!, tls = url.scheme?.lowercased() == "https"
        guard host.lowercased() == destination else { throw denied("With its secrets in, this fetch no longer goes to \(destination); nothing was sent.",
            "Keep the destination host fixed; put secret placeholders in the URL path, query, headers or body.") }
        let connected = try await network("network.connect", args: ["host": .string(host),
            "port": .int(Int64(url.port ?? (tls ? 443 : 80))), "tls": .bool(tls), "publicOnly": .bool(!Self.loopback(host))], fetch: true,
                onActivity: onActivity)
        let id = try text(Parts.fields(connected), "id")
        defer { connections.removeValue(forKey: id)?.cancel(); fetchConnections.remove(id) }
        let message = CFHTTPMessageCreateRequest(nil, (request.httpMethod! as CFString), url as CFURL, kCFHTTPVersion1_1).takeRetainedValue()
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            CFHTTPMessageSetHeaderFieldValue(message, key as CFString, value as CFString)
        }
        // URL.host omits IPv6 brackets required by the HTTP Host field.
        let named = host.contains(":") ? "[\(host)]" : host
        CFHTTPMessageSetHeaderFieldValue(message, "Host" as CFString, (url.port == nil ? named : "\(named):\(url.port!)") as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Connection" as CFString, "close" as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Accept-Encoding" as CFString, "identity" as CFString)
        if let body = request.httpBody {
            CFHTTPMessageSetBody(message, body as CFData)
            CFHTTPMessageSetHeaderFieldValue(message, "Content-Length" as CFString, String(body.count) as CFString)
        }
        guard let wire = CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data? else {
            throw SenseFailure(code: "http_request_encoding",
                message: "fetch could not encode this HTTP request. Correct its URL, method, headers and body in the fetch call.")
        }
        _ = try await network("network.send", args: ["id": .string(id), "base64": .string(wire.base64EncodedString())], fetch: true, onActivity: onActivity)
        guard let connection = connections[id] else { throw CancellationError() }
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
        guard !received.isEmpty else { throw SenseFailure(code: "http_response_empty",
            message: "fetch received no HTTP response. Check that the endpoint serves HTTP and inspect service state before another request.") }
        var response = CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
        while true {
            let parsed = received.withUnsafeBytes { bytes in
                CFHTTPMessageAppendBytes(response, bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count)
            }
            guard parsed, CFHTTPMessageIsHeaderComplete(response) else {
                throw SenseFailure(code: "http_response_incomplete", message: """
                    fetch received an incomplete HTTP response. Repair the endpoint's HTTP framing or premature close; inspect service state before \
                    another request.
                    """)
            }
            if CFHTTPMessageGetResponseStatusCode(response) >= 200 { break }
            guard CFHTTPMessageGetResponseStatusCode(response) != 101,
                  let rest = CFHTTPMessageCopyBody(response)?.takeRetainedValue() as Data?, !rest.isEmpty else {
                throw SenseFailure(code: "http_upgrade_unsupported", message: """
                    fetch received no final HTTP response or a protocol upgrade. Use a final HTTP endpoint, or implement the upgraded protocol with \
                    network primitives.
                    """)
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

    private func denied(_ detail: String, _ fix: String) -> SenseFailure {
        SenseFailure(code: "permission_denied", message: detail, remedy: Repair.remedy(owner: "ability \(abilityID)",
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
            throw Self.inputFailure("invalid_send_base64", field: "base64",
                accepted: "a base64 string decoding to at most 4 MiB; alternatively pass nonempty text")
        }
        return data
    }
    /// Only exact localhost/loopback IP literals are local; lookalike names grant no local authority.
    private static func loopback(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        return bytes == Array(repeating: 0, count: 15) + [1] || bytes.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] && bytes[12] == 127
    }

    /// Run DNS off the broker and retain its handle until synchronous exit; cancellation cannot interrupt getaddrinfo. Admitted fetches retain their
    /// original lookup through transport settlement.
    private func address(_ host: String, publicOnly: Bool = false, fetch: Bool = false) async throws -> String {
        try Task.checkCancellation()
        guard !closed || fetch else { throw CancellationError() }
        let id = UUID()
        let lookup = Task.detached {
            try Task.checkCancellation()
            let addresses = try Self.resolve(host)
            try Task.checkCancellation()
            return addresses
        }
        lookups[id] = (lookup, fetch)
        defer { lookups.removeValue(forKey: id) }
        let addresses = try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() }
        try Task.checkCancellation()
        // A run closing ends ordinary lookups, while an admitted fetch still owns its one request.
        guard !closed || fetch else { throw CancellationError() }
        // A local destination resolves to this Mac alone; a public one never reaches it.
        guard !publicOnly || addresses.allSatisfy({ !Self.loopback($0) }), !Self.loopback(host) || addresses.allSatisfy(Self.loopback),
              let chosen = addresses.first, permissions.contains("network")
            || addresses.allSatisfy({ Self.loopback($0) ? permissions.contains("network_localhost") : permissions.contains("network_public") }) else {
            throw denied("The resolved address for \(host) is outside the declared network reach.", """
                Check the host's DNS addresses; use a matching loopback or public host and declare its network reach. A public fetch cannot target \
                loopback.
                """)
        }
        return chosen
    }

    private static func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0, let start = first else {
            throw SenseFailure(code: "dns_resolution_failed",
                message: "Network host \(host) could not be resolved. Correct the host or repair DNS/network access before connecting.")
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

    private func network(_ operation: String, args: [String: JSONValue], fetch: Bool = false, onActivity: (@Sendable () -> Void)?) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !closed || fetch else { throw CancellationError() }
        switch operation {
        case "network.connect" where args["path"] != nil:
            let id = UUID().uuidString
            connections[id] = NWConnection(to: .unix(path: try text(args, "path")), using: .tcp)
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
            else if args["tls"] == .bool(true), operation == "network.connect" {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
                parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else { parameters = .tcp }
            let id = UUID().uuidString
            if operation == "network.connect" {
                connections[id] = NWConnection(host: NWEndpoint.Host(address), port: port, using: parameters)
                if fetch { fetchConnections.insert(id) }
                try await ready(id, onActivity: onActivity)
                guard !closed || fetch, connections[id] != nil else { throw CancellationError() }
                return .object(["id": .string(id)])
            }
            guard permissions.contains("network") || Self.loopback(address) && permissions.contains("network_localhost") else {
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
            guard let arrival = try await next(id, until: try Self.deadline(args), onActivity: onActivity) else { return .object(["pending": .bool(true)]) }
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
            try await networkReply(onActivity: onActivity, cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
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

    private func incoming(_ connection: NWConnection, listener id: String) {
        guard !closed, listeners[id] != nil, (inbox[id] ?? []).count < OwnedProgramRunner.actionLimit else { connection.cancel(); return }
        let key = UUID().uuidString
        connections[key] = connection
        arrive(id, .accepted(key))
    }

    /// Failed connection opens must cancel and release their resource.
    private func ready(_ id: String, onActivity: (@Sendable () -> Void)?) async throws {
        guard let connection = connections[id] else { throw CancellationError() }
        do {
            try await networkReply(onActivity: onActivity, cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
                connection.stateUpdateHandler = { state in
                    if case .ready = state { done.yield(()); done.finish() }
                    // Refused or missing local sockets fail immediately instead of consuming the wait.
                    if case .waiting(let error) = state { done.finish(throwing: error) }
                    if case .failed(let error) = state { done.finish(throwing: error) }
                    if case .cancelled = state { done.finish(throwing: CancellationError()) }
                }
                connection.start(queue: self.queue)
            }
        } catch {
            connections.removeValue(forKey: id)?.cancel()
            fetchConnections.remove(id)
            throw error
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

    /// Arrivals stay ordered; deadline expiry returns nil without inventing terminal evidence, while real terminal evidence remains repeatable.
    private func next(_ id: String, until deadline: ContinuousClock.Instant, onActivity: (@Sendable () -> Void)?) async throws -> Arrival? {
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
            if closed || Task.isCancelled { throw CancellationError() }
            let read = Read()
            readers[id] = (token, read)
            // Only this caller's wait ends at its deadline; arrival/exit owns the read result.
            timer = Task { try? await Task.sleep(until: deadline, clock: .continuous); self.endRead(id, token, nil) }
            await read.done.park()
            endRead(id, token, CancellationError())
            let came = try read.result!.get()
            guard let came else { return nil }
            arrival = came
        }
        onActivity?()
        if arrival.ends { ended[id] = arrival } else { pump(id) }
        return arrival
    }

    private func endRead(_ id: String, _ token: Int, _ error: Error?) {
        guard readers[id]?.token == token, let waiting = readers.removeValue(forKey: id) else { return }
        if let error { complete(waiting.read, .failure(error)) } else { complete(waiting.read, .success(nil)) }
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

    private func receive(_ connection: NWConnection, onActivity: (@Sendable () -> Void)?) async throws -> Arrival {
        try await networkReply(onActivity: onActivity, cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Arrival, Error>.Continuation) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.byteLimit) { data, _, complete, error in
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
    @discardableResult func finish() -> [JSONValue] {
        guard held != nil else { return close() }
        running -= 1
        guard running == 0 else { return [] }
        endWatch("run_ended")
        defer { watched = [] }
        return watched
    }

    /// Only the holding ability may end its named program.
    func end(_ arguments: JSONValue) {
        if let id = Parts.string(Parts.fields(arguments), "id"), programs[id] != nil { endProgram(id) }
    }

    /// Closing held reach must preserve admitted fetch ownership through its original transport settlement.
    @discardableResult func close() -> [JSONValue] {
        closed = true
        for lookup in lookups.values where !lookup.fetch { lookup.task.cancel() }
        for (id, connection) in connections where !fetchConnections.contains(id) { connection.cancel() }
        for listener in listeners.values { listener.cancel() }
        for program in programs.values { program.end() }
        for waiting in readers.values { complete(waiting.read, .failure(CancellationError())) }
        connections = connections.filter { fetchConnections.contains($0.key) }
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

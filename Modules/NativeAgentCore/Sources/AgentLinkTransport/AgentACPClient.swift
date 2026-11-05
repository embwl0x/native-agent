import Darwin
import Dispatch
import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `AgentACPClient.swift` | `AgentACPClient`, `startupTimeoutReceipt`, `turn`, `learned`, `Mismatch` |

/// EOF cannot prove a prompt response; sends never retry, launch a shell or grant optional services or permissions.
public actor AgentACPClient {
    package typealias Permission = @Sendable (JSONValue) async throws -> Bool
    package typealias Update = @Sendable (JSONValue) async -> Void
    package struct Reply: Sendable {
        package let sessionID: String
        package let text: String
        package let stopReason: String
        package let continued: Bool
        /// The model the agent said its session uses, when it says.
        package var model: String? = nil
        package var completed: Bool { stopReason == "end_turn" }
    }
    public enum Failure: String, Error, LocalizedError {
        case unavailable, executableChanged, interrupted, appQuit, invalidResponse, timedOut, tooLarge, busy, sessionUnavailable
        case initializationTimedOut, sessionStartupTimedOut, modeSetupTimedOut
        public var errorDescription: String? {
            switch self {
            case .busy: "This conversation is already answering. Wait for that reply before sending another message."
            case .sessionUnavailable: """
                The earlier conversation could not be verified. No message was sent. Start a new conversation explicitly if you want to continue without \
                its context.
                """
            case .unavailable: "The other agent could not start. Check its installation and sign-in."
            case .executableChanged: "The approved program changed or is missing. Review a fresh connection approval. Nothing ran."
            case .interrupted: "The other agent stopped before finishing. Do not resend automatically."
            case .appQuit: "The app quit before the other agent finished, which ended its turn. Nothing was resent."
            case .invalidResponse: "The other agent sent an unreadable answer. Completion is not confirmed."
            case .timedOut: "The other agent did not finish after prompt delivery began. Delivery and completion are unconfirmed. Do not resend automatically."
            case .initializationTimedOut: """
                The other agent timed out during connection initialization. Your message was not sent. Check that its CLI starts and is signed in before \
                explicitly reconnecting.
                """
            case .sessionStartupTimedOut: """
                The other agent timed out while opening or restoring its conversation. Your message was not sent. Check its session startup, model \
                availability, and MCP connections before explicitly reconnecting.
                """
            case .modeSetupTimedOut: """
                The other agent timed out while setting its approved conversation mode. Your message was not sent. Check its mode support before explicitly \
                reconnecting.
                """
            case .tooLarge: "The other agent's answer exceeded the size limit. Completion is not confirmed."
            }
        }
    }

    /// Recipe disagreement before the prompt write proves nothing was sent.
    package struct Mismatch: Error {
        package let method: String
        package let code: Int64?
        package let detail: String
    }

    /// Unavailable permission evidence is not the person's refusal; preserve owner and cancellation-write errors.
    package struct PermissionUnavailable: Error, LocalizedError {
        package let cause: any Error
        package var settlementFailure: String? = nil
        package var errorDescription: String? {
            "The permission decision was unavailable: \(cause.localizedDescription). Completion is unconfirmed; do not resend automatically."
                + (settlementFailure.map { " Peer cancellation was not confirmed: " + $0 } ?? "")
        }
    }

    /// Only startup timeouts can prove that no prompt write was attempted.
    package static func startupTimeoutReceipt(_ error: any Error) -> [String: JSONValue]? {
        guard let failure = error as? Failure else { return nil }
        let phase: String
        switch failure {
        case .initializationTimedOut: phase = "initialization"
        case .sessionStartupTimedOut: phase = "session_startup"
        case .modeSetupTimedOut: phase = "mode_setup"
        default: return nil
        }
        return ["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "phase": .string(phase), "reason": .string("connection_startup_timeout"),
                "detail": .string(failure.localizedDescription)]
    }

    private var startupTimeout: Failure = .initializationTimedOut
    private var processID: pid_t = 0
    private let input = Pipe()
    private let output = Pipe()
    private final class PendingRequest {
        let done = ScopedWaiter()
        var result: Result<JSONValue, Error>?
    }
    private var pending: [Int64: PendingRequest] = [:]

    private func complete(_ request: PendingRequest, _ result: Result<JSONValue, Error>) {
        request.result = result
        request.done.resume()
    }
    private var permissions: [String: (JSONValue, Task<Void, Never>)] = [:]
    private var nextID: Int64 = 0
    private var sessionID: String?
    package var currentSessionID: String? { sessionID }
    private var newSessionRequestID: Int64?
    private var failure: (any Error)?
    private var text = ""
    private var peerCredential: String?
    private var receivedBytes = 0
    /// A bounded turn caps what it reads; a job's turn runs to its own end.
    private var bounded = true
    private var permission: Permission?
    private var update: Update?
    private var reader: Task<Void, Never>?
    private var pipeReader: AgentACPPipeReader?
    private var deadline: Task<Void, Never>?
    private var deadlineGeneration = 0
    private var started = false
    private var closing = false
    private var tree: ProcessTreeSnapshot?
    private var cleanup: Task<String?, Never>?
    private var terminationFailure: String?
    private var requiredMode: String?
    private var deniedPermission = false
    private var prompting = false
    /// A written prompt belongs to the peer's turn; callers must not treat its later failure as a failed send.
    package private(set) var delivered = false
    private var active = false
    private var restoredHistory = false
    private var initialized: JSONValue?
    private var advertised: [String]?

    package nonisolated let dataRoot: URL
    package init(dataRoot: URL) { self.dataRoot = dataRoot.standardizedFileURL }

    var canRestoreSession: Bool {
        let capabilities = initialized?.objectValue?["agentCapabilities"]?.objectValue
        return capabilities?["loadSession"] == .bool(true)
            || capabilities?["sessionCapabilities"]?.objectValue?["resume"]?.objectValue != nil
    }

    /// Without a message, learn the advertised handshake and mode without sending a prompt.
    package func turn(executable: String, arguments: [String], directory: URL,
              environment: [String: String], message: String?, peerCredential: String, mcpServers: [JSONValue] = [],
              line: AgentHostACP,
              conversationID: String? = nil,
              approvedExecutable: AgentACPExecutable? = nil,
              requireVerifiedRestore: Bool = false,
              timeout: Duration? = .seconds(300), permission: @escaping Permission,
              update: @escaping Update = { _ in },
              sessionOpened: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> Reply {
        guard !active else { throw Failure.busy }
        guard !closing, failure == nil else { throw Failure.interrupted }
        if started { guard conversationID == sessionID else { throw Failure.sessionUnavailable } }
        active = true
        defer { active = false; prompting = false; self.permission = nil; self.update = nil; self.peerCredential = nil }
        text = ""; receivedBytes = 0; deniedPermission = false; restoredHistory = false; requiredMode = nil; delivered = false
        bounded = timeout != nil
        startupTimeout = .initializationTimedOut
        self.permission = permission
        self.update = update
        self.peerCredential = peerCredential
        do {
        let reply = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let initialized = try await handshake(executable: executable, arguments: arguments, directory: directory,
                environment: environment, approvedExecutable: approvedExecutable, timeout: timeout ?? .seconds(300))
            // Opening the session is bounded either way; nil leaves only the prompt unbounded.
            arm(timeout ?? .seconds(300))
            startupTimeout = .sessionStartupTimedOut
            let params: [String: JSONValue] = ["cwd": .string(directory.path), "mcpServers": .array(mcpServers)]
            var restored: JSONValue? = sessionID != nil && conversationID == sessionID ? .object([:]) : nil
            var opened = "session/new"
            if let conversationID, restored == nil {
                guard !conversationID.isEmpty, conversationID.utf8.count <= 1024 else { throw Failure.invalidResponse }
                let capabilities = initialized.objectValue?["agentCapabilities"]?.objectValue
                let method = requireVerifiedRestore && capabilities?["loadSession"] == .bool(true) ? "session/load"
                    : capabilities?["sessionCapabilities"]?.objectValue?["resume"]?.objectValue != nil
                    ? "session/resume" : capabilities?["loadSession"] == .bool(true) ? "session/load" : nil
                // Continuing requires restoration; a fresh session needs an explicit send without its id.
                guard method != nil else { throw Failure.sessionUnavailable }
                if let method {
                    opened = method
                    // History may arrive before the load/resume response.
                    sessionID = conversationID
                    do {
                        let candidate = try await request(method, params.merging(["sessionId": .string(conversationID)]) { _, new in new })
                        if let returnedID = candidate.objectValue?["sessionId"], returnedID != .string(conversationID) {
                            throw Failure.sessionUnavailable
                        }
                        guard !requireVerifiedRestore || restoredHistory || candidate.objectValue?["sessionId"] == .string(conversationID) ||
                            candidate.objectValue?["_meta"]?.objectValue?["hermes"]?.objectValue?[
                                "sessionProvenance"]?.objectValue?["acpSessionId"] == .string(conversationID) else {
                            throw Failure.sessionUnavailable
                        }
                        restored = candidate
                    } catch {
                        try Task.checkCancellation()
                        if let failure { throw failure }
                        // Only -32601/-32602 prove recipe mismatch; other errors mean restoration failed.
                        if let refused = error as? Mismatch, [-32601, -32602].contains(refused.code) { throw refused }
                        throw Failure.sessionUnavailable
                    }
                }
            }
            let continued = restored != nil
            let session: JSONValue
            let id: String
            if let restored, let conversationID {
                session = restored
                id = conversationID
            } else {
                sessionID = nil
                session = try await request("session/new", params)
                guard case .string(let newID)? = session.objectValue?["sessionId"] else { throw Failure.invalidResponse }
                id = newID
            }
            guard !id.isEmpty, id.utf8.count <= 1024 else {
                throw Failure.invalidResponse
            }
            sessionID = id
            let model = session.objectValue?["models"]?.objectValue?["currentModelId"]?.stringValue
            await sessionOpened(id)
            startupTimeout = .modeSetupTimedOut
            let available = session.objectValue?["modes"]?.objectValue?["availableModes"]
            // A continued session need not restate modes, so retain the approved recipe's.
            let now: [String]? = continued && available == nil ? nil : {
                guard case .array(let modes)? = available else { return [] }
                return modes.compactMap { if case .string(let mode)? = $0.objectValue?["id"] { mode } else { nil } }
            }()
            if let now {
                advertised = now
                func named(_ modes: [String]) -> String { modes.isEmpty ? "none" : modes.joined(separator: ", ") }
                if message != nil, let recipe = line.modes, Set(recipe) != Set(now) {
                    throw Mismatch(method: opened, code: nil, detail: "it advertises modes \(named(now)); the recipe says \(named(recipe))")
                }
                if message != nil, line.modes == nil, now.isEmpty {
                    throw Mismatch(
                        method: "session/set_mode",
                        code: nil,
                        detail: "it advertises no modes, so permissionMode \(line.permissionMode) cannot be set")
                }
                guard now.isEmpty || now.contains(line.permissionMode) else {
                    throw Mismatch(
                        method: "session/set_mode",
                        code: nil,
                        detail: "the recipe's permissionMode \(line.permissionMode) is not one of its modes \(named(now))")
                }
            }
            if (now ?? line.modes)?.isEmpty != true {
                requiredMode = line.permissionMode
                _ = try await request("session/set_mode", ["sessionId": .string(id), "modeId": .string(line.permissionMode)])
            }
            guard let message else {
                return Reply(sessionID: id, text: "", stopReason: "dry_run", continued: continued)
            }
            if timeout == nil { deadlineGeneration += 1; deadline?.cancel(); deadline = nil }
            // Conservative boundary: any attempted prompt write makes delivery uncertain.
            prompting = true; delivered = true
            let response = try await request("session/prompt", ["sessionId": .string(id),
                "prompt": .array([.object(["type": .string("text"), "text": .string(message)])])])
            guard case .string(let reason)? = response.objectValue?["stopReason"],
                  ["end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled"].contains(reason) else { throw Failure.invalidResponse }
            // An agent that ends its turn over a permission request it stopped waiting on has withdrawn it: its card goes, and it was not granted.
            withdrawOpenPermissions()
            try Task.checkCancellation()
            return Reply(sessionID: id, text: text, stopReason: deniedPermission ? "permission_denied" : reason,
                continued: continued, model: model)
        } onCancel: { Task { await self.cancel(error: CancellationError()) } }
        deadlineGeneration += 1
        deadline?.cancel(); deadline = nil
        return reply
        } catch {
            let reportedError: any Error = (error as? Failure == .timedOut && !prompting) ? startupTimeout : error
            shutdown()
            await retainCleanupResult()
            reader?.cancel()
            try? output.fileHandleForReading.close()
            if let terminationFailure {
                if var unavailable = reportedError as? PermissionUnavailable {
                    unavailable.settlementFailure = [unavailable.settlementFailure, terminationFailure].compactMap { $0 }.joined(separator: "; ")
                    throw unavailable
                }
                throw ToolFailureError(reportedError.localizedDescription + " " + terminationFailure, effects: .unknown,
                    owner: "ACP process group", code: "process_termination_incomplete",
                    instruction: "Reconcile the original run and repair its retained process group before sending again.", recovery: .repair)
            }
            throw reportedError
        }
    }

    /// Fresh spawns and retained exchanges verify the program; initialize must prove JSON-RPC 2.0, request identity and ACP 1.
    private func handshake(executable: String, arguments: [String], directory: URL, environment: [String: String],
                           approvedExecutable: AgentACPExecutable?, timeout: Duration) async throws -> JSONValue {
        if started, let approvedExecutable {
            do { try approvedExecutable.verify() } catch { throw Failure.executableChanged }
        }
        if !started {
            started = true
            // The sole supported wrapper must receive the approved path.
            if let approvedExecutable {
                guard executable == approvedExecutable.path ||
                    (executable == "/usr/bin/sandbox-exec" && arguments.count >= 3 &&
                     arguments[0] == "-p" && arguments[2] == approvedExecutable.path)
                else { throw Failure.unavailable }
            }
            processID = try AgentACPProcess.spawn(executable: executable, arguments: arguments,
                directory: directory, environment: environment, input: input, output: output,
                approvedExecutable: approvedExecutable)
            tree = ProcessTreeReaper.snapshot(rootPID: processID)
            // Close parent copies of child ends so EOF is observable.
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            let pipeReader = try AgentACPPipeReader(handle: output.fileHandleForReading)
            self.pipeReader = pipeReader
            try? output.fileHandleForReading.close()
            reader = Task { [weak self] in
                do {
                    var line = Data()
                    for try await chunk in pipeReader.chunks {
                        pipeReader.consumed()
                        try Task.checkCancellation()
                        for byte in chunk {
                            if byte == 10 {
                                guard !line.isEmpty else { throw Failure.invalidResponse }
                                let value = try JSONValue.parse(line)
                                line.removeAll(keepingCapacity: true)
                                await self?.receive(value)
                            } else {
                                guard line.count < 1_048_576 else { throw Failure.tooLarge }
                                line.append(byte)
                            }
                        }
                    }
                    await self?.fail(Failure.interrupted)
                } catch { await self?.fail(error) }
            }
        }
        // Initialization needs its own 30-second bound, independent of the reply window.
        arm(min(timeout, .seconds(30)))
        if initialized == nil { initialized = try await request("initialize", [
            "protocolVersion": .int(1), "clientCapabilities": .object([:]),
            "clientInfo": .object(["name": .string("nativeagent"), "version": .string("1")])]) }
        guard let initialized else { throw Failure.invalidResponse }
        guard initialized.objectValue?["protocolVersion"] == .int(1) else {
            throw Mismatch(method: "initialize", code: nil, detail: "it speaks ACP version "
                + ((try? initialized.objectValue?["protocolVersion"]?.serialize(pretty: false)) ?? "none") + "; this app speaks 1")
        }
        return initialized
    }

    /// Discovery runs only the handshake, then stops the program without sending a prompt.
    package func initialize(executable: String, arguments: [String], directory: URL, environment: [String: String],
                            approvedExecutable: AgentACPExecutable, timeout: Duration) async throws -> JSONValue {
        guard !active, !started else { throw Failure.busy }
        active = true
        defer { active = false }
        do {
            let result = try await withTaskCancellationHandler {
                try await handshake(executable: executable, arguments: arguments, directory: directory,
                                    environment: environment, approvedExecutable: approvedExecutable, timeout: timeout)
            } onCancel: { Task { await self.cancel(error: CancellationError()) } }
            await close()
            if let terminationFailure {
                throw ToolFailureError(terminationFailure, effects: .unknown, owner: "ACP process group",
                    code: "process_termination_incomplete", instruction: "Repair the retained process group before reconnecting.", recovery: .repair)
            }
            return result
        } catch { await close(); throw error }
    }

    private func arm(_ duration: Duration) {
        deadlineGeneration += 1
        let generation = deadlineGeneration
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            await self?.expire(generation)
        }
    }

    package func learned(_ line: AgentHostACP) -> AgentHostACP {
        var line = line
        let capabilities = initialized?.objectValue?["agentCapabilities"]?.objectValue
        if case .int(let version)? = initialized?.objectValue?["protocolVersion"] { line.protocolVersion = Int(version) }
        if let advertised, line.modes.map(Set.init) != Set(advertised) { line.modes = advertised }
        if initialized != nil {
            line.supportsLoad = capabilities?["loadSession"] == .bool(true)
            line.supportsResume = capabilities?["sessionCapabilities"]?.objectValue?["resume"]?.objectValue != nil
        }
        return line
    }

    /// `appQuit` only from `closeAll`: the send it cuts off carries that origin.
    package func close(_ error: Failure = .interrupted) async {
        cancel(error: error)
        shutdown()
        await retainCleanupResult()
        reader?.cancel()
        try? output.fileHandleForReading.close()
    }

    private func retainCleanupResult() async {
        guard let detail = await cleanup?.value else { return }
        terminationFailure = detail
        await RepairOwed.owe(dataRoot,
            id: "acp-termination:" + String(processID), kind: .act,
            operation: "agent.acp.termination:" + String(processID), owner: "ACP process group " + String(processID),
            words: detail,
            lever: "Reconcile the original agent run and repair the retained process group before reconnecting or repeating its work.").value
    }

    private func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        if let failure { throw failure }
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        if method == "session/new" { newSessionRequestID = id }
        do {
            let request = PendingRequest()
            pending[id] = request
            do { try write(.object(["jsonrpc": .string("2.0"), "id": .int(id),
                                   "method": .string(method), "params": .object(params)])) }
            catch { fail(error) }
            let done = request.done
            await Task { await done.park() }.value
            return try request.result!.get()
        } catch let refused as Mismatch { throw Mismatch(method: method, code: refused.code, detail: refused.detail) }
    }

    private func write(_ value: JSONValue) throws {
        var bytes = try value.serializedData(pretty: false)
        guard bytes.count <= 1_048_576 else { throw Failure.tooLarge }
        bytes.append(10)
        // A full pipe must not block timeout or cancellation handlers on this actor.
        let fd = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.interrupted }
        let end = ContinuousClock.now.advanced(by: .seconds(1))
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard ContinuousClock.now < end else { throw Failure.timedOut }
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                guard count < 0, errno == EAGAIN else { throw Failure.interrupted }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, 20)
                if ready < 0, errno != EINTR { throw Failure.interrupted }
            }
        }
    }

    private func receive(_ value: JSONValue) async {
        guard failure == nil else { return }
        do {
            guard let object = value.objectValue, object["jsonrpc"] == .string("2.0") else { throw Failure.invalidResponse }
            receivedBytes += (try value.serializedData(pretty: false)).count
            guard !bounded || receivedBytes <= 8 * 1_048_576 else { throw Failure.tooLarge }
            if case .string(let method)? = object["method"] {
                guard let params = object["params"]?.objectValue else { throw Failure.invalidResponse }
                if method == "session/update" {
                    guard object["id"] == nil, params["sessionId"] == sessionID.map(JSONValue.string),
                          let event = params["update"] else { throw Failure.invalidResponse }
                    guard prompting else {
                        if [
                            JSONValue.string("agent_message_chunk"),
                            .string("user_message_chunk")].contains(event.objectValue?["sessionUpdate"] ?? .null) { restoredHistory = true }
                        return
                    }
                    if let requiredMode, event.objectValue?["sessionUpdate"] == .string("current_mode_update"),
                       event.objectValue?["currentModeId"] != .string(requiredMode) {
                        cancel(error: Failure.invalidResponse)
                        return
                    }
                    if event.objectValue?["sessionUpdate"] == .string("agent_message_chunk"),
                       let content = event.objectValue?["content"]?.objectValue,
                       content["type"] == .string("text"), case .string(let chunk)? = content["text"] {
                        guard text.utf8.count + chunk.utf8.count <= 1_048_576 else { throw Failure.tooLarge }
                        text += chunk
                    }
                    await update?(liveEvent(event))
                } else if let id = object["id"] {
                    guard case .string = id else {
                        if case .int = id { try handleRequest(method, id: id, params: params); return }
                        throw Failure.invalidResponse
                    }
                    try handleRequest(method, id: id, params: params)
                }
                return
            }
            guard case .int(let id)? = object["id"], let request = pending.removeValue(forKey: id) else {
                throw Failure.invalidResponse
            }
            if let error = object["error"] {
                let detail = (try? error.serialize(pretty: false)) ?? ""
                if !prompting {
                    let code: Int64? = if case .int(let code)? = error.objectValue?["code"] { code } else { nil }
                    let said: String = if case .string(let said)? = error.objectValue?["message"] { said } else { detail }
                    complete(request, .failure(Mismatch(method: "", code: code, detail: said + (code.map { " (\($0))" } ?? ""))))
                    return
                }
                complete(request, .failure(ProviderFailure.Report(cause: .wire(detail), work: .outcomeUnknown)))
            } else if let result = object["result"], result.objectValue != nil {
                if id == newSessionRequestID, case .string(let session)? = result.objectValue?["sessionId"] {
                    sessionID = session
                }
                complete(request, .success(result))
            } else {
                complete(request, .failure(Failure.invalidResponse))
            }
        } catch { fail(error) }
    }

    private func liveEvent(_ event: JSONValue) -> JSONValue {
        guard case .object(var event) = event else { return event }
        func redacted(_ value: JSONValue) -> JSONValue {
            guard case .string(let value) = value else { return value }
            return .string(AgentPeerHTTP.redactLiveText(value, token: peerCredential))
        }
        if event["sessionUpdate"] == .string("agent_message_chunk"),
           case .object(var content)? = event["content"], content["type"] == .string("text") {
            content["text"] = .string(AgentPeerHTTP.redactLiveText(text, token: peerCredential))
            event["content"] = .object(content)
        } else if event["sessionUpdate"] == .string("tool_call"), let title = event["title"] {
            event["title"] = redacted(title)
        } else if event["sessionUpdate"] == .string("plan"), case .array(let entries)? = event["entries"] {
            event["entries"] = .array(entries.map { entry in
                guard case .object(var entry) = entry, let content = entry["content"] else { return entry }
                entry["content"] = redacted(content)
                return .object(entry)
            })
        }
        return .object(event)
    }

    private func handleRequest(_ method: String, id: JSONValue, params: [String: JSONValue]) throws {
        guard method == "session/request_permission" else {
            try write(.object(["jsonrpc": .string("2.0"), "id": id,
                               "error": .object(["code": .int(-32601), "message": .string("This operation is not available.")])]))
            return
        }
        guard prompting, params["sessionId"] == sessionID.map(JSONValue.string), sessionID != nil,
              params["toolCall"]?.objectValue != nil, case .array(let options)? = params["options"],
              permissions.count < 16 else { throw Failure.invalidResponse }
        let key = String(decoding: try id.serializedData(pretty: false), as: UTF8.self)
        guard permissions[key] == nil else { throw Failure.invalidResponse }
        // Never choose allow_always, even if it is the agent's only allow option.
        let allow = options.first { $0.objectValue?["kind"] == .string("allow_once") }?.objectValue?["optionId"]
        let deny = options.first { $0.objectValue?["kind"] == .string("reject_once") }?.objectValue?["optionId"]
        var preview = params
        if let peerCredential, !peerCredential.isEmpty, var call = params["toolCall"]?.objectValue,
           case .string(let title)? = call["title"] {
            call["title"] = .string(title.replacingOccurrences(of: peerCredential, with: "[redacted]"))
            preview["toolCall"] = .object(call)
        }
        let request = JSONValue.object(preview)
        let task = Task { [weak self, permission] in
            do {
                guard let permission else {
                    throw ToolFailureError("The ACP permission service is not mounted.", effects: .unknown,
                        owner: "ACP permission service", tap: "Open NativeAgent", code: "agent_acp_permission_owner_unavailable",
                        instruction: "Repair the permission service before starting another peer turn.")
                }
                let approved = try await permission(request)
                guard !Task.isCancelled else { return }
                await self?.permissionResult(key: key, selection: approved ? allow : deny, allowed: approved && allow != nil)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.permissionUnavailable(key: key, cause: error)
            }
        }
        permissions[key] = (id, task)
    }

    private func withdrawOpenPermissions() {
        guard !permissions.isEmpty else { return }
        for (_, open) in permissions { open.1.cancel() }
        permissions.removeAll()
        deniedPermission = true
    }

    private func permissionResult(key: String, selection: JSONValue?, allowed: Bool) {
        guard failure == nil, let (id, _) = permissions.removeValue(forKey: key) else { return }
        if !allowed { deniedPermission = true }
        do { try respondPermission(id: id, selection: selection) } catch { fail(error) }
    }

    private func permissionUnavailable(key: String, cause: any Error) {
        guard failure == nil, permissions[key] != nil else { return }
        cancel(error: PermissionUnavailable(cause: cause))
    }

    private func respondPermission(id: JSONValue, selection: JSONValue?) throws {
        var outcome: [String: JSONValue] = ["outcome": .string("cancelled")]
        if case .string(let option)? = selection { outcome = ["outcome": .string("selected"), "optionId": .string(option)] }
        try write(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["outcome": .object(outcome)])]))
    }

    /// ACP cancellation answers open permission requests as cancelled but keeps the session for the next message.
    func requestCancel() -> Bool {
        guard prompting, failure == nil, !closing, sessionID != nil else { return false }
        do { try cancelSession(notify: write) } catch { return false }
        return true
    }

    private func cancelSession(notify: (JSONValue) throws -> Void) throws {
        var errors: [String] = []
        if let sessionID {
            do {
                try notify(.object(["jsonrpc": .string("2.0"), "method": .string("session/cancel"),
                                    "params": .object(["sessionId": .string(sessionID)])]))
            } catch { errors.append("session/cancel: " + error.localizedDescription) }
        }
        for (_, (id, task)) in permissions {
            task.cancel()
            do { try respondPermission(id: id, selection: nil) }
            catch { errors.append("permission cancellation: " + error.localizedDescription) }
        }
        permissions.removeAll()
        guard errors.isEmpty else {
            throw ToolFailureError(errors.joined(separator: "; "), effects: .unknown,
                owner: "ACP connection", tap: "Agents → open the contact's conversation",
                code: "agent_acp_cancellation_unconfirmed", instruction: "Inspect the original peer turn before sending again.", recovery: .reconcile)
        }
    }

    /// A late timer must not kill a session that has advanced beyond the timed operation.
    private func expire(_ generation: Int) {
        guard generation == deadlineGeneration else { return }
        cancel(error: Failure.timedOut)
    }

    private func cancel(error: any Error) {
        guard failure == nil else { return }
        do { try cancelSession(notify: write) }
        catch let settlementError {
            if var unavailable = error as? PermissionUnavailable {
                unavailable.settlementFailure = settlementError.localizedDescription
                fail(unavailable)
            } else {
                fail(ToolFailureError(error.localizedDescription + " Peer cancellation was not confirmed: " + settlementError.localizedDescription,
                    effects: .unknown, owner: "ACP connection", tap: "Agents → open the contact's conversation",
                    code: "agent_acp_cancellation_unconfirmed", instruction: "Inspect the original peer turn before sending again.", recovery: .reconcile))
            }
            return
        }
        fail(error)
    }

    private func fail(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        let waiting = pending.values
        pending.removeAll()
        for request in waiting { complete(request, .failure(error)) }
        shutdown()
    }

    private func shutdown() {
        guard !closing else { return }
        closing = true
        deadline?.cancel(); deadline = nil
        pipeReader?.cancel(); pipeReader = nil
        reader?.cancel()
        for (_, (_, task)) in permissions { task.cancel() }
        permissions.removeAll()
        try? input.fileHandleForWriting.close()
        // Keep the leader waitable until group escalation ends so its PID/PGID cannot be reused.
        let child = processID
        let snapshot = tree.map { ProcessTreeReaper.snapshot(rootPID: $0.rootPID, retaining: $0) }
        cleanup = Task.detached {
            await AgentACPProcess.finish(child, snapshot: snapshot)
        }
    }
}

/// Per-process kernel readiness avoids an idle pipe starving other connections on Foundation's shared reader. One consumer preserves wire order and
/// backpressure without blocking reads or per-chunk tasks.
final class AgentACPPipeReader: @unchecked Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let source: any DispatchSourceRead
    private let fd: Int32
    private let lock = NSLock()
    private var bufferedChunks = 0
    private var suspended = false

    init(handle: FileHandle) throws {
        let owned = dup(handle.fileDescriptor)
        guard owned >= 0 else { throw AgentACPClient.Failure.unavailable }
        let flags = fcntl(owned, F_GETFL)
        guard flags >= 0, fcntl(owned, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(owned, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(owned)
            throw AgentACPClient.Failure.unavailable
        }
        fd = owned
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        chunks = pair.stream; continuation = pair.continuation
        source = DispatchSource.makeReadSource(fileDescriptor: owned,
            queue: DispatchQueue(label: "nativeagent.acp.pipe.\(owned)", qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(owned) }
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        source.resume()
    }

    func consumed() {
        lock.lock()
        bufferedChunks -= 1
        if suspended { suspended = false; source.resume() }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        if suspended { suspended = false; source.resume() }
        source.cancel()
        lock.unlock()
        continuation.finish()
    }

    deinit { cancel() }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            lock.lock()
            guard !source.isCancelled else { lock.unlock(); return }
            // Count before yielding because consumption can start immediately; leave excess bytes in the pipe.
            if bufferedChunks == 16 {
                suspended = true; source.suspend()
                lock.unlock(); return
            }
            lock.unlock()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                lock.lock(); bufferedChunks += 1; lock.unlock()
                switch continuation.yield(Data(buffer.prefix(count))) {
                case .enqueued: continue
                case .dropped:
                    continuation.finish(throwing: AgentACPClient.Failure.interrupted)
                    cancel(); return
                case .terminated: cancel(); return
                @unknown default:
                    continuation.finish(throwing: AgentACPClient.Failure.interrupted)
                    cancel(); return
                }
            }
            if count == 0 { cancel(); return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            continuation.finish(throwing: AgentACPClient.Failure.interrupted)
            cancel(); return
        }
    }
}

/// Process ownership is bounded; conversation history remains with the peer.
package actor AgentACPConnections {
    package static let shared = AgentACPConnections()
    package struct Lease: Sendable { let key: String; let generation: UUID; package let client: AgentACPClient }
    private struct Entry {
        let client: AgentACPClient
        let configuration: String
        var generation: UUID = UUID()
        var busy: Bool
        var expiry: Task<Void, Never>?
        var idleSince = Date()
    }
    private var entries: [String: Entry] = [:]

    package func acquire(peer: String, conversation: String?, configuration: String, dataRoot: URL) async throws -> Lease {
        let key = peer + ":" + (conversation ?? UUID().uuidString)
        if let entry = entries[key] {
            guard !entry.busy else { throw AgentACPClient.Failure.busy }
            if entry.configuration == configuration, entry.client.dataRoot == dataRoot.standardizedFileURL {
                entry.expiry?.cancel()
                let generation = UUID()
                entries[key]?.busy = true
                entries[key]?.generation = generation
                return Lease(key: key, generation: generation, client: entry.client)
            }
            entries.removeValue(forKey: key)
            entry.expiry?.cancel()
            await entry.client.close()
            guard entries[key] == nil else { throw AgentACPClient.Failure.busy }
        }
        // Evict after 30 idle minutes or at capacity: prefer resumable sessions, else require 10 idle minutes before losing context.
        if entries.count >= 8 {
            let idle = entries.filter { !$0.value.busy }.sorted { $0.value.idleSince < $1.value.idleSince }
            var victim: String?
            for candidate in idle where await candidate.value.client.canRestoreSession { victim = candidate.key; break }
            if victim == nil, let oldest = idle.first, Date().timeIntervalSince(oldest.value.idleSince) > 600 { victim = oldest.key }
            if let victim, entries[victim]?.busy == false, let evicted = entries.removeValue(forKey: victim) {
                evicted.expiry?.cancel()
                await evicted.client.close()
                guard entries[key] == nil else { throw AgentACPClient.Failure.busy }
            }
        }
        guard entries.count < 8 else { throw AgentACPClient.Failure.busy }
        let client = AgentACPClient(dataRoot: dataRoot)
        entries[key] = Entry(client: client, configuration: configuration, busy: true)
        return Lease(key: key, generation: entries[key]!.generation, client: client)
    }

    @discardableResult
    package func finish(_ lease: Lease, peer: String, conversation: String?) async -> Bool {
        guard let entry = entries[lease.key], entry.generation == lease.generation else { return false }
        entries.removeValue(forKey: lease.key)
        entry.expiry?.cancel()
        guard let conversation else { await entry.client.close(); return true }
        let key = peer + ":" + conversation
        guard entries[key] == nil else { await entry.client.close(); return false }
        let generation = UUID()
        let expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1800)) } catch { return }
            await self?.expire(key, generation: generation)
        }
        entries[key] = Entry(client: entry.client, configuration: entry.configuration, generation: generation, busy: false, expiry: expiry)
        return true
    }

    /// A supplied id targets one turn; first sends without an id cancel through their own task/lease.
    package func cancelTurn(peer: String, conversation: String?) async -> Bool {
        let busy = entries.filter { $0.value.busy && $0.key.hasPrefix(peer + ":") }
        guard let conversation, let entry = busy[peer + ":" + conversation] else { return false }
        return await entry.client.requestCancel()
    }

    package func closeAll() async {
        let owned = entries.values
        entries.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for entry in owned { entry.expiry?.cancel(); group.addTask { await entry.client.close(.appQuit) } }
        }
    }

    package func revoke(peer: String) async {
        let keys = entries.keys.filter { $0.hasPrefix(peer + ":") }
        for key in keys {
            guard let entry = entries.removeValue(forKey: key) else { continue }
            entry.expiry?.cancel()
            await entry.client.close()
        }
    }

    private func expire(_ key: String, generation: UUID) async {
        guard let entry = entries[key], entry.generation == generation, !entry.busy else { return }
        entries.removeValue(forKey: key)
        await entry.client.close()
    }
}

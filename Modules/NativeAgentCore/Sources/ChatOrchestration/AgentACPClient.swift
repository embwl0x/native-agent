import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

/// One owned stdio connection. EOF is never a prompt response. No retries,
/// shell, optional filesystem/terminal service, or automatic permission grants.
actor AgentACPClient {
    typealias Permission = @Sendable (JSONValue) async throws -> Bool
    typealias Update = @Sendable (JSONValue) async -> Void
    struct Reply: Sendable {
        let sessionID: String
        let text: String
        let stopReason: String
        var completed: Bool { stopReason == "end_turn" }
    }
    enum Failure: String, Error, LocalizedError {
        case unavailable, executableChanged, interrupted, invalidResponse, incompatibleVersion, timedOut, tooLarge
        var errorDescription: String? {
            switch self {
            case .unavailable: "The other agent could not start. Check its installation and sign-in."
            case .executableChanged: "The approved program changed or is missing. Review a fresh connection approval. Nothing ran."
            case .interrupted: "The other agent stopped before finishing. Do not resend automatically."
            case .invalidResponse: "The other agent sent an unreadable answer. Completion is not confirmed."
            case .incompatibleVersion: "The other agent uses a conversation version this app cannot read."
            case .timedOut: "The other agent did not finish in time. Do not resend automatically."
            case .tooLarge: "The other agent's answer exceeded the size limit. Completion is not confirmed."
            }
        }
    }

    private var processID: pid_t = 0
    private let input = Pipe()
    private let output = Pipe()
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var permissions: [String: (JSONValue, Task<Void, Never>)] = [:]
    private var nextID: Int64 = 0
    private var sessionID: String?
    private var newSessionRequestID: Int64?
    private var failure: (any Error)?
    private var text = ""
    private var receivedBytes = 0
    private var permission: Permission?
    private var update: Update?
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var started = false
    private var closing = false
    private var tree: ProcessTreeSnapshot?
    private var cleanup: Task<Void, Never>?
    private var requiredMode: String?
    private var deniedPermission = false

    func turn(executable: String, arguments: [String], directory: URL,
              environment: [String: String], message: String, mcpServers: [JSONValue] = [],
              permissionMode: String? = nil,
              approvedExecutable: AgentACPExecutable? = nil,
              timeout: Duration = .seconds(300), permission: @escaping Permission,
              update: @escaping Update = { _ in }) async throws -> Reply {
        guard !started else { throw Failure.unavailable }
        started = true
        self.permission = permission
        self.update = update
        self.requiredMode = permissionMode
        do {
        let reply = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
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
            }
            tree = ProcessTreeReaper.snapshot(rootPID: processID)
            // Close parent copies of child ends so EOF is observable.
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            let handle = output.fileHandleForReading
            reader = Task { [weak self] in
                do {
                    var line = Data()
                    for try await byte in handle.bytes {
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
                    await self?.fail(Failure.interrupted)
                } catch { await self?.fail(error) }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.cancel(error: Failure.timedOut)
            }
            let initialized = try await request("initialize", [
                "protocolVersion": .int(1), "clientCapabilities": .object([:]),
                "clientInfo": .object(["name": .string("nativeagent"), "version": .string("1")])])
            guard initialized.objectValue?["protocolVersion"] == .int(1) else { throw Failure.incompatibleVersion }
            let session = try await request("session/new", ["cwd": .string(directory.path), "mcpServers": .array(mcpServers)])
            guard case .string(let id)? = session.objectValue?["sessionId"], !id.isEmpty, id.utf8.count <= 1024 else {
                throw Failure.invalidResponse
            }
            sessionID = id
            if let permissionMode {
                guard case .array(let modes)? = session.objectValue?["modes"]?.objectValue?["availableModes"],
                      modes.contains(where: { $0.objectValue?["id"] == .string(permissionMode) }) else {
                    throw Failure.incompatibleVersion
                }
                _ = try await request("session/set_mode", ["sessionId": .string(id), "modeId": .string(permissionMode)])
            }
            let response = try await request("session/prompt", ["sessionId": .string(id),
                "prompt": .array([.object(["type": .string("text"), "text": .string(message)])])])
            guard case .string(let reason)? = response.objectValue?["stopReason"],
                  ["end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled"].contains(reason),
                  permissions.isEmpty else { throw Failure.invalidResponse }
            try Task.checkCancellation()
            return Reply(sessionID: id, text: text, stopReason: deniedPermission ? "permission_denied" : reason)
        } onCancel: { Task { await self.cancel(error: CancellationError()) } }
        shutdown()
        await cleanup?.value
        reader?.cancel()
        try? output.fileHandleForReading.close()
        return reply
        } catch {
            shutdown()
            await cleanup?.value
            reader?.cancel()
            try? output.fileHandleForReading.close()
            throw error
        }
    }

    private func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        if let failure { throw failure }
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        if method == "session/new" { newSessionRequestID = id }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try write(.object(["jsonrpc": .string("2.0"), "id": .int(id),
                                   "method": .string(method), "params": .object(params)])) }
            catch { fail(error) }
        }
    }

    private func write(_ value: JSONValue) throws {
        var bytes = try value.serializedData(pretty: false)
        guard bytes.count <= 1_048_576 else { throw Failure.tooLarge }
        bytes.append(10)
        // A peer that stops reading must not block this actor's timeout and
        // cancellation handlers behind a full pipe.
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
            guard receivedBytes <= 8 * 1_048_576 else { throw Failure.tooLarge }
            if case .string(let method)? = object["method"] {
                guard let params = object["params"]?.objectValue else { throw Failure.invalidResponse }
                if method == "session/update" {
                    guard object["id"] == nil, params["sessionId"] == sessionID.map(JSONValue.string),
                          let event = params["update"] else { throw Failure.invalidResponse }
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
                    await update?(event)
                } else if let id = object["id"] {
                    guard case .string = id else {
                        if case .int = id { try handleRequest(method, id: id, params: params); return }
                        throw Failure.invalidResponse
                    }
                    try handleRequest(method, id: id, params: params)
                }
                return
            }
            guard case .int(let id)? = object["id"], let continuation = pending.removeValue(forKey: id) else {
                throw Failure.invalidResponse
            }
            if let error = object["error"] {
                let detail = (try? error.serialize(pretty: false)) ?? ""
                continuation.resume(throwing: ProviderFailure.Report(cause: .wire(detail), work: .outcomeUnknown))
            } else if let result = object["result"], result.objectValue != nil {
                if id == newSessionRequestID, case .string(let session)? = result.objectValue?["sessionId"] {
                    sessionID = session
                }
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: Failure.invalidResponse)
            }
        } catch { fail(error) }
    }

    private func handleRequest(_ method: String, id: JSONValue, params: [String: JSONValue]) throws {
        guard method == "session/request_permission" else {
            try write(.object(["jsonrpc": .string("2.0"), "id": id,
                               "error": .object(["code": .int(-32601), "message": .string("This operation is not available.")])]))
            return
        }
        guard params["sessionId"] == sessionID.map(JSONValue.string), sessionID != nil,
              params["toolCall"]?.objectValue != nil, case .array(let options)? = params["options"],
              permissions.count < 16 else { throw Failure.invalidResponse }
        let key = String(decoding: try id.serializedData(pretty: false), as: UTF8.self)
        guard permissions[key] == nil else { throw Failure.invalidResponse }
        // Never choose allow_always, even if it is the agent's only allow option.
        let allow = options.first { $0.objectValue?["kind"] == .string("allow_once") }?.objectValue?["optionId"]
        let deny = options.first { $0.objectValue?["kind"] == .string("reject_once") }?.objectValue?["optionId"]
        let task = Task { [weak self, permission] in
            let approved = (try? await permission?(.object(params))) == true
            guard !Task.isCancelled else { return }
            await self?.permissionResult(key: key, selection: approved ? allow : deny, allowed: approved && allow != nil)
        }
        permissions[key] = (id, task)
    }

    private func permissionResult(key: String, selection: JSONValue?, allowed: Bool) {
        guard failure == nil, let (id, _) = permissions.removeValue(forKey: key) else { return }
        if !allowed { deniedPermission = true }
        do { try respondPermission(id: id, selection: selection) } catch { fail(error) }
    }

    private func respondPermission(id: JSONValue, selection: JSONValue?) throws {
        var outcome: [String: JSONValue] = ["outcome": .string("cancelled")]
        if case .string(let option)? = selection { outcome = ["outcome": .string("selected"), "optionId": .string(option)] }
        try write(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["outcome": .object(outcome)])]))
    }

    private func cancel(error: any Error) {
        guard failure == nil else { return }
        if let sessionID {
            try? write(.object(["jsonrpc": .string("2.0"), "method": .string("session/cancel"),
                               "params": .object(["sessionId": .string(sessionID)])]))
        }
        for (_, (id, task)) in permissions {
            task.cancel()
            try? respondPermission(id: id, selection: nil)
        }
        permissions.removeAll()
        fail(error)
    }

    private func fail(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: error) }
        shutdown()
    }

    private func shutdown() {
        guard !closing else { return }
        closing = true
        deadline?.cancel(); deadline = nil
        for (_, (_, task)) in permissions { task.cancel() }
        permissions.removeAll()
        try? input.fileHandleForWriting.close()
        // Do not reap the leader until group escalation is complete. Even an
        // exited leader remains our waitable child, reserving its PID/PGID.
        let child = processID
        let snapshot = tree.map { ProcessTreeReaper.snapshot(rootPID: $0.rootPID, retaining: $0) }
        cleanup = Task.detached {
            await AgentACPProcess.finish(child, snapshot: snapshot)
        }
    }
}

/// ACP owns and reaps its children directly: Foundation's termination observer
/// must not reap the group leader before descendants have been signaled.
enum AgentACPProcess {
    static func spawn(executable: String, arguments: [String], directory: URL,
                      environment: [String: String], input: Pipe, output: Pipe,
                      approvedExecutable: AgentACPExecutable? = nil) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw AgentACPClient.Failure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw AgentACPClient.Failure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0,
              posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else {
            throw AgentACPClient.Failure.unavailable
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        if let approvedExecutable {
            do { try approvedExecutable.verify() }
            catch { throw AgentACPClient.Failure.executableChanged }
        }
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw AgentACPClient.Failure.unavailable }
        return pid
    }

    static func finish(_ pid: pid_t, snapshot: ProcessTreeSnapshot? = nil,
                       grace: Duration = .milliseconds(200)) async {
        guard pid > 0 else { return }
        try? await Task.sleep(for: grace)
        kill(-pid, SIGTERM)
        if let snapshot { ProcessTreeReaper.signal(snapshot, signal: SIGTERM) }
        try? await Task.sleep(for: .milliseconds(500))
        kill(-pid, SIGSTOP)
        if let snapshot {
            ProcessTreeReaper.quiesceAndKill(ProcessTreeReaper.snapshot(rootPID: pid, retaining: snapshot))
        }
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
}

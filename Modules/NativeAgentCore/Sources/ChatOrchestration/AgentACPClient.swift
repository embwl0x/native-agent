import Darwin
import Dispatch
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

/// One owned stdio connection. EOF is never a prompt response. No prompt retries,
/// shell, optional filesystem/terminal service, or automatic permission grants.
actor AgentACPClient {
    typealias Permission = @Sendable (JSONValue) async throws -> Bool
    typealias Update = @Sendable (JSONValue) async -> Void
    struct Reply: Sendable {
        let sessionID: String
        let text: String
        let stopReason: String
        let continued: Bool
        let detail: String?
        var completed: Bool { stopReason == "end_turn" }
    }
    enum Failure: String, Error, LocalizedError {
        case unavailable, executableChanged, interrupted, invalidResponse, incompatibleVersion, timedOut, tooLarge, busy, sessionUnavailable
        case initializationTimedOut, sessionStartupTimedOut, modeSetupTimedOut
        var errorDescription: String? {
            switch self {
            case .busy: "This conversation is already answering. Wait for that reply before sending another message."
            case .sessionUnavailable: "The earlier conversation could not be verified. No message was sent. Start a new conversation explicitly if you want to continue without its context."
            case .unavailable: "The other agent could not start. Check its installation and sign-in."
            case .executableChanged: "The approved program changed or is missing. Review a fresh connection approval. Nothing ran."
            case .interrupted: "The other agent stopped before finishing. Do not resend automatically."
            case .invalidResponse: "The other agent sent an unreadable answer. Completion is not confirmed."
            case .incompatibleVersion: "The other agent uses a conversation version this app cannot read."
            case .timedOut: "The other agent did not finish after prompt delivery began. Delivery and completion are unconfirmed. Do not resend automatically."
            case .initializationTimedOut: "The other agent timed out during connection initialization. Your message was not sent. Check that its CLI starts and is signed in before explicitly reconnecting."
            case .sessionStartupTimedOut: "The other agent timed out while opening or restoring its conversation. Your message was not sent. Check its session startup, model availability, and MCP connections before explicitly reconnecting."
            case .modeSetupTimedOut: "The other agent timed out while setting its approved conversation mode. Your message was not sent. Check its mode support before explicitly reconnecting."
            case .tooLarge: "The other agent's answer exceeded the size limit. Completion is not confirmed."
            }
        }
    }

    /// Only startup timeouts can prove that no prompt write was attempted.
    static func startupTimeoutReceipt(_ error: any Error) -> [String: JSONValue]? {
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
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var permissions: [String: (JSONValue, Task<Void, Never>)] = [:]
    private var nextID: Int64 = 0
    private var sessionID: String?
    var currentSessionID: String? { sessionID }
    private var newSessionRequestID: Int64?
    private var failure: (any Error)?
    private var text = ""
    private var receivedBytes = 0
    private var permission: Permission?
    private var update: Update?
    private var reader: Task<Void, Never>?
    private var pipeReader: AgentACPPipeReader?
    private var deadline: Task<Void, Never>?
    private var deadlineGeneration = 0
    private var started = false
    private var closing = false
    private var tree: ProcessTreeSnapshot?
    private var cleanup: Task<Void, Never>?
    private var requiredMode: String?
    private var deniedPermission = false
    private var prompting = false
    private var active = false
    private var restoredHistory = false
    private var initialized: JSONValue?

    /// The peer said at initialize it can reopen a session by id.
    var canRestoreSession: Bool {
        let capabilities = initialized?.objectValue?["agentCapabilities"]?.objectValue
        return capabilities?["loadSession"] == .bool(true)
            || capabilities?["sessionCapabilities"]?.objectValue?["resume"]?.objectValue != nil
    }

    func turn(executable: String, arguments: [String], directory: URL,
              environment: [String: String], message: String, mcpServers: [JSONValue] = [],
              permissionMode: String? = nil,
              conversationID: String? = nil,
              approvedExecutable: AgentACPExecutable? = nil,
              keepAlive: Bool = false, requireVerifiedRestore: Bool = false,
              timeout: Duration = .seconds(300), permission: @escaping Permission,
              update: @escaping Update = { _ in }) async throws -> Reply {
        guard !active else { throw Failure.busy }
        guard !closing, failure == nil else { throw Failure.interrupted }
        if started { guard conversationID == sessionID else { throw Failure.sessionUnavailable } }
        active = true
        defer { active = false; prompting = false; self.permission = nil; self.update = nil }
        text = ""; receivedBytes = 0; deniedPermission = false; restoredHistory = false
        startupTimeout = .initializationTimedOut
        self.permission = permission
        self.update = update
        self.requiredMode = permissionMode
        do {
        let reply = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let approvedExecutable {
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
            // 2026-09-22 WHY: one 300s deadline covered the handshake too, so a
            // CLI stuck initializing burned the whole reply window.
            deadlineGeneration += 1
            let handshake = deadlineGeneration
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: min(timeout, .seconds(30))) } catch { return }
                await self?.expire(handshake)
            }
            if initialized == nil { initialized = try await request("initialize", [
                "protocolVersion": .int(1), "clientCapabilities": .object([:]),
                "clientInfo": .object(["name": .string("nativeagent"), "version": .string("1")])]) }
            deadlineGeneration += 1
            let replyDeadline = deadlineGeneration
            deadline?.cancel()
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.expire(replyDeadline)
            }
            guard let initialized else { throw Failure.invalidResponse }
            guard initialized.objectValue?["protocolVersion"] == .int(1) else { throw Failure.incompatibleVersion }
            startupTimeout = .sessionStartupTimedOut
            let params: [String: JSONValue] = ["cwd": .string(directory.path), "mcpServers": .array(mcpServers)]
            var restored: JSONValue? = sessionID != nil && conversationID == sessionID ? .object([:]) : nil
            if let conversationID, restored == nil {
                guard !conversationID.isEmpty, conversationID.utf8.count <= 1024 else { throw Failure.invalidResponse }
                let capabilities = initialized.objectValue?["agentCapabilities"]?.objectValue
                let method = requireVerifiedRestore && capabilities?["loadSession"] == .bool(true) ? "session/load"
                    : capabilities?["sessionCapabilities"]?.objectValue?["resume"]?.objectValue != nil
                    ? "session/resume" : capabilities?["loadSession"] == .bool(true) ? "session/load" : nil
                if let method {
                    // History can arrive before the load/resume response, including from Hermes resume.
                    sessionID = conversationID
                    do {
                        let candidate = try await request(method, params.merging(["sessionId": .string(conversationID)]) { _, new in new })
                        if let returnedID = candidate.objectValue?["sessionId"], returnedID != .string(conversationID) {
                            throw Failure.sessionUnavailable
                        }
                        guard !requireVerifiedRestore || restoredHistory || candidate.objectValue?["sessionId"] == .string(conversationID) ||
                            candidate.objectValue?["_meta"]?.objectValue?["hermes"]?.objectValue?["sessionProvenance"]?.objectValue?["acpSessionId"] == .string(conversationID) else {
                            throw Failure.sessionUnavailable
                        }
                        restored = candidate
                    } catch {
                        try Task.checkCancellation()
                        if let failure { throw failure }
                        throw Failure.sessionUnavailable
                    }
                }
            }
            if conversationID != nil && restored == nil { throw Failure.sessionUnavailable }
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
            if let permissionMode {
                startupTimeout = .modeSetupTimedOut
                let available = session.objectValue?["modes"]?.objectValue?["availableModes"]
                if !continued || available != nil {
                    guard case .array(let modes)? = available,
                          modes.contains(where: { $0.objectValue?["id"] == .string(permissionMode) }) else {
                        throw Failure.incompatibleVersion
                    }
                }
                _ = try await request("session/set_mode", ["sessionId": .string(id), "modeId": .string(permissionMode)])
            }
            // Conservative boundary: any attempted prompt write makes delivery uncertain.
            prompting = true
            let response = try await request("session/prompt", ["sessionId": .string(id),
                "prompt": .array([.object(["type": .string("text"), "text": .string(message)])])])
            guard case .string(let reason)? = response.objectValue?["stopReason"],
                  ["end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled"].contains(reason),
                  permissions.isEmpty else { throw Failure.invalidResponse }
            try Task.checkCancellation()
            return Reply(sessionID: id, text: text, stopReason: deniedPermission ? "permission_denied" : reason,
                continued: continued, detail: nil)
        } onCancel: { Task { await self.cancel(error: CancellationError()) } }
        deadlineGeneration += 1
        deadline?.cancel(); deadline = nil
        if !keepAlive { await close() }
        return reply
        } catch {
            let reportedError: any Error = (error as? Failure == .timedOut && !prompting) ? startupTimeout : error
            shutdown()
            await cleanup?.value
            reader?.cancel()
            try? output.fileHandleForReading.close()
            throw reportedError
        }
    }

    func close() async {
        cancel(error: Failure.interrupted)
        shutdown()
        await cleanup?.value
        reader?.cancel()
        try? output.fileHandleForReading.close()
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
                    guard prompting else {
                        if [JSONValue.string("agent_message_chunk"), .string("user_message_chunk")].contains(event.objectValue?["sessionUpdate"] ?? .null) { restoredHistory = true }
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
        guard prompting, params["sessionId"] == sessionID.map(JSONValue.string), sessionID != nil,
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

    /// A timer whose sleep finished just as its phase answered must not kill
    /// the session that has since moved on (next phase, or kept alive).
    private func expire(_ generation: Int) {
        guard generation == deadlineGeneration else { return }
        cancel(error: Failure.timedOut)
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
        pipeReader?.cancel(); pipeReader = nil
        reader?.cancel()
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

/// Each idle ACP process has its own kernel readiness source. Foundation's
/// shared FileHandle.AsyncBytes reader can block on an idle retained pipe and
/// starve initialization on another connection. No blocking read or per-chunk
/// Task is used here; the sole consumer preserves wire order and backpressure.
private final class AgentACPPipeReader: @unchecked Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let source: any DispatchSourceRead
    private let fd: Int32

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
        continuation.onTermination = { [weak self] _ in self?.source.cancel() }
        source.resume()
    }

    func cancel() {
        continuation.finish()
        source.cancel()
    }

    deinit { cancel() }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !source.isCancelled {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                switch continuation.yield(Data(buffer.prefix(count))) {
                case .enqueued: continue
                case .dropped:
                    continuation.finish(throwing: AgentACPClient.Failure.tooLarge)
                    source.cancel(); return
                case .terminated: source.cancel(); return
                @unknown default:
                    continuation.finish(throwing: AgentACPClient.Failure.interrupted)
                    source.cancel(); return
                }
            }
            if count == 0 { continuation.finish(); source.cancel(); return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            continuation.finish(throwing: AgentACPClient.Failure.interrupted)
            source.cancel(); return
        }
    }
}

/// Bounded process ownership only. Conversation history remains with the ACP peer.
actor AgentACPConnections {
    static let shared = AgentACPConnections()
    struct Lease: Sendable { let key: String; let generation: UUID; let client: AgentACPClient }
    private struct Entry {
        let client: AgentACPClient
        let configuration: String
        var generation: UUID = UUID()
        var busy: Bool
        var expiry: Task<Void, Never>?
        var idleSince = Date()
    }
    private var entries: [String: Entry] = [:]

    func acquire(peer: String, conversation: String?, configuration: String) async throws -> Lease {
        let key = peer + ":" + (conversation ?? UUID().uuidString)
        if let entry = entries[key] {
            guard !entry.busy else { throw AgentACPClient.Failure.busy }
            if entry.configuration == configuration {
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
        // Finished conversations idle for 30 min; at the cap an idle one makes
        // room instead of every new conversation reading "already answering".
        // First one whose peer reopens sessions by id; otherwise the longest
        // idle, only once it has sat 10 min (it cannot continue after this).
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
        let client = AgentACPClient()
        entries[key] = Entry(client: client, configuration: configuration, busy: true)
        return Lease(key: key, generation: entries[key]!.generation, client: client)
    }

    @discardableResult
    func finish(_ lease: Lease, peer: String, conversation: String?) async -> Bool {
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

    func closeAll() async {
        let owned = entries.values
        entries.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for entry in owned { entry.expiry?.cancel(); group.addTask { await entry.client.close() } }
        }
    }

    func revoke(peer: String) async {
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

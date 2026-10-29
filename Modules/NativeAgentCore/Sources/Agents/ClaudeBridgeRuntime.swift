import Foundation
import NativeAgentShared
import Darwin
import Network
import ChatTurnRuntime
import ChatTurnContracts
import AgentConversations
import ChatToolParsing
import Cognition
import ContextFlow
import PersonaEngine
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore
import Privacy
import MacControl
// Blueprint: | `ClaudeBridgeRuntime.swift` | Authenticated HTTP/contact routes and generation-ordered contact lifecycle; stop closes admission before passive cleanup, preserving accepted turns/tools; the 64-request ceiling inherited from connection admission now holds workers/actual tool dispatches until exit, beyond response deadlines; the shared human-pausable tool ceiling returns unknown on timeout without prematurely settling the tool receipt; one recovery per listener generation owns concurrent Codex/OMP children through exit, including ProcessExecution-owned helper reaping; live payload publication, retained clients and event transport |

/// Factories and app observations bound at launch; ingress and retained delivery stay with the agent runtime.
public protocol ClaudeBridgeRuntimePort: ClaudeBridgeMessagePort {
    var dataRoot: URL { get }
    var cognition: NativeCognitionRuntime { get }
    var contextFlow: NativeContextFlowRuntime { get }
    var tasks: AgentContactTasks { get }
    var grpcPort: UInt16? { get }
    var preferredPersona: String? { get }
    var preferredSessionID: String? { get }
    func chatClient() -> SwiftNativeChatOrchestrationClient
    func toolClient(verifiedSessionID: String?) -> any ToolDispatchClient
    func completionSender(dataRoot: URL) -> any AgentBridgeCompletionSending
    func receiveGrok(_ reply: GrokReplyInput, principal: AgentBridgePrincipal, dataRoot: URL) async throws
    func publishChatTurnCompleted(sessionID: String?) async
}

public final class ClaudeBridgeRuntime: @unchecked Sendable, BridgeHTTPServer, ClaudeBridgeStatePort {
    let host: any ClaudeBridgeRuntimePort
    var tasks: AgentContactTasks { host.tasks }

    public init(port: any ClaudeBridgeRuntimePort) {
        self.host = port
    }

    public static let port = InstallPaths.current.loopbackPorts().bridge
    private static let maxRequestBodyBytes = 4 * 1024 * 1024

    private static let connectionDeadlineSeconds: Int = 30
    /// Work-phase bound for /claude/tool dispatches.
    public static let toolWorkDeadlineSeconds: Int = 300
    /// Work-phase bound for the read/debug endpoints (/claude/state, /claude/organism_debug). Both await the cognition runtime actor; a stalled actor left their detached Tasks and connections unbounded. Short by design — neither endpoint
    /// does LLM work.
    public static let readWorkDeadlineSeconds: Int = 60

    /// Claim-once latch shared by a work Task and its deadline timer so exactly one of them writes the HTTP response.
    public final class WorkLatch: @unchecked Sendable {
        public init() {}

        private let lock = NSLock()
        private var claimed = false
        private var deadlineWork: DispatchWorkItem?

        /// Returns true exactly once. The winner also cancels the deadline this latch owns, so a burst of requests can no longer stack live timers that each retain the bridge (and the connection) until their deadline elapses.
        public func claim() -> Bool {
            lock.lock()
            if claimed {
                lock.unlock()
                return false
            }
            claimed = true
            let pending = deadlineWork
            deadlineWork = nil
            lock.unlock()
            // Cancelling from inside the deadline's own execution is a no-op.
            pending?.cancel()
            return true
        }

        /// Arms the single deadline timer this latch owns. If the work already claimed the response, nothing is scheduled at all.
        public func arm(afterSeconds seconds: Int, _ body: @escaping @Sendable () -> Void) {
            let work = DispatchWorkItem(block: body)
            lock.lock()
            let alreadyClaimed = claimed
            if !alreadyClaimed { deadlineWork = work }
            lock.unlock()
            guard !alreadyClaimed else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
        }
    }

    private let bridgeListener = NativeLoopbackListener(
        port: ClaudeBridgeRuntime.port,
        label: "ClaudeBridge"
    )
    /// Doctor's "Local bridges" row: which port this bridge got, or why it has none.
    public var listenerHealth: NativeLoopbackListener.Health { bridgeListener.health }
    private let stateLock = NSLock()
    private var _token: String = ""
    private var _activePort: UInt16 = 0
    private var replyRecoveryTask: Task<Void, Never>?
    private var replyRecoveryToken: String?
    private var contactLifecycleRevision: UInt64 = 0
    private var contactLifecycleWorkers: [UInt64: Task<Void, Never>] = [:]
    private struct RequestWorker {
        let connection: ObjectIdentifier
        let token: String
        let latch: WorkLatch
        let accepted: Bool
        var worker: Task<Void, Never>?
        var operation: Task<JSONValue, Error>?
        var operationAdmitted = false
        var operationClosed = false
    }
    // A response timeout does not release a slot while its operation lives. Use the same 64-request ceiling as connection admission.
    private var requestWorkers: [UUID: RequestWorker] = [:]
    public private(set) var startedAt: Date = Date()
    // Connection UUIDs gate exact request-read deadlines so reused connection identities cannot inherit a late timeout.
    private struct ConnectionEntry {
        let conn: NWConnection
        var deadline: BridgeReadDeadlineState
        let deadlineWork: DispatchWorkItem
    }
    private var connections: [ObjectIdentifier: ConnectionEntry] = [:]

    private func updateContactLifecycleLocked(active: Bool) {
        contactLifecycleRevision += 1
        let revision = contactLifecycleRevision
        tasks.setBridgeAdmission(active, revision: revision)
        contactLifecycleWorkers[revision] = Task { [self] in
            await tasks.setBridgeActive(active, revision: revision)
            _ = stateLock.withLock { contactLifecycleWorkers.removeValue(forKey: revision) }
        }
    }

    /// Retain each request through actual exit, including a tool operation whose HTTP deadline has already answered. Accepted tool work survives disconnect/stop; reads are canceled with their connection.
    func startRequest(conn: NWConnection, latch: WorkLatch, priority: TaskPriority,
                      accepted: Bool = false,
                      operation: @escaping @Sendable (UUID) async -> Void) -> Task<Void, Never>? {
        stateLock.withLock {
            guard !_token.isEmpty, requestWorkers.count < 64,
                  connections[ObjectIdentifier(conn)] != nil else { return nil }
            let id = UUID()
            requestWorkers[id] = RequestWorker(connection: ObjectIdentifier(conn), token: _token, latch: latch, accepted: accepted)
            let worker = Task.detached(priority: priority) { [self] in
                defer { finishRequest(id, operation: false) }
                guard !Task.isCancelled else { return }
                await operation(id)
            }
            requestWorkers[id]?.worker = worker
            return worker
        }
    }

    private func finishRequest(_ id: UUID, operation: Bool) {
        stateLock.withLock {
            if operation { requestWorkers[id]?.operation = nil }
            else { requestWorkers[id]?.worker = nil }
            if let entry = requestWorkers[id], entry.worker == nil, entry.operation == nil {
                requestWorkers.removeValue(forKey: id)
            }
        }
    }

    func runToolOperation(_ id: UUID, operation: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        // Created inside TurnDeadline's scope so human waits still pause the existing active-work ceiling. Retain the actual dispatch, not just the wrapper that returns as soon as that ceiling fires.
        let worker = try stateLock.withLock {
            guard requestWorkers[id]?.operationClosed == false, !Task.isCancelled else { throw CancellationError() }
            requestWorkers[id]?.operationAdmitted = true
            let worker = Task { [self] in
                defer { finishRequest(id, operation: true) }
                return try await operation()
            }
            requestWorkers[id]?.operation = worker
            return worker
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    func closeUnstartedTool(_ id: UUID) -> Bool {
        stateLock.withLock {
            guard requestWorkers[id]?.operationAdmitted == false else { return false }
            requestWorkers[id]?.operationClosed = true
            return true
        }
    }

    private func retireRequests(connection: ObjectIdentifier? = nil, token: String? = nil) {
        let entries = stateLock.withLock {
            requestWorkers.values.filter {
                (connection == nil || $0.connection == connection) && (token == nil || $0.token == token)
            }
        }
        for entry in entries {
            _ = entry.latch.claim()
            if !entry.accepted { entry.worker?.cancel(); entry.operation?.cancel() }
        }
    }

    // One bounded event history feeds state readback and live subscribers; closing a connection removes its subscription.
    private static let recentToolCallsCap = 50
    private var recentToolCalls: [BridgeEvent] = []
    private var eventSubscribers: [ObjectIdentifier: NWConnection] = [:]
    private var eventSeq: UInt64 = 0
    private let eventDeliveryQueue = DispatchQueue(label: "com.nativeagent.bridge.events")

    /// Bridge activity event. Pushed into recentToolCalls (bounded) AND fanned out to /claude/events SSE subscribers. Payload values must be JSONSerialization-compatible (String/Int/Bool/NSNull/Array/Dict of same) — kept as a pre-
    /// serialized JSON string to satisfy strict- concurrency Sendable checking without losing structured access.
    struct BridgeEvent: @unchecked Sendable {
        let seq: UInt64
        let timestamp: Date
        let kind: String          // "tool", "message_in", "message_out", "message_failed", "tool_failed"
        let payload: [String: Any]

        var asJSON: [String: Any] {
            var obj: [String: Any] = [
                "seq": seq,
                "timestamp": NativeTimestampFormat.plainZulu(timestamp),
                "kind": kind,
            ]
            for (k, v) in payload { obj[k] = v }
            return obj
        }
    }

    /// Canonical SSE framing for both a live fan-out and a reconnect backfill. Keeping this at the route owner prevents a valid bridge event from being silently emitted in one format and replayed in another.
    static func eventStreamFrame(for event: BridgeEvent) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: event.asJSON))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Data("data: \(json)\n\n".utf8)
    }

    /// Bounded projection used by the state endpoint and hermetic route evals. Callers receive values, never access to the mutable event ring.
    public func recentEventPayloads() -> [[String: Any]] {
        stateLock.lock()
        let recent = recentToolCalls
        stateLock.unlock()
        return recent.map { $0.asJSON }
    }

    /// A returned envelope proves dispatch completed, not that the requested operation succeeded. Share chat's exact classification; do not turn queued/approval/unknown results into success or retain result content.
    public func publishToolResultEvent(name: String, surface: String, result: JSONValue, durationMs: Int) {
        let outcome = ChatToolOutcome.exactResultClass(result)
        let ok: Any
        switch outcome {
        case .succeeded: ok = true
        case .failed, .refused, .cancelled, .timeout: ok = false
        case .unknown: ok = NSNull()
        }
        publishEvent(kind: "tool", payload: [
            "name": name, "surface": surface, "ok": ok,
            "resultClass": outcome.rawValue, "dispatchCompleted": true,
            "durationMs": durationMs,
        ])
    }

    /// Canonical organism-debug event seam shared by the HTTP endpoint and no-network eval harness. Optional fields are omitted rather than serialized as null so reset/settle/clear events stay minimal.
    public func publishOrganismDebugEvent(
        status: String,
        scenario: String? = nil,
        ttlSeconds: Int? = nil
    ) {
        var payload: [String: Any] = ["status": status]
        if let scenario { payload["scenario"] = scenario }
        if let ttlSeconds { payload["ttlSeconds"] = ttlSeconds }
        publishEvent(kind: "organism_debug", payload: payload)
    }

    public var token: String { stateLock.lock(); defer { stateLock.unlock() }; return _token }
    public var activePort: UInt16 { stateLock.lock(); defer { stateLock.unlock() }; return _activePort }

    // Lazily-built ChatTurnRuntime client + dispatcher. Built off-MainActor on first need. Both are Sendable.
    let clientLock = NSLock()
    private var cachedToolClient: (any ToolDispatchClient)?

    // MARK: - Token storage

    private var configDir: URL {
        AgentHostDirectory.bridgeDiscoveryDirectory(dataRoot: host.dataRoot)
    }

    private var tokenFileURL: URL {
        configDir.appendingPathComponent("token")
    }

    private var descriptorFileURL: URL {
        configDir.appendingPathComponent("bridge.json")
    }

    private func writeDiscoveryFiles(token: String, port: UInt16) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir.path)
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "host": "127.0.0.1",
            "port": Int(port),
            "url": "http://127.0.0.1:\(port)",
            "token": token,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "writtenAt": NativeTimestampFormat.plainZulu(Date()),
        ]
        guard let descriptor = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        _ = NativePrivateFile.write(Data(token.utf8), to: tokenFileURL)
        _ = NativePrivateFile.write(descriptor, to: descriptorFileURL)
        // Peers receive only the address and authenticate with their own contact secret.
        let peerDir = AgentHostDirectory.peerDescriptorDirectory(dataRoot: host.dataRoot)
        try? FileManager.default.createDirectory(at: peerDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: peerDir.path)
        if let peerDescriptor = try? JSONSerialization.data(
            withJSONObject: ["schemaVersion": 1, "url": "http://127.0.0.1:\(port)"], options: [.prettyPrinted]) {
            _ = NativePrivateFile.write(peerDescriptor, to: peerDescriptorFileURL)
        }
    }

    private var peerDescriptorFileURL: URL {
        URL(fileURLWithPath: AgentHostDirectory.bridgeDescriptorPath(dataRoot: host.dataRoot))
    }

    private func removeDiscoveryFiles() {
        _ = tokenFileURL.path.withCString { Darwin.unlink($0) }
        _ = peerDescriptorFileURL.path.withCString { Darwin.unlink($0) }
        _ = descriptorFileURL.path.withCString { Darwin.unlink($0) }
    }

    // MARK: - Lifecycle

    /// Start the bridge on its preferred port, advancing deterministically on collisions and publishing the selected endpoint once it is ready.
    public func startServer() async {
        await Task.detached(priority: .background) { [weak self] in
            self?.startSync()
        }.value
    }

    /// Synchronous entry for the AppDelegate bootstrap path. We were dispatching via `Task.detached(priority: .background) { await startServer() }` from `applicationDidFinishLaunching`, but the `.background` Task was being indefinitely
    /// deferred on cold-launch (the SwiftUI lifecycle finished, BUT the cooperative pool never scheduled our task — no log, no bind, no token file). Mirrors MacControlBridge.shared.start() which uses DispatchQueue and runs every time. NOT
    /// async.
    public func startSyncForBootstrap() {
        nativeLog("[claude-bootstrap] startSyncForBootstrap entered — invoking startSync")
        startSync()
    }

    /// Cancel the listener, all live connections + their deadline timers, clear the in-memory endpoint, and remove discovery files. Idempotent.
    public func stop() {
        teardown(token: nil)
    }

    /// A listener's token fences retirement; explicit stop also closes the listener.
    private func teardown(token: String?) {
        stateLock.lock()
        guard token == nil || _token == token else { stateLock.unlock(); return }
        let entries = Array(connections.values)
        let retiringToken = _token
        connections.removeAll()
        _token = ""
        _activePort = 0
        updateContactLifecycleLocked(active: false)
        let recovery = replyRecoveryTask
        eventSubscribers.removeAll()
        if token == nil { bridgeListener.stop() }
        removeDiscoveryFiles()
        stateLock.unlock()
        recovery?.cancel()
        retireRequests(token: retiringToken)
        for entry in entries {
            entry.deadlineWork.cancel()
            entry.conn.cancel()
        }
    }

    private func startSync() {
        // The coding-organ return listener is ordinary NativeAgent infrastructure, not a developer-mode capability. It is always resident so installed Codex/Claude sessions can complete their authenticated round trip. Authority still comes
        // from loopback-only binding, a per-launch private bearer, and the normal Trust Center / approval gates applied at each message and tool endpoint.
        stateLock.lock()
        let alreadyRunningOrStarting = bridgeListener.isActive || !_token.isEmpty
        stateLock.unlock()
        nativeLog(
            "[ClaudeBridge] startSync entered (state=%@)",
            alreadyRunningOrStarting ? "already-running-or-starting" : "idle"
        )
        guard !alreadyRunningOrStarting else { return }
        installAgentLivePublisher()

        guard let tk = BridgeCore.generateToken() else {
            nativeLog("[ClaudeBridge] failed to generate token")
            return
        }
        stateLock.lock()
        guard !bridgeListener.isActive, _token.isEmpty else {
            stateLock.unlock()
            return
        }
        _token = tk
        _activePort = 0
        updateContactLifecycleLocked(active: true)
        removeDiscoveryFiles()
        let started = bridgeListener.start(
            onReady: { [weak self] port in
                self?.handleListenerReady(token: tk, port: port)
            },
            onConnection: { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            },
            onTerminated: { [weak self] in
                self?.teardown(token: tk)
            }
        )
        stateLock.unlock()
        if !started {
            teardown(token: tk)
        }
    }

    private func handleListenerReady(token: String, port: UInt16) {
        stateLock.lock()
        guard _token == token else {
            stateLock.unlock()
            return
        }
        _activePort = port
        startedAt = Date()
        // Hold the lifecycle lock over the tiny atomic publications so stop() cannot remove them and then lose a race to a stale ready callback.
        writeDiscoveryFiles(token: token, port: port)
        startReplyRecoveryLocked(token: token)
        stateLock.unlock()

        nativeLog("[ClaudeBridge] listening on 127.0.0.1:%d", Int(port))
    }

    private func startReplyRecoveryLocked(token: String) {
        guard replyRecoveryTask == nil, replyRecoveryToken != token else { return }
        replyRecoveryToken = token
        replyRecoveryTask = Task.detached(priority: .utility) { [self] in
            defer {
                stateLock.withLock {
                    replyRecoveryTask = nil
                    // A new listener may have become ready while the old helper drained. Its state change admits one recovery.
                    if !_token.isEmpty, _activePort != 0, _token != token {
                        startReplyRecoveryLocked(token: _token)
                    }
                }
            }
            guard !Task.isCancelled, self.token == token else { return }
            // Each organ recovers independently; the retained parent owns both children until exit, including cancellation and helper reaping.
            async let codex: Void = startCodexReplyJobRecovery(token: token)
            async let omp: Void = AgentBridgeRuntime.startOMPReplyJobRecovery()
            _ = await (codex, omp)
        }
    }

    /// Relaunch repair for durable Codex reply jobs. The Node helper performs a single locked scan and gives every job its own delivery lock; it does not install a poller or another scheduler.
    private func startCodexReplyJobRecovery(token: String) async {
        let environment = ProcessInfo.processInfo.environment
        if ["1", "true", "yes"].contains(
            environment["NATIVE_AGENT_CODEX_REPLY_RECOVERY_DISABLED"]?.lowercased() ?? ""
        ) {
            return
        }
        let dataRoot = PersistenceCore.defaultDataRoot()
        let repoRoot = dataRoot.deletingLastPathComponent()
        guard let helper = AgentBridgeRuntime.codexHelperURL(dataRoot: dataRoot) else {
            nativeLog(
                "[ClaudeBridge] codex wake helper missing; expected %@",
                AgentBridgeRuntime.expectedHelperPath(named: "codex_thread_wakeup.js", dataRoot: dataRoot).path
            )
            return
        }
        nativeLog("[ClaudeBridge] codex wake helper: %@", helper.path)
        let processEnvironment = AgentBridgeRuntime.processEnvironment(base: environment)
        guard let node = AgentBridgeRuntime.executableURL(named: "node", environment: processEnvironment) else {
            return
        }
        var childEnvironment = processEnvironment
        childEnvironment["NATIVE_AGENT_DATA_ROOT"] = dataRoot.path
        if childEnvironment["CODEX_BIN"] == nil,
           let codex = AgentBridgeRuntime.executableURL(named: "codex", environment: processEnvironment) {
            childEnvironment["CODEX_BIN"] = codex.path
        }
        guard !Task.isCancelled, self.token == token else { return }
        do {
            // The existing process owner retains/reaps the helper and its descendants on cancellation; this recovery task awaits exit.
            let result = try await ProcessExecution().run(executable: node.path,
                arguments: [helper.path, "--recover-reply-jobs"], currentDirectory: repoRoot,
                environment: childEnvironment, standardInput: nil, timeoutSeconds: nil, outputByteLimit: 0)
            if result.exitCode != 0, !Task.isCancelled {
                nativeLog("[ClaudeBridge] Codex reply-job recovery exited %d", Int(result.exitCode))
            }
        } catch {
            if !Task.isCancelled {
                nativeLog("[ClaudeBridge] could not start Codex reply-job recovery: %@", String(describing: error))
            }
        }
    }


    private func accept(_ conn: NWConnection) {
        guard BridgeCore.endpointIsLoopback(conn.endpoint) else { conn.cancel(); return }
        stateLock.lock()
        let bridgeIsReady = !_token.isEmpty && _activePort != 0
        stateLock.unlock()
        guard bridgeIsReady else { conn.cancel(); return }
        let key = ObjectIdentifier(conn)
        // Per-connection read deadline — prevents a peer from holding a slot open forever by never sending the body bytes promised in Content-Length. UUID-gated (C5): a late fire only cancels the exact connection it was armed for, never an
        // ObjectIdentifier-reused sibling.
        let deadlineToken = UUID()
        let deadlineWork = DispatchWorkItem { [weak self] in
            self?.cancelUnroutedConnection(key: key, deadlineToken: deadlineToken)
        }
        stateLock.lock()
        guard connections.count < 64, !_token.isEmpty, _activePort != 0 else {
            stateLock.unlock()
            conn.cancel()
            return
        }
        connections[key] = ConnectionEntry(
            conn: conn,
            deadline: BridgeReadDeadlineState(token: deadlineToken),
            deadlineWork: deadlineWork
        )
        stateLock.unlock()
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(Self.connectionDeadlineSeconds),
            execute: deadlineWork
        )
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.stateLock.lock()
                let removed = self?.connections.removeValue(forKey: key)
                self?.eventSubscribers.removeValue(forKey: key)
                self?.stateLock.unlock()
                removed?.deadlineWork.cancel()
                self?.retireRequests(connection: key)
            default: break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        BridgeCore.readRequest(conn, buffered: Data(), maxBodyBytes: Self.maxRequestBodyBytes, server: self)
    }

    /// Cancel a connection whose request never fully arrived before its read deadline fired. Identity-gated so it cannot cancel a routed connection or a different connection that reused the ObjectIdentifier.
    private func cancelUnroutedConnection(key: ObjectIdentifier, deadlineToken: UUID) {
        stateLock.lock()
        guard let entry = connections[key],
              entry.deadline.shouldCancel(firingToken: deadlineToken) else {
            stateLock.unlock()
            return
        }
        connections.removeValue(forKey: key)
        stateLock.unlock()
        entry.conn.cancel()
    }

    // MARK: - Routing

    public func route(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        // The connection deadline covers request reads, never response work.
        let connKey = ObjectIdentifier(conn)
        stateLock.lock()
        var readDeadlineWork: DispatchWorkItem?
        if var entry = connections[connKey] {
            entry.deadline.routed = true
            connections[connKey] = entry
            readDeadlineWork = entry.deadlineWork
        }
        let liveToken = _token
        stateLock.unlock()
        readDeadlineWork?.cancel()
        if routeAgentContact(conn: conn, method: method, path: path, headers: headers, body: body) { return }
        // Constant-time authorization rejects an empty live token.
        switch BridgeCore.authorize(authorizationHeader: headers["authorization"], liveToken: liveToken) {
        case .serverStopping:
            writeJSON(conn, status: 503, obj: ["error": "server_stopping"])
            return
        case .unauthorized:
            writeJSON(conn, status: 401, obj: ["error": "unauthorized"])
            return
        case .authorized:
            break
        }

        let components = path.dropFirst().split(separator: "/", maxSplits: 1).map(String.init)
        let lane = components.first ?? ""
        let operation = components.count == 2 ? "/" + components[1] : path
        let principal = bridgeCallerPrincipal(headers: headers)
        if let peerID = principal?.peerID { AgentPeerStore(dataRoot: host.dataRoot).recordProof(peerID: peerID, inbound: true) }

        switch operation {
        case "/state":
            guard method == "GET" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleState(conn: conn, path: path)
        case "/message":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleMessage(conn: conn, body: body, defaultSender: lane, principal: principal)
        case "/tool":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleTool(conn: conn, body: body, principal: principal)
        case "/reply":
            guard method == "POST",
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let session = json["session_id"] as? String,
                  let request = json["request_id"] as? String,
                  let principal else {
                writeJSON(conn, status: 400, obj: ["error": "invalid_caller_result_request"])
                return
            }
            func wholeNumber(_ value: Any?) -> Int? {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return nil }
                return number.intValue
            }
            let offset = json["offset"] == nil ? 0 : wholeNumber(json["offset"])
            let maxChars = json["max_chars"] == nil ? 8000 : wholeNumber(json["max_chars"])
            guard let offset, (0...1_048_576).contains(offset), let maxChars, (1...16000).contains(maxChars) else {
                writeJSON(conn, status: 400, obj: ["error": "invalid_pagination",
                    "detail": "offset is an integer from 0 through 1048576; max_chars from 1 through 16000."])
                return
            }
            let tasks = self.tasks
            Task {
                let reply = await AgentContactRoutes.retainedReply(requestID: request, sessionID: session,
                    taskID: "na3.\(session).\(request)", receiptSessionID: session, offset: offset, maxChars: maxChars,
                    principal: principal, tasks: tasks)
                if reply.task == nil, reply.receipt["status"] as? String != "ok" {
                    if reply.receipt["evidence"] as? String == "canonical_task_unreadable" {
                        writeJSON(conn, status: 503, obj: reply.receipt)
                    } else {
                        writeJSON(conn, status: 404, obj: ["status": "unavailable",
                            "detail": "No retained result is available for this caller and request. Absence does not authorize resending.",
                            "evidence": reply.receipt["evidence"] ?? NSNull()])
                    }
                    return
                }
                writeJSON(conn, status: 200, obj: reply.receipt, onSent: { [task = reply.task] in
                    if let task, !task.text.isEmpty { Task { await tasks.recordReplyFetch(task) } }
                })
            }
        case "/organism/debug":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleOrganismDebug(conn: conn, body: body, path: path)
        case "/live":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleAgentLive(conn: conn, body: body, agent: lane)
        case "/events":
            guard method == "GET" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleEventsStream(conn: conn)
        default:
            writeJSON(conn, status: 404, obj: ["error": "unknown_path", "path": path])
        }
    }


    // MARK: - /claude/message

    var bridgeMessageRuntime: ClaudeBridgeMessageRuntime?

    // MARK: - Activity event publisher

    /// Push an event into the ring buffer + fan out to SSE subscribers. stateLock orders sequence assignment and delivery enqueueing together. Connection writes run on one serial queue, outside the state lock. `retain: false` fans out
    /// only: a live partial is stale the moment the next one lands and must not crowd real actions out of the backfill ring.
    public func publishEvent(kind: String, payload: [String: Any], retain: Bool = true) {
        stateLock.lock()
        eventSeq += 1
        let event = BridgeEvent(seq: eventSeq, timestamp: Date(), kind: kind, payload: payload)
        if retain { recentToolCalls.append(event) }
        if recentToolCalls.count > Self.recentToolCallsCap {
            recentToolCalls.removeFirst(recentToolCalls.count - Self.recentToolCallsCap)
        }
        let subs = Array(eventSubscribers.values)
        if !subs.isEmpty {
            eventDeliveryQueue.async {
                let chunk = Self.eventStreamFrame(for: event)
                for sub in subs {
                    sub.send(content: chunk, completion: .contentProcessed { _ in })
                }
            }
        }
        stateLock.unlock()
    }

    private func handleEventsStream(conn: NWConnection) {
        // SSE headers — keep-alive, never close, no Content-Length.
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        let hello = "event: hello\ndata: {\"connected\":true,\"recentToolCallsCap\":\(Self.recentToolCallsCap)}\n\n"
        let initial = Data((headers + hello).utf8)
        let key = ObjectIdentifier(conn)

        // Register and enqueue the backfill under the same lock as live events. A publisher can only enqueue this subscriber's live sends after it.
        stateLock.lock()
        guard connections[key] != nil else {
            stateLock.unlock()
            return
        }
        let backfill = recentToolCalls
        eventSubscribers[key] = conn
        eventDeliveryQueue.async {
            conn.send(content: initial, completion: .contentProcessed { _ in })
            for event in backfill {
                conn.send(content: Self.eventStreamFrame(for: event), completion: .contentProcessed { _ in })
            }
        }
        stateLock.unlock()
    }

    // MARK: - HTTP response

    public func writeJSON(_ conn: NWConnection, status: Int, obj: [String: Any], onSent: (@Sendable () -> Void)? = nil) {
        BridgeCore.writeJSON(conn, status: status, obj: obj, onSent: onSent)
    }
}

extension ClaudeBridgeRuntime {
    func installAgentLivePublisher() {
        Task {
            await AgentConversationLiveHub.shared.setPublisher { [weak self] live in
                self?.publishEvent(kind: "agent_live", payload: Self.agentLivePayload(live), retain: false)
            }
        }
    }

    static func agentLivePayload(_ live: AgentConversationLive) -> [String: Any] {
        return [
            "key": live.key, "recordId": live.recordID ?? NSNull(), "operationId": live.operationID ?? NSNull(),
            "agent": live.agent, "messageId": live.messageID ?? NSNull(), "lane": live.lane,
            "state": live.state, "streams": live.streams,
            "startedAt": NativeTimestampFormat.plainZulu(live.startedAt), "lastActivityAt": NativeTimestampFormat.plainZulu(live.lastActivityAt),
            "partialText": live.partial.map { NativeAgentSecretRedactor.redactText($0) } ?? NSNull(),
            "partialChars": live.partialChars, "partialTruncated": live.partialTruncated,
            "note": live.note.map { NativeAgentSecretRedactor.redactText($0) } ?? NSNull(),
            "finishedAt": live.finishedAt.map { NativeTimestampFormat.plainZulu($0) } ?? NSNull(),
        ]
    }

    func handleAgentLive(conn: NWConnection, body: Data, agent: String) {
        messageRuntime().handleAgentLive(response: { [weak self] status, object in
            self?.writeJSON(conn, status: status, obj: object)
        }, body: body, agent: agent)
    }
}

extension ClaudeBridgeRuntime {
    func handleState(conn: NWConnection, path: String) {
        // Same WorkLatch + asyncAfter bound as handleMessage/handleTool: exactly one of the work Task and the deadline writes the response.
        let workLatch = WorkLatch()
        let workTask = startRequest(conn: conn, latch: workLatch, priority: .userInitiated) { [weak self] _ in
            guard let self else { return }
            let payload = await ClaudeBridgeReadout.statePayload(
                dataRoot: self.host.dataRoot,
                port: self
            )
            guard !Task.isCancelled else { return }
            guard workLatch.claim() else { return }
            self.writeJSON(conn, status: 200, obj: payload)
        }
        guard let workTask else { writeJSON(conn, status: 503, obj: ["error": "server_stopping_or_busy"]); return }
        workLatch.arm(afterSeconds: Self.readWorkDeadlineSeconds) { [weak self] in
            guard let self, workLatch.claim() else { return }
            workTask.cancel()
            self.writeJSON(conn, status: 504, obj: [
                "error": "work_timeout",
                "path": path,
                "seconds": Self.readWorkDeadlineSeconds,
                "outcome": "unknown",
            ])
        }
    }


    public var preferredPersona: String? { host.preferredPersona }
    public var preferredSessionID: String? { host.preferredSessionID }
    public var cognition: NativeCognitionRuntime { host.cognition }
    public var contextFlow: NativeContextFlowRuntime { host.contextFlow }

    public func toolClient(verifiedSessionID: String?) -> any ToolDispatchClient {
        if let verifiedSessionID { return host.toolClient(verifiedSessionID: verifiedSessionID) }
        return clientLock.withLock {
            if let cachedToolClient { return cachedToolClient }
            let client = host.toolClient(verifiedSessionID: nil)
            cachedToolClient = client
            return client
        }
    }
    private func routeAgentContact(conn: NWConnection, method: String, path: String,
                                   headers: [String: String], body: Data) -> Bool {
        AgentContactRoutes(token: { self.token }, port: { self.activePort }, grpcPort: { self.host.grpcPort },
            tasks: { self.tasks }, receiveGrok: { reply, principal, root in
                try await self.host.receiveGrok(reply, principal: principal, dataRoot: root)
            }).route(conn: conn, method: method, path: path, headers: headers, body: body, dataRoot: host.dataRoot)
    }
}

public extension ClaudeBridgeRuntimePort {
    func activeSessionID(dataRoot: URL) -> String? {
        ClaudeBridgeReadout.readBridgeActiveSession(dataRoot: dataRoot, preferred: { self.preferredSessionID }).id
    }
    func activePersona(dataRoot: URL) -> String? {
        ClaudeBridgeReadout.readActivePersona(dataRoot: dataRoot, preferred: preferredPersona)
    }
}

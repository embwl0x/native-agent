import Foundation
import Darwin
import Network
import ChatTurnRuntime
import ChatTurnContracts
import AgentConversations
import ChatToolParsing
import Cognition
import ContextFlow
import GrokLink
import PersonaEngine
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore
import Privacy
import MacControl
// Blueprint: | `ClaudeBridgeRuntime.swift` | Authenticated HTTP/contact routes and generation-ordered contact lifecycle; stop closes admission before passive cleanup, preserving accepted turns/tools; the 64-request ceiling inherited from connection admission now holds workers/actual tool dispatches until exit, beyond response deadlines; the shared human-pausable tool ceiling returns unknown on timeout without prematurely settling the tool receipt; one recovery per listener generation owns concurrent Codex/OMP children through exit, including SystemProcessAdapter-owned helper reaping; live payload publication, retained clients and event transport |

/// Factories and app observations bound at launch; ingress and retained delivery
/// stay with the agent runtime.
public protocol ClaudeBridgeRuntimePort: ClaudeBridgeMessagePort {
    var dataRoot: URL { get }
    var cognition: NativeCognitionRuntime { get }
    var contextFlow: NativeContextFlowRuntime { get }
    var tasks: AgentContactTasks { get }
    var grpcPort: UInt16? { get }
    var preferredPersona: String? { get }
    var preferredSessionID: String? { get }
    func chatClient() -> any ChatOrchestrationClient
    func toolClient(verifiedSessionID: String?) -> any ToolDispatchClient
    func completionSender(dataRoot: URL) -> any AgentBridgeCompletionSending
    func receiveGrok(_ reply: GrokReplyInput, principal: AgentBridgePrincipal, dataRoot: URL) async throws
    func publishChatTurnCompleted(sessionID: String?) async
}

public final class ClaudeBridgeRuntime: @unchecked Sendable, BridgeHTTPServer, ClaudeBridgeStatePort {
    let host: any ClaudeBridgeRuntimePort
    private var tasks: AgentContactTasks { host.tasks }

    public init(port: any ClaudeBridgeRuntimePort) {
        self.host = port
    }

    public static let port = InstallPaths.current.loopbackPorts().bridge
    private static let maxRequestBodyBytes = 4 * 1024 * 1024

    private static let connectionDeadlineSeconds: Int = 30
    /// Work-phase bound for /claude/tool dispatches.
    public static let toolWorkDeadlineSeconds: Int = 300
    /// Work-phase bound for the read/debug endpoints (/claude/state,
    /// /claude/organism_debug). Both await the cognition runtime actor; a
    /// stalled actor left their detached Tasks and connections unbounded.
    /// Short by design — neither endpoint does LLM work.
    public static let readWorkDeadlineSeconds: Int = 60

    /// Claim-once latch shared by a work Task and its deadline timer so
    /// exactly one of them writes the HTTP response.
    public final class WorkLatch: @unchecked Sendable {
        public init() {}

        private let lock = NSLock()
        private var claimed = false
        private var deadlineWork: DispatchWorkItem?

        /// Returns true exactly once. The winner also cancels the deadline this
        /// latch owns, so a burst of requests can no longer stack live timers
        /// that each retain the bridge (and the connection) until their
        /// deadline elapses.
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

        /// Arms the single deadline timer this latch owns. If the work already
        /// claimed the response, nothing is scheduled at all.
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
    // A response timeout does not release a slot while its operation lives.
    // Use the same 64-request ceiling as connection admission.
    private var requestWorkers: [UUID: RequestWorker] = [:]
    public private(set) var startedAt: Date = Date()
    // Each accepted connection owns one exact cancellable request-read deadline,
    // UUID-gated via `BridgeReadDeadlineState` so a late deadline fire can never
    // cancel a different connection that reused an `ObjectIdentifier` (C5:
    // adopted from MacControlBridge; previously a plain `[weak conn]` timer in a
    // sibling dict).
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

    /// Retain each request through actual exit, including a tool operation
    /// whose HTTP deadline has already answered. Accepted tool work survives
    /// disconnect/stop; reads are canceled with their connection.
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

    private func runToolOperation(_ id: UUID, operation: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        // Created inside TurnDeadline's scope so human waits still pause the
        // existing active-work ceiling. Retain the actual dispatch, not just
        // the wrapper that returns as soon as that ceiling fires.
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

    private func closeUnstartedTool(_ id: UUID) -> Bool {
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

    // MARK: - Activity ring buffer + SSE subscribers
    //
    // Phase 3b (recentToolCalls): bounded queue records every /claude/tool
    // dispatch so /claude/state can surface "what did she just do for me."
    // Phase 3d (events stream): the SAME events feed any /claude/events SSE
    // subscribers — one push, many consumers. Subscribers are NWConnections
    // held in append-only fashion for the connection's lifetime; the conn's
    // stateUpdateHandler drops it on close.
    private static let recentToolCallsCap = 50
    private var recentToolCalls: [BridgeEvent] = []
    private var eventSubscribers: [ObjectIdentifier: NWConnection] = [:]
    private var eventSeq: UInt64 = 0
    private let eventDeliveryQueue = DispatchQueue(label: "com.nativeagent.bridge.events")

    /// Bridge activity event. Pushed into recentToolCalls (bounded) AND
    /// fanned out to /claude/events SSE subscribers. Payload values must
    /// be JSONSerialization-compatible (String/Int/Bool/NSNull/Array/Dict
    /// of same) — kept as a pre-serialized JSON string to satisfy strict-
    /// concurrency Sendable checking without losing structured access.
    struct BridgeEvent: @unchecked Sendable {
        let seq: UInt64
        let timestamp: Date
        let kind: String          // "tool", "message_in", "message_out", "message_failed", "tool_failed"
        let payload: [String: Any]

        var asJSON: [String: Any] {
            var obj: [String: Any] = [
                "seq": seq,
                "timestamp": ISO8601DateFormatter().string(from: timestamp),
                "kind": kind,
            ]
            for (k, v) in payload { obj[k] = v }
            return obj
        }
    }

    /// Canonical SSE framing for both a live fan-out and a reconnect backfill.
    /// Keeping this at the route owner prevents a valid bridge event from being
    /// silently emitted in one format and replayed in another.
    static func eventStreamFrame(for event: BridgeEvent) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: event.asJSON))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Data("data: \(json)\n\n".utf8)
    }

    /// Bounded projection used by the state endpoint and hermetic route evals.
    /// Callers receive values, never access to the mutable event ring.
    public func recentEventPayloads() -> [[String: Any]] {
        stateLock.lock()
        let recent = recentToolCalls
        stateLock.unlock()
        return recent.map { $0.asJSON }
    }

    /// A returned envelope proves dispatch completed, not that the requested
    /// operation succeeded. Share chat's exact classification; do not turn
    /// queued/approval/unknown results into success or retain result content.
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

    /// Canonical organism-debug event seam shared by the HTTP endpoint and
    /// no-network eval harness. Optional fields are omitted rather than
    /// serialized as null so reset/settle/clear events stay minimal.
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

    // Lazily-built ChatTurnRuntime client + dispatcher. Built off-MainActor on
    // first need. Both are Sendable.
    private let clientLock = NSLock()
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
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let descriptor = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        _ = NativePrivateFile.write(Data(token.utf8), to: tokenFileURL)
        _ = NativePrivateFile.write(descriptor, to: descriptorFileURL)
        // 2026-09-22: connected peers get the address only; they authenticate
        // with their own secret (contactHeaders), never the main bearer.
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

    /// Start the bridge on its preferred port, advancing deterministically on
    /// collisions and publishing the selected endpoint once it is ready.
    public func startServer() async {
        await Task.detached(priority: .background) { [weak self] in
            self?.startSync()
        }.value
    }

    /// Synchronous entry for the AppDelegate bootstrap path. We were
    /// dispatching via `Task.detached(priority: .background) { await
    /// startServer() }` from `applicationDidFinishLaunching`, but the
    /// `.background` Task was being indefinitely deferred on cold-launch
    /// (the SwiftUI lifecycle finished, BUT the cooperative pool never
    /// scheduled our task — no log, no bind, no token file). Mirrors
    /// MacControlBridge.shared.start() which uses DispatchQueue and runs
    /// every time. NOT async.
    public func startSyncForBootstrap() {
        nativeLog("[claude-bootstrap] startSyncForBootstrap entered — invoking startSync")
        startSync()
    }

    /// Cancel the listener, all live connections + their deadline timers,
    /// clear the in-memory endpoint, and remove discovery files. Idempotent.
    public func stop() {
        stateLock.lock()
        let entries = Array(connections.values)
        let retiringToken = _token
        connections.removeAll()
        _token = ""
        _activePort = 0
        updateContactLifecycleLocked(active: false)
        let recovery = replyRecoveryTask
        eventSubscribers.removeAll()
        bridgeListener.stop()
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
        // The coding-organ return listener is ordinary NativeAgent
        // infrastructure, not a developer-mode capability. It is always
        // resident so installed Codex/Claude sessions can complete their
        // authenticated round trip. Authority still comes from loopback-only
        // binding, a per-launch private bearer, and the normal Trust Center /
        // approval gates applied at each message and tool endpoint.
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
                self?.handleListenerTerminated(token: tk)
            }
        )
        stateLock.unlock()
        if !started {
            handleListenerTerminated(token: tk)
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
        // Hold the lifecycle lock over the tiny atomic publications so stop()
        // cannot remove them and then lose a race to a stale ready callback.
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
                    // A new listener may have become ready while the old
                    // helper drained. Its state change admits one recovery.
                    if !_token.isEmpty, _activePort != 0, _token != token {
                        startReplyRecoveryLocked(token: _token)
                    }
                }
            }
            guard !Task.isCancelled, self.token == token else { return }
            // Each organ recovers independently; the retained parent owns both
            // children until exit, including cancellation and helper reaping.
            async let codex: Void = startCodexReplyJobRecovery(token: token)
            async let omp: Void = AgentBridgeRuntime.startOMPReplyJobRecovery()
            _ = await (codex, omp)
        }
    }

    /// Relaunch repair for durable Codex reply jobs. The Node helper performs a
    /// single locked scan and gives every job its own delivery lock; it does not
    /// install a poller or another scheduler.
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
            // The existing process owner retains/reaps the helper and its
            // descendants on cancellation; this recovery task awaits exit.
            let result = try await SystemProcessAdapter().run(executable: node.path,
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

    /// Drop in-memory state + discovery files when the listener dies.
    /// Token-generation gated so a retired listener callback cannot wipe a
    /// newer bridge generation. Also cancels in-flight
    /// connections so a mid-flight request can't pass the auth check
    /// against an empty token (gpt-5.5 R2-BLOCKING #2).
    private func handleListenerTerminated(token: String) {
        stateLock.lock()
        guard _token == token else {
            stateLock.unlock()
            return
        }
        _token = ""
        _activePort = 0
        updateContactLifecycleLocked(active: false)
        let recovery = replyRecoveryTask
        eventSubscribers.removeAll()
        let entries = Array(connections.values)
        connections.removeAll()
        removeDiscoveryFiles()
        stateLock.unlock()
        recovery?.cancel()
        retireRequests(token: token)
        for entry in entries {
            entry.deadlineWork.cancel()
            entry.conn.cancel()
        }
    }

    private func accept(_ conn: NWConnection) {
        guard BridgeCore.endpointIsLoopback(conn.endpoint) else { conn.cancel(); return }
        stateLock.lock()
        let bridgeIsReady = !_token.isEmpty && _activePort != 0
        stateLock.unlock()
        guard bridgeIsReady else { conn.cancel(); return }
        let key = ObjectIdentifier(conn)
        // Per-connection read deadline — prevents a peer from holding a slot
        // open forever by never sending the body bytes promised in
        // Content-Length. UUID-gated (C5): a late fire only cancels the exact
        // connection it was armed for, never an ObjectIdentifier-reused sibling.
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
                self?.stateLock.unlock()
                removed?.deadlineWork.cancel()
                self?.retireRequests(connection: key)
            default: break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        BridgeCore.readRequest(conn, buffered: Data(), maxBodyBytes: Self.maxRequestBodyBytes, server: self)
    }

    /// Cancel a connection whose request never fully arrived before its
    /// read deadline fired. Identity-gated so it cannot cancel a routed
    /// connection or a different connection that reused the ObjectIdentifier.
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

    public func received(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        route(conn: conn, method: method, path: path,
              headers: AgentContactRoutes.contactHeaders(path: path, headers: headers, liveToken: token,
                                                        dataRoot: host.dataRoot), body: body)
    }

    public func route(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        // Body is fully read — cancel the per-connection deadline timer so
        // legitimate long-running work (e.g. a 60s LLM completion on
        // /claude/message) isn't killed mid-response. Deadline scope is
        // request-read only. (gpt-5.5 R2-HIGH)
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
        // Shared best-of-both auth (BridgeCore.authorize): constant-time compare
        // + empty-token 503 guard. If the listener was terminated between accept
        // and now, `_token` is "" — reject even a peer that sent "Bearer "
        // (matches empty) rather than leaking that race as a 200. The
        // identity-gated listener cleanup also cancels live connections; this is
        // the belt with the suspender. (gpt-5.5 R2-BLOCKING #2)
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
        if routeAgentContact(conn: conn, method: method, path: path, headers: headers, body: body) { return }

        let components = path.dropFirst().split(separator: "/", maxSplits: 1).map(String.init)
        let lane = components.first ?? ""
        let operation = path.hasPrefix("/standing_views") ? path : components.count == 2 ? "/" + components[1] : path
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
            handleMessage(conn: conn, body: body, defaultSender: lane, headers: headers)
        case "/tool":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleTool(conn: conn, body: body, headers: headers)
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
                do {
                    let task = try await tasks.get("na3.\(session).\(request)", owner: principal.id)
                    writeJSON(conn, status: 200, obj: AgentContactRoutes.contactReply(task, requestID: request, sessionID: session,
                                                                     offset: offset, maxChars: maxChars), onSent: {
                        if !task.text.isEmpty { Task { await tasks.recordReplyFetch(task) } }
                    })
                } catch {
                    // A /claude/message turn retains no task: its reply is
                    // the conversation's, kept in the bridge's reply ledger
                    // (message-replies.jsonl) by request id for the caller
                    // that sent the message, including a turn that resumed
                    // after a relaunch. Another caller's ids read as nothing.
                    let receipt = ClaudeBridgeMessageRuntime.agentReplyReceipt(requestID: request, sessionID: session,
                        offset: offset, maxChars: maxChars, logURL: ClaudeBridgeMessageRuntime.messageReplyURL(),
                        principal: principal.id)
                    guard receipt["status"] as? String == "ok" else {
                        writeJSON(conn, status: 404, obj: ["status": "unavailable",
                            "detail": "No retained result is available for this caller and request. Absence does not authorize resending.",
                            "evidence": receipt["evidence"] ?? NSNull()])
                        return
                    }
                    writeJSON(conn, status: 200, obj: receipt)
                }
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
        case "/standing_views":
            guard method == "GET" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleStandingViewsList(conn: conn)
        case "/standing_views/resolve":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleStandingViewResolve(conn: conn, body: body)
        default:
            writeJSON(conn, status: 404, obj: ["error": "unknown_path", "path": path])
        }
    }


    private func handleOrganismDebug(conn: NWConnection, body: Data, path: String) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            writeJSON(conn, status: 400, obj: ["error": "invalid_json"])
            return
        }
        let action = (json["action"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let rawScenario = (json["scenario"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldClear = action == "clear" || rawScenario.lowercased() == "clear"
        // Clamped here: Int(ttlSeconds) below traps on "inf" or 1e300.
        let ttlSeconds = Self.timeInterval(json["ttlSeconds"]).flatMap { $0.isFinite ? min(600, max(5, $0)) : nil } ?? 120

        // Same WorkLatch + asyncAfter bound as handleMessage/handleTool.
        let workLatch = WorkLatch()
        let workTask = startRequest(conn: conn, latch: workLatch, priority: .utility) { [weak self] _ in
            guard let self else { return }
            // Every response path below goes through respond(...), so the work
            // Task and the deadline timer can never both write the response.
            func respond(_ status: Int, _ obj: [String: Any]) {
                guard workLatch.claim() else { return }
                self.writeJSON(conn, status: status, obj: obj)
            }
            let runtime = host.cognition
            if action == "reset" || action == "reset_continuity" {
                let outcome = await runtime.resetOrganismContinuityChecked()
                guard !Task.isCancelled else { return }
                guard outcome.applied else {
                    respond(409, ["status": outcome.status.rawValue, "error": outcome.error ?? outcome.status.rawValue,
                                  "organism": ClaudeBridgeStateProjection.organismSnapshotJSON(outcome.snapshot)])
                    return
                }
                self.publishOrganismDebugEvent(status: "reset")
                respond(200, [
                    "status": "reset",
                    "organism": ClaudeBridgeStateProjection.organismSnapshotJSON(outcome.snapshot),
                    "debug": NSNull(),
                ])
                return
            }
            if action == "settle" || action == "settle_continuity" {
                let outcome = await runtime.settleOrganismContinuityChecked()
                guard !Task.isCancelled else { return }
                guard outcome.applied else {
                    respond(409, ["status": outcome.status.rawValue, "error": outcome.error ?? outcome.status.rawValue,
                                  "organism": ClaudeBridgeStateProjection.organismSnapshotJSON(outcome.snapshot)])
                    return
                }
                self.publishOrganismDebugEvent(status: "settled")
                respond(200, [
                    "status": "settled",
                    "organism": ClaudeBridgeStateProjection.organismSnapshotJSON(outcome.snapshot),
                    "debug": NSNull(),
                ])
                return
            }
            if shouldClear {
                let snapshot = await runtime.clearOrganismDebugBodyOverride()
                guard !Task.isCancelled else { return }
                self.publishOrganismDebugEvent(status: "cleared")
                respond(200, [
                    "status": "cleared",
                    "organism": ClaudeBridgeStateProjection.organismSnapshotJSON(snapshot),
                    "debug": NSNull(),
                ])
                return
            }

            guard !rawScenario.isEmpty else {
                respond(400, [
                    "error": "missing_scenario",
                    "allowedScenarios": OrganismDebugBodyScenario.allCases.map(\.rawValue),
                ])
                return
            }

            do {
                let snapshot = try await runtime.setOrganismDebugBodyOverride(
                    scenario: rawScenario,
                    ttlSeconds: ttlSeconds
                )
                guard !Task.isCancelled else { return }
                let debug = await runtime.organismDebugBodyOverrideStatus()
                guard !Task.isCancelled else { return }
                self.publishOrganismDebugEvent(
                    status: "active",
                    scenario: rawScenario,
                    ttlSeconds: Int(ttlSeconds)
                )
                respond(200, [
                    "status": "active",
                    "organism": ClaudeBridgeStateProjection.organismSnapshotJSON(snapshot),
                    "debug": Self.organismDebugStatusJSON(debug),
                ])
            } catch {
                respond(400, [
                    "error": "invalid_scenario",
                    "detail": String(describing: error),
                    "allowedScenarios": OrganismDebugBodyScenario.allCases.map(\.rawValue),
                ])
            }
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

    private static func organismDebugStatusJSON(_ status: OrganismDebugBodyOverrideStatus?) -> Any {
        guard let status else { return NSNull() }
        let iso = ISO8601DateFormatter()
        return [
            "scenario": status.scenario.rawValue,
            "expiresAt": iso.string(from: status.expiresAt),
        ]
    }


    private static func timeInterval(_ value: Any?) -> TimeInterval? {
        if let interval = value as? TimeInterval { return interval }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return TimeInterval(string) }
        return nil
    }


    // MARK: - /claude/message

    private var bridgeMessageRuntime: ClaudeBridgeMessageRuntime?

    public func messageRuntime() -> ClaudeBridgeMessageRuntime {
        clientLock.lock(); defer { clientLock.unlock() }
        if let bridgeMessageRuntime { return bridgeMessageRuntime }
        let runtime = ClaudeBridgeMessageRuntime(port: host, tasks: tasks, eventPublisher: { [weak self] kind, payload in
            self?.publishEvent(kind: kind, payload: payload)
        })
        bridgeMessageRuntime = runtime
        return runtime
    }

    private func handleMessage(conn: NWConnection, body: Data, defaultSender: String, headers: [String: String]) {
        guard let principal = bridgeCallerPrincipal(headers: headers) else {
            writeJSON(conn, status: 403, obj: ["error": "invalid_peer_identity"])
            return
        }
        messageRuntime().handleMessage(response: { [weak self] status, object in
            self?.writeJSON(conn, status: status, obj: object)
        }, body: body, defaultSender: defaultSender, principal: principal)
    }

    // MARK: - /claude/tool

    /// Only the door's own authenticated key carries its identity and grant.
    private func bridgeCallerPrincipal(headers: [String: String]) -> AgentBridgePrincipal? {
        let principal = AgentBridgePrincipal.resolve(headers: headers, dataRoot: host.dataRoot)
        guard !principal.replyOnly,
              !AgentBridgePrincipal.claimsIdentity(headers: headers) || principal.peerID != nil else { return nil }
        return principal
    }

    private func handleTool(conn: NWConnection, body: Data, headers: [String: String]) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            writeJSON(conn, status: 400, obj: ["error": "invalid_json"])
            return
        }
        guard let name = json["name"] as? String, !name.isEmpty else {
            writeJSON(conn, status: 400, obj: ["error": "missing_name"])
            return
        }
        guard let principal = bridgeCallerPrincipal(headers: headers) else {
            writeJSON(conn, status: 401, obj: ["error": "unauthorized"])
            return
        }
        let surface = principal.surface
        let context = json["session_id"] as? String
        let request = json["request_id"] as? String
        if json["session_id"] != nil || json["request_id"] != nil {
            guard let context, context.utf8.count <= 128,
                  NativeAgentChatSessionID.normalizedPathComponent(context) == context,
                  let request, request.count == 36, UUID(uuidString: request) != nil else {
                writeJSON(conn, status: 400, obj: ["error": "invalid_caller_reply_route",
                    "detail": "Supply a transport session_id and UUID request_id together; no work was queued."])
                return
            }
        }
        let inputRaw = (json["input"] as? [String: Any]) ?? [:]
        let inputJV: [String: JSONValue]
        do {
            inputJV = try toolInputJSONValue(inputRaw)
        } catch {
            writeJSON(conn, status: 400, obj: ["error": "invalid_input", "detail": String(describing: error)])
            return
        }

        let tasks = self.tasks
        let session = context.map(principal.storedConversation)
        let tools = toolClient(verifiedSessionID: session)
        let turn = principal.turnRequest(context: context, plain: "", messageID: request)
        let taskID = context.flatMap { context in request.map { "na3.\(context).\($0)" } }
        let requestDigest = AgentPeerReplayClaimStore.digest(body)
        let started = Date()
        let workLatch = WorkLatch()
        let workTask = startRequest(conn: conn, latch: workLatch, priority: .userInitiated, accepted: true) { [weak self] id in
            guard let self else { return }
            var admitted = false
            do {
                if let context, let request {
                    let retained = try await tasks.beginTool(context: context, request: request, principal: principal, digest: requestDigest)
                    guard retained.execute else {
                        guard workLatch.claim() else { return }
                        self.writeJSON(conn, status: 200, obj: AgentContactRoutes.contactReply(retained.task, requestID: request,
                                                                              sessionID: context, offset: 0, maxChars: 8000), onSent: {
                            if !retained.task.text.isEmpty { Task { await tasks.recordReplyFetch(retained.task) } }
                        })
                        return
                    }
                    admitted = true
                }
                let result = try await TurnDeadline.withThrowingDeadline(seconds: Double(Self.toolWorkDeadlineSeconds)) {
                    try await self.runToolOperation(id) {
                        do {
                            let result = try await turn.bind {
                                try await tools.dispatch(tool: name, input: inputJV, surface: turn.surface)
                            }
                            if let taskID { try await tasks.finishTool(taskID, owner: principal.id, result: result) }
                            return result
                        } catch {
                            // Settle only at dispatch exit. The HTTP timeout
                            // cannot claim a still-running tool has failed.
                            if let taskID {
                                let status = Task.isCancelled || error is CancellationError || error is TurnDeadline.DeadlineExceeded
                                    ? "outcome_unknown" : "failed"
                                try? await tasks.finishTool(taskID, owner: principal.id,
                                    result: .object(["status": .string(status), "detail": .string(String(describing: error))]))
                            }
                            throw error
                        }
                    }
                }
                let resultAny = jsonValueToAny(result)
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                self.publishToolResultEvent(name: name, surface: surface, result: result, durationMs: durationMs)
                guard workLatch.claim() else { return }
                self.writeJSON(conn, status: 200, obj: [
                    "name": name,
                    "result": resultAny,
                    "durationMs": durationMs,
                ])
            } catch {
                if admitted, let taskID, self.closeUnstartedTool(id) {
                    try? await tasks.finishTool(taskID, owner: principal.id,
                        result: .object(["status": .string("failed"), "detail": .string(String(describing: error))]))
                }
                if error is TurnDeadline.DeadlineExceeded {
                    guard workLatch.claim() else { return }
                    self.publishEvent(kind: "tool_timeout", payload: [
                        "name": name, "surface": surface, "seconds": Self.toolWorkDeadlineSeconds,
                    ])
                    self.writeJSON(conn, status: 504, obj: [
                        "error": "work_timeout", "name": name, "seconds": Self.toolWorkDeadlineSeconds,
                        "outcome": "unknown",
                    ])
                    return
                }
                self.publishEvent(kind: "tool_failed", payload: [
                    "name": name,
                    "ok": false,
                    "detail": String(describing: error),
                ])
                guard workLatch.claim() else { return }
                self.writeJSON(conn, status: 500, obj: [
                    "error": "tool_failed",
                    "name": name,
                    "surface": surface,
                    "detail": String(describing: error),
                ])
            }
        }
        guard workTask != nil else { writeJSON(conn, status: 503, obj: ["error": "server_stopping_or_busy"]); return }
    }

    // MARK: - Activity event publisher

    /// Push an event into the ring buffer + fan out to SSE subscribers.
    /// stateLock orders sequence assignment and delivery enqueueing together.
    /// Connection writes run on one serial queue, outside the state lock.
    /// `retain: false` fans out only: a live partial is stale the moment the
    /// next one lands and must not crowd real actions out of the backfill ring.
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

        // Drop on close. accept()'s stateUpdateHandler already removes
        // from `connections` + cancels the deadline; ALSO drop from
        // subscribers here so we don't leak the entry.
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

        // Register and enqueue the backfill under the same lock as live events.
        // A publisher can only enqueue this subscriber's live sends after it.
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

// MARK: - JSONValue conversion helpers

private enum JSONConvertError: Error { case unsupportedType }

private func toolInputJSONValue(_ raw: [String: Any]) throws -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for (k, v) in raw {
        out[k] = try anyToJSONValue(v)
    }
    return out
}

private func anyToJSONValue(_ value: Any) throws -> JSONValue {
    if value is NSNull { return .null }
    // NSNumber FIRST, disambiguated by CFTypeID: `NSNumber(1) as? Bool`
    // SUCCEEDS in Swift, so the old `as? Bool` fast path silently turned wire
    // `1`/`0` into booleans (caught live: desk_breakdown's blocked_on [1]
    // arrived as [.bool(true)] and was refused). Mirrors
    // PersistenceCore.JSONValue's converter, the reference implementation.
    if let n = value as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
        let typeId = CFNumberGetType(n)
        if typeId == .floatType || typeId == .doubleType || typeId == .float32Type || typeId == .float64Type || typeId == .cgFloatType {
            return .double(n.doubleValue)
        }
        return .int(n.int64Value)
    }
    if let b = value as? Bool { return .bool(b) }
    if let i = value as? Int { return .int(Int64(i)) }
    if let d = value as? Double { return .double(d) }
    if let s = value as? String { return .string(s) }
    if let arr = value as? [Any] {
        return .array(try arr.map { try anyToJSONValue($0) })
    }
    if let dict = value as? [String: Any] {
        var out: [String: JSONValue] = [:]
        for (k, v) in dict { out[k] = try anyToJSONValue(v) }
        return .object(out)
    }
    throw JSONConvertError.unsupportedType
}

private func jsonValueToAny(_ v: JSONValue) -> Any {
    switch v {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .array(let arr): return arr.map { jsonValueToAny($0) }
    case .object(let obj):
        var out: [String: Any] = [:]
        for (k, val) in obj { out[k] = jsonValueToAny(val) }
        return out
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
        let iso = ISO8601DateFormatter()
        return [
            "key": live.key, "recordId": live.recordID ?? NSNull(), "operationId": live.operationID ?? NSNull(),
            "agent": live.agent, "messageId": live.messageID ?? NSNull(), "lane": live.lane,
            "state": live.state, "streams": live.streams,
            "startedAt": iso.string(from: live.startedAt), "lastActivityAt": iso.string(from: live.lastActivityAt),
            "partialText": live.partial.map { NativeAgentSecretRedactor.redactText($0) } ?? NSNull(),
            "partialChars": live.partialChars, "partialTruncated": live.partialTruncated,
            "note": live.note.map { NativeAgentSecretRedactor.redactText($0) } ?? NSNull(),
            "finishedAt": live.finishedAt.map { iso.string(from: $0) } ?? NSNull(),
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
        // Same WorkLatch + asyncAfter bound as handleMessage/handleTool: exactly
        // one of the work Task and the deadline writes the response.
        let workLatch = WorkLatch()
        // 2026-09-23: .userInitiated; at .utility the first /codex/state reply
        // nearly missed the installer's 2s liveness check.
        let workTask = startRequest(conn: conn, latch: workLatch, priority: .userInitiated) { [weak self] _ in
            guard let self else { return }
            let payload = await ClaudeBridgeStateProjection.statePayload(
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
        ClaudeBridgeStateProjection.readBridgeActiveSession(dataRoot: dataRoot, preferred: { self.preferredSessionID }).id
    }
    func activePersona(dataRoot: URL) -> String? {
        ClaudeBridgeStateProjection.readActivePersona(dataRoot: dataRoot, preferred: preferredPersona)
    }
}

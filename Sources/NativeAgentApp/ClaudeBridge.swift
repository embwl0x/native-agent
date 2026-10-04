import Privacy
// ClaudeBridge — sibling of MacControlBridge. Localhost HTTP server on this install's fixed port (8771)
// that lets local agent CLIs query Agent's state, fire chat turns, and run
// tools without UI click-through. The original surface is Claude/Claude Code;
// /codex/* aliases share the same listener/token so Codex can use the same
// Agent channel without a second bridge stack.
//
// Pattern mirrored from MacControlBridge: NWListener on 127.0.0.1, bearer auth,
// off-MainActor, one fixed port per install (a taken port fails loudly). The
// endpoint + token are published atomically in
// ~/.config/claude-bridge/bridge.json (chmod 0600); every client reads it.
// The token file is kept beside it for token-only readers.
//
// Endpoints:
//   GET  /claude/state    snapshot of active session/persona/model + context/organism health
//   POST /claude/message  fire a headless chat turn via ChatOrchestration
//   POST /claude/tool     dispatch a single tool via SwiftToolDispatcher
//   POST /claude/organism/debug  TTL-bound in-memory organism body simulation
//   GET  /standing_views          active/held/proposed standing views (id/status/body head)
//   POST /standing_views/resolve  approve | reject | retire one, through the
//                                 same CognitionProposalActions the Observatory calls
//   GET/POST /codex/*      aliases of the same endpoints, default sender=codex
//
// Hardening (gpt-5.5 review fixes 2026-06-07):
//   - /claude/tool wraps the inner dispatcher with the same FileAccessGated +
//     AutonomyGated chain chat uses, so Trust Center deny/confirm gates and
//     persona write-guards apply to the bridge surface too. fileAccess
//     defaults to "read_only" and no ApprovalFiler is wired, so CONFIRM-tier
//     tools fail closed.
//   - Bearer-token compare is constant-time (timing side-channel).
//   - Token file is atomically created with mode 0o600 BEFORE first write
//     (no umask race).
//   - Listener .failed/.cancelled clears in-memory token + discovery files so a
//     stale token can't outlive the server.
//   - Per-connection 30s deadline cancels half-open / never-completing peers.
//   - stop() cancels listener, all connections, all deadline timers, and
//     removes discovery files for tests / shutdown.

import Foundation
import GitHubConnector
import Darwin
import Network
import Agents
import ChatOrchestration
import Cognition
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersistenceCore
import ProviderRouting

final class ClaudeBridge: NSObject, @unchecked Sendable, BridgeHTTPServer {
    static let shared = ClaudeBridge()

    static let port = InstallPaths.current.loopbackPorts().bridge
    private static let maxRequestBodyBytes = 4 * 1024 * 1024

    private static let connectionDeadlineSeconds: Int = 30
    /// Work-phase bound for /claude/tool dispatches.
    static let toolWorkDeadlineSeconds: Int = 300
    /// Work-phase bound for the read/debug endpoints (/claude/state,
    /// /claude/organism_debug). Both await the cognition runtime actor; a
    /// stalled actor left their detached Tasks and connections unbounded.
    /// Short by design — neither endpoint does LLM work.
    static let readWorkDeadlineSeconds: Int = 60

    /// The canonical chat store is already durable when a bridge turn reaches
    /// this seam. Reuse the app's existing completion edge so Mac UI and the
    /// coalesced iOS transcript projection observe the same turn without a
    /// second transcript owner.
    private static func publishChatTurnCompleted(sessionID: String?) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
        }
    }

    /// Claim-once latch shared by a work Task and its deadline timer so
    /// exactly one of them writes the HTTP response.
    final class WorkLatch: ClaudeBridgeResponseLatch, @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        private var deadlineWork: DispatchWorkItem?

        /// Returns true exactly once. The winner also cancels the deadline this
        /// latch owns, so a burst of requests can no longer stack live timers
        /// that each retain the bridge (and the connection) until their
        /// deadline elapses.
        func claim() -> Bool {
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

        func arm(afterSeconds seconds: Int, _ body: @escaping @Sendable () -> Void) {
            arm(afterSeconds: seconds, on: .global(), body)
        }

        /// Arms the single deadline timer this latch owns. If the work already
        /// claimed the response, nothing is scheduled at all.
        func arm(
            afterSeconds seconds: Int,
            on queue: DispatchQueue,
            _ body: @escaping @Sendable () -> Void
        ) {
            let work = DispatchWorkItem(block: body)
            lock.lock()
            let alreadyClaimed = claimed
            if !alreadyClaimed { deadlineWork = work }
            lock.unlock()
            guard !alreadyClaimed else { return }
            queue.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
        }
    }

    private let bridgeListener = NativeLoopbackListener(
        port: ClaudeBridge.port,
        label: "ClaudeBridge"
    )
    /// Doctor's "Local bridges" row: which port this bridge got, or why it has none.
    var listenerHealth: NativeLoopbackListener.Health { bridgeListener.health }
    private let stateLock = NSLock()
    private var _token: String = ""
    private var _activePort: UInt16 = 0
    private(set) var startedAt: Date = Date()
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

    func eventRouteSnapshot() -> (connectionCount: Int, subscriberCount: Int, latestSequence: UInt64) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (connections.count, eventSubscribers.count, eventSeq)
    }

    /// Bounded projection used by the state endpoint and hermetic route evals.
    /// Callers receive values, never access to the mutable event ring.
    func recentEventPayloads() -> [[String: Any]] {
        stateLock.lock()
        let recent = recentToolCalls
        stateLock.unlock()
        return recent.map { $0.asJSON }
    }

    /// A returned envelope proves dispatch completed, not that the requested
    /// operation succeeded. Share chat's exact classification; do not turn
    /// queued/approval/unknown results into success or retain result content.
    func publishToolResultEvent(name: String, surface: String, result: JSONValue, durationMs: Int) {
        let outcome = ChatToolOutcome.exactResultClass(result)
        let ok: Any
        switch outcome {
        case .succeeded: ok = true
        case .failed, .cancelled, .timeout: ok = false
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
    func publishOrganismDebugEvent(
        status: String,
        scenario: String? = nil,
        ttlSeconds: Int? = nil
    ) {
        var payload: [String: Any] = ["status": status]
        if let scenario { payload["scenario"] = scenario }
        if let ttlSeconds { payload["ttlSeconds"] = ttlSeconds }
        publishEvent(kind: "organism_debug", payload: payload)
    }

    var token: String { stateLock.lock(); defer { stateLock.unlock() }; return _token }
    var activePort: UInt16 { stateLock.lock(); defer { stateLock.unlock() }; return _activePort }

    // Lazily-built ChatOrchestration client + dispatcher. Built off-MainActor on
    // first need. Both are Sendable.
    private let clientLock = NSLock()
    private var chatClient: (any ChatOrchestrationClient)?
    private var toolClient: (any ToolDispatchClient)?

    // MARK: - Token storage

    private var configDir: URL {
        AgentHostDirectory.bridgeDiscoveryDirectory(dataRoot: NativeAgentPaths.dataRoot)
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
        let peerDir = AgentHostDirectory.peerDescriptorDirectory(dataRoot: NativeAgentPaths.dataRoot)
        try? FileManager.default.createDirectory(at: peerDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: peerDir.path)
        if let peerDescriptor = try? JSONSerialization.data(
            withJSONObject: ["schemaVersion": 1, "url": "http://127.0.0.1:\(port)"], options: [.prettyPrinted]) {
            _ = NativePrivateFile.write(peerDescriptor, to: peerDescriptorFileURL)
        }
    }

    private var peerDescriptorFileURL: URL {
        URL(fileURLWithPath: AgentHostDirectory.bridgeDescriptorPath(dataRoot: NativeAgentPaths.dataRoot))
    }

    private func removeDiscoveryFiles() {
        _ = tokenFileURL.path.withCString { Darwin.unlink($0) }
        _ = peerDescriptorFileURL.path.withCString { Darwin.unlink($0) }
        _ = descriptorFileURL.path.withCString { Darwin.unlink($0) }
    }

    // MARK: - Lifecycle

    /// Start the bridge on its preferred port, advancing deterministically on
    /// collisions and publishing the selected endpoint once it is ready.
    func startServer() async {
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
    func startSyncForBootstrap() {
        NSLog("[claude-bootstrap] startSyncForBootstrap entered — invoking startSync")
        startSync()
    }

    /// Cancel the listener, all live connections + their deadline timers,
    /// clear the in-memory endpoint, and remove discovery files. Idempotent.
    func stop() {
        bridgeListener.stop()
        stateLock.lock()
        let entries = Array(connections.values)
        connections.removeAll()
        _token = ""
        _activePort = 0
        stateLock.unlock()
        for entry in entries {
            entry.deadlineWork.cancel()
            entry.conn.cancel()
        }
        removeDiscoveryFiles()
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
        NSLog(
            "[ClaudeBridge] startSync entered (state=%@)",
            alreadyRunningOrStarting ? "already-running-or-starting" : "idle"
        )
        guard !alreadyRunningOrStarting else { return }
        installAgentLivePublisher()

        guard let tk = BridgeCore.generateToken() else {
            NSLog("[ClaudeBridge] failed to generate token")
            return
        }
        stateLock.lock()
        guard !bridgeListener.isActive, _token.isEmpty else {
            stateLock.unlock()
            return
        }
        _token = tk
        _activePort = 0
        stateLock.unlock()
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
        stateLock.unlock()

        NSLog("[ClaudeBridge] listening on 127.0.0.1:%d", Int(port))
        Task.detached(priority: .utility) {
            let reconciled = (try? await CodexCompletionLifecycle.shared
                .reconcileInterruptedClaims()) ?? []
            if !reconciled.isEmpty {
                NSLog(
                    "[ClaudeBridge] marked %d interrupted Codex completion claim(s) outcome_unknown",
                    reconciled.count
                )
            }
            Self.startCodexReplyJobRecovery()
        }
    }

    /// Relaunch repair for durable Codex reply jobs. The Node helper performs a
    /// single locked scan and gives every job its own delivery lock; it does not
    /// install a poller or another scheduler.
    private static func startCodexReplyJobRecovery() {
        let environment = ProcessInfo.processInfo.environment
        if ["1", "true", "yes"].contains(
            environment["NATIVE_AGENT_CODEX_REPLY_RECOVERY_DISABLED"]?.lowercased() ?? ""
        ) {
            return
        }
        let dataRoot = PersistenceCore.defaultDataRoot()
        let repoRoot = dataRoot.deletingLastPathComponent()
        guard let helper = AgentBridgeRuntime.codexHelperURL(dataRoot: dataRoot) else {
            NSLog(
                "[ClaudeBridge] codex wake helper missing; expected %@",
                AgentBridgeRuntime.expectedHelperPath(named: "codex_thread_wakeup.js", dataRoot: dataRoot).path
            )
            return
        }
        NSLog("[ClaudeBridge] codex wake helper: %@", helper.path)
        let processEnvironment = AgentBridgeRuntime.processEnvironment(base: environment)
        guard let node = AgentBridgeRuntime.executableURL(named: "node", environment: processEnvironment) else {
            return
        }
        let process = Process()
        process.executableURL = node
        process.arguments = [helper.path, "--recover-reply-jobs"]
        process.currentDirectoryURL = repoRoot
        var childEnvironment = processEnvironment
        if childEnvironment["CODEX_BIN"] == nil,
           let codex = AgentBridgeRuntime.executableURL(named: "codex", environment: processEnvironment) {
            childEnvironment["CODEX_BIN"] = codex.path
        }
        process.environment = childEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                NSLog(
                    "[ClaudeBridge] Codex reply-job recovery exited %d",
                    Int(process.terminationStatus)
                )
            }
        }
        do {
            try process.run()
        } catch {
            NSLog(
                "[ClaudeBridge] could not start Codex reply-job recovery: %@",
                String(describing: error)
            )
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
        let entries = Array(connections.values)
        connections.removeAll()
        stateLock.unlock()
        for entry in entries {
            entry.deadlineWork.cancel()
            entry.conn.cancel()
        }
        removeDiscoveryFiles()
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

    func route(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
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

        switch path {
        case "/claude/state", "/codex/state", "/omp/state":
            guard method == "GET" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleState(conn: conn)
        case "/claude/message":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleMessage(conn: conn, body: body, defaultSender: "claude")
        case "/codex/message":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleMessage(conn: conn, body: body, defaultSender: "codex")
        case "/omp/message":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleMessage(conn: conn, body: body, defaultSender: "omp")
        case "/claude/tool":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleTool(conn: conn, body: body, surface: BridgeLane.claudeSurfaceName, headers: headers)
        case "/codex/tool":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleTool(conn: conn, body: body, surface: BridgeLane.codexSurfaceName, headers: headers)
        case "/codex/reply", "/claude/reply":
            guard method == "POST",
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let session = json["session_id"] as? String,
                  let request = json["request_id"] as? String,
                  let principal = toolCallerPrincipal(headers: headers) else {
                writeJSON(conn, status: 400, obj: ["error": "invalid_caller_result_request"])
                return
            }
            Task {
                do {
                    let task = try await NativeAgentEngine.live.agents.tasks.get("na3.\(session).\(request)", owner: principal.id)
                    writeJSON(conn, status: 200, obj: Self.contactReply(task, requestID: request, sessionID: session,
                                                                     offset: 0, maxChars: 8000), onSent: {
                        if !task.replyText.isEmpty { Task { await NativeAgentEngine.live.agents.tasks.recordReplyFetch(task) } }
                    })
                } catch {
                    writeJSON(conn, status: 404, obj: ["status": "unavailable",
                        "detail": "No retained result is available for this caller and request. Absence does not authorize resending."])
                }
            }
        case "/claude/organism/debug", "/codex/organism/debug":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleOrganismDebug(conn: conn, body: body)
        case "/codex/live", "/omp/live":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleAgentLive(conn: conn, body: body, agent: String(path.dropFirst().prefix { $0 != "/" }))
        case "/claude/events", "/codex/events":
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


    private func handleOrganismDebug(conn: NWConnection, body: Data) {
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
        let workTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // Every response path below goes through respond(...), so the work
            // Task and the deadline timer can never both write the response.
            func respond(_ status: Int, _ obj: [String: Any]) {
                guard workLatch.claim() else { return }
                self.writeJSON(conn, status: status, obj: obj)
            }
            let runtime = NativeAgentEngine.liveCognition
            if action == "reset" || action == "reset_continuity" {
                let outcome = await runtime.resetOrganismContinuityChecked()
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
                let debug = await runtime.organismDebugBodyOverrideStatus()
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
        workLatch.arm(afterSeconds: Self.readWorkDeadlineSeconds) { [weak self] in
            guard let self, workLatch.claim() else { return }
            workTask.cancel()
            self.writeJSON(conn, status: 504, obj: [
                "error": "work_timeout",
                "path": "/claude/organism_debug",
                "seconds": Self.readWorkDeadlineSeconds,
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

    static func mcpTransportRejection(headers: [String: String], port: UInt16) -> Int? {
        if let origin = headers["origin"], origin != "http://127.0.0.1:\(port)" { return 403 }
        if let version = headers["mcp-protocol-version"], !NativeAgentMCPWire.versions.contains(version) { return 400 }
        let accept = Set((headers["accept"] ?? "").lowercased().split(separator: ",").compactMap {
            $0.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
        })
        guard accept.contains("application/json"), accept.contains("text/event-stream") else { return 406 }
        guard headers["content-type"]?.lowercased().split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces) == "application/json" else { return 415 }
        return nil
    }

    private var bridgeMessageRuntime: ClaudeBridgeMessageRuntime?

    func messageRuntime() -> ClaudeBridgeMessageRuntime {
        clientLock.lock(); defer { clientLock.unlock() }
        if let bridgeMessageRuntime { return bridgeMessageRuntime }
        let runtime = ClaudeBridgeMessageRuntime(port: MessagePort(bridge: self))
        bridgeMessageRuntime = runtime
        return runtime
    }

    private func handleMessage(conn: NWConnection, body: Data, defaultSender: String) {
        messageRuntime().handleMessage(response: { [weak self] status, object in
            self?.writeJSON(conn, status: status, obj: object)
        }, body: body, defaultSender: defaultSender)
    }

    private struct MessagePort: ClaudeBridgeMessagePort {
        weak var bridge: ClaudeBridge?
        func activeSessionID(dataRoot: URL) -> String? { bridge?.readBridgeActiveSession(dataRoot: dataRoot).id }
        func activePersona(dataRoot: URL) -> String? { bridge?.readActivePersona(dataRoot: dataRoot) }
        func chatClient() -> any ChatOrchestrationClient { bridge!.sharedChatClient() }
        func completionSender(dataRoot: URL) -> any AgentBridgeCompletionSending {
            LiveAgentBridgeCompletionSender(dataRoot: dataRoot)
        }
        func makeResponseLatch() -> any ClaudeBridgeResponseLatch { WorkLatch() }
        func publishEvent(kind: String, payload: [String: Any]) { bridge?.publishEvent(kind: kind, payload: payload) }
        func publishChatTurnCompleted(sessionID: String?) async {
            await ClaudeBridge.publishChatTurnCompleted(sessionID: sessionID)
        }
        func handleCodexCompletion(messageIds: [String], codexStatus: String, summary: String,
                                   threadId: String?, turnId: String?, errorMessage: String?,
                                   noWorkObserved: Bool?) async {
            await GitHubCommandRuntime.shared.handleCodexCompletion(
                messageIds: messageIds, codexStatus: codexStatus, summary: summary,
                threadId: threadId, turnId: turnId, errorMessage: errorMessage,
                noWorkObserved: noWorkObserved)
        }
    }

    // MARK: - /claude/tool

    private func toolCallerPrincipal(headers: [String: String]) -> AgentBridgePrincipal? {
        let principal = AgentBridgePrincipal.resolve(headers: headers, dataRoot: NativeAgentPaths.dataRoot)
        guard !principal.replyOnly,
              !AgentBridgePrincipal.claimsIdentity(headers: headers) || principal.peerID != nil else { return nil }
        // The listener has already authenticated the shared bearer. Without a
        // scoped credential it attests only this shared transport namespace.
        return principal
    }

    private func handleTool(conn: NWConnection, body: Data, surface: String, headers: [String: String]) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            writeJSON(conn, status: 400, obj: ["error": "invalid_json"])
            return
        }
        guard let name = json["name"] as? String, !name.isEmpty else {
            writeJSON(conn, status: 400, obj: ["error": "missing_name"])
            return
        }
        guard let principal = toolCallerPrincipal(headers: headers) else {
            writeJSON(conn, status: 401, obj: ["error": "unauthorized"])
            return
        }
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

        let tasks = NativeAgentEngine.live.agents.tasks
        let session = context.map(principal.storedConversation)
        let engine = NativeAgentEngine.live
        let tools = session.map {
            engine.bridgeToolDispatchClient(
                approvalFiler: NativeAgentChatApprovalFiler(dataRoot: engine.dataRoot),
                verifiedSessionId: $0)
        } ?? sharedToolClient()
        let replyRoute = context.flatMap { context in request.map { request in
            ChatToolSessionContext.ReplyRoute(surface: "caller-result", destinationId: principal.id,
                                              threadId: context, correlationId: request)
        } }
        let taskID = context.flatMap { context in request.map { "na3.\(context).\($0)" } }
        let requestDigest = AgentPeerReplayClaimStore.digest(body)
        let started = Date()
        // U5 W-G: bound the work phase (same latch pattern as handleMessage).
        let workLatch = WorkLatch()
        let workTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var admitted = false
            do {
                if let context, let request {
                    let retained = try await tasks.beginTool(context: context, request: request, principal: principal, digest: requestDigest)
                    guard retained.execute else {
                        guard workLatch.claim() else { return }
                        self.writeJSON(conn, status: 200, obj: Self.contactReply(retained.task, requestID: request,
                                                                              sessionID: context, offset: 0, maxChars: 8000), onSent: {
                            if !retained.task.replyText.isEmpty { Task { await tasks.recordReplyFetch(retained.task) } }
                        })
                        return
                    }
                    admitted = true
                }
                let result = try await ChatToolSessionContext.$verifiedSessionId.withValue(session) {
                    try await ChatToolSessionContext.$replyRoute.withValue(replyRoute) {
                        try await tools.dispatch(tool: name, input: inputJV, surface: surface)
                    }
                }
                if let taskID { try await tasks.finishTool(taskID, owner: principal.id, result: result) }
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
                if admitted, let taskID {
                    try? await tasks.finishTool(taskID, owner: principal.id,
                                               result: .object(["status": .string("failed"), "detail": .string(String(describing: error))]))
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
        workLatch.arm(afterSeconds: Self.toolWorkDeadlineSeconds) { [weak self] in
            guard let self, workLatch.claim() else { return }
            workTask.cancel()
            self.publishEvent(kind: "tool_timeout", payload: [
                "name": name,
                "surface": surface,
                "seconds": Self.toolWorkDeadlineSeconds,
            ])
            self.writeJSON(conn, status: 504, obj: [
                "error": "work_timeout",
                "name": name,
                "seconds": Self.toolWorkDeadlineSeconds,
            ])
        }
    }

    // MARK: - Shared client builders

    private func sharedChatClient() -> any ChatOrchestrationClient {
        clientLock.lock(); defer { clientLock.unlock() }
        if let c = chatClient { return c }
        // The bridge `/claude/message` path runs the full chat client with
        // surface "chat" — the bridge IS Claude/codex working with Agent as a
        // team, so per the user's 2026-06-13 call it gets the SAME tool surface as
        // local Mac chat: builder tools (yolo-window gated), self-evolution
        // (includeEvolutionBridge default true → real backend; self_install
        // still only STAGES a card the user approves), and integration tools.
        //
        // The ONE thing held back is the external MCP namespace
        // (denyExternalMcp:true): `mcp__*` third-party connectors — including a
        // wired real-money brokerage — must not be reachable from a turn with
        // no human at the trigger. That is a third-party-side-effect boundary,
        // not a fence on Claude's own tools. See ClaudeBridgeDenyDispatcher.
        let c = NativeAgentEngine.live.chatClient(profile: .bridge)
        chatClient = c
        return c
    }

    /// gpt-5.5 R1 BLOCKING fix (2026-06-07): wrap the raw SwiftToolDispatcher in
    /// the same FileAccessGated + AutonomyGated chain `SwiftNativeChatOrchestrationClient.chat`
    /// builds per-turn. Without this, /claude/tool bypasses Trust Center
    /// deny/confirm decisions and persona write-guards.
    ///
    /// Defaults are conservative:
    ///   - `fileAccess: "read_only"` blocks `write_file`, `mac_*`, `shell_*`,
    ///     `persona_write`, etc. by name prefix/exact match.
    ///   - The canonical nonblocking approval filer returns `waiting_approval`
    ///     with the ordinary approval card's id when a gate requires consent.
    ///
    /// 2026-06-13 (the user, "the bridges should be open"): the bridge is Claude/
    /// codex/Agent working as a team, so NativeAgent-native write/send tools are
    /// no longer fenced here — they pass through to the gated chain above
    /// (`fileAccess:"read_only"` still blocks raw FS writes / `mac_*`, and
    /// approval-required calls still wait for the person's decision, so this RPC
    /// path stays read-mostly without a bridge-specific NativeAgent deny-list).
    /// The remaining `ClaudeBridgeDenyDispatcher` wrap is now an mcp__-ONLY
    /// guard: the external MCP namespace (third-party connectors, incl. wired
    /// real-money brokerage) must not be reachable from a no-human-in-the-loop
    /// surface. That boundary is third-party side effects, not Claude's tools.
    private func sharedToolClient() -> any ToolDispatchClient {
        clientLock.lock(); defer { clientLock.unlock() }
        if let t = toolClient { return t }
        let engine = NativeAgentEngine.live
        let tools = engine.bridgeToolDispatchClient(
            approvalFiler: NativeAgentChatApprovalFiler(dataRoot: engine.dataRoot))
        toolClient = tools
        return tools
    }

    // MARK: - Activity event publisher

    /// Push an event into the ring buffer + fan out to SSE subscribers.
    /// stateLock orders sequence assignment and delivery enqueueing together.
    /// Connection writes run on one serial queue, outside the state lock.
    /// `retain: false` fans out only: a live partial is stale the moment the
    /// next one lands and must not crowd real actions out of the backfill ring.
    func publishEvent(kind: String, payload: [String: Any], retain: Bool = true) {
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

    func writeJSON(_ conn: NWConnection, status: Int, obj: [String: Any], onSent: (@Sendable () -> Void)? = nil) {
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

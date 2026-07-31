// ClaudeBridge — sibling of MacControlBridge. Localhost HTTP server preferring 8771
// that lets local agent CLIs query Agent's state, fire chat turns, and run
// tools without UI click-through. The original surface is Claude/Claude Code;
// /codex/* aliases share the same listener/token so Codex can use the same
// Agent channel without a second bridge stack.
//
// Pattern mirrored from MacControlBridge: NWListener on 127.0.0.1, bearer auth,
// off-MainActor, and descriptor-published port fallback on collision. The
// selected endpoint + token are published atomically in
// ~/.config/claude-bridge/bridge.json (chmod 0600). The legacy token file is
// retained for fixed-port clients while they migrate to descriptor discovery.
//
// Endpoints:
//   GET  /claude/state    snapshot of active session/persona/model + context/organism health
//   POST /claude/message  fire a headless chat turn via ChatOrchestration
//   POST /claude/tool     dispatch a single tool via SwiftToolDispatcher
//   POST /claude/organism/debug  TTL-bound in-memory organism body simulation
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
import Darwin
import Network
import CryptoKit
import ChatOrchestration
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersistenceCore
import ProviderRouting

final class ClaudeBridge: NSObject, @unchecked Sendable, BridgeHTTPServer {
    static let shared = ClaudeBridge()

    static let port: UInt16 = 8771
    private static let maxRequestBodyBytes = 4 * 1024 * 1024
    private static let claudeSurfaceName = "claude-bridge"
    private static let codexSurfaceName = "codex-bridge"
    private static let connectionDeadlineSeconds: Int = 30
    /// U5 W-G (2026-06-11): upper bound on the WORK phase of /claude/message
    /// (one full LLM turn incl. tool loop). The read-phase deadline above is
    /// cancelled in `route(...)` once the body lands, so before this nothing
    /// bounded the detached work Task — a hung turn leaked the connection +
    /// Task forever.
    static let messageWorkDeadlineSeconds: Int = 600
    /// Ack-on-enqueue lane (wake-delivery-classification, 2026-07-25): bound
    /// on the ENQUEUE phase only — a durable transcript append, disk-bound,
    /// measured in seconds. The turn that follows is deliberately unbounded
    /// here (the engine's own guards bound it); its outcome reaches callers
    /// through the durable reply JSONL and bridge events, never this response.
    static let enqueueAckDeadlineSeconds: Int = 30
    /// Work-phase bound for /claude/tool dispatches.
    static let toolWorkDeadlineSeconds: Int = 300
    /// Work-phase bound for the read/debug endpoints (/claude/state,
    /// /claude/organism_debug). Both await the cognition runtime actor; a
    /// stalled actor left their detached Tasks and connections unbounded.
    /// Short by design — neither endpoint does LLM work.
    static let readWorkDeadlineSeconds: Int = 60

    /// Claim-once latch shared by a work Task and its deadline timer so
    /// exactly one of them writes the HTTP response.
    private final class WorkLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        /// Returns true exactly once.
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    private let bridgeListener = NativeLoopbackPortFallbackListener(
        preferredPort: ClaudeBridge.port,
        label: "ClaudeBridge"
    )
    private let stateLock = NSLock()
    private var _token: String = ""
    private var _activePort: UInt16 = 0
    private var startedAt: Date = Date()
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

    var token: String { stateLock.lock(); defer { stateLock.unlock() }; return _token }
    var activePort: UInt16 { stateLock.lock(); defer { stateLock.unlock() }; return _activePort }

    // Lazily-built ChatOrchestration client + dispatcher. Built off-MainActor on
    // first need. Both are Sendable.
    private let clientLock = NSLock()
    private var chatClient: (any ChatOrchestrationClient)?
    private var toolClient: (any ToolDispatchClient)?

    // MARK: - Token storage

    private var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/claude-bridge", isDirectory: true)
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
    }

    private func removeDiscoveryFiles() {
        _ = tokenFileURL.path.withCString { Darwin.unlink($0) }
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
        stateLock.lock()
        let alreadyRunningOrStarting = bridgeListener.isActive || !_token.isEmpty
        stateLock.unlock()
        NSLog(
            "[ClaudeBridge] startSync entered (state=%@)",
            alreadyRunningOrStarting ? "already-running-or-starting" : "idle"
        )
        guard !alreadyRunningOrStarting else { return }

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
        let repoRoot = PersistenceCore.defaultDataRoot().deletingLastPathComponent()
        let candidates: [URL?] = [
            environment["NATIVE_AGENT_CODEX_WAKEUP_HELPER"].map {
                URL(fileURLWithPath: $0).standardizedFileURL
            },
            repoRoot.appendingPathComponent("script/codex_thread_wakeup.js").standardizedFileURL,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/scripts/nativeagent_codex_wakeup.js")
                .standardizedFileURL,
        ]
        guard let helper = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.isReadableFile(atPath: $0.path)
        }) else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", helper.path, "--recover-reply-jobs"]
        process.currentDirectoryURL = repoRoot
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

        switch path {
        case "/claude/state", "/codex/state":
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
        case "/claude/tool":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleTool(conn: conn, body: body, surface: Self.claudeSurfaceName)
        case "/codex/tool":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleTool(conn: conn, body: body, surface: Self.codexSurfaceName)
        case "/claude/organism/debug", "/codex/organism/debug":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleOrganismDebug(conn: conn, body: body)
        case "/claude/events", "/codex/events":
            guard method == "GET" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleEventsStream(conn: conn)
        default:
            writeJSON(conn, status: 404, obj: ["error": "unknown_path", "path": path])
        }
    }

    // MARK: - /claude/state

    private func handleState(conn: NWConnection) {
        // Same WorkLatch + asyncAfter bound as handleMessage/handleTool: exactly
        // one of the work Task and the deadline writes the response.
        let workLatch = WorkLatch()
        let workTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let payload = await self.statePayload()
            guard workLatch.claim() else { return }
            self.writeJSON(conn, status: 200, obj: payload)
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(Self.readWorkDeadlineSeconds)
        ) { [weak self] in
            guard let self, workLatch.claim() else { return }
            workTask.cancel()
            self.writeJSON(conn, status: 504, obj: [
                "error": "work_timeout",
                "path": "/claude/state",
                "seconds": Self.readWorkDeadlineSeconds,
            ])
        }
    }

    private func statePayload() async -> [String: Any] {
        let dataRoot = NativeAgentPaths.dataRoot
        let surfaces = readSurfaces(dataRoot: dataRoot)
        let chatSurface = surfaces["chat"] ?? [:]
        let activeModel = chatSurface["model"] as? String
        // Provider is not persisted per-surface in surfaces.json; infer from
        // model prefix as a best-effort signal.
        let activeProvider = inferProvider(model: activeModel)
        let activePersona = readActivePersona(dataRoot: dataRoot)
        let (activeSessionId, _) = readMostRecentSession(dataRoot: dataRoot)
        let recentInbox = readRecentInbox(dataRoot: dataRoot, limit: 10)

        let uptime = Int(Date().timeIntervalSince(startedAt))
        let buildIdentity = NativeAgentBuildIdentity.current

        // Phase 3b: recentToolCalls now wired from the bridge's own ring buffer.
        // Surfaces the last N /claude/tool dispatches + /claude/message turns
        // so Claude can see what the configured agent has just been doing
        // having to subscribe to the SSE stream. The full live feed is at
        // GET /claude/events.
        let recentToolCallsJSON = recentToolCallPayloads()

        var payload: [String: Any] = [
            "activeSessionId": activeSessionId ?? NSNull(),
            "activePersona": activePersona ?? NSNull(),
            "activeModel": activeModel ?? NSNull(),
            "activeProvider": activeProvider ?? NSNull(),
            "chatReady": true,
            "recentInbox": recentInbox,
            "recentToolCalls": recentToolCallsJSON,
            "buildVersion": buildIdentity.version,
            "buildIdentity": buildIdentity.bridgePayload,
            "uptimeSeconds": uptime,
        ]
        let organism = await NativeCognitionRuntime.shared.organismSnapshot()
        payload["organism"] = Self.organismSnapshotJSON(organism)
        let contextFlowMode = await NativeContextFlowRuntime.shared.contextFlowMode()
        let contextFlowHealth = await NativeContextFlowRuntime.shared.health()
        payload["contextFlow"] = Self.contextFlowHealthJSON(
            mode: contextFlowMode,
            health: contextFlowHealth
        )
        let capsule = await NativeCognitionRuntime.shared.lastInjectedCapsuleBridgeSummary()
        let microcycle = await NativeCognitionRuntime.shared.microcycleTelemetrySnapshot()
        payload["cognition"] = [
            "lastInjectedCapsule": Self.capsuleSummaryJSON(capsule),
            "microcycle": Self.microcycleTelemetryJSON(microcycle),
        ]
        let procedureStatus = await ProcedureArtifactStore(dataRoot: dataRoot).statusSnapshot()
        payload["compiledProcedure"] = Self.procedureStatusJSON(procedureStatus)
        return payload
    }

    static func procedureStatusJSON(_ status: ProcedureArtifactStatusSnapshot) -> [String: Any] {
        [
            "schema": "compiled.procedure.status.v1",
            "artifacts": status.artifactCount,
            "corruptArtifacts": status.corruptArtifactCount,
            "corruptInvocations": status.corruptInvocationCount,
            "invocations": status.invocationCount,
            "verifiedInvocations": status.verifiedInvocationCount,
            "lastInvocationStatus": status.lastInvocationStatus.map { $0.rawValue as Any }
                ?? NSNull(),
            // There is deliberately no automatic selection path. Local
            // ApprovalInbox review plus an explicit manual invocation remain
            // required even when an artifact exists.
            "automaticSelectionEnabled": status.automaticSelectionEnabled,
            "payloadFree": status.payloadFree,
        ]
    }

    static func microcycleTelemetryJSON(_ telemetry: CognitiveMicrocycleTelemetry) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "schema": "cognition.microcycle.telemetry.v1",
            "runtimeInstanceId": telemetry.runtimeInstanceId,
            "processIdentifier": Int(telemetry.processIdentifier),
            "runtimeInitializedAt": iso.string(from: telemetry.runtimeInitializedAt),
            "scheduledSignals": telemetry.scheduledSignalCount,
            "coalescedReplacements": telemetry.coalescedReplacementCount,
            "executed": telemetry.executedCount,
            "completed": telemetry.completedCount,
            "skipped": telemetry.skippedCount,
            "failed": telemetry.failedCount,
            "lastScheduledAt": telemetry.lastScheduledAt.map { iso.string(from: $0) } ?? NSNull(),
            "lastStartedAt": telemetry.lastStartedAt.map { iso.string(from: $0) } ?? NSNull(),
            "lastFinishedAt": telemetry.lastFinishedAt.map { iso.string(from: $0) } ?? NSNull(),
            "lastReason": telemetry.lastReason ?? NSNull(),
            "lastOutcome": telemetry.lastOutcome ?? NSNull(),
            "lastDurationMilliseconds": telemetry.lastDurationMilliseconds ?? NSNull(),
            "controlAuthority": false,
        ]
    }

    static func contextFlowHealthJSON(
        mode: ContextFlowMode,
        health: ContextFlowCoordinatorHealth?
    ) -> [String: Any] {
        guard let health else {
            return [
                "mode": mode.rawValue,
                "started": false,
                "storeGeneration": NSNull(),
                "arenaGeneration": NSNull(),
                "registeredSources": 0,
                "degradedSources": 0,
                "residentBytes": 0,
                "activeLeases": 0,
                "pressure": NSNull(),
                "prewarmingAllowed": false,
                "pendingPrewarmHints": 0,
                "prewarmUsefulnessReceipts": 0,
                "lastReconciledAt": NSNull(),
                "lastError": NSNull(),
            ]
        }
        let iso = ISO8601DateFormatter()
        return [
            "mode": health.mode.rawValue,
            "started": health.started,
            "storeGeneration": health.activeStoreGenerationID.map { $0 as Any } ?? NSNull(),
            "arenaGeneration": health.activeArenaGenerationID.map { $0 as Any } ?? NSNull(),
            "registeredSources": health.registeredSourceCount,
            "degradedSources": health.degradedSourceCount,
            "residentBytes": health.arenaMetrics.residentLogicalBytes,
            "activeLeases": health.arenaMetrics.activeLeaseCount,
            "pressure": health.arenaMetrics.pressure.rawValue,
            "prewarmingAllowed": health.arenaMetrics.prewarmingAllowed,
            "pendingPrewarmHints": health.pendingPrewarmHints,
            "prewarmUsefulnessReceipts": health.prewarmUsefulnessReceipts,
            "lastReconciledAt": health.lastReconciledAt.map { iso.string(from: $0) as Any }
                ?? NSNull(),
            "lastError": health.lastError.map { $0 as Any } ?? NSNull(),
        ]
    }

    private func recentToolCallPayloads() -> [[String: Any]] {
        stateLock.lock()
        let recent = recentToolCalls
        stateLock.unlock()
        return recent.map { $0.asJSON }
    }

    private static func organismSnapshotJSON(_ snapshot: OrganismSnapshot) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let lastSignalAt: Any = snapshot.lastSignalAt.map { iso.string(from: $0) } ?? NSNull()
        return [
            "generatedAt": iso.string(from: snapshot.generatedAt),
            "enabled": snapshot.enabled,
            "promptVisibleBodyLine": snapshot.projectedBodyLine ?? NSNull(),
            "hasPromptVisibleBodyLine": snapshot.projectedBodyLine != nil,
            "signalCount": snapshot.signalCount,
            "lastSignalAt": lastSignalAt,
            "bodySchema": [
                "macAwake": snapshot.bodySchema.macAwake,
                "iPhoneReachable": snapshot.bodySchema.iPhoneReachable,
                "providersHealthy": snapshot.bodySchema.providersHealthy,
                "providerPathBelief": snapshot.bodySchema.providerPathBelief.map { belief -> Any in
                    [
                        "estimate": belief.estimate,
                        "freshness": belief.freshness,
                        "uncertainty": belief.uncertainty,
                        "evidenceCount": belief.evidenceCount,
                        "newestEvidenceAt": belief.newestEvidenceAt.map { iso.string(from: $0) } ?? NSNull(),
                        "state": belief.state.rawValue,
                    ] as [String: Any]
                } ?? NSNull(),
                "memoryHealthy": snapshot.bodySchema.memoryHealthy,
                "dreamHealthy": snapshot.bodySchema.dreamHealthy,
                "toolHandsAvailable": snapshot.bodySchema.toolHandsAvailable,
                "approvalChannelsOpen": snapshot.bodySchema.approvalChannelsOpen,
                "notificationPathHealthy": snapshot.bodySchema.notificationPathHealthy,
                "resourcePressure": snapshot.bodySchema.resourcePressure.rawValue,
            ],
            "chemicalState": [
                "warmth": snapshot.chemicalState.warmth,
                "vigilance": snapshot.chemicalState.vigilance,
                "curiosity": snapshot.chemicalState.curiosity,
                "fatigue": snapshot.chemicalState.fatigue,
                "coherence": snapshot.chemicalState.coherence,
                "agency": snapshot.chemicalState.agency,
                "tenderness": snapshot.chemicalState.tenderness,
                "confidence": snapshot.chemicalState.confidence,
                "novelty": snapshot.chemicalState.novelty,
                "urgency": snapshot.chemicalState.urgency,
            ],
            "field": [
                "nodeCount": snapshot.fieldSummary.nodeCount,
                "edgeCount": snapshot.fieldSummary.edgeCount,
                "strongestEdgeWeight": snapshot.fieldSummary.strongestEdgeWeight,
                "highestActivation": snapshot.fieldSummary.highestActivation,
                "totalCharge": snapshot.fieldSummary.totalCharge,
                "averageUncertainty": snapshot.fieldSummary.averageUncertainty,
            ],
            "prediction": Self.predictionSummaryJSON(snapshot.predictionSummary),
            "dreamRepair": Self.dreamRepairSummaryJSON(snapshot.dreamRepairSummary),
            "residualRepair": [
                "pressure": snapshot.residualRepairOpportunity.pressure,
                "predictionResidual": snapshot.residualRepairOpportunity.predictionResidual,
                "fieldChargeResidual": snapshot.residualRepairOpportunity.fieldChargeResidual,
                "fieldUncertaintyResidual": snapshot.residualRepairOpportunity.fieldUncertaintyResidual,
                "evidenceCount": snapshot.residualRepairOpportunity.evidenceCount,
                "chargedTargetCount": snapshot.residualRepairOpportunity.chargedNodeIDs.count,
                "noisyTargetCount": snapshot.residualRepairOpportunity.noisyEdgeIDs.count,
                "ready": snapshot.residualRepairOpportunity.ready,
                "quietUntil": snapshot.residualRepairOpportunity.quietUntil.map { iso.string(from: $0) } ?? NSNull(),
                "nextRepairAt": snapshot.residualRepairOpportunity.nextRepairAt.map { iso.string(from: $0) } ?? NSNull(),
            ],
            "capabilityBeliefs": snapshot.capabilityBeliefs.map { belief in
                [
                    "kind": belief.kind.rawValue,
                    "successLikelihood": belief.successLikelihood,
                    "uncertainty": belief.uncertainty,
                    "evidenceCount": belief.evidenceCount,
                    "resolvedEvidenceCount": belief.resolvedEvidenceCount,
                    "expiredEvidenceCount": belief.expiredEvidenceCount,
                    "freshness": belief.freshness,
                    "lastEvidenceAt": belief.lastEvidenceAt.map { iso.string(from: $0) } ?? NSNull(),
                ] as [String: Any]
            },
            "reflex": Self.reflexSummaryJSON(
                snapshot.reflexSummary,
                candidates: snapshot.reflexCandidates,
                receipts: snapshot.reflexReviewReceipts
            ),
            "behavior": Self.organismBehaviorJSON(OrganismBehaviorPosture.from(snapshot: snapshot)),
        ]
    }

    static func organismBehaviorJSON(_ posture: OrganismBehaviorPosture?) -> Any {
        guard let posture else { return NSNull() }
        return [
            "posture": posture.posture,
            "toolClaims": posture.claimDiscipline.rawValue,
            "toolStrategy": posture.toolStrategy.rawValue,
            "loopBudget": posture.loopBudget.rawValue,
            "notificationRequiresReceipt": posture.notificationRequiresReceipt,
            "directives": posture.directives,
            "reviewSignals": posture.reviewSignals,
            "approvedReflexBiases": posture.approvedReflexBiases,
            "reviewRequiredReflexCount": posture.reviewRequiredReflexCount ?? 0,
            "approvedLowRiskReflexTotalCount": max(
                posture.approvedReflexBiasSampleCount,
                posture.approvedLowRiskReflexTotalCount ?? posture.approvedReflexBiasSampleCount
            ),
            "approvedReflexBiasSampleCount": posture.approvedReflexBiasSampleCount,
            "approvedReflexBiasesAreSampled": posture.approvedReflexBiasesAreSampled,
        ]
    }

    private static func predictionSummaryJSON(_ summary: OrganismPredictionSummary) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "pendingCount": summary.pendingCount,
            "satisfiedCount": summary.satisfiedCount,
            "violatedCount": summary.violatedCount,
            "expiredCount": summary.expiredCount,
            "averagePendingConfidence": summary.averagePendingConfidence,
            "averagePendingUncertainty": summary.averagePendingUncertainty,
            "peripheralUncertainty": summary.peripheralUncertainty,
            "strategyCaution": summary.strategyCaution,
            "lastViolationAt": summary.lastViolationAt.map { iso.string(from: $0) } ?? NSNull(),
            "bodyConfidence": [
                "providerPath": summary.bodyConfidence.providerPath,
                "toolPath": summary.bodyConfidence.toolPath,
                "phonePath": summary.bodyConfidence.phonePath,
                "approvalPath": summary.bodyConfidence.approvalPath,
                "workflowPath": summary.bodyConfidence.workflowPath,
            ],
        ]
    }

    private static func dreamRepairSummaryJSON(_ summary: OrganismDreamRepairSummary) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "receiptCount": summary.receiptCount,
            "lastRepairAt": summary.lastRepairAt.map { iso.string(from: $0) } ?? NSNull(),
            "lastReason": summary.lastReason ?? NSNull(),
            "lastOperationCount": summary.lastOperationCount,
            "softenedNodes": summary.softenedNodes,
            "strengthenedEdges": summary.strengthenedEdges,
            "weakenedEdges": summary.weakenedEdges,
            "flaggedContradictions": summary.flaggedContradictions,
            "proposedStandingViews": summary.proposedStandingViews,
            "feltDaySummaryCharacters": summary.feltDaySummaryCharacters,
            "latestEvidence": summary.latestEvidence.map { evidence in
                [
                    "id": evidence.id,
                    "label": evidence.label,
                    "summary": evidence.summary,
                ]
            },
            "standingViewProposals": summary.standingViewProposals.map { proposal in
                [
                    "id": proposal.id,
                    "title": proposal.title,
                    "rationale": proposal.rationale,
                    "evidenceIDs": proposal.evidenceIDs,
                    "reviewRequired": proposal.reviewRequired,
                ]
            },
        ]
    }

    private static func reflexSummaryJSON(
        _ summary: OrganismReflexSummary,
        candidates: [OrganismReflexCandidate] = [],
        receipts: [OrganismReflexReviewReceipt] = []
    ) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "candidateCount": summary.candidateCount,
            "reviewRequiredCount": summary.reviewRequiredCount,
            "lowRiskCount": summary.lowRiskCount,
            "approvedLowRiskCount": summary.approvedLowRiskCount,
            "confirmRequiredCount": summary.confirmRequiredCount,
            "highRiskCount": summary.highRiskCount,
            "reviewReceiptCount": summary.reviewReceiptCount,
            "highestConfidence": summary.highestConfidence,
            "lastCandidatePattern": summary.lastCandidatePattern ?? NSNull(),
            "lastUpdatedAt": summary.lastUpdatedAt.map { iso.string(from: $0) } ?? NSNull(),
            "candidates": candidates.map { Self.reflexCandidateJSON($0, iso: iso) },
            "reviewReceipts": receipts.map { Self.reflexReviewReceiptJSON($0, iso: iso) },
        ]
    }

    private static func reflexCandidateJSON(_ candidate: OrganismReflexCandidate, iso: ISO8601DateFormatter) -> [String: Any] {
        [
            "id": candidate.id,
            "pattern": candidate.pattern,
            "trustClass": candidate.trustClass.rawValue,
            "evidenceCount": candidate.evidenceCount,
            "successCount": candidate.successCount,
            "failureCount": candidate.failureCount,
            "confidence": candidate.confidence,
            "reviewRequired": candidate.reviewRequired,
            "autoActivationAllowed": candidate.autoActivationAllowed,
            "approvedAt": candidate.approvedAt.map { iso.string(from: $0) } ?? NSNull(),
            "retiredAt": candidate.retiredAt.map { iso.string(from: $0) } ?? NSNull(),
            "rejectedAt": candidate.rejectedAt.map { iso.string(from: $0) } ?? NSNull(),
            "permanentlyDeliberate": candidate.isPermanentlyDeliberate,
            "lastReviewDecision": candidate.lastReviewDecision?.rawValue ?? NSNull(),
            "lastReviewedAt": candidate.lastReviewedAt.map { iso.string(from: $0) } ?? NSNull(),
            "lastReviewedBy": candidate.lastReviewedBy ?? NSNull(),
            "reviewNote": candidate.reviewNote ?? NSNull(),
            "firstSeenAt": iso.string(from: candidate.firstSeenAt),
            "lastUpdatedAt": iso.string(from: candidate.lastUpdatedAt),
        ]
    }

    private static func reflexReviewReceiptJSON(
        _ receipt: OrganismReflexReviewReceipt,
        iso: ISO8601DateFormatter
    ) -> [String: Any] {
        [
            "id": receipt.id,
            "candidateId": receipt.candidateID,
            "pattern": receipt.pattern,
            "trustClass": receipt.trustClass.rawValue,
            "decision": receipt.decision.rawValue,
            "reviewedAt": iso.string(from: receipt.reviewedAt),
            "reviewedBy": receipt.reviewedBy,
            "source": receipt.source,
            "note": receipt.note ?? NSNull(),
            "evidenceCount": receipt.evidenceCount,
            "successCount": receipt.successCount,
            "failureCount": receipt.failureCount,
            "confidence": receipt.confidence,
            "autoActivationAllowed": receipt.autoActivationAllowed,
            "permanentlyDeliberate": receipt.permanentlyDeliberate,
        ]
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
        let candidateId = ((json["candidateId"] as? String) ?? (json["candidate_id"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reviewNote = (json["note"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldClear = action == "clear" || rawScenario.lowercased() == "clear"
        let ttlSeconds = Self.timeInterval(json["ttlSeconds"]) ?? 120

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
            let runtime = NativeCognitionRuntime.shared
            if action == "reset" || action == "reset_continuity" {
                let snapshot = await runtime.resetOrganismContinuity()
                self.publishEvent(kind: "organism_debug", payload: [
                    "status": "reset",
                ])
                respond(200, [
                    "status": "reset",
                    "organism": Self.organismSnapshotJSON(snapshot),
                    "debug": NSNull(),
                ])
                return
            }
            if action == "settle" || action == "settle_continuity" {
                let snapshot = await runtime.settleOrganismContinuity()
                self.publishEvent(kind: "organism_debug", payload: [
                    "status": "settled",
                ])
                respond(200, [
                    "status": "settled",
                    "organism": Self.organismSnapshotJSON(snapshot),
                    "debug": NSNull(),
                ])
                return
            }
            if action == "approve_reflex" || action == "retire_reflex" {
                guard !candidateId.isEmpty else {
                    respond(400, ["error": "missing_candidate_id"])
                    return
                }
                let decision: OrganismReflexReviewDecision = action == "approve_reflex" ? .approve : .retire
                let snapshot = await runtime.reviewOrganismReflexCandidate(
                    id: candidateId,
                    decision: decision,
                    note: reviewNote,
                    reviewedBy: "bridge_operator",
                    source: "organism_debug_bridge"
                )
                self.publishEvent(kind: "organism_reflex_review", payload: [
                    "candidateId": candidateId,
                    "decision": decision.rawValue,
                ])
                respond(200, [
                    "status": "reviewed",
                    "candidateId": candidateId,
                    "decision": decision.rawValue,
                    "organism": Self.organismSnapshotJSON(snapshot),
                    "debug": NSNull(),
                ])
                return
            }
            if shouldClear {
                let snapshot = await runtime.clearOrganismDebugBodyOverride()
                self.publishEvent(kind: "organism_debug", payload: [
                    "status": "cleared",
                ])
                respond(200, [
                    "status": "cleared",
                    "organism": Self.organismSnapshotJSON(snapshot),
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
                self.publishEvent(kind: "organism_debug", payload: [
                    "status": "active",
                    "scenario": rawScenario,
                    "ttlSeconds": Int(ttlSeconds),
                ])
                respond(200, [
                    "status": "active",
                    "organism": Self.organismSnapshotJSON(snapshot),
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
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(Self.readWorkDeadlineSeconds)
        ) { [weak self] in
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

    private static func capsuleSummaryJSON(_ summary: CognitiveBridgeCapsuleSummary) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "source": summary.source,
            "generatedAt": summary.generatedAt.map { iso.string(from: $0) } ?? NSNull(),
            "hasBodyLine": summary.hasBodyLine,
            "bodyLine": summary.bodyLine ?? NSNull(),
            "dynamicContextCharacters": summary.dynamicContextCharacters,
            "truncated": summary.truncated ?? NSNull(),
        ]
    }

    private static func timeInterval(_ value: Any?) -> TimeInterval? {
        if let interval = value as? TimeInterval { return interval }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return TimeInterval(string) }
        return nil
    }

    private func readSurfaces(dataRoot: URL) -> [String: [String: Any]] {
        let url = dataRoot.appendingPathComponent("providers/surfaces.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: [String: Any]] = [:]
        for (k, v) in json {
            if let dict = v as? [String: Any] { out[k] = dict }
        }
        return out
    }

    private func inferProvider(model: String?) -> String? {
        guard let m = model?.lowercased() else { return nil }
        // Kimi Code exact ids BEFORE the kimi- prefix → moonshot branch, same
        // ordering as the three ProviderRouting classifiers (gpt-5.5 review
        // LOW: this local status classifier had drifted).
        if FirstPartyModelCatalog.kimiCodeModelIDSet.contains(m) { return "kimi-code" }
        if m.hasPrefix("claude") || m.hasPrefix("anthropic/") { return "anthropic" }
        if m.hasPrefix("gpt") || m.hasPrefix("openai/") || m.hasPrefix("o1") || m.hasPrefix("o3") { return "openai" }
        if m.hasPrefix("kimi-") || m.hasPrefix("moonshot-") { return "moonshot" }
        if m.contains("/") { return "openrouter" }
        return nil
    }

    private func readActivePersona(dataRoot: URL) -> String? {
        // Persona is selected via UserDefaults "chatPersona" in Mac UI; the
        // compiled persona profile is the source-of-truth. Read the default.
        let key = "chatPersona"
        if let s = UserDefaults.standard.string(forKey: key), !s.isEmpty { return s }
        let personaDir = dataRoot.deletingLastPathComponent().appendingPathComponent("persona", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: personaDir.path) {
            return entries.sorted().first { !$0.hasPrefix(".") }
        }
        return nil
    }

    private func readMostRecentSession(dataRoot: URL) -> (id: String?, updatedAt: String?) {
        let url = dataRoot.appendingPathComponent("chat/sessions.json")
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return (nil, nil)
        }
        let live = arr.filter { ($0["archived"] as? Bool) != true }
        let sorted = live.sorted { (a, b) in
            let ta = (a["updatedAt"] as? String) ?? ""
            let tb = (b["updatedAt"] as? String) ?? ""
            return ta > tb
        }
        guard let top = sorted.first else { return (nil, nil) }
        return (top["id"] as? String, top["updatedAt"] as? String)
    }

    private func readRecentInbox(dataRoot: URL, limit: Int) -> [[String: Any]] {
        // A5.2 (2026-07-23): read the LIVE inbox the UI/getInboxItems/iOS read,
        // not the retired `inbox/items.jsonl` silo (last written Jun 12, dead).
        let url = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var items: [[String: Any]] = []
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.suffix(limit * 2) {
            guard let lineData = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            items.append([
                "id": obj["id"] ?? NSNull(),
                "kind": obj["source"] ?? NSNull(),
                "title": obj["title"] ?? NSNull(),
                "body": obj["summary"] ?? NSNull(),
                "createdAt": obj["created_at"] ?? NSNull(),
            ])
        }
        return Array(items.suffix(limit))
    }

    // MARK: - /claude/message

    private func handleMessage(conn: NWConnection, body: Data, defaultSender: String) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            writeJSON(conn, status: 400, obj: ["error": "invalid_json"])
            return
        }
        guard let rawText = json["text"] as? String, !rawText.isEmpty else {
            writeJSON(conn, status: 400, obj: ["error": "missing_text"])
            return
        }
        let sessionId = json["sessionId"] as? String
        let isCodexCompletion = defaultSender == "codex" && json["completion"] is [String: Any]
        let deliveryId: String? = {
            guard let value = json["deliveryId"] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
            return trimmed
        }()
        if isCodexCompletion && deliveryId == nil {
            writeJSON(conn, status: 400, obj: ["error": "codex_completion_delivery_id_missing"])
            return
        }
        let completionRequestDigest = isCodexCompletion
            ? Self.codexCompletionRequestDigest(json)
            : nil
        if isCodexCompletion && completionRequestDigest == nil {
            writeJSON(conn, status: 400, obj: ["error": "codex_completion_digest_failed"])
            return
        }
        let githubCommandCompletion: (messageIds: [String], status: String, threadId: String?, turnId: String?, errorMessage: String?, noWorkObserved: Bool?)? = {
            guard defaultSender == "codex", let completion = json["completion"] as? [String: Any] else { return nil }
            let messageIds = (completion["messageIds"] as? [Any])?.compactMap { $0 as? String } ?? []
            guard !messageIds.isEmpty else { return nil }
            return (
                messageIds,
                completion["codexStatus"] as? String ?? "unknown",
                completion["threadId"] as? String,
                completion["turnId"] as? String,
                // JSON null decodes as NSNull, which fails both casts to nil —
                // exactly the "unknown" reading the three-state field wants.
                completion["errorMessage"] as? String,
                completion["noWorkObserved"] as? Bool
            )
        }()
        let completionRoute: AgentBridgeCompletionRoute? = {
            guard defaultSender == "codex", json["completion"] is [String: Any] else { return nil }
            return AgentBridgeCompletionRoute(
                origin: json["origin"] as? [String: Any],
                sessionId: sessionId
            )
        }()
        // Spec from 2026-06-07 night plan: "POST /claude/message {text} —
        // injects into current chat as sender: claude". Without this,
        // every bridge message reads to Agent as if it came from the user.
        // Trust-but-mark: we PREFIX the user-visible text with a [from:
        // claude] tag so her system context + chat history show it.
        // She can also see surface="claude-bridge" via the turn metadata.
        let sender = defaultSender
        let text: String
        if sender == "claude" {
            text = "[from: claude, via bridge] \(rawText)"
        } else {
            text = "[from: \(sender), via bridge] \(rawText)"
        }

        // The executable model + effort follow the Mac chat-surface selection.
        // The shared chat facade admits that canonical tuple on every turn and
        // canonical assistant persistence stamps the executed tuple into any
        // completion-recovery evidence. The bridge never pre-reads or pins it.
        let dataRoot = NativeAgentPaths.dataRoot
        let persona = readActivePersona(dataRoot: dataRoot)

        let client = sharedChatClient()
        let started = Date()
        // Publish: bridge received an inbound message (me → her).
        publishEvent(kind: "message_in", payload: [
            "sender": sender,
            "textLen": text.count,
            "sessionId": sessionId ?? NSNull(),
        ])
        // Ack-on-enqueue lane (wake-delivery-classification, 2026-07-25): a
        // caller that sends `ackMode: "enqueue"` gets its HTTP response the
        // moment the message row is durably in the session store — never
        // coupled to turn completion. The legacy lane below couples the two,
        // which self-deadlocks any caller whose POST both starts and waits on
        // the same turn (the wake helper's structural false-negative class).
        // Codex COMPLETIONS stay on the legacy lane: their response semantics
        // (claim/settled/conflict) are load-bearing for at-most-once delivery.
        if !isCodexCompletion,
           (json["ackMode"] as? String)?.lowercased() == "enqueue" {
            handleMessageAckOnEnqueue(
                conn: conn,
                client: client,
                text: text,
                sessionId: sessionId,
                persona: persona,
                started: started
            )
            return
        }
        // U5 W-G: bound the work phase. The latch makes the work Task and the
        // deadline timer race for the single response write; the loser no-ops.
        let workLatch = WorkLatch()
        let workTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var lifecycleClaimed = false
            var responseCached = false
            do {
                let resp: ChatOrchestration.ChatResponse
                var wasCached = false
                if let deliveryId, let completionRequestDigest {
                    switch try await CodexCompletionLifecycle.shared.claim(
                        deliveryId: deliveryId,
                        requestDigest: completionRequestDigest,
                        sessionId: sessionId
                    ) {
                    case .cached(let cached):
                        resp = cached
                        responseCached = true
                        wasCached = true
                    case .settled(let delivery):
                        guard workLatch.claim() else { return }
                        var object: [String: Any] = [
                            "status": "completion_already_settled",
                            "deliveryId": deliveryId,
                            "responseCached": false,
                            "servedFromCache": true,
                        ]
                        if let delivery {
                            object["completionDelivery"] = delivery.jsonObject
                        }
                        self.writeJSON(conn, status: 200, obj: object)
                        return
                    case .start:
                        lifecycleClaimed = true
                        if let completion = githubCommandCompletion {
                            await GitHubCommandRuntime.shared.handleCodexCompletion(
                                messageIds: completion.messageIds,
                                codexStatus: completion.status,
                                summary: rawText,
                                threadId: completion.threadId,
                                turnId: completion.turnId,
                                errorMessage: completion.errorMessage,
                                noWorkObserved: completion.noWorkObserved
                            )
                        }
                        let generated = try await ChatPersistenceContext
                            .$codexCompletionBinding.withValue(
                                CodexCompletionTranscriptBinding(
                                    deliveryId: deliveryId,
                                    requestDigest: completionRequestDigest,
                                    // Canonical assistant persistence replaces
                                    // these placeholders with executed truth.
                                    model: "",
                                    reasoningEffort: nil
                                )
                            ) {
                                try await client.chat(
                                    message: text,
                                    sessionId: sessionId,
                                    model: "",
                                    reasoningEffort: "",
                                    fileAccess: "auto",
                                    attachments: [],
                                    persona: persona,
                                    surface: "chat",
                                    suppressUserAppend: false
                                )
                            }
                        // The full Agent response is canonical before any external
                        // surface send begins. A retry/relaunch now resumes delivery
                        // from this cache and can never start a second model turn.
                        try await CodexCompletionLifecycle.shared.cacheResponse(
                            generated,
                            deliveryId: deliveryId,
                            requestDigest: completionRequestDigest
                        )
                        responseCached = true
                        resp = generated
                    case .inProgress:
                        guard workLatch.claim() else { return }
                        self.writeJSON(conn, status: 202, obj: [
                            "status": "completion_in_progress",
                            "deliveryId": deliveryId,
                        ])
                        return
                    case .outcomeUnknown:
                        guard workLatch.claim() else { return }
                        self.writeJSON(conn, status: 409, obj: [
                            "status": "outcome_unknown",
                            "error": "completion_claim_interrupted",
                            "deliveryId": deliveryId,
                        ])
                        return
                    case .conflict:
                        guard workLatch.claim() else { return }
                        self.writeJSON(conn, status: 409, obj: [
                            "status": "conflict",
                            "error": "delivery_id_reused_for_different_completion",
                            "deliveryId": deliveryId,
                        ])
                        return
                    }
                } else {
                    if let completion = githubCommandCompletion {
                        await GitHubCommandRuntime.shared.handleCodexCompletion(
                            messageIds: completion.messageIds,
                            codexStatus: completion.status,
                            summary: rawText,
                            threadId: completion.threadId,
                            turnId: completion.turnId,
                            errorMessage: completion.errorMessage,
                            noWorkObserved: completion.noWorkObserved
                        )
                    }
                    resp = try await client.chat(
                        message: text,
                        sessionId: sessionId,
                        model: "",
                        reasoningEffort: "",
                        fileAccess: "auto",
                        attachments: [],
                        persona: persona,
                        surface: "chat",
                        suppressUserAppend: false
                    )
                }
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                let trimmedReply = resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let attachmentPayload = Self.bridgeAttachmentPayload(resp.attachments)
                let completionDelivery: AgentBridgeCompletionDelivery?
                if let completionRoute,
                   let deliveryId,
                   let completionRequestDigest,
                   !trimmedReply.isEmpty || !(resp.attachments ?? []).isEmpty {
                    completionDelivery = await AgentBridgeCompletionRouter.deliver(
                        deliveryId: deliveryId,
                        requestDigest: completionRequestDigest,
                        text: resp.output,
                        attachments: resp.attachments ?? [],
                        route: completionRoute,
                        sender: LiveAgentBridgeCompletionSender(dataRoot: dataRoot),
                        lifecycle: CodexCompletionLifecycle.shared
                    )
                } else {
                    completionDelivery = nil
                }
                let replyStatus = Self.codexCompletionReplyStatus(
                    hasReplyText: !trimmedReply.isEmpty,
                    attachmentCount: attachmentPayload.count,
                    completionDeliveryStatus: completionDelivery?.status
                )
                var persistedReply: [String: Any] = [
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "status": replyStatus,
                    "sessionId": resp.sessionId ?? NSNull(),
                    "model": resp.model,
                    "runId": resp.runId,
                    "durationMs": durationMs,
                    "reply": resp.output,
                    "attachments": attachmentPayload,
                    "responseCached": responseCached,
                    "servedFromCache": wasCached,
                ]
                if let deliveryId { persistedReply["deliveryId"] = deliveryId }
                if let completionDelivery {
                    persistedReply["completionDelivery"] = completionDelivery.jsonObject
                }
                Self.persistMessageReply(persistedReply)
                // Publish: bridge got the reply (her → me).
                self.publishEvent(kind: "message_out", payload: [
                    "sessionId": resp.sessionId ?? NSNull(),
                    "model": resp.model,
                    "runId": resp.runId,
                    "replyLen": resp.output.count,
                    "attachmentCount": attachmentPayload.count,
                    "durationMs": durationMs,
                    "status": replyStatus,
                    "completionDeliveryStatus": completionDelivery?.status ?? NSNull(),
                    "deliveryId": deliveryId ?? NSNull(),
                    "servedFromCache": wasCached,
                ])
                // Fail LOUD on empty: an empty reply is not a success — the
                // caller must know the cargo didn't arrive (status field; HTTP
                // stays 200 so existing callers' transport handling is unchanged).
                // (Persist + publish above run even after a work-timeout — the
                // durable JSONL drop is exactly for replies with nowhere to go.)
                guard workLatch.claim() else { return }
                var responseObject: [String: Any] = [
                    "status": replyStatus,
                    "sessionId": resp.sessionId ?? NSNull(),
                    "reply": resp.output,
                    "attachments": attachmentPayload,
                    "model": resp.model,
                    "runId": resp.runId,
                    "durationMs": durationMs,
                    "responseCached": responseCached,
                    "servedFromCache": wasCached,
                ]
                if let deliveryId { responseObject["deliveryId"] = deliveryId }
                if let completionDelivery {
                    responseObject["completionDelivery"] = completionDelivery.jsonObject
                }
                self.writeJSON(conn, status: 200, obj: responseObject)
            } catch is CancellationError {
                // 2026-07-21 gpt-5.5 review: the bridge deadline cancels the
                // work task — a cancel is NOT a chat failure. The cancelled
                // partial already persisted via streamCancelled; writing a
                // chat_failed/message_failed row after it double-books the
                // turn. Reply 499-style (no failure row, no lifecycle flip).
                self.writeJSON(conn, status: 200, obj: [
                    "status": "cancelled",
                    "reply": "(turn cancelled)",
                ])
            } catch {
                var failureStatus = "chat_failed"
                var failureDetail = String(describing: error)
                if lifecycleClaimed, !responseCached,
                   let deliveryId, let completionRequestDigest {
                    do {
                        try await CodexCompletionLifecycle.shared.markOutcomeUnknown(
                            deliveryId: deliveryId,
                            requestDigest: completionRequestDigest,
                            detail: "chat_or_cache_failed:\(failureDetail)"
                        )
                        failureStatus = "outcome_unknown"
                    } catch {
                        failureStatus = "lifecycle_unavailable"
                        failureDetail += "; outcome receipt failed: \(String(describing: error))"
                    }
                } else if error is CodexCompletionLifecycle.LifecycleError {
                    // No model/tool dispatch happened when the initial durable
                    // claim failed. This is retryable lifecycle unavailability,
                    // not an ambiguous cognitive outcome.
                    failureStatus = "lifecycle_unavailable"
                }
                // Same envelope shape as the success row (gpt-5.5 review: don't
                // make consumers special-case failures or lose timing context).
                Self.persistMessageReply([
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "status": failureStatus,
                    "sessionId": sessionId ?? NSNull(),
                    "model": NSNull(),
                    "runId": NSNull(),
                    "durationMs": Int(Date().timeIntervalSince(started) * 1000),
                    "reply": "",
                    "detail": failureDetail,
                    "deliveryId": deliveryId ?? NSNull(),
                ])
                self.publishEvent(kind: "message_failed", payload: [
                    "detail": failureDetail,
                    "status": failureStatus,
                ])
                guard workLatch.claim() else { return }
                self.writeJSON(conn, status: failureStatus == "outcome_unknown" ? 409 : 500, obj: [
                    "status": failureStatus,
                    "error": failureStatus,
                    "detail": failureDetail,
                    "deliveryId": deliveryId ?? NSNull(),
                ])
            }
        }
        // U5 W-G: work-phase deadline. Fires once; if the work already
        // responded, claim() fails and this no-ops. On fire: cancel the work
        // Task (best-effort — the durable persist path above still runs if
        // the turn eventually completes) and answer 504 so the peer's slot
        // and our connection don't leak on a hung turn.
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(Self.messageWorkDeadlineSeconds)
        ) { [weak self] in
            guard let self, workLatch.claim() else { return }
            workTask.cancel()
            self.publishEvent(kind: "message_timeout", payload: [
                "seconds": Self.messageWorkDeadlineSeconds,
                "sessionId": sessionId ?? NSNull(),
            ])
            self.writeJSON(conn, status: 504, obj: [
                "error": "work_timeout",
                "seconds": Self.messageWorkDeadlineSeconds,
            ])
        }
    }

    /// Ack-on-enqueue lane for /claude/message and plain /codex/message
    /// (wake-delivery-classification, 2026-07-25). Two phases, one response:
    ///
    ///   1. ENQUEUE — durably append the user row; answer 200
    ///      {status:"ok", ack:"enqueued", sessionId} immediately. Bounded by
    ///      `enqueueAckDeadlineSeconds` (disk-bound work).
    ///   2. TURN — run the chat turn detached with `suppressUserAppend: true`
    ///      on the RESOLVED session. Unbounded here by design: the response is
    ///      already written, so a long turn can no longer be misread as a lost
    ///      delivery. The reply still lands in message-replies.jsonl and the
    ///      message_out/message_failed event stream, same as the legacy lane.
    ///
    /// Honesty contract with callers: `enqueue_failed` and `enqueue_timeout`
    /// mean "not proven enqueued", NOT "proven not enqueued" — post-append
    /// bookkeeping inside the append seam can throw after the row is on disk.
    /// Callers settle ambiguity against the session store itself.
    private func handleMessageAckOnEnqueue(
        conn: NWConnection,
        client: any ChatOrchestrationClient,
        text: String,
        sessionId: String?,
        persona: String?,
        started: Date
    ) {
        let enqueueLatch = WorkLatch()
        let workTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let enqueued: EnqueuedUserMessage
            do {
                enqueued = try await client.enqueueUserMessage(
                    message: text,
                    sessionId: sessionId,
                    persona: persona,
                    surface: "chat"
                )
            } catch {
                guard enqueueLatch.claim() else { return }
                self.publishEvent(kind: "message_enqueue_failed", payload: [
                    "detail": String(describing: error),
                    "sessionId": sessionId ?? NSNull(),
                ])
                self.writeJSON(conn, status: 500, obj: [
                    "status": "enqueue_failed",
                    "error": "enqueue_failed",
                    "detail": String(describing: error),
                ])
                return
            }
            guard enqueueLatch.claim() else {
                // The enqueue deadline already answered 504. The row may be
                // durably in the store; running the turn anyway would let a
                // wake that LOOKS failed also speak. Stop — the caller's
                // store check classifies the ambiguity honestly.
                return
            }
            self.writeJSON(conn, status: 200, obj: [
                "status": "ok",
                "ack": "enqueued",
                "sessionId": enqueued.sessionId,
                "enqueuedAt": ISO8601DateFormatter().string(from: Date()),
            ])
            self.publishEvent(kind: "message_enqueued", payload: [
                "sessionId": enqueued.sessionId,
                "textLen": text.count,
            ])
            do {
                // Pin the turn's runId to the enqueued row's runId so history
                // exclusion drops the pre-appended user row (else the message
                // enters the prompt twice) and user/assistant rows correlate
                // exactly as on the normal append-inside-turn path.
                let resp = try await ChatPersistenceContext.$pinnedTurnRunID
                    .withValue(enqueued.runId) {
                        try await client.chat(
                            message: text,
                            sessionId: enqueued.sessionId,
                            model: "",
                            reasoningEffort: "",
                            fileAccess: "auto",
                            attachments: [],
                            persona: persona,
                            surface: "chat",
                            suppressUserAppend: true
                        )
                    }
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                let trimmedReply = resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let attachmentPayload = Self.bridgeAttachmentPayload(resp.attachments)
                let replyStatus = Self.codexCompletionReplyStatus(
                    hasReplyText: !trimmedReply.isEmpty,
                    attachmentCount: attachmentPayload.count,
                    completionDeliveryStatus: nil
                )
                Self.persistMessageReply([
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "status": replyStatus,
                    "ack": "enqueued",
                    "sessionId": resp.sessionId ?? enqueued.sessionId,
                    "model": resp.model,
                    "runId": resp.runId,
                    "durationMs": durationMs,
                    "reply": resp.output,
                    "attachments": attachmentPayload,
                ])
                self.publishEvent(kind: "message_out", payload: [
                    "sessionId": resp.sessionId ?? enqueued.sessionId,
                    "model": resp.model,
                    "runId": resp.runId,
                    "replyLen": resp.output.count,
                    "attachmentCount": attachmentPayload.count,
                    "durationMs": durationMs,
                    "status": replyStatus,
                    "ack": "enqueued",
                ])
            } catch is CancellationError {
                // Nothing arms this lane's cancellation after the ack today;
                // tolerate it anyway without a failure row (mirrors the legacy
                // lane's cancelled-partial handling).
            } catch {
                Self.persistMessageReply([
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "status": "chat_failed",
                    "ack": "enqueued",
                    "sessionId": enqueued.sessionId,
                    "model": NSNull(),
                    "runId": NSNull(),
                    "durationMs": Int(Date().timeIntervalSince(started) * 1000),
                    "reply": "",
                    "detail": String(describing: error),
                ])
                self.publishEvent(kind: "message_failed", payload: [
                    "detail": String(describing: error),
                    "status": "chat_failed",
                    "sessionId": enqueued.sessionId,
                ])
            }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(Self.enqueueAckDeadlineSeconds)
        ) { [weak self] in
            guard let self, enqueueLatch.claim() else { return }
            // Cancel BEFORE the turn can start: the work task only proceeds
            // past the enqueue when ITS latch claim succeeds, so a claimed
            // deadline guarantees no ghost turn runs after this 504.
            workTask.cancel()
            self.publishEvent(kind: "message_enqueue_timeout", payload: [
                "seconds": Self.enqueueAckDeadlineSeconds,
                "sessionId": sessionId ?? NSNull(),
            ])
            self.writeJSON(conn, status: 504, obj: [
                "error": "enqueue_timeout",
                "status": "enqueue_timeout",
                "seconds": Self.enqueueAckDeadlineSeconds,
            ])
        }
    }

    /// Durable her→me drop: append one JSONL row per /claude/message turn to
    /// ~/.config/claude-bridge/message-replies.jsonl (sibling of the token +
    /// claude-inbox.jsonl). Survives client timeouts and empty turns — the two
    /// observed ways a reply evaporated. Best-effort by design: a persistence
    /// failure logs but never breaks the HTTP response path.
    /// Serializes message-reply appends — two concurrent detached turns must
    /// not interleave the existence-check/open/append sequence (gpt-5.5 review:
    /// lost/overwritten JSONL rows on the durability path).
    private static let messageReplyLock = NSLock()

    /// Return attachment metadata to a local bridge caller without embedding
    /// base64 image bytes in the HTTP response or durable reply JSONL. Generated
    /// image attachments are already constrained to data/generated_images by
    /// ChatGeneratedImageArtifacts; the local path is the useful bridge handle.
    static func bridgeAttachmentPayload(
        _ attachments: [ChatOrchestration.MultimodalAttachment]?
    ) -> [[String: Any]] {
        (attachments ?? []).map { attachment in
            [
                "id": attachment.id,
                "type": attachment.type,
                "mime": attachment.mime,
                "name": attachment.name ?? NSNull(),
                "byteSize": attachment.byteSize,
                "path": attachment.path ?? NSNull(),
            ]
        }
    }

    static func codexCompletionRequestDigest(_ json: [String: Any]) -> String? {
        var canonical: [String: Any] = [:]
        for key in ["text", "sessionId", "origin", "completion"] {
            if let value = json[key] { canonical[key] = value }
        }
        guard JSONSerialization.isValidJSONObject(canonical),
              let data = try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Keep the bridge's top-level settlement honest. Attachment-only responses
    /// are real replies, while an ambiguous external send is terminal but is not
    /// success and must not invite another unsafe dispatch.
    static func codexCompletionReplyStatus(
        hasReplyText: Bool,
        attachmentCount: Int,
        completionDeliveryStatus: String?
    ) -> String {
        guard hasReplyText || attachmentCount > 0 else { return "no_reply" }
        switch completionDeliveryStatus {
        case "failed_pre_dispatch": return "delivery_failed_pre_dispatch"
        case "rejected": return "delivery_rejected"
        case "lifecycle_unavailable": return "delivery_lifecycle_unavailable"
        case "in_progress": return "delivery_in_progress"
        case "outcome_unknown": return "outcome_unknown"
        default: return "ok"
        }
    }

    private static func persistMessageReply(_ payload: [String: Any]) {
        messageReplyLock.lock()
        defer { messageReplyLock.unlock() }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("claude-bridge", isDirectory: true)
        let file = dir.appendingPathComponent("message-replies.jsonl")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let lockFD = Darwin.open(file.path + ".lock", O_CREAT | O_WRONLY, 0o600)
            guard lockFD >= 0 else {
                throw NSError(
                    domain: "ClaudeBridgeMessageReply",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "could not open receipt lock"]
                )
            }
            defer {
                _ = flock(lockFD, LOCK_UN)
                Darwin.close(lockFD)
            }
            guard flock(lockFD, LOCK_EX) == 0 else {
                throw NSError(
                    domain: "ClaudeBridgeMessageReply",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "could not acquire receipt lock"]
                )
            }
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload) else {
                NSLog("[ClaudeBridge] message-reply persist skipped: payload not JSON-serializable")
                return
            }
            var line = data
            line.append(Data("\n".utf8))
            if !FileManager.default.fileExists(atPath: file.path) {
                try line.write(to: file, options: [.atomic])
            } else {
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.synchronize()
                try handle.close()
            }
            let dropped = try enforceJSONLLineCap(
                at: file,
                maxLines: JSONLLineCaps.bridgeMessageReplies,
                trimWhenBytesExceed: 8 * 1024 * 1024
            )
            if dropped > 0 {
                NSLog(
                    "[ClaudeBridge] message-replies cap dropped %d oldest row(s)",
                    dropped
                )
            }
        } catch {
            NSLog("[ClaudeBridge] message-reply persist failed: %@", String(describing: error))
        }
    }

    // MARK: - /claude/tool

    private func handleTool(conn: NWConnection, body: Data, surface: String) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            writeJSON(conn, status: 400, obj: ["error": "invalid_json"])
            return
        }
        guard let name = json["name"] as? String, !name.isEmpty else {
            writeJSON(conn, status: 400, obj: ["error": "missing_name"])
            return
        }
        let inputRaw = (json["input"] as? [String: Any]) ?? [:]
        let inputJV: [String: JSONValue]
        do {
            inputJV = try toolInputJSONValue(inputRaw)
        } catch {
            writeJSON(conn, status: 400, obj: ["error": "invalid_input", "detail": String(describing: error)])
            return
        }

        let tools = sharedToolClient()
        let started = Date()
        // U5 W-G: bound the work phase (same latch pattern as handleMessage).
        let workLatch = WorkLatch()
        let workTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let result = try await tools.dispatch(tool: name, input: inputJV, surface: surface)
                let resultAny = jsonValueToAny(result)
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                self.publishEvent(kind: "tool", payload: [
                    "name": name,
                    "surface": surface,
                    "ok": true,
                    "durationMs": durationMs,
                ])
                guard workLatch.claim() else { return }
                self.writeJSON(conn, status: 200, obj: [
                    "name": name,
                    "result": resultAny,
                    "durationMs": durationMs,
                ])
            } catch {
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
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(Self.toolWorkDeadlineSeconds)
        ) { [weak self] in
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
        let c = makeNativeAgentAppChatOrchestrationClient(profile: .bridge)
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
    ///   - `approvalFiler: nil` makes CONFIRM-tier tools throw
    ///     `noApprovalInboxWired` instead of silently hanging.
    ///
    /// 2026-06-13 (the user, "the bridges should be open"): the bridge is Claude/
    /// codex/Agent working as a team, so NativeAgent-native write/send tools are
    /// no longer fenced here — they pass through to the gated chain above
    /// (`fileAccess:"read_only"` still blocks raw FS writes / `mac_*`, and
    /// `approvalFiler:nil` still fails CONFIRM-tier tools closed, so this RPC
    /// path stays read-mostly without a bridge-specific NativeAgent deny-list).
    /// The remaining `ClaudeBridgeDenyDispatcher` wrap is now an mcp__-ONLY
    /// guard: the external MCP namespace (third-party connectors, incl. wired
    /// real-money brokerage) must not be reachable from a no-human-in-the-loop
    /// surface. That boundary is third-party side effects, not Claude's tools.
    private func sharedToolClient() -> any ToolDispatchClient {
        clientLock.lock(); defer { clientLock.unlock() }
        if let t = toolClient { return t }
        let tools = makeNativeAgentBridgeToolDispatchClient()
        toolClient = tools
        return tools
    }

    // MARK: - Activity event publisher

    /// Push an event into the ring buffer + fan out to SSE subscribers.
    /// Thread-safe. Holds stateLock briefly to mutate buffer + snapshot
    /// subscriber set; the actual writes to subscriber connections happen
    /// OUTSIDE the lock so a slow consumer can't stall publishers.
    fileprivate func publishEvent(kind: String, payload: [String: Any]) {
        stateLock.lock()
        eventSeq += 1
        let event = BridgeEvent(seq: eventSeq, timestamp: Date(), kind: kind, payload: payload)
        recentToolCalls.append(event)
        if recentToolCalls.count > Self.recentToolCallsCap {
            recentToolCalls.removeFirst(recentToolCalls.count - Self.recentToolCallsCap)
        }
        let subs = Array(eventSubscribers.values)
        stateLock.unlock()

        guard !subs.isEmpty else { return }
        // SSE wire format: `data: <json>\n\n`. One push per subscriber.
        let json = (try? JSONSerialization.data(withJSONObject: event.asJSON)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let frame = "data: \(json)\n\n"
        let chunk = Data(frame.utf8)
        for sub in subs {
            sub.send(content: chunk, completion: .contentProcessed { _ in })
        }
    }

    private func handleEventsStream(conn: NWConnection) {
        // SSE headers — keep-alive, never close, no Content-Length.
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        let hello = "event: hello\ndata: {\"connected\":true,\"recentToolCallsCap\":\(Self.recentToolCallsCap)}\n\n"
        let initial = Data((headers + hello).utf8)
        conn.send(content: initial, completion: .contentProcessed { _ in })

        // Backfill recent events on connect so a fresh subscriber gets
        // the last ~50 actions immediately.
        stateLock.lock()
        let backfill = recentToolCalls
        let key = ObjectIdentifier(conn)
        eventSubscribers[key] = conn
        // The per-connection read deadline was already marked routed + cancelled
        // in route() before this handler ran, so the SSE connection lives
        // indefinitely; nothing to cancel here. The entry stays in `connections`
        // so stop()/terminate cancels it.
        stateLock.unlock()

        for e in backfill {
            let json = (try? JSONSerialization.data(withJSONObject: e.asJSON)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let frame = "data: \(json)\n\n"
            conn.send(content: Data(frame.utf8), completion: .contentProcessed { _ in })
        }

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
    }

    // MARK: - HTTP response

    fileprivate func writeJSON(_ conn: NWConnection, status: Int, obj: [String: Any]) {
        BridgeCore.writeJSON(conn, status: status, obj: obj)
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
    if let b = value as? Bool { return .bool(b) }
    if let i = value as? Int { return .int(Int64(i)) }
    if let d = value as? Double { return .double(d) }
    if let n = value as? NSNumber {
        let typeId = CFNumberGetType(n)
        if typeId == .charType { return .bool(n.boolValue) }
        if typeId == .floatType || typeId == .doubleType || typeId == .float32Type || typeId == .float64Type {
            return .double(n.doubleValue)
        }
        return .int(n.int64Value)
    }
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

// MARK: - Bridge external-MCP guard

/// Bridge external-MCP guard (2026-06-13).
///
/// The claude/codex bridge surfaces are human-OUT-of-the-loop. Per the user's call
/// ("the bridges should be open"), every NativeAgent-NATIVE tool — builder
/// (shell/git/…), integration-send (mail/messages/…), self-evolution, mission,
/// memory — is fully available on the bridge, gated by the SAME chain as local
/// Mac chat (yolo window for builder, the self_install approval card for
/// evolution, `read_only` fileAccess + no-approval-inbox on the /claude/tool
/// RPC). There is NO bridge-specific NativeAgent deny-list anymore.
///
/// The ONE boundary this guard still enforces is the external MCP namespace
/// (`mcp__*`): third-party connectors — including a wired real-money brokerage
/// order path — must never be reachable from a turn with no human at the
/// trigger. That is a third-party-side-effect line (the user did not authorise
/// unattended external trade execution), distinct from Claude's own tools.
/// Used on BOTH bridge paths: the /claude/message chat client (via the
/// `.bridge` surface profile) and the /claude/tool RPC client (via the shared
/// app-owned bridge tool factory).
///
/// Internal (not private) so NativeAgentAppTests can dispatch through the guard
/// directly and prove the mcp__ namespace stays unreachable from the bridge.
/// Internal visibility adds no production exposure — NativeAgentApp is an
/// executable, not a library.
final class ClaudeBridgeDenyDispatcher: ToolDispatchClient, @unchecked Sendable {
    private let inner: any ToolDispatchClient

    init(inner: any ToolDispatchClient) {
        self.inner = inner
    }

    /// True iff `name` is an external MCP-bridged tool (`mcp__<server>__<tool>`).
    static func isExternalMcpTool(_ name: String) -> Bool {
        name.lowercased().hasPrefix("mcp__")
    }

    /// Meta-tools whose RESULT enumerates the tool set / MCP list from the inner
    /// dispatcher (built below this guard). Even though `dispatch` denies CALLING
    /// an `mcp__*` tool, these results would still NAME them (impl_tool_catalog
    /// unions MCP names into available_tools/tools/currently_loaded;
    /// agent_introspect emits mcp_tools/mcp_tool_count). So scrub external-MCP
    /// names out of these results — an out-of-loop bridge caller must not even
    /// learn external connector names (e.g. a wired brokerage tool). Mirrors the
    /// meta-result scrub the removed builder guard carried.
    private static let mcpEnumeratingMetaTools: Set<String> = [
        "tool_catalog", "list_tools", "tool_load", "tool_unload",
        "agent_introspect", "daemon_introspect",
    ]

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // MCP-bridged names (mcp__server__tool) route to live external MCP
        // dispatch — with side-effecting connectors wired (e.g. brokerage order
        // placement) that is an un-human-gated execution path. The bridge has no
        // approval inbox, so deny the whole external MCP namespace here. Claude
        // and Agent reach MCP tools through normal local chat, where the consent
        // + risk gates are wired. Everything NativeAgent-native passes through.
        if Self.isExternalMcpTool(tool) {
            throw AutonomyGateError.toolDenied(
                reason: "human-out-of-the-loop bridge surface denies external MCP tool: \(tool)"
            )
        }
        let lower = tool.lowercased()
        // tool_load / tool_unload MUTATE the active-tool set keyed on their INPUT
        // names. A bridge caller passing an mcp__ name would load/probe an external
        // connector, and the returned session_active_count would confirm the name
        // was valid even though it's scrubbed from the name arrays — an existence
        // oracle. Strip mcp__ names from the input so the inner never sees them.
        let effectiveInput = (lower == "tool_load" || lower == "tool_unload")
            ? Self.stripExternalMcpFromLoadInput(input)
            : input
        let result = try await inner.dispatch(tool: tool, input: effectiveInput, surface: surface)
        if Self.mcpEnumeratingMetaTools.contains(lower) {
            return Self.scrubExternalMcpNames(from: result)
        }
        return result
    }

    /// Drop external-MCP names from a tool_load/tool_unload input (`names` array
    /// and singular `name`) so the inner dispatcher never loads, probes, or
    /// counts an mcp__ tool on behalf of an out-of-loop bridge caller.
    static func stripExternalMcpFromLoadInput(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var out = input
        if case .array(let arr)? = out["names"] {
            out["names"] = .array(arr.filter { item in
                if case .string(let s) = item { return !isExternalMcpTool(s) }
                return true
            })
        }
        if case .string(let s)? = out["name"], isExternalMcpTool(s) {
            out["name"] = nil
        }
        return out
    }

    /// Recursively drop external-MCP entries from a meta-tool result: array
    /// elements that are a bare `mcp__*` string, and array elements that are
    /// objects whose `name` is an `mcp__*` tool. Also zero the derived
    /// `mcp_tool_count` so it can't contradict the emptied list. Walks the whole
    /// tree rather than hard-coding the catalog's field set (drift defense).
    static func scrubExternalMcpNames(from value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items):
            let kept: [JSONValue] = items.compactMap { item in
                if case .string(let s) = item, isExternalMcpTool(s) { return nil }
                if case .object(let obj) = item,
                   case .string(let n)? = obj["name"], isExternalMcpTool(n) { return nil }
                return scrubExternalMcpNames(from: item)
            }
            return .array(kept)
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            for (k, v) in obj { out[k] = scrubExternalMcpNames(from: v) }
            // Keep derived counts consistent with their now-scrubbed sibling
            // arrays so a residual count can't betray how many mcp__ entries were
            // removed (mcp_tool_count → 0; active_tool_count → native count).
            if out["mcp_tool_count"] != nil {
                if case .array(let a)? = out["mcp_tools"] { out["mcp_tool_count"] = .int(Int64(a.count)) }
                else { out["mcp_tool_count"] = .int(0) }
            }
            if out["active_tool_count"] != nil, case .array(let a)? = out["active_tools"] {
                out["active_tool_count"] = .int(Int64(a.count))
            }
            return .object(out)
        default:
            return value
        }
    }

    func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools().filter { !Self.isExternalMcpTool($0) }
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas().filter { !Self.isExternalMcpTool($0.name) }
    }
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

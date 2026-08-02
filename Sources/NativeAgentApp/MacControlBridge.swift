// PATCH-2026-05-07: mac-control-bridge In-app HTTP server that runs Mac Control
// subprocess calls (osascript, shortcuts, pmset, …) under the NativeAgent bundle
// identity so macOS attributes TCC requests (Automation, Accessibility, Full Disk
// Access, etc.) to NativeAgent.app, not to a retired external runtime.
//
// Wire-up: AppDelegate.applicationDidFinishLaunching starts the listener,
// preferring port 8770 and advancing on collision, with a random shared-secret token written to
// ~/Library/Application Support/NativeAgent/macctl_bridge.json (chmod 0600).
// Swift runtime callers read that file and forward approved subprocess
// invocations through this bridge.
//
// Endpoint surface:
//   POST /macctl/exec    body: {"protocolVersion":2, "operationId":"…", "argv":[…], "stdin":"…", "timeout":30}
//                        resp: {"protocolVersion":2,"operationId":"…","exit":0,"stdout":"","stderr":"","duration_ms":…}
//   POST /macctl/cancel  body: {"operationId":"…"}; request acknowledgement
//                        is distinct from terminal process-death acknowledgement.
//   GET  /macctl/health  resp: {"ok":true,"version":"…"}
//   GET  /macctl/info    resp: {"port":…,"bundleId":"…","version":"…"}
//
// Auth: every request except /macctl/health requires `Authorization: Bearer <token>`.

import Foundation
import Darwin
import MacControl
import NativeAgentCore
import Network
import PersistenceCore

/// Lock-protected by `MacControlBridge.stateLock` in production. Kept as a
/// value type so restart/admission races can be proven without opening a real
/// listener or touching the live personal data root.
struct MacControlBridgeStartupState: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var recoveryInProgress = false

    mutating func begin(listenerExists: Bool) -> UInt64? {
        guard !listenerExists, !recoveryInProgress else { return nil }
        generation &+= 1
        recoveryInProgress = true
        return generation
    }

    func mayContinueAfterRecovery(
        generation attempt: UInt64,
        recoverySucceeded: Bool,
        listenerExists: Bool
    ) -> Bool {
        recoverySucceeded
            && recoveryInProgress
            && generation == attempt
            && !listenerExists
    }

    mutating func finish(generation attempt: UInt64) -> Bool {
        guard recoveryInProgress, generation == attempt else { return false }
        recoveryInProgress = false
        return true
    }

    mutating func stop() {
        generation &+= 1
        recoveryInProgress = false
    }
}

// PATCH-2026-05-07: bridge-off-main Bridge runs OFF the main actor. MainActor
// is contended at app launch (iCloud `forUbiquityContainerIdentifier` does a
// synchronous query that can block for seconds), and tasks dispatched onto
// it stall — including network connection accept callbacks. The bridge has
// no UI dependency, so all its state is guarded by a private dispatch queue
// and an internal lock instead.
final class MacControlBridge: NSObject, @unchecked Sendable, BridgeHTTPServer {
    static let shared = MacControlBridge()

    private let bridgeListener = NativeLoopbackPortFallbackListener(
        preferredPort: MacControlBridge.port,
        label: "MacControlBridge"
    )
    /// Listener admission is held behind durable-operation recovery. The
    /// generation prevents a stopped/restarted attempt from being completed by
    /// an older asynchronous recovery task.
    private var startupState = MacControlBridgeStartupState()
    private let stateLock = NSLock()
    private struct ConnectionEntry {
        let conn: NWConnection
        var deadline: BridgeReadDeadlineState
        let deadlineWork: DispatchWorkItem
    }

    // Each accepted connection owns one exact cancellable request-read
    // deadline. A routed request cancels that deadline and is then bounded by
    // its operation timeout. With no accepted connections there is no timer,
    // sweep, or idle wake.
    private var connections: [ObjectIdentifier: ConnectionEntry] = [:]
    // Max time a connection may sit after accept WITHOUT having
    // its request fully read+routed. Covers the slow-loris case where the peer
    // trickles or never finishes the HTTP request.
    private static let connectionReadTimeout: TimeInterval = 30
    private var _token: String = ""
    private var _activePort: UInt16 = 0
    var token: String { stateLock.lock(); defer { stateLock.unlock() }; return _token }
    var activePort: UInt16 { stateLock.lock(); defer { stateLock.unlock() }; return _activePort }

    static let port: UInt16 = 8770
    private static let maxRequestBodyBytes = 2 * 1024 * 1024
    private static let execLimit = 2
    private static let execOutputLimitBytes = 1_048_576
    private static let operationStore = MacControlOperationStore(dataRoot: NativeAgentPaths.dataRoot)
    private final class ExecResultBox: @unchecked Sendable {
        var value: [String: Any]
        init(_ value: [String: Any]) { self.value = value }
    }
    private final class ExecState: @unchecked Sendable {
        let lock = NSLock()
        var activeProcesses: [String: Process] = [:]
        var cancelRequested: Set<String> = []
        var cancelSignalled: Set<String> = []
        var processExited: Set<String> = []
    }
    private static let execState = ExecState()
    // fix-audit-append-race: serialize appendExecAudit. Multiple exec background
    // threads (plus route/accept threads) call it concurrently; each does
    // FileHandle open → seekToEnd → write. Without serialization two writers can
    // seek to the same end offset and clobber/interleave each other's JSONL line.
    private static let auditAppendLock = NSLock()

    /// The exec concurrency gate. The count lives INSIDE `ScopedSlotCounter`
    /// and is private to it, so there is no way to admit an exec without
    /// holding a `ScopedSlot` handle, and no way to release except by letting
    /// that handle die (`deinit` is the only release path).
    ///
    /// fix-exec-slot-leak (2026-08-02): the handler used to acquire a raw
    /// counter increment and rely solely on the `defer` inside the background
    /// dispatch block. Any throw between the acquire and that block (the
    /// durable `.started` transition throws on flock contention or a full disk)
    /// unwound straight to the request's outer catch WITHOUT entering the block,
    /// leaking the slot permanently. `execLimit` is 2, so two such throws pinned
    /// the count at the limit and every subsequent `/macctl/exec` returned 429
    /// until the app was restarted — `stopAllProcesses` deliberately refuses to
    /// zero the count, so emergency_stop could not recover it either.
    /// With the handle idiom the throw unwinds THROUGH the handle, whose deinit
    /// releases; the background block owns the release only because it captures
    /// the handle explicitly.
    static let execSlots = ScopedSlotCounter(name: "macctl-exec", limit: execLimit)

    private static func currentExecCount() -> Int { execSlots.activeCount }

    private static func registerProcess(_ proc: Process, operationId: String) {
        execState.lock.lock()
        execState.activeProcesses[operationId] = proc
        execState.lock.unlock()
    }

    private static func unregisterProcess(operationId: String) {
        execState.lock.lock()
        execState.activeProcesses.removeValue(forKey: operationId)
        execState.processExited.insert(operationId)
        execState.lock.unlock()
    }

    private static func requestCancellation(operationId: String) -> Bool {
        execState.lock.lock()
        if execState.processExited.contains(operationId) {
            execState.lock.unlock()
            return false
        }
        execState.cancelRequested.insert(operationId)
        guard let process = execState.activeProcesses[operationId] else {
            execState.lock.unlock()
            return false
        }
        let pid = process.processIdentifier
        let running = process.isRunning
        if running { execState.cancelSignalled.insert(operationId) }
        execState.lock.unlock()
        guard running else { return true }
        if killpg(pid, SIGTERM) != 0 { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning, killpg(pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
        }
        return true
    }

    private static func cancellationWasRequested(operationId: String) -> Bool {
        execState.lock.lock()
        defer { execState.lock.unlock() }
        return execState.cancelRequested.contains(operationId)
    }

    private static func consumeCancellation(operationId: String) -> (requested: Bool, signalled: Bool) {
        execState.lock.lock()
        defer { execState.lock.unlock() }
        execState.processExited.remove(operationId)
        return (
            execState.cancelRequested.remove(operationId) != nil,
            execState.cancelSignalled.remove(operationId) != nil
        )
    }

    nonisolated static func execTerminalState(
        exit: Int,
        timedOut: Bool,
        cancellationSignalled: Bool
    ) -> MacControlOperationState {
        if timedOut { return .timedOut }
        if cancellationSignalled, exit != 0 { return .cancelAcknowledged }
        return exit == 0 ? .completed : .failed
    }

    private static func stopAllProcesses(reason: String) -> Int {
        execState.lock.lock()
        let processes = execState.activeProcesses
        execState.cancelRequested.formUnion(processes.keys)
        execState.cancelSignalled.formUnion(processes.compactMap { key, process in
            process.isRunning ? key : nil
        })
        execState.activeProcesses.removeAll()
        // fix-emergency-stop-race: do NOT try to zero the exec slot count here.
        // Every admitted exec still holds a live `ScopedSlot` handle whose
        // deinit releases it when the background block unwinds. Forcing the
        // count to zero on top of that would double-count each release, driving
        // it below the true number of live slots and letting the next burst
        // over-admit past execLimit. `ScopedSlotCounter` keeps the count private
        // precisely so this shortcut is not expressible.
        execState.lock.unlock()
        final class ProcessSnapshot: @unchecked Sendable {
            let processes: [String: Process]
            init(_ processes: [String: Process]) {
                self.processes = processes
            }
        }
        let snapshot = ProcessSnapshot(processes)
        for (_, proc) in processes where proc.isRunning {
            let pid = proc.processIdentifier
            if killpg(pid, SIGTERM) != 0 {
                proc.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for (_, proc) in snapshot.processes where proc.isRunning {
                let pid = proc.processIdentifier
                if killpg(pid, SIGKILL) != 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
        appendExecAudit(argv: ["emergency_stop"], status: "cancel_requested", reason: "\(reason): \(processes.count)")
        return processes.count
    }

    // MARK: - App support dir + bridge descriptor

    // Phase 11c: use the shared resolver so macctl_bridge.json goes to
    // <repo>/data/ rather than ~/Library/Application Support/NativeAgent/.
    private var appSupportDir: URL {
        NativeAgentPaths.dataRoot
    }

    private var descriptorURL: URL {
        appSupportDir.appendingPathComponent("macctl_bridge.json")
    }

    private func writeDescriptor(token: String, port: UInt16) {
        let dir = appSupportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundleId = Bundle.main.bundleIdentifier ?? "local.nativeagent.NativeAgent"
        let buildIdentity = NativeAgentBuildIdentity.current
        let payload: [String: Any] = [
            "port": Int(port),
            "token": token,
            "bundleId": bundleId,
            "version": buildIdentity.version,
            "build": buildIdentity.build,
            "sourceRevision": buildIdentity.sourceRevision ?? NSNull(),
            "sourceDirty": buildIdentity.sourceDirty,
            "exactSourceRevision": buildIdentity.exactSourceRevision ?? NSNull(),
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        _ = NativePrivateFile.write(data, to: descriptorURL)
    }

    private func removeDescriptor() {
        try? FileManager.default.removeItem(at: descriptorURL)
    }

    // MARK: - Lifecycle

    /// A1.3 (prerelease-upgrade-campaign): don't bind 8770 or mint a bearer
    /// token until Mac Control is actually switched on. Reads the SAME live
    /// policy file + key `bridgePolicyAllows` already uses
    /// (`<dataRoot>/trust/policy.json` → `macControlPolicy.enabled`), so there
    /// is one policy source for this bridge, not two. Absent/unparseable file
    /// or absent key ⇒ false ⇒ no listener.
    ///
    /// Verified safe to gate (consumer sweep 2026-08-02): the 8770 listener has
    /// ZERO in-repo clients — the in-app Mac Control tool lane runs in-process
    /// through `MacControlGate` + `SystemProcessAdapter`, and iOS remote Mac
    /// actions go over iCloud sync / `NativeClient /v1/mac_control/*`, never
    /// this socket. And with `enabled == false` every `/macctl/exec` was
    /// already rejected 403 `exec_blocked` by `bridgePolicyAllows`, so the bind
    /// produced nothing but an occupied port and an on-disk descriptor
    /// advertising a live token.
    nonisolated static func startGateAllows() -> Bool {
        let policyURL = NativeAgentPaths.dataRoot
            .appendingPathComponent("trust")
            .appendingPathComponent("policy.json")
        let json: [String: Any]? = {
            guard let data = try? Data(contentsOf: policyURL) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }()
        return startGateAllows(policyJSON: json)
    }

    /// Pure decision seam for `startGateAllows()` — same semantics, no I/O.
    /// `policyJSON == nil` models a missing/unparseable policy file.
    nonisolated static func startGateAllows(policyJSON: [String: Any]?) -> Bool {
        guard let macPolicy = policyJSON?["macControlPolicy"] as? [String: Any] else {
            return false
        }
        // STRICT — see BridgeCore.strictBool: a numeric `1` must NOT open a
        // gate that binds a port and mints a bearer token.
        return BridgeCore.strictBool(macPolicy["enabled"])
    }

    func start() {
        // Gate BEFORE the startup-state latch, the operation-recovery Task, and
        // `BridgeCore.generateToken()` — a gated-off launch must leave no
        // listener, no in-memory token, and no descriptor on disk.
        guard Self.startGateAllows() else {
            NSLog(
                "NativeAgent MacControlBridge not starting: macControlPolicy.enabled is false "
                + "— no port bound, no token minted"
            )
            // Sweep a descriptor left by a crashed or pre-gate run: it still
            // advertises a bearer token for a port nothing is listening on
            // (gpt-5.5 review, NEEDS_FIX). Unconditional here — unlike
            // ClaudeBridge's shared ~/.config path, this descriptor lives
            // under THIS instance's dataRoot, so it can only be our own.
            removeDescriptor()
            return
        }
        stateLock.lock()
        guard let generation = startupState.begin(listenerExists: bridgeListener.isActive) else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        // A restarted app cannot still own a process from the prior instance.
        // Terminalize interrupted durable rows before creating the listener,
        // advertising its descriptor, or accepting any duplicate operation ID.
        removeDescriptor()
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Self.operationStore.recoverInterruptedOperations()
            } catch {
                NSLog("NativeAgent MacControl operation recovery failed closed: \(error)")
                self.failStartup(generation: generation)
                return
            }
            self.startListenerAfterRecovery(generation: generation)
        }
    }

    private func startListenerAfterRecovery(generation: UInt64) {
        stateLock.lock()
        let attemptIsCurrent = startupState.mayContinueAfterRecovery(
            generation: generation,
            recoverySucceeded: true,
            listenerExists: bridgeListener.isActive
        )
        stateLock.unlock()
        guard attemptIsCurrent else { return }

        // Generate token
        guard let tk = BridgeCore.generateToken() else {
            NSLog("NativeAgent MacControlBridge failed to generate a secure bridge token")
            failStartup(generation: generation)
            return
        }
        stateLock.lock()
        guard startupState.mayContinueAfterRecovery(
            generation: generation,
            recoverySucceeded: true,
            listenerExists: bridgeListener.isActive
        ), startupState.finish(generation: generation) else {
            stateLock.unlock()
            return
        }
        _token = tk
        _activePort = 0
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
            _token = ""
        }
        stateLock.unlock()
        if !started { removeDescriptor() }
    }

    private func handleListenerReady(token: String, port: UInt16) {
        stateLock.lock()
        guard _token == token else {
            stateLock.unlock()
            return
        }
        _activePort = port
        // Publish while lifecycle ownership is held so stop cannot remove the
        // descriptor and then lose a race to a stale ready callback.
        writeDescriptor(token: token, port: port)
        stateLock.unlock()
        print("[MacCtlBridge] listening on 127.0.0.1:\(port)")
    }

    private func failStartup(generation: UInt64) {
        stateLock.lock()
        guard startupState.finish(generation: generation) else {
            stateLock.unlock()
            return
        }
        _token = ""
        _activePort = 0
        stateLock.unlock()
        removeDescriptor()
    }

    /// Drop in-memory state + the descriptor when the live socket dies.
    /// The token generation rejects callbacks from a retired socket.
    private func handleListenerTerminated(token: String) {
        stateLock.lock()
        guard _token == token else { stateLock.unlock(); return }
        _token = ""
        _activePort = 0
        let entries = Array(connections.values)
        connections.removeAll()
        stateLock.unlock()
        for entry in entries {
            entry.deadlineWork.cancel()
            entry.conn.cancel()
        }
        removeDescriptor()
    }

    /// Cancel the listener + all live connections and read deadlines, clear
    /// the in-memory token, and remove the on-disk descriptor. Idempotent.
    /// Mirrors ClaudeBridge.stop(); called from applicationWillTerminate so a
    /// quit can't leave a descriptor advertising a port nothing is serving.
    ///
    /// Also terminates active exec children (gpt-5.5 review, 2026-07-09):
    /// each `/macctl/exec` child runs in its own process group precisely so it
    /// can be killed as a unit — but cancelling the HTTP connection alone never
    /// signals it, so quitting NativeAgent mid-exec orphaned `osascript`/
    /// `shortcuts`/etc. Same SIGTERM→SIGKILL ladder as the emergency stop.
    func stop() {
        stateLock.lock()
        startupState.stop()
        let entries = Array(connections.values)
        connections.removeAll()
        _token = ""
        _activePort = 0
        stateLock.unlock()
        bridgeListener.stop()
        for entry in entries {
            entry.deadlineWork.cancel()
            entry.conn.cancel()
        }
        removeDescriptor()
        _ = Self.stopAllProcesses(reason: "bridge_stop")
    }

    private func accept(_ conn: NWConnection) {
        guard BridgeCore.endpointIsLoopback(conn.endpoint) else {
            Self.appendExecAudit(argv: ["remote_connection"], status: "blocked", reason: "non_loopback_peer")
            conn.cancel()
            return
        }
        stateLock.lock()
        let bridgeIsReady = !_token.isEmpty && _activePort != 0
        stateLock.unlock()
        guard bridgeIsReady else {
            conn.cancel()
            return
        }
        let key = ObjectIdentifier(conn)
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
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.connectionReadTimeout,
            execute: deadlineWork
        )
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.stateLock.lock()
                let removed = self.connections.removeValue(forKey: key)
                self.stateLock.unlock()
                removed?.deadlineWork.cancel()
            default: break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        BridgeCore.readRequest(conn, buffered: Data(), maxBodyBytes: Self.maxRequestBodyBytes, server: self)
    }

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
        // The request is fully read. Cancel its one-shot read deadline; the
        // routed operation/response lifetime is bounded by the exec timeout.
        let routeKey = ObjectIdentifier(conn)
        stateLock.lock()
        var readDeadlineWork: DispatchWorkItem?
        if var entry = connections[routeKey] {
            entry.deadline.routed = true
            connections[routeKey] = entry
            readDeadlineWork = entry.deadlineWork
        }
        stateLock.unlock()
        readDeadlineWork?.cancel()
        // Health is unauthenticated; everything else requires bearer token.
        // Shared best-of-both auth (BridgeCore.authorize): constant-time compare
        // + empty-token 503 guard (the listener terminated between accept and
        // now → `token` is "", so reject even a peer that sent "Bearer " rather
        // than leaking that race window as a 200).
        if path != "/macctl/health" {
            switch BridgeCore.authorize(authorizationHeader: headers["authorization"], liveToken: token) {
            case .serverStopping:
                writeJSON(conn, status: 503, obj: ["error": "server_stopping"])
                return
            case .unauthorized:
                writeJSON(conn, status: 401, obj: ["error": "unauthorized"])
                return
            case .authorized:
                break
            }
        }

        switch path {
        case "/macctl/health":
            var payload: [String: Any] = [
                "ok": true,
                "bundleId": Bundle.main.bundleIdentifier ?? "",
            ]
            payload.merge(NativeAgentBuildIdentity.current.bridgePayload) { _, new in new }
            writeJSON(conn, status: 200, obj: payload)
        case "/macctl/info":
            let port = activePort
            var payload: [String: Any] = [
                "ok": true,
                "port": Int(port),
                "bundleId": Bundle.main.bundleIdentifier ?? "",
            ]
            payload.merge(NativeAgentBuildIdentity.current.bridgePayload) { _, new in new }
            writeJSON(conn, status: 200, obj: payload)
        case "/macctl/emergency_stop":
            guard method == "POST" || method == "GET" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            let stopped = Self.stopAllProcesses(reason: "operator requested emergency stop")
            writeJSON(conn, status: 200, obj: [
                "ok": true,
                "stopped": stopped,
                "active": Self.currentExecCount(),
                "via": "macctl-bridge",
            ])
        case "/macctl/exec":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            execHandler(conn: conn, body: body)
        case "/macctl/cancel":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            cancelHandler(conn: conn, body: body)
        case "/macctl/spotlight_frame":
            // PATCH-2026-05-07: spotlight-frame Report the overlay panel's
            // current frame so external probes can read the preferred size.
            if let f = SpotlightOverlayProbe.currentFrame() {
                writeJSON(conn, status: 200, obj: [
                    "ok": true,
                    "x": f.0,
                    "y": f.1,
                    "width": f.2,
                    "height": f.3,
                ])
            } else {
                writeJSON(conn, status: 404, obj: ["ok": false, "error": "panel_not_open"])
            }
        default:
            writeJSON(conn, status: 404, obj: ["error": "unknown_path", "path": path])
        }
    }

    // MARK: - Exec handler — runs subprocess UNDER NativeAgent.app

    private func cancelHandler(conn: NWConnection, body: Data) {
        let json = body.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        guard let operationId = json["operationId"] as? String,
              MacControlOperationStore.validOperationId(operationId) else {
            writeJSON(conn, status: 400, obj: ["error": "invalid_operation_id"])
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let current = try await Self.operationStore.record(operationId: operationId) else {
                    self.writeJSON(conn, status: 404, obj: [
                        "error": "operation_not_found",
                        "operationId": operationId,
                    ])
                    return
                }
                if current.state.isTerminal {
                    self.writeJSON(conn, status: 200, obj: [
                        "ok": current.state == .cancelAcknowledged,
                        "operationId": operationId,
                        "operationState": current.state.rawValue,
                        "cancelAcknowledged": current.state == .cancelAcknowledged,
                    ])
                    return
                }
                if current.state != .cancelRequested {
                    _ = try await Self.operationStore.transition(
                        operationId: operationId,
                        to: .cancelRequested,
                        verification: .pending,
                        expectedNextEvidence: "Process-group death acknowledgement",
                        outcomeCode: "cancel_requested"
                    )
                }
                _ = Self.requestCancellation(operationId: operationId)
                Self.appendExecAudit(
                    argv: ["cancel"],
                    status: "cancel_requested",
                    reason: nil,
                    operationId: operationId
                )
                self.writeJSON(conn, status: 202, obj: [
                    "ok": true,
                    "operationId": operationId,
                    "operationState": MacControlOperationState.cancelRequested.rawValue,
                    "cancelAcknowledged": false,
                ])
            } catch {
                self.writeJSON(conn, status: 409, obj: [
                    "error": "cancel_transition_failed",
                    "detail": error.localizedDescription,
                    "operationId": operationId,
                ])
            }
        }
    }

    nonisolated private static func bridgePolicyAllows(executable exe: String, argv: [String] = []) -> Bool {
        let policyURL = NativeAgentPaths.dataRoot
            .appendingPathComponent("trust")
            .appendingPathComponent("policy.json")
        guard let data = try? Data(contentsOf: policyURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let policy = json["macControlPolicy"] as? [String: Any],
              policy["enabled"] as? Bool == true
        else {
            return false
        }
        switch exe {
        case "sh", "bash", "zsh":
            return false
        case "osascript":
            let wantsJXA = osascriptUsesJavaScript(argv)
            if wantsJXA {
                return policy["jxa_allowed"] as? Bool == true
            }
            return policy["applescript_allowed"] as? Bool == true
        case "shortcuts":
            return policy["shortcuts_allowed"] as? Bool == true
        case "pmset":
            return policy["system_control_allowed"] as? Bool == true
                && bridgeDestructiveActionsAllowed(json)
        case "mdfind":
            return policy["spotlight_allowed"] as? Bool == true
        case "ls":
            return policy["file_ops_allowed"] as? Bool == true && bridgeFullMacAccessIsActive(json)
        case "mv":
            return policy["file_ops_allowed"] as? Bool == true
                && bridgeDestructiveActionsAllowed(json)
                && bridgeFullMacAccessIsActive(json)
        default:
            return false
        }
    }

    nonisolated private static func osascriptUsesJavaScript(_ argv: [String]) -> Bool {
        for (idx, arg) in argv.enumerated() {
            let lower = arg.lowercased()
            if lower == "-l", idx + 1 < argv.count, argv[idx + 1].lowercased() == "javascript" {
                return true
            }
            if lower == "-ljavascript" || lower == "-l javascript" {
                return true
            }
        }
        return false
    }

    nonisolated private static func bridgeFullMacAccessIsActive(_ policy: [String: Any]) -> Bool {
        let permissionLevel = (policy["permissionLevel"] as? String) ?? ""
        let filePolicy = policy["filePolicy"] as? [String: Any]
        let outsideDefault = (filePolicy?["outsideWorkspaceDefault"] as? String) ?? "deny"
        guard outsideDefault == "allow" || permissionLevel == "wide_open_receipts" || permissionLevel == "full_mac_os" else {
            return false
        }
        let expiresAt = ((policy["fullMacExpiresAt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if policy["fullMacNeverExpires"] as? Bool == true || expiresAt.lowercased() == "never" {
            return true
        }
        if !expiresAt.isEmpty {
            if let expires = tolerantISO8601Date(from: expiresAt) {
                return Date() <= expires
            }
            return false
        }
        guard let confirmedAt = policy["fullMacConfirmedAt"] as? String,
              let confirmed = tolerantISO8601Date(from: confirmedAt)
        else {
            return false
        }
        let rawHours = policy["fullMacMaxDurationHours"] as? Double ?? 4
        let hours = min(max(rawHours, 0.1), 24)
        return Date() <= confirmed.addingTimeInterval(hours * 3600)
    }

    nonisolated private static func bridgeDestructiveActionsAllowed(_ policy: [String: Any]) -> Bool {
        policy["developerMode"] as? Bool == true
    }

    nonisolated private static func tolerantISO8601Date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private static let allowedExecutablePaths: [String: String] = [
        "osascript": "/usr/bin/osascript",
        "shortcuts": "/usr/bin/shortcuts",
        "pmset": "/usr/bin/pmset",
        "mdfind": "/usr/bin/mdfind",
        "ls": "/bin/ls",
        "mv": "/bin/mv",
    ]

    nonisolated private static func canonicalArgv(_ argv: [String]) -> [String]? {
        guard let first = argv.first, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let exe = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        guard let canonical = allowedExecutablePaths[exe] else {
            return nil
        }
        if first.contains("/") {
            let supplied = URL(fileURLWithPath: first).standardizedFileURL.path
            guard supplied == canonical else {
                return nil
            }
        }
        var out = argv
        out[0] = canonical
        return out
    }

    nonisolated private static func validateExecArgv(_ argv: [String]) -> String? {
        guard let canonical = canonicalArgv(argv), let first = canonical.first else {
            let exe = argv.first.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() } ?? ""
            return exe.isEmpty ? "missing executable" : "executable_not_allowed: \(exe)"
        }
        let exe = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        if !bridgePolicyAllows(executable: exe, argv: argv) {
            return "mac_control_policy_denied: \(exe)"
        }
        if let reason = bridgeProtectedMutationReason(canonical: canonical, executable: exe) {
            return reason
        }
        if exe == "osascript" {
            // Scan the SCRIPT ARGS (canonical argv minus the executable element).
            // Normalize ALL whitespace runs to a single space and also build a fully
            // whitespace-stripped form, so `do shell script` can't be evaded with
            // tabs/newlines/comments (the previous code only de-spaced for the single
            // `doshellscript` recheck). We drop argv[0]: the canonical exe path ends in
            // "osascript", so including it would make the "osascript -e" marker self-match
            // EVERY legitimate top-level `osascript -e …` call and break non-full-mac
            // osascript control. A nested osascript call inside the script body is still
            // caught — it lives in the args we do scan. This is a soft gate — full-mac
            // access bypasses it — so over-blocking benign scripts that merely contain
            // these tokens is the safer failure direction.
            // fix-osascript-continuation: strip the AppleScript line-continuation
            // char "¬" (U+00AC) BEFORE scanning. Otherwise a script can split a
            // high-risk phrase across continued lines (e.g. `do shell ¬\n-e\nscript`)
            // so the marker reconstructs at runtime but slips past a whitespace-only
            // normalization. Removing it lets the existing whitespace-collapse /
            // compact forms re-join the pieces and catch the marker.
            let rawScript = canonical.dropFirst().joined(separator: "\n")
                .replacingOccurrences(of: "\u{00AC}", with: "")
                .lowercased()
            let script = rawScript
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let compactScript = script.replacingOccurrences(of: " ", with: "")
            if !bridgeFullMacAccessIsActive(currentTrustPolicy() ?? [:]) {
                let deniedMarkers = ["do shell script", "do script", "quoted form of", "open for access", "write ", "delete file", "rm ", "curl ", "python", "osascript -e"]
                // fix-osascript-file-bypass: in non-full-mac mode a file-path
                // invocation (e.g. `osascript /tmp/x.applescript`) carries no inline
                // `-e` source, so the dropFirst args-only scan above only sees the
                // PATH, never the dangerous script body — a total bypass. Resolve
                // the referenced script file(s): allow ONLY inline `-e` source, OR a
                // readable .applescript/.scptd-free TEXT file whose contents we scan
                // with the same markers. Deny opaque/compiled .scpt or unreadable
                // script files (fail closed).
                if let reason = Self.osascriptFileScanReason(canonical, deniedMarkers: deniedMarkers) {
                    return reason
                }
                // Apply each marker against both the whitespace-collapsed form and the
                // fully whitespace-stripped form so neither extra spacing nor removed
                // spacing can slip a marker past the scan.
                for marker in deniedMarkers {
                    // Always match the whitespace-collapsed form, which preserves word
                    // boundaries (single spaces) — so trailing-space tokens like "rm "
                    // keep their boundary and don't false-match "Terminal"/"confirm".
                    if script.contains(marker) {
                        return "osascript_high_risk_marker"
                    }
                    // Compact (all-whitespace-stripped) match ONLY for multi-word phrase
                    // markers, where whitespace can be injected between words to evade
                    // (e.g. "do\tshell\tscript" → "doshellscript"). Single-token markers
                    // have no internal space, so compact-matching them only loses their
                    // boundary and over-blocks benign substrings.
                    if marker.trimmingCharacters(in: .whitespaces).contains(" ") {
                        let compactMarker = marker.replacingOccurrences(of: " ", with: "")
                        if !compactMarker.isEmpty && compactScript.contains(compactMarker) {
                            return "osascript_high_risk_marker"
                        }
                    }
                }
            }
        }
        return nil
    }

    nonisolated private static func bridgeProtectedMutationReason(
        canonical: [String],
        executable exe: String
    ) -> String? {
        let args = Array(canonical.dropFirst())
        if exe == "mv" {
            let operands = args.filter { !$0.hasPrefix("-") }
            for operand in operands {
                if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: operand) {
                    return reason
                }
            }
        }
        if exe == "sh" || exe == "bash" || exe == "zsh" {
            let commandText = args.joined(separator: " ").lowercased()
            for prefix in MacControlSensitivePathFence.protectedSystemMutationPrefixes {
                let lowerPrefix = prefix.lowercased()
                if commandText.contains(lowerPrefix + "/") || commandText.contains(lowerPrefix + " ")
                    || commandText.hasSuffix(lowerPrefix) {
                    return "protected_system_path_denied: \(prefix)"
                }
            }
        }
        return nil
    }

    // fix-osascript-file-bypass: resolve the script source for a non-full-mac
    // osascript invocation and fail CLOSED on anything we cannot inspect as
    // inline text. `canonical` is the full validated argv (argv[0] = osascript
    // path). Returns a deny reason string, or nil if the call is safe to let
    // the inline marker scan handle (inline `-e` source, or a clean text file).
    nonisolated private static func osascriptFileScanReason(_ canonical: [String], deniedMarkers: [String]) -> String? {
        let args = Array(canonical.dropFirst())
        // Flags that consume the following token as their value.
        let valueFlags: Set<String> = ["-e", "-l", "-s"]
        var hasInlineSource = false
        var scriptFile: String? = nil
        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            if arg == "-e" {
                hasInlineSource = true
                idx += 2          // skip the statement value
                continue
            }
            if valueFlags.contains(arg) {
                idx += 2          // flag + its value
                continue
            }
            if arg.hasPrefix("-") {
                idx += 1          // valueless flag (e.g. -i, -ss)
                continue
            }
            // First bare (non-flag) token is the script file; trailing bare
            // tokens are arguments TO the script, not additional files.
            scriptFile = arg
            break
        }
        // Inline `-e` source is authoritative; the outer marker scan over the
        // args already covers it. No file to resolve.
        if hasInlineSource {
            return nil
        }
        guard let path = scriptFile else {
            // No inline source and no script file — nothing executable here
            // (flags only). Let the outer scan proceed; it is harmless.
            return nil
        }
        let lowerPath = path.lowercased()
        // Opaque/compiled script bundles can't be scanned as text — fail closed.
        if lowerPath.hasSuffix(".scpt") || lowerPath.hasSuffix(".scptd") {
            return "osascript_compiled_script_denied"
        }
        // Read the referenced script file as text and scan its CONTENTS with the
        // same marker set. Unreadable / non-UTF8 → fail closed.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else {
            return "osascript_script_unreadable"
        }
        let raw = text
            .replacingOccurrences(of: "\u{00AC}", with: "")
            .lowercased()
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let compact = collapsed.replacingOccurrences(of: " ", with: "")
        for marker in deniedMarkers {
            if collapsed.contains(marker) {
                return "osascript_high_risk_marker"
            }
            if marker.trimmingCharacters(in: .whitespaces).contains(" ") {
                let compactMarker = marker.replacingOccurrences(of: " ", with: "")
                if !compactMarker.isEmpty && compact.contains(compactMarker) {
                    return "osascript_high_risk_marker"
                }
            }
        }
        return nil
    }

    nonisolated private static func currentTrustPolicy() -> [String: Any]? {
        let policyURL = NativeAgentPaths.dataRoot
            .appendingPathComponent("trust")
            .appendingPathComponent("policy.json")
        guard let data = try? Data(contentsOf: policyURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    nonisolated private static func appendExecAudit(argv: [String], status: String, reason: String? = nil, operationId: String? = nil) {
        let url = NativeAgentPaths.dataRoot.appendingPathComponent("mac_control_bridge_audit.jsonl")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let event: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "argv0": argv.first ?? "",
            "argc": argv.count,
            "operationId": operationId ?? "",
            "status": status,
            "reason": reason ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        // fix-audit-append-race: serialize the open→seek→write so concurrent
        // writers can't seek to the same end offset and clobber each other.
        auditAppendLock.lock()
        defer { auditAppendLock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? line.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: Data(line.utf8))
        }
    }

    private func execHandler(conn: NWConnection, body: Data) {
        let json = body.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        guard let argv = json["argv"] as? [String], !argv.isEmpty else {
            writeJSON(conn, status: 400, obj: ["error": "missing_argv"])
            return
        }
        let operationId = (json["operationId"] as? String) ?? UUID().uuidString
        guard MacControlOperationStore.validOperationId(operationId) else {
            writeJSON(conn, status: 400, obj: ["error": "invalid_operation_id"])
            return
        }
        let protocolVersion = (json["protocolVersion"] as? Int) ?? 1
        let stdinStr = json["stdin"] as? String
        let rawTimeout = (json["timeout"] as? Double) ?? 30.0
        let timeout = min(max(rawTimeout.isFinite ? rawTimeout : 30.0, 1.0), 120.0)
        Task { [weak self] in
            guard let self else { return }
            do {
                let requestDigest = try MacControlOperationStore.requestDigest(
                    action: "bridge_exec",
                    body: [
                        "argv": .array(argv.map(JSONValue.string)),
                        "stdin": stdinStr.map(JSONValue.string) ?? .null,
                        "timeout": .double(timeout),
                    ]
                )
                let begin = try await Self.operationStore.begin(
                    operationId: operationId,
                    action: "bridge_exec",
                    requestDigest: requestDigest,
                    deadlineSeconds: Int(timeout.rounded(.up))
                )
                switch begin {
                case .replay(let record):
                    self.writeJSON(conn, status: 200, obj: [
                        "ok": record.state == .completed,
                        "status": "idempotent_replay",
                        "operationId": operationId,
                        "operationState": record.state.rawValue,
                        "verification": record.verification.rawValue,
                        "protocolVersion": protocolVersion,
                    ])
                    return
                case .duplicateActive(let record):
                    self.writeJSON(conn, status: 409, obj: [
                        "error": "duplicate_active_operation",
                        "operationId": operationId,
                        "operationState": record.state.rawValue,
                        "protocolVersion": protocolVersion,
                    ])
                    return
                case .accepted:
                    break
                }
                if let reason = Self.validateExecArgv(argv) {
                    _ = try await Self.operationStore.transition(
                        operationId: operationId,
                        to: .blocked,
                        verification: .notRequired,
                        expectedNextEvidence: nil,
                        outcomeCode: "bridge_policy_blocked"
                    )
                    Self.appendExecAudit(argv: argv, status: "blocked", reason: reason, operationId: operationId)
                    self.writeJSON(conn, status: 403, obj: [
                        "error": "exec_blocked",
                        "detail": reason,
                        "via": "macctl-bridge",
                        "protocolVersion": protocolVersion,
                        "operationId": operationId,
                        "operationState": MacControlOperationState.blocked.rawValue,
                    ])
                    return
                }
                // fix-exec-slot-leak (2026-08-02): the slot is a `ScopedSlot`
                // handle. Every exit from here — including a throw out of the
                // `.started` transition below — unwinds through `execSlot`,
                // whose deinit is the ONLY release path. Previously the only
                // release was the background block's `defer`; a throwing
                // transition (flock contention, disk full) unwound to the outer
                // catch without ever entering that block, permanently burning a
                // slot. Two of them pinned the active count at execLimit forever
                // — every /macctl/exec returned 429 and emergency_stop
                // deliberately refuses to zero the count, so only an app restart
                // recovered it.
                guard let execSlot = Self.execSlots.acquire() else {
                    _ = try await Self.operationStore.transition(
                        operationId: operationId,
                        to: .blocked,
                        verification: .notRequired,
                        expectedNextEvidence: nil,
                        outcomeCode: "exec_queue_saturated"
                    )
                    Self.appendExecAudit(argv: argv, status: "blocked", reason: "exec_queue_saturated", operationId: operationId)
                    self.writeJSON(conn, status: 429, obj: [
                        "error": "exec_queue_saturated",
                        "detail": "Too many Mac Control exec jobs are already running.",
                        "active": Self.currentExecCount(),
                        "limit": Self.execLimit,
                        "protocolVersion": protocolVersion,
                        "operationId": operationId,
                        "operationState": MacControlOperationState.blocked.rawValue,
                    ])
                    return
                }
                do {
                    _ = try await Self.operationStore.transition(
                        operationId: operationId,
                        to: .started,
                        verification: .pending,
                        expectedNextEvidence: "Process exit and bounded output"
                    )

                    // Process.waitUntilExit is intentionally kept off Swift's
                    // cooperative executor. The completion returns to a Task only
                    // after the child and process group are gone.
                    // `[execSlot]`: capturing the handle IS the ownership
                    // transfer — the slot stays held until this block's context
                    // is torn down, i.e. after the child and its process group
                    // are gone. No `defer` to forget.
                    DispatchQueue.global(qos: .userInitiated).async { [weak self, execSlot] in
                        // Holding the handle IS the release contract: it dies
                        // with this block's context, exactly once.
                        defer { withExtendedLifetime(execSlot) {} }
                        let resultBox = ExecResultBox(Self.runProcess(
                            argv: argv,
                            stdin: stdinStr,
                            timeout: timeout,
                            operationId: operationId
                        ))
                        let result = resultBox.value
                        let cancellation = Self.consumeCancellation(operationId: operationId)
                        let timedOut = result["timed_out"] as? Bool ?? false
                        let exit = result["exit"] as? Int ?? -1
                        // A request racing with natural exit is not an
                        // acknowledgement, and a real exit-0 remains completed
                        // even if a cancellation signal was attempted too late to
                        // prevent the successful terminal result.
                        let terminal = Self.execTerminalState(
                            exit: exit,
                            timedOut: timedOut,
                            cancellationSignalled: cancellation.signalled
                        )
                        let cancellationAcknowledged = terminal == .cancelAcknowledged
                        let verification: MotorVerificationState = terminal == .completed ? .unverified : .failed
                        Task { [weak self] in
                            guard let self else { return }
                            do {
                                let record = try await Self.operationStore.transition(
                                    operationId: operationId,
                                    to: terminal,
                                    verification: verification,
                                    expectedNextEvidence: terminal == .completed ? "Separate observation of intended effect" : nil,
                                    outcomeCode: cancellationAcknowledged
                                        ? "cancelled_after_process_exit"
                                        : (timedOut ? "timeout" : "exit_\(exit)")
                                )
                                resultBox.value["protocolVersion"] = protocolVersion
                                resultBox.value["operationId"] = operationId
                                resultBox.value["operationState"] = record.state.rawValue
                                resultBox.value["verification"] = record.verification.rawValue
                                resultBox.value["cancelAcknowledged"] = record.state == .cancelAcknowledged
                                Self.appendExecAudit(
                                    argv: argv,
                                    status: record.state.rawValue,
                                    reason: "exit_\(exit)",
                                    operationId: operationId
                                )
                                self.writeJSON(conn, status: 200, obj: resultBox.value)
                            } catch {
                                self.writeJSON(conn, status: 500, obj: [
                                    "error": "terminal_transition_failed",
                                    "detail": error.localizedDescription,
                                    "operationId": operationId,
                                ])
                            }
                        }
                    }
                    // The background block owns the release from here on: it
                    // captured the handle, so the slot is freed exactly once,
                    // after the child process and its process group are gone.
                }
            } catch {
                self.writeJSON(conn, status: 409, obj: [
                    "error": "operation_transition_failed",
                    "detail": error.localizedDescription,
                    "operationId": operationId,
                ])
            }
        }
    }

    // PATCH-2026-05-07: mac-control-bridge Process spawn UNDER the SwiftUI app
    // process (NativeAgent.app), so any TCC requests the child triggers
    // (osascript controlling another app, Accessibility, Full Disk Access)
    // are attributed to NativeAgent's responsible-app bundle ID.
    nonisolated private static func runProcess(
        argv: [String],
        stdin stdinStr: String?,
        timeout: Double,
        operationId: String
    ) -> [String: Any] {
        let t0 = Date()
        guard let argv = canonicalArgv(argv) else {
            return [
                "exit": 127,
                "stdout": "",
                "stderr": "executable_not_allowed",
                "duration_ms": Int(Date().timeIntervalSince(t0) * 1000),
                "via": "macctl-bridge",
            ]
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: argv[0])
        proc.arguments = Array(argv.dropFirst())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        if stdinStr != nil {
            proc.standardInput = Pipe()
        }

        do {
            try proc.run()
            setpgid(proc.processIdentifier, proc.processIdentifier)
            registerProcess(proc, operationId: operationId)
            if cancellationWasRequested(operationId: operationId) {
                _ = requestCancellation(operationId: operationId)
            }
        } catch {
            return [
                "exit": 127,
                "stdout": "",
                "stderr": "spawn_failed: \(error.localizedDescription)",
                "duration_ms": Int(Date().timeIntervalSince(t0) * 1000),
                "via": "macctl-bridge",
            ]
        }
        defer { unregisterProcess(operationId: operationId) }

        // Drop our copy of the stdin read end now that the child owns its own:
        // without this a stalled write below could never fail with EPIPE, even
        // after the child exits, because the parent still held the pipe open.
        // Safe because NativeAgentApp.init installs SIGPIPE=SIG_IGN before any
        // spawn, so the doomed write throws instead of killing the app.
        if let pipe = proc.standardInput as? Pipe {
            try? pipe.fileHandleForReading.close()
        }

        // Timeout watchdog. TimeoutFlag is a class so the watchdog block can
        // safely mutate it across thread boundaries without tripping Swift's
        // sendable-closure-capture warning.
        final class TimeoutFlag: @unchecked Sendable {
            let lock = NSLock()
            private var _fired = false
            var fired: Bool { lock.lock(); defer { lock.unlock() }; return _fired }
            func fire() { lock.lock(); _fired = true; lock.unlock() }
        }
        let timeoutFlag = TimeoutFlag()
        let deadline = DispatchTime.now() + .milliseconds(Int(timeout * 1000))
        DispatchQueue.global().asyncAfter(deadline: deadline) { [weak proc] in
            guard let proc, proc.isRunning else { return }
            timeoutFlag.fire()
            if killpg(proc.processIdentifier, SIGTERM) != 0 {
                proc.terminate()
            }
            // Hard kill after 2s grace
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak proc] in
                guard let proc, proc.isRunning else { return }
                if killpg(proc.processIdentifier, SIGKILL) != 0 {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }

        // Drain pipes concurrently BEFORE calling waitUntilExit to prevent
        // deadlock when a subprocess emits more than the pipe buffer (~64 KB).
        // Use a class box so Swift's Sendable checker doesn't flag mutation of
        // captured vars across concurrently-executing closures.
        final class DataBox: @unchecked Sendable {
            var value = Data()
            var truncated = false
        }
        let outBox = DataBox()
        let errBox = DataBox()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global().async {
            let capped = Self.readCapped(stdoutPipe.fileHandleForReading, maxBytes: Self.execOutputLimitBytes)
            outBox.value = capped.data
            outBox.truncated = capped.truncated
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global().async {
            let capped = Self.readCapped(stderrPipe.fileHandleForReading, maxBytes: Self.execOutputLimitBytes)
            errBox.value = capped.data
            errBox.truncated = capped.truncated
            drainGroup.leave()
        }

        // fix-stdin-wedge: write stdin on its own queue, and only once the
        // drains above are enqueued. A stdin payload larger than the ~64 KB
        // pipe buffer blocks the writer until the child reads it — and the
        // child may itself be blocked writing stdout. Writing synchronously
        // here deadlocked both sides until the watchdog killed the process.
        let stdinGroup = DispatchGroup()
        if let stdinStr, let pipe = proc.standardInput as? Pipe {
            stdinGroup.enter()
            DispatchQueue.global().async {
                let handle = pipe.fileHandleForWriting
                if let data = stdinStr.data(using: .utf8) {
                    try? handle.write(contentsOf: data)
                }
                try? handle.close()
                stdinGroup.leave()
            }
        }

        proc.waitUntilExit()
        drainGroup.wait()
        // The child is gone, so a blocked write has taken EPIPE by now. Bounded
        // anyway: a stuck writer must never outlive the request it belongs to.
        _ = stdinGroup.wait(timeout: .now() + 5)
        let outData = outBox.value
        let errData = errBox.value
        // Use String(decoding:as:) so non-UTF8 bytes become replacement chars (U+FFFD)
        // rather than being silently dropped by String(data:encoding:)'s nil return.
        let stdoutRaw = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)
        let durationMs = Int(Date().timeIntervalSince(t0) * 1000)

        let isTimeout = timeoutFlag.fired
        let exitCode = isTimeout ? 124 : Int(proc.terminationStatus)

        // Detect binary output: if >10% of bytes are non-printable (excluding tab/LF/CR),
        // replace with a placeholder so raw binary is never surfaced as text.
        let nonPrintableCount = outData.filter { $0 < 0x20 && $0 != 0x09 && $0 != 0x0a && $0 != 0x0d }.count
        let isBinary = !outData.isEmpty && nonPrintableCount * 10 > outData.count
        let stdout: Any = isBinary
            ? "<\(outData.count) bytes of non-text output>"
            : stdoutRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputKind: String = isBinary ? "binary_data" : "text"

        return [
            "exit": exitCode,
            "stdout": stdout,
            "stderr": isTimeout ? (stderr + "\ntimed_out_after_\(timeout)s") : stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            "duration_ms": durationMs,
            "via": "macctl-bridge",
            "timed_out": isTimeout,
            "output_kind": outputKind,
            "stdout_truncated": outBox.truncated,
            "stderr_truncated": errBox.truncated,
        ]
    }

    nonisolated private static func readCapped(_ handle: FileHandle, maxBytes: Int) -> (data: Data, truncated: Bool) {
        var collected = Data()
        var truncated = false
        while true {
            guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            let remaining = max(0, maxBytes - collected.count)
            if remaining > 0 {
                collected.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                truncated = true
            }
        }
        return (collected, truncated)
    }

    // MARK: - HTTP response

    fileprivate func writeJSON(_ conn: NWConnection, status: Int, obj: [String: Any]) {
        BridgeCore.writeJSON(conn, status: status, obj: obj)
    }
}

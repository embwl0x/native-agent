// PATCH-2026-05-07: mac-control-bridge In-app HTTP server that runs Mac Control
// subprocess calls (osascript, shortcuts, pmset, …) under the NativeAgent bundle
// identity so macOS attributes TCC requests (Automation, Accessibility, Full Disk
// Access, etc.) to NativeAgent.app, not to a retired external runtime.
//
// Wire-up: AppDelegate.applicationDidFinishLaunching starts the listener,
// on this install's fixed port (8770; a taken port fails loudly), with a random shared-secret token written to
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

    private let bridgeListener = NativeLoopbackListener(
        port: MacControlBridge.port,
        label: "MacControlBridge"
    )
    /// Doctor's "Local bridges" row: which port this bridge got, or why it has none.
    var listenerHealth: NativeLoopbackListener.Health { bridgeListener.health }
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

    static let port = InstallPaths.current.loopbackPorts().macControl
    private static let maxRequestBodyBytes = 2 * 1024 * 1024
    private let runtime = MacControlBridgeRuntime(
        dataRoot: NativeAgentPaths.dataRoot,
        processes: MacControlBridgeProcesses()
    )

    static func startGateAllows() -> Bool { shared.runtime.startGateAllows() }

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
                try await runtime.recoverInterruptedOperations()
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
        _ = runtime.stopAllProcesses(reason: "bridge_stop")
    }

    private func accept(_ conn: NWConnection) {
        guard BridgeCore.endpointIsLoopback(conn.endpoint) else {
            runtime.appendExecAudit(argv: ["remote_connection"], status: "blocked", reason: "non_loopback_peer")
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
        if MacControlBridgeRuntime.requiresAuthorization(path: path) {
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

        runtime.route(
            method: method, path: path, body: body,
            bundleId: Bundle.main.bundleIdentifier ?? "", activePort: { self.activePort },
            buildPayload: { NativeAgentBuildIdentity.current.bridgePayload }
        ) { [weak self] status, object in
            self?.writeJSON(conn, status: status, obj: object)
        }
    }

    // MARK: - HTTP response

    fileprivate func writeJSON(_ conn: NWConnection, status: Int, obj: [String: Any]) {
        BridgeCore.writeJSON(conn, status: status, obj: obj)
    }
}

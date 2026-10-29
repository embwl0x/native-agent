import Foundation
import NativeAgentCore
import Network
import PersistenceCore
import Security
import NativeAgentShared
// Blueprint: | `BrowserIPCServer.swift` | browser IPC routing with NativeLoopbackListener and BridgeCore HTTP parsing/writing; invalid response objects close the connection; browser_ipc.json alone publishes endpoint/token discovery and Doctor readiness events, with backup/export/phone exclusions and privacy coverage; no duplicate token file writer; connection retirement cancels its routed task; deadlines report unknown effect outcome |

@MainActor
public final class BrowserIPCServer: BridgeHTTPServer {
    public init(dataRoot: URL, transport: NativeLoopbackListener, effects: any BrowserIPCWindowEffects) {
        self.dataRoot = dataRoot
        self.transport = transport
        self.effects = effects
    }

    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTimeouts: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var connectionOperations: [ObjectIdentifier: Task<Void, Never>] = [:]
    public private(set) var ipcToken: String = ""
    public private(set) var ipcPort: UInt16 = 0
    private let dataRoot: URL
    private nonisolated let transport: NativeLoopbackListener
    private let effects: any BrowserIPCWindowEffects

    /// Drop a connection that hasn't completed its request/response within this window
    /// so stalled/half-open peers can't accumulate in `connections` indefinitely.
    private static let ipcIdleTimeout: Duration = .seconds(15)

    // The descriptor owns endpoint and token discovery for external clients.
    // Credential-filtered from all backups/archives; no phone copy; PrivacyMap: browser_ipc.
    private var descriptorFileURL: URL {
        dataRoot.appendingPathComponent("browser_ipc.json")
    }

    private func writeDiscovery(token: String, port: UInt16) {
        try? FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "host": "127.0.0.1",
            "port": Int(port),
            "url": "http://127.0.0.1:\(port)",
            "token": token,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            _ = NativePrivateFile.write(data, to: descriptorFileURL)
        }
    }

    private func removeDiscoveryFile() {
        try? FileManager.default.removeItem(at: descriptorFileURL)
    }

    // MARK: - IPC server

    public func start() {
        guard !transport.isActive, ipcToken.isEmpty else { return }

        guard let token = BridgeCore.generateToken() else {
            nativeLog("NativeAgent browser IPC failed to generate a secure token")
            return
        }
        ipcToken = token
        ipcPort = 0
        removeDiscoveryFile()
        let started = transport.start(
            onReady: { [weak self] port in
                Task { @MainActor in self?.handleIPCListenerReady(token: token, port: port) }
            },
            onConnection: { [weak self] connection in
                Task { @MainActor in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    self.acceptIPC(connection, token: token)
                }
            },
            onTerminated: { [weak self] in
                Task { @MainActor in self?.handleIPCListenerTerminated(token: token) }
            }
        )
        if !started { handleIPCListenerTerminated(token: token) }
    }

    private func handleIPCListenerReady(token: String, port: UInt16) {
        guard ipcToken == token else { return }
        ipcPort = port
        writeDiscovery(token: token, port: port)
        print("[BrowserIPC] listening on 127.0.0.1:\(port)")
    }

    private func handleIPCListenerTerminated(token: String) {
        guard ipcToken == token else { return }
        ipcToken = ""
        ipcPort = 0
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        for timeout in connectionTimeouts.values { timeout.cancel() }
        connectionTimeouts.removeAll()
        for operation in connectionOperations.values { operation.cancel() }
        connectionOperations.removeAll()
        removeDiscoveryFile()
    }

    public func stop() {
        handleIPCListenerTerminated(token: ipcToken)
        transport.stop()
    }

    private func acceptIPC(_ conn: NWConnection, token: String) {
        guard transport.isActive, ipcToken == token, !ipcToken.isEmpty, ipcPort != 0 else {
            conn.cancel()
            return
        }
        guard BridgeCore.endpointIsLoopback(conn.endpoint) else {
            conn.cancel()
            return
        }
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { Task { @MainActor in self?.dropIPCConnection(key) } }
            if case .failed = state    { Task { @MainActor in self?.dropIPCConnection(key) } }
        }
        conn.start(queue: .global(qos: .userInitiated))
        // Idle/read timeout: a peer that connects but never completes a request would
        // otherwise sit in `connections` forever. Cancel it after the timeout; the
        // connection's .cancelled handler then evicts it from the dict.
        connectionTimeouts[key] = Task { [weak self, weak conn] in
            try? await Task.sleep(for: Self.ipcIdleTimeout)
            guard !Task.isCancelled else { return }
            conn?.cancel()
            _ = self
        }
        BridgeCore.readRequest(conn, buffered: Data(), maxBodyBytes: 2 * 1024 * 1024, server: self)
    }

    /// Retiring the connection also retires its deadline and exact routed task.
    private func dropIPCConnection(_ key: ObjectIdentifier) {
        connections.removeValue(forKey: key)
        connectionTimeouts.removeValue(forKey: key)?.cancel()
        connectionOperations.removeValue(forKey: key)?.cancel()
    }

    // MARK: - Routing

    public nonisolated func route(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        Task { @MainActor in
            self.routeIPC(conn: conn, method: method, path: path, headers: headers, body: body)
        }
    }

    private func routeIPC(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        let timeoutKey = ObjectIdentifier(conn)
        guard connections[timeoutKey] === conn, connectionOperations[timeoutKey] == nil else { return }
        // Request fully read & routed — swap the 15s idle/read deadline for a
        // generous routed-OPERATION deadline. The 15s would kill a legitimate slow
        // navigate mid-flight; removing the timeout entirely would leak a connection
        // wedged on a hung WebKit callback. Re-arm to 120s: long enough for any real
        // browser op, short enough to reap a wedge. Retiring a connection cancels
        // its operation too; a deadline cannot prove a dispatched effect stopped.
        connectionTimeouts[timeoutKey]?.cancel()
        connectionTimeouts[timeoutKey] = Task { [weak self, weak conn] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            guard let self, let conn, self.connections[timeoutKey] === conn else { return }
            self.connectionOperations.removeValue(forKey: timeoutKey)?.cancel()
            // Keep the socket owned while the unknown-outcome response drains.
            // A peer that does not read still loses the socket at the idle limit.
            self.connectionTimeouts[timeoutKey] = Task { [weak conn] in
                do { try await Task.sleep(for: Self.ipcIdleTimeout) } catch { return }
                conn?.cancel()
            }
            BridgeCore.writeJSON(conn, status: 500, obj: [
                "error": "outcome_unknown",
                "detail": "Browser operation exceeded its deadline; its outcome is unknown."
            ])
        }
        let token = ipcToken
        connectionOperations[timeoutKey] = Task {
            let response = await BrowserActionRoutes.authenticatedIPCRoute(
                method: method, path: path, headers: headers, body: body,
                token: token, effects: effects
            )
            guard !Task.isCancelled, self.connections[timeoutKey] === conn else { return }
            self.connectionOperations.removeValue(forKey: timeoutKey)
            guard JSONSerialization.isValidJSONObject(response.object) else { conn.cancel(); return }
            BridgeCore.writeJSON(conn, status: response.status, obj: response.object)
        }
    }
}

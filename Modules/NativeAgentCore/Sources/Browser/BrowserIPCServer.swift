import Foundation
import NativeAgentCore
import Network
import PersistenceCore
import Security

/// The app binds its shared loopback listener and HTTP head parser.
public protocol BrowserIPCTransport: Sendable {
    var isActive: Bool { get }
    var headerByteCap: Int { get }
    func start(onReady: @escaping @Sendable (UInt16) -> Void,
               onConnection: @escaping @Sendable (NWConnection) -> Void,
               onTerminated: @escaping @Sendable () -> Void) -> Bool
    func stop()
    func parseRequestHead(_ data: Data) -> (method: String, path: String, headers: [String: String])?
    func parseContentLength(_ headers: [String: String], maxBytes: Int) -> Int?
}

@MainActor
public final class BrowserIPCServer {
    public init(dataRoot: URL, transport: any BrowserIPCTransport, effects: any BrowserIPCWindowEffects) {
        self.dataRoot = dataRoot
        self.transport = transport
        self.effects = effects
    }

    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTimeouts: [ObjectIdentifier: Task<Void, Never>] = [:]
    public private(set) var ipcToken: String = ""
    public private(set) var ipcPort: UInt16 = 0
    private let dataRoot: URL
    private nonisolated let transport: any BrowserIPCTransport
    private let effects: any BrowserIPCWindowEffects

    /// Drop a connection that hasn't completed its request/response within this window
    /// so stalled/half-open peers can't accumulate in `connections` indefinitely.
    private static let ipcIdleTimeout: Duration = .seconds(15)

    // MARK: - App support dir + token

    // Phase 11c: use the shared resolver so browser_ipc_token goes to
    // <repo>/data/ rather than ~/Library/Application Support/NativeAgent/.
    private var appSupportDir: URL { dataRoot }

    private var tokenFileURL: URL {
        appSupportDir.appendingPathComponent("browser_ipc_token")
    }

    private var descriptorFileURL: URL {
        appSupportDir.appendingPathComponent("browser_ipc.json")
    }

    private func writeDiscovery(token: String, port: UInt16) {
        let dir = appSupportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        _ = NativePrivateFile.write(Data(token.utf8), to: tokenFileURL)
    }

    private func removeDiscoveryFiles() {
        try? FileManager.default.removeItem(at: tokenFileURL)
        try? FileManager.default.removeItem(at: descriptorFileURL)
    }

    // MARK: - IPC server

    private static func endpointIsLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return true }
        let value = "\(host)".lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return value == "localhost"
            || value == "127.0.0.1"
            || value == "::1"
            || value.hasPrefix("::1%")
    }

    public func start() {
        guard !transport.isActive, ipcToken.isEmpty else { return }

        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            nativeLog("NativeAgent browser IPC failed to generate a secure token")
            return
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        ipcToken = token
        ipcPort = 0
        removeDiscoveryFiles()
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
                    self.acceptIPC(connection)
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
        removeDiscoveryFiles()
    }

    public func stop() {
        transport.stop()
        ipcToken = ""
        ipcPort = 0
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        for timeout in connectionTimeouts.values { timeout.cancel() }
        connectionTimeouts.removeAll()
        removeDiscoveryFiles()
    }

    private func acceptIPC(_ conn: NWConnection) {
        guard transport.isActive, !ipcToken.isEmpty, ipcPort != 0 else {
            conn.cancel()
            return
        }
        guard Self.endpointIsLoopback(conn.endpoint) else {
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
        Self.readIPCRequest(conn, buffered: Data(), server: self)
    }

    /// Evict a connection and tear down its idle-timeout Task. Safe to call multiple times.
    private func dropIPCConnection(_ key: ObjectIdentifier) {
        connections.removeValue(forKey: key)
        connectionTimeouts.removeValue(forKey: key)?.cancel()
    }

    // MARK: - HTTP parsing (nonisolated)

    nonisolated private static func readIPCRequest(_ conn: NWConnection, buffered: Data, server: BrowserIPCServer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak server] data, _, isComplete, error in
            guard let server else { return }
            if error != nil { conn.cancel(); return }
            var buf = buffered
            if let d = data { buf.append(d) }

            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || buf.count > server.transport.headerByteCap { conn.cancel() }
                else { Self.readIPCRequest(conn, buffered: buf, server: server) }
                return
            }
            guard headerEnd.lowerBound <= server.transport.headerByteCap else { conn.cancel(); return }

            let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
            guard let (method, path, headers) = server.transport.parseRequestHead(headerData) else { conn.cancel(); return }

            guard let contentLength = server.transport.parseContentLength(headers, maxBytes: 2 * 1024 * 1024) else {
                Self.writeRawJSON(conn, status: 413, obj: ["error": "invalid_content_length"])
                return
            }
            let bodyStart = headerEnd.upperBound
            let bodyAlready = buf.subdata(in: bodyStart..<buf.count)

            if bodyAlready.count >= contentLength {
                let body = Data(bodyAlready.prefix(contentLength))
                Task { @MainActor in
                    server.routeIPC(conn: conn, method: method, path: path, headers: headers, body: body)
                }
            } else {
                guard !isComplete else { conn.cancel(); return }
                Self.readIPCBody(conn, have: bodyAlready, need: contentLength, method: method, path: path, headers: headers, server: server)
            }
        }
    }

    nonisolated private static func readIPCBody(_ conn: NWConnection, have: Data, need: Int, method: String, path: String, headers: [String: String], server: BrowserIPCServer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: max(1, need - have.count)) { [weak server] data, _, isComplete, error in
            guard let server else { return }
            guard error == nil else { conn.cancel(); return }
            var acc = have
            if let d = data { acc.append(d) }
            if acc.count >= need {
                let body = Data(acc.prefix(need))
                Task { @MainActor in
                    server.routeIPC(conn: conn, method: method, path: path, headers: headers, body: body)
                }
            } else {
                guard !isComplete else { conn.cancel(); return }
                Self.readIPCBody(conn, have: acc, need: need, method: method, path: path, headers: headers, server: server)
            }
        }
    }

    // MARK: - Routing

    private func routeIPC(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        // Request fully read & routed — swap the 15s idle/read deadline for a
        // generous routed-OPERATION deadline. The 15s would kill a legitimate slow
        // navigate mid-flight; removing the timeout entirely would leak a connection
        // wedged on a hung WebKit callback. Re-arm to 120s: long enough for any real
        // browser op, short enough to reap a wedge. dropIPCConnection cancels it when
        // the connection ends.
        let timeoutKey = ObjectIdentifier(conn)
        connectionTimeouts[timeoutKey]?.cancel()
        connectionTimeouts[timeoutKey] = Task { [weak self, weak conn] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            conn?.cancel()
            _ = self
        }
        let token = ipcToken
        Task {
            let response = await BrowserActionRoutes.authenticatedIPCRoute(
                method: method, path: path, headers: headers, body: body,
                token: token, effects: effects
            )
            self.writeIPCJSON(conn, status: response.status, obj: response.object)
        }
    }

    // MARK: - HTTP response helpers

    private func writeIPCJSON(_ conn: NWConnection, status: Int, obj: [String: Any]) {
        Self.writeRawJSON(conn, status: status, obj: obj)
    }

    nonisolated private static func writeRawJSON(_ conn: NWConnection, status: Int, obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { conn.cancel(); return }
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 413: statusText = "Payload Too Large"
        default:  statusText = "Internal Server Error"
        }
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var resp = Data(header.utf8)
        resp.append(data)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }
}

extension NativeLoopbackListener: BrowserIPCTransport {
    public var headerByteCap: Int { BridgeCore.headerByteCap }
    public func parseRequestHead(_ data: Data) -> (method: String, path: String, headers: [String: String])? {
        BridgeCore.parseRequestHead(data)
    }
    public func parseContentLength(_ headers: [String: String], maxBytes: Int) -> Int? {
        BridgeCore.parseContentLength(headers, maxBytes: maxBytes)
    }
}

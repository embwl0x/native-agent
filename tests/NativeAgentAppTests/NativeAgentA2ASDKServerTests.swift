import Foundation
import Network
import Testing
import ChatOrchestration
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
@testable import NativeAgentApp

/// SDK client -> real authenticated contact route -> in-process task owner.
/// Only the turn producer and credential reader are synthetic.
private final class SDKContactServer: BridgeHTTPServer, @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("a2a-sdk-server-\(UUID())")
    let bridge = ClaudeBridge()
    let listener: NWListener
    let tasks: AgentContactTasks
    let token = UUID().uuidString
    let otherToken = UUID().uuidString
    let peerID: String
    let otherID: String
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private let grpcTransport = HTTP2ServerTransport.TransportServices(
        address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
    private var grpcWorker: Task<Void, Error>?
    private var grpcServer: GRPCServer<HTTP2ServerTransport.TransportServices>?
    private var grpcPort: UInt16?

    init() throws {
        var peer = AgentPeerContact(name: "SDK fixture", endpoint: URL(string: "http://127.0.0.1:1234")!, transport: .a2a)
        peer.credentialKey = AgentPeerContact.credentialKey(for: peer.id)
        peerID = peer.id
        try AgentPeerStore(dataRoot: root).upsert(peer)
        var other = AgentPeerContact(name: "Other fixture", endpoint: URL(string: "http://127.0.0.1:1235")!, transport: .a2a)
        other.credentialKey = AgentPeerContact.credentialKey(for: other.id)
        otherID = other.id
        try AgentPeerStore(dataRoot: root).upsert(other)
        tasks = AgentContactTasks(dataRoot: root) { turn, emit in
            await emit(.working)
            let text = turn.parts.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined()
            if text.contains("cancel") { try await Task.sleep(for: .seconds(45)) }
            await emit(.text("SDK "))
            try await Task.sleep(for: .milliseconds(50))
            await emit(.text("reply"))
            return .init(state: .completed, parts: [.text("SDK reply")] + turn.parts.filter(\.isAttachment))
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: .global())
            BridgeCore.readRequest(connection, buffered: Data(), maxBodyBytes: 4 * 1024 * 1024, server: self)
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state { case .ready: c.resume(); case .failed(let e): c.resume(throwing: e); default: break }
            }
            listener.start(queue: .global())
        }
        let service = NativeAgentA2AGRPCService(endpoint: { [self] in
            AgentContactA2AEndpoint(tasks: tasks, port: listener.port!.rawValue, grpcPort: lock.withLock { grpcPort })
        }, authenticate: { [self] metadata in
            try NativeAgentA2AGRPCService.authenticate(metadata: metadata, liveToken: "temporary-bridge-key", dataRoot: root,
                readCredential: { id in id == peerID ? token : (id == otherID ? otherToken : nil) })
        })
        let grpcServer = GRPCServer(transport: grpcTransport, services: [service])
        self.grpcServer = grpcServer
        grpcWorker = Task { try await grpcServer.serve() }
        let address = try await grpcTransport.listeningAddress
        lock.withLock { grpcPort = UInt16(address.ipv4!.port) }
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
    }

    func route(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        _ = bridge.routeAgentContact(conn: conn, method: method, path: path, headers: headers, body: body,
            dataRoot: root, liveToken: "temporary-bridge-key",
            readCredential: { [self] id in id == peerID ? token : (id == otherID ? otherToken : nil) },
            tasks: tasks, advertisedPort: listener.port!.rawValue, advertisedGRPCPort: lock.withLock { grpcPort })
    }

    func stop() {
        listener.cancel()
        grpcServer?.beginGracefulShutdown()
        lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
        try? FileManager.default.removeItem(at: root)
    }

    func verifyShutdown() async throws {
        stop()
        try await grpcWorker?.value
        do {
            _ = try await grpcTransport.listeningAddress
            Issue.record("gRPC transport still advertises a listening address after shutdown")
        } catch { /* Closed transports must no longer expose a bound address. */ }
    }
}

@Suite(.timeLimit(.minutes(2))) struct NativeAgentA2ASDKServerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NATIVEAGENT_A2A_SDK_PYTHON"] != nil))
    func officialSDKCallsAllBindingsExtendedCardAndPush() async throws {
        let server = try SDKContactServer()
        defer { server.stop() }
        let base = try await server.start()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NATIVEAGENT_A2A_SDK_PYTHON"]))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.arguments = [repo.appendingPathComponent("tests/a2a_sdk/server_client.py").path]
        var env = ProcessInfo.processInfo.environment
        env["A2A_BASE_URL"] = base.absoluteString
        env["A2A_BEARER_TOKEN"] = server.token
        env["A2A_OTHER_TOKEN"] = server.otherToken
        process.environment = env
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        #expect(process.terminationStatus == 0)
        try await server.verifyShutdown()
    }
}

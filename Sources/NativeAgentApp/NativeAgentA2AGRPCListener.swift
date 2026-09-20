import Foundation
import ChatOrchestration
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import NativeAgentCore

/// The third A2A wire listener. All task ownership and execution stays in AgentContactRuntime.
final class NativeAgentA2AGRPCListener: @unchecked Sendable {
    static let shared = NativeAgentA2AGRPCListener()
    private let lock = NSLock()
    private var worker: Task<Void, Never>?
    private var generation: UUID?
    private var boundPort: UInt16?
    private var server: GRPCServer<HTTP2ServerTransport.TransportServices>?
    var port: UInt16? { lock.withLock { boundPort } }

    private var descriptorURL: URL {
        AgentHostDirectory.bridgeDiscoveryDirectory(dataRoot: NativeAgentPaths.dataRoot)
            .appendingPathComponent("a2a-grpc.json")
    }

    func start() {
        lock.withLock {
            guard worker == nil else { return }
            let id = UUID()
            generation = id
            worker = Task { [self] in
                defer { finished(id) }
                let transport = HTTP2ServerTransport.TransportServices(
                    address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
                let service = NativeAgentA2AGRPCService(endpoint: {
                    AgentContactA2AEndpoint(tasks: AgentContactRuntime.tasks,
                        port: ClaudeBridge.shared.activePort, grpcPort: self.port)
                }, authenticate: { metadata in
                    try NativeAgentA2AGRPCService.authenticate(metadata: metadata,
                        liveToken: ClaudeBridge.shared.token, dataRoot: NativeAgentPaths.dataRoot)
                })
                let server = GRPCServer(transport: transport, services: [service])
                let shouldServe = lock.withLock {
                    guard generation == id else { return false }
                    self.server = server
                    return true
                }
                guard shouldServe else { return }
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await server.serve() }
                        group.addTask {
                            let address = try await transport.listeningAddress
                            guard let number = address.ipv4?.port, let port = UInt16(exactly: number) else {
                                throw RPCError(code: .internalError, message: "gRPC did not bind a loopback port")
                            }
                            try self.publish(port: port, generation: id)
                        }
                        try await group.waitForAll()
                    }
                } catch {
                    if !Task.isCancelled { NSLog("[A2A gRPC] listener ended: %@", String(describing: error)) }
                }
            }
        }
    }

    func stop() {
        lock.withLock {
            generation = nil
            if let server { server.beginGracefulShutdown() }
            else { worker?.cancel() }
            server = nil
            worker = nil
            boundPort = nil
            try? FileManager.default.removeItem(at: descriptorURL)
        }
    }

    private func publish(port: UInt16, generation id: UUID) throws {
        try lock.withLock {
            guard generation == id, !Task.isCancelled else { throw CancellationError() }
            let directory = descriptorURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "host": "127.0.0.1",
                "port": Int(port), "url": "http://127.0.0.1:\(port)", "protocolVersion": "1.0", "protocolBinding": "GRPC"])
            try bytes.write(to: descriptorURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptorURL.path)
            boundPort = port
        }
    }

    private func finished(_ id: UUID) {
        lock.withLock {
            guard generation == id else { return }
            boundPort = nil
            generation = nil
            worker = nil
            server = nil
            try? FileManager.default.removeItem(at: descriptorURL)
        }
    }
}

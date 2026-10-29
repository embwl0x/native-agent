import Foundation
import AgentConversations
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `NativeAgentA2AGRPCListener.swift` | gRPC loopback listener generation and endpoint publication; stop closes publication and retains the serving worker through graceful drain, excluding restart until actual exit |

/// The third A2A wire listener. All task ownership and execution stays in AgentContactTasks.
public final class NativeAgentA2AGRPCListener: @unchecked Sendable {
    private let dataRoot: @Sendable () -> URL
    private let endpoint: @Sendable (UInt16?) -> AgentContactA2AEndpoint
    private let liveToken: @Sendable () -> String

    public init(dataRoot: @escaping @Sendable () -> URL,
                endpoint: @escaping @Sendable (UInt16?) -> AgentContactA2AEndpoint,
                liveToken: @escaping @Sendable () -> String) {
        self.dataRoot = dataRoot
        self.endpoint = endpoint
        self.liveToken = liveToken
    }
    private let lock = NSLock()
    private var worker: Task<Void, Never>?
    private var generation: UUID?
    private var stopping = false
    private var boundPort: UInt16?
    private var server: GRPCServer<HTTP2ServerTransport.TransportServices>?
    public var port: UInt16? { lock.withLock { boundPort } }

    private var descriptorURL: URL {
        AgentHostDirectory.bridgeDiscoveryDirectory(dataRoot: dataRoot())
            .appendingPathComponent("a2a-grpc.json")
    }

    public func start() {
        lock.withLock {
            guard worker == nil else { return }
            let id = UUID()
            stopping = false
            generation = id
            worker = Task { [self] in
                defer { finished(id) }
                let transport = HTTP2ServerTransport.TransportServices(
                    address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
                let service = AgentA2AGRPCEndpoint(endpoint: {
                    self.endpoint(self.port)
                }, authenticate: { metadata in
                    try AgentA2AGRPCEndpoint.authenticate(metadata: metadata,
                        liveToken: self.liveToken(), dataRoot: self.dataRoot())
                })
                let server = GRPCServer(transport: transport, services: [service])
                let shouldServe = lock.withLock {
                    guard generation == id, !stopping else { return false }
                    self.server = server
                    return true
                }
                guard shouldServe else { return }
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        defer { group.cancelAll() }
                        group.addTask { try await server.serve() }
                        group.addTask {
                            let address = try await transport.listeningAddress
                            guard let number = address.ipv4?.port, let port = UInt16(exactly: number) else {
                                throw RPCError(code: .internalError, message: "gRPC did not bind a loopback port")
                            }
                            try self.publish(port: port, generation: id)
                        }
                        // Observe publication failure before waiting for the serving child.
                        while try await group.next() != nil {}
                    }
                } catch {
                    if !Task.isCancelled { nativeLog("[A2A gRPC] listener ended: %@", String(describing: error)) }
                }
            }
        }
    }

    public func stop() {
        lock.withLock {
            stopping = true
            if let server { server.beginGracefulShutdown() }
            else { worker?.cancel() }
            // Keep the worker and server owned until serve() has actually
            // drained. start() cannot admit another listener in the meantime.
            boundPort = nil
            try? FileManager.default.removeItem(at: descriptorURL)
        }
    }

    private func publish(port: UInt16, generation id: UUID) throws {
        try lock.withLock {
            guard generation == id, !stopping, !Task.isCancelled else { throw CancellationError() }
            let directory = descriptorURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "host": "127.0.0.1",
                "port": Int(port), "url": "http://127.0.0.1:\(port)", "protocolVersion": "1.0", "protocolBinding": "GRPC"])
            try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: descriptorURL)
            boundPort = port
        }
    }

    private func finished(_ id: UUID) {
        lock.withLock {
            guard generation == id else { return }
            boundPort = nil
            generation = nil
            stopping = false
            worker = nil
            server = nil
            try? FileManager.default.removeItem(at: descriptorURL)
        }
    }
}

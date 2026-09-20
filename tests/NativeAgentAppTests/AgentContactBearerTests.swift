import Foundation
import Network
import Testing
import ChatOrchestration
@testable import NativeAgentApp

private final class ContactBearerServer: BridgeHTTPServer, @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("contact-bearer-\(UUID())")
    let bridge = ClaudeBridge()
    let listener: NWListener
    let peer: AgentPeerContact
    let tasks: AgentContactTasks
    init() throws {
        var contact = AgentPeerContact(name: "Fixture", endpoint: URL(string: "http://127.0.0.1:1234")!, transport: .a2a)
        contact.credentialKey = AgentPeerContact.credentialKey(for: contact.id)
        peer = contact
        try AgentPeerStore(dataRoot: root).upsert(contact)
        tasks = AgentContactTasks(dataRoot: root) { _, _ in .init(state: .completed, parts: [.text("Reached Agent")]) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: .global())
            BridgeCore.readRequest(connection, buffered: Data(), maxBodyBytes: 65536, server: self)
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state { case .ready: c.resume(); case .failed(let e): c.resume(throwing: e); default: break }
            }
            listener.start(queue: .global())
        }
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
    }
    func received(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        route(conn: conn, method: method, path: path,
              headers: ClaudeBridge.contactHeaders(path: path, headers: headers, liveToken: "fixture-bridge",
                  dataRoot: root, readCredential: { _ in "fixture-contact" }), body: body)
    }
    func route(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        // Same outer gate as ClaudeBridge.route, followed by its real door.
        guard BridgeCore.authorize(authorizationHeader: headers["authorization"], liveToken: "fixture-bridge") == .authorized else {
            BridgeCore.writeJSON(conn, status: 401, obj: ["error": "unauthorized"]); return
        }
        _ = bridge.routeAgentContact(conn: conn, method: method, path: path, headers: headers, body: body,
            dataRoot: root, liveToken: "fixture-bridge", readCredential: { _ in "fixture-contact" }, tasks: tasks)
    }
    func stop() { listener.cancel(); try? FileManager.default.removeItem(at: root) }
}

@Suite(.timeLimit(.minutes(1))) struct AgentContactBearerTests {
    @Test func nativeAndPlainClientsReachDoorWithBearerAlone() async throws {
        let server = try ContactBearerServer()
        defer { server.stop() }
        let base = try await server.start()
        for path in ["agent/card", ".well-known/agent-card.json"] {
            let response = try await AgentPeerHTTP.get(base.appendingPathComponent(path), bearerToken: "fixture-contact")
            #expect(response.statusCode == 200)
        }
        let nativeRequest = try AgentA2AWire.messageRequest(text: "hello from NativeAgent", messageID: "native-client",
            interface: .init(endpoint: base.appendingPathComponent("a2a"), version: "0.3", binding: "JSONRPC"))
        let nativeReply = try await AgentPeerHTTP.send(nativeRequest, bearerToken: "fixture-contact")
        #expect(nativeReply.statusCode == 200)
        #expect(nativeReply.json != nil)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent("a2a"))
        request.httpMethod = "POST"
        request.setValue("Bearer fixture-contact", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"message/send","params":{"message":{"kind":"message","messageId":"plain-client","role":"user","parts":[{"kind":"text","text":"hello"}]},"configuration":{"blocking":true}}}"#.utf8)
        let (bytes, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: bytes, as: UTF8.self).contains("Reached Agent"))
        #expect(try await AgentPeerHTTP.get(base.appendingPathComponent("agent/card"), bearerToken: "unknown").statusCode == 401)
        // A shared transport key alone must not impersonate a contact.
        #expect(try await AgentPeerHTTP.get(base.appendingPathComponent("agent/card"), bearerToken: "fixture-bridge").statusCode == 401)
        let builder = ClaudeBridge.contactHeaders(path: "/codex/message", headers: ["authorization": "Bearer fixture-contact"],
            liveToken: "fixture-bridge", dataRoot: server.root, readCredential: { _ in "fixture-contact" })
        #expect(builder["authorization"] == "Bearer fixture-contact")
        try AgentPeerStore(dataRoot: server.root).remove(server.peer.id)
        #expect(try await AgentPeerHTTP.get(base.appendingPathComponent("agent/card"), bearerToken: "fixture-contact").statusCode == 401)
    }
}

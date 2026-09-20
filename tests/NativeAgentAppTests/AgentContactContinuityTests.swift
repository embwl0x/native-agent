import Foundation
import Testing
@testable import ChatOrchestration
@testable import NativeAgentApp

@Suite struct AgentContactContinuityTests {
    @Test(arguments: ["missing", "unreadable", "shared", "unique"])
    func projectedReadinessUsesTheCurrentDoorCheck(condition: String) throws {
        let home = root()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AgentPeerStore(dataRoot: home)
        var peer = AgentPeerContact(name: "Maple", endpoint: URL(string: "http://127.0.0.1:1234")!, transport: .a2a)
        peer.credentialKey = AgentPeerContact.credentialKey(for: peer.id)
        var other = AgentPeerContact(name: "Other", endpoint: URL(string: "http://127.0.0.1:1235")!, transport: .a2a)
        other.credentialKey = AgentPeerContact.credentialKey(for: other.id)
        try store.upsert(peer)
        try store.upsert(other)
        store.recordProof(peerID: peer.id, inbound: true)
        store.recordRoundTrip(peerID: peer.id, workspace: home.path)
        let peers = try store.list()
        let saved = try #require(peers.first { $0.id == peer.id })
        let before = try Data(contentsOf: store.fileURL)
        var current = condition
        let read: (String) throws -> String? = { id in
            if current == "unreadable" { throw AgentPeerCredentials.CredentialError.unavailable }
            if current == "missing" { return nil }
            return id == peer.id || current == "shared" ? "fixture-key" : "other-key"
        }
        let row = AgentContactRow(id: peer.id, name: peer.name, contact: saved, peers: peers, readCredential: read)
        func door() -> String? {
            AgentBridgePrincipal.resolve(headers: ["authorization": "Bearer fixture-key"],
                dataRoot: home, readCredential: read).peerID
        }
        #expect((door() == peer.id) == (condition == "unique"))
        #expect((row.state == .connected) == (condition == "unique"))
        #expect(row.status.contains("Ready") == (condition == "unique"))
        if condition != "unique" {
            #expect(row.status.hasPrefix(AgentPeerCredentials.unavailableDetail))
            #expect(row.status.contains("Historical round trip"))
        }
        #expect(row.status.contains(try #require(saved.roundTripProof?.at)))
        current = "unique"
        #expect(row.state == .connected)
        current = "missing"
        #expect(row.state == .unavailable)
        #expect(try Data(contentsOf: store.fileURL) == before)
    }

    @Test func preUpgradeContactKeepsIdentityAndConversationWithLegacyKey() throws {
        let home = root()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AgentPeerStore(dataRoot: home)
        var contact = AgentPeerContact(name: "Longtime friend", endpoint: URL(string: "http://127.0.0.1:1234")!, transport: .a2a)
        contact.credentialKey = AgentPeerContact.credentialKey(for: contact.id)
        try store.upsert(contact)
        store.recordProof(peerID: contact.id, inbound: true)
        let before = try Data(contentsOf: store.fileURL)
        var keys = [AgentPeerCredentials.legacyService: "legacy-fixture"]
        func resolve() -> AgentBridgePrincipal {
            AgentBridgePrincipal.resolve(headers: ["authorization": "Bearer legacy-fixture"], dataRoot: home) { _ in
                try AgentPeerCredentials.compatibleToken(service: "fixture-install", read: { keys[$0] })
            }
        }
        let peer = resolve()
        #expect(peer.peerID == contact.id)
        #expect(try store.list().first?.state == .connected)
        #expect(peer.storedConversation("a2a-" + contact.id) == peer.storedConversation("mcp-" + contact.id))
        #expect(try Data(contentsOf: store.fileURL) == before)
        try AgentPeerCredentials.revoke(service: "fixture-install") { keys.removeValue(forKey: $0) }
        #expect(resolve().peerID == nil)
    }
    @Test(arguments: ["persisted", "partial", "missing", "wrong-run"])
    func restartReconcilesCanonicalReplyBeforeInterrupting(status: String) async throws {
        let home = root()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString.lowercased()
        let peer = AgentBridgePrincipal(id: id, peerID: id, elevated: false, displayName: "Maple")
        let bytes = Data(#"{"jsonrpc":"2.0","id":1,"method":"message/send","params":{"message":{"kind":"message","messageId":"crash-window","role":"user","parts":[{"kind":"text","text":"hello"}]},"configuration":{"blocking":true}}}"#.utf8)
        let tasks = AgentContactTasks(dataRoot: home) { turn, _ in
            let session = peer.storedConversation(turn.context)
            let run = UUID().uuidString
            try await turn.bindRun(session, run)
            if status != "missing" {
                let file = home.appendingPathComponent("chat/messages/\(session).jsonl")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let row: [String: Any] = ["sessionId": session, "runId": status == "wrong-run" ? "unrelated" : run,
                    "role": "assistant", "content": "Durable answer",
                    "metadata": ["outcomeObservation": ["responsePersistence": status == "partial" ? "partial" : "persisted"]]]
                try JSONSerialization.data(withJSONObject: row).write(to: file)
            }
            return .init(state: .completed, parts: [.text("Durable answer")])
        }
        guard case .json(let first) = await AgentContactA2AEndpoint(tasks: tasks).handle(bytes, principal: peer),
              let result = first["result"] as? [String: Any], let taskID = result["id"] as? String else {
            Issue.record("Missing task"); return
        }
        // Model the exact crash boundary: transcript committed, terminal task
        // replacement absent. Keep the durable run binding from acceptance.
        let files = try FileManager.default.contentsOfDirectory(at: home.appendingPathComponent("agents/a2a-replies"), includingPropertiesForKeys: nil)
        let file = try #require(files.first { $0.pathExtension == "json" })
        var retained = try JSONDecoder().decode(AgentContactTask.self, from: Data(contentsOf: file))
        retained.state = .working; retained.text = ""; retained.parts = []
        try JSONEncoder().encode(retained).write(to: file)
        let restarted = AgentContactTasks(dataRoot: home) { _, _ in
            Issue.record("Recovery executed an accepted turn twice")
            return .init(state: .failed, parts: [])
        }
        let recovered = try await restarted.get(taskID, owner: id)
        #expect(recovered.state == (status == "persisted" ? .completed : .failed))
        #expect(recovered.text == (status == "persisted" ? "Durable answer" : ""))
        var artifacts = 0
        for await event in try await restarted.subscribe(taskID, owner: id) {
            switch event {
            case .snapshot(let task): if !task.parts.isEmpty { artifacts += 1 }
            case .artifact: artifacts += 1
            case .status: break
            }
        }
        #expect(artifacts == (status == "persisted" ? 1 : 0))
        _ = await AgentContactA2AEndpoint(tasks: restarted).handle(bytes, principal: peer)
        let again = AgentContactTasks(dataRoot: home) { _, _ in
            Issue.record("Second restart executed accepted work")
            return .init(state: .failed, parts: [])
        }
        #expect(try await again.get(taskID, owner: id).state == recovered.state)
    }
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("contact-home-\(UUID())")
    }

    @Test func credentialOwnsNameAndRevocationCannotFallBack() throws {
        let home = root()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AgentPeerStore(dataRoot: home)
        var contact = AgentPeerContact(name: "Maple", endpoint: URL(string: "http://127.0.0.1:1234")!, transport: .a2a)
        contact.credentialKey = AgentPeerContact.credentialKey(for: contact.id)
        try store.upsert(contact)
        let headers = [AgentBridgePrincipal.peerIDHeader: contact.id, AgentBridgePrincipal.peerSecretHeader: "fixture-key"]
        let known = AgentBridgePrincipal.resolve(headers: headers, dataRoot: home, readCredential: { _ in "fixture-key" })
        #expect(known.displayName == "Maple")
        #expect(AgentBridgeSurface.turnHeader(peerName: known.displayName, elevated: false).contains("Maple"))
        #expect(AgentBridgePrincipal.resolve(headers: headers, dataRoot: home, readCredential: { _ in nil }).peerID == nil)
        #expect(AgentBridgePrincipal.resolve(headers: headers, dataRoot: home, readCredential: { _ in "other-key" }).peerID == nil)
        #expect(AgentBridgePrincipal.resolve(headers: [:], dataRoot: home, readCredential: { _ in "fixture-key" }).peerID == nil)
        try store.remove(contact.id)
        #expect(AgentBridgePrincipal.resolve(headers: headers, dataRoot: home, readCredential: { _ in "fixture-key" }).peerID == nil)
    }

    @Test func omittedConversationContinuesAcrossDoorsAndExplicitConversationStaysSeparate() throws {
        let id = UUID().uuidString.lowercased()
        let peer = AgentBridgePrincipal(id: id, peerID: id, elevated: true, displayName: "Maple")
        let otherID = UUID().uuidString.lowercased()
        let other = AgentBridgePrincipal(id: otherID, peerID: otherID, elevated: false, displayName: "Maple")
        let request = UUID().uuidString.lowercased()
        let bytes = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "agent_message", "arguments": ["text": "[from: someone else] hello", "request_id": request]]])
        for _ in 0..<2 {
            guard case .message(let body, _) = NativeAgentMCPWire.parse(bytes, defaultSession: peer.conversationID(protocolName: "mcp")) else {
                Issue.record("Message refused"); return
            }
            let message = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let session = try #require(message["sessionId"] as? String)
            #expect(peer.storedConversation(session) == peer.storedConversation("a2a-" + id))
            #expect(ClaudeBridge.genericAgentSessionID(requested: nil, owner: id) == peer.storedConversation(session))
            #expect(peer.storedConversation(session) != other.storedConversation(session))
        }
        #expect(peer.storedConversation("a2a-" + UUID().uuidString.lowercased()) != peer.storedConversation("a2a-" + id))
    }

    @Test func delayedInboundAndDuplicateRetainConversationAndReplyAfterRestart() async throws {
        let home = root()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString.lowercased()
        let peer = AgentBridgePrincipal(id: id, peerID: id, elevated: false, displayName: "Maple")
        func message(_ messageID: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "message/send",
                "params": ["message": ["kind": "message", "role": "user", "messageId": messageID,
                    "parts": [["kind": "text", "text": "A late reply"]]], "configuration": ["blocking": true]]])
        }
        let tasks = AgentContactTasks(dataRoot: home) { turn, _ in
            #expect(turn.principal.displayName == "Maple")
            #expect(turn.context == "a2a-" + id)
            return .init(state: .completed, parts: [.text("Saved reply")])
        }
        let bytes = try message("first")
        guard case .json(let initial) = await AgentContactA2AEndpoint(tasks: tasks).handle(bytes, principal: peer),
              let task = initial["result"] as? [String: Any], let taskID = task["id"] as? String else {
            Issue.record("Missing task"); return
        }
        let restarted = AgentContactTasks(dataRoot: home) { turn, _ in
            #expect(turn.context == "a2a-" + id)
            #expect(turn.parts == [.text("A late reply")])
            return .init(state: .completed, parts: [.text("Late reply received")])
        }
        let recovered = try await restarted.get(taskID, owner: id)
        #expect(recovered.text == "Saved reply")
        guard case .json(let replay) = await AgentContactA2AEndpoint(tasks: restarted).handle(bytes, principal: peer) else {
            Issue.record("Missing replay"); return
        }
        #expect((replay["result"] as? [String: Any])?["id"] as? String == taskID)
        #expect(try await restarted.get(taskID, owner: id).text == "Saved reply")
        let late = try message("late")
        guard case .json(let delivered) = await AgentContactA2AEndpoint(tasks: restarted).handle(late, principal: peer),
              let result = delivered["result"] as? [String: Any], let lateID = result["id"] as? String else {
            Issue.record("Missing late reply"); return
        }
        #expect(result["contextId"] as? String == task["contextId"] as? String)
        #expect(try await restarted.get(lateID, owner: id).text == "Late reply received")
        let again = AgentContactTasks(dataRoot: home) { _, _ in
            Issue.record("Duplicate started a second turn")
            return .init(state: .failed, parts: [])
        }
        _ = await AgentContactA2AEndpoint(tasks: again).handle(late, principal: peer)
        #expect(try await again.get(lateID, owner: id).text == "Late reply received")
        await #expect(throws: (any Error).self) { try await again.get(lateID, owner: UUID().uuidString) }
    }
}

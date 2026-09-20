import Foundation
import Testing
import NativeAgentCore
@testable import ChatOrchestration

@Suite struct AgentContactLaneTests {
    @Test(arguments: ["missing", "unreadable", "shared", "unique"])
    func projectedStateRequiresCurrentUniqueCredential(condition: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        var peer = AgentPeerContact(name: "Codex", endpoint: URL(string: "mcp://codex")!, transport: .mcpHost)
        peer.credentialKey = AgentPeerContact.credentialKey(for: peer.id)
        var other = AgentPeerContact(name: "Other", endpoint: URL(string: "mcp://codex")!, transport: .mcpHost)
        other.credentialKey = AgentPeerContact.credentialKey(for: other.id)
        try store.upsert(peer)
        try store.upsert(other)
        store.recordProof(peerID: peer.id, inbound: true)
        store.recordRoundTrip(peerID: peer.id, executable: "/fixture/codex", workspace: root.path)
        let before = try Data(contentsOf: store.fileURL)
        let peers = try store.list()
        let read: (String) throws -> String? = { id in
            if condition == "unreadable" { throw AgentPeerCredentials.CredentialError.unavailable }
            if condition == "missing" { return nil }
            return id == other.id && condition != "shared" ? "other-key" : "fixture-key"
        }
        let contacts = SwiftToolDispatcher.agentLaneContacts(peers: peers, usable: [], readCredential: read)
        guard case .object(let value)? = contacts.first else { Issue.record("Missing projection"); return }
        #expect(value["state"] == .string(condition == "unique" ? "connected" : "unavailable"))
        if condition != "unique" {
            #expect(value["state_detail"] == .string(AgentPeerCredentials.unavailableDetail))
            #expect(value["readiness"] == .string("unavailable"))
        }
        #expect(value["round_trip_proof"] != nil)
        #expect(value["last_reply_in"] != nil)
        #expect(try Data(contentsOf: store.fileURL) == before)
    }

    @Test(arguments: [false, true])
    func hostReadinessRequiresReplyThroughConnection(connectionReply: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        let peer = try store.upsert(AgentPeerContact(name: "Codex", endpoint: URL(string: "mcp://codex")!, transport: .mcpHost))
        let nonce = try store.beginConnectionProbe(peerID: peer.id, timeout: 60)
        store.recordProof(peerID: peer.id, inbound: true, message: connectionReply ? nonce : "unrelated message")
        let arrived = SwiftToolDispatcher.recordHostConnectionOutcome(store: store, contact: peer,
            ran: true, replied: true, probe: true, probeNonce: nonce,
            executable: "/fixture/codex", workspace: root.path)
        let saved = try #require(store.list().first)
        #expect(arrived == connectionReply)
        #expect(saved.state == (connectionReply ? .connected : .setUp))
        guard case .object(let projected)? = SwiftToolDispatcher.agentLaneContacts(peers: [saved], usable: [],
            readCredential: { _ in nil }).first else { Issue.record("Missing contact"); return }
        #expect(projected["state"] == .string("unavailable"))
        #expect(projected["state_detail"] == .string(AgentPeerCredentials.unavailableDetail))
        #expect(saved.isReady == connectionReply)
        #expect(saved.roundTripProof == nil)
        #expect((saved.mcpReturnProof != nil) == connectionReply)
        #expect(saved.provenInboundAt != nil)
        #expect(!store.finishConnectionProbe(peerID: peer.id, nonce: nonce, ran: true, workspace: root.path))
    }

    @Test func probeRejectsWrongPeerExpiredSupersededAndReplayedNonces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        let peer = try store.upsert(AgentPeerContact(name: "Codex", endpoint: URL(string: "mcp://codex")!, transport: .mcpHost))
        let other = try store.upsert(AgentPeerContact(name: "Other", endpoint: URL(string: "mcp://codex")!, transport: .mcpHost))
        let expired = try store.beginConnectionProbe(peerID: peer.id, timeout: -1)
        store.recordProof(peerID: peer.id, inbound: true, message: expired)
        #expect(!store.finishConnectionProbe(peerID: peer.id, nonce: expired, ran: true, workspace: root.path))
        let old = try store.beginConnectionProbe(peerID: peer.id, timeout: 60)
        let nonce = try store.beginConnectionProbe(peerID: peer.id, timeout: 60)
        #expect(old != nonce)
        #expect(AgentHostDirectory.probeText(appName: "Fixture", nonce: nonce).contains(nonce))
        store.recordProof(peerID: peer.id, inbound: true, message: old)
        store.recordProof(peerID: other.id, inbound: true, message: nonce)
        #expect(!store.finishConnectionProbe(peerID: peer.id, nonce: old, ran: true, workspace: root.path))
        #expect(!store.finishConnectionProbe(peerID: peer.id, nonce: nonce, ran: true, workspace: root.path))
        store.recordProof(peerID: peer.id, inbound: true, message: nonce)
        #expect(try store.list().first { $0.id == peer.id }?.mcpReturnProof == nil)
    }

    @Test func commandAndReturnProofsRemainSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        let peer = try store.upsert(AgentPeerContact(name: "Codex", endpoint: URL(string: "mcp://codex")!, transport: .mcpHost))
        store.recordRoundTrip(peerID: peer.id, executable: "/fixture/codex", workspace: root.path)
        let original = try #require(store.list().first?.roundTripProof)
        let nonce = try store.beginConnectionProbe(peerID: peer.id, timeout: 60)
        store.recordProof(peerID: peer.id, inbound: true, message: nonce)
        #expect(store.finishConnectionProbe(peerID: peer.id, nonce: nonce, ran: true, workspace: root.path))
        let saved = try #require(store.list().first)
        #expect(saved.isReady)
        #expect(saved.roundTripProof == original)
        #expect(saved.mcpReturnProof?.endpoint.absoluteString == "mcp://codex")
        #expect(saved.mcpReturnProof?.executable == nil)
    }

    @Test func commandReplyProvesOnlyCommandRoute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        var contact = AgentPeerContact(name: "Codex", endpoint: URL(string: "mcp://codex")!, transport: .mcpHost)
        contact.approvedExecutablePath = "/fixture/codex"
        let peer = try store.upsert(contact)
        _ = SwiftToolDispatcher.recordHostConnectionOutcome(store: store, contact: peer,
            ran: true, replied: true, probe: false, executable: "/fixture/codex", workspace: root.path)
        let saved = try #require(store.list().first)
        #expect(saved.isReady)
        #expect(saved.roundTripProof?.executable == "/fixture/codex")
        #expect(saved.mcpReturnProof == nil)
        #expect(saved.provenInboundAt == nil)
        _ = SwiftToolDispatcher.recordHostConnectionOutcome(store: store, contact: saved,
            ran: true, replied: true, probe: true, executable: "/fixture/codex", workspace: root.path)
        #expect(try store.list().first?.isReady == true)
    }

    @Test func freshInstallListsNoBuiltInLanesAndKeepsSavedContacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = AgentPeerContact(name: "Codex", endpoint: URL(string: "https://fixture.example")!, transport: .a2a)
        try AgentPeerStore(dataRoot: root).upsert(peer)
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false,
            agentBridgeConfigRoot: root.appendingPathComponent("config"))
        let result = try await dispatcher.impl_agentCommunication(tool: "agent_contacts", input: [:], surface: "chat")
        guard case .object(let fields) = result, case .array(let contacts)? = fields["contacts"] else {
            Issue.record("Missing contacts"); return
        }
        let handles = contacts.compactMap { contact -> String? in
            guard case .object(let fields) = contact, case .string(let handle)? = fields["agent"] else { return nil }
            return handle
        }
        #expect(handles.contains("peer:" + peer.id))
        #expect(Set(handles).isDisjoint(with: ["codex", "claude", "omp"]))
    }

    @Test func lanesNeedTheirDirectoryAndRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = root.appendingPathComponent("claude-bridge")
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        let token = "fixture-token"
        try Data(token.utf8).write(to: bridge.appendingPathComponent("token"))
        try JSONSerialization.data(withJSONObject: [
            "url": "http://127.0.0.1:49152", "token": token,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier
        ]).write(to: bridge.appendingPathComponent("bridge.json"))
        let returnPath = AgentBridgeRuntime.returnPathReadiness(configRoot: root)
        let executable = root.appendingPathComponent("fixture")
        let ready = AgentBridgeRuntime.Readiness(helper: executable, runtime: executable,
                                                cli: executable, returnPath: returnPath)
        for name in ["codex-nativeagent-bridge", "claude-bridge", "omp-bridge"] {
            let directory = root.appendingPathComponent(name)
            if name != "claude-bridge" {
                #expect(!SwiftToolDispatcher.builtInAgentLaneUsable(directory: directory, readiness: ready))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            #expect(SwiftToolDispatcher.builtInAgentLaneUsable(directory: directory, readiness: ready))
            for missing in 0..<3 {
                let unavailable = AgentBridgeRuntime.Readiness(
                    helper: missing == 0 ? nil : executable, runtime: missing == 1 ? nil : executable,
                    cli: missing == 2 ? nil : executable, returnPath: returnPath)
                #expect(!SwiftToolDispatcher.builtInAgentLaneUsable(directory: directory, readiness: unavailable))
            }
        }
        try FileManager.default.removeItem(at: bridge.appendingPathComponent("token"))
        let unavailable = AgentBridgeRuntime.Readiness(helper: executable, runtime: executable,
            cli: executable, returnPath: AgentBridgeRuntime.returnPathReadiness(configRoot: root))
        #expect(!SwiftToolDispatcher.builtInAgentLaneUsable(directory: bridge, readiness: unavailable))
    }
}

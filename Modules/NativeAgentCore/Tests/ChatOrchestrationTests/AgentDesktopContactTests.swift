import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite struct AgentDesktopContactTests {
    @Test func desktopSetupAndRoutesNeverPerformNetworkOrClaimDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-contact-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
        try await AgentPeerHTTP.$fixtureConfiguration.withValue({
            Issue.record("Desktop routes must not even configure HTTP")
            return .ephemeral
        }) {
            let input: [String: JSONValue] = ["name": .string("Grok Bot"), "transport": .string("desktop"),
                "app_bundle_id": .string("com.anysphere.sand"), "conversation_label": .string("grok"),
                "endpoint": .null, "bearer_token": .null]
            let configured = try await dispatcher.impl_agentCommunication(tool: "agent_connect", input: input, surface: "chat")
            guard case .object(let setup) = configured else { Issue.record("Missing setup"); return }
            #expect(setup["sent"] == .bool(false))
            #expect(setup["completed"] == .bool(false))
            let store = AgentPeerStore(dataRoot: root)
            let peer = try #require(store.list().first)
            #expect(peer.endpoint.absoluteString == "app://com.anysphere.sand")
            #expect(peer.conversationLabel == "grok")
            #expect(peer.credentialKey == nil)
            _ = try await dispatcher.impl_agentCommunication(tool: "agent_connect", input: input, surface: "chat")
            #expect(try store.list() == [peer])
            for operation in ["agent_message", "agent_read"] {
                var args: [String: JSONValue] = ["agent": .string("peer:" + peer.id)]
                if operation == "agent_message" { args["text"] = .string("Hello fixture") }
                let route = try await dispatcher.impl_agentCommunication(tool: operation, input: args, surface: "chat")
                guard case .object(let fields) = route else { Issue.record("Missing route"); return }
                #expect(fields["status"] == .string("requires_interaction"))
                #expect(fields["sent"] == .bool(false))
                #expect(fields["completed"] == .bool(false))
                #expect(fields["automatic_action"] == .bool(false))
                #expect(fields["target"] == .object(["app_bundle_id": .string("com.anysphere.sand"), "conversation_label": .string("grok")]))
                #expect(fields["requested_text"] == (operation == "agent_message" ? .string("Hello fixture") : nil))
                #expect(fields["message_id"] == nil && fields["conversation_id"] == nil && fields["reply"] == nil)
            }
            var credential = input
            credential["bearer_token"] = .string("fixture-secret")
            await #expect(throws: (any Error).self) {
                try await dispatcher.impl_agentCommunication(tool: "agent_connect", input: credential, surface: "chat")
            }
            for field in ["conversation_id", "message_id", "task_id", "offset"] {
                await #expect(throws: (any Error).self) {
                    try await dispatcher.impl_agentCommunication(tool: "agent_read", input: [
                        "agent": .string("peer:" + peer.id), field: .string("invented")], surface: "chat")
                }
            }
            #expect(try store.list() == [peer])
        }
    }

    @Test func labelsScopeDistinctTargetsAndLegacyContactsStillUpdateAndRemove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        let app = URL(string: "app://com.example.agent")!
        let one = try store.insertDiscovered(AgentPeerContact(name: "One", endpoint: app, transport: .desktop, conversationLabel: "one"))
        let two = try store.insertDiscovered(AgentPeerContact(name: "Two", endpoint: app, transport: .desktop, conversationLabel: "two"))
        #expect(one.id != two.id)
        var legacy = AgentPeerContact(name: "Legacy", endpoint: URL(string: "https://example.test/card")!, transport: .a2a)
        try store.upsert(legacy)
        legacy.name = "Updated"
        try store.upsert(legacy)
        #expect(try store.list().contains(legacy))
        #expect(try store.remove(one.id))
        #expect(try store.remove(legacy.id))
        #expect(try store.list() == [two])
        let oldJSON = """
        {"id":"\(UUID().uuidString.lowercased())","name":"Old","endpoint":"https://example.test/card","transport":"a2a"}
        """
        let old = try JSONDecoder().decode(AgentPeerContact.self, from: Data(oldJSON.utf8))
        #expect(old.conversationLabel == nil)
        try AgentPeerStore.validate(old)
    }

    @Test(arguments: ["app://com.example.agent/path", "app://com.example.agent?x=y", "app://user@com.example.agent", "app://com..agent", "https://com.example.agent", "app://com.example.agent#x"])
    func desktopIdentityRejectsURLsThatAreNotExactBundleIdentifiers(address: String) {
        #expect(AgentPeerStore.desktopBundleID(URL(string: address)!) == nil)
    }
}

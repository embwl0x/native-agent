import Foundation
import AppKit
import ApplicationServices
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration
@testable import NativeAgentApp

private struct NoGrokDesktopTools: ToolDispatchClient {
    func listAvailableTools() async throws -> [String] { [] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        Issue.record("Unconfirmed disconnect must not drive the desktop")
        return .null
    }
}

@Suite struct GrokBotConnectionTests {
    @Test func unconfirmedLegacyDisconnectRemovesContactWithoutDesktopCleanup() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var peer = AgentPeerContact(name: "Grok Bot", endpoint: URL(string: "grok://grok-bot")!, transport: .grokBot)
        peer.grokSetup = "disconnected"
        peer.credentialKey = AgentPeerContact.credentialKey(for: peer.id)
        peer.grokConversation = "Grok Bot" // old failed bootstrap saved the window title
        let store = AgentPeerStore(dataRoot: root)
        _ = try store.upsert(peer)
        let result = await GrokBotConnection.perform(plan: ["status": .string("grok_disconnect"), "peer_id": .string(peer.id)],
            dataRoot: root, inner: NoGrokDesktopTools(), surface: "chat")
        guard case .object(let fields) = result else { Issue.record("Missing result"); return }
        #expect(fields["status"] == .string("disconnected"))
        #expect(try store.list().isEmpty)
    }

    @Test @MainActor func placeholderRecognitionDoesNotMistakeDraftsForEmptyComposers() {
        #expect(GrokRoutineAccessibility.isEmptyBox("Message grok"))
        #expect(GrokRoutineAccessibility.isEmptyBox("Ask anything…"))
        #expect(!GrokRoutineAccessibility.isEmptyBox("Ask Grok to finish…"))
        #expect(!GrokRoutineAccessibility.isEmptyBox("Message User"))
    }

    @Test @MainActor func grokInputEventsCarryClickAndKeyboardIntentWithoutPosting() throws {
        let point = CGPoint(x: 120, y: 340)
        let click = try GrokRoutineAccessibility.clickEvents(at: point)
        #expect(click.map(\.type) == [.leftMouseDown, .leftMouseUp])
        #expect(click.allSatisfy { $0.location == point && $0.getIntegerValueField(.mouseEventClickState) == 1 })
        let paste = try GrokRoutineAccessibility.keyEvents(9, flags: .maskCommand)
        #expect(paste.map(\.type) == [.keyDown, .keyUp])
        #expect(paste.allSatisfy { $0.flags == .maskCommand && $0.getIntegerValueField(.keyboardEventKeycode) == 9 })
        let submit = try GrokRoutineAccessibility.keyEvents(36)
        #expect(submit.map(\.type) == [.keyDown, .keyUp])
        #expect(submit.allSatisfy { $0.flags.isEmpty && $0.getIntegerValueField(.keyboardEventKeycode) == 36 })
    }

    @Test @MainActor func grokPasteboardSnapshotPreservesAllItemsAndFormats() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        let custom = NSPasteboard.PasteboardType("test.grok.binary")
        let bytes = Data([0, 255, 10, 42])
        first.setString("previous clipboard", forType: .string)
        first.setData(bytes, forType: custom)
        second.setString("second item", forType: .string)
        #expect(board.writeObjects([first, second]))
        let saved = try GrokRoutineAccessibility.copyPasteboard(board)
        board.clearContents()
        board.setString("temporary message", forType: .string)
        board.clearContents()
        #expect(board.writeObjects(saved))
        let restored = try #require(board.pasteboardItems)
        #expect(restored.count == 2)
        #expect(restored[0].string(forType: .string) == "previous clipboard")
        #expect(restored[0].data(forType: custom) == bytes)
        #expect(restored[1].string(forType: .string) == "second item")
        board.clearContents()
        #expect(try GrokRoutineAccessibility.copyPasteboard(board).isEmpty)
    }

    @Test func chosenBotAndConfirmationSurviveContactPersistence() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let peer = try contact(root)
        let store = AgentPeerStore(dataRoot: root)
        try store.updateGrok(peer.id) {
            $0.conversationLabel = "NA Research"
            $0.grokBootstrapConfirmed = true
        }
        let saved = try #require(store.list().first)
        #expect(saved.conversationLabel == "NA Research")
        #expect(saved.grokBootstrapConfirmed == true)
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("grok-fixture-" + UUID().uuidString) }
    private func contact(_ root: URL) throws -> AgentPeerContact {
        var peer = AgentPeerContact(name: "Grok Bot", endpoint: URL(string: "grok://grok-bot")!, transport: .grokBot)
        peer.credentialKey = AgentPeerContact.credentialKey(for: peer.id)
        peer.grokSetup = "set up"
        return try AgentPeerStore(dataRoot: root).upsert(peer)
    }
    @Test func fakeWebhookKeepsAcceptanceSeparateAndNeverRetriesAmbiguity() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let peer = try contact(root), id = UUID().uuidString.lowercased()
        var credential = GrokLinkCredential(descriptorPath: "/tmp/fake-descriptor", replyToken: "local-fixture")
        try credential.importWebhook(url: "https://example.invalid/routine-secret", key: "webhook-fixture")
        let receipt = try await GrokBotRoute.send(peer: peer, text: "nonce-314 what is 12 times 12", conversation: "original-chat",
            messageID: id, dataRoot: root, credential: credential) { request in
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer webhook-fixture")
                let bytes = try #require(request.httpBody)
                let decoded = try JSONSerialization.jsonObject(with: bytes) as? [String: String]
                let body = try #require(decoded)
                #expect(Set(body.keys) == ["message_id", "conversation_id", "text"])
                #expect(body["message_id"] == id && body["conversation_id"] == "original-chat")
                return 200
            }
        guard case .object(let fields) = receipt else { Issue.record("Missing receipt"); return }
        #expect(fields["status"] == .string("accepted"))
        #expect(fields["completed"] == .bool(false))
        let disk = try String(contentsOf: root.appendingPathComponent("agents/grok-requests/\(id).json"), encoding: .utf8)
        #expect(!disk.contains("webhook-fixture") && !disk.contains("routine-secret"))
        let uncertain = UUID().uuidString.lowercased()
        _ = try await GrokBotRoute.send(peer: peer, text: "hello", conversation: "original-chat", messageID: uncertain,
            dataRoot: root, credential: credential) { _ in throw URLError(.timedOut) }
        #expect(try GrokRequestStore(dataRoot: root).read(uncertain, peer: peer.id).state == "outcome unknown")
        do {
            _ = try await GrokBotRoute.send(peer: peer, text: "hello", conversation: "original-chat", messageID: uncertain,
                dataRoot: root, credential: credential) { _ in Issue.record("Retried ambiguous POST"); return 200 }
            Issue.record("Accepted duplicate send")
        } catch {}
    }
    @Test func fakeHelperReturnsOneAttributedAnswerToOriginalConversation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let peer = try contact(root), id = UUID().uuidString.lowercased()
        let store = GrokRequestStore(dataRoot: root)
        _ = try store.create(id: id, peer: peer.id, conversation: "original-chat")
        let principal = AgentBridgePrincipal.resolve(headers: ["authorization": "Bearer local-fixture"], dataRoot: root) { _ in "local-fixture" }
        #expect(principal.peerID == peer.id)
        #expect(principal.replyOnly)
        let text = "144 nonce-314 $(touch /tmp/never-execute)"
        let input = try GrokReplyInput.parse(JSONSerialization.data(withJSONObject: ["message_id": id, "text": text]))
        try await GrokInboundReply.receive(input, principal: principal, dataRoot: root) { pending, content, author in
            #expect(pending.conversationID == "original-chat")
            #expect(content == text && author.displayName == "Grok Bot")
            #expect(author.surface == "agent-bridge" && !author.elevated)
            return "fake-enqueued-run"
        }
        #expect(try store.read(id, peer: peer.id).state == "answered")
        for messageID in [id, UUID().uuidString.lowercased()] {
            let repeated = try GrokReplyInput.parse(JSONSerialization.data(withJSONObject: ["message_id": messageID, "text": text]))
            do {
                try await GrokInboundReply.receive(repeated, principal: principal, dataRoot: root) { _, _, _ in
                    Issue.record("Duplicate or unknown reply enqueued"); return "wrong"
                }
                Issue.record("Reply should be refused")
            } catch {}
        }
        #expect(throws: (any Error).self) {
            try GrokReplyInput.parse(JSONSerialization.data(withJSONObject: ["message_id": id, "text": text, "conversation_id": "other-chat"]))
        }
        #expect(AgentBridgePrincipal.resolve(headers: ["authorization": "Bearer wrong"], dataRoot: root) { _ in "local-fixture" }.peerID == nil)
        let contacts = AgentPeerStore(dataRoot: root)
        try contacts.updateGrok(peer.id) { $0.grokSetup = "disconnected" }
        #expect(throws: (any Error).self) {
            try contacts.updateGrok(peer.id) { $0.grokSetup = "set up" }
        }
    }
}

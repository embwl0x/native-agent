import Foundation
import Testing
import ChatOrchestration
import PersistenceCore
@testable import NativeAgentApp

private actor HumanReplyRecorder: AgentBridgeCompletionSending {
    var appends = 0
    var deliveries: [AgentBridgeCompletionRoute] = []
    var refreshed: [String?] = []
    let outcome: AgentBridgeTransportResult
    init(outcome: AgentBridgeTransportResult = .accepted) { self.outcome = outcome }
    func recordAppend() { appends += 1 }
    func refreshLocalChat(sessionId: String?) { refreshed.append(sessionId) }
    func preflight(surface: String, route: AgentBridgeCompletionRoute, artifacts: [AgentBridgeCompletionArtifact]) {}
    func send(artifact: AgentBridgeCompletionArtifact, idempotencyKey: String, surface: String,
              route: AgentBridgeCompletionRoute) -> AgentBridgeTransportResult {
        deliveries.append(route); return outcome
    }
}

@Suite struct HumanConversationReplyTests {
    private func fixture(surface: String = "telegram", destination: String? = "123") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("human-reply-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chat/messages"), withIntermediateDirectories: true)
        try JSONValue.array([.object(["id": .string("exact-chat"), "source": .string(surface), "title": .string("Project")])])
            .serializedData(pretty: false).write(to: root.appendingPathComponent("chat/sessions.json"))
        var envelope: [String: JSONValue] = ["surface": .string(surface), "threadId": .string("7")]
        if let destination { envelope["destinationId"] = .string(destination) }
        let row: JSONValue = .object(["id": .string("last-user"), "role": .string("user"), "content": .string("How is it?"),
            "metadata": .object(["envelope": .object(envelope)])])
        var data = try row.serializedData(pretty: false); data.append(10)
        try data.write(to: root.appendingPathComponent("chat/messages/exact-chat.jsonl"))
        return root
    }
    private let input: [String: JSONValue] = ["conversation_session_id": .string("exact-chat"),
                                             "last_message_id": .string("last-user"), "text": .string("Ready.")]
    private func status(_ value: JSONValue) -> String? { HumanConversationReader.string(HumanConversationReader.object(value)["status"]) }
    @Test func exactSavedTelegramTopicReceivesOneReply() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HumanReplyRecorder()
        let service = HumanConversationReplyService(dataRoot: root, sender: recorder,
            append: { _, _, _, _ in await recorder.recordAppend() })
        #expect(status(try await service.reply(input: input)) == "completed")
        #expect(status(try await service.reply(input: input)) == "already_attempted")
        #expect(await recorder.appends == 1)
        #expect(await recorder.deliveries.count == 1)
        #expect(await recorder.deliveries.first?.sessionId == "exact-chat")
        #expect(await recorder.deliveries.first?.destinationId == "123")
        #expect(await recorder.deliveries.first?.threadId == "7")
    }
    @Test func appConversationRefreshesExactSessionWithoutForegroundSwitchOrExternalSend() async throws {
        let root = try fixture(surface: "app"); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HumanReplyRecorder()
        let service = HumanConversationReplyService(dataRoot: root, sender: recorder,
            append: { _, _, _, _ in await recorder.recordAppend() })
        #expect(status(try await service.reply(input: input)) == "completed")
        #expect(await recorder.appends == 1)
        #expect(await recorder.deliveries.isEmpty)
        #expect(await recorder.refreshed == ["exact-chat"])
    }
    @Test func missingDestinationAndStaleSnapshotNeverAppendOrSend() async throws {
        let root = try fixture(destination: nil); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HumanReplyRecorder()
        let service = HumanConversationReplyService(dataRoot: root, sender: recorder,
            append: { _, _, _, _ in await recorder.recordAppend() })
        #expect(status(try await service.reply(input: input)) == "conversation_changed")
        var stale = input; stale["last_message_id"] = .string("older")
        #expect(status(try await service.reply(input: stale)) == "conversation_changed")
        #expect(await recorder.appends == 0)
        #expect(await recorder.deliveries.isEmpty)
    }
    @Test func uncertainTransportIsNeverReplayed() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HumanReplyRecorder(outcome: .ambiguous(reason: "connection_lost"))
        let service = HumanConversationReplyService(dataRoot: root, sender: recorder,
            append: { _, _, _, _ in await recorder.recordAppend() })
        let first = try await service.reply(input: input)
        #expect(status(first) != "completed")
        _ = try await service.reply(input: input)
        #expect(await recorder.appends == 1)
        #expect(await recorder.deliveries.count == 1)
    }
    @Test func activeConversationUsesNormalReply() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HumanReplyRecorder()
        let service = HumanConversationReplyService(dataRoot: root, sender: recorder,
            append: { _, _, _, _ in await recorder.recordAppend() })
        let result = try await ChatToolSessionContext.$verifiedSessionId.withValue("exact-chat") {
            try await service.reply(input: input)
        }
        #expect(status(result) == "current_turn")
        #expect(await recorder.appends == 0)
    }
}

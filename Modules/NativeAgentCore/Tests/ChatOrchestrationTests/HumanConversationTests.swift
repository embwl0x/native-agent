import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
import DreamREMCycle
@testable import ChatOrchestration
import NativeAgentTestSupport

@Suite struct HumanConversationTests {
    private func fixture(surface: String = "telegram", agent: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("human-conversation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chat/messages"), withIntermediateDirectories: true)
        let rows: JSONValue = .array([.object(["id": .string("human"), "title": .string("A useful conversation"),
            "source": .string(surface), "transcriptGeneration": .int(3), "updatedAt": .string("2026-09-21")]),
            .object(["id": .string("bot"), "source": .string("bot")])])
        try rows.serializedData(pretty: false).write(to: root.appendingPathComponent("chat/sessions.json"))
        var envelope: [String: JSONValue] = ["surface": .string(surface), "destinationId": .string("123"), "threadId": .string("7")]
        if let agent { envelope["agent"] = .string(agent) }
        let message: JSONValue = .object(["id": .string("last-1"), "role": .string("user"), "content": .string("How is the project?"),
            "createdAt": .string("2026-09-21T12:00:00Z"), "metadata": .object(["envelope": .object(envelope)])])
        var bytes = try message.serializedData(pretty: false); bytes.append(10)
        try bytes.write(to: root.appendingPathComponent("chat/messages/human.jsonl"))
        return root
    }
    @Test func exactConversationRetainsHumanDestinationAndVersion() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let read = try await HumanConversationReader.read(sessionID: "human", dataRoot: root)
        #expect(read.title == "A useful conversation")
        #expect(read.sourceRevision == "3")
        #expect(read.lastMessageID == "last-1")
        #expect(read.route?.replyRoute.destinationId == "123")
        #expect(read.route?.replyRoute.threadId == "7")
        #expect(HumanConversationReader.routeAvailable(read.route))
        #expect(try HumanConversationReader.rows(dataRoot: root).count == 1)
    }
    @Test func agentProvenanceNeverBecomesHumanReplyRoute() async throws {
        let root = try fixture(agent: "peer"); defer { try? FileManager.default.removeItem(at: root) }
        let read = try await HumanConversationReader.read(sessionID: "human", dataRoot: root)
        #expect(read.route == nil)
        #expect(!HumanConversationReader.routeAvailable(read.route))
    }
    @Test func corruptedTranscriptRetainsEvidenceButDisablesReply() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("chat/messages/human.jsonl")
        var bytes = try Data(contentsOf: path); bytes.append(Data("{broken\n".utf8)); try bytes.write(to: path)
        let read = try await HumanConversationReader.read(sessionID: "human", dataRoot: root)
        #expect(!read.complete)
        #expect(read.route == nil)
        #expect(try Data(contentsOf: path) == bytes)
    }
    @Test func invalidOrMissingExactSessionNeverFallsBack() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for id in ["../human", "missing", "bot"] {
            await #expect(throws: (any Error).self) { try await HumanConversationReader.read(sessionID: id, dataRoot: root) }
        }
    }
    @Test func canonicalAppendIsAssistantOnlyAndBindsDestinationEnvelope() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let llm = MockLLMClient(scriptedResponses: []), tools = MockToolDispatchClient()
        let client = SwiftNativeChatOrchestrationClient(engine: makeEngine(root: root, llm: llm, tools: tools),
            tools: tools, llm: llm, history: SessionHistoryReader(dataRoot: root), dataRoot: root)
        try await ChatToolSessionContext.$envelope.withValue(TurnEnvelope(surface: "chat", agent: "codex")) {
            try await client.appendHumanConversationReply(sessionID: "human", expectedLastMessageID: "last-1", text: "It is ready.", runID: "reply-1")
        }
        let read = try await HumanConversationReader.read(sessionID: "human", dataRoot: root)
        #expect(read.messages.map(\.role) == ["user", "assistant"])
        let metadata = HumanConversationReader.object(HumanConversationReader.object(read.messages.last?.extras)["metadata"])
        #expect(HumanConversationReader.object(metadata["envelope"])["destinationId"] == .string("123"))
        #expect(HumanConversationReader.object(metadata["envelope"])["agent"] == nil)
        await #expect(throws: (any Error).self) {
            try await client.appendHumanConversationReply(sessionID: "human", expectedLastMessageID: "last-1", text: "Duplicate", runID: "reply-2")
        }
    }
    @Test func canonicalTailCheckRefusesStaleWriteUnderOwnerLock() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let llm = MockLLMClient(scriptedResponses: []), tools = MockToolDispatchClient()
        let client = SwiftNativeChatOrchestrationClient(engine: makeEngine(root: root, llm: llm, tools: tools),
            tools: tools, llm: llm, history: SessionHistoryReader(dataRoot: root), dataRoot: root)
        await #expect(throws: (any Error).self) {
            try await client.appendMessage(sessionId: "human", role: "assistant", content: "Stale", runId: "stale", attachments: [], expectedLastMessageID: "old")
        }
        let read = try await HumanConversationReader.read(sessionID: "human", dataRoot: root)
        #expect(read.messages.count == 1)
    }
}

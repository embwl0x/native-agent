import Foundation
import Testing
@testable import ChatOrchestration

struct RetiredHelperTests {
    @Test func legacyAdviceIsNotDeliveredButOrdinaryDirectivesRemain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(ChatSessionDirective.recordURL(dataRoot: root, sessionID: "fixture"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let oldAdvice = ChatSessionDirectiveRecord(createdAt: timestamp, directive: "Retired advice", helperLane: "post_turn")
        try JSONEncoder().encode(oldAdvice).write(to: url)
        #expect(ChatSessionDirective.pendingDirective(dataRoot: root, sessionID: "fixture") == nil)
        let ordinary = ChatSessionDirectiveRecord(createdAt: timestamp, directive: "Continue the authorized task")
        try JSONEncoder().encode(ordinary).write(to: url)
        #expect(ChatSessionDirective.pendingDirective(dataRoot: root, sessionID: "fixture") == ordinary.directive)
        ChatSessionDirective.markDelivered(dataRoot: root, sessionID: "fixture")
        #expect(ChatSessionDirective.pendingDirective(dataRoot: root, sessionID: "fixture") == nil)
    }

    @Test func retiredToolIsNotAdvertisedEvenWithOldCredentialFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDirectory = root.appendingPathComponent("jev")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try Data("{\"api_key\":\"fixture-unused\"}".utf8).write(to: oldDirectory.appendingPathComponent("credential.json"))
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let tools = try await dispatcher.listAvailableTools()
        #expect(!tools.contains("second_opinion"))
        #expect(tools.contains("agent_introspect"))
    }
}

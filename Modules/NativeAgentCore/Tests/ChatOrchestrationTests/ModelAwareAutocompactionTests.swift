import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

@Suite("Model-aware chat autocompaction")
struct ModelAwareAutocompactionTests {
    @Test("global threshold is clamped to forty percent of model window")
    func thresholdClamp() {
        let config = ChatSessionAutocompactionConfig(thresholdTokens: 200_000)

        #expect(config.effectiveThresholdTokens(forModel: "claude-fable-5") == 200_000)
        #expect(config.effectiveThresholdTokens(forModel: "gpt-5.6-sol") == 148_800)
        #expect(config.effectiveThresholdTokens(forModel: "gpt-5.4") == 51_200)
    }

    @Test("small-window model compacts before a global threshold can exceed its window")
    func smallWindowCompacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-aware-compact-\(UUID().uuidString)", isDirectory: true)
        let sessionID = "small-window-session"
        let messagesPath = root
            .appendingPathComponent("chat/messages/\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: messagesPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var data = Data()
        for index in 0..<30 {
            let row: JSONValue = .object([
                "id": .string("message-\(index)"),
                "sessionId": .string(sessionID),
                "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                "content": .string("MESSAGE-\(index) " + String(repeating: "x", count: 8_000)),
                "createdAt": .string("2026-07-10T12:00:\(String(format: "%02d", index))Z"),
            ])
            data.append(Data((try row.serialize(pretty: false) + "\n").utf8))
        }
        try data.write(to: messagesPath, options: .atomic)

        let outcome = try await ChatSessionAutocompactor(
            dataRoot: root,
            config: ChatSessionAutocompactionConfig(
                thresholdTokens: 200_000,
                keepCount: 20,
                distillEnabled: false
            )
        ).compactIfNeeded(
            sessionId: sessionID,
            model: "gpt-5.4",
            surface: "chat",
            runId: "small-window-run"
        )

        #expect(outcome.compacted)
        #expect(outcome.thresholdTokens == 51_200)
        #expect(outcome.estimatedTokensBefore > outcome.thresholdTokens)
        #expect(outcome.messagesAfter < outcome.messagesBefore)
    }
}

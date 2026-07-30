import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Session context status", .serialized)
struct SessionContextStatusTests {
    @Test("provider receipt drives total context while transcript remains separately visible")
    func providerReceiptDrivesTotal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-context-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "context-status-session"
        let messagesPath = root.appendingPathComponent("chat/messages/\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: messagesPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var transcript = Data()
        for index in 0..<10 {
            let row: [String: Any] = [
                "id": "message-\(index)",
                "sessionId": sessionID,
                "role": index.isMultiple(of: 2) ? "user" : "assistant",
                "content": String(repeating: "x", count: 700),
                "createdAt": "2026-07-10T12:00:\(String(format: "%02d", index))Z",
            ]
            transcript.append(try JSONSerialization.data(withJSONObject: row))
            transcript.append(0x0A)
        }
        try transcript.write(to: messagesPath, options: .atomic)

        let receiptPath = root
            .appendingPathComponent("chat/session_state/\(sessionID)/provider_usage.json")
        try FileManager.default.createDirectory(
            at: receiptPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: [
            "schema": "session.provider_usage.v1",
            "sessionId": sessionID,
            "model": "claude-fable-5",
            "lastRequestInputTokens": 11_658,
            "previousTurnInputTokens": 11_100,
            "turnInputDeltaTokens": 558,
        ]).write(to: receiptPath, options: .atomic)

        let client = NativeClient(baseURL: "")
        let fable = try await client.getSessionContext(
            sessionId: sessionID,
            model: "claude-fable-5",
            dataRoot: root,
            configuredThresholdTokens: 200_000
        )
        #expect(fable.used_tokens == 11_658)
        #expect(fable.transcript_tokens == 2_000)
        #expect(fable.prompt_tokens == 9_658)
        #expect(fable.previous_turn_tokens == 11_100)
        #expect(fable.turn_delta_tokens == 558)
        #expect(fable.budget == 1_000_000)
        #expect(fable.auto_compact_threshold == 200_000)
        #expect(fable.context_loaded == true)
        #expect(fable.context_mode == "provider_receipt")
        #expect(!fable.compactable)

        let smallerModel = try await client.getSessionContext(
            sessionId: sessionID,
            model: "gpt-5.4",
            dataRoot: root,
            configuredThresholdTokens: 200_000
        )
        #expect(smallerModel.used_tokens == 1_750)
        #expect(smallerModel.transcript_tokens == 1_750)
        #expect(smallerModel.prompt_tokens == 0)
        #expect(smallerModel.budget == 128_000)
        #expect(smallerModel.auto_compact_threshold == 51_200)
        #expect(smallerModel.context_loaded == false)
        #expect(smallerModel.context_mode == "transcript_estimate")

        try JSONSerialization.data(withJSONObject: [
            "schema": "session.provider_usage.v1",
            "sessionId": sessionID,
            "model": "claude-fable-5",
            "lastRequestInputTokens": 1_200,
        ]).write(to: receiptPath, options: .atomic)
        let selectivelyLoaded = try await client.getSessionContext(
            sessionId: sessionID,
            model: "claude-fable-5",
            dataRoot: root,
            configuredThresholdTokens: 200_000
        )
        #expect(selectivelyLoaded.used_tokens == 1_200)
        #expect(selectivelyLoaded.transcript_tokens == 2_000)
        #expect(selectivelyLoaded.prompt_tokens == 0)
    }
}

import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ProviderRouting

@Suite("Session provider usage receipts")
struct SessionProviderUsageReceiptTests {
    @Test("logical input occupancy respects provider cache semantics")
    func logicalInputOccupancy() {
        let anthropic = LLMUsage(
            inputTokens: 2,
            outputTokens: 10,
            cacheReadInputTokens: 3_853,
            cacheCreationInputTokens: 7_803
        )
        #expect(anthropic.logicalInputTokens(provider: "anthropic_oauth_direct") == 11_658)

        let openAI = LLMUsage(
            inputTokens: 11_658,
            outputTokens: 10,
            cacheReadInputTokens: 3_853
        )
        #expect(openAI.logicalInputTokens(provider: "openai_oauth_direct") == 11_658)
        #expect(LLMUsage().logicalInputTokens(provider: "anthropic") == nil)
    }

    @Test("successful session call persists latest request occupancy")
    func persistsReceipt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-provider-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = LLMCallTraceRecorder(dataRootOverride: root)
        await LLMCallContext.$surface.withValue("chat") {
            await LLMCallContext.$sessionId.withValue("session-usage") {
                await TurnTraceContext.$turnId.withValue("turn-usage") {
                    await recorder.record(
                        provider: "anthropic_oauth_direct",
                        model: "claude-fable-5",
                        streaming: true,
                        usage: LLMUsage(
                            inputTokens: 2,
                            outputTokens: 247,
                            cacheReadInputTokens: 3_853,
                            cacheCreationInputTokens: 7_803
                        ),
                        ttftMs: 5_490,
                        durationMs: 9_325
                    )
                }
            }
        }

        let path = root
            .appendingPathComponent("chat/session_state/session-usage/provider_usage.json")
        let data = try Data(contentsOf: path)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["schema"] as? String == "session.provider_usage.v1")
        #expect(object["sessionId"] as? String == "session-usage")
        #expect(object["turnId"] as? String == "turn-usage")
        #expect(object["model"] as? String == "claude-fable-5")
        #expect(object["lastRequestInputTokens"] as? Int == 11_658)
        #expect(object["reportedInputTokens"] as? Int == 2)
        #expect(object["cacheReadInputTokens"] as? Int == 3_853)
        #expect(object["cacheCreationInputTokens"] as? Int == 7_803)

        await LLMCallContext.$surface.withValue("chat") {
            await LLMCallContext.$sessionId.withValue("session-usage") {
                await TurnTraceContext.$turnId.withValue("turn-next") {
                    await recorder.record(
                        provider: "anthropic_oauth_direct",
                        model: "claude-fable-5",
                        streaming: true,
                        usage: LLMUsage(inputTokens: 12_200, outputTokens: 100),
                        ttftMs: 100,
                        durationMs: 200
                    )
                    await recorder.record(
                        provider: "anthropic_oauth_direct",
                        model: "claude-fable-5",
                        streaming: true,
                        usage: LLMUsage(inputTokens: 13_000, outputTokens: 100),
                        ttftMs: 100,
                        durationMs: 200
                    )
                }
            }
        }

        let updatedData = try Data(contentsOf: path)
        let updatedObject = try #require(
            JSONSerialization.jsonObject(with: updatedData) as? [String: Any]
        )
        #expect(updatedObject["lastRequestInputTokens"] as? Int == 13_000)
        #expect(updatedObject["previousTurnInputTokens"] as? Int == 11_658)
        #expect(updatedObject["turnInputDeltaTokens"] as? Int == 1_342)
    }
}

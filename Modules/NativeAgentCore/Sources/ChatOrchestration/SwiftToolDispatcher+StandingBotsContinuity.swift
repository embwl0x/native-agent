import Foundation
import NativeAgentCore
import StandingBots
import ProviderRouting
import TrustCenter

/// Stateless adapters: no resident context, transcript, notification or memory sink.
public enum StandingBotContinuity {
    /// Reuse the existing in-flight mechanical compaction path, entirely in
    /// memory. No distiller call spends outside the bot's reserved run budget.
    public static let compact: BotContextCompactor = { notes, maximumBytes in
        var messages = [LLMMessage.assistantText(notes)]
        _ = await IntraTurnContextCompaction.compact(conversation: &messages,
            turnStartIndex: -1, windowTokens: max(1, maximumBytes / 4),
            keepRecentRounds: 0, pressure: .overflow, distill: { _ in nil })
        let rendered = IntraTurnContextCompaction.render(messages[...])
        // The helper measures characters; bot admission uses UTF-8 bytes.
        return String(decoding: rendered.utf8.suffix(max(0, maximumBytes - 3)), as: UTF8.self)
    }

    static func ask(dataRoot: URL, bot: UUID, question: String,
                    lifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
                    session: BotRunnerSession? = nil, admission: BotRunnerAdmission? = nil) async throws -> String {
        let provider = SwiftNativeLLMClient(router: SwiftNativeProviderRouting(dataRoot: dataRoot),
            codex: CodexAdapter(), anthropic: AnthropicAdapter(), openAI: OpenAIAdapter(),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(), anthropicOAuthDirect: AnthropicOAuthDirectAdapter(),
            lifecycleObserver: lifecycleObserver)
        let admission: BotRunnerAdmission = admission ?? {
            await StandingBotToolLoop.admitted(dataRoot: dataRoot, tool: "bot_ask")
        }
        let runner = BotRunner(dataRoot: dataRoot, session: session ?? { system, prompt, limit in
            try await provider.completeStandingBot(system: system, prompt: prompt, maxOutputTokens: limit,
                preRequestAdmission: {
                    do { guard try await admission() else { throw BotRunnerError.notPermitted } }
                    catch { throw BotRunnerError.notPermitted }
                })
        }, fetch: { _, _ in throw BotRunnerError.notPermitted }, admission: admission, compact: compact)
        return try await runner.ask(bot: bot, question: question)
    }
}

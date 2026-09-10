import Foundation
import StandingBots
import ProviderRouting

/// Adapter only: all history, recall, compaction, tools and approvals belong to
/// the ordinary chat client. No bot-owned conversational state is maintained.
public enum StandingBotContinuity {
    public static func session(client: SwiftNativeChatOrchestrationClient, dataRoot: URL) -> BotRunnerSession {
        { bot, message in
            // A bot with no model choice is a persistent sub-agent on the agent's own route.
            var choice: ProviderTurnChoice?
            if let provider = bot.provider, let model = bot.model, let effort = bot.reasoningEffort {
                choice = ProviderTurnChoice(provider: provider, model: model, reasoningEffort: effort, fast: bot.fast ?? false)
            }
            try await client.importBotHistory(bot: bot, dataRoot: dataRoot)
            // A text-only account hears the limitation before the brief, so the
            // answer leads with it instead of dressing remembered text as fresh
            // (Agent, 2026-09-10: appending the note did not make the reply honest).
            var message = message
            if let provider = bot.provider, !ProviderToolCapability.supportsTools(providerID: provider) {
                message = ProviderToolCapability.textOnlyTurnPreface + "\n\n" + message
            }
            let response = try await client.chat(message: message, sessionId: bot.sessionID,
                choice: choice, tokenLimit: bot.budget.tokens, surface: "bot")
            return BotTurnReply(reply: response.output,
                artifacts: (response.attachments ?? []).map { attachment in
                    var artifact = BotArtifact(name: attachment.name ?? "Artifact", path: attachment.path ?? "")
                    artifact.type = attachment.type; artifact.mime = attachment.mime
                    artifact.base64 = attachment.base64.isEmpty ? nil : attachment.base64
                    artifact.byteSize = attachment.byteSize
                    return artifact
                }, status: BotRunStatus(rawValue: response.runtimeStatus ?? "completed") ?? .failed,
                detail: response.statusDetail)
        }
    }
}

extension SwiftNativeChatOrchestrationClient {
    func importBotHistory(bot: BotDefinition, dataRoot: URL) async throws {
        let path = dataRoot.appendingPathComponent("chat/messages/" + bot.sessionID + ".jsonl")
        for item in try ShelfStore(dataRoot: dataRoot).legacyHistory(bot: bot.id, dataRoot: dataRoot) {
            if await Self.sessionAlreadyHasAssistantMessage(path: path, runId: item.id) { continue }
            try await appendMessage(sessionId: bot.sessionID, role: "assistant", content: item.text,
                runId: item.id, attachments: item.artifacts.map {
                    MultimodalAttachment(type: "file", base64: "", mime: "application/json", name: $0.name, byteSize: 0, path: $0.path)
                }, source: "bot")
        }
    }
}

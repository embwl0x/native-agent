import Foundation
import StandingBots
import ProviderRouting

/// Adapter only: all history, recall, compaction, tools and approvals belong to
/// the ordinary chat client. No bot-owned conversational state is maintained.
public enum StandingBotContinuity {
    public static func session(client: SwiftNativeChatOrchestrationClient, dataRoot: URL) -> BotRunnerSession {
        { bot, message in
            // A bot runs on the tuple it was made with, never the agent's route
            // (2026-09-13 review): building NO choice here is exactly what sent
            // such a turn to Chat's model. The runner already refuses a bot with
            // no usable tuple; this is the second line of the same rule, so no
            // path into a bot turn can invent a route.
            if let problem = bot.modelChoiceProblem {
                throw StandingBotsError.invalidValue(
                    "\(bot.name) has no model chosen: \(problem)"
                )
            }
            let choice = ProviderTurnChoice(
                provider: bot.provider ?? "", model: bot.model ?? "",
                reasoningEffort: bot.reasoningEffort ?? "", fast: bot.fast ?? false
            )
            try await client.importBotHistory(bot: bot, dataRoot: dataRoot)
            // A text-only account hears the limitation before the brief, so the
            // answer leads with it instead of dressing remembered text as fresh
            // (Agent, 2026-09-10: appending the note did not make the reply honest).
            var message = message
            if let provider = bot.provider, !ProviderToolCapability.supportsTools(providerID: provider) {
                message = ProviderToolCapability.textOnlyTurnPreface + "\n\n" + message
            }
            // A BOT'S RUN IS NOT HER MOMENT, live as well as imported (Agent,
            // item 5, 2026-09-14). The brief that starts this turn and the
            // reply it produces are both the bot's machinery, so the kind is
            // carried through the invocation to both automatic transcript
            // writes. Carried, not inferred from `surface`: a person steering
            // into a bot session arrives on the same surface, and what she
            // hears from a person stays appraisable.
            let response = try await client.chat(message: message, sessionId: bot.sessionID,
                choice: choice, tokenLimit: bot.budget.tokens, surface: "bot",
                mechanicalRow: .botReceipt)
            return BotTurnReply(reply: response.output,
                artifacts: (response.attachments ?? []).map { attachment in
                    var artifact = BotArtifact(name: attachment.name ?? "Artifact", path: attachment.path ?? "")
                    artifact.type = attachment.type; artifact.mime = attachment.mime
                    artifact.base64 = attachment.base64.isEmpty ? nil : attachment.base64
                    artifact.byteSize = attachment.byteSize
                    return artifact
                }, status: BotRunStatus(rawValue: response.runtimeStatus ?? "completed") ?? .failed,
                detail: response.statusDetail, model: response.model,
                approvalID: response.pendingApprovalID)
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
                }, source: "bot",
                // A BOT'S RECEIPT IS NOT HER MOMENT (Agent, item 5, 2026-09-14).
                // These rows are the shelf's stored bot output replayed into a
                // session verbatim — text a bot produced, on a past run, filed
                // on her row. Importing history is bookkeeping; it is not a
                // week's worth of things she just felt.
                mechanicalRow: .botReceipt)
        }
    }
}

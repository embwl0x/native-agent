import Foundation
import ChatTurnContracts
import StandingBots
import ProviderRouting

/// Adapter only: all history, recall, compaction, tools and approvals belong to
/// the ordinary chat client. No bot-owned conversational state is maintained.
public enum StandingBotContinuity {
    @TaskLocal public static var currentBot: BotDefinition?
    @TaskLocal static var currentContract: BotChatContract?

    static var isHelperTurn: Bool { currentBot != nil || currentContract != nil }

    static func withSessionContract<T>(
        sessionID: String?, dataRoot: URL, isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async throws -> T {
        let sessionID = try SwiftNativeChatOrchestrationClient.resolveSessionId(sessionID)
        guard currentBot == nil,
              let contract = await BotChatContract.checked(sessionID, dataRoot: dataRoot) else {
            return try await operation()
        }
        if let problem = contract.modelChoiceProblem {
            throw ChatOrchestrationError.helperModelChoice(
                sessionID: sessionID, reason: problem,
                message: "\(contract.name) can't run yet. \(problem) Choose its account, model and Think level on its helper card on the Mac. Nothing was started, and its unfinished work is kept.")
        }
        return try await $currentContract.withValue(contract) {
            try await ProviderTurnChoice.$current.withValue(contract.choice, operation: operation)
        }
    }

    public static func session(client: SwiftNativeChatOrchestrationClient, dataRoot: URL) -> BotRunnerSession {
        { bot, message in
            try await $currentBot.withValue(bot) {
            try await TurnAdmission.shared.run(sessionID: bot.sessionID) {
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
            // A first conversation need not be preceded by Run once. Reattach
            // the current saved brief on every turn so first asks and edited
            // jobs receive their instructions without replaying a prior run.
            // This stays in the ordinary session; there is no second memory.
            var message = BotChatContract.instructions(for: bot)
                + "\n\nMessage for this turn:\n" + message
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
            let response: ChatResponse
            if let event = BotRunQueue.eventProvenance {
                let source = event.source?.rawValue ?? "remote"
                response = try await PeerDataTaint.withScope {
                    PeerDataTaint.markConsumed(
                        peer: event.verifiedUserID.map { source + ":" + $0 } ?? "an event with no recorded sender",
                        line: BotRunQueue.eventContext ?? "")
                    let envelope = TurnEnvelope(
                        surface: source,
                        verifiedChatId: event.verifiedChatID,
                        verifiedUserId: event.verifiedUserID,
                        declaredRemote: true)
                    return try await ChatToolSessionContext.$envelope.withValue(envelope) {
                        try await client.chat(message: message, sessionId: bot.sessionID,
                            choice: choice, tokenLimit: bot.budget.tokens, surface: "bot",
                            mechanicalRow: .botReceipt)
                    }
                }
            } else {
                response = try await client.chat(message: message, sessionId: bot.sessionID,
                    choice: choice, tokenLimit: bot.budget.tokens, surface: "bot",
                    mechanicalRow: .botReceipt)
            }
            return reply(response)
            }
            }
        }
    }

    public static func reply(_ response: ChatResponse) -> BotTurnReply {
        BotTurnReply(reply: response.output,
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

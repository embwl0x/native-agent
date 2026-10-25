import Foundation
import ChatTurnContracts
import StandingBots
import ProviderRouting
import PersistenceCore
import Transcripts
import NativeAgentShared
// Blueprint: | `StandingBotContinuity.swift` | Helper ingress routes to StandingBots' own turn runner; checked session creation and legacy shelf import retain the existing transcript format |

/// Helper ingress and transcript adapters; the resident's turn engine is never called.
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
                message: "\(contract.name) can't run yet. \(problem) Nothing was started, and its unfinished work is kept.")
        }
        return try await $currentContract.withValue(contract) {
            try await ProviderTurnChoice.$current.withValue(contract.choice, operation: operation)
        }
    }

    /// Opens the checked helper session, retaining a row that a first turn created concurrently.
    public static func openSession(for bot: BotDefinition, dataRoot: URL) async throws -> NativeAgentShared.ChatSession {
        let path = dataRoot.appendingPathComponent("chat/sessions.json")
        let row = try await ChatSessionIndexFile.mutate(at: path) { rows in
            if let existing = rows.first(where: { row in
                guard case .string(let id)? = row["id"] else { return false }
                return id == bot.sessionID
            }) {
                return existing
            }
            rows.append([
                "id": .string(bot.sessionID), "title": .string(bot.name), "source": .string("bot"),
                "createdAt": .string(ISO8601DateFormatter().string(from: bot.createdAt)),
                "archived": .bool(false), "messageCount": .int(0)
            ])
            return rows[rows.count - 1]
        }
        return try NativeAgentShared.ChatSession(row: row)
    }

    public static func session(client: SwiftNativeChatOrchestrationClient, dataRoot: URL, admitted: Bool = false,
                               attachments: [MultimodalAttachment] = [], fileAccess: String = "auto",
                               progress: ChatOrchestrationProgressHandler? = nil) -> BotRunnerSession {
        { bot, message in
            try await $currentBot.withValue(bot) {
            let run: @Sendable () async throws -> BotTurnReply = {
            let choice = try await BotChatContract.choice(for: bot, dataRoot: dataRoot)
            try await client.importBotHistory(bot: bot, dataRoot: dataRoot)
            if let event = BotRunQueue.eventProvenance {
                let source = event.source?.rawValue ?? "remote"
                let envelope = TurnEnvelope(
                    surface: source,
                    verifiedChatId: event.verifiedChatID,
                    verifiedUserId: event.verifiedUserID,
                    declaredRemote: true)
                return try await ChatToolSessionContext.$envelope.withValue(envelope) {
                    try await client.runStandingBot(bot, message: message, choice: choice,
                        attachments: attachments, fileAccess: fileAccess, runID: admitted ? ChatPersistenceContext.pinnedTurnRunID : nil,
                        progress: progress)
                }
            }
            return try await client.runStandingBot(bot, message: message, choice: choice,
                attachments: attachments, fileAccess: fileAccess, runID: admitted ? ChatPersistenceContext.pinnedTurnRunID : nil,
                progress: progress)
            }
            return try await BotRunQueue.$ancestry.withValue(BotRunQueue.ancestry.union([bot.id])) {
                if admitted {
                    return try await BotRunnerDeadline.settled(seconds: bot.budget.seconds, onDeadline: {}, body: run)
                }
                return try await TurnAdmission.shared.run(sessionID: bot.sessionID, operation: run)
            }
            }
        }
    }

    public static func response(_ reply: BotTurnReply, sessionID: String, runID: String) -> ChatResponse {
        let state: TurnEngineResult.TerminalState = switch reply.status {
        case .completed: .completed
        case .stopped: .stopped
        case .interrupted: .interrupted
        case .failed: .failed
        case .waitingForApproval, .waitingOnPerson: .waiting
        }
        var response = ChatResponse(runId: runID, model: reply.model ?? "", output: reply.reply, sessionId: sessionID,
            attachments: reply.artifacts.map {
                MultimodalAttachment(type: $0.type ?? "file", base64: $0.base64 ?? "", mime: $0.mime ?? "application/octet-stream",
                    name: $0.name, byteSize: $0.byteSize ?? 0, path: $0.path)
            }, terminalState: state)
        response.runtimeStatus = reply.status.rawValue
        response.statusDetail = reply.detail
        response.pendingApprovalID = reply.approvalID
        return response
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

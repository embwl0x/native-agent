import Foundation
import NativeAgentCore
import ChatTurnContracts
import StandingBots
import ProviderRouting
import PersistenceCore
import Transcripts
import NativeAgentShared
import TurnTrace
// Blueprint: | `StandingBotContinuity.swift` | Helper-owned ingress and exact session ownership |

/// Helper ingress uses its own turn engine; transcript adaptation must not invoke the resident engine.
public enum StandingBotContinuity {

    static func isHelperTurn(turn: Turn) -> Bool { turn.standingBot != nil || turn.botContract != nil }

    static func withSessionContract<T>(
        sessionID: String?, dataRoot: URL, turn: Turn, isolation: isolated (any Actor)? = #isolation,
        operation: (Turn) async throws -> T
    ) async throws -> T {
        let sessionID = try SwiftNativeChatOrchestrationClient.resolveSessionId(sessionID)
        guard turn.standingBot == nil,
              let contract = try await BotChatContract.checked(sessionID, dataRoot: dataRoot) else {
            return try await operation(turn)
        }
        if let problem = contract.modelChoiceProblem {
            throw ChatOrchestrationError.helperModelChoice(
                sessionID: sessionID, reason: problem,
                message: "\(contract.name) can't run yet. \(problem) Nothing was started, and its unfinished work is kept.")
        }
        return try await operation(turn.with(\.botContract, contract).with(\.providerChoice, contract.choice))
    }

    /// Opens the checked helper session, retaining a row that a first turn created concurrently.
    public static func openSession(for bot: BotDefinition, dataRoot: URL) async throws -> NativeAgentShared.ChatSession {
        let path = dataRoot.appendingPathComponent("chat/sessions.json")
        let row = try await ChatSessionIndexFile.mutate(at: path) { rows in
            if !rows.contains(where: { $0["id"] == .string(bot.sessionID) }),
               let restored = try await ChatSessionRetention.restoreArchivedRow(sessionId: bot.sessionID, dataRoot: dataRoot) {
                rows.append(restored)
            }
            if let index = rows.firstIndex(where: { row in
                guard case .string(let id)? = row["id"] else { return false }
                return id == bot.sessionID
            }) {
                rows[index]["threadKind"] = .string(ChatThreadKind.agent.rawValue)
                rows[index]["helperID"] = .string(bot.id.uuidString)
                return rows[index]
            }
            let created: [String: JSONValue] = [
                "id": .string(bot.sessionID), "title": .string(bot.name), "source": .string("bot"),
                "threadKind": .string(ChatThreadKind.agent.rawValue),
                "helperID": .string(bot.id.uuidString),
                "createdAt": .string(ISO8601DateFormatter().string(from: bot.createdAt)),
                "archived": .bool(false), "messageCount": .int(0),
                ChatSessionIndexFile.transcriptGenerationKey: .int(0)
            ]
            rows.append(created)
            return created
        }
        return try NativeAgentShared.ChatSession(row: row)
    }

    public static func session(client: SwiftNativeChatOrchestrationClient, dataRoot: URL, admitted: Bool = false,
                               attachments: [MultimodalAttachment] = [], fileAccess: String = "auto",
                               progress: TurnEventSink? = nil, work: ChatTurnWork = .init()) -> BotRunnerSession {
        { bot, message, turn, scope, options in
            try await holding(turn.with(\.standingBot, bot)) { turn in
            let run: @Sendable (Turn, ChatTurnWork) async throws -> BotTurnReply = { turn, work in
            let choice = try await BotChatContract.choice(for: bot, dataRoot: dataRoot)
            _ = try await openSession(for: bot, dataRoot: dataRoot)
            if let event = turn.botEventProvenance {
                let source = event.source?.rawValue ?? "remote"
                let envelope = TurnEnvelope(
                    surface: source,
                    verifiedChatId: event.verifiedChatID,
                    verifiedUserId: event.verifiedUserID,
                    declaredRemote: true)
                return try await holding(turn.with(\.envelope, envelope)) { turn in
                    try await client.runStandingBot(bot, message: message, choice: choice,
                        attachments: attachments, fileAccess: fileAccess, runID: admitted ? turn.run : nil,
                        progress: progress, turn: turn, work: work)
                }
            }
            // A direct native helper run owns its explicit origin; nested runs
            // retain the authenticated turn that invoked them.
            let origin = turn.envelope ?? .native("helper:" + bot.id.uuidString)
            return try await holding(turn.with(\.envelope, origin)) { turn in
            try await client.runStandingBot(bot, message: message, choice: choice,
                attachments: attachments, fileAccess: fileAccess, runID: admitted ? turn.run : nil,
                progress: progress, turn: turn, work: work)
            }
            }
            return try await holding(work.with(\.botAncestry, scope.entering(bot.id).ancestry).with(\.botOptions, options)) { work in
                if admitted {
                    return try await BotRunnerDeadline.settled(seconds: bot.budget.seconds, onDeadline: {}, body: { try await run(turn, work) })
                }
                // A helper's loop is its own work in its own conversation; it never joins another turn.
                return try await TurnAdmission.shared.runAlone(dataRoot: dataRoot, sessionID: bot.sessionID, turn: turn,
                    operation: { turn in try await run(turn, work) })
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

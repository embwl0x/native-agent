import Foundation
import ChatTurnRuntime
import NativeAgentCore
import TurnTrace
// Blueprint: | `TelegramPollLoop+SessionDelivery.swift` | Resolve bound destinations and join previews before journal recovery |

extension TelegramPollLoop {
    public func sessionDelivery(_ context: SessionTurnDelivery.Context, turn: Turn) async throws -> SessionTurnDelivery.Recipient? {
        guard context.dataRoot.standardizedFileURL == dataRoot.standardizedFileURL else { return nil }
        guard let route = context.route, route.surface == "telegram",
              let raw = route.destinationId, let chat = Int(raw),
              route.threadId == nil || route.threadId.flatMap(Int.init) != nil,
              Self.inboundAuthorizationDecision(allowedChatIds: allowedChatIds, allowedUserIds: allowedUserIds,
                chatId: chat, fromUserId: route.requesterUserId.flatMap(Int.init)) == .allowed else {
            throw TelegramBotError.invalidRequest
        }
        let destination = TelegramDestination(chatId: chat, threadId: route.threadId.flatMap(Int.init))
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
        let existing = try await inbox.snapshots().first {
            $0.assistantSessionId == context.sessionID && $0.assistantRunId == context.runID
        }
        let updateID = existing?.updateId ?? TelegramUpdateInbox.replyUpdateID(runId: context.runID)
        guard await turnCoordinator.claimUpdateProcessing(updateID) else { return nil }
        do {
        let claim: TelegramUpdateClaim
        if let existing { claim = existing }
        else {
            // No finished answer is invented here. previewPending keeps recovery waiting for the canonical transcript, even if no delta ever arrives.
            var pending = TelegramAssistantDeliveryState(reply: "")
            pending.previewPending = true
            claim = try await inbox.reserveReply(runId: context.runID, sessionId: context.sessionID,
                destination: destination, delivery: pending, priorVerdict: nil,
                fromUserId: route.requesterUserId.flatMap(Int.init))
        }
        guard claim.quarantineReason == nil, claim.update.message?.destination == destination,
              claim.phase == .processing || claim.phase == .outcomeUnknown,
              claim.settledAssistantRuns[context.runID] == nil else {
            await turnCoordinator.endUpdateProcessing(updateID)
            return nil
        }
        let driver = makeAssistantDelivery(destination: destination,
            draftKey: turn.id, turn: turn,
            errorContext: "session_stream", update: claim.update, message: claim.update.message, text: nil,
            savedDelivery: claim.assistantDelivery)
        return .init(progress: { event in
            if case .delta(let text) = event { await driver.onDelta(text) }
        }, finish: {
            await driver.stop()
            await turnCoordinator.endUpdateProcessing(updateID)
            do {
                if let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot,
                    sessionId: context.sessionID, runId: context.runID) {
                    _ = try await recoverReply(response, originRunId: context.runID, destination: destination,
                        requesterUserId: route.requesterUserId.flatMap(Int.init))
                }
            } catch {
                await recordError(context: "session_reply", error: String(describing: error))
            }
        })
        } catch {
            await turnCoordinator.endUpdateProcessing(updateID)
            throw error
        }
    }
}

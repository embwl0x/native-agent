import Foundation
import ChatTurnRuntime
import NativeAgentCore
// Blueprint: | `SlackSocketModeLoop+SessionDelivery.swift` | Journal previews; final recovery joins the preview writer before updating its message |

extension SlackSocketModeLoop {
    public func sessionDelivery(_ context: SessionTurnDelivery.Context) async throws -> SessionTurnDelivery.Recipient? {
        guard context.dataRoot.standardizedFileURL == dataRoot.standardizedFileURL else { return nil }
        guard let route = context.route, route.surface == "slack",
              let channel = route.destinationId, !channel.isEmpty,
              config.allowedChannelIds.contains(channel) || route.requesterUserId.map(config.allowedUserIds.contains) == true else {
            throw SlackInboundJournalError.malformed
        }
        let existing = try await deliveryJournal.answerRecord(runId: context.runID, originRunId: context.runID)
        let inbound: SlackInboundMessage
        if let existing {
            guard existing.assistantSessionId == context.sessionID,
                  existing.inbound.channelId == channel, existing.inbound.replyThreadTs == route.threadId,
                  existing.phase == .generating else { return nil }
            inbound = existing.inbound
        } else {
            inbound = SlackInboundMessage(eventId: "answer:" + context.runID, teamId: config.teamId ?? "",
                channelId: channel, userId: route.requesterUserId ?? "", eventType: "answer", text: "",
                ts: "", threadTs: route.threadId, channelType: nil,
                isDirectMessage: channel.hasPrefix("D"), files: [], opensReplyThread: false)
        }
        guard await deliveryJournal.acquireHandler(eventId: inbound.eventId) else { return nil }
        do {
        if existing == nil {
            _ = try await deliveryJournal.claim(inbound)
            _ = try await deliveryJournal.beginGeneration(eventId: inbound.eventId, runId: context.runID,
                sessionId: context.sessionID)
        }
        let preview = replyPreview(for: inbound, sessionId: context.sessionID)
        return .init(progress: noticeSink(for: inbound, preview: preview), finish: {
            await preview.finish()
            await deliveryJournal.releaseHandler(eventId: inbound.eventId)
            do {
                if let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot,
                    sessionId: context.sessionID, runId: context.runID) {
                    _ = try await recoverReply(response, originRunId: context.runID)
                }
            } catch { await recordError(context: "session_reply", error: error, inbound: inbound) }
        })
        } catch {
            await deliveryJournal.releaseHandler(eventId: inbound.eventId)
            throw error
        }
    }
}

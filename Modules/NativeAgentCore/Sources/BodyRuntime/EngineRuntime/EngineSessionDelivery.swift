import SenseCore
import Foundation
import NativeAgentCore
import DeskCore
// Blueprint: | `EngineSessionDelivery.swift` | Bound-route reply delivery through canonical transcript and transport journals |

extension NativeAgentEngine {
    static func makeSessionDelivery(deviceSync: DeviceSync?, turns: TurnsFacade,
                                    transcripts: TranscriptsFacade) -> SessionTurnDelivery.Resolver? {
        guard let deviceSync else { return nil }
        return { [weak deviceSync, weak turns, weak transcripts] context, turn in
            guard let deviceSync, let turns, let transcripts else { return nil }
            let surface = ConversationSurfaceProfile(context.surface)
            if surface.isIOSRemote {
                guard deviceSync.dataRoot.standardizedFileURL == context.dataRoot.standardizedFileURL else { return nil }
                return try await deviceSync.bridge.sessionDelivery(context)
            }
            switch surface.id {
            case "telegram":
                guard let loop = await BackgroundLoopLifetimes.shared.loopRunner(loopId: "telegram_poll") as? TelegramPollLoop,
                      loop.dataRoot.standardizedFileURL == context.dataRoot.standardizedFileURL else { return nil }
                return try await loop.sessionDelivery(context, turn: turn)
            case "slack":
                guard let loop = await BackgroundLoopLifetimes.shared.loopRunner(loopId: "slack_socket_mode") as? SlackSocketModeLoop,
                      loop.dataRoot.standardizedFileURL == context.dataRoot.standardizedFileURL else { return nil }
                return try await loop.sessionDelivery(context)
            case "chat":
                let reply = await MacSessionReply(turns: turns, transcripts: transcripts, sessionID: context.sessionID, runID: context.runID)
                return .init(progress: { await reply.receive($0) }, finish: { await reply.finish() })
            default: return nil
            }
        }
    }
}

/// Turns from other surfaces must stream into the same mounted transcript.
@MainActor
private final class MacSessionReply {
    let turns: TurnsFacade
    let transcripts: TranscriptsFacade
    let sessionID: String
    let runID: String
    var bubble: String?
    var text = ""

    init(turns: TurnsFacade, transcripts: TranscriptsFacade, sessionID: String, runID: String) {
        self.turns = turns
        self.transcripts = transcripts
        self.sessionID = sessionID
        self.runID = runID
    }

    func receive(_ event: TurnStreamEvent) {
        guard case .delta(let delta) = event, !delta.isEmpty else { return }
        if bubble == nil {
            let row = ChatMessage(sessionId: sessionID, runId: runID)
            bubble = row.id
            transcripts.appendMessage(row, to: sessionID)
            turns.streamingSessions.insert(sessionID)
            turns.setStreamingBubbleID(row.id, for: sessionID)
        }
        text += delta
        turns.streamingTexts[sessionID] = text
        if let bubble { transcripts.updateMessageContent(id: bubble, in: sessionID, content: text) }
    }

    func finish() async {
        func releasePresentation() {
            if let bubble, turns.streamingBubbleID(for: sessionID) == bubble {
                turns.streamingSessions.remove(sessionID)
                turns.setStreamingBubbleID(nil, for: sessionID)
                turns.streamingTexts[sessionID] = nil
            }
        }
        defer {
            releasePresentation()
            // Once this read lands, stop leading with a live bubble over the saved or newer reply.
            if let bubble { transcripts.settleLive(sessionID, only: bubble) }
        }
        // Replace spoken text only after reading its canonical replacement; failures retain the partial and error receipt.
        do {
            let rows = try await transcripts.loadMessages(sessionId: sessionID, cached: false)
            let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rows.contains(where: { $0.runId == runID && $0.role == "assistant"
                && (shown.isEmpty || $0.content.contains(shown)) }) else { return }
            releasePresentation()
            // Remove the differently identified live bubble only after publishing the saved reply.
            if let bubble { transcripts.removeMessage(id: bubble, from: sessionID) }
        } catch {
            nativeLog("Session reply is saved but its Mac view could not reload: %@", error.localizedDescription)
        }
    }
}

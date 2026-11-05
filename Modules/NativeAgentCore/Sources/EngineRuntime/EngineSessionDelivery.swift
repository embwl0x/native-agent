import BackgroundLoops
import ChatTurnRuntime
import DeviceSync
import Foundation
import NativeAgentCore
import SlackBot
import TelegramBot
import TrustCenter
// Blueprint: | `EngineSessionDelivery.swift` | Bound-route reply delivery through canonical transcript and transport journals |

extension NativeAgentEngine {
    func installSessionDelivery() {
        guard hasBody else { return }
        SessionTurnDelivery.install(dataRoot: dataRoot) { [weak self] context, turn in
            guard let self else { return nil }
            let surface = ConversationSurfaceProfile(context.surface)
            if surface.isIOSRemote {
                guard let sync = self.deviceSync else { return nil }
                return try await sync.bridge.sessionDelivery(context)
            }
            switch surface.id {
            case "telegram":
                guard let loop = await BackgroundLoopLifetimes.shared.loopRunner(loopId: "telegram_poll") as? TelegramPollLoop else { return nil }
                return try await loop.sessionDelivery(context, turn: turn)
            case "slack":
                guard let loop = await BackgroundLoopLifetimes.shared.loopRunner(loopId: "slack_socket_mode") as? SlackSocketModeLoop else { return nil }
                return try await loop.sessionDelivery(context)
            case "chat":
                let reply = await MacSessionReply(engine: self, sessionID: context.sessionID, runID: context.runID)
                return .init(progress: { await reply.receive($0) }, finish: { await reply.finish() })
            default: return nil
            }
        }
    }
}

/// Turns from other surfaces must stream into the same mounted transcript.
@MainActor
private final class MacSessionReply {
    let engine: NativeAgentEngine
    let sessionID: String
    let runID: String
    var bubble: String?
    var text = ""

    init(engine: NativeAgentEngine, sessionID: String, runID: String) {
        self.engine = engine; self.sessionID = sessionID; self.runID = runID
    }

    func receive(_ event: TurnStreamEvent) {
        guard case .delta(let delta) = event, !delta.isEmpty else { return }
        if bubble == nil {
            let row = ChatMessage(sessionId: sessionID, runId: runID)
            bubble = row.id
            engine.transcripts.appendMessage(row, to: sessionID)
            engine.turns.streamingSessions.insert(sessionID)
            engine.turns.streamingBubbleIds[sessionID] = row.id
        }
        text += delta
        engine.turns.streamingTexts[sessionID] = text
        if let bubble { engine.transcripts.updateMessageContent(id: bubble, in: sessionID, content: text) }
    }

    func finish() async {
        func releasePresentation() {
            if let bubble, engine.turns.streamingBubbleIds[sessionID] == bubble {
                engine.turns.streamingSessions.remove(sessionID)
                engine.turns.streamingBubbleIds[sessionID] = nil
                engine.turns.streamingTexts[sessionID] = nil
            }
        }
        defer {
            releasePresentation()
            // Once this read lands, stop leading with a live bubble over the saved or newer reply.
            if let bubble { engine.transcripts.settleLive(sessionID, only: bubble) }
        }
        // Replace spoken text only after reading its canonical replacement; failures retain the partial and error receipt.
        do {
            let rows = try await engine.transcripts.loadMessages(sessionId: sessionID, cached: false)
            let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rows.contains(where: { $0.runId == runID && $0.role == "assistant"
                && (shown.isEmpty || $0.content.contains(shown)) }) else { return }
            releasePresentation()
            // Remove the differently identified live bubble only after publishing the saved reply.
            if let bubble { engine.transcripts.removeMessage(id: bubble, from: sessionID) }
        } catch {
            nativeLog("Session reply is saved but its Mac view could not reload: %@", error.localizedDescription)
        }
    }
}

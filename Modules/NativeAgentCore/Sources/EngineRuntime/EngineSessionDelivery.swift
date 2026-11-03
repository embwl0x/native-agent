import BackgroundLoops
import ChatTurnRuntime
import DeviceSync
import Foundation
import NativeAgentCore
import SlackBot
import TelegramBot
import TrustCenter
// Blueprint: | `EngineSessionDelivery.swift` | Resident root resolves a session's delivery from its bound route and live surface owner; unmounted Mac turns draw through the canonical transcript facade, Telegram/Slack reuse their durable journals, and phone continuations use the phone bridge |

extension NativeAgentEngine {
    func installSessionDelivery() {
        guard hasBody else { return }
        SessionTurnDelivery.install(dataRoot: dataRoot) { [weak self] context in
            guard let self else { return nil }
            let surface = ConversationSurfaceProfile(context.surface)
            if surface.isIOSRemote {
                guard let sync = self.deviceSync else { return nil }
                return await sync.bridge.sessionDelivery(context)
            }
            switch surface.id {
            case "telegram":
                guard let loop = await BackgroundLoopLifetimes.shared.loopRunner(loopId: "telegram_poll") as? TelegramPollLoop else { return nil }
                return try await loop.sessionDelivery(context)
            case "slack":
                guard let loop = await BackgroundLoopLifetimes.shared.loopRunner(loopId: "slack_socket_mode") as? SlackSocketModeLoop else { return nil }
                return try await loop.sessionDelivery(context)
            case "chat", "app", "mac":
                let reply = await MacSessionReply(engine: self, sessionID: context.sessionID, runID: context.runID)
                return .init(progress: { await reply.receive($0) }, finish: { await reply.finish() })
            default: return nil
            }
        }
    }
}

/// Ordinary Mac sends already have a mounted stream. A turn started elsewhere
/// in that session draws on the very same transcript while it is being written.
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
            // Whatever this read proved, the bubble stops leading: it gives way to its saved reply or a newer one.
            if let bubble { engine.transcripts.settleLive(sessionID, only: bubble) }
        }
        // Do not remove spoken text unless its canonical replacement was read.
        // A failed read leaves the visible partial and the failure's own receipt.
        do {
            let rows = try await engine.transcripts.loadMessages(sessionId: sessionID, cached: false)
            let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rows.contains(where: { $0.runId == runID && $0.role == "assistant"
                && (shown.isEmpty || $0.content.contains(shown)) }) else { return }
            releasePresentation()
            // The read just published the saved reply; its live bubble (another id) leaves.
            if let bubble { engine.transcripts.removeMessage(id: bubble, from: sessionID) }
        } catch {
            nativeLog("Session reply is saved but its Mac view could not reload: %@", error.localizedDescription)
        }
    }
}

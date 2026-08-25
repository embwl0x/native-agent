import Foundation
import SwiftUI

/// The state transition behind the Voice Auto-Read setting. Keeping the
/// decision separate from the speaker prevents SwiftUI re-renders from
/// changing what "new reply" means and makes every refusal inspectable.
enum ChatVoiceAutoReadGate {
    enum Decision: Equatable {
        case speak(messageID: String, text: String)
        case disabled
        case unprimedSession
        case noMessage
        case messageFromAnotherSession
        case notAssistant
        case emptyReply
        case alreadyRead
    }

    static func decide(
        enabled: Bool,
        sessionID: String,
        isSessionPrimed: Bool,
        lastMessage: ChatMessage?,
        lastReadMessageID: String?
    ) -> Decision {
        guard enabled else { return .disabled }
        guard isSessionPrimed else { return .unprimedSession }
        guard let lastMessage else { return .noMessage }

        let cleanSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSessionID.isEmpty else { return .messageFromAnotherSession }
        if let messageSessionID = lastMessage.sessionId {
            guard messageSessionID.trimmingCharacters(in: .whitespacesAndNewlines) == cleanSessionID else {
                return .messageFromAnotherSession
            }
        }
        guard lastMessage.role == "assistant" else { return .notAssistant }
        let text = lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .emptyReply }
        guard lastMessage.id != lastReadMessageID else { return .alreadyRead }
        return .speak(messageID: lastMessage.id, text: text)
    }
}

extension ChatView {
    func showToast(_ s: String) {
        ChatComposerBottomToastPresentation.show(s, in: toasts)
    }

    func rename() {
        renameActiveChatTitle(renameTitle)
    }

    func renameActiveChatTitle(_ title: String) {
        renameSession(appModel.activeChatSessionId, title)
    }

    func renameSession(_ sessionId: String, _ title: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, !cleanTitle.isEmpty else { return }
        if sessionId == appModel.activeChatSessionId {
            renameTitle = cleanTitle
        }
        Task {
            await appModel.renameChatSession(id: sessionId, title: cleanTitle)
        }
    }

    func primeAutoReadForCurrentSessionIfNeeded() {
        let sessionID = appModel.activeChatSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty, !autoReadPrimedSessionIds.contains(sessionID) else { return }
        // Prime only once per session. A later tab switch must retain its old
        // cursor so an assistant reply that arrived while the tab was hidden
        // still passes the gate exactly once when it becomes current again.
        lastAutoReadMessageIds[sessionID] = appModel.chatMessages
            .last(where: { $0.role == "assistant" })?.id
        autoReadPrimedSessionIds.insert(sessionID)
    }

    func speakLatestAssistantIfReady() {
        let sessionID = appModel.activeChatSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let decision = ChatVoiceAutoReadGate.decide(
            enabled: voiceAutoRead,
            sessionID: sessionID,
            isSessionPrimed: autoReadPrimedSessionIds.contains(sessionID),
            lastMessage: appModel.chatMessages.last,
            lastReadMessageID: lastAutoReadMessageIds[sessionID]
        )
        guard case .speak(let messageID, let text) = decision else { return }
        // Consume before dispatching the asynchronous voice request: a count,
        // content, and busy-state update may all re-render this same reply.
        lastAutoReadMessageIds[sessionID] = messageID
        Task {
            await voiceOutput.speak(
                text: text,
                resolution: VoiceOutputModeSelection.resolve(for: appModel.trustPolicy)
            )
        }
    }

    // PATCH-2026-06-06: chat-upgrades — dump current session messages as
    // Markdown into ~/Downloads/NativeAgent-chat-<sid>-<ts>.md
    func exportCurrentChatToDownloads() {
        do {
            _ = try ChatExportService.export(
                session: activeSession,
                sessionId: appModel.activeChatSessionId,
                messages: appModel.chatMessages
            )
            appModel.systemToasts.push(success: "Chat exported to Downloads")
        } catch let error as ChatExportError {
            switch error {
            case .noActiveSession, .noMessages:
                showToast(error.localizedDescription)
            case .downloadsUnavailable:
                appModel.systemToasts.push(error: error.localizedDescription)
            }
        } catch {
            appModel.systemToasts.push(error: "Export failed: \(error.localizedDescription)")
        }
    }

    // chat-smoothness phase 4: one visibility truth for the floating live-turn
    // card — the overlay, its animation, and the "Latest" button lift all key
    // off this so they can never disagree.
    //
    // Desk 658.11: that truth is now the lifecycle owner's own projection, not
    // `isBusy`. Session keying already fences other sessions' work, and a turn
    // that ended without provable terminal evidence (including one repaired at
    // relaunch) keeps its honest card instead of vanishing with the busy flag.
    //
    // Desk 658.12: approvals join that same truth. A turn that ended cleanly
    // while its approval is still pending (or ended unproven) keeps the card,
    // because that question has no other home in the transcript.
    var showThinkingRow: Bool {
        MacChatTurnCardProjection.isVisible(
            appModel.chatTurnLifecycle(for: appModel.activeChatSessionId),
            sessionId: appModel.activeChatSessionId,
            approvals: appModel.approvals
        )
    }

    func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool, delay: TimeInterval, force: Bool = false) {
        scrollCoordinator.scrollToBottom(
            proxy,
            bottomAnchor: bottomAnchor,
            animated: animated,
            delay: delay,
            force: force
        )
    }
}

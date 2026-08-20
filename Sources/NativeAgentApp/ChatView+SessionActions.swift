import Foundation
import SwiftUI

extension ChatView {
    func showToast(_ s: String) {
        toasts.show(s)
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

    func speakLatestAssistantIfReady() {
        guard voiceAutoRead,
              let last = appModel.chatMessages.last,
              last.role == "assistant" else { return }
        let text = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, last.id != lastAutoReadMessageId else { return }
        lastAutoReadMessageId = last.id
        Task {
            await voiceOutput.speak(
                text: text,
                mode: voiceUseOpenAI ? .openai : .local
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

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

    // chat-smoothness phase 4: one visibility truth for the floating thinking
    // row — the overlay, its animation, and the "Latest" button lift all key
    // off this so they can never disagree.
    var showThinkingRow: Bool {
        appModel.isBusy && (appModel.currentChatTaskSessionId == nil || appModel.currentChatTaskSessionId == appModel.activeChatSessionId)
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

import EngineRuntime
import Transcripts
import Foundation
import SwiftUI
import MultimodalTTS
// Blueprint: | `ChatView+SessionActions.swift` | `ChatView`: `showToast`, `rename`, `renameActiveChatTitle` |

extension VoiceOutputController {
    static func forChat() -> VoiceOutputController {
        VoiceOutputController(
            failureMessage: { UserFacingError.message($0, action: $1) },
            failureCause: { UserFacingError.cause($0, action: $1) }
        )
    }

    // Manual message playback is globally singular; auto-read has its mounted owner.
    static let sharedMessagePlayback = forChat()
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

    /// 2026-09-22 WHY: a reconnect waits up to 30s (the backoff cap); 6s left
    /// most of the wait silent. Each try replaces the last.
    func pushChatTopNotice(_ text: String, kind: String) {
        guard kind == "provider_retry" else {
            turnNoticeToasts.push(info: text, autoDismissAfter: 6)
            return
        }
        // One fixed id: each try replaces the last without clearing other notices.
        turnNoticeToasts.push(SystemToast(kind: .info, text: text, autoDismissAfter: 30, id: Self.providerRetryNoticeID))
    }

    static let providerRetryNoticeID = UUID()

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
        let decision = VoiceOutputModeSelection.autoReadDecision(
            enabled: voiceAutoRead,
            sessionID: sessionID,
            isSessionPrimed: autoReadPrimedSessionIds.contains(sessionID),
            lastMessage: appModel.chatMessages.last.map { ($0.id, $0.sessionId, $0.role, $0.content) },
            lastReadMessageID: lastAutoReadMessageIds[sessionID]
        )
        guard case .speak(let messageID, let text) = decision else { return }
        // Consume before dispatching the asynchronous voice request: a count,
        // content, and busy-state update may all re-render this same reply.
        lastAutoReadMessageIds[sessionID] = messageID
        Task {
            await voiceOutput.speak(
                text: text,
                policy: appModel.engine.trust.policy,
                loadPolicy: { try await appModel.engine.trust.load() }
            )
        }
    }

    // PATCH-2026-06-06: chat-upgrades — dump current session messages as
    // Markdown into ~/Downloads/NativeAgent-chat-<sid>-<ts>.md
    func exportCurrentChatToDownloads() {
        let session = activeSession
        let sessionId = appModel.activeChatSessionId
        let messages = appModel.chatMessages
        Task {
            do {
                _ = try await ChatExportService.export(session: session, sessionId: sessionId, messages: messages)
                appModel.systemToasts.push(success: "Chat exported to Downloads")
            } catch let error as ChatExportError {
                switch error {
                case .noActiveSession, .noMessages:
                    showToast(error.localizedDescription)
                case .downloadsUnavailable:
                    appModel.systemToasts.push(error: error.localizedDescription)
                }
            } catch {
                appModel.systemToasts.push(error: UserFacingError.message(error, action: "export the chat"))
            }
        }
    }
}

// 2026-09-22: read only by ChatTurnCardInset, never by ChatView.body.
extension ChatTurnCardInset {
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
            appModel.engine.turns.lifecycle(for: appModel.activeChatSessionId),
            sessionId: appModel.activeChatSessionId,
            approvals: appModel.engine.approvals.records,
            parseTimestamp: UserDisplayFormatters.parseFoundationISOTimestamp
        )
    }
}

extension ChatView {
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

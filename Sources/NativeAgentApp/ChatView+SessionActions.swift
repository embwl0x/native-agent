import EngineRuntime
import Transcripts
import Foundation
import NativeAgentShared
import SwiftUI
import MultimodalTTS
// Blueprint: | `ChatView+SessionActions.swift` | `ChatView`: toast publication, committed session rename and voice/export actions |

extension VoiceOutputController {
    static func forChat() -> VoiceOutputController {
        VoiceOutputController(
            failureMessage: { UserFacingError.message($0, action: $1) },
            failureCause: { UserFacingError.cause($0, action: $1) }
        )
    }

    // Keep manual playback globally singular while auto-read retains its mounted owner.
    static let sharedMessagePlayback = forChat()
}

extension ChatView {
    func showToast(_ s: String) {
        toasts.show(s)
    }

    func renameSession(_ sessionId: String, _ title: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, !cleanTitle.isEmpty else { return }
        Task {
            await appModel.renameChatSession(id: sessionId, title: cleanTitle)
        }
    }

    /// Replace the prior retry notice through reconnect backoff so attempts do not stack.
    func pushChatTopNotice(_ text: String, kind: String) {
        guard kind == "provider_retry" else {
            turnNoticeToasts.push(info: text, autoDismissAfter: 6)
            return
        }
        // Use one fixed ID so retries replace only their own notice.
        turnNoticeToasts.push(SystemToast(kind: .info, text: text, autoDismissAfter: 30, id: Self.providerRetryNoticeID))
    }

    static let providerRetryNoticeID = UUID()

    func primeAutoReadForCurrentSessionIfNeeded() {
        let sessionID = appModel.activeChatSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty, !autoReadPrimedSessionIds.contains(sessionID) else { return }
        // Prime once per session so replies arriving behind another tab still pass the gate exactly once on return.
        lastAutoReadMessageIds[sessionID] = appModel.chatMessages
            .last(where: { $0.role == "assistant" })?.id
        autoReadPrimedSessionIds.insert(sessionID)
    }

    func speakLatestAssistantIfReady() {
        let sessionID = appModel.activeChatSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let request = VoiceOutputModeSelection.autoReadDecision(
            enabled: voiceAutoRead,
            sessionID: sessionID,
            isSessionPrimed: autoReadPrimedSessionIds.contains(sessionID),
            lastMessage: appModel.chatMessages.last.map { ($0.id, $0.sessionId, $0.role, $0.content) },
            lastReadMessageID: lastAutoReadMessageIds[sessionID]
        ) else { return }
        // Consume before async playback because content, count and busy updates can re-render the same reply.
        lastAutoReadMessageIds[sessionID] = request.messageID
        Task {
            await voiceOutput.speak(
                text: request.text,
                policy: appModel.engine.trust.policy,
                loadPolicy: { try await appModel.engine.trust.load() }
            )
        }
    }

    func exportCurrentChatToDownloads() {
        let session = activeSession
        let sessionId = appModel.activeChatSessionId
        let messages = appModel.chatMessages
        Task {
            do {
                let result = try await ChatExport.export(session: session, sessionId: sessionId, messages: messages)
                if result.unavailableImages.isEmpty {
                    appModel.systemToasts.push(success: "Chat exported to Downloads")
                } else {
                    appModel.systemToasts.push(warn: "Chat exported to Downloads; images unavailable: \(result.unavailableImages.joined(separator: "; "))")
                }
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

// Keep inset observation out of ChatView.body so clearance changes affect only the pill.
extension ChatTurnCardInset {
    // Derive card visibility, animation and Latest clearance from the lifecycle owner so they cannot disagree.
    // Keep unproven terminal work and pending approvals visible because their question has no other transcript home.
    var showThinkingRow: Bool {
        TurnCardReadout.isVisible(
            appModel.engine.turns.lifecycle(for: appModel.activeChatSessionId),
            sessionId: appModel.activeChatSessionId,
            approvals: appModel.engine.approvals.records,
            parseTimestamp: NativeTimestampFormat.parseISO8601FractionalFirst
        )
    }
}

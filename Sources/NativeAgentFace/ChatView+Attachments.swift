import Foundation
import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `ChatView+Attachments.swift` | `ChatView`: `endDictation`, `toggleVoice`, `captureScreen` |

extension ChatView {
    /// Ending dictation must not write into a newly selected conversation.
    func endDictation() {
        voiceSessionId = ""
        voiceDraftBeforeListening = ""
        // Invalidate starts still waiting for microphone permission.
        voiceGeneration &+= 1
        voiceInput.discardListening()
    }

    func discardDictation() {
        if voiceSessionId == appModel.activeChatSessionId, draft.manualEditRevision == voiceDraftRevision {
            draft.edit(voiceDraftBeforeListening)
        }
        endDictation()
    }

    func toggleVoice() {
        if voiceInput.isStarting { discardDictation(); return }
        if voiceInput.isListening {
            Task { @MainActor in _ = await finishDictation() }
        } else {
            let startSessionId = appModel.activeChatSessionId
            let startGeneration = voiceGeneration
            Task {
                if !voiceSessionId.isEmpty { _ = await finishDictation() }
                _ = await ChatAttachmentTypeResolver.beginDictation(
                    voiceInput, client: appModel.client, draft: draft,
                    isCurrent: { appModel.activeChatSessionId == startSessionId && voiceGeneration == startGeneration },
                    prepareDraft: { base, revision in
                        voiceDraftBeforeListening = base
                        voiceDraftRevision = revision
                        voiceSessionId = startSessionId
                    },
                    showToast: showToast
                )
            }
        }
    }

    func finishDictation() async -> Bool {
        let listeningSession = voiceSessionId
        let stoppedGeneration = voiceGeneration
        return await ChatAttachmentTypeResolver.finishDictation(
            voiceInput, draft: draft, revision: voiceDraftRevision,
            isCurrent: { listeningSession == appModel.activeChatSessionId
                && voiceSessionId == listeningSession && stoppedGeneration == voiceGeneration },
            base: { voiceDraftBeforeListening }, finished: {
            voiceSessionId = ""
            voiceDraftBeforeListening = ""
        }, attach: { pendingAttachments.append($0) }, showToast: showToast)
    }

    func captureScreen() {
        if !voiceSessionId.isEmpty {
            Task { @MainActor in if await finishDictation() { captureScreen() } }
            return
        }
        guard !isCapturing else { return }
        // Share the send latch because screenshot admission suspends before marking the session busy.
        guard !isSubmittingSend else { return }
        let captureSessionId = appModel.activeChatSessionId
        let captured = ChatAttachmentTypeResolver.ScreenshotDraft(draft, attachments: pendingAttachments)
        isCapturing = true
        isSubmittingSend = true
        showToast("Capturing screen...")
        Task {
            defer {
                isCapturing = false
                isSubmittingSend = false
            }
            await ChatAttachmentTypeResolver.sendScreenshot(captured, client: appModel.client, expectedSelection: captureSessionId, canSubmit: {
                guard appModel.activeChatSessionId == captureSessionId else {
                    showToast("Screen capture canceled because the chat changed")
                    return false
                }
                return true
            }, submit: { prompt, attachments in
                await appModel.startActiveChatTurn(
                    prompt, attachments: attachments, expectedSessionId: captureSessionId, composerRevision: captured.revision)
            }, accepted: { acceptedSessionId in
                guard acceptedSessionId == captureSessionId,
                      appModel.activeChatSessionId == acceptedSessionId,
                      draftSessionId == acceptedSessionId else { return }
                transcriptLatestRequest &+= 1
                if captured.clearIfUnchanged(appModel: appModel, draft: draft, attachments: &pendingAttachments) {
                    endDictation()
                }
            }, showToast: showToast)
        }
    }

    func composeVoiceDraft(_ transcript: String) {
        draft.dictate(ChatAttachmentTypeResolver.voiceDraft(base: voiceDraftBeforeListening, transcript: transcript),
                      revision: voiceDraftRevision)
    }

    func attachFromClipboardOrPickFile() {
        let destination = appModel.activeChatSessionId
        ChatAttachmentTypeResolver.attachFromClipboardOrPickFile(
            appModel: appModel, session: destination,
            appendImage: { appModel.chatPendingAttachments[destination, default: []].append($0) },
            attachFile: { attachLocalFile($0, sessionId: destination) },
            showToast: showToast,
            emptySelectionMessage: "No file selected"
        )
    }

    /// Share bounded intake across picker, paste and drop.
    func attachLocalFile(_ url: URL, sessionId: String) {
        ChatAttachmentTypeResolver.attachLocalFile(
            url,
            to: appModel,
            sessionId: sessionId,
            resolveType: ChatAttachmentTypeResolver.typeAndMime,
            showToast: showToast
        )
    }

    func handleDrop(providers: [NSItemProvider]) {
        let destination = appModel.activeChatSessionId
        ChatAttachmentTypeResolver.attachProviders(
            providers, appModel: appModel, session: destination,
            appendImage: { appModel.chatPendingAttachments[destination, default: []].append($0) },
            attachFile: { attachLocalFile($0, sessionId: destination) },
            showToast: showToast
        )
    }
}

import Foundation
import MultimodalTTS
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NativeAgentShared
import enum ChatTurnRuntime.ChatAttachmentTypeResolver
import ScreenVision
// Blueprint: | `ChatView+Attachments.swift` | `ChatView`: `endDictation`, `toggleVoice`, `captureScreen` |

extension ChatView {
    /// Stop recognition without writing into the newly selected conversation's composer.
    func endDictation() {
        voiceSessionId = ""
        voiceDraftBeforeListening = ""
        // Invalidate starts still waiting for microphone permission.
        voiceGeneration &+= 1
        guard voiceInput.isListening else { return }
        Task { @MainActor in _ = await voiceInput.stopListeningResult() }
    }

    func toggleVoice() {
        if voiceInput.isListening {
            Task { @MainActor in _ = await finishDictation() }
        } else {
            voiceOutput.stop()
            let startSessionId = appModel.activeChatSessionId
            let startGeneration = voiceGeneration
            Task {
                if !voiceSessionId.isEmpty { _ = await finishDictation() }
                _ = await ChatAttachmentTypeResolver.beginDictation(
                    voiceInput, draft: draft,
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
        // Screenshot sends share the send latch because admission suspends before marking the session busy.
        guard !isSubmittingSend else { return }
        guard appModel.engine.trust.policy?.multimodalPolicy?.screen_capture == true else {
            showToast("Enable screen capture in Trust → Features → Multimodal")
            return
        }
        guard !appModel.isBusy && !appModel.isChatStreaming else {
            showToast("Chat is already running")
            return
        }
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
            await ChatAttachmentTypeResolver.sendScreenshot(captured, canSubmit: {
                guard appModel.activeChatSessionId == captureSessionId else {
                    showToast("Screen capture canceled because the chat changed")
                    return false
                }
                return true
            }, submit: { prompt, attachments in
                scrollCoordinator.forceFollow()
                return await appModel.startActiveChatTurn(
                    prompt, attachments: attachments, expectedSessionId: captureSessionId)
            }, accepted: { acceptedSessionId in
                guard acceptedSessionId == captureSessionId,
                      appModel.activeChatSessionId == acceptedSessionId,
                      draftSessionId == acceptedSessionId else { return }
                transcriptLatestRequest &+= 1
                scrollCoordinator.forceFollow()
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

    /// Prefer a copied image; otherwise let the person choose files.
    func attachFromClipboardOrPickFile() {
        let destination = appModel.activeChatSessionId
        ChatAttachmentTypeResolver.attachFromClipboardOrPickFile(
            appendImage: { appModel.chatPendingAttachments[destination, default: []].append($0) },
            attachFile: { attachLocalFile($0, sessionId: destination) },
            showToast: showToast,
            emptySelectionMessage: "No file selected"
        )
    }

    /// Picker, paste and drop share the same bounded file intake.
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
            providers,
            appendImage: { appModel.chatPendingAttachments[destination, default: []].append($0) },
            attachFile: { attachLocalFile($0, sessionId: destination) },
            showToast: showToast
        )
    }
}

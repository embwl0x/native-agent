import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NativeAgentShared
import enum ChatOrchestration.ChatAttachmentTypeResolver
import ScreenVision

extension ChatView {
    /// Stop recognition without writing anything through the composer. Called
    /// when the dictating conversation stops being the one on screen — the
    /// composer is already pointed elsewhere, so the stop has nothing to say
    /// to it (2026-09-06).
    func endDictation() {
        voiceSessionId = ""
        voiceDraftBeforeListening = ""
        // 2026-09-06: also cancels a start that is still waiting on the
        // microphone permission prompt, which has no recognition to stop yet.
        voiceGeneration &+= 1
        guard voiceInput.isListening else { return }
        Task { @MainActor in _ = await voiceInput.stopListening() }
    }

    func toggleVoice() {
        if voiceInput.isListening {
            let listeningSession = voiceSessionId
            Task { @MainActor in
                let result = await voiceInput.stopListeningResult()
                // The stop suspends; the person may have moved to another
                // conversation while it flushed. That conversation's composer
                // is not this dictation's to write (2026-09-06).
                guard listeningSession == appModel.activeChatSessionId,
                      voiceSessionId == listeningSession
                else {
                    voiceSessionId = ""
                    voiceDraftBeforeListening = ""
                    return
                }
                let final = result.transcriptForSubmission
                if final.isEmpty {
                    text = voiceDraftBeforeListening
                    showToast(result.userFacingFailureMessage ?? "No speech detected")
                } else {
                    text = composeVoiceDraft(final)
                }
                voiceDraftBeforeListening = ""
                voiceSessionId = ""
            }
        } else {
            // Starting to talk ends her talking. Opening the microphone while
            // playback is still running means she is speaking into her own
            // input and he is talking over her; the person reaching for the
            // mic has already said which of the two matters (2026-09-13).
            voiceOutput.stop()
            VoiceOutputController.sharedMessagePlayback.stop()
            // Clear any prior error so we can detect fresh failures from the
            // current attempt (requestPermission may set errorMessage too).
            voiceInput.errorMessage = nil
            showToast("Checking microphone...")
            // 2026-09-06: the conversation this dictation belongs to is the
            // one the button was pressed in. Reading it after the permission
            // prompt started listening on whichever conversation the person
            // had moved to, and `endDictation` on the way out could not stop
            // a start that had not happened yet.
            let startSessionId = appModel.activeChatSessionId
            let startGeneration = voiceGeneration
            Task {
                let granted = await voiceInput.requestPermission()
                guard granted else {
                    // requestPermission already set a specific errorMessage
                    // (speech vs mic) — surface it.
                    let msg = voiceInput.errorMessage
                        ?? "Microphone or speech permission denied. Enable in System Settings → Privacy & Security."
                    showToast(msg)
                    return
                }
                // The prompt suspends. If the conversation moved on while it
                // was up, this dictation has nothing to dictate into.
                // The composer may also have LEFT while the prompt was up
                // (Chat → Settings) with the same conversation still active,
                // which the session fence alone cannot see.
                guard appModel.activeChatSessionId == startSessionId,
                      voiceGeneration == startGeneration
                else { return }
                voiceDraftBeforeListening = text
                voiceSessionId = startSessionId
                voiceInput.startListening()
                // startListening sets errorMessage if the audio engine refused
                // (busy device, no input route, etc.) — surface that too.
                if let msg = voiceInput.errorMessage, !voiceInput.isListening {
                    showToast(msg)
                } else if voiceInput.isListening {
                    showToast("Listening")
                }
            }
        }
    }

    func captureScreen() {
        guard !isCapturing else { return }
        // 2026-09-06: a screenshot send is a send, so it takes the send latch
        // too. Admission suspends before it marks the session busy, so a
        // Return whose send is still in flight leaves `isBusy` false and the
        // capture button live — the screenshot was admitted as a second turn.
        guard !isSubmittingSend else { return }
        guard appModel.engine.trust.policy?.multimodalPolicy?.screen_capture == true else {
            showToast("Enable screen capture in Trust → Multimodal Capabilities")
            return
        }
        guard !appModel.isBusy && !appModel.isChatStreaming else {
            showToast("Chat is already running")
            return
        }
        let captureSessionId = appModel.activeChatSessionId
        let capturedDraft = text
        // 2026-09-06: the snapshot's own edit time, for the send-clear below.
        let capturedDraftEditedAt = draftEditedAt
        let capturedAttachments = pendingAttachments
        let capturedAttachmentIds = Set(capturedAttachments.map(\.id))
        isCapturing = true
        isSubmittingSend = true
        showToast("Capturing screen...")
        let prompt = capturedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Look at this screenshot and tell me what you see."
            : capturedDraft
        Task {
            defer {
                isCapturing = false
                isSubmittingSend = false
            }
            do {
                // ScreenVision v1 (2026-06-06): the mouse-display hint is
                // dropped — the new module captures the primary
                // (CGMainDisplayID) display only. Multi-display selection is
                // v2 scope. Skip the MainActor hop that used to compute the
                // hint; the static func still accepts (and ignores) a
                // preferredDisplayID for source-compat with other callers.
                let capture = try await Task.detached(priority: .userInitiated) {
                    try await NativeScreenCapture.captureImageBase64()
                }.value
                guard appModel.activeChatSessionId == captureSessionId else {
                    showToast("Screen capture canceled because the chat changed")
                    return
                }
                let mb = Double(capture.byteSize) / (1024.0 * 1024.0)
                showToast(String(format: "Sending screenshot (%.1f MB)...", mb))
                let attachment = MultimodalAttachment(
                    type: "image",
                    base64: capture.base64,
                    mime: capture.mime,
                    name: capture.name,
                    byteSize: capture.byteSize
                )
                let attachments = capturedAttachments + [attachment]
                scrollCoordinator.forceFollow()
                let acceptance = await appModel.startActiveChatTurn(
                    prompt,
                    attachments: attachments,
                    expectedSessionId: captureSessionId
                )
                switch acceptance {
                case .accepted(let acceptedSessionId), .queued(let acceptedSessionId, _):
                    // 2026-09-06: admission suspends; only clear the captured chat's visible draft.
                    guard acceptedSessionId == captureSessionId,
                          appModel.activeChatSessionId == acceptedSessionId,
                          draftSessionId == acceptedSessionId
                    else { return }
                    // 2026-09-06: reveal the accepted exchange even when newer draft edits remain.
                    transcriptLatestRequest &+= 1
                    scrollCoordinator.forceFollow()
                    let currentAttachmentIds = Set(pendingAttachments.map(\.id))
                    guard text == capturedDraft,
                          currentAttachmentIds == capturedAttachmentIds
                    else { return }
                    text = ""
                    // 2026-09-06: a screenshot send is a send. It used to
                    // commit an empty draft with a FRESH timestamp, which
                    // outranked — and deleted — newer text typed in a detached
                    // panel on the same session; and it left a live dictation
                    // running, whose cumulative transcript wrote the words
                    // just sent straight back into the emptied box.
                    appModel.clearChatDraftAfterSend(
                        capturedDraft,
                        sessionId: captureSessionId,
                        editedAt: capturedDraftEditedAt
                    )
                    draftAdoptedText = ""
                    pendingAttachments = []
                    endDictation()
                case .rejected(let message):
                    showToast(message)
                }
            } catch let error as NativeScreenCapture.CaptureError {
                showToast(error.localizedDescription)
            } catch {
                showToast(UserFacingError.message(error, action: "send the screenshot"))
            }
        }
    }

    func composeVoiceDraft(_ transcript: String) -> String {
        ChatComposerSupport.voiceDraft(base: voiceDraftBeforeListening, transcript: transcript)
    }

    /// Prefer a copied image; otherwise let the person choose files.
    func attachFromClipboardOrPickFile() {
        let destination = appModel.activeChatSessionId
        ChatComposerSupport.attachFromClipboardOrPickFile(
            appendImage: { appModel.chatPendingAttachments[destination, default: []].append($0) },
            attachFile: { attachLocalFile($0, sessionId: destination) },
            showToast: showToast,
            emptySelectionMessage: "No file selected"
        )
    }

    /// Picker, paste and drop share the same bounded file intake.
    func attachLocalFile(_ url: URL, sessionId: String) {
        ChatComposerSupport.attachLocalFile(
            url,
            to: appModel,
            sessionId: sessionId,
            resolveType: ChatAttachmentTypeResolver.typeAndMime,
            showToast: showToast
        )
    }

    func handleDrop(providers: [NSItemProvider]) {
        let destination = appModel.activeChatSessionId
        ChatComposerSupport.attachProviders(
            providers,
            appendImage: { appModel.chatPendingAttachments[destination, default: []].append($0) },
            attachFile: { attachLocalFile($0, sessionId: destination) },
            showToast: showToast
        )
    }
}

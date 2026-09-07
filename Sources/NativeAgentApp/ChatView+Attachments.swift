import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NativeAgentShared
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
        guard appModel.trustPolicy?.multimodalPolicy?.screen_capture == true else {
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
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func composeVoiceDraft(_ transcript: String) -> String {
        ChatComposerSupport.voiceDraft(base: voiceDraftBeforeListening, transcript: transcript)
    }

    /// Attach button handler: prefer clipboard image (Cmd-C an image, then click);
    /// fall back to NSOpenPanel so the button always does something visible.
    /// Replaces the old paste-only flow that silently returned nil when the
    /// clipboard didn't have a TIFF.
    func attachFromClipboardOrPickFile() {
        ChatComposerSupport.attachFromClipboardOrPickFile(
            appendImage: { pendingAttachments.append($0) },
            attachFile: attachLocalFile,
            showToast: showToast,
            emptySelectionMessage: "No file selected"
        )
    }

    /// Attach a local file URL — mirrors the file-URL path of handleDrop so
    /// the picker and drag-drop flows stay consistent.
    func attachLocalFile(_ url: URL) {
        ChatComposerSupport.attachLocalFile(
            url,
            to: appModel,
            sessionId: appModel.activeChatSessionId,
            resolveType: ChatAttachmentTypeResolver.typeAndMime,
            showToast: showToast
        )
    }

    func handleDrop(providers: [NSItemProvider]) {
        let dropSessionId = appModel.activeChatSessionId
        for provider in providers {
            // PNG image data (from DropNSView)
            if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    guard let data else { return }
                    // PATCH-2026-05-08: review-fix-B Raw PNG drops bypassed the
                    // 10 MB gate that the file-URL path enforces. Apply the
                    // same limit on data.count here.
                    if data.count > 10_000_000 {
                        DispatchQueue.main.async { self.showToast("Image too large (limit: 10 MB)") }
                        return
                    }
                    let b64 = data.base64EncodedString()
                    let att = MultimodalAttachment(type: "image", base64: b64, mime: "image/png", byteSize: data.count)
                    DispatchQueue.main.async {
                        self.appModel.chatPendingAttachments[dropSessionId, default: []].append(att)
                    }
                }
            // File URLs
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var fileURL: URL?
                    if let url = item as? URL { fileURL = url }
                    else if let data = item as? Data { fileURL = URL(dataRepresentation: data, relativeTo: nil) }
                    guard let url = fileURL else { return }
                    let ext = url.pathExtension.lowercased()
                    guard let attachmentInfo = ChatAttachmentTypeResolver.typeAndMime(forExtension: ext) else {
                        // S.6: surface unsupported extension in toast
                        DispatchQueue.main.async { self.showToast("Unsupported file type: \(url.pathExtension)") }
                        return
                    }
                    // Fix 1: enforce 10 MB size limit before reading file bytes
                    if let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
                       let fileSize = attrs.fileSize, fileSize > 10_000_000 {
                        // S.6: include filename in oversized toast
                        DispatchQueue.main.async { self.showToast("File too large (limit: 10 MB): \(url.lastPathComponent)") }
                        return
                    }
                    guard let data = try? ChatComposerSupport.readAttachmentFile(url) else {
                        // error_handling fix: surface read failure instead of
                        // returning silently with no user feedback.
                        // Sweep R4 C14: one spelling for this failure across the
                        // picker and drop paths ("Couldn't read file: <name>").
                        DispatchQueue.main.async { self.showToast("Couldn't read file: \(url.lastPathComponent)") }
                        return
                    }
                    guard data.count <= 10_000_000 else {
                        DispatchQueue.main.async { self.showToast("File too large (limit: 10 MB): \(url.lastPathComponent)") }
                        return
                    }
                    let b64 = data.base64EncodedString()
                    let att = MultimodalAttachment(
                        type: attachmentInfo.type,
                        base64: b64,
                        mime: attachmentInfo.mime,
                        name: url.lastPathComponent,
                        byteSize: data.count
                    )
                    DispatchQueue.main.async {
                        self.appModel.chatPendingAttachments[dropSessionId, default: []].append(att)
                    }
                }
            } else {
                // S.6: provider is neither PNG nor file URL — surface a toast
                DispatchQueue.main.async { self.showToast("Unsupported drag content — drop an image or file") }
            }
        }
    }
}

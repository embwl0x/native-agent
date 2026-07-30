import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NativeAgentShared
import ScreenVision

extension ChatView {
    func toggleVoice() {
        if voiceInput.isListening {
            Task { @MainActor in
                let final = await voiceInput.stopListening()
                if final.isEmpty {
                    text = voiceDraftBeforeListening
                    showToast("No speech detected")
                } else {
                    text = composeVoiceDraft(final)
                }
                voiceDraftBeforeListening = ""
            }
        } else {
            // Clear any prior error so we can detect fresh failures from the
            // current attempt (requestPermission may set errorMessage too).
            voiceInput.errorMessage = nil
            showToast("Checking microphone...")
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
                voiceDraftBeforeListening = text
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
        let capturedAttachments = pendingAttachments
        let capturedAttachmentIds = Set(capturedAttachments.map(\.id))
        isCapturing = true
        showToast("Capturing screen...")
        let prompt = capturedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Look at this screenshot and tell me what you see."
            : capturedDraft
        Task {
            defer { isCapturing = false }
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
                let currentAttachmentIds = Set(pendingAttachments.map(\.id))
                if text == capturedDraft && currentAttachmentIds == capturedAttachmentIds {
                    text = ""
                    pendingAttachments = []
                }
                scrollCoordinator.forceFollow()
                await appModel.sendChat(prompt, attachments: attachments, sessionId: captureSessionId)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func composeVoiceDraft(_ transcript: String) -> String {
        let base = voiceDraftBeforeListening.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return spoken }
        if spoken.isEmpty { return base }
        return "\(base) \(spoken)"
    }

    /// Attach button handler: prefer clipboard image (Cmd-C an image, then click);
    /// fall back to NSOpenPanel so the button always does something visible.
    /// Replaces the old paste-only flow that silently returned nil when the
    /// clipboard didn't have a TIFF.
    func attachFromClipboardOrPickFile() {
        if clipboardHasImage() {
            if let att = pasteImageFromClipboard() {
                pendingAttachments.append(att)
                showToast("Image pasted from clipboard")
                return
            }
            showToast("Clipboard image could not be pasted; choose a file instead")
        }
        // No usable image on the clipboard — open a file picker.
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .plainText, .text, .data]
        panel.prompt = "Attach"
        panel.message = "Choose an image or document to attach to your chat."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        if urls.isEmpty {
            showToast("No file selected")
            return
        }
        for url in urls {
            attachLocalFile(url)
        }
    }

    /// Attach a local file URL — mirrors the file-URL path of handleDrop so
    /// the picker and drag-drop flows stay consistent.
    func attachLocalFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard let attachmentInfo = ChatAttachmentTypeResolver.typeAndMime(forExtension: ext) else {
            showToast("Unsupported file type: \(ext.isEmpty ? "(no extension)" : ext)")
            return
        }
        if let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = attrs.fileSize, size > 10_000_000 {
            showToast("File too large (limit: 10 MB): \(url.lastPathComponent)")
            return
        }
        // Move the blocking read off the main actor — large or iCloud-resident
        // files can block for seconds and trigger watchdog termination.
        // Capture the target session NOW (like handleDrop's dropSessionId) so a
        // mid-read chat switch can't land the attachment in the wrong session:
        // pendingAttachments is a computed accessor keyed on the *current*
        // activeChatSessionId, which can change across the await.
        let sessionId = appModel.activeChatSessionId
        Task {
            let data = await Task.detached(priority: .utility) { () -> Data? in
                try? Data(contentsOf: url)
            }.value
            // Back on MainActor here; all @State / @Published mutation stays on main.
            guard let data else {
                showToast("Couldn't read file: \(url.lastPathComponent)")
                return
            }
            let att = MultimodalAttachment(
                type: attachmentInfo.type,
                base64: data.base64EncodedString(),
                mime: attachmentInfo.mime,
                name: url.lastPathComponent,
                byteSize: data.count
            )
            appModel.chatPendingAttachments[sessionId, default: []].append(att)
            showToast("Attached \(url.lastPathComponent)")
        }
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
                    guard let data = try? Data(contentsOf: url) else {
                        // error_handling fix: surface read failure instead of
                        // returning silently with no user feedback.
                        DispatchQueue.main.async { self.showToast("Could not read file: \(url.lastPathComponent)") }
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

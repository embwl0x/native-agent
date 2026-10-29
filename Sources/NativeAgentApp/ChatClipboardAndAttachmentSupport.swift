import AppKit
import EngineRuntime
import NativeAgentShared
import ChatTurnRuntime
import MultimodalTTS
import ScreenVision
import UniformTypeIdentifiers

// Blueprint: | `ChatClipboardAndAttachmentSupport.swift` | `ChatAttachmentTypeResolver` and `ChatClipboard`: shared dictation preparation, screenshot submission/reconciliation, drop/paste/picker intake and off-main image conversion |

extension NativeAgentShared.ChatAttachmentTypeResolver {
    static let attachmentContentTypes: [UTType] = [.fileURL, .image]

    /// Surfaces keep their session/lifetime fence and publish the draft only
    /// after permission returns to that same composer.
    @MainActor
    static func beginDictation(
        _ input: VoiceInputCapture, draft: ChatComposerDraft, isCurrent: () -> Bool,
        prepareDraft: (String, UInt64) -> Void, showToast: (String) -> Void
    ) async -> Bool {
        guard isCurrent() else { return false }
        VoiceOutputController.sharedMessagePlayback.stop()
        input.errorMessage = nil
        showToast("Checking microphone...")
        let permission = await input.requestPermission()
        if let message = permission.errorMessage {
            showToast(message)
            return false
        }
        guard isCurrent() else { return false }
        prepareDraft(draft.text, draft.manualEditRevision)
        input.startListening()
        if let message = input.errorMessage, !input.isListening { showToast(message) }
        else if input.isListening { showToast("Listening") }
        return input.isListening
    }

    @MainActor
    struct ScreenshotDraft {
        let text: String
        let editedAt: Date
        let attachments: [MultimodalAttachment]

        init(_ draft: ChatComposerDraft, attachments: [MultimodalAttachment]) {
            text = draft.text
            editedAt = draft.editedAt
            self.attachments = attachments
        }

        func clearIfUnchanged(
            appModel: AppModel, draft: ChatComposerDraft,
            attachments current: inout [MultimodalAttachment]
        ) -> Bool {
            guard draft.text == text, draft.editedAt == editedAt,
                  Set(current.map(\.id)) == Set(attachments.map(\.id)) else { return false }
            appModel.clearChatDraftAfterSend(text, sessionId: draft.sessionId, editedAt: editedAt)
            current = []
            return true
        }
    }

    /// Mac turn admission stays with the caller's existing session route.
    @MainActor
    static func sendScreenshot(
        _ draft: ScreenshotDraft, canSubmit: () -> Bool,
        submit: @MainActor (String, [MultimodalAttachment]) async -> MacChatTurnAcceptance,
        accepted: (String) -> Void, showToast: (String) -> Void
    ) async {
        do {
            let capture = try await Task.detached(priority: .userInitiated) {
                try await NativeScreenCapture.captureImageBase64()
            }.value
            guard canSubmit() else { return }
            showToast(String(format: "Sending screenshot (%.1f MB)...", Double(capture.byteSize) / (1024 * 1024)))
            let attachment = MultimodalAttachment(type: "image", base64: capture.base64,
                                                  mime: capture.mime, name: capture.name,
                                                  byteSize: capture.byteSize)
            let prompt = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Look at this screenshot and tell me what you see." : draft.text
            switch await submit(prompt, draft.attachments + [attachment]) {
            case .accepted(let sessionID), .queued(let sessionID, _): accepted(sessionID)
            case .rejected(let message): showToast(message)
            }
        } catch let error as NativeScreenCapture.CaptureError {
            showToast(error.localizedDescription)
        } catch {
            showToast(UserFacingError.message(error, action: "send the screenshot"))
        }
    }

    @MainActor
    static func finishDictation(
        _ input: VoiceInputCapture, draft: ChatComposerDraft, revision: UInt64,
        isCurrent: () -> Bool, base: () -> String, finished: () -> Void,
        attach: (MultimodalAttachment) -> Void, showToast: (String) -> Void
    ) async -> Bool {
        let wasListening = input.isListening
        let result = await input.stopListeningResult()
        guard isCurrent() else { return false }
        defer { finished() }
        // Typing supersedes late recognition; the requested action may proceed.
        guard draft.manualEditRevision == revision else { return true }
        let final = result.transcriptForSubmission
        guard !final.isEmpty else {
            draft.edit(base())
            showToast(result.userFacingFailureMessage ?? "No speech detected")
            return false
        }
        if wasListening { draft.edit(voiceDraft(base: base(), transcript: final)) }
        if let attachment = input.attachment { attach(attachment) }
        return true
    }

    /// Each surface captures its destination before asynchronous intake starts.
    @MainActor
    static func attachFromClipboardOrPickFile(
        appendImage: @escaping @MainActor (MultimodalAttachment) -> Void,
        attachFile: @escaping @MainActor (URL) -> Void,
        showToast: @escaping @MainActor (String) -> Void,
        emptySelectionMessage: String? = nil
    ) {
        let pasteboard = NSPasteboard.general
        if let type = imageType(in: (pasteboard.types ?? []).map(\.rawValue)) {
            let data = pasteboard.data(forType: .init(type))
            Task {
                switch await Task.detached(priority: .userInitiated, operation: {
                    imageAttachment(data, typeIdentifier: type)
                }).value {
                case .success(let attachment):
                    appendImage(attachment)
                    showToast("Image pasted from clipboard")
                case .failure:
                    showToast("Clipboard image could not be pasted; choose a file instead")
                    pickFiles()
                }
            }
            return
        }
        pickFiles()

        func pickFiles() {
            guard let urls = pickAttachmentFiles() else { return }
            if urls.isEmpty, let emptySelectionMessage {
                showToast(emptySelectionMessage)
            }
            for url in urls { attachFile(url) }
        }
    }

    @MainActor
    static func clipboardAttachmentProviders() -> [NSItemProvider] {
        (NSPasteboard.general.pasteboardItems ?? []).compactMap { item -> NSItemProvider? in
            // Prefer the original file over its thumbnail representation.
            if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                return NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
            }
            guard let type = imageType(in: item.types.map(\.rawValue)),
                  let data = item.data(forType: .init(type)) else { return nil }
            return NSItemProvider(item: data as NSData, typeIdentifier: type)
        }
    }

    /// Drop, paste and the + button feed the same image decoder and local-file
    /// intake. One representation per item prevents attaching Finder previews.
    @MainActor
    static func attachProviders(
        _ providers: [NSItemProvider],
        appendImage: @escaping @MainActor (MultimodalAttachment) -> Void,
        attachFile: @escaping @MainActor (URL) -> Void,
        showToast: @escaping @MainActor (String) -> Void
    ) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = localFileURL(item)
                    Task { @MainActor in
                        guard let url, url.isFileURL else {
                            showToast("Couldn't read the attached file")
                            return
                        }
                        attachFile(url)
                    }
                }
            } else if let type = imageType(in: provider.registeredTypeIdentifiers) {
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    // Decoding TIFF and other image formats stays off the UI actor.
                    Task.detached(priority: .utility) {
                        let result = imageAttachment(data, typeIdentifier: type)
                        await MainActor.run {
                            switch result {
                            case .success(let attachment):
                                appendImage(attachment)
                                showToast("Image attached")
                            case .failure(let refusal): showToast(refusal.message)
                            }
                        }
                    }
                }
            } else {
                showToast("Attach an image or a supported file")
            }
        }
    }

    @MainActor
    static func pickAttachmentFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .plainText, .text, .data]
        panel.prompt = "Attach"
        panel.message = "Choose an image or document to attach to your chat."
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    /// Capture the destination before metadata reads and conversion suspend.
    @MainActor
    static func attachLocalFile(
        _ url: URL,
        to appModel: AppModel,
        sessionId: @autoclosure () -> String,
        resolveType: (String) -> (type: String, mime: String)?,
        canAttach: @escaping @MainActor () -> Bool = { true },
        showToast: @escaping @MainActor (String) -> Void
    ) {
        let resolved = resolveType(url.pathExtension.lowercased())
        let destination = sessionId()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                switch attachmentKind(url, resolveType: { _ in resolved }) {
                case .failure(let refusal): return Result<MultimodalAttachment, AttachmentRefusal>.failure(refusal)
                case .success(let kind): return await readAttachment(url, kind: kind)
                }
            }.value
            switch result {
            case .failure(let refusal):
                showToast(refusal.message)
            case .success(let att):
                guard canAttach() else { return }
                appModel.chatPendingAttachments[destination, default: []].append(att)
                showToast("Attached \(url.lastPathComponent)")
            }
        }
    }

}

enum ChatClipboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

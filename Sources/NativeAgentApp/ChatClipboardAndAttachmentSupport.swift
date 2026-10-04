import AppKit
import NativeAgentShared
import UniformTypeIdentifiers

enum ChatComposerSupport {
    /// Clipboard-first intake is synchronous; each surface keeps destination
    /// availability and asynchronous file-read fences in its own callbacks.
    @MainActor
    static func attachFromClipboardOrPickFile(
        appendImage: (MultimodalAttachment) -> Void,
        attachFile: (URL) -> Void,
        showToast: (String) -> Void,
        emptySelectionMessage: String? = nil
    ) {
        if clipboardHasImage() {
            if let attachment = pasteImageFromClipboard() {
                appendImage(attachment)
                showToast("Image pasted from clipboard")
                return
            }
            showToast("Clipboard image could not be pasted; choose a file instead")
        }
        guard let urls = pickAttachmentFiles() else { return }
        if urls.isEmpty, let emptySelectionMessage {
            showToast(emptySelectionMessage)
        }
        for url in urls { attachFile(url) }
    }

    /// Read one overflow byte so a growing file cannot bypass the attachment
    /// cap or allocate an unbounded buffer before it is rejected.
    static func readAttachmentFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bound = 10_000_000 + 1
        var data = Data()
        while data.count < bound {
            guard let chunk = try handle.read(upToCount: bound - data.count),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    static func voiceDraft(base: String, transcript: String) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return spoken }
        if spoken.isEmpty { return base }
        return "\(base) \(spoken)"
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

    /// Validate synchronously, then read off the main actor. Keep the captured
    /// destination across suspension; each surface retains its availability rule.
    @MainActor
    static func attachLocalFile(
        _ url: URL,
        to appModel: AppModel,
        sessionId: @autoclosure () -> String,
        resolveType: (String) -> (type: String, mime: String)?,
        canAttach: @escaping @MainActor () -> Bool = { true },
        showToast: @escaping @MainActor (String) -> Void
    ) {
        let kind: (type: String, mime: String)
        switch attachmentKind(url, resolveType: resolveType) {
        case .success(let resolved): kind = resolved
        case .failure(let refusal): showToast(refusal.message); return
        }
        let destination = sessionId()
        Task {
            switch await readAttachment(url, kind: kind) {
            case .failure(let refusal):
                showToast(refusal.message)
            case .success(let att):
                guard canAttach() else { return }
                appModel.chatPendingAttachments[destination, default: []].append(att)
                showToast("Attached \(url.lastPathComponent)")
            }
        }
    }

    struct AttachmentRefusal: Error { let message: String }

    /// Type and size, decided before any read. Shared with the agent's own
    /// composer verbs so a file she attaches meets the same rules.
    static func attachmentKind(
        _ url: URL, resolveType: (String) -> (type: String, mime: String)?
    ) -> Result<(type: String, mime: String), AttachmentRefusal> {
        let ext = url.pathExtension.lowercased()
        guard let attachmentInfo = resolveType(ext) else {
            return .failure(.init(message: "Unsupported file type: \(ext.isEmpty ? "(no extension)" : ext)"))
        }
        if let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = attrs.fileSize, size > 10_000_000 {
            return .failure(.init(message: "File too large (limit: 10 MB): \(url.lastPathComponent)"))
        }
        return .success(attachmentInfo)
    }

    /// The bounded read, off the main actor.
    static func readAttachment(
        _ url: URL, kind: (type: String, mime: String)
    ) async -> Result<MultimodalAttachment, AttachmentRefusal> {
        let data = await Task.detached(priority: .utility) { () -> Data? in
            try? readAttachmentFile(url)
        }.value
        guard let data else {
            return .failure(.init(message: "Couldn't read file: \(url.lastPathComponent)"))
        }
        guard data.count <= 10_000_000 else {
            return .failure(.init(message: "File too large (limit: 10 MB): \(url.lastPathComponent)"))
        }
        return .success(MultimodalAttachment(
            type: kind.type,
            base64: data.base64EncodedString(),
            mime: kind.mime,
            name: url.lastPathComponent,
            byteSize: data.count
        ))
    }
}

enum ChatClipboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

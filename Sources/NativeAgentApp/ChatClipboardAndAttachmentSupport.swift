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
        let ext = url.pathExtension.lowercased()
        guard let attachmentInfo = resolveType(ext) else {
            showToast("Unsupported file type: \(ext.isEmpty ? "(no extension)" : ext)")
            return
        }
        if let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = attrs.fileSize, size > 10_000_000 {
            showToast("File too large (limit: 10 MB): \(url.lastPathComponent)")
            return
        }
        let destination = sessionId()
        Task {
            let data = await Task.detached(priority: .utility) { () -> Data? in
                try? readAttachmentFile(url)
            }.value
            guard let data else {
                showToast("Couldn't read file: \(url.lastPathComponent)")
                return
            }
            guard data.count <= 10_000_000 else {
                showToast("File too large (limit: 10 MB): \(url.lastPathComponent)")
                return
            }
            guard canAttach() else { return }
            let att = MultimodalAttachment(
                type: attachmentInfo.type,
                base64: data.base64EncodedString(),
                mime: attachmentInfo.mime,
                name: url.lastPathComponent,
                byteSize: data.count
            )
            appModel.chatPendingAttachments[destination, default: []].append(att)
            showToast("Attached \(url.lastPathComponent)")
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

enum ChatAttachmentTypeResolver {
    static func typeAndMime(forExtension ext: String) -> (type: String, mime: String)? {
        switch ext {
        case "png":
            return ("image", "image/png")
        case "jpg", "jpeg":
            return ("image", "image/jpeg")
        case "heic":
            return ("image", "image/heic")
        case "webp":
            return ("image", "image/webp")
        case "gif":
            return ("image", "image/gif")
        case "pdf":
            return ("file", "application/pdf")
        case "docx":
            return ("file", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        case "txt", "md":
            return ("file", "text/plain")
        default:
            return nil
        }
    }
}

import AppKit
import NativeAgentShared
import UniformTypeIdentifiers

enum ChatComposerSupport {
    static let attachmentContentTypes: [UTType] = [.fileURL, .image]
    static let attachmentByteLimit = ChatAttachmentTypeResolver.fileByteLimit
    static let clipboardImageByteLimit = 10 * 1024 * 1024

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
            switch imageAttachment(pasteboard.data(forType: .init(type)), typeIdentifier: type) {
            case .success(let attachment):
                appendImage(attachment)
                showToast("Image pasted from clipboard")
                return
            case .failure:
                showToast("Clipboard image could not be pasted; choose a file instead")
            }
        }
        guard let urls = pickAttachmentFiles() else { return }
        if urls.isEmpty, let emptySelectionMessage {
            showToast(emptySelectionMessage)
        }
        for url in urls { attachFile(url) }
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
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                    else if let value = item as? String { url = URL(string: value) }
                    else { url = nil }
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

    static func imageType(in identifiers: [String]) -> String? {
        let preferred = [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier]
        return preferred.first(where: identifiers.contains)
            ?? identifiers.first { UTType($0)?.conforms(to: .image) == true }
    }

    static func imageAttachment(
        _ data: Data?, typeIdentifier: String
    ) -> Result<MultimodalAttachment, AttachmentRefusal> {
        guard let data else { return .failure(.init(message: "Couldn't read the attached image")) }
        guard data.count <= clipboardImageByteLimit else {
            return .failure(.init(message: "Image too large (limit: 10 MB)"))
        }
        let bytes: Data
        let mime: String
        switch typeIdentifier {
        case UTType.png.identifier: bytes = data; mime = "image/png"
        case UTType.jpeg.identifier: bytes = data; mime = "image/jpeg"
        default:
            guard let rep = NSBitmapImageRep(data: data),
                  let png = rep.representation(using: .png, properties: [:]) else {
                return .failure(.init(message: "Couldn't read the attached image"))
            }
            bytes = png; mime = "image/png"
        }
        guard bytes.count <= clipboardImageByteLimit else {
            return .failure(.init(message: "Image too large (limit: 10 MB)"))
        }
        return .success(MultimodalAttachment(
            type: "image", base64: bytes.base64EncodedString(), mime: mime, byteSize: bytes.count
        ))
    }

    /// Read one overflow byte so a growing file cannot bypass the attachment
    /// cap or allocate an unbounded buffer before it is rejected.
    static func readAttachmentFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bound = attachmentByteLimit + 1
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
           let size = attrs.fileSize, size > attachmentByteLimit {
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
        guard data.count <= attachmentByteLimit else {
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

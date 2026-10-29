import UIKit
import ImageIO
import NativeAgentShared

enum MobileChatAttachmentPreparation {
    static func fileAttachment(from url: URL) throws -> MultimodalAttachment {
        guard let shape = ChatAttachmentTypeResolver.typeAndMime(forExtension: url.pathExtension.lowercased()), shape.type == "file" else {
            throw NSError(domain: "ChatAttachment", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a PDF, TXT, or Markdown file."])
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                let size = try readable.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= ChatAttachmentTypeResolver.fileByteLimit else {
                    throw NSError(domain: "ChatAttachment", code: 2, userInfo: [NSLocalizedDescriptionKey: "Documents must be nonempty and no larger than 10 MB."])
                }
                let bytes = try Data(contentsOf: readable)
                guard !bytes.isEmpty, bytes.count <= ChatAttachmentTypeResolver.fileByteLimit else {
                    throw NSError(domain: "ChatAttachment", code: 2, userInfo: [NSLocalizedDescriptionKey: "Documents must be nonempty and no larger than 10 MB."])
                }
                return bytes
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        let bytes = try result.get()
        return MultimodalAttachment(id: UUID().uuidString, type: shape.type,
            base64: bytes.base64EncodedString(), mime: shape.mime, name: url.lastPathComponent, byteSize: bytes.count)
    }

    static func thumbnail(from data: Data, maxDimension: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = TranscriptAttachmentPreview.thumbnail(from: source, maxDimension: maxDimension) else { return nil }
        return UIImage(cgImage: image)
    }

    static func preparedJPEGData(from data: Data) -> Data? {
        guard let image = thumbnail(from: data, maxDimension: 1400),
              let bytes = image.jpegData(compressionQuality: 0.78),
              bytes.count <= ChatAttachmentTypeResolver.fileByteLimit else { return nil }
        return bytes
    }
}

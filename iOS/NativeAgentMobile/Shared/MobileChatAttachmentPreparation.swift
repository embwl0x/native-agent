import UIKit
import ImageIO
import UniformTypeIdentifiers
import NativeAgentShared

enum MobileChatAttachmentPreparation {
    static let payloadBudgetBytes = 520 * 1024

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
              let image = thumbnail(from: source, maxDimension: maxDimension) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func thumbnail(from source: CGImageSource, maxDimension: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as CFDictionary)
    }

    static func preparedJPEGData(from data: Data, maxDimension: Int = 1400,
                                 maxBytes: Int = payloadBudgetBytes) -> Data? {
        guard maxBytes > 0, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var dimension = maxDimension
        while dimension > 0 {
            guard let image = thumbnail(from: source, maxDimension: dimension) else { return nil }
            for quality in [0.78, 0.66, 0.54, 0.42, 0.32, 0.24] {
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), encoded.length <= maxBytes {
                    return encoded as Data
                }
            }
            guard dimension > 320 else { return nil }
            dimension = max(320, Int(Double(dimension) * 0.78))
        }
        return nil
    }
}

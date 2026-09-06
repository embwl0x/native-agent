import Foundation
import NativeAgentCore
import PersistenceCore
import ImageIO
import UniformTypeIdentifiers

/// Pixels live only in the admitted tool call's model continuation, never in
/// JSON tool results, transcript receipts, result paging, or tool notices.
public enum LocalToolImage {
    @TaskLocal public static var sink: Sink?
    public static let maximumBytes = 8 * 1024 * 1024

    /// Bound the entire active conversation, not just one tool iteration.
    /// Keep the newest eight images for before/after comparisons. Replace old
    /// pixels with an explicit reread notice; paired tool receipts stay intact.
    public static func boundConversation(_ messages: inout [LLMMessage],
                                         maxImages: Int = 8, maxBytes: Int = 32 * 1024 * 1024) {
        var count = 0, bytes = 0
        for index in messages.indices.reversed() {
            let message = messages[index]
            var content = message.content
            var changed = false
            for blockIndex in content.indices.reversed() {
                guard case .image(_, let base64, let name, let byteSize) = content[blockIndex] else { continue }
                let size = max(byteSize, base64.utf8.count * 3 / 4)
                if count < maxImages, size <= maxBytes - bytes {
                    count += 1; bytes += size
                } else {
                    content[blockIndex] = .text("[Earlier image \(name ?? "attachment") released from visual context to bound this turn. Its pixels are no longer visible; reread the original file if needed.]")
                    changed = true
                }
            }
            if changed {
                messages[index] = LLMMessage(role: message.role, content: content,
                    turnScopedClearAtNextUserMessage: message.turnScopedClearAtNextUserMessage,
                    toolChanges: message.toolChanges)
            }
        }
    }

    /// Responses adapters emit function outputs separately from image messages.
    /// Never mix them in one message where an image fast path can drop outputs.
    public static func continuation(_ blocks: [LLMContentBlock]) -> [LLMMessage] {
        let images = blocks.filter { if case .image = $0 { return true }; return false }
        let results = blocks.filter { if case .image = $0 { return false }; return true }
        var messages: [LLMMessage] = results.isEmpty ? [] : [LLMMessage(role: .user, content: results)]
        if !images.isEmpty { messages.append(LLMMessage(role: .user, content: images)) }
        return messages
    }

    public final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var image: LLMContentBlock?
        private var closed = false
        public init() {}
        fileprivate func accept(_ block: LLMContentBlock) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !closed, image == nil else { return false }
            image = block
            return true
        }
        public func finish(success: Bool) -> [LLMContentBlock] {
            lock.lock(); defer { lock.unlock() }
            closed = true
            defer { image = nil }
            return success ? image.map { [$0] } ?? [] : []
        }
    }

    /// Caller MUST have resolved and authorized this exact URL through its
    /// ordinary file gate. nil preserves the existing text-file reader.
    public static func readAuthorizedFile(_ url: URL) -> JSONValue? {
        guard ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tif", "tiff", "bmp"]
            .contains(url.pathExtension.lowercased()) else { return nil }
        func failure(_ reason: String) -> JSONValue {
            .object(["status": .string("failed"), "error": .string(reason)])
        }
        guard let sink else {
            return failure("Image pixels require a model tool turn; this direct text-only call cannot display an image.")
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size > 0, size <= maximumBytes else {
                return failure("Image must be a nonempty regular file of at most 8 MiB.")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard !data.isEmpty, data.count <= maximumBytes,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, Double(width) * Double(height) <= 40_000_000,
                  let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                  ] as CFDictionary) else {
                return failure("Image is unreadable, unsupported, or exceeds the 40-megapixel limit.")
            }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
                return failure("Could not encode image pixels.")
            }
            CGImageDestinationAddImage(destination, pixels, nil)
            guard CGImageDestinationFinalize(destination), encoded.length <= maximumBytes else {
                return failure("Encoded image exceeds the 8 MiB delivery limit.")
            }
            guard !Task.isCancelled, sink.accept(.image(mediaType: "image/png",
                base64: (encoded as Data).base64EncodedString(), name: url.lastPathComponent, byteSize: encoded.length)) else {
                return failure("Image delivery was cancelled or this tool call already supplied an image.")
            }
            return .object([
                "status": .string("ok"), "image_pixels": .bool(true),
                "name": .string(url.lastPathComponent),
                "width": .int(Int64(pixels.width)), "height": .int(Int64(pixels.height)),
                "source_width": .int(Int64(width)), "source_height": .int(Int64(height)),
                "note": .string("Actual image follows this tool result. First frame, oriented and bounded to 2048 pixels; not OCR or a text description."),
            ])
        } catch {
            return failure("Could not read image: \(error.localizedDescription)")
        }
    }
}

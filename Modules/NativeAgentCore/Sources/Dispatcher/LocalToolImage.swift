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

    // MARK: - Tools that MAKE a picture show the picture (2026-09-13)
    //
    // Agent shipped two images she had never seen: image_generate returned a
    // path, and seeing it meant a second turn with read_file — which on the
    // second occasion was not even loaded. The tool that makes the thing shows
    // the thing, through this same sink: a bounded thumbnail rides back on the
    // SAME tool result, the full-size file path stays in the JSON.

    /// Images ONE tool result may deliver. Eight: a folder read_file with
    /// `match` (2026-09-24), a generate call with n=4, a before/after pair —
    /// the same eight `boundConversation` keeps.
    public static let maximumImagesPerResult = 8
    /// Long edge of a produced-image thumbnail. Half `readAuthorizedFile`'s
    /// 2048: a produced image is shown so the model can CHECK it (did it come
    /// out, is it the right shape, is the text right), and 1024 JPEG is a
    /// tenth of the bytes of 2048 PNG.
    public static let producedThumbnailMaxPixelSize = 1024
    /// Source file a producer may open. Generous — it is downscaled
    /// immediately — but a 100 MB render is a file, not a look.
    public static let producedSourceMaximumBytes = 32 * 1024 * 1024

    /// Tool names whose result may carry pixels: the reader the model points
    /// at a file, plus every tool that MAKES an image file the model should
    /// look at before it speaks about it. The dispatcher hands a sink to these
    /// and to nothing else — a name absent here simply never mints pixels.
    public static let pixelCapableTools: Set<String> = [
        "read_file",
        "screen",
        "app_page_screenshot",
        "image_generate",
        "browser.screenshot",
        // Both carry a `capture_screenshot` flag through the same capture.
        "browser.open_url",
        "browser.navigate",
        // The underscore spellings AppChatToolDispatcher canonicalizes: a call
        // that arrives under an alias is dispatched to the same capture, and a
        // name missing from this set would silently return no pixels at all.
        "browser_screenshot", "browser_capture_screenshot", "browser.capture_screenshot",
        "browser_open_url", "browser_navigate",
    ]

    /// What happened when a tool offered the model a file it just produced.
    /// `note` is always tellable to the model; when `shown` is false it says
    /// why the pixels are not there, so the model never claims to have looked.
    public struct ProducedImage: Sendable {
        public let shown: Bool
        public let note: String
        public let width: Int?
        public let height: Int?
    }

    /// A tool that just WROTE `url` offers it to the model for this same turn.
    /// No file gate is consulted and none is needed: the caller produced this
    /// file itself, inside its own data root, in the turn that is returning it
    /// — unlike `readAuthorizedFile`, where the path came from the model.
    public static func showProducedImage(at url: URL, name: String? = nil) -> ProducedImage {
        func skipped(_ reason: String) -> ProducedImage {
            ProducedImage(shown: false, note: reason, width: nil, height: nil)
        }
        guard let sink else {
            return skipped("Not shown inline: this call has no model turn to display pixels in. The file is at the path above.")
        }
        let label = name ?? url.lastPathComponent
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                return skipped("Not shown inline: \(label) is not a readable file.")
            }
            guard size <= producedSourceMaximumBytes else {
                return skipped("Not shown inline: \(label) is \(size / (1024 * 1024)) MB, over the \(producedSourceMaximumBytes / (1024 * 1024)) MB inline cap. Open the path above to see it.")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let thumbnail = jpegThumbnail(data, maxPixelSize: producedThumbnailMaxPixelSize) else {
                return skipped("Not shown inline: \(label) could not be decoded as an image.")
            }
            guard !Task.isCancelled, sink.accept(.image(
                mediaType: "image/jpeg", base64: thumbnail.data.base64EncodedString(),
                name: label, byteSize: thumbnail.data.count
            )) else {
                return skipped("Not shown inline: this tool result already carries \(maximumImagesPerResult) image(s), the per-result cap.")
            }
            return ProducedImage(
                shown: true,
                note: "Shown below this tool result as a JPEG thumbnail, long edge \(producedThumbnailMaxPixelSize)px. The full-size file is at the path above.",
                width: thumbnail.width, height: thumbnail.height
            )
        } catch {
            return skipped("Not shown inline: \(label) could not be read (\(error.localizedDescription)).")
        }
    }

    /// Downscaled JPEG of the first frame, oriented. Shared by every producer.
    static func jpegThumbnail(
        _ data: Data, maxPixelSize: Int
    ) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 40_000_000,
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, pixels, [
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length > 0,
              encoded.length <= maximumBytes else { return nil }
        return (encoded as Data, pixels.width, pixels.height)
    }

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
        // 2026-09-13: was a single slot, because read_file was the only
        // producer and one call reads one file. A generate call returns n
        // images, so the slot became a bounded list — `maximumImagesPerResult`
        // is the whole of the widening, and one image is still one image.
        private var images: [LLMContentBlock] = []
        private var closed = false
        public init() {}
        fileprivate func accept(_ block: LLMContentBlock) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !closed, images.count < maximumImagesPerResult else { return false }
            images.append(block)
            return true
        }
        public func finish(success: Bool) -> [LLMContentBlock] {
            lock.lock(); defer { lock.unlock() }
            closed = true
            defer { images = [] }
            return success ? images : []
        }
    }

    /// Hand already-encoded PNG bytes to the model as a real image block.
    ///
    /// The same one-image-per-call sink the file reader uses, for pixels a tool
    /// MADE rather than read: the caller owns the bytes, so there is no path to
    /// authorize and no file to resolve. The size ceiling is the delivery
    /// ceiling and is checked here rather than trusted from the caller.
    public static func deliverPNG(
        _ data: Data, name: String, width: Int, height: Int, mediaType: String = "image/png"
    ) -> JSONValue {
        func failure(_ reason: String) -> JSONValue {
            .object(["status": .string("failed"), "error": .string(reason)])
        }
        guard !data.isEmpty, data.count <= maximumBytes else {
            return failure("Image must be nonempty and at most 8 MiB.")
        }
        guard let sink else {
            return failure("Image pixels require a model tool turn; this direct text-only call cannot display an image.")
        }
        guard !Task.isCancelled, sink.accept(.image(
            mediaType: mediaType, base64: data.base64EncodedString(),
            name: name, byteSize: data.count
        )) else {
            return failure("Image delivery was cancelled or this tool call already supplied an image.")
        }
        return .object([
            "status": .string("ok"), "image_pixels": .bool(true),
            "name": .string(name),
            "width": .int(Int64(width)), "height": .int(Int64(height)),
            "note": .string("Actual image follows this tool result."),
        ])
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

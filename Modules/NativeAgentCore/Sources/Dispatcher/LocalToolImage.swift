import Foundation
import CoreGraphics
import NativeAgentCore
import PersistenceCore
import ImageIO
import UniformTypeIdentifiers

// Blueprint: | `LocalToolImage.swift` | `LocalToolImage`: explicitly supplied image sinks and bounded thumbnails; pixels never enter durable receipts |

/// Pixels live only in the admitted tool call's model continuation, never in JSON tool results, transcript receipts, result paging, or tool notices.
public enum LocalToolImage {
    public static let maximumBytes = 8 * 1024 * 1024


    /// Bound unanswered pixels to eight images and 32 MiB; conversation release goes to half to avoid repeated prefix rewrites.
    public static let roundImages = 8
    public static let roundBytes = 32 * 1024 * 1024
    public static let roundFull = "This round's images are full (\(roundImages) images or 32 MiB); read it next."
    /// 1024 JPEG suffices for checking produced images at about one tenth the bytes of 2048 PNG.
    public static let producedThumbnailMaxPixelSize = 1024
    /// Downscale immediately; refuse sources above the ceiling so a large render stays a file rather than an unbounded look.
    public static let producedSourceMaximumBytes = 32 * 1024 * 1024

    /// Only image readers and producers receive sinks; other tools cannot mint pixels.
    public static let pixelCapableTools: Set<String> = [
        "read_file",
        "screen",
        "app",
        "image_generate",
        "browser.screenshot",
        "browser.chrome_look",
        "browser.open_url",
    ]

    /// A missing-pixels note stays model-readable so the response cannot claim an unseen image was inspected.
    public struct ProducedImage: Sendable {
        public let shown: Bool
        public let note: String
        public let width: Int?
        public let height: Int?
    }

    /// The caller produced this file inside its own data root during this turn, so delivery needs no additional path gate.
    public static func showProducedImage(at url: URL, name: String? = nil, sink: Sink?) -> ProducedImage {
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
                return skipped("""
                    Not shown inline: \(label) is \(size / (1024 * 1024)) MB, over the \(producedSourceMaximumBytes / (1024 * 1024)) MB inline \
                    cap. Open the path above to see it.
                    """)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let thumbnail = thumbnail(data, maxPixelSize: producedThumbnailMaxPixelSize) else {
                return skipped("Not shown inline: \(label) could not be decoded as an image.")
            }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
                return skipped("Not shown inline: \(label) could not be decoded as an image.")
            }
            CGImageDestinationAddImage(destination, thumbnail.pixels, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination), encoded.length > 0, encoded.length <= maximumBytes else {
                return skipped("Not shown inline: \(label) could not be decoded as an image.")
            }
            guard !Task.isCancelled, sink.accept(.image(
                mediaType: "image/jpeg", base64: (encoded as Data).base64EncodedString(),
                name: label, byteSize: encoded.length
            )) else {
                return skipped("Not shown inline: \(roundFull) The file is at the path above.")
            }
            return ProducedImage(
                shown: true,
                note: """
                    Shown below this tool result as a JPEG thumbnail, long edge \(producedThumbnailMaxPixelSize)px. The full-size file is at the \
                    path above.
                    """,
                width: thumbnail.pixels.width, height: thumbnail.pixels.height
            )
        } catch {
            return skipped("Not shown inline: \(label) could not be read (\(error.localizedDescription)).")
        }
    }

    static func thumbnail(
        _ data: Data, maxPixelSize: Int
    ) -> (pixels: CGImage, sourceWidth: Int, sourceHeight: Int)? {
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
        return (pixels, width, height)
    }

    /// Bound the whole conversation while retaining up to eight images for comparisons and all paired receipts. Release to half the cap at once: each release
    /// rewrites the cached prefix from the oldest touched image. Never release pixels the model has not answered; replace released images with an explicit
    /// reread notice.
    public static func boundConversation(_ messages: inout [LLMMessage],
                                         maxImages: Int = roundImages, maxBytes: Int = roundBytes) {
        supersede(&messages)
        func size(_ block: LLMContentBlock) -> Int? {
            guard case .image(_, let base64, _, let byteSize) = block else { return nil }
            return max(byteSize, base64.utf8.count * 3 / 4)
        }
        let all = messages.flatMap(\.content).compactMap(size)
        guard all.count > maxImages || all.reduce(0, +) > maxBytes else { return }
        let answered = messages.lastIndex { $0.role == .assistant } ?? -1
        let unseen = messages[(answered + 1)...].flatMap(\.content).compactMap(size)
        var count = unseen.count, bytes = unseen.reduce(0, +)
        for index in messages.indices.reversed() where index <= answered {
            let message = messages[index]
            var content = message.content
            var changed = false
            for blockIndex in content.indices.reversed() {
                guard case .image(_, _, let name, _) = content[blockIndex], let size = size(content[blockIndex]) else { continue }
                if count < maxImages / 2, size <= maxBytes / 2 - bytes {
                    count += 1; bytes += size
                } else {
                    content[blockIndex] = .text("""
                        [Earlier image \(name.map(shown) ?? "attachment") released from visual context to bound this turn. Its pixels are no longer \
                        visible; reread the original file if needed.]
                        """)
                    changed = true
                }
            }
            if changed {
                messages[index] = LLMMessage(role: message.role, content: content)
            }
        }
    }

    /// Source-tag screenshot names so only a newer capture of the same window and region can supersede its pixels.
    public static func screenshotName(of display: String, source: String, at date: Date = Date()) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let tag = source.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return "screenshot of " + display + " at " + clock.string(from: date) + sourceMark + String(tag, radix: 16)
    }
    private static let sourceMark = " · source "

    public static func shown(_ name: String) -> String {
        name.range(of: sourceMark, options: .backwards).map { String(name[..<$0.lowerBound]) } ?? name
    }

    public static func imageNames(_ messages: [LLMMessage]) -> Set<String> {
        Set(messages.flatMap(\.content).compactMap { if case .image(_, _, let name?, _) = $0 { name } else { nil } })
    }

    /// Replace superseded pixels with a stable label so each later screenshot rewrites only its own recent prefix.
    static func supersede(_ messages: inout [LLMMessage]) {
        func source(_ block: LLMContentBlock) -> (name: String, source: String)? {
            guard case .image(_, _, let name?, _) = block, name.hasPrefix("screenshot of "),
                  let mark = name.range(of: sourceMark, options: .backwards) else { return nil }
            return (name, String(name[mark.upperBound...]))
        }
        var newest: Set<String> = []
        for index in messages.indices.reversed() {
            var content = messages[index].content, changed = false
            for blockIndex in content.indices.reversed() {
                guard let shot = source(content[blockIndex]) else { continue }
                if newest.insert(shot.source).inserted { continue }
                content[blockIndex] = .text("[" + shown(shot.name) + " replaced by a newer one]")
                changed = true
            }
            if changed {
                let message = messages[index]
                messages[index] = LLMMessage(role: message.role, content: content)
            }
        }
    }

    /// Keep Responses function outputs separate from images so an image fast path cannot drop tool outputs.
    public static func continuation(_ blocks: [LLMContentBlock]) -> [LLMMessage] {
        let images = blocks.filter { if case .image = $0 { return true }; return false }
        let results = blocks.filter { if case .image = $0 { return false }; return true }
        var messages: [LLMMessage] = results.isEmpty ? [] : [LLMMessage(role: .user, content: results)]
        if !images.isEmpty { messages.append(LLMMessage(role: .user, content: images)) }
        return messages
    }

    public final class Round: @unchecked Sendable {
        private let lock = NSLock()
        private var images = 0, bytes = 0
        public init() {}
        public var hasRoom: Bool {
            lock.lock(); defer { lock.unlock() }
            return images < roundImages && bytes < roundBytes
        }
        fileprivate func take(_ size: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard images < roundImages, bytes + size <= roundBytes else { return false }
            images += 1; bytes += size
            return true
        }
        fileprivate func giveBack(_ count: Int, _ size: Int) {
            lock.lock(); defer { lock.unlock() }
            images -= count; bytes -= size
        }
    }

    public final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        public let round: Round
        private var images: [LLMContentBlock] = []
        private var taken = 0
        private var closed = false
        public init(round: Round = Round()) { self.round = round }
        fileprivate func accept(_ block: LLMContentBlock) -> Bool {
            guard case .image(_, _, _, let size) = block else { return false }
            lock.lock(); defer { lock.unlock() }
            guard !closed, round.take(size) else { return false }
            images.append(block); taken += size
            return true
        }
        public func finish(success: Bool) -> [LLMContentBlock] {
            lock.lock(); defer { lock.unlock() }
            closed = true
            defer { images = [] }
            if !success { round.giveBack(images.count, taken) }
            return success ? images : []
        }
    }

    /// Encoded produced pixels need no path authorization; enforce the delivery ceiling here rather than trust the caller.
    public static func deliverPNG(
        _ data: Data, name: String, width: Int, height: Int, mediaType: String = "image/png", sink: Sink?
    ) -> JSONValue {
        func failure(_ reason: String) -> JSONValue {
            .object(["ok": .bool(false), "status": .string("failed"), "error": .string(reason)])
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
            return failure(Task.isCancelled ? "Image delivery was cancelled." : roundFull)
        }
        return .object([
            "status": .string("ok"), "image_pixels": .bool(true),
            "name": .string(name),
            "width": .int(Int64(width)), "height": .int(Int64(height)),
            "note": .string("Actual image follows this tool result."),
        ])
    }

}

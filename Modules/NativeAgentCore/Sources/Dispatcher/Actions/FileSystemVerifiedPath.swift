import Foundation
import ImageIO
import NativeAgentCore
import PersistenceCore
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Image pixels decoded from the verified descriptor

/// Decode the bytes the verified descriptor already produced, avoiding the
/// swap window of reopening the path.
enum VerifiedImageRead {

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tif", "tiff", "bmp",
    ]

    static func isImagePath(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func failure(_ reason: String) -> JSONValue {
        .object(["ok": .bool(false), "status": .string("failed"), "error": .string(reason)])
    }

    static func deliver(data: Data, name: String) -> JSONValue {
        guard LocalToolImage.sink != nil else {
            return failure("No image slot for this call: it is text-only, or this round already reads 8 images. Read it in the next call.")
        }
        guard !data.isEmpty, data.count <= LocalToolImage.maximumBytes else {
            return failure("Image must be a nonempty regular file of at most 8 MiB.")
        }
        guard let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
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
        guard let destination = CGImageDestinationCreateWithData(
                encoded, UTType.png.identifier as CFString, 1, nil) else {
            return failure("Could not encode image pixels.")
        }
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= LocalToolImage.maximumBytes else {
            return failure("Encoded image exceeds the 8 MiB delivery limit.")
        }
        let delivered = LocalToolImage.deliverPNG(
            encoded as Data, name: name, width: pixels.width, height: pixels.height)
        // Keep the reader's receipt: it reports the SOURCE dimensions and says
        // what the bounded thumbnail is and is not.
        guard case .object(var fields) = delivered,
              case .string("ok")? = fields["status"] else { return delivered }
        fields["source_width"] = .int(Int64(width))
        fields["source_height"] = .int(Int64(height))
        fields["note"] = .string("Actual image follows this tool result. First frame, oriented and bounded to 2048 pixels; not OCR or a text description.")
        return .object(fields)
    }
}

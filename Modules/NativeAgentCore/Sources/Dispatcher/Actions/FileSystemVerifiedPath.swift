import Foundation
import ImageIO
import NativeAgentCore
import PersistenceCore
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif

// Blueprint: | `FileSystemVerifiedPath.swift` | `VerifiedImageRead`: shared image delivery from verified file or owned Chrome capture bytes; source dimensions and bounded-thumbnail receipts remain intact |

// MARK: - Image pixels decoded from the verified descriptor

/// Decode already admitted bytes, avoiding a file reopen. Chrome's owned-tab
/// capture shares this same image delivery boundary without creating a file.
public enum VerifiedImageRead {

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tif", "tiff", "bmp",
    ]

    static func isImagePath(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func failure(_ reason: String) -> JSONValue {
        .object(["ok": .bool(false), "status": .string("failed"), "error": .string(reason)])
    }

    public static func deliver(data: Data, name: String) -> JSONValue {
        guard LocalToolImage.sink != nil else {
            return failure("No image slot for this call: it is text-only. Read it in a model turn.")
        }
        guard !data.isEmpty, data.count <= LocalToolImage.maximumBytes else {
            return failure("Image must be a nonempty regular file of at most 8 MiB.")
        }
        guard let thumbnail = LocalToolImage.thumbnail(data, maxPixelSize: 2048) else {
            return failure("Image is unreadable, unsupported, or exceeds the 40-megapixel limit.")
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                encoded, UTType.png.identifier as CFString, 1, nil) else {
            return failure("Could not encode image pixels.")
        }
        CGImageDestinationAddImage(destination, thumbnail.pixels, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= LocalToolImage.maximumBytes else {
            return failure("Encoded image exceeds the 8 MiB delivery limit.")
        }
        let delivered = LocalToolImage.deliverPNG(
            encoded as Data, name: name, width: thumbnail.pixels.width, height: thumbnail.pixels.height)
        // Keep the reader's receipt: it reports the SOURCE dimensions and says
        // what the bounded thumbnail is and is not.
        guard case .object(var fields) = delivered,
              case .string("ok")? = fields["status"] else { return delivered }
        fields["source_width"] = .int(Int64(thumbnail.sourceWidth))
        fields["source_height"] = .int(Int64(thumbnail.sourceHeight))
        fields["note"] = .string("Actual image follows this tool result. First frame, oriented and bounded to 2048 pixels; not OCR or a text description.")
        return .object(fields)
    }
}

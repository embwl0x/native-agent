import Foundation
import ChatToolParsing
import ImageIO
import NativeAgentCore
import PersistenceCore
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif

// Blueprint: | `FileSystemVerifiedPath.swift` | `VerifiedImageRead`: verified file/Chrome bytes; metadata never claims pixel delivery |

// MARK: - Image pixels decoded from the verified descriptor

/// Decode admitted bytes without reopening a path; owned Chrome captures share this delivery boundary.
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

    public static func deliver(data: Data, name: String, sink: LocalToolImage.Sink?) -> JSONValue {
        guard !data.isEmpty, data.count <= LocalToolImage.maximumBytes else {
            return failure("Image must be a nonempty regular file of at most 8 MiB.")
        }
        guard let thumbnail = LocalToolImage.thumbnail(data, maxPixelSize: 2048) else {
            return failure("Image is unreadable, unsupported, or exceeds the 40-megapixel limit.")
        }
        guard sink != nil else {
            // Derive type and pixels from the admitted bytes; filename extensions cannot prove encoding.
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) else {
                return failure("Could not read the image's encoded type.")
            }
            return .object([
                "status": .string("ok"), "image_pixels": .bool(false), "read_only": .bool(true),
                "name": .string(name), "bytes": .int(Int64(data.count)),
                "type": .string(type as String),
                "source_width": .int(Int64(thumbnail.sourceWidth)),
                "source_height": .int(Int64(thumbnail.sourceHeight)),
                "note": .string("Verified image metadata only; this call has no image slot. To see the pixels, use files.read on this file from a turn."),
            ])
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
        let reply = ToolResult(LocalToolImage.deliverPNG(
            encoded as Data, name: name, width: thumbnail.pixels.width, height: thumbnail.pixels.height, sink: sink))
        // Retain source dimensions and the bounded-thumbnail distinction so delivery cannot imply full-resolution pixels.
        guard reply.said("ok"), case .object(var fields) = reply.payload else { return reply.payload }
        fields["source_width"] = .int(Int64(thumbnail.sourceWidth))
        fields["source_height"] = .int(Int64(thumbnail.sourceHeight))
        fields["note"] = .string("Actual image follows this result. First frame, oriented and bounded to 2048 pixels; not OCR or a text description.")
        return .object(fields)
    }
}

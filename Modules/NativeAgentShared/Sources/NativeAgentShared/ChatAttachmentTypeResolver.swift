import Foundation

/// Supported chat files have the same type and byte ceiling on every door.
public enum ChatAttachmentTypeResolver {
    public static let fileByteLimit = 10_000_000

    public static func typeAndMime(forExtension ext: String) -> (type: String, mime: String)? {
        switch ext.lowercased() {
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
        case "txt", "md":
            return ("file", "text/plain")
        default:
            return nil
        }
    }
}

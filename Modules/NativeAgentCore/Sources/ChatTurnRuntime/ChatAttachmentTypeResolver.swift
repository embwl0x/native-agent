import Foundation

/// The attachment type and MIME for a file extension the composer and the
/// agent-contact wire both accept.
public enum ChatAttachmentTypeResolver {
    public static func typeAndMime(forExtension ext: String) -> (type: String, mime: String)? {
        switch ext {
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
        case "docx":
            return ("file", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        case "txt", "md":
            return ("file", "text/plain")
        default:
            return nil
        }
    }
}

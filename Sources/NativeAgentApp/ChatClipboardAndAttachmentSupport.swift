import AppKit

enum ChatClipboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum ChatAttachmentTypeResolver {
    static func typeAndMime(forExtension ext: String) -> (type: String, mime: String)? {
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

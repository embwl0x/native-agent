import Foundation
// Blueprint: | `ChatAttachmentTypeResolver.swift` | `ChatAttachmentTypeResolver` enum; `typeAndMime`, `fileByteLimit`, `submittingSpeech` keeps composer wording on its utterances |

/// Supported chat files have the same type and byte ceiling on every door.
public enum ChatAttachmentTypeResolver {
    public static let fileByteLimit = 10_000_000

    /// The composer submits one wording for its recordings, including typed context.
    public static func submittingSpeech(_ attachments: [MultimodalAttachment], text: String) -> [MultimodalAttachment] {
        attachments.map {
            var attachment = $0
            if attachment.utterance != nil { attachment.utterance?.correctedText = text }
            return attachment
        }
    }

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

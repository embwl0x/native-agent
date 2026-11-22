import Foundation
// Blueprint: | `ChatAttachmentTypeResolver.swift` | Chat file types and byte limits, speech correction in attachments, and voice-draft joining |

/// Supported chat files have the same type and byte ceiling on every door.
public enum ChatAttachmentTypeResolver {
    public static let fileByteLimit = 10_000_000

    public static func voiceDraft(base: String, transcript: String) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return spoken }
        if spoken.isEmpty { return base }
        return base + " " + spoken
    }

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

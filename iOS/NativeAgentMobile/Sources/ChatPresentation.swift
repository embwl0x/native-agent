import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared
// Blueprint: | `ChatPresentation.swift` | Chat controls and picker presentation; model controls read the shared `iCloudSyncEngine.surfaceModels` projection |

enum ChatSessionTabPresentation {
    static func isSelectionDisabled(isSwitchingSession: Bool, isClosingSession: Bool) -> Bool {
        isSwitchingSession || isClosingSession
    }
}

enum ChatRuntimeControlPresentation {
    static func processingModeTitle(fastMode: Bool) -> String {
        fastMode ? "Fast" : "Normal"
    }

    static func normalizedFileAccessID(_ id: String) -> String {
        ICloudChatFileAccessPolicy.normalized(id)
    }
}


actor ChatAttachmentPresentation {
    static let shared = ChatAttachmentPresentation()
    private var entries: [String: (summary: ChatAttachmentSummary, image: UIImage?)] = [:]
    private var recency: [String] = []

    func images(in attachments: [ChatAttachmentSummary]) -> [(summary: ChatAttachmentSummary, image: UIImage)] {
        attachments.compactMap { attachment in
            recency.removeAll { $0 == attachment.id }
            recency.append(attachment.id)
            if entries[attachment.id]?.summary != attachment {
                let image: UIImage?
                if attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image",
                   let raw = attachment.base64?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let data = Data(base64Encoded: raw) {
                    image = MobileChatAttachmentPreparation.thumbnail(from: data, maxDimension: 780)
                } else { image = nil }
                entries[attachment.id] = (attachment, image)
            }
            let image = entries[attachment.id]?.image
            if recency.count > 128 { entries.removeValue(forKey: recency.removeFirst()) }
            return image.map { (attachment, $0) }
        }
    }
}

enum PhotosPickerLoadPresentation {
    /// Photos can return selections too large for CloudKit; if none fit, say none were added because no thumbnail strip can show the rejection.
    static func message(loadedCount: Int, skippedCount: Int) -> String? {
        guard skippedCount > 0 else { return nil }
        if loadedCount == 0 {
            return skippedCount == 1
                ? "No photo was added because it was too large or unsupported. Try a smaller image."
                : "No photos were added because all \(skippedCount) were too large or unsupported. Try smaller images."
        }
        return skippedCount == 1
            ? "One photo was too large or unsupported; \(loadedCount) photo\(loadedCount == 1 ? "" : "s") is ready to send."
            : """
                \(skippedCount) photos were too large or unsupported; \(loadedCount) photo\(loadedCount == 1 ? "" : "s") \(loadedCount == 1 ? "is" : "are") \
                ready to send.
                """
    }
}

enum VoicePresentation {
    static func deniedSpeechMessage() -> String {
        "Speech recognition permission denied. Enable it in Settings."
    }

    static func deniedMicrophoneMessage() -> String {
        "Microphone permission denied. Enable it in Settings."
    }

}

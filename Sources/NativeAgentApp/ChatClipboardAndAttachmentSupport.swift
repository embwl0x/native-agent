import AppKit
import Foundation
// Blueprint: | `ChatClipboardAndAttachmentSupport.swift` | Clipboard writes requested through the body settings owner |

enum ChatClipboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

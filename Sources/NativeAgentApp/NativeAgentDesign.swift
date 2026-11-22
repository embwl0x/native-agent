import NativeAgentShared
import SwiftUI
// Blueprint: | `NativeAgentDesign.swift` | AppKit transcript preparation tokens shared with the window's typography and geometry |

enum NativeAgentShell {
    static let trouble    = Color.adaptive(dark: 0xFF9F0A, light: 0x864800)
}

enum ShellType {
    static let captionSize: CGFloat = 11
    static let labelSize: CGFloat = 13
    static let bodySize: CGFloat = 16
}

enum NativeAgentShellLayout {
    static let roomGutter: CGFloat = 16
    static let userBubbleMaxWidth: CGFloat = 640
    static let replyLineSpacing: CGFloat = 8
    static let transcriptGap: CGFloat = 16
}

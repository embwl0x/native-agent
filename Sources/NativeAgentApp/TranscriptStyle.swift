import AppKit
import NativeAgentShared
import SwiftUI

// Blueprint: | `TranscriptStyle.swift` | The Mac's transcript look (AppKit tokens at the reader's text scale) for the press's Shared renderer |

extension TranscriptLook {
    /// The app's tokens as the document lays them out (NativeAgentShellLayout, ShellType and NativeAgentSpacing), at the reader's
    /// ⌘+/⌘− scale. The text container includes the room's gutters.
    static func mac(scale: CGFloat) -> TranscriptLook {
        func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            .systemFont(ofSize: (size * scale).rounded(), weight: weight)
        }
        let replyLineSpacing = NativeAgentShellLayout.replyLineSpacing
        let userLineSpacing: CGFloat = 2
        let listMarkerColumn: CGFloat = 20
        let listMarkerGap = NativeAgentSpacing.sm
        return TranscriptLook(
            gutter: NativeAgentShellLayout.roomGutter, userSeatRoom: 60, userTextMax: NativeAgentShellLayout.userBubbleMaxWidth,
            bubblePadH: NativeAgentSpacing.lg, replyLineSpacing: replyLineSpacing, userLineSpacing: userLineSpacing,
            // A user row's quiet line keeps the bubble's spacing; every other quiet line reads as a reply.
            quietLineSpacing: { role in role == "user" ? userLineSpacing : replyLineSpacing },
            listMarkerColumn: listMarkerColumn, listMarkerGap: listMarkerGap,
            listIndent: { depth in CGFloat(max(0, depth)) * (listMarkerColumn + listMarkerGap) },
            quoteIndent: NativeAgentSpacing.md, foldIndent: 18, codePad: NativeAgentSpacing.sm,
            messageGap: NativeAgentShellLayout.transcriptGap,
            body: font(ShellType.bodySize), quiet: font(ShellType.labelSize), heading: font(ShellType.bodySize, .semibold),
            code: .monospacedSystemFont(ofSize: (ShellType.labelSize * scale).rounded(), weight: .regular),
            caption: font(ShellType.captionSize), foldHeadline: font(ShellType.labelSize, .medium),
            codeLabel: font(NSFont.preferredFont(forTextStyle: .caption2).pointSize, .medium),
            label: .labelColor, secondary: .secondaryLabelColor, listMarker: .labelColor, trouble: { NSColor(NativeAgentShell.trouble) },
            styleLink: { _, _, attributes in attributes[.foregroundColor] = NSColor.controlAccentColor },
            foldLink: { group in TranscriptFoldLink.url(group) })
    }
}

extension TranscriptRenderer {
    /// The press's render call: the Mac's look at the reader's width and scale.
    nonisolated static func prepare(_ block: TranscriptBlock, width: Double, scale: Double) throws -> TranscriptRenderedParagraph {
        try TranscriptRenderer(width: CGFloat(width), look: .mac(scale: CGFloat(scale))).prepared(block)
    }
}

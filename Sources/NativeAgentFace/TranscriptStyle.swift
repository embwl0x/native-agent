import AppKit
import Foundation
import NativeAgentShared
import SwiftUI

// Blueprint: | `TranscriptStyle.swift` | Layout tokens and text scale |

enum TranscriptMetrics {
    static let column = NativeAgentShellLayout.roomColumn
    static let gutter = NativeAgentShellLayout.roomGutter
    static let bubblePadH: CGFloat = NativeAgentSpacing.lg
    static let bubblePadV: CGFloat = NativeAgentSpacing.md
    static let userCorners = NativeAgentShellLayout.userBubbleCorners
    static let codePadH: CGFloat = NativeAgentSpacing.sm
    static let codePadV: CGFloat = NativeAgentSpacing.sm
    static let codeRadius = NativeAgentRadius.card
    static let documentInset: CGFloat = NativeAgentSpacing.sm
    static let topFade: CGFloat = 24
    /// Text fades out across the clearance between the reading bottom and the composer's top edge, so none shows under the glass.
    static let bottomFade: CGFloat = NativeAgentShellLayout.composerClearanceMargin
}

enum TranscriptInk {
    static var userBubble: NSColor { NSColor(NativeAgentShell.softFill) }
    static var codeFill: NSColor { NSColor(NativeAgentShell.quietFill) }
    static var trouble: NSColor { NSColor(NativeAgentShell.trouble) }
    static var hairline: NSColor { NSColor(NativeAgentShell.hairline) }
}

/// ⌘+ and ⌘− scale every transcript's text; the scale persists and every open transcript follows it.
@MainActor
enum TranscriptTextScale {
    static let defaultsKey = "transcriptTextScale"
    struct Changed: NotificationCenter.MainActorMessage {
        typealias Subject = NSObject
    }
    static let range: ClosedRange<Double> = 0.8...1.6
    static let step = 0.1

    /// No stored value is the shipped scale, 1.
    static var value: CGFloat {
        let stored = UserDefaults.standard.double(forKey: defaultsKey)
        return CGFloat(stored == 0 ? 1 : min(max(stored, range.lowerBound), range.upperBound))
    }

    static func nudge(_ direction: Int) {
        let next = min(max(Double(value) + step * Double(direction), range.lowerBound), range.upperBound)
        let rounded = (next * 10).rounded() / 10
        guard rounded != Double(value) else { return }
        UserDefaults.standard.set(rounded, forKey: defaultsKey)
        NotificationCenter.default.post(Changed())
    }
}

import Foundation
import NativeAgentShared
import SwiftUI
import UIKit

// Blueprint: | `MobileTranscriptStyle.swift` | The phone's transcript look (UIKit tokens at the reader's text size) for the press's Shared renderer, and action links |

/// The phone's tokens as the document lays them out: the 740 pt room column inside the page inset, bubbles, code insets and gaps.
enum TranscriptMetrics {
    /// Room above a user bubble for its provenance or bridge line.
    static let tagSpace: CGFloat = 16
    static let column = NativeAgentMobileTheme.Layout.roomColumn
    /// The column never comes closer than this to the screen's edges.
    static let pageInset: CGFloat = 20
    static let documentInset: CGFloat = NativeAgentSpacing.md
    static let bubblePadH: CGFloat = 14
    static let bubblePadV: CGFloat = 10
    static let userCorners = (topLeading: CGFloat(18), topTrailing: CGFloat(18), bottomTrailing: CGFloat(6), bottomLeading: CGFloat(18))
    static let codePad: CGFloat = NativeAgentSpacing.md
    /// The strip above the code that holds its language, when it has one.
    static let codeHeader: CGFloat = 22
    static let codeRadius: CGFloat = 12
}

enum TranscriptInk {
    static var userBubble: UIColor { UIColor(NativeAgentMobileTheme.Colors.softFill) }
    static var codeFill: UIColor { UIColor(NativeAgentMobileTheme.Colors.quietFill) }
    static var hairline: UIColor { UIColor(NativeAgentMobileTheme.Colors.hairline) }
    static var trouble: UIColor { UIColor(NativeAgentMobileTheme.Colors.trouble) }
    static var action: UIColor { UIColor(NativeAgentMobileTheme.Colors.accentText) }
}

/// A row's button as words in the document: one scheme only this view opens, read back into what it asks for.
enum TranscriptLink: Equatable {
    case fold(String)
    case olderHistory
    case sendNow(UUID)
    case wholeMessage(UUID)
    case retrySend(UUID)

    static let scheme = "nativeagent-transcript"

    /// Hierarchical (`nativeagent-transcript:///<action>/<value>`): an opaque URL has no path to read the value back from.
    var url: URL {
        get throws {
            let path: String
            switch self {
            case .fold(let group): path = "/fold/" + group
            case .olderHistory: path = "/older"
            case .sendNow(let id): path = "/send-now/" + id.uuidString
            case .wholeMessage(let id): path = "/whole/" + id.uuidString
            case .retrySend(let id): path = "/retry/" + id.uuidString
            }
            var parts = URLComponents()
            parts.scheme = Self.scheme
            parts.host = ""
            parts.path = path
            guard let url = parts.url else {
                throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "The transcript action URL could not be encoded."])
            }
            return url
        }
    }

    init?(_ url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        let parts = url.path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let action = parts.first else { return nil }
        let value = parts.count > 1 ? parts[1] : ""
        switch action {
        case "fold" where !value.isEmpty: self = .fold(value)
        case "older": self = .olderHistory
        case "send-now": guard let id = UUID(uuidString: value) else { return nil }; self = .sendNow(id)
        case "whole": guard let id = UUID(uuidString: value) else { return nil }; self = .wholeMessage(id)
        case "retry": guard let id = UUID(uuidString: value) else { return nil }; self = .retrySend(id)
        default: return nil
        }
    }
}

extension TranscriptLook {
    /// The phone's tokens at the reader's captured text-size category: Dynamic Type fonts, and a text container that is the column
    /// itself, so nothing is inset for gutters.
    static func phone(category: String) -> TranscriptLook {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(rawValue: category))
        func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight? = nil) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
            guard let weight else { return base }
            return .systemFont(ofSize: base.pointSize, weight: weight)
        }
        let quiet = font(.footnote)
        let listMarkerColumn: CGFloat = 20
        let listMarkerGap = NativeAgentSpacing.sm
        return TranscriptLook(
            gutter: 0, userSeatRoom: 48, userTextMax: 560, bubblePadH: TranscriptMetrics.bubblePadH, replyLineSpacing: 6,
            userLineSpacing: 3, quietLineSpacing: { _ in 2 }, listMarkerColumn: listMarkerColumn, listMarkerGap: listMarkerGap,
            // Nesting past eight levels stays at eight, each level half a marker column and gap.
            listIndent: { depth in CGFloat(min(max(0, depth), 8)) * (listMarkerColumn + listMarkerGap) / 2 },
            // A fold's text sits past its chevron.
            quoteIndent: NativeAgentSpacing.md, foldIndent: 18, codePad: TranscriptMetrics.codePad,
            // The space between one message (or card, or other-room row) and the next.
            messageGap: 26,
            body: font(.body), quiet: quiet, heading: font(.headline),
            code: .monospacedSystemFont(ofSize: quiet.pointSize, weight: .regular), caption: font(.caption1),
            foldHeadline: quiet, codeLabel: font(.caption2, .medium),
            label: .label, secondary: .secondaryLabel, listMarker: .secondaryLabel, trouble: { TranscriptInk.trouble },
            // An action link reads as a control; a markdown link as underlined words.
            styleLink: { link, base, attributes in
                if TranscriptLink(link) != nil {
                    attributes[.font] = try TranscriptRenderer.styled(base, bold: true, italic: false, code: false)
                    attributes[.foregroundColor] = TranscriptInk.action
                } else {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            },
            foldLink: { group in try TranscriptLink.fold(group).url })
    }
}

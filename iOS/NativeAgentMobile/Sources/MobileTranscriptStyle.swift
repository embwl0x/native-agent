import NativeAgentShared
import SwiftUI
import UIKit

// Blueprint: | `MobileTranscriptStyle.swift` | The phone document's look: paragraph keys, tokens in UIKit units, one block as one paragraph, action links |

/// What a paragraph carries. Fragments, hit testing, the menu and Copy as Markdown read these; nothing reads a measured height.
enum TranscriptKey {
    static let blockID = NSAttributedString.Key("transcript.blockID")
    static let messageID = NSAttributedString.Key("transcript.messageID")
    /// `TranscriptParagraph` raw value; picks the layout fragment class.
    static let kind = NSAttributedString.Key("transcript.kind")
    /// The block's markdown source, read by Copy as Markdown.
    static let source = NSAttributedString.Key("transcript.source")
    /// Space above the paragraph (NSNumber, pt). Spacing lives in fragment margins, never in NSParagraphStyle spacing.
    static let topGap = NSAttributedString.Key("transcript.topGap")
    /// On a fold headline: the tool-run group it opens.
    static let foldOpens = NSAttributedString.Key("transcript.foldOpens")
    /// On a folded paragraph: the group it hides with while closed.
    static let foldGroup = NSAttributedString.Key("transcript.foldGroup")
    /// A code block's language and the font it is drawn in, in its inset's header.
    static let language = NSAttributedString.Key("transcript.language")
    static let languageFont = NSAttributedString.Key("transcript.languageFont")
}

enum TranscriptParagraph: String {
    case user, reply, heading, quote, listItem, code, foldHeadline, foldDetail, gap, attachment

    init(_ kind: TranscriptBlock.Kind) {
        switch kind {
        case .user: self = .user
        case .reply: self = .reply
        case .heading: self = .heading
        case .quote: self = .quote
        case .listItem: self = .listItem
        case .code: self = .code
        case .foldHeadline: self = .foldHeadline
        case .foldDetail: self = .foldDetail
        case .gap: self = .gap
        case .attachment: self = .attachment
        }
    }

    static func of(_ paragraph: NSTextParagraph) -> TranscriptParagraph? {
        let text = paragraph.attributedString
        guard text.length > 0, let raw = text.attribute(TranscriptKey.kind, at: 0, effectiveRange: nil) as? String else { return nil }
        return TranscriptParagraph(rawValue: raw)
    }
}

/// The phone's tokens as the document lays them out: the 740 pt room column inside the page inset, bubbles, code insets and gaps.
enum TranscriptMetrics {
    static let column = NativeAgentMobileTheme.Layout.roomColumn
    /// The column never comes closer than this to the screen's edges.
    static let pageInset: CGFloat = 20
    static let documentInset: CGFloat = NativeAgentSpacing.md
    /// A user bubble never comes closer than this to the column's leading edge.
    static let userSeatRoom: CGFloat = 48
    static let userTextMax: CGFloat = 560
    static let bubblePadH: CGFloat = 14
    static let bubblePadV: CGFloat = 10
    static let userCorners = (topLeading: CGFloat(18), topTrailing: CGFloat(18), bottomTrailing: CGFloat(6), bottomLeading: CGFloat(18))
    static let replyLineSpacing: CGFloat = 6
    static let userLineSpacing: CGFloat = 3
    static let listMarkerColumn: CGFloat = 20
    static let listMarkerGap: CGFloat = NativeAgentSpacing.sm
    static let quoteIndent: CGFloat = NativeAgentSpacing.md
    /// A fold's text sits past its chevron.
    static let foldIndent: CGFloat = 18
    /// `StreamingParagraphText.paragraphGap`, the gap between a reply's paragraphs.
    static let paragraphGap: CGFloat = 10
    /// The space between one message (or card, or other-room row) and the next.
    static let messageGap: CGFloat = 26
    static let codePad: CGFloat = NativeAgentSpacing.md
    /// The strip above the code that holds its language, when it has one.
    static let codeHeader: CGFloat = 22
    static let codeRadius: CGFloat = 12

    static func topGap(_ lead: TranscriptBlock.Lead) -> CGFloat {
        switch lead {
        case .none: 0
        case .message: messageGap
        case .paragraph: paragraphGap
        case .listItem: NativeAgentSpacing.xs
        case .detail: NativeAgentSpacing.xs
        case .gap: messageGap + NativeAgentSpacing.sm
        }
    }
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
        return parts.url ?? URL(fileURLWithPath: "/")
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

/// Renders one block as one paragraph. Every paragraph is one NSTextParagraph: newlines inside a block become line separators.
/// Fonts follow the reader's text size through `traits`.
@MainActor
struct TranscriptRenderer {
    /// The text container's width: the column, or less on a narrow screen.
    let width: CGFloat
    let traits: UITraitCollection
    let attachment: (TranscriptBlock, TranscriptAttachmentRef) -> NSTextAttachment

    func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight? = nil) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        guard let weight else { return base }
        return .systemFont(ofSize: base.pointSize, weight: weight)
    }

    var body: UIFont { font(.body) }
    var quiet: UIFont { font(.footnote) }
    var code: UIFont { .monospacedSystemFont(ofSize: font(.footnote).pointSize, weight: .regular) }

    /// The paragraph without its source; the controller stamps the source when it installs it, so a growing reply compares by look alone.
    func paragraph(_ block: TranscriptBlock) -> NSMutableAttributedString {
        render(block).body
    }

    /// The paragraph and the separator that ends it, sharing one set of paragraph attributes (a bubble is measured once).
    func render(_ block: TranscriptBlock) -> (body: NSMutableAttributedString, separator: NSAttributedString) {
        let attributes = paragraphAttributes(block)
        let body: NSMutableAttributedString
        switch block.kind {
        case .user(let runs, _):
            body = inline(runs, font: self.body, color: .label)
        case .reply(let runs, let ink):
            body = ink == .quiet ? inline(runs, font: quiet, color: .secondaryLabel) : inline(runs, font: self.body, color: .label)
        case .heading(let runs):
            body = inline(runs, font: font(.headline), color: .label)
        case .quote(let runs):
            body = inline(runs, font: self.body, color: .secondaryLabel)
        case .listItem(let marker, _, let runs):
            body = NSMutableAttributedString(string: "\t" + marker + "\t", attributes: [.font: self.body, .foregroundColor: UIColor.secondaryLabel])
            body.append(inline(runs, font: self.body, color: .label))
        case .code(_, let text):
            body = NSMutableAttributedString(string: Self.oneParagraph(text), attributes: [.font: code, .foregroundColor: UIColor.label])
        case .foldHeadline(let text, let failed):
            // The headline is a link to its own run, so a tap and a VoiceOver activation open it alike.
            body = NSMutableAttributedString(string: Self.oneParagraph(text), attributes: [
                .font: quiet, .foregroundColor: failed ? TranscriptInk.trouble : UIColor.secondaryLabel,
                .link: TranscriptLink.fold(block.messageID).url,
            ])
        case .foldDetail(let text, let failed):
            body = NSMutableAttributedString(string: Self.oneParagraph(text), attributes: [
                .font: quiet, .foregroundColor: failed ? TranscriptInk.trouble : UIColor.secondaryLabel,
            ])
        case .gap(let date):
            body = NSMutableAttributedString(string: Self.gapLabel(date), attributes: [
                .font: font(.caption1), .foregroundColor: UIColor.secondaryLabel,
            ])
        case .attachment(let ref):
            body = NSMutableAttributedString(attachment: attachment(block, ref))
            body.addAttribute(.font, value: self.body, range: NSRange(location: 0, length: body.length))
        }
        // An empty block still draws one line.
        if body.length == 0 { body.append(NSAttributedString(string: " ", attributes: [.font: baseFont(block)])) }
        body.addAttributes(attributes, range: NSRange(location: 0, length: body.length))
        return (body, separator(block, attributes))
    }

    /// The paragraph separator belongs to the paragraph it ends and carries that paragraph's own attributes, nothing that draws.
    func separator(_ block: TranscriptBlock) -> NSAttributedString {
        separator(block, paragraphAttributes(block))
    }

    private func separator(_ block: TranscriptBlock, _ paragraph: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = paragraph
        attributes[.font] = baseFont(block)
        return NSAttributedString(string: "\n", attributes: attributes)
    }

    private func baseFont(_ block: TranscriptBlock) -> UIFont {
        switch block.kind {
        case .code: code
        case .foldHeadline, .foldDetail: quiet
        case .gap: font(.caption1)
        case .reply(_, let ink): ink == .quiet ? quiet : body
        default: body
        }
    }

    private func paragraphAttributes(_ block: TranscriptBlock) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            TranscriptKey.kind: TranscriptParagraph(block.kind).rawValue,
            TranscriptKey.blockID: block.id,
            TranscriptKey.messageID: block.messageID,
            TranscriptKey.topGap: NSNumber(value: Double(TranscriptMetrics.topGap(block.lead))),
            .paragraphStyle: style(block),
        ]
        if let group = block.foldGroup { attributes[TranscriptKey.foldGroup] = group }
        switch block.kind {
        case .foldHeadline:
            attributes[TranscriptKey.foldOpens] = block.messageID
        case .code(let language, _) where !language.isEmpty:
            attributes[TranscriptKey.language] = language
            attributes[TranscriptKey.languageFont] = font(.caption2, .medium)
        default:
            break
        }
        return attributes
    }

    private func style(_ block: TranscriptBlock) -> NSParagraphStyle {
        switch block.kind {
        case .user(let runs, _):
            return userStyle(runs)
        case .reply(_, let ink):
            return Self.style(head: 0, tail: 0, lineSpacing: ink == .quiet ? 2 : TranscriptMetrics.replyLineSpacing)
        case .heading:
            return Self.style(head: 0, tail: 0, lineSpacing: TranscriptMetrics.replyLineSpacing)
        case .quote:
            return Self.style(head: TranscriptMetrics.quoteIndent, tail: 0, lineSpacing: TranscriptMetrics.replyLineSpacing)
        case .listItem(_, let depth, _):
            let first = CGFloat(min(max(0, depth), 8)) * (TranscriptMetrics.listMarkerColumn + TranscriptMetrics.listMarkerGap) / 2
            let marker = first + TranscriptMetrics.listMarkerColumn
            let text = marker + TranscriptMetrics.listMarkerGap
            return Self.style(head: text, first: first, tail: 0, lineSpacing: TranscriptMetrics.replyLineSpacing,
                              tabs: [NSTextTab(textAlignment: .right, location: marker, options: [:]),
                                     NSTextTab(textAlignment: .left, location: text, options: [:])])
        case .code:
            return Self.style(head: TranscriptMetrics.codePad, tail: -TranscriptMetrics.codePad, lineSpacing: 2)
        case .foldHeadline, .foldDetail:
            return Self.style(head: TranscriptMetrics.foldIndent, tail: 0, lineSpacing: 2)
        case .gap:
            return Self.style(head: 0, tail: 0, lineSpacing: 0, alignment: .center)
        case .attachment:
            return Self.style(head: 0, tail: 0, lineSpacing: 0)
        }
    }

    /// Right-seated and hugging its text: the text box is measured, then indented from the leading edge so it ends inside the column's
    /// trailing edge by the bubble's padding.
    private func userStyle(_ runs: [TranscriptRun]) -> NSParagraphStyle {
        let measure = inline(runs, font: body, color: .label)
        if measure.length == 0 { measure.append(NSAttributedString(string: " ", attributes: [.font: body])) }
        measure.addAttribute(.paragraphStyle, value: Self.style(head: 0, tail: 0, lineSpacing: TranscriptMetrics.userLineSpacing),
                             range: NSRange(location: 0, length: measure.length))
        let pad = TranscriptMetrics.bubblePadH
        let room = width - TranscriptMetrics.userSeatRoom - 2 * pad
        let widest = max(1, min(TranscriptMetrics.userTextMax, room))
        let bounds = measure.boundingRect(with: CGSize(width: widest, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        // Two points of slack so TextKit's line breaking never wraps a line the measurement kept whole.
        let textWidth = min(widest, ceil(bounds.width) + 2)
        let textRight = width - pad
        return Self.style(head: textRight - textWidth, tail: -pad, lineSpacing: TranscriptMetrics.userLineSpacing)
    }

    static func style(head: CGFloat, first: CGFloat? = nil, tail: CGFloat, lineSpacing: CGFloat, alignment: NSTextAlignment = .natural,
                      tabs: [NSTextTab] = []) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = head
        style.firstLineHeadIndent = first ?? head
        style.tailIndent = tail
        style.lineSpacing = lineSpacing
        style.alignment = alignment
        style.tabStops = tabs
        return style
    }

    /// A markdown link is underlined in the text's own ink, as the phone's replies always drew them; an action link reads as a control.
    func inline(_ runs: [TranscriptRun], font base: UIFont, color: UIColor) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for run in runs where !run.text.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: styled(base, bold: run.bold, italic: run.italic, code: run.code), .foregroundColor: color,
            ]
            if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                if TranscriptLink(link) != nil {
                    attributes[.font] = styled(base, bold: true, italic: false, code: false)
                    attributes[.foregroundColor] = TranscriptInk.action
                } else {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            out.append(NSAttributedString(string: Self.oneParagraph(run.text), attributes: attributes))
        }
        return out
    }

    private func styled(_ base: UIFont, bold: Bool, italic: Bool, code: Bool) -> UIFont {
        var font = base
        if code {
            font = .monospacedSystemFont(ofSize: (base.pointSize - 1.5).rounded(), weight: bold ? .semibold : .regular)
        } else if bold {
            font = .systemFont(ofSize: base.pointSize, weight: .semibold)
        }
        if italic, let slanted = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            font = UIFont(descriptor: slanted, size: font.pointSize)
        }
        return font
    }

    /// Line breaks inside a block become line separators, so the block stays exactly one paragraph.
    static func oneParagraph(_ text: String) -> String {
        guard text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" || $0 == "\u{2029}" || $0 == "\u{85}" }) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\u{2028}")
            .replacingOccurrences(of: "\r", with: "\u{2028}")
            .replacingOccurrences(of: "\n", with: "\u{2028}")
            .replacingOccurrences(of: "\u{2029}", with: "\u{2028}")
            .replacingOccurrences(of: "\u{85}", with: "\u{2028}")
    }

    /// "Today 3:04 PM" after an hour of quiet.
    static func gapLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

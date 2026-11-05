import AppKit
import NativeAgentShared
import SwiftUI

// Blueprint: | `TranscriptStyle.swift` | The document's look: paragraph attribute keys, the app's tokens in AppKit units, one block rendered as one paragraph |

/// What a paragraph carries. Fragments, hit testing, the menu and Copy as Markdown read these; nothing reads a measured height.
enum TranscriptKey {
    static let blockID = NSAttributedString.Key("transcript.blockID")
    static let messageID = NSAttributedString.Key("transcript.messageID")
    static let role = NSAttributedString.Key("transcript.role")
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
    /// A user bubble's provenance or bridge line, drawn above the bubble.
    static let tagSymbol = NSAttributedString.Key("transcript.tagSymbol")
    static let tagLabel = NSAttributedString.Key("transcript.tagLabel")
    static let tagAutomated = NSAttributedString.Key("transcript.tagAutomated")
    /// A code block's language, drawn in its inset's header.
    static let language = NSAttributedString.Key("transcript.language")
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

/// The app's tokens as the document lays them out (NativeAgentShellLayout, ShellType, ChatPreparedContent, ChatCodeBlockView).
enum TranscriptMetrics {
    static let column = NativeAgentShellLayout.roomColumn
    static let gutter = NativeAgentShellLayout.roomGutter
    static let userTextMax = NativeAgentShellLayout.userBubbleMaxWidth
    /// A user bubble never comes closer than this to the column's leading edge.
    static let userSeatRoom: CGFloat = 60
    static let bubblePadH: CGFloat = NativeAgentSpacing.lg
    static let bubblePadV: CGFloat = NativeAgentSpacing.md
    static let userCorners = NativeAgentShellLayout.userBubbleCorners
    static let replyLineSpacing = NativeAgentShellLayout.replyLineSpacing
    static let userLineSpacing: CGFloat = 2
    static let listMarkerColumn: CGFloat = 20
    static let listMarkerGap: CGFloat = NativeAgentSpacing.sm
    static let quoteIndent: CGFloat = NativeAgentSpacing.md
    /// `ChatActivityRow.indent`: a fold's text sits past its chevron.
    static let foldIndent: CGFloat = 18
    /// `StreamingParagraphText.paragraphGap`, the gap between a reply's paragraphs.
    static let paragraphGap: CGFloat = 10
    static let codePadH: CGFloat = NativeAgentSpacing.sm
    static let codePadV: CGFloat = NativeAgentSpacing.sm
    /// The strip above the code that holds its language label and copy button.
    static let codeHeader: CGFloat = 22
    static let codeRadius = NativeAgentRadius.card
    /// The space the provenance line takes above a user bubble.
    static let tagSpace: CGFloat = 16
    static let documentInset: CGFloat = NativeAgentSpacing.sm
    static let topFade: CGFloat = 24
    /// Text fades out across the clearance between the reading bottom and the composer's top edge, so none shows under the glass.
    static let bottomFade: CGFloat = NativeAgentShellLayout.composerClearanceMargin

    static func topGap(_ lead: TranscriptBlock.Lead) -> CGFloat {
        switch lead {
        case .none: 0
        case .message: NativeAgentShellLayout.transcriptGap
        case .paragraph: paragraphGap
        case .listItem: NativeAgentSpacing.xs
        case .detail: NativeAgentSpacing.xs
        case .gap: NativeAgentShellLayout.transcriptGap + NativeAgentSpacing.sm
        }
    }
}

enum TranscriptInk {
    static var userBubble: NSColor { NSColor(NativeAgentShell.softFill) }
    static var codeFill: NSColor { NSColor(NativeAgentShell.quietFill) }
    static var trouble: NSColor { NSColor(NativeAgentShell.trouble) }
    static var hairline: NSColor { NSColor(NativeAgentShell.hairline) }
}

/// Renders one block as one paragraph. Every paragraph is one NSTextParagraph: newlines inside a block become line separators.
@MainActor
struct TranscriptRenderer {
    /// The text container's width: the column, or less in a narrow window.
    let width: CGFloat
    let scale: CGFloat
    let attachment: (TranscriptBlock, TranscriptAttachmentRef) -> NSTextAttachment

    func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: (size * scale).rounded(), weight: weight)
    }

    var body: NSFont { font(ShellType.bodySize) }
    var label: NSFont { font(ShellType.labelSize) }
    var code: NSFont { .monospacedSystemFont(ofSize: (ShellType.labelSize * scale).rounded(), weight: .regular) }

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
            body = inline(runs, font: self.body, color: .labelColor)
        case .reply(let runs, let ink):
            body = ink == .quiet ? inline(runs, font: label, color: .secondaryLabelColor) : inline(runs, font: self.body, color: .labelColor)
        case .heading(let runs):
            body = inline(runs, font: font(ShellType.bodySize, .semibold), color: .labelColor)
        case .quote(let runs):
            body = inline(runs, font: self.body, color: .secondaryLabelColor)
        case .listItem(let marker, _, let runs):
            body = NSMutableAttributedString(string: "\t" + marker + "\t", attributes: [.font: self.body, .foregroundColor: NSColor.labelColor])
            body.append(inline(runs, font: self.body, color: .labelColor))
        case .code(_, let text):
            body = NSMutableAttributedString(string: Self.oneParagraph(text), attributes: [.font: code, .foregroundColor: NSColor.labelColor])
        case .foldHeadline(let text, let failed):
            // The headline is a link to its own run, so a keyboard, VoiceOver or accessibility press opens it as a click does.
            body = NSMutableAttributedString(string: Self.oneParagraph(text), attributes: [
                .font: font(ShellType.labelSize, .medium), .foregroundColor: failed ? TranscriptInk.trouble : NSColor.secondaryLabelColor,
                .link: TranscriptFoldLink.url(block.messageID),
            ])
        case .foldDetail(let text, let failed):
            body = NSMutableAttributedString(string: Self.oneParagraph(text), attributes: [
                .font: label, .foregroundColor: failed ? TranscriptInk.trouble : NSColor.secondaryLabelColor,
            ])
        case .gap(let date):
            body = NSMutableAttributedString(string: Self.gapLabel(date), attributes: [
                .font: font(ShellType.captionSize), .foregroundColor: NSColor.secondaryLabelColor,
            ])
        case .attachment(let ref):
            body = NSMutableAttributedString(attachment: attachment(block, ref))
            body.addAttribute(.font, value: self.body, range: NSRange(location: 0, length: body.length))
        }
        // An empty block still draws one line, as an empty bubble drew one blank line.
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

    private func baseFont(_ block: TranscriptBlock) -> NSFont {
        switch block.kind {
        case .code: code
        case .foldHeadline, .foldDetail: label
        case .gap: font(ShellType.captionSize)
        case .reply(_, let ink): ink == .quiet ? label : body
        default: body
        }
    }

    private func paragraphAttributes(_ block: TranscriptBlock) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            TranscriptKey.kind: TranscriptParagraph(block.kind).rawValue,
            TranscriptKey.blockID: block.id,
            TranscriptKey.messageID: block.messageID,
            TranscriptKey.role: block.role,
            TranscriptKey.topGap: NSNumber(value: Double(TranscriptMetrics.topGap(block.lead))),
            .paragraphStyle: style(block),
        ]
        if let group = block.foldGroup { attributes[TranscriptKey.foldGroup] = group }
        switch block.kind {
        case .foldHeadline:
            attributes[TranscriptKey.foldOpens] = block.messageID
        case .user(_, let tag?):
            attributes[TranscriptKey.tagSymbol] = tag.symbol
            attributes[TranscriptKey.tagLabel] = tag.label
            attributes[TranscriptKey.tagAutomated] = NSNumber(value: tag.automated)
        case .code(let language, _) where !language.isEmpty:
            attributes[TranscriptKey.language] = language
        default:
            break
        }
        return attributes
    }

    private func style(_ block: TranscriptBlock) -> NSParagraphStyle {
        let gutter = TranscriptMetrics.gutter
        switch block.kind {
        case .user(let runs, _):
            return userStyle(runs)
        case .reply(_, let ink):
            let spacing = ink == .quiet && block.role == "user" ? TranscriptMetrics.userLineSpacing : TranscriptMetrics.replyLineSpacing
            return Self.style(head: gutter, tail: -gutter, lineSpacing: spacing)
        case .heading:
            return Self.style(head: gutter, tail: -gutter, lineSpacing: TranscriptMetrics.replyLineSpacing)
        case .quote:
            return Self.style(head: gutter + TranscriptMetrics.quoteIndent, tail: -gutter, lineSpacing: TranscriptMetrics.replyLineSpacing)
        case .listItem(_, let depth, _):
            let first = gutter + CGFloat(max(0, depth)) * (TranscriptMetrics.listMarkerColumn + TranscriptMetrics.listMarkerGap)
            let marker = first + TranscriptMetrics.listMarkerColumn
            let text = marker + TranscriptMetrics.listMarkerGap
            return Self.style(head: text, first: first, tail: -gutter, lineSpacing: TranscriptMetrics.replyLineSpacing,
                              tabs: [NSTextTab(textAlignment: .right, location: marker), NSTextTab(textAlignment: .left, location: text)])
        case .code:
            let inset = gutter + TranscriptMetrics.codePadH
            return Self.style(head: inset, tail: -inset, lineSpacing: 2)
        case .foldHeadline, .foldDetail:
            return Self.style(head: gutter + TranscriptMetrics.foldIndent, tail: -gutter, lineSpacing: 2)
        case .gap:
            return Self.style(head: gutter, tail: -gutter, lineSpacing: 0, alignment: .center)
        case .attachment:
            return Self.style(head: gutter, tail: -gutter, lineSpacing: 0)
        }
    }

    /// Right-seated and hugging its text: the text box is measured, then indented from the leading edge so it ends at the column's trailing gutter.
    private func userStyle(_ runs: [TranscriptRun]) -> NSParagraphStyle {
        let measure = inline(runs, font: body, color: .labelColor)
        if measure.length == 0 { measure.append(NSAttributedString(string: " ", attributes: [.font: body])) }
        measure.addAttribute(.paragraphStyle, value: Self.style(head: 0, tail: 0, lineSpacing: TranscriptMetrics.userLineSpacing),
                             range: NSRange(location: 0, length: measure.length))
        let pad = TranscriptMetrics.bubblePadH
        let room = width - 2 * TranscriptMetrics.gutter - TranscriptMetrics.userSeatRoom - 2 * pad
        let widest = max(1, min(TranscriptMetrics.userTextMax, room))
        let bounds = measure.boundingRect(with: NSSize(width: widest, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Two points of slack so TextKit's line breaking never wraps a line the measurement kept whole.
        let textWidth = min(widest, ceil(bounds.width) + 2)
        let textRight = width - TranscriptMetrics.gutter - pad
        return Self.style(head: textRight - textWidth, tail: -(TranscriptMetrics.gutter + pad), lineSpacing: TranscriptMetrics.userLineSpacing)
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

    func inline(_ runs: [TranscriptRun], font base: NSFont, color: NSColor) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for run in runs where !run.text.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: styled(base, bold: run.bold, italic: run.italic, code: run.code), .foregroundColor: color,
            ]
            if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.controlAccentColor
            }
            out.append(NSAttributedString(string: Self.oneParagraph(run.text), attributes: attributes))
        }
        return out
    }

    private func styled(_ base: NSFont, bold: Bool, italic: Bool, code: Bool) -> NSFont {
        var font = base
        if code {
            font = .monospacedSystemFont(ofSize: (base.pointSize - 1.5).rounded(), weight: bold ? .semibold : .regular)
        } else if bold {
            font = .systemFont(ofSize: base.pointSize, weight: .semibold)
        }
        if italic, let slanted = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)),
                                        size: font.pointSize) {
            font = slanted
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

/// ⌘+ and ⌘− scale every transcript's text; the scale persists and every open transcript follows it.
@MainActor
enum TranscriptTextScale {
    static let defaultsKey = "transcriptTextScale"
    static let changed = Notification.Name("TranscriptTextScale.changed")
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
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// A fold headline's link: the tool run's group id under a scheme only this view opens.
enum TranscriptFoldLink {
    static let scheme = "nativeagent-fold"

    /// Hierarchical (`nativeagent-fold:///<group>`): an opaque URL has no path to read the group back from.
    static func url(_ group: String) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = ""
        parts.path = "/" + group
        return parts.url ?? URL(fileURLWithPath: "/")
    }

    static func group(_ link: Any) -> String? {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)), url.scheme == scheme else { return nil }
        let group = String(url.path.dropFirst())
        return group.isEmpty ? nil : group
    }
}

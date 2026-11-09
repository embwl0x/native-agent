import AppKit
import NativeAgentShared
import SwiftUI

// Blueprint: | `TranscriptStyle.swift` | AppKit tokens and the press's off-main paragraph renderer |

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

/// The app's tokens as the document lays them out (NativeAgentShellLayout, ShellType and NativeAgentSpacing).
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
    static var paragraphGap: CGFloat { StreamingParagraphText.paragraphGap }
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
struct TranscriptRenderer {
    /// The text container's width: the column, or less in a narrow window.
    let width: CGFloat
    let scale: CGFloat

    nonisolated static func prepare(_ block: TranscriptBlock, width: Double, scale: Double) throws -> TranscriptRenderedParagraph {
        try Self(width: CGFloat(width), scale: CGFloat(scale)).prepared(block)
    }

    func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: (size * scale).rounded(), weight: weight)
    }

    var body: NSFont { font(ShellType.bodySize) }
    var label: NSFont { font(ShellType.labelSize) }
    var code: NSFont { .monospacedSystemFont(ofSize: (ShellType.labelSize * scale).rounded(), weight: .regular) }

    func prepared(_ block: TranscriptBlock) throws -> TranscriptRenderedParagraph {
        let paragraph = try render(block)
        let hidden = NSMutableAttributedString(string: " ", attributes: paragraph.separator.attributes(at: 0, effectiveRange: nil))
        hidden.addAttribute(TranscriptKey.liveHidden, value: NSNumber(value: true), range: NSRange(location: 0, length: 1))
        return try TranscriptRenderedParagraph(block: block,
            body: AttributedString(paragraph.body, including: TranscriptAttributes.self),
            separator: AttributedString(paragraph.separator, including: TranscriptAttributes.self),
            hidden: AttributedString(hidden, including: TranscriptAttributes.self),
            mapping: TranscriptRevealMapping(block, rendered: paragraph.body.string))
    }

    /// The paragraph and the separator that ends it, sharing one set of paragraph attributes (a bubble is measured once).
    func render(_ block: TranscriptBlock) throws -> (body: NSMutableAttributedString, separator: NSAttributedString) {
        let attributes = try paragraphAttributes(block)
        let body: NSMutableAttributedString
        switch block.kind {
        case .user(let runs, _):
            body = try inline(runs, font: self.body, color: .labelColor)
        case .reply(let runs, let ink):
            if ink == .quiet { body = try inline(runs, font: label, color: .secondaryLabelColor) }
            else { body = try inline(runs, font: self.body, color: .labelColor) }
        case .heading(let runs):
            body = try inline(runs, font: font(ShellType.bodySize, .semibold), color: .labelColor)
        case .quote(let runs):
            body = try inline(runs, font: self.body, color: .secondaryLabelColor)
        case .listItem(let marker, _, let runs):
            body = NSMutableAttributedString(string: "\t" + marker + "\t", attributes: [.font: self.body, .foregroundColor: NSColor.labelColor])
            body.append(try inline(runs, font: self.body, color: .labelColor))
        case .code(_, let text):
            body = NSMutableAttributedString(string: TranscriptRevealMapping.oneParagraph(text),
                                             attributes: [.font: code, .foregroundColor: NSColor.labelColor])
        case .foldHeadline(let text, let failed):
            // The headline is a link to its own run, so a keyboard, VoiceOver or accessibility press opens it as a click does.
            body = NSMutableAttributedString(string: TranscriptRevealMapping.oneParagraph(text), attributes: [
                .font: font(ShellType.labelSize, .medium), .foregroundColor: failed ? TranscriptInk.trouble : NSColor.secondaryLabelColor,
                .link: TranscriptFoldLink.url(block.messageID),
            ])
        case .foldDetail(let text, let failed):
            body = NSMutableAttributedString(string: TranscriptRevealMapping.oneParagraph(text), attributes: [
                .font: label, .foregroundColor: failed ? TranscriptInk.trouble : NSColor.secondaryLabelColor,
            ])
        case .gap(let date):
            body = NSMutableAttributedString(string: Self.gapLabel(date), attributes: [
                .font: font(ShellType.captionSize), .foregroundColor: NSColor.secondaryLabelColor,
            ])
        case .attachment:
            body = NSMutableAttributedString(string: "\u{FFFC}", attributes: [.font: self.body])
        }
        // Empty blocks occupy one line.
        if body.length == 0 { body.append(NSAttributedString(string: " ", attributes: [.font: baseFont(block)])) }
        body.addAttributes(attributes, range: NSRange(location: 0, length: body.length))
        return (body, separator(block, attributes))
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

    private func paragraphAttributes(_ block: TranscriptBlock) throws -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            TranscriptKey.kind: TranscriptParagraph(block.kind).rawValue,
            TranscriptKey.blockID: block.id,
            TranscriptKey.topGap: NSNumber(value: Double(TranscriptMetrics.topGap(block.lead))),
            .paragraphStyle: try style(block),
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

    private func style(_ block: TranscriptBlock) throws -> NSParagraphStyle {
        let gutter = TranscriptMetrics.gutter
        switch block.kind {
        case .user(let runs, _):
            return try userStyle(runs)
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
    private func userStyle(_ runs: [TranscriptRun]) throws -> NSParagraphStyle {
        let measure = try inline(runs, font: body, color: .labelColor)
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

    func inline(_ runs: [TranscriptRun], font base: NSFont, color: NSColor) throws -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for run in runs where !run.text.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: try styled(base, bold: run.bold, italic: run.italic, code: run.code), .foregroundColor: color,
            ]
            if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.controlAccentColor
            }
            out.append(NSAttributedString(string: TranscriptRevealMapping.oneParagraph(run.text), attributes: attributes))
        }
        return out
    }

    private func styled(_ base: NSFont, bold: Bool, italic: Bool, code: Bool) throws -> NSFont {
        var font = base
        if code {
            font = .monospacedSystemFont(ofSize: (base.pointSize - 1.5).rounded(), weight: bold ? .semibold : .regular)
        } else if bold {
            font = .systemFont(ofSize: base.pointSize, weight: .semibold)
        }
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            guard let italicFont = NSFont(descriptor: descriptor, size: font.pointSize) else {
                throw CocoaError(.formatting, userInfo: [NSLocalizedDescriptionKey: "The transcript italic font could not be created."])
            }
            font = italicFont
        }
        return font
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
    static func url(_ group: String) -> String {
        scheme + ":///" + group.utf8.map { String(format: "%%%02X", $0) }.joined()
    }

    static func group(_ link: Any) -> String? {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)), url.scheme == scheme else { return nil }
        let group = String(url.path.dropFirst())
        return group.isEmpty ? nil : group
    }
}

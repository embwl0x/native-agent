import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// Blueprint: | `TranscriptRenderer.swift` | `TranscriptRenderer`, `TranscriptLook`, `TranscriptFoldLink`: one block as one styled paragraph on the press, shared header and provenance heights, and each platform's look |

/// How one platform's transcript reads: its values, its fonts and colours, and the few rules where the Mac and the phone differ.
/// Each platform builds it inside the press's render call from that call's width, scale or text-size category.
public struct TranscriptLook {
    public static let provenanceHeight: CGFloat = 16
    public static let codeHeaderHeight: CGFloat = 22

    /// Room between the text container's edges and the column: the Mac's container includes its gutters, the phone's is the column.
    public var gutter: CGFloat
    /// A user bubble never comes closer than this to the column's leading edge.
    public var userSeatRoom: CGFloat
    public var userTextMax: CGFloat
    public var bubblePadH: CGFloat
    public var replyLineSpacing: CGFloat
    public var userLineSpacing: CGFloat
    /// A quiet reply's line spacing by its row's role.
    public var quietLineSpacing: (_ role: String) -> CGFloat
    public var listMarkerColumn: CGFloat
    public var listMarkerGap: CGFloat
    /// A list item's first-line indent past the gutter at its depth.
    public var listIndent: (_ depth: Int) -> CGFloat
    public var quoteIndent: CGFloat
    /// A fold's text sits past its chevron.
    public var foldIndent: CGFloat
    /// Code text's inset from each side of its fill.
    public var codePad: CGFloat
    /// The space between one message and the next.
    public var messageGap: CGFloat

    public var body: TranscriptFont
    /// Quiet replies, fold details and the separator under every fold line.
    public var quiet: TranscriptFont
    public var heading: TranscriptFont
    public var code: TranscriptFont
    /// The time line after an hour of quiet.
    public var caption: TranscriptFont
    public var foldHeadline: TranscriptFont
    /// The code block's language label, carried as `languageFontSize` for a fragment that draws it at the reader's size; nil writes none.
    public var codeLabel: TranscriptFont?

    public var label: TranscriptColor
    public var secondary: TranscriptColor
    public var listMarker: TranscriptColor
    /// Read where a failure is drawn, so the colour is resolved only for a failed line.
    public var trouble: () -> TranscriptColor

    /// Styles a run that carries a link; the link itself is already set.
    public var styleLink: (_ link: URL, _ base: TranscriptFont, _ attributes: inout [NSAttributedString.Key: Any]) throws -> Void
    /// The link a fold headline carries to its tool run. A throw draws the headline with the failure in place of the link.
    public var foldLink: (_ group: String) throws -> Any

    public init(gutter: CGFloat, userSeatRoom: CGFloat, userTextMax: CGFloat, bubblePadH: CGFloat, replyLineSpacing: CGFloat,
                userLineSpacing: CGFloat, quietLineSpacing: @escaping (_ role: String) -> CGFloat, listMarkerColumn: CGFloat,
                listMarkerGap: CGFloat, listIndent: @escaping (_ depth: Int) -> CGFloat, quoteIndent: CGFloat, foldIndent: CGFloat,
                codePad: CGFloat, messageGap: CGFloat, body: TranscriptFont, quiet: TranscriptFont, heading: TranscriptFont,
                code: TranscriptFont, caption: TranscriptFont, foldHeadline: TranscriptFont, codeLabel: TranscriptFont?,
                label: TranscriptColor, secondary: TranscriptColor, listMarker: TranscriptColor, trouble: @escaping () -> TranscriptColor,
                styleLink: @escaping (_ link: URL, _ base: TranscriptFont, _ attributes: inout [NSAttributedString.Key: Any]) throws -> Void,
                foldLink: @escaping (_ group: String) throws -> Any) {
        self.gutter = gutter
        self.userSeatRoom = userSeatRoom
        self.userTextMax = userTextMax
        self.bubblePadH = bubblePadH
        self.replyLineSpacing = replyLineSpacing
        self.userLineSpacing = userLineSpacing
        self.quietLineSpacing = quietLineSpacing
        self.listMarkerColumn = listMarkerColumn
        self.listMarkerGap = listMarkerGap
        self.listIndent = listIndent
        self.quoteIndent = quoteIndent
        self.foldIndent = foldIndent
        self.codePad = codePad
        self.messageGap = messageGap
        self.body = body
        self.quiet = quiet
        self.heading = heading
        self.code = code
        self.caption = caption
        self.foldHeadline = foldHeadline
        self.codeLabel = codeLabel
        self.label = label
        self.secondary = secondary
        self.listMarker = listMarker
        self.trouble = trouble
        self.styleLink = styleLink
        self.foldLink = foldLink
    }
}

/// Renders one block as one paragraph. Every paragraph is one NSTextParagraph: newlines inside a block become line separators.
/// Rendering runs on the press actor.
public struct TranscriptRenderer {
    /// The text container's width: the column, or less in a narrow window or on a narrow screen.
    public let width: CGFloat
    public let look: TranscriptLook

    public init(width: CGFloat, look: TranscriptLook) {
        self.width = width
        self.look = look
    }

    public func prepared(_ block: TranscriptBlock) throws -> TranscriptRenderedParagraph {
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
    public func render(_ block: TranscriptBlock) throws -> (body: NSMutableAttributedString, separator: NSAttributedString) {
        let attributes = try paragraphAttributes(block)
        let body: NSMutableAttributedString
        switch block.kind {
        case .user(let runs, _):
            body = try inline(runs, font: look.body, color: look.label)
        case .reply(let runs, let ink):
            body = try (ink == .quiet ? inline(runs, font: look.quiet, color: look.secondary) : inline(runs, font: look.body, color: look.label))
        case .heading(let runs):
            body = try inline(runs, font: look.heading, color: look.label)
        case .quote(let runs):
            body = try inline(runs, font: look.body, color: look.secondary)
        case .listItem(let marker, _, let runs):
            body = NSMutableAttributedString(string: "\t" + marker + "\t", attributes: [.font: look.body, .foregroundColor: look.listMarker])
            body.append(try inline(runs, font: look.body, color: look.label))
        case .code(_, let text):
            body = NSMutableAttributedString(string: TranscriptRevealMapping.oneParagraph(text),
                                             attributes: [.font: look.code, .foregroundColor: look.label])
        case .foldHeadline(let text, let failed):
            // The headline is a link to its own run, so a keyboard, VoiceOver or accessibility press opens it as a click does.
            body = NSMutableAttributedString(string: TranscriptRevealMapping.oneParagraph(text), attributes: [
                .font: look.foldHeadline, .foregroundColor: failed ? look.trouble() : look.secondary,
            ])
            do {
                body.addAttribute(.link, value: try look.foldLink(block.messageID), range: NSRange(location: 0, length: body.length))
            } catch {
                body.append(NSAttributedString(string: " · Action unavailable: \(error.localizedDescription)",
                                               attributes: [.font: look.quiet, .foregroundColor: look.trouble()]))
            }
        case .foldDetail(let text, let failed):
            body = NSMutableAttributedString(string: TranscriptRevealMapping.oneParagraph(text), attributes: [
                .font: look.quiet, .foregroundColor: failed ? look.trouble() : look.secondary,
            ])
        case .gap(let date):
            body = NSMutableAttributedString(string: Self.gapLabel(date), attributes: [
                .font: look.caption, .foregroundColor: look.secondary,
            ])
        case .attachment:
            body = NSMutableAttributedString(string: "\u{FFFC}", attributes: [.font: look.body])
        }
        // An empty block still draws one line.
        if body.length == 0 { body.append(NSAttributedString(string: " ", attributes: [.font: baseFont(block)])) }
        body.addAttributes(attributes, range: NSRange(location: 0, length: body.length))
        return (body, separator(block, attributes))
    }

    private func separator(_ block: TranscriptBlock, _ paragraph: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = paragraph
        attributes[.font] = baseFont(block)
        return NSAttributedString(string: "\n", attributes: attributes)
    }

    private func baseFont(_ block: TranscriptBlock) -> TranscriptFont {
        switch block.kind {
        case .code: look.code
        case .foldHeadline, .foldDetail: look.quiet
        case .gap: look.caption
        case .reply(_, let ink): ink == .quiet ? look.quiet : look.body
        default: look.body
        }
    }

    private func paragraphAttributes(_ block: TranscriptBlock) throws -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            TranscriptKey.kind: TranscriptParagraph(block.kind).rawValue,
            TranscriptKey.blockID: block.id,
            TranscriptKey.topGap: NSNumber(value: Double(block.lead.topGap(message: look.messageGap))),
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
            if let codeLabel = look.codeLabel {
                attributes[TranscriptKey.languageFontSize] = NSNumber(value: Double(codeLabel.pointSize))
            }
        default:
            break
        }
        return attributes
    }

    private func style(_ block: TranscriptBlock) throws -> NSParagraphStyle {
        // `0 - gutter`, so a container without gutters ends lines at +0, as a literal 0 does.
        let gutter = look.gutter, tail = 0 - look.gutter
        switch block.kind {
        case .user(let runs, _):
            return try userStyle(runs)
        case .reply(_, let ink):
            return Self.style(head: gutter, tail: tail,
                              lineSpacing: ink == .quiet ? look.quietLineSpacing(block.role) : look.replyLineSpacing)
        case .heading:
            return Self.style(head: gutter, tail: tail, lineSpacing: look.replyLineSpacing)
        case .quote:
            return Self.style(head: gutter + look.quoteIndent, tail: tail, lineSpacing: look.replyLineSpacing)
        case .listItem(_, let depth, _):
            let first = gutter + look.listIndent(depth)
            let marker = first + look.listMarkerColumn
            let text = marker + look.listMarkerGap
            return Self.style(head: text, first: first, tail: tail, lineSpacing: look.replyLineSpacing,
                              tabs: [NSTextTab(textAlignment: .right, location: marker, options: [:]),
                                     NSTextTab(textAlignment: .left, location: text, options: [:])])
        case .code:
            let inset = gutter + look.codePad
            return Self.style(head: inset, tail: -inset, lineSpacing: 2)
        case .foldHeadline, .foldDetail:
            return Self.style(head: gutter + look.foldIndent, tail: tail, lineSpacing: 2)
        case .gap:
            return Self.style(head: gutter, tail: tail, lineSpacing: 0, alignment: .center)
        case .attachment:
            return Self.style(head: gutter, tail: tail, lineSpacing: 0)
        }
    }

    /// Right-seated and hugging its text: the text box is measured, then indented from the leading edge so it ends inside the column's
    /// trailing edge by the bubble's padding.
    private func userStyle(_ runs: [TranscriptRun]) throws -> NSParagraphStyle {
        let measure = try inline(runs, font: look.body, color: look.label)
        if measure.length == 0 { measure.append(NSAttributedString(string: " ", attributes: [.font: look.body])) }
        measure.addAttribute(.paragraphStyle, value: Self.style(head: 0, tail: 0, lineSpacing: look.userLineSpacing),
                             range: NSRange(location: 0, length: measure.length))
        let pad = look.bubblePadH
        let room = width - 2 * look.gutter - look.userSeatRoom - 2 * pad
        let widest = max(1, min(look.userTextMax, room))
#if canImport(AppKit)
        let bounds = measure.boundingRect(with: NSSize(width: widest, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
#else
        let bounds = measure.boundingRect(with: CGSize(width: widest, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
#endif
        // Two points of slack so TextKit's line breaking never wraps a line the measurement kept whole.
        let textWidth = min(widest, ceil(bounds.width) + 2)
        let textRight = width - look.gutter - pad
        return Self.style(head: textRight - textWidth, tail: -(look.gutter + pad), lineSpacing: look.userLineSpacing)
    }

    public static func style(head: CGFloat, first: CGFloat? = nil, tail: CGFloat, lineSpacing: CGFloat, alignment: NSTextAlignment = .natural,
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

    public func inline(_ runs: [TranscriptRun], font base: TranscriptFont, color: TranscriptColor) throws -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for run in runs where !run.text.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: try Self.styled(base, bold: run.bold, italic: run.italic, code: run.code), .foregroundColor: color,
            ]
            if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                try look.styleLink(link, base, &attributes)
            }
            out.append(NSAttributedString(string: TranscriptRevealMapping.oneParagraph(run.text), attributes: attributes))
        }
        return out
    }

    public static func styled(_ base: TranscriptFont, bold: Bool, italic: Bool, code: Bool) throws -> TranscriptFont {
        var font = base
        if code {
            font = .monospacedSystemFont(ofSize: (base.pointSize - 1.5).rounded(), weight: bold ? .semibold : .regular)
        } else if bold {
            font = .systemFont(ofSize: base.pointSize, weight: .semibold)
        }
        if italic {
#if canImport(AppKit)
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            guard let italicFont = NSFont(descriptor: descriptor, size: font.pointSize) else {
                throw CocoaError(.formatting, userInfo: [NSLocalizedDescriptionKey: "The transcript italic font could not be created."])
            }
            font = italicFont
#else
            guard let slanted = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) else {
                throw CocoaError(.formatting, userInfo: [NSLocalizedDescriptionKey: "The transcript italic font could not be created."])
            }
            font = UIFont(descriptor: slanted, size: font.pointSize)
#endif
        }
        return font
    }

    /// "Today 3:04 PM" after an hour of quiet.
    public static func gapLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The Mac's fold headline link: the tool run's group id under a scheme only its transcript view opens. The App process writes it
/// when it renders a headline; the Face process reads the group back when the link is pressed.
public enum TranscriptFoldLink {
    public static let scheme = "nativeagent-fold"

    /// Hierarchical (`nativeagent-fold:///<group>`): an opaque URL has no path to read the group back from.
    public static func url(_ group: String) -> String {
        scheme + ":///" + group.utf8.map { String(format: "%%%02X", $0) }.joined()
    }

    public static func group(_ link: Any) -> String? {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)), url.scheme == scheme else { return nil }
        let group = String(url.path.dropFirst())
        return group.isEmpty ? nil : group
    }
}

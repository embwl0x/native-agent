import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
public typealias TranscriptColor = NSColor
public typealias TranscriptFont = NSFont
#else
import UIKit
public typealias TranscriptColor = UIColor
public typealias TranscriptFont = UIFont
#endif

// Blueprint: | `TranscriptLayout.swift` | `TranscriptParagraph`, `TranscriptFragment`, `TranscriptFoldFragment`, `TranscriptLayoutDelegate`, `TranscriptAttachment`, `TranscriptShapes`: paragraph kinds and gaps, fragment geometry, the fold chevron, fold hiding, attachment room and decoration shapes for Mac and phone |

public enum TranscriptParagraph: String {
    case user, reply, heading, quote, listItem, code, foldHeadline, foldDetail, gap, attachment

    public init(_ kind: TranscriptBlock.Kind) {
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

    public static func of(_ paragraph: NSTextParagraph) -> TranscriptParagraph? {
        let text = paragraph.attributedString
        guard text.length > 0, let raw = text.attribute(TranscriptKey.kind, at: 0, effectiveRange: nil) as? String else { return nil }
        return TranscriptParagraph(rawValue: raw)
    }
}

/// Every paragraph's look comes from its fragment. Margins are read once from the paragraph's attributes; decoration is placed from the
/// laid-out lines, never from column constants, because TextKit shifts each fragment by its paragraph indent. Paths are cached per rect
/// because `draw(at:in:)` runs many times per scroll step.
open class TranscriptFragment: NSTextLayoutFragment {
    public final lazy var paragraphAttributes: [NSAttributedString.Key: Any] = {
        guard let paragraph = self.textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return [:] }
        return paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
    }()
    public final lazy var topGap: CGFloat = (self.paragraphAttributes[TranscriptKey.topGap] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    public final var cachedPath: CGPath?
    public final var cachedRect = CGRect.null

    open override var topMargin: CGFloat { topGap }

    /// Where the text actually sits, in this fragment's own drawing space (y down), from the laid-out lines. Null before layout.
    public final var inkRect: CGRect {
        var rect = CGRect.null
        for line in textLineFragments {
            let text = line.attributedString.string as NSString
            let range = line.characterRange
            var end = range.upperBound
            while end > range.lowerBound, let scalar = UnicodeScalar(text.character(at: end - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "\u{2028}" { end -= 1 }
            guard end > range.lowerBound else { continue }
            let origin = line.typographicBounds.origin
            let start = origin.x + line.locationForCharacter(at: range.lowerBound).x
            let finish = origin.x + line.locationForCharacter(at: end).x
            rect = rect.union(CGRect(x: start, y: line.typographicBounds.minY, width: max(0, finish - start),
                                     height: line.typographicBounds.height))
        }
        return rect
    }

    /// The x where the first line's text starts, in fragment space.
    public final var textStartX: CGFloat? {
        guard let line = textLineFragments.first else { return nil }
        return line.typographicBounds.minX + line.locationForCharacter(at: line.characterRange.lowerBound).x
    }

    /// The text container's width, which the column decorations span.
    public final var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }
}

extension TranscriptBlock.Lead {
    /// The space above a block led this way. `message` is the platform's gap between messages: the Mac's
    /// `NativeAgentShellLayout.transcriptGap` (16), the phone's 26.
    public func topGap(message: CGFloat) -> CGFloat {
        switch self {
        case .none: 0
        case .message: message
        case .paragraph: StreamingParagraphText.paragraphGap
        case .listItem: NativeAgentSpacing.xs
        case .detail: NativeAgentSpacing.xs
        case .gap: message + NativeAgentSpacing.sm
        }
    }
}

extension TranscriptFragment {
    /// Fills `rect` with the path `shape` makes, cached per rect; `stroke` also outlines it (the phone's code inset).
    public final func fillBackground(_ rect: CGRect, color: TranscriptColor, stroke: TranscriptColor? = nil, at point: CGPoint,
                                     in context: CGContext, shape: (CGRect) -> CGPath) {
        guard rect.width > 0, rect.height > 0 else { return }
        if cachedPath == nil || cachedRect != rect {
            cachedPath = shape(rect)
            cachedRect = rect
        }
        guard let path = cachedPath else { return }
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
        if let stroke {
            context.addPath(path)
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(0.8)
            context.strokePath()
        }
        context.restoreGState()
    }
}

/// One quiet line for a tool run with a drawn disclosure chevron. Open state is fixed per fragment: a toggle edits the run's range,
/// which makes TextKit build fresh fragments.
public final class TranscriptFoldFragment: TranscriptFragment {
    public var isOpen = false

    /// Just before the label's first glyph, centred on its first line.
    private var chevronRect: CGRect {
        guard let line = textLineFragments.first, let start = textStartX else { return .zero }
        return CGRect(x: start - 14, y: line.typographicBounds.midY - 4, width: 8, height: 8)
    }

    private var chevron: CGPath {
        let rect = chevronRect
        let path = CGMutablePath()
        if isOpen {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + 2))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 1))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 2))
        } else {
            path.move(to: CGPoint(x: rect.minX + 2, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY))
        }
        return path
    }

    public override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(chevronRect.insetBy(dx: -2, dy: -2)) }

    public override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.addPath(chevron)
#if canImport(AppKit)
        context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
#else
        context.setStrokeColor(UIColor.secondaryLabel.cgColor)
#endif
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// What TextKit asks the document: which fragment draws a paragraph, and whether a folded paragraph is enumerated at all.
/// A closed fold's paragraphs stay in storage and are skipped, never deleted. The bubble and code fragments are each platform's own.
public final class TranscriptLayoutDelegate: NSObject, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate {
    public typealias Make = (NSTextElement, NSTextRange?) -> NSTextLayoutFragment

    /// Tool-run group ids the reader opened. Folds start closed.
    public var openFolds: Set<String> = []
    private let user: Make
    private let code: Make

    public init(user: @escaping Make, code: @escaping Make) {
        self.user = user
        self.code = code
        super.init()
    }

    public func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                                   options: NSTextContentManager.EnumerationOptions) -> Bool {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return true }
        if paragraph.attributedString.attribute(TranscriptKey.liveHidden, at: 0, effectiveRange: nil) as? Bool == true { return false }
        guard let group = paragraph.attributedString.attribute(TranscriptKey.foldGroup, at: 0, effectiveRange: nil) as? String else { return true }
        return openFolds.contains(group)
    }

    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                  in textElement: NSTextElement) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        guard let paragraph = textElement as? NSTextParagraph, let kind = TranscriptParagraph.of(paragraph) else {
            return TranscriptFragment(textElement: textElement, range: range)
        }
        switch kind {
        case .user:
            return user(textElement, range)
        case .code:
            return code(textElement, range)
        case .foldHeadline:
            let fragment = TranscriptFoldFragment(textElement: textElement, range: range)
            if let group = paragraph.attributedString.attribute(TranscriptKey.foldOpens, at: 0, effectiveRange: nil) as? String {
                fragment.isOpen = openFolds.contains(group)
            }
            return fragment
        case .reply, .heading, .quote, .listItem, .foldDetail, .gap, .attachment:
            return TranscriptFragment(textElement: textElement, range: range)
        }
    }
}

/// A block's room in the text: TextKit lays out its measured bounds and draws nothing there; the reader places the block's hosted
/// view over that frame. TextKit's own attachment views are not used: it creates their providers only for paragraphs a scroll lays out.
public final class TranscriptAttachment: NSTextAttachment {
    public let blockID: String

    public init(blockID: String) {
        self.blockID = blockID
#if canImport(AppKit)
        super.init(data: Data(blockID.utf8), ofType: "com.nativeagent.transcript.attachment")
#else
        super.init(data: nil, ofType: nil)
#endif
        allowsTextAttachmentView = false
    }

    public required init?(coder: NSCoder) { nil }

#if canImport(AppKit)
    /// The hosted view is the only drawing; there is no image under it.
    public override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSImage? { nil }
#else
    /// The hosted view is the only drawing; under it TextKit draws an empty image.
    public override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> UIImage? { UIImage() }
#endif

    /// The hosted view's measured size (kept in `bounds` by the owner), never wider than the line; zero until measured.
    public override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                          textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        CGRect(x: 0, y: 0, width: min(bounds.width, proposedLineFragment.width), height: bounds.height)
    }
}

public enum TranscriptShapes {
    /// Corners in a y-down fragment space: top is minY.
    public static func rounded(_ rect: CGRect, topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let tl = min(topLeft, limit), tr = min(topRight, limit), br = min(bottomRight, limit), bl = min(bottomLeft, limit)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        path.closeSubpath()
        return path
    }

    public static func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
        rounded(rect, topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
    }
}

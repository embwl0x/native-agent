import CoreText
import NativeAgentShared
import UIKit

// Blueprint: | `MobileTranscriptFragments.swift` | One layout fragment per drawn paragraph kind, and the delegate that picks them and hides closed folds |

/// Read paragraph geometry once, cache decoration paths and resolve dynamic colors at draw time.
class TranscriptFragment: NSTextLayoutFragment {
    final lazy var paragraphAttributes: [NSAttributedString.Key: Any] = {
        guard let paragraph = self.textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return [:] }
        return paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
    }()
    final lazy var topGap: CGFloat = (self.paragraphAttributes[TranscriptKey.topGap] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    private var cachedPath: CGPath?
    private var cachedRect = CGRect.null

    override var topMargin: CGFloat { topGap }

    /// Where the text actually sits, in this fragment's own drawing space (y down), from the laid-out lines. Null before layout.
    final var inkRect: CGRect {
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
    final var textStartX: CGFloat? {
        guard let line = textLineFragments.first else { return nil }
        return line.typographicBounds.minX + line.locationForCharacter(at: line.characterRange.lowerBound).x
    }

    /// The text container's width, which the column decorations span.
    final var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    final func fillBackground(_ rect: CGRect, color: UIColor, stroke: UIColor? = nil, at point: CGPoint, in context: CGContext,
                              shape: (CGRect) -> CGPath) {
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

/// Right-seated bubble on the house's soft surface; the text sits inside by paragraph indents set at render.
final class TranscriptUserFragment: TranscriptFragment {
    override var topMargin: CGFloat { topGap + TranscriptMetrics.bubblePadV }
    override var bottomMargin: CGFloat { TranscriptMetrics.bubblePadV }

    /// The text's own extent, padded: the bubble always wraps exactly what is drawn.
    private var bubbleRect: CGRect {
        let ink = inkRect
        guard !ink.isNull else { return .zero }
        return ink.insetBy(dx: -TranscriptMetrics.bubblePadH, dy: -TranscriptMetrics.bubblePadV)
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(bubbleRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        let corners = TranscriptMetrics.userCorners
        fillBackground(bubbleRect, color: TranscriptInk.userBubble, at: point, in: context) {
            TranscriptShapes.rounded($0, topLeft: corners.topLeading, topRight: corners.topTrailing,
                                     bottomRight: corners.bottomTrailing, bottomLeft: corners.bottomLeading)
        }
        super.draw(at: point, in: context)
    }
}

/// Fenced code: one paragraph (lines joined by U+2028) on the quiet inset across the column, its language in a header strip.
final class TranscriptCodeFragment: TranscriptFragment {
    private lazy var language: (text: String, font: UIFont)? = {
        guard let text = paragraphAttributes[TranscriptKey.language] as? String,
              let size = paragraphAttributes[TranscriptKey.languageFontSize] as? NSNumber else { return nil }
        return (text, .systemFont(ofSize: CGFloat(size.doubleValue), weight: .medium))
    }()

    private var header: CGFloat { language == nil ? 0 : TranscriptMetrics.codeHeader }

    override var topMargin: CGFloat { topGap + header + TranscriptMetrics.codePad }
    override var bottomMargin: CGFloat { TranscriptMetrics.codePad }

    /// From the text's own start back by the inset padding, to the column's trailing edge.
    var insetRect: CGRect {
        guard let start = textStartX else { return .zero }
        let left = start - TranscriptMetrics.codePad
        let right = containerWidth - layoutFragmentFrame.minX
        return CGRect(x: left, y: topGap, width: max(0, right - left), height: max(0, layoutFragmentFrame.height - topGap))
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(insetRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        let inset = insetRect
        fillBackground(inset, color: TranscriptInk.codeFill, stroke: TranscriptInk.hairline, at: point, in: context) {
            TranscriptShapes.rounded($0, radius: TranscriptMetrics.codeRadius)
        }
        if inset != .zero, let language {
            // Core Text in the fragment's y-down space: flip the text matrix so the glyphs stand upright.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: language.font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor.secondaryLabel.cgColor,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: language.text, attributes: attributes) as CFAttributedString)
            let baseline = inset.minY + (TranscriptMetrics.codeHeader + language.font.ascender + language.font.descender) / 2
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: inset.minX + TranscriptMetrics.codePad, y: baseline)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}

/// One quiet line for a tool run with a drawn disclosure chevron. Open state is fixed per fragment: a toggle edits the run's range,
/// which makes TextKit build fresh fragments.
final class TranscriptFoldFragment: TranscriptFragment {
    var isOpen = false

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

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(chevronRect.insetBy(dx: -2, dy: -2)) }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.addPath(chevron)
        context.setStrokeColor(UIColor.secondaryLabel.cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

enum TranscriptShapes {
    /// Corners in a y-down fragment space: top is minY.
    static func rounded(_ rect: CGRect, topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat) -> CGPath {
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

    static func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
        rounded(rect, topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
    }
}

/// What TextKit asks the document: which fragment draws a paragraph, and whether a folded paragraph is enumerated at all.
/// A closed fold's paragraphs stay in storage and are skipped, never deleted.
final class TranscriptLayoutDelegate: NSObject, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate {
    /// Tool-run group ids the reader opened. Folds start closed.
    var openFolds: Set<String> = []

    func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                            options: NSTextContentManager.EnumerationOptions) -> Bool {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return true }
        if paragraph.attributedString.attribute(TranscriptKey.liveHidden, at: 0, effectiveRange: nil) as? Bool == true { return false }
        guard let group = paragraph.attributedString.attribute(TranscriptKey.foldGroup, at: 0, effectiveRange: nil) as? String else { return true }
        return openFolds.contains(group)
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        guard let paragraph = textElement as? NSTextParagraph, let kind = TranscriptParagraph.of(paragraph) else {
            return TranscriptFragment(textElement: textElement, range: range)
        }
        switch kind {
        case .user:
            return TranscriptUserFragment(textElement: textElement, range: range)
        case .code:
            return TranscriptCodeFragment(textElement: textElement, range: range)
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

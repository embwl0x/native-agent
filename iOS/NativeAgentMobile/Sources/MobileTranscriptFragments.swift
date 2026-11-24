import CoreText
import NativeAgentShared
import UIKit

// Blueprint: | `MobileTranscriptFragments.swift` | The phone's user bubble (with its provenance line, as on the Mac) and code fragments; the shared delegate picks them |

/// Right-seated bubble on the house's soft surface; the text sits inside by paragraph indents set at render.
/// A provenance or bridge line, when the message has one, sits above the bubble at its trailing edge, as on the Mac.
final class TranscriptUserFragment: TranscriptFragment {
    private lazy var tag: (text: NSAttributedString, symbol: UIImage?)? = {
        guard let label = paragraphAttributes[TranscriptKey.tagLabel] as? String else { return nil }
        let automated = (paragraphAttributes[TranscriptKey.tagAutomated] as? NSNumber)?.boolValue == true
        let color = automated ? TranscriptInk.trouble : UIColor.secondaryLabel
        let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .medium)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
        let symbol = (paragraphAttributes[TranscriptKey.tagSymbol] as? String).flatMap {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium))?
                .withTintColor(color, renderingMode: .alwaysOriginal)
        }
        return (text, symbol)
    }()

    private var tagSpace: CGFloat {
        guard let tag else { return 0 }
        return max(TranscriptMetrics.tagSpace, ceil(max(tag.text.size().height, tag.symbol?.size.height ?? 0)) + 4)
    }

    override var topMargin: CGFloat { topGap + tagSpace + TranscriptMetrics.bubblePadV }
    override var bottomMargin: CGFloat { TranscriptMetrics.bubblePadV }

    /// The text's own extent, padded: the bubble always wraps exactly what is drawn.
    private var bubbleRect: CGRect {
        let ink = inkRect
        guard !ink.isNull else { return .zero }
        return ink.insetBy(dx: -TranscriptMetrics.bubblePadH, dy: -TranscriptMetrics.bubblePadV)
    }

    private var tagRect: CGRect {
        guard let tag, bubbleRect != .zero else { return .zero }
        let size = tag.text.size()
        let symbolWidth = tag.symbol.map { $0.size.width + 4 } ?? 0
        let leadingEdge = -layoutFragmentFrame.minX
        let maxWidth = max(0, bubbleRect.maxX - leadingEdge)
        let width = min(maxWidth, ceil(size.width + symbolWidth))
        let height = ceil(max(size.height, tag.symbol?.size.height ?? 0))
        return CGRect(x: bubbleRect.maxX - width, y: bubbleRect.minY - tagSpace, width: width, height: height)
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(bubbleRect).union(tagRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        let corners = TranscriptMetrics.userCorners
        fillBackground(bubbleRect, color: TranscriptInk.userBubble, at: point, in: context) {
            TranscriptShapes.rounded($0, topLeft: corners.topLeading, topRight: corners.topTrailing,
                                     bottomRight: corners.bottomTrailing, bottomLeft: corners.bottomLeading)
        }
        if let tag {
            // UIKit draws in the fragment's y-down space.
            let rect = tagRect
            let textSize = tag.text.size()
            UIGraphicsPushContext(context)
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            var x = rect.minX
            if let symbol = tag.symbol {
                let side = symbol.size
                symbol.draw(in: CGRect(x: x, y: rect.midY - side.height / 2, width: side.width, height: side.height))
                x += side.width + 4
            }
            let textWidth = max(0, rect.maxX - x)
            if textWidth > 0 {
                tag.text.draw(
                    with: CGRect(x: x, y: rect.midY - textSize.height / 2, width: textWidth, height: ceil(textSize.height)),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    context: nil
                )
            }
            context.restoreGState()
            UIGraphicsPopContext()
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

    private var header: CGFloat {
        guard let language else { return 0 }
        return max(TranscriptMetrics.codeHeader, ceil(language.font.lineHeight) + 8)
    }

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
        let labelWidth = Double(inset.width - 2 * TranscriptMetrics.codePad)
        if labelWidth > 0, let language {
            // Core Text in the fragment's y-down space: flip the text matrix so the glyphs stand upright.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: language.font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor.secondaryLabel.cgColor,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: language.text, attributes: attributes) as CFAttributedString)
            let visibleLine: CTLine?
            if CTLineGetTypographicBounds(line, nil, nil, nil) > labelWidth {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes) as CFAttributedString)
                visibleLine = CTLineCreateTruncatedLine(line, labelWidth, .middle, ellipsis)
            } else {
                visibleLine = line
            }
            if let visibleLine {
                let baseline = inset.minY + (header + language.font.ascender + language.font.descender) / 2
                context.saveGState()
                context.translateBy(x: point.x, y: point.y)
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = CGPoint(x: inset.minX + TranscriptMetrics.codePad, y: baseline)
                CTLineDraw(visibleLine, context)
                context.restoreGState()
            }
        }
        super.draw(at: point, in: context)
    }
}

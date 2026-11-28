import AppKit
import NativeAgentShared
import SwiftUI

// Blueprint: | `TranscriptFragments.swift` | The Mac's user bubble (with its provenance line) and code fragments; the shared delegate picks them |

extension TranscriptFragment {
    /// AppKit string and image drawing into the fragment's flipped space.
    final func drawAppKit(at point: CGPoint, in context: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        body()
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Right-seated bubble on the house's soft surface, corners 14/14/4/14; the text sits inside by paragraph indents set at render.
/// A provenance or bridge line, when the message has one, sits above the bubble at its trailing edge.
final class TranscriptUserFragment: TranscriptFragment {
    private lazy var tag: (text: NSAttributedString, symbol: NSImage?)? = {
        guard let label = paragraphAttributes[TranscriptKey.tagLabel] as? String else { return nil }
        let automated = (paragraphAttributes[TranscriptKey.tagAutomated] as? NSNumber)?.boolValue == true
        let color = automated ? TranscriptInk.trouble : NSColor.secondaryLabelColor
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .medium)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
        let symbol = (paragraphAttributes[TranscriptKey.tagSymbol] as? String)
            .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
        return (text, symbol)
    }()

    override var topMargin: CGFloat { topGap + (tag == nil ? 0 : TranscriptLook.provenanceHeight) + TranscriptMetrics.bubblePadV }
    override var bottomMargin: CGFloat { TranscriptMetrics.bubblePadV }

    private var bubbleRect: CGRect { paddedInkRect(horizontal: TranscriptMetrics.bubblePadH, vertical: TranscriptMetrics.bubblePadV) }

    private var tagRect: CGRect {
        guard let tag, bubbleRect != .zero else { return .zero }
        let size = tag.text.size()
        let symbolWidth = tag.symbol.map { $0.size.width + 4 } ?? 0
        let width = ceil(size.width + symbolWidth)
        return CGRect(x: bubbleRect.maxX - width, y: bubbleRect.minY - TranscriptLook.provenanceHeight, width: width, height: ceil(size.height))
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(bubbleRect).union(tagRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        let corners = TranscriptMetrics.userCorners
        fillBackground(bubbleRect, color: TranscriptInk.userBubble, at: point, in: context) {
            TranscriptShapes.rounded($0, topLeft: corners.topLeading, topRight: corners.topTrailing,
                                     bottomRight: corners.bottomTrailing, bottomLeft: corners.bottomLeading)
        }
        if let tag {
            let rect = tagRect
            drawAppKit(at: point, in: context) {
                var x = rect.minX
                if let symbol = tag.symbol {
                    let side = symbol.size
                    symbol.draw(in: CGRect(x: x, y: rect.midY - side.height / 2, width: side.width, height: side.height),
                                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    x += side.width + 4
                }
                tag.text.draw(at: CGPoint(x: x, y: rect.minY))
            }
        }
        super.draw(at: point, in: context)
    }
}

/// Fenced code: one paragraph (lines joined by U+2028) on the quiet inset fill across the reply width, its language in a header strip.
final class TranscriptCodeFragment: TranscriptFragment {
    var headerHeight: CGFloat { max(TranscriptLook.codeHeaderHeight, ceil(language?.size().height ?? 0) + 8) }
    override var topMargin: CGFloat { topGap + headerHeight + TranscriptMetrics.codePadV }
    override var bottomMargin: CGFloat { TranscriptMetrics.codePadV }

    // The label is set at the reader's text size, so ⌘+ and ⌘− scale it with the code it names.
    private lazy var language: NSAttributedString? = (paragraphAttributes[TranscriptKey.language] as? String).map {
        let size = (paragraphAttributes[TranscriptKey.languageFontSize] as? NSNumber).map { CGFloat($0.doubleValue) }
            ?? NSFont.preferredFont(forTextStyle: .caption2).pointSize
        return NSAttributedString(string: $0, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// From the text's own start back by the inset padding, to the column's trailing gutter.
    var insetRect: CGRect {
        guard let start = textStartX else { return .zero }
        let left = start - TranscriptMetrics.codePadH
        let right = containerWidth - TranscriptMetrics.gutter - layoutFragmentFrame.minX
        return CGRect(x: left, y: topGap, width: max(0, right - left), height: max(0, layoutFragmentFrame.height - topGap))
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(insetRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        let inset = insetRect
        fillBackground(inset, color: TranscriptInk.codeFill, at: point, in: context) {
            TranscriptShapes.rounded($0, radius: TranscriptMetrics.codeRadius)
        }
        if inset != .zero {
            let divider = inset.minY + headerHeight
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            context.setFillColor(TranscriptInk.hairline.withAlphaComponent(0.4).cgColor)
            context.fill(CGRect(x: inset.minX, y: divider, width: inset.width, height: 0.5))
            context.restoreGState()
            if let language {
                let size = language.size()
                drawAppKit(at: point, in: context) {
                    language.draw(at: CGPoint(x: inset.minX + TranscriptMetrics.codePadH,
                                              y: inset.minY + (headerHeight - size.height) / 2))
                }
            }
        }
        super.draw(at: point, in: context)
    }
}

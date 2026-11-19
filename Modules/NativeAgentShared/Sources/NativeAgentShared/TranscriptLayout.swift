import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// Blueprint: | `TranscriptLayout.swift` | `TranscriptParagraph`, `TranscriptFragment`, `TranscriptShapes`: paragraph kinds, fragment geometry and decoration shapes for Mac and phone |

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

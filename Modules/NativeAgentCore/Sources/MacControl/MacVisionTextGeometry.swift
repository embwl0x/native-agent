import Foundation
import PersistenceCore

// Shared OCR geometry for the pixel percept and independent app-window text.

/// A rectangle in IMAGE PIXEL coordinates, origin top-left (the coordinate
/// space a caller who looked at the screenshot expects). Vision's own
/// normalized bottom-left boxes are converted at the boundary, once.
public struct VisionRect: Sendable, Equatable, Hashable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var area: Double { max(0, w) * max(0, h) }
    public var centerX: Double { x + w / 2 }
    public var centerY: Double { y + h / 2 }

    public func intersection(_ other: VisionRect) -> VisionRect {
        let left = max(x, other.x)
        let top = max(y, other.y)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return VisionRect(x: 0, y: 0, w: 0, h: 0) }
        return VisionRect(x: left, y: top, w: right - left, h: bottom - top)
    }

    /// Intersection over union — the overlap measure the abstain rule uses.
    public func iou(_ other: VisionRect) -> Double {
        let inter = intersection(other).area
        guard inter > 0 else { return 0 }
        let union = area + other.area - inter
        guard union > 0 else { return 0 }
        return inter / union
    }

    /// How much of THIS rect is covered by `other`. Containment is not
    /// symmetric and IoU alone misses it: a small label fully inside a big
    /// button has a low IoU but is completely contained.
    public func coverage(by other: VisionRect) -> Double {
        guard area > 0 else { return 0 }
        return intersection(other).area / area
    }

    public func union(_ other: VisionRect) -> VisionRect {
        let left = min(x, other.x)
        let top = min(y, other.y)
        let right = max(maxX, other.maxX)
        let bottom = max(maxY, other.maxY)
        return VisionRect(x: left, y: top, w: right - left, h: bottom - top)
    }

    /// The SAFE ACTION POINT Agent asked for: not "button-like near here" but
    /// a specific point. The centre, because a synthesized click at a region's
    /// edge lands on whatever is next to it.
    public var actionPoint: (x: Double, y: Double) { (centerX, centerY) }

    /// The shared `MacAXFrame` shape, so a vision affordance's `frame` is the
    /// same field the AX lane's is and no consumer needs a second branch.
    public var axFrame: MacAXFrame { MacAXFrame(x: x, y: y, w: w, h: h) }

    public func toJSON() -> JSONValue {
        .object([
            "x": .double(x.rounded()),
            "y": .double(y.rounded()),
            "w": .double(w.rounded()),
            "h": .double(h.rounded()),
        ])
    }
}
public struct VisionSize: Sendable, Equatable {
    public let width: Double
    public let height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

// MARK: - The text layer's output

/// One OCR observation: what was read, where, and how sure Vision itself was.
public struct VisionTextBox: Sendable, Equatable {
    public let text: String
    public let rect: VisionRect
    /// Vision's own recognition confidence, 0…1. Carried through UNCHANGED
    /// into the row's `text` confidence — the OCR engine's uncertainty is the
    /// honest source for "how sure are we this says what we think it says".
    public let confidence: Double
    /// Which pass produced it — `whole_frame` or `tile`. Tiling is conditional
    /// (see `VisionTextLayer`), so this says whether it fired.
    public let source: String

    public init(text: String, rect: VisionRect, confidence: Double, source: String = "whole_frame") {
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.source = source
    }
}

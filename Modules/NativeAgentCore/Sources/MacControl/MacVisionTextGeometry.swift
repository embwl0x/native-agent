import Foundation
import PersistenceCore
// Blueprint: | `MacVisionTextGeometry.swift` | `VisionRect`, `VisionSize`, `VisionTextBox`; shared image-pixel OCR geometry |

/// Convert Vision’s normalized bottom-left boxes once into top-left image pixels so callers share screenshot coordinates.
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

    public func iou(_ other: VisionRect) -> Double {
        let inter = intersection(other).area
        guard inter > 0 else { return 0 }
        let union = area + other.area - inter
        guard union > 0 else { return 0 }
        return inter / union
    }

    /// Coverage is asymmetric: IoU alone misses a small label fully contained inside a large button.
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

    /// Group against each first member after strict sorting; pairwise tolerances are not transitive.
    static func readingOrder<Value>(
        _ values: [Value], rect: KeyPath<Value, VisionRect>, tolerance: Double,
        geometryPrecedes: (Value, Value) -> Bool, finalPrecedes: (Value, Value) -> Bool
    ) -> [Value] {
        func groups(_ values: [Value], coordinate: (Value) -> Double) -> [[Value]] {
            var groups: [[Value]] = []
            for value in values {
                if let anchor = groups.last?.first, coordinate(value) - coordinate(anchor) <= tolerance {
                    groups[groups.count - 1].append(value)
                } else { groups.append([value]) }
            }
            return groups
        }
        return groups(values.sorted(by: geometryPrecedes), coordinate: { $0[keyPath: rect].y }).flatMap { row in
            let byX = row.sorted {
                let x = $0[keyPath: rect].x, otherX = $1[keyPath: rect].x
                return x == otherX ? geometryPrecedes($0, $1) : x < otherX
            }
            return groups(byX, coordinate: { $0[keyPath: rect].x }).flatMap { $0.sorted(by: finalPrecedes) }
        }
    }

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

public struct VisionTextBox: Sendable, Equatable {
    public let text: String
    public let rect: VisionRect
    /// Carry Vision’s own confidence unchanged so text uncertainty is not replaced by invented certainty.
    public let confidence: Double
    /// Retain pass provenance so callers can tell whether conditional tiling ran.
    public let source: String

    public init(text: String, rect: VisionRect, confidence: Double, source: String = "whole_frame") {
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.source = source
    }
}

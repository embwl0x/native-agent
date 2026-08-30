import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A read from the system cursor, never the point the hand intended to reach.
/// Nil is unavailable; the origin must not be fabricated as a fallback.
public struct MacPointerPosition: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init?(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return nil }
        self.x = x
        self.y = y
    }

    public func isInside(_ frame: MacAXFrame) -> Bool {
        frame.x.isFinite && frame.y.isFinite && frame.w.isFinite && frame.h.isFinite
            && frame.w > 0 && frame.h > 0
            && x >= frame.x && x < frame.x + frame.w
            && y >= frame.y && y < frame.y + frame.h
    }

    public var json: JSONValue { .object(["x": .double(x), "y": .double(y)]) }
}

public protocol MacPointerPositionSource: Sendable {
    func currentPosition() -> MacPointerPosition?
}

public struct SystemMacPointerPositionSource: MacPointerPositionSource {
    public init() {}
    public func currentPosition() -> MacPointerPosition? {
        #if canImport(CoreGraphics) && os(macOS)
        guard let point = CGEvent(source: nil)?.location else { return nil }
        return MacPointerPosition(x: point.x, y: point.y)
        #else
        return nil
        #endif
    }
}

public struct UnavailableMacPointerPositionSource: MacPointerPositionSource {
    public init() {}
    public func currentPosition() -> MacPointerPosition? { nil }
}

public func defaultMacPointerPositionSource() -> any MacPointerPositionSource {
    if NSClassFromString("XCTestCase") != nil { return UnavailableMacPointerPositionSource() }
    return SystemMacPointerPositionSource()
}

/// Choose a fresh clear point in a broad region, without changing its identity
/// or pretending that an explicitly requested covered point is somewhere else.
public enum MacRegionAim {
    public static func pathIsClear(from start: MacPointerPosition, to end: MacPointerPosition,
                                   excluding exclusions: [MacAXFrame]) -> Bool {
        guard exclusions.count <= 128 else { return false }
        for frame in exclusions {
            var enter = 0.0, leave = 1.0
            for (origin, delta, low, high) in [
                (start.x, end.x - start.x, frame.x - 2, frame.x + frame.w + 2),
                (start.y, end.y - start.y, frame.y - 2, frame.y + frame.h + 2),
            ] {
                guard low.isFinite, high.isFinite, high > low else { return false }
                if delta == 0 {
                    if origin < low || origin > high { enter = 2; break }
                } else {
                    let a = (low - origin) / delta, b = (high - origin) / delta
                    enter = max(enter, min(a, b)); leave = min(leave, max(a, b))
                }
            }
            if enter <= leave { return false }
        }
        return true
    }

    public static func point(in frame: MacAXFrame, preferred: MacPointerPosition,
                             excluding exclusions: [MacAXFrame], allowAlternate: Bool) -> MacPointerPosition? {
        guard preferred.isInside(frame), exclusions.count <= 64 else { return nil }
        let blocked = exclusions.map { MacAXFrame(x: $0.x - 2, y: $0.y - 2, w: $0.w + 4, h: $0.h + 4) }
        guard blocked.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.w.isFinite && $0.h.isFinite
            && $0.w > 0 && $0.h > 0 }) else { return nil }
        if !blocked.contains(where: { preferred.isInside($0) }) { return preferred }
        guard allowAlternate else { return nil }
        var clear = [frame]
        for obstruction in blocked {
            clear = clear.flatMap { rect -> [MacAXFrame] in
                let left = max(rect.x, obstruction.x), top = max(rect.y, obstruction.y)
                let right = min(rect.x + rect.w, obstruction.x + obstruction.w)
                let bottom = min(rect.y + rect.h, obstruction.y + obstruction.h)
                guard right > left, bottom > top else { return [rect] }
                return [
                    MacAXFrame(x: rect.x, y: rect.y, w: left - rect.x, h: rect.h),
                    MacAXFrame(x: right, y: rect.y, w: rect.x + rect.w - right, h: rect.h),
                    MacAXFrame(x: rect.x, y: rect.y, w: rect.w, h: top - rect.y),
                    MacAXFrame(x: rect.x, y: bottom, w: rect.w, h: rect.y + rect.h - bottom),
                ].filter { $0.w >= 4 && $0.h >= 4 }
            }.sorted { $0.w * $0.h > $1.w * $1.h }
            // Bound fragmented window arrangements. Dropping a candidate can
            // only make this unavailable; every retained candidate stays clear.
            if clear.count > 128 { clear = Array(clear.prefix(128)) }
            if clear.isEmpty { return nil }
        }
        return clear.lazy.compactMap { MacPointerPosition(x: $0.x + $0.w / 2, y: $0.y + $0.h / 2) }
            .first { candidate in !blocked.contains { candidate.isInside($0) } }
    }
}

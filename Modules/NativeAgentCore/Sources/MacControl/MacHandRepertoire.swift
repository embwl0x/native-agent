import CoreGraphics
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon) && os(macOS)
import Carbon
#endif

// Blueprint: | `MacHandRepertoire.swift` | `MacHandRepertoire`: constructs bounded keyboard/pointer step sequences with one drag interpolation, held-key/button balance and residual-release accounting |

// Pure bounded plans in global screen coordinates; no app-specific policy.
// Callers own admission, timing, emission and effect verification.

/// One step of a planned gesture. A gesture is an ordered list of these, and
/// the caller posts them in order.
///
/// `.wait` is a step rather than a `Thread.sleep` inside the planner because a
/// hover with a dwell, a press-and-hold, and a drag that pauses over a drop
/// target are all real human gestures whose TIMING is part of the gesture. The
/// planner states the timing; the caller performs it.
public enum MacHandStep: Sendable, Equatable {
    case mouse(MacMouseEvent)
    case key(MacKeyEvent)
    case scroll(MacScrollEvent)
    case wait(Duration)
}

extension MacHandStep {
    public var keyEvent: MacKeyEvent? {
        if case .key(let event) = self { return event }
        return nil
    }
}

// MARK: - The repertoire

public enum MacHandRepertoire {

    // MARK: Bounds
    //
    // Every bound here is a SAFETY bound, not a preference. They cap what one
    // planned gesture can be, so a bad number from a model becomes a clamped
    // gesture rather than a hundred thousand events posted into the host.

    /// Interpolation steps for one straight A→B drag. Below 2 that drag is a
    /// teleport, so `drag(from:to:)` floors here. `dragPath` does NOT: a caller
    /// who supplied the waypoints already chose the density, and forcing extra
    /// interpolation into a hand-drawn path would silently change its shape.
    public static let minimumDragSteps = 2
    public static let maximumDragSteps = 240
    /// Points in one `dragPath`. A path with more corners than this is not a
    /// gesture, it is a drawing — and drawing is composed of many gestures.
    public static let maximumPathPoints = 64
    /// A single planned dwell/hold. Longer waits are the caller's business.
    public static let maximumWaitMilliseconds = 60_000

    /// Virtual keycodes of the modifier keys, for holds. `MacKeyEvent` carries
    /// modifiers as FLAGS, which is right for a chord — but a flag lives on an
    /// event, and a hold has to stay down across events that carry no flags at
    /// all. So a hold emits the modifier's PHYSICAL key down/up around the
    /// inner steps AND sets the flags on every inner input event. Both,
    /// because apps split on which they
    /// watch: a text field reads the flags, a game reads the key.
    public enum ModifierKeyCode {
        public static let command: UInt16 = 55
        public static let shift: UInt16 = 56
        public static let option: UInt16 = 58
        public static let control: UInt16 = 59
        public static let function: UInt16 = 63
    }

    /// Physical keycodes for a modifier set, in a stable order so plans are
    /// deterministic and byte-comparable in tests.
    public static func modifierKeyCodes(_ modifiers: MacKeyModifiers) -> [UInt16] {
        var codes: [UInt16] = []
        if modifiers.contains(.command) { codes.append(ModifierKeyCode.command) }
        if modifiers.contains(.control) { codes.append(ModifierKeyCode.control) }
        if modifiers.contains(.function) { codes.append(ModifierKeyCode.function) }
        if modifiers.contains(.option) { codes.append(ModifierKeyCode.option) }
        if modifiers.contains(.shift) { codes.append(ModifierKeyCode.shift) }
        return codes
    }

    // MARK: - Pointer

    /// Move the cursor. No button state changes.
    public static func move(to point: CGPoint, button: MacMouseButton = .left) -> [MacHandStep] {
        [.mouse(MacMouseEvent(phase: .move, button: button, x: point.x, y: point.y))]
    }

    /// Move somewhere and STAY there. Hover is not a move: tooltips, menu
    /// reveals, hover-highlights and drop-target feedback all key off the
    /// cursor resting, which a move alone never expresses.
    public static func hover(at point: CGPoint, dwellMs: Int) -> [MacHandStep] {
        move(to: point) + [.wait(.milliseconds(clampWait(dwellMs)))]
    }

    /// Press and HOLD a button at a point. The matching `release` is the
    /// caller's obligation — see `dragPath` / `pressAndHold` for the composed
    /// forms that cannot leave a button down.
    public static func press(button: MacMouseButton, at point: CGPoint) -> [MacHandStep] {
        return [.mouse(MacMouseEvent(phase: .down, button: button, x: point.x, y: point.y, clickCount: 1))]
    }

    public static func release(button: MacMouseButton, at point: CGPoint) -> [MacHandStep] {
        return [.mouse(MacMouseEvent(phase: .up, button: button, x: point.x, y: point.y, clickCount: 1))]
    }

    /// Press, wait, release — a press-and-hold, which is a distinct gesture
    /// from a click on long-press surfaces. Balanced by construction.
    public static func pressAndHold(
        button: MacMouseButton,
        at point: CGPoint,
        holdMs: Int
    ) -> [MacHandStep] {
        press(button: button, at: point)
            + [.wait(.milliseconds(clampWait(holdMs)))]
            + release(button: button, at: point)
    }

    /// Click: move → (down → up) × count, with `clickCount` counting UP across
    /// the burst. The leading move puts hover-sensitive UI in the state a
    /// human's click would find it in. The ascending clickCount is what makes a
    /// double-click a double-click: macOS reads the click state off the event,
    /// so two events both stamped 1 are two single clicks, not a double.
    public static func click(
        button: MacMouseButton,
        at point: CGPoint,
        count: Int = 1
    ) -> [MacHandStep] {
        var plan = move(to: point, button: button)
        for index in 1...max(1, min(count, 3)) {
            plan.append(.mouse(MacMouseEvent(phase: .down, button: button, x: point.x, y: point.y, clickCount: index)))
            plan.append(.mouse(MacMouseEvent(phase: .up, button: button, x: point.x, y: point.y, clickCount: index)))
        }
        return plan
    }

    /// A straight drag from A to B, interpolated.
    ///
    /// EXACTLY `steps + 2` mouse events: one press at `from`, `steps`
    /// intermediate drag moves, one release at `to`. The last interpolated move
    /// lands exactly on `to` so the release never introduces a jump the app has
    /// not already seen.
    ///
    /// There is deliberately NO leading `.move` here: `mouseDown` carries its
    /// own position, so the press lands where it says it lands, and the event
    /// arithmetic stays exactly `steps + 2`. When the target needs hover state
    /// first (a drag handle that only appears on hover), compose:
    /// `hover(at:dwellMs:) + drag(...)`.
    public static func drag(
        button: MacMouseButton = .left,
        from: CGPoint,
        to: CGPoint,
        steps: Int,
        holdMs: Int = 0,
        travelMs: Int = 0
    ) throws -> [MacHandStep] {
        try dragPath(
            button: button,
            through: [from, to],
            // The teleport floor lives HERE, on the two-point convenience —
            // this is the call that would otherwise emit a single jump.
            stepsPerSegment: max(minimumDragSteps, steps),
            holdMs: holdMs,
            travelMs: travelMs
        )
    }

    /// A drag along a PATH: press at the first point, travel through EVERY
    /// remaining point in order, release at the last.
    ///
    /// `stepsPerSegment` interpolates WITHIN each segment. A real hand emits
    /// many small moves; an app that integrates deltas (a slider, a scrub bar,
    /// a canvas, a drag-and-drop list that measures velocity) sees a single
    /// jump as no movement at all and drops the drag. Interpolation is
    /// therefore not smoothing — it is the difference between a drag that works
    /// and one that does nothing.
    ///
    /// `holdMs`, when non-zero, inserts a dwell after the press and another
    /// before the release: many drop targets only arm after the pointer has
    /// rested on them, and many sources only begin a drag after a hold.
    ///
    /// Balanced by construction: the press and the release are emitted by the
    /// same call, and no path through this function can produce one without the
    /// other.
    public static func dragPath(
        button: MacMouseButton = .left,
        through points: [CGPoint],
        stepsPerSegment: Int = 1,
        holdMs: Int = 0,
        travelMs: Int = 0
    ) throws -> [MacHandStep] {
        guard points.count >= 2 else {
            throw MacHandPathError.needsAtLeastTwoPoints(points.count)
        }
        let path = Array(points.prefix(maximumPathPoints))
        let perSegment = max(1, min(stepsPerSegment, maximumDragSteps))
        let dwell = clampWait(holdMs)
        // Optional elapsed travel is distributed across moves, not substituted
        // with a pause at either endpoint.
        let travel = clampWait(travelMs)
        let moveCount = (path.count - 1) * perSegment
        var moveIndex = 0

        var plan: [MacHandStep] = [
            .mouse(MacMouseEvent(phase: .down, button: button, x: path[0].x, y: path[0].y, clickCount: 1))
        ]
        if dwell > 0 { plan.append(.wait(.milliseconds(dwell))) }

        for index in 1..<path.count {
            let start = path[index - 1]
            let end = path[index]
            for step in 1...perSegment {
                let delay = travel * (moveIndex + 1) / moveCount - travel * moveIndex / moveCount
                if delay > 0 { plan.append(.wait(.milliseconds(delay))) }
                moveIndex += 1
                let progress = Double(step) / Double(perSegment)
                plan.append(.mouse(MacMouseEvent(
                    phase: .drag,
                    button: button,
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress
                )))
            }
        }

        if dwell > 0 { plan.append(.wait(.milliseconds(dwell))) }
        let last = path[path.count - 1]
        plan.append(.mouse(MacMouseEvent(phase: .up, button: button, x: last.x, y: last.y, clickCount: 1)))
        return plan
    }

    /// A path that needs at least a start and an end.
    public enum MacHandPathError: Error, Equatable, Sendable {
        case needsAtLeastTwoPoints(Int)
    }

    /// Wheel scroll. Deltas are the seam's own units; `unit` picks line
    /// (notched wheel) or pixel (trackpad-grade) granularity.
    public static func scroll(dx: Int32, dy: Int32, unit: MacScrollUnit = .line) -> [MacHandStep] {
        [.scroll(MacScrollEvent(deltaX: dx, deltaY: dy, unit: unit))]
    }

    // MARK: - Keyboard

    /// Literal text, one keyDown/keyUp pair per character carrying it verbatim.
    public static func type(text: String) -> [MacHandStep] {
        text.flatMap { character in
            let unit = String(character)
            return [
                MacHandStep.key(MacKeyEvent(keyCode: 0, down: true, modifiers: [], unicodeText: unit)),
                .key(MacKeyEvent(keyCode: 0, down: false, modifiers: [], unicodeText: unit)),
            ]
        }
    }

    /// One key, with modifier flags on both the down and the up. The flags on
    /// the UP matter: an app that tracks modifier state from events believes
    /// the modifier is still held if the release arrives without them.
    public static func chord(_ chord: MacKeyChord) -> [MacHandStep] {
        [
            .key(MacKeyEvent(keyCode: chord.keyCode, down: true, modifiers: chord.modifiers)),
            .key(MacKeyEvent(keyCode: chord.keyCode, down: false, modifiers: chord.modifiers)),
        ]
    }

    /// Wrap planned steps in physical key downs and reverse-order releases.
    public static func hold(
        modifiers: MacKeyModifiers = [],
        keys: [UInt16] = [],
        whileDoing steps: [MacHandStep]
    ) -> [MacHandStep] {
        let held = modifierKeyCodes(modifiers) + keys
        var plan: [MacHandStep] = held.map {
            .key(MacKeyEvent(keyCode: $0, down: true, modifiers: modifiers))
        }

        // Every inner input carries held flags as well as physical key downs.
        plan.append(contentsOf: steps.map { step in
            switch step {
            case .key(let event):
                return .key(MacKeyEvent(
                    keyCode: event.keyCode, down: event.down,
                    modifiers: event.modifiers.union(modifiers), unicodeText: event.unicodeText
                ))
            case .mouse(let event):
                return .mouse(MacMouseEvent(
                    phase: event.phase, button: event.button, x: event.x, y: event.y,
                    clickCount: event.clickCount, modifiers: event.modifiers.union(modifiers)
                ))
            case .scroll(let event):
                return .scroll(MacScrollEvent(
                    deltaX: event.deltaX, deltaY: event.deltaY, unit: event.unit,
                    modifiers: event.modifiers.union(modifiers)
                ))
            case .wait: return step
            }
        })
        var remaining = modifiers
        return plan + held.reversed().map { code in
            switch code {
            case ModifierKeyCode.command: remaining.remove(.command)
            case ModifierKeyCode.control: remaining.remove(.control)
            case ModifierKeyCode.function: remaining.remove(.function)
            case ModifierKeyCode.option: remaining.remove(.option)
            case ModifierKeyCode.shift: remaining.remove(.shift)
            default: break
            }
            return MacHandStep.key(MacKeyEvent(keyCode: code, down: false, modifiers: remaining))
        }
    }

    // MARK: - Invariants
    //
    // These are not test helpers. A caller assembling gestures can assert them
    // before posting anything, and the stuck-modifier failure mode is severe
    // enough that "the plan is balanced" deserves to be checkable in
    // production, not only under `swift test`.

    /// Keycodes pressed but never released, in press order. Empty is correct.
    public static func residualHeldKeys(in plan: [MacHandStep]) -> [UInt16] {
        var down: [UInt16] = []
        for step in plan {
            guard case .key(let event) = step else { continue }
            if event.down {
                down.append(event.keyCode)
            } else if let index = down.lastIndex(of: event.keyCode) {
                down.remove(at: index)
            }
        }
        return down
    }

    /// Buttons pressed but never released, in press order. A drag counts as
    /// held: `.drag` neither presses nor releases.
    public static func residualHeldButtons(in plan: [MacHandStep]) -> [MacMouseButton] {
        var down: [MacMouseButton] = []
        for step in plan {
            guard case .mouse(let event) = step else { continue }
            switch event.phase {
            case .down:
                down.append(event.button)
            case .up:
                if let index = down.lastIndex(of: event.button) { down.remove(at: index) }
            case .move, .drag:
                continue
            }
        }
        return down
    }

    /// True when the plan leaves the hand exactly as it found it: no key down,
    /// no button down.
    public static func isBalanced(_ plan: [MacHandStep]) -> Bool {
        residualHeldKeys(in: plan).isEmpty && residualHeldButtons(in: plan).isEmpty
    }

    // MARK: - Private

    private static func clampWait(_ milliseconds: Int) -> Int {
        max(0, min(milliseconds, maximumWaitMilliseconds))
    }
}

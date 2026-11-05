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

// Blueprint: | `MacHandRepertoire.swift` | `MacHandRepertoire`: Bounded gestures with interpolated drags, balanced holds and residual releases |

// Plans are pure; callers own admission, timing, emission and effect verification.

/// Timing belongs in gesture steps so callers can perform dwells without blocking the pure planner.
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
    // Safety bounds prevent model-supplied sizes from flooding the host with events.

    /// Two-point drags need interpolation to avoid teleporting; authored paths already choose their own density.
    public static let minimumDragSteps = 2
    public static let maximumDragSteps = 240
    /// Bound path complexity so one gesture cannot become an unbounded drawing.
    public static let maximumPathPoints = 64
    /// Longer waits belong to the caller.
    public static let maximumWaitMilliseconds = 60_000

    /// Holds need physical key down/up and flags on inner events: games watch keys while text fields watch flags.
    public enum ModifierKeyCode {
        public static let command: UInt16 = 55
        public static let shift: UInt16 = 56
        public static let option: UInt16 = 58
        public static let control: UInt16 = 59
        public static let function: UInt16 = 63
    }

    /// Stable modifier ordering keeps plans deterministic.
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

    public static func move(to point: CGPoint, button: MacMouseButton = .left) -> [MacHandStep] {
        [.mouse(MacMouseEvent(phase: .move, button: button, x: point.x, y: point.y))]
    }

    /// Hover dwell lets tooltips, menus and drop targets react to a resting cursor.
    public static func hover(at point: CGPoint, dwellMs: Int) -> [MacHandStep] {
        move(to: point) + [.wait(.milliseconds(clampWait(dwellMs)))]
    }

    /// The caller owes a matching release; composed holds and drags balance it internally.
    public static func press(button: MacMouseButton, at point: CGPoint) -> [MacHandStep] {
        return [.mouse(MacMouseEvent(phase: .down, button: button, x: point.x, y: point.y, clickCount: 1))]
    }

    public static func release(button: MacMouseButton, at point: CGPoint) -> [MacHandStep] {
        return [.mouse(MacMouseEvent(phase: .up, button: button, x: point.x, y: point.y, clickCount: 1))]
    }

    /// Balanced press/wait/release supports surfaces that distinguish long presses from clicks.
    public static func pressAndHold(
        button: MacMouseButton,
        at point: CGPoint,
        holdMs: Int
    ) -> [MacHandStep] {
        press(button: button, at: point)
            + [.wait(.milliseconds(clampWait(holdMs)))]
            + release(button: button, at: point)
    }

    /// Leading movement primes hover state; ascending clickCount makes macOS recognize a double-click rather than two single clicks.
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

    /// The final interpolated move reaches `to` before release to avoid a jump. No leading move: mouseDown carries its position; hover-sensitive sources must
    /// compose a hover first.
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
            // Only the two-point convenience needs a floor against teleporting.
            stepsPerSegment: max(minimumDragSteps, steps),
            holdMs: holdMs,
            travelMs: travelMs
        )
    }

    /// Interpolate each segment so delta- and velocity-sensitive apps observe movement. Dwell at both ends lets drag sources and drop targets arm; one call
    /// balances the press and release.
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
        // Optional elapsed travel is distributed across moves, not substituted with a pause at either endpoint.
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

    public enum MacHandPathError: Error, Equatable, Sendable {
        case needsAtLeastTwoPoints(Int)
    }

    /// Keep deltas in the sink’s declared wheel or pixel units.
    public static func scroll(dx: Int32, dy: Int32, unit: MacScrollUnit = .line) -> [MacHandStep] {
        [.scroll(MacScrollEvent(deltaX: dx, deltaY: dy, unit: unit))]
    }

    // MARK: - Keyboard

    public static func type(text: String) -> [MacHandStep] {
        text.flatMap { character in
            let unit = String(character)
            return [
                MacHandStep.key(MacKeyEvent(keyCode: 0, down: true, modifiers: [], unicodeText: unit)),
                .key(MacKeyEvent(keyCode: 0, down: false, modifiers: [], unicodeText: unit)),
            ]
        }
    }

    /// Modifier flags must reach key-up too, or apps may believe a modifier remains held.
    public static func chord(_ chord: MacKeyChord) -> [MacHandStep] {
        [
            .key(MacKeyEvent(keyCode: chord.keyCode, down: true, modifiers: chord.modifiers)),
            .key(MacKeyEvent(keyCode: chord.keyCode, down: false, modifiers: chord.modifiers)),
        ]
    }

    /// Reverse-order releases balance nested holds.
    public static func hold(
        modifiers: MacKeyModifiers = [],
        keys: [UInt16] = [],
        whileDoing steps: [MacHandStep]
    ) -> [MacHandStep] {
        let held = modifierKeyCodes(modifiers) + keys
        var plan: [MacHandStep] = held.map {
            .key(MacKeyEvent(keyCode: $0, down: true, modifiers: modifiers))
        }

        // Apps may watch flags rather than physical modifier keys.
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
    // Production callers can check balance before posting to prevent stuck keys or buttons.

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

    /// Drag events preserve a held button; they neither press nor release it.
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

    public static func isBalanced(_ plan: [MacHandStep]) -> Bool {
        residualHeldKeys(in: plan).isEmpty && residualHeldButtons(in: plan).isEmpty
    }

    // MARK: - Private

    private static func clampWait(_ milliseconds: Int) -> Int {
        max(0, min(milliseconds, maximumWaitMilliseconds))
    }
}

import CoreGraphics
import Foundation

// Blueprint: | `MacHandRepertoire.swift` | `MacHandRepertoire`: pure bounded keyboard/pointer plans with held-key/button balance and residual-release accounting |

// MARK: - MacHandRepertoire
//
// THE FULL HAND. Everything a human hand and keyboard can do, expressed as a
// PURE PLAN.
//
// Today's act verbs (click/type/select/toggle/dismiss/scroll/open) are
// AX-SEMANTIC: they name an element and stop existing the moment the app has no
// accessibility tree. A human's hands never stop working. In a screen that is
// only pixels there are no elements — there is a point, a button, and a path.
// The gesture that separates a real hand from a click-only one is the DRAG:
// picking a thing up at A, carrying it through the intervening points, and
// putting it down at B. Any surface that tracks deltas — a slider, a
// drag-and-drop list, a canvas, a game inventory — ignores a teleport.
//
// GENERAL BY LAW: nothing in this file knows what app it is aiming at. There is
// no branch on an app name, a window title, or a bundle id, and there must
// never be one. A hard instance is the BAR that proves the repertoire is
// complete; it is never the target.
//
// PURE PLANNER, POSTS NOTHING. `MacHandRepertoire` takes a described gesture
// and returns the ordered steps that perform it. It never touches a
// `MacEventSink`, never sleeps, and never reads the clock. Three reasons:
//   1. every gesture is testable headless, with no host input and no timing;
//   2. every safety gate (Accessibility grant, target policy, motor epoch)
//      stays in the caller, where it already lives — this file cannot become a
//      second, ungated route to synthesized input;
//   3. dwell and hold are DATA (`.wait` steps) inside the returned plan, so the
//      caller honours them with its own scheduler and can cancel mid-gesture.
//
// This is the same shape as `MacEventPlanner` in `MacAccessibilityActuator.swift`
// — deliberately so. `MacEventPlanner` is the narrow seam for the semantic
// verbs and this is the full repertoire over the same event types; where the
// two overlap (`typeText`, `chord`) this file CALLS the planner rather than
// restating it, so there is one definition of how a keystroke is shaped.
//
// COORDINATES are points in global screen space — exactly what `MacMouseEvent`
// already carries (`x`/`y` as `Double`). There is no second convention here and
// no conversion: a `CGPoint` handed in is a `CGPoint` handed to the sink.

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
    case wait(milliseconds: Int)
}

extension MacHandStep {
    public var keyEvent: MacKeyEvent? {
        if case .key(let event) = self { return event }
        return nil
    }
}

/// The pointer buttons a hand has. `MacMouseButton` — the event seam — models
/// only left and right today, so `.middle` is DESCRIBABLE here but not
/// PLANNABLE: asking for it throws `MacHandUnsupported` naming exactly what is
/// missing, rather than silently substituting a left click. A middle click that
/// quietly becomes a left click is worse than a refusal: it opens the link
/// instead of opening it in a new tab, and the caller believes it succeeded.
public enum MacHandButton: String, Sendable, Equatable, CaseIterable {
    case left
    case right
    case middle

    /// The seam button, or nil when the seam cannot express this button.
    public var seamButton: MacMouseButton? {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return nil
        }
    }
}

/// A capability this repertoire can DESCRIBE but the physical event seam cannot
/// currently EXPRESS. Every case names the concrete missing piece so the report
/// is actionable and so no gesture ever degrades into a different gesture.
public enum MacHandLimit: String, Sendable, Equatable {
    /// `MacMouseButton` has no `.middle`, and `CGEventSink.post(mouse:)` has no
    /// `.otherMouseDown/.otherMouseUp/.otherMouseDragged` mapping.
    case middleButtonNotAtSeam = "mac_hand_middle_button_not_at_event_seam"
}

/// Thrown when a described gesture has no honest event representation.
public struct MacHandUnsupported: Error, Equatable, Sendable {
    public let limit: MacHandLimit
    /// What the seam would need, in one sentence, for a report or a log line.
    public let needed: String

    public init(limit: MacHandLimit, needed: String) {
        self.limit = limit
        self.needed = needed
    }
}

/// Thrown when the body of a `hold` fails.
///
/// THE POINT OF THIS TYPE is `recoveryPlan`. A stuck modifier is the worst
/// failure this file can produce: it does not crash, it silently corrupts every
/// later keystroke system-wide — the user's own typing included — until
/// something happens to clear it. So a failing hold does not merely refuse; it
/// hands back a plan that is safe to post, ending in the release of every key
/// it pressed. A caller that has already begun posting can always get the hand
/// back to neutral.
public struct MacHandHoldFailure: Error {
    public let underlying: any Error
    /// Steps planned before the failure, terminated by every release needed to
    /// leave no key and no button down. Always balanced.
    public let recoveryPlan: [MacHandStep]

    public init(underlying: any Error, recoveryPlan: [MacHandStep]) {
        self.underlying = underlying
        self.recoveryPlan = recoveryPlan
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
    public static func move(to point: CGPoint) -> [MacHandStep] {
        [.mouse(MacMouseEvent(phase: .move, button: .left, x: point.x, y: point.y))]
    }

    /// Move somewhere and STAY there. Hover is not a move: tooltips, menu
    /// reveals, hover-highlights and drop-target feedback all key off the
    /// cursor resting, which a move alone never expresses.
    public static func hover(at point: CGPoint, dwellMs: Int) -> [MacHandStep] {
        move(to: point) + [.wait(milliseconds: clampWait(dwellMs))]
    }

    /// Press and HOLD a button at a point. The matching `release` is the
    /// caller's obligation — see `dragPath` / `pressAndHold` for the composed
    /// forms that cannot leave a button down.
    public static func press(button: MacHandButton, at point: CGPoint) throws -> [MacHandStep] {
        let seam = try seamButton(button)
        return [.mouse(MacMouseEvent(phase: .down, button: seam, x: point.x, y: point.y, clickCount: 1))]
    }

    public static func release(button: MacHandButton, at point: CGPoint) throws -> [MacHandStep] {
        let seam = try seamButton(button)
        return [.mouse(MacMouseEvent(phase: .up, button: seam, x: point.x, y: point.y, clickCount: 1))]
    }

    /// Press, wait, release — a press-and-hold, which is a distinct gesture
    /// from a click on long-press surfaces. Balanced by construction.
    public static func pressAndHold(
        button: MacHandButton,
        at point: CGPoint,
        holdMs: Int
    ) throws -> [MacHandStep] {
        try press(button: button, at: point)
            + [.wait(milliseconds: clampWait(holdMs))]
            + release(button: button, at: point)
    }

    /// Click: move → (down → up) × count, with `clickCount` counting UP across
    /// the burst. The leading move puts hover-sensitive UI in the state a
    /// human's click would find it in. The ascending clickCount is what makes a
    /// double-click a double-click: macOS reads the click state off the event,
    /// so two events both stamped 1 are two single clicks, not a double.
    public static func click(
        button: MacHandButton,
        at point: CGPoint,
        count: Int = 1
    ) throws -> [MacHandStep] {
        let seam = try seamButton(button)
        return MacEventPlanner.click(x: point.x, y: point.y, button: seam, count: count)
            .map { MacHandStep.mouse($0) }
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
        button: MacHandButton = .left,
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
        button: MacHandButton = .left,
        through points: [CGPoint],
        stepsPerSegment: Int = 1,
        holdMs: Int = 0,
        travelMs: Int = 0
    ) throws -> [MacHandStep] {
        let seam = try seamButton(button)
        guard points.count >= 2 else {
            throw MacHandPathError.needsAtLeastTwoPoints(points.count)
        }
        let path = Array(points.prefix(maximumPathPoints))
        let perSegment = max(1, min(stepsPerSegment, maximumDragSteps))
        let dwell = clampWait(holdMs)
        // Optional elapsed travel is distributed across moves, not substituted
        // with a pause at either endpoint. Legacy unpaced plans stay unchanged.
        let travel = clampWait(travelMs)
        let moveCount = (path.count - 1) * perSegment
        var moveIndex = 0

        var plan: [MacHandStep] = [
            .mouse(MacMouseEvent(phase: .down, button: seam, x: path[0].x, y: path[0].y, clickCount: 1))
        ]
        if dwell > 0 { plan.append(.wait(milliseconds: dwell)) }

        for index in 1..<path.count {
            let start = path[index - 1]
            let end = path[index]
            for step in 1...perSegment {
                let delay = travel * (moveIndex + 1) / moveCount - travel * moveIndex / moveCount
                if delay > 0 { plan.append(.wait(milliseconds: delay)) }
                moveIndex += 1
                let progress = Double(step) / Double(perSegment)
                plan.append(.mouse(MacMouseEvent(
                    phase: .drag,
                    button: seam,
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress
                )))
            }
        }

        if dwell > 0 { plan.append(.wait(milliseconds: dwell)) }
        let last = path[path.count - 1]
        plan.append(.mouse(MacMouseEvent(phase: .up, button: seam, x: last.x, y: last.y, clickCount: 1)))
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

    /// Literal text, one keyDown/keyUp pair per character carrying the
    /// character verbatim. Delegates to `MacEventPlanner` so there is exactly
    /// one definition of how typing is shaped in this module.
    public static func type(text: String) -> [MacHandStep] {
        MacEventPlanner.typeText(text).map { MacHandStep.key($0) }
    }

    /// One key, with modifier flags on both the down and the up. The flags on
    /// the UP matter: an app that tracks modifier state from events believes
    /// the modifier is still held if the release arrives without them.
    public static func key(code: UInt16, modifiers: MacKeyModifiers = []) -> [MacHandStep] {
        [
            .key(MacKeyEvent(keyCode: code, down: true, modifiers: modifiers)),
            .key(MacKeyEvent(keyCode: code, down: false, modifiers: modifiers)),
        ]
    }

    /// A parsed chord. Delegates to `MacEventPlanner` for the same reason
    /// `type(text:)` does.
    public static func chord(_ chord: MacKeyChord) -> [MacHandStep] {
        MacEventPlanner.chord(chord).map { MacHandStep.key($0) }
    }

    /// HOLD a modifier and/or key down while doing something else — ⌥-drag to
    /// copy, ⇧-click to extend a selection, holding a movement key while
    /// aiming. This is the gesture that a flags-on-the-event model cannot
    /// express on its own, because mouse events at this seam carry no modifier
    /// field: the only way a drag can be an ⌥-drag is for the ⌥ key to be
    /// physically down across it.
    ///
    /// THE RELEASE IS STRUCTURAL. Every exit from this function — normal return
    /// and thrown body alike — goes through `sealed()`, which appends the key-up
    /// for every key pressed, in reverse press order. There is no `return plan`
    /// anywhere in the function and no early exit that skips it. (Swift's
    /// `defer` cannot alter a value being returned, so a single sealing exit is
    /// the structural equivalent; `residualHeldKeys` proves it on both paths.)
    ///
    /// A throwing body does not merely propagate: it throws
    /// `MacHandHoldFailure` carrying a `recoveryPlan` that is safe to post and
    /// ends with every key released.
    public static func hold(
        modifiers: MacKeyModifiers = [],
        keys: [UInt16] = [],
        whileDoing body: () throws -> [MacHandStep]
    ) throws -> [MacHandStep] {
        let held = modifierKeyCodes(modifiers) + keys
        var plan: [MacHandStep] = held.map {
            .key(MacKeyEvent(keyCode: $0, down: true, modifiers: modifiers))
        }

        // The ONLY way out. Both call sites below use it; nothing returns `plan`.
        func sealed() -> [MacHandStep] {
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

        do {
            // Every inner input carries the held flags: relying only on a
            // preceding key-down races asynchronous HID delivery.
            let inner = try body()
            plan.append(contentsOf: inner.map { step in
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
        } catch {
            throw MacHandHoldFailure(underlying: error, recoveryPlan: sealed())
        }
        return sealed()
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

    private static func seamButton(_ button: MacHandButton) throws -> MacMouseButton {
        guard let seam = button.seamButton else {
            throw MacHandUnsupported(
                limit: .middleButtonNotAtSeam,
                needed: "MacMouseButton needs a `.middle` case and CGEventSink.post(mouse:) needs the .otherMouseDown/.otherMouseUp/.otherMouseDragged mapping (CGMouseButton.center) before middle-button gestures can be planned."
            )
        }
        return seam
    }

    private static func clampWait(_ milliseconds: Int) -> Int {
        max(0, min(milliseconds, maximumWaitMilliseconds))
    }
}

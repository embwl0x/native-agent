import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension SwiftNativeMacControl {
    // MARK: act — the CLOSED LOOP (native-look item 3)

    /// The physical tier behind the model-facing `act`. The caller already
    /// resolved a fresh named/ordinal target; this owner validates a bounded
    /// gesture, plans it through `MacHandRepertoire`, and posts the balanced
    /// sequence through the same gated event sink as click/keystroke/scroll.
    func handleHand(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        if let refusal = injectionPreconditions(action: "hand", requiresSink: true) { return refusal }
        if let refusal = await attentionActionRefusal(action: "hand", body: body) { return refusal }
        guard let gesture = body.stringValue("gesture")?.lowercased(), !gesture.isEmpty else {
            return injectionRefusal(action: "hand", error: "missing required field: gesture", status: 400)
        }
        let button: MacHandButton
        if body["button"] != nil {
            guard let raw = body.stringValue("button")?.lowercased(),
                  let parsed = MacHandButton(rawValue: raw), parsed != .middle,
                  ["click", "double_click", "hold", "drag"].contains(gesture) else {
                return injectionRefusal(action: "hand", error: "invalid mouse button for gesture", status: 400)
            }
            button = parsed
        } else {
            button = .left
        }

        func point(_ xKey: String = "x", _ yKey: String = "y") -> CGPoint? {
            guard let x = Self.doubleValue(body, xKey), let y = Self.doubleValue(body, yKey),
                  x.isFinite, y.isFinite, abs(x) <= 100_000, abs(y) <= 100_000 else { return nil }
            return CGPoint(x: x, y: y)
        }
        let waitMs = Self.handWaitMilliseconds(seconds: Self.doubleValue(body, "seconds"))
        var dragTravelMs: Int?
        var plan: [MacHandStep]
        do {
            switch gesture {
            case "click", "double_click", "click_type":
                guard let at = point() else {
                    return injectionRefusal(action: "hand", error: "gesture needs finite x/y", status: 400)
                }
                let count = gesture == "double_click" ? 2 : 1
                var steps = try MacHandRepertoire.click(button: button, at: at, count: count)
                if gesture == "click_type" {
                    guard let text = body.stringValue("text"), !text.isEmpty else {
                        return injectionRefusal(action: "hand", error: "click_type needs text", status: 400)
                    }
                    _ = try MacKeySyntax.validateText(text)
                    steps += MacHandRepertoire.type(text: text)
                }
                plan = steps
            case "hover":
                guard let at = point() else {
                    return injectionRefusal(action: "hand", error: "hover needs finite x/y", status: 400)
                }
                plan = MacHandRepertoire.hover(at: at, dwellMs: waitMs)
            case "move":
                guard let at = point() else {
                    return injectionRefusal(action: "hand", error: "move needs finite x/y", status: 400)
                }
                plan = MacHandRepertoire.move(to: at)
            case "hold":
                guard let at = point() else {
                    return injectionRefusal(action: "hand", error: "hold needs finite x/y", status: 400)
                }
                plan = try MacHandRepertoire.pressAndHold(button: button, at: at, holdMs: waitMs)
            case "drag":
                guard let start = point(), let end = point("to_x", "to_y") else {
                    return injectionRefusal(action: "hand", error: "drag needs finite x/y and to_x/to_y", status: 400)
                }
                // Named four-verb drags publish travel_seconds. Preserve the
                // legacy low-level seconds-as-endpoint-dwell contract otherwise.
                if body["travel_seconds"] != nil {
                    dragTravelMs = Self.handDragMilliseconds(seconds: Self.doubleValue(body, "travel_seconds"))
                }
                plan = try MacHandRepertoire.drag(
                    button: button,
                    from: start,
                    to: end,
                    steps: dragTravelMs.map { max(4, min(60, $0 / 16)) } ?? 18,
                    holdMs: dragTravelMs == nil ? min(waitMs, 1_500) : 0,
                    travelMs: dragTravelMs ?? 0
                )
            case "scroll":
                guard let at = point() else {
                    return injectionRefusal(action: "hand", error: "scroll needs finite x/y", status: 400)
                }
                let dy = max(-120, min(Self.intValue(body, "dy") ?? -6, 120))
                let dx = max(-120, min(Self.intValue(body, "dx") ?? 0, 120))
                plan = MacHandRepertoire.move(to: at)
                    + MacHandRepertoire.scroll(dx: Int32(dx), dy: Int32(dy), unit: .line)
            case "key":
                guard let keys = body.stringValue("keys") else {
                    return injectionRefusal(action: "hand", error: "key needs keys", status: 400)
                }
                plan = try MacKeySyntax.parseChords(keys).flatMap(MacHandRepertoire.chord)
            case "hold_key":
                guard let keys = body.stringValue("keys") else {
                    return injectionRefusal(action: "hand", error: "hold_key needs a held key set", status: 400)
                }
                let held = try MacKeySyntax.parseHeldKeys(keys)
                plan = try MacHandRepertoire.hold(
                    modifiers: held.modifiers,
                    keys: held.keys
                ) { [.wait(milliseconds: waitMs)] }
            default:
                return injectionRefusal(
                    action: "hand",
                    error: "unknown gesture: \(gesture)",
                    status: 400
                )
            }

            if let rawHolding = body.stringValue("holding")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !rawHolding.isEmpty {
                // Pointer hold + held keys is one balanced coordinated gesture.
                // Only nesting a second KEY hold conflicts with the outer set.
                guard gesture != "hold_key" else {
                    return injectionRefusal(
                        action: "hand",
                        error: "holding cannot wrap another keyboard hold gesture",
                        status: 400
                    )
                }
                let held = try MacKeySyntax.parseHeldKeys(rawHolding)
                let inner = plan
                plan = try MacHandRepertoire.hold(modifiers: held.modifiers, keys: held.keys) { inner }
            }
        } catch {
            return injectionRefusal(action: "hand", error: "invalid gesture: \(error)", status: 400)
        }

        guard !plan.isEmpty, MacHandRepertoire.isBalanced(plan) else {
            return injectionRefusal(action: "hand", error: "gesture plan was empty or unbalanced", status: 400)
        }

        // A composed four-verb physical act may own both fresh observations.
        // In that lane this hand reports emission only, never verification;
        // all injection/attention/cancellation gates below remain unchanged.
        let defersVisualVerification = body["defer_visual_verification"] == .bool(true)
        // Capture evidence inside the same canonical operation. Browser scroll
        // and Page Down often change pixels while the accessibility document
        // remains structurally identical, so the fused image participates in
        // the comparison instead of relying on AX notifications alone.
        func visibleEvidence(_ result: MacControlResult) -> [String: JSONValue]? {
            guard result.ok, case .object(let output) = result.output else { return nil }
            return [
                "app": output["app"] ?? .null,
                "window_title": output["window_title"] ?? .null,
                "marks": output["marks"] ?? .null,
                "text": output["text"] ?? .null,
                "image": output["image"] ?? .null,
            ]
        }
        var heldKeys: [UInt16] = []
        var heldButtons: [MacMouseButton] = []
        var lastPoint = CGPoint.zero
        var emittedEvents = 0
        @discardableResult func recoverNeutral() -> Int {
            let released = heldKeys.count + heldButtons.count
            for key in heldKeys.reversed() {
                eventSink.post(key: MacKeyEvent(keyCode: key, down: false))
            }
            for button in heldButtons.reversed() {
                eventSink.post(mouse: MacMouseEvent(
                    phase: .up, button: button, x: lastPoint.x, y: lastPoint.y
                ))
            }
            heldKeys.removeAll()
            heldButtons.removeAll()
            return released
        }
        func interruptedResult() -> MacControlResult {
            let recoveryEvents = recoverNeutral()
            return MacControlResult(
                ok: false,
                action: "hand",
                output: .object([
                    "status": .string("interrupted"),
                    "gesture": .string(gesture),
                    "steps": .int(Int64(plan.count)),
                    "requested_events_emitted": .int(Int64(emittedEvents)),
                    "recovery_events_emitted": .int(Int64(recoveryEvents)),
                    "effects_may_have_occurred": .bool(emittedEvents > 0),
                    "verified": .bool(false),
                    "hand_neutral": .bool(heldKeys.isEmpty && heldButtons.isEmpty),
                    "guidance": .string("Cancellation stopped further input. Already emitted input was not undone; observe the current screen before any further action."),
                ]),
                error: "gesture_cancelled",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true,
                verification: .unverified
            )
        }
        if Task.isCancelled { return interruptedResult() }

        // A targeted wheel gesture first moves the pointer into the named
        // region. That hover can change pixels by itself; it is positioning,
        // not proof that the subsequent scroll moved anything. Establish the
        // evidence baseline only after that leading move so a hover highlight
        // can never turn an inert scroll into a verified one.
        var executionPlan = plan
        if gesture == "scroll", case .mouse(let event)? = executionPlan.first {
            if let refusal = await attentionActionRefusal(action: "hand", body: body) {
                return refusal
            }
            if Task.isCancelled { return interruptedResult() }
            lastPoint = CGPoint(x: event.x, y: event.y)
            eventSink.post(mouse: event)
            emittedEvents += 1
            executionPlan.removeFirst()
        }

        if Task.isCancelled { return interruptedResult() }

        let beforeView = defersVisualVerification ? nil : visibleEvidence(await handleView([
            "max_marks": .int(60),
            "max_text_items": .int(80),
        ]))

        for step in executionPlan {
            if Task.isCancelled { return interruptedResult() }
            if let refusal = await attentionActionRefusal(action: "hand", body: body) {
                recoverNeutral()
                return refusal
            }
            if Task.isCancelled { return interruptedResult() }
            switch step {
            case .key(let event):
                eventSink.post(key: event)
                emittedEvents += 1
                if event.down { heldKeys.append(event.keyCode) }
                else { heldKeys.removeAll { $0 == event.keyCode } }
            case .mouse(let event):
                lastPoint = CGPoint(x: event.x, y: event.y)
                eventSink.post(mouse: event)
                emittedEvents += 1
                if event.phase == .down { heldButtons.append(event.button) }
                else if event.phase == .up { heldButtons.removeAll { $0 == event.button } }
            case .scroll(let event):
                eventSink.post(scroll: event)
                emittedEvents += 1
            case .wait(let milliseconds):
                if milliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                }
            }
        }

        if Task.isCancelled { return interruptedResult() }

        let afterView = defersVisualVerification ? nil : visibleEvidence(await handleView([
            "max_marks": .int(60),
            "max_text_items": .int(80),
        ]))
        if Task.isCancelled { return interruptedResult() }
        let visibleChanged = beforeView != nil && afterView != nil && beforeView != afterView

        return MacControlResult(
            ok: true,
            action: "hand",
            output: .object([
                "status": .string(visibleChanged ? "emitted_observed" : "emitted_unobserved"),
                "gesture": .string(gesture),
                "steps": .int(Int64(plan.count)),
                "visible_changed": .bool(visibleChanged),
                "verified": .bool(visibleChanged),
                "visual_verification_deferred": .bool(defersVisualVerification),
                "drag_travel_ms": dragTravelMs.map { .int(Int64($0)) } ?? .null,
                "holding": body["holding"] ?? .null,
                "button": body["button"] ?? .null,
                "hand_neutral": .bool(heldKeys.isEmpty && heldButtons.isEmpty),
                "verification_evidence": visibleChanged
                    ? .string("fresh_fused_view_change")
                    : .null,
            ]),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    // MARK: nudge (W7)

    /// How far the cursor moves, in points. One point: enough for the window
    /// server to see a HID move event, small enough that it cannot drag
    /// anything anywhere even if a button were somehow already held down by a
    /// physical mouse.
    static let nudgeOffsetPoints: Double = 1

    /// `nudge` — post ONE bare mouse move. That is the entire tool.
    ///
    /// It exists for the smallest real problem in this organ: an idle Mac shows
    /// a screensaver or a slept display, and every perception tool then reports
    /// the saver instead of the screen. A human fixes that by bumping the
    /// mouse. This is that bump, and nothing else.
    ///
    /// THE STRUCTURAL GUARANTEE, and the only invariant this handler has: it
    /// emits `MacMouseEvent(phase: .move, …)` and NOTHING else. There is no
    /// `.down`, no `.up`, no `.drag`, no `post(key:)`, no `post(scroll:)` and
    /// no AX mutation anywhere on this path — a single call site, no body, no
    /// branch a caller can steer. `MacNudgeMoveOnlyTests` greps the events the
    /// sink actually received and fails on anything that is not a move.
    ///
    /// WHY IT NEEDS NO APPROVAL, when `mac_click` (which posts a move too) does:
    /// a bare move cannot click, cannot type, cannot activate whatever sits
    /// under the cursor, and cannot bypass a lock — on a locked screen the most
    /// it achieves is showing the login field, exactly like a human bumping the
    /// mouse, which is why it also needs no lock probe. It changes no app
    /// state, so there is nothing for a human to approve. It is NOT a bypass
    /// for `click` / `keystroke` / `ax_act` / `wake`: those keep their three
    /// gates in full, and `nudge` cannot do any part of what they do.
    ///
    /// It is still gated: the accessibility category plus an ACTIVE Full Mac
    /// window (`gatePreflightOutcome`), the macOS Accessibility TCC grant and a
    /// live event sink — the same floor `mac_ax_status` clears, plus the sink,
    /// because reporting "nudged" with the grant missing would be a lie: the
    /// window server silently swallows CGEventPost without it.
    func handleNudge(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()

        // The TCC grant and a working sink. Same check the injection handlers
        // run — a policy gate is not a system grant — reused rather than
        // copied so a future fix to it cannot miss this handler.
        if let refusal = injectionPreconditions(action: "nudge", requiresSink: true) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "nudge", body: body) {
            return refusal
        }

        // THE WHOLE FEATURE: one move event. The destination is the current
        // cursor position plus one point, so nothing about it depends on caller
        // input — `nudge` takes no parameters at all.
        let origin = Self.currentCursorPoint()
        eventSink.post(mouse: MacMouseEvent(
            phase: .move,
            button: .left,
            x: origin.x + Self.nudgeOffsetPoints,
            y: origin.y
        ))
        await screenViewStore.invalidate()

        return MacControlResult(
            ok: true,
            action: "nudge",
            output: .object([
                "nudged": .bool(true),
                "message": .string(
                    "Posted one bare mouse move (\(Int(Self.nudgeOffsetPoints)) point). This can wake a "
                        + "sleeping display or dismiss a screensaver. It clicks nothing, types nothing and "
                        + "unlocks nothing — on a locked Mac it only brings up the login field."
                ),
            ]),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// Current cursor location in the CGEvent coordinate space. Read straight
    /// from CoreGraphics rather than through `sessionStateSource`: this tool
    /// does not probe the login session, and where the cursor is is not session
    /// state. `(0, 0)` off-macOS / when the read fails — the move still posts,
    /// which is the honest outcome for a tool whose only job is to emit one.
    private static func currentCursorPoint() -> (x: Double, y: Double) {
        #if canImport(CoreGraphics) && os(macOS)
        if let location = CGEvent(source: nil)?.location {
            return (Double(location.x), Double(location.y))
        }
        #endif
        return (0, 0)
    }

    // MARK: wake (W6)

    /// The default settle wait between the nudge and the re-capture. The window
    /// server needs a beat to tear the saver down; capturing at zero would
    /// photograph the thing we just dismissed and report it as the screen.
    static let wakeDefaultSettleMs = 700
    static let wakeMaxSettleMs = 3000
    /// US virtual keycode for LEFT SHIFT (0x38). A modifier on its own inserts
    /// no character in any app, which is why it is the only key this tool will
    /// press. Kept here rather than in `MacKeySyntax` on purpose: it is not part
    /// of the chord grammar and must not become spellable by a model.
    static let wakeShiftKeyCode: UInt16 = 56

    /// `wake` — dismiss a screensaver / wake a sleeping display with
    /// the smallest possible HID nudge, then hand back the fresh fused view.
    ///
    /// THE SAFETY LINE, and the reason this is one tool rather than "call
    /// mac_click then mac_view": the session is probed BEFORE anything is posted,
    /// and an unreadable/off-console session returns a refusal with the sink
    /// untouched. It is probed AGAIN after the settle wait and before capture.
    /// The ambiguous CoreGraphics obstruction flag never blocks the inert
    /// nudge; it only prevents capture while the saver/login layer remains.
    ///
    /// The result is the `view` output SHAPE (flattened, not nested) plus a
    /// `wake` block. That is deliberate: every downstream sink that already
    /// knows how to strip a base64 `image` and read a redacted legend keys off
    /// the top level, so flattening inherits mac_view's redaction and image
    /// stripping wholesale instead of opening a second, un-covered channel.
    func handleWake(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()

        // 1. CAN WE EVEN SEE THE SESSION? An unreadable session is not an
        //    unlocked one.
        guard sessionStateSource.isAvailable else {
            return injectionRefusal(
                action: "wake",
                error: "session_state_unavailable: this build or this Mac would not report the "
                    + "login session, and an unreadable session is not an unlocked one, so it "
                    + "will not nudge blind",
                status: 503
            )
        }
        let before = sessionStateSource.currentState()

        // 2. THE REFUSAL. Nothing has been posted at this point and nothing
        //    will be: this returns before the sink is touched.
        if let reason = MacWakeGuard.nudgeRefusalReason(for: before) {
            return injectionRefusal(
                action: "wake",
                error: reason,
                status: 403,
                extra: ["session_before": before.toJSON()]
            )
        }

        // 3. The same TCC + sink preconditions every injection handler applies.
        //    Without the Accessibility grant CGEventPost is swallowed by the
        //    window server, and reporting "woken" would be a lie.
        if let refusal = injectionPreconditions(action: "wake", requiresSink: true) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "wake", body: body) {
            return refusal
        }

        // 4. THE NUDGE. A one-point mouse move and back is the smallest input
        //    that reaches the HID tap: it cannot type, cannot click, cannot
        //    activate anything under the cursor, and it leaves the pointer
        //    exactly where it was.
        // NEVER FABRICATE THE ORIGIN. `?? 0` used to mean "unreadable cursor ⇒
        // move the pointer to (0,0)" — the TOP-LEFT HOT CORNER, which is a
        // configurable trigger (Lock Screen, Mission Control, Quick Note). A
        // nudge is supposed to be the smallest inert input there is; teleporting
        // the pointer into a corner is neither small nor inert. An unreadable
        // cursor now REFUSES rather than guessing a coordinate, and the same
        // rule is what makes the relaxed nudge guard honest: the only thing we
        // ever post is a one-pixel move from where the pointer ALREADY is.
        guard let cursorX = before.cursorX, let cursorY = before.cursorY else {
            return injectionRefusal(
                action: "wake",
                error: "cursor_position_unreadable: this Mac would not report where the pointer "
                    + "is, and a nudge posted at a guessed origin could land in a hot corner "
                    + "instead of nowhere, so it refuses rather than move the pointer somewhere "
                    + "it was not",
                status: 503,
                extra: ["session_before": before.toJSON()]
            )
        }
        let origin = (cursorX, cursorY)
        var mouseEvents = 0
        for point in [(origin.0 + 1, origin.1), origin] {
            if let refusal = await attentionActionRefusal(action: "wake", body: body) {
                await screenViewStore.invalidate()
                return refusal
            }
            eventSink.post(mouse: MacMouseEvent(
                phase: .move,
                button: .left,
                x: point.0,
                y: point.1
            ))
            mouseEvents += 1
        }
        // ON BY DEFAULT (User, 2026-08-22; opt out with key_tap:false). Live
        // runs C3F445B2/B94F9DCF proved a bare one-pixel move resets the idle
        // clock and dismisses NOTHING — the saver layer wants a real gesture.
        // Left-shift alone types nothing in any app and cannot authenticate.
        var keyEvents = 0
        if body["key_tap"] != .bool(false) {
            for down in [true, false] {
                if let refusal = await attentionActionRefusal(action: "wake", body: body) {
                    await screenViewStore.invalidate()
                    return refusal
                }
                eventSink.post(key: MacKeyEvent(
                    keyCode: Self.wakeShiftKeyCode,
                    down: down,
                    modifiers: down ? .shift : []
                ))
                keyEvents += 1
            }
        }
        await screenViewStore.invalidate()

        // 5. Let the window server tear the saver down before we photograph it.
        let settleMs = max(0, min(
            Self.intValue(body, "settle_ms") ?? Self.wakeDefaultSettleMs,
            Self.wakeMaxSettleMs
        ))
        if settleMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)
        }

        // 6. RE-READ, then RE-GUARD, then re-capture. The verdict comes from what
        //    the session says afterwards — never from "I posted two events".
        let after = sessionStateSource.currentState()

        // THE SECOND HALF OF THE SAFETY LINE. The first guard proved the screen
        // was not locked BEFORE the nudge; a settle wait later that is a stale
        // fact. User can hit Ctrl-Cmd-Q, the idle timer can fire, or the display
        // can lock inside the window we just slept through — and the capture
        // below is a screenshot. So the same guard runs again on the fresh read,
        // and a screen that locked mid-call is neither photographed nor
        // described: no image, no marks, no legend, no view id.
        if let reason = MacWakeGuard.captureRefusalReason(for: after) {
            return injectionRefusal(
                action: "wake",
                error: reason,
                status: 403,
                extra: [
                    "session_before": before.toJSON(),
                    "session_after": after.toJSON(),
                    "wake": .object([
                        "nudged": .bool(true),
                        "mouse_events": .int(Int64(mouseEvents)),
                        "key_events": .int(Int64(keyEvents)),
                        "settle_ms": .int(Int64(settleMs)),
                        "was_obstructed": .bool(before.obstructed),
                        "dismissed": .bool(false),
                        "still_obstructed": .bool(true),
                        // THE POINTER CLAIM, MADE CHECKABLE (Agent F0D81308).
                        // The nudge posts (x+1, y) then (x, y), so restoration
                        // is true by construction — but "by construction" is an
                        // argument, not evidence, and she was right that the
                        // receipt could not prove it. These are the two READ
                        // positions; `pointer_restored` is their COMPARISON,
                        // not a restatement of intent, and it is null when
                        // either read failed rather than optimistically true.
                        "nudge_origin": .object([
                            "x": before.cursorX.map { .double(($0 * 10).rounded() / 10) } ?? .null,
                            "y": before.cursorY.map { .double(($0 * 10).rounded() / 10) } ?? .null,
                        ]),
                        "pointer_restored": Self.pointerRestoredJSON(before: before, after: after),
                        "note": .string(
                            "The nudge was delivered and the saver/login layer is still covering "
                                + "the screen, so nothing was photographed or read back. Retrying "
                                + "can help; a screen that never clears needs a human at the "
                                + "keyboard."
                        ),
                    ]),
                ]
            )
        }
        if let refusal = await attentionActionRefusal(action: "wake", body: body) {
            return refusal
        }

        let dismissed = !after.obstructed
        let view = await handleView(body)
        if let refusal = await attentionActionRefusal(action: "wake", body: body) {
            await screenViewStore.invalidate()
            return refusal
        }

        var output: [String: JSONValue]
        if case .object(let viewOutput) = view.output {
            output = viewOutput
        } else {
            output = [:]
        }
        // BUILT IN STEPS, not as one literal. Adding two more keys to the big
        // dictionary literal here tipped the Swift type checker past its budget
        // ("unable to type-check this expression in reasonable time") and hung
        // the build for ten minutes before it was killed. Incremental
        // construction is not a style choice; the literal form does not compile.
        var wake: [String: JSONValue] = [:]
        wake["nudged"] = .bool(true)
        wake["mouse_events"] = .int(Int64(mouseEvents))
        wake["key_events"] = .int(Int64(keyEvents))
        wake["settle_ms"] = .int(Int64(settleMs))
        wake["was_obstructed"] = .bool(before.obstructed)
        wake["dismissed"] = .bool(dismissed)
        // The pointer claim rides on EVERY wake receipt, not just refusals —
        // the nudge moves the mouse whether or not the screen clears, so "it
        // was put back" needs proving on the success path too.
        wake["nudge_origin"] = .object([
            "x": before.cursorX.map { JSONValue.double(($0 * 10).rounded() / 10) } ?? .null,
            "y": before.cursorY.map { JSONValue.double(($0 * 10).rounded() / 10) } ?? .null,
        ])
        wake["pointer_restored"] = Self.pointerRestoredJSON(before: before, after: after)
        wake["session_before"] = before.toJSON()
        wake["session_after"] = after.toJSON()
        let wakeTail: [String: JSONValue] = [
            // The orthogonal evidence that the nudge actually LANDED: a HID
            // post resets the system idle timer. Falling idle time across the
            // nudge is proof; a flat one means the events went nowhere (almost
            // always a missing Accessibility grant).
            "idle_reset": .bool({
                guard let b = before.idleSeconds, let a = after.idleSeconds else { return false }
                return a < b
            }()),
            "note": .string(
                dismissed
                    ? "The screen is awake and showing the real desktop — the view below is it."
                    : "The nudge (pointer move + shift tap) was posted but the screen still "
                        + "reports a sleeping display or the saver layer. Retry, or try a larger "
                        + "settle_ms."
            ),
        ]
        for (k, v) in wakeTail { wake[k] = v }
        output["wake"] = .object(wake)
        // `verified` is OBSERVED, not asserted: it is the post-nudge session
        // re-read, which is what `verificationState` picks up.
        output["verified"] = .bool(dismissed)
        return MacControlResult(
            ok: view.ok,
            action: "wake",
            output: .object(output),
            error: view.error,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }
}

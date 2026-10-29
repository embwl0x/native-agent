import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CoreGraphics)
import CoreGraphics
// Blueprint: | `MacControl+HandAndWake.swift` | `SwiftNativeMacControl`: `waitForTextInput`, `handleHand`, `watchedWindowMiss` (a watch's events land on its window, read at each event), `handleNudge`; text input verifies focus, selection and value with cancellable 25ms polling bounded to 750ms; hand text mismatch excerpts are always redacted because its readback lacks canonical caption/group redaction context |
#endif

extension SwiftNativeMacControl {
    /// Wait for the focused editor, not merely AXFocused on its outer control.
    /// Also serves as the acknowledgement for select-all and text delivery.
    func waitForTextInput(
        pid: Int32, target: MacAXActTarget? = nil, clickPoint: CGPoint? = nil,
        selectedAll: Bool = false, value: String? = nil,
        changedFrom before: MacAXTextInput? = nil
    ) async -> MacAXTextInput? {
        func containsClick(_ element: MacAXActTarget, point: CGPoint) -> Bool {
            guard let frame = element.frame, frame.w > 0, frame.h > 0 else { return false }
            return CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h).contains(point)
        }
        func matchesClick(_ focused: MacAXActTarget) -> Bool {
            guard let clickPoint, let target else { return true }
            if MacActClosedLoop.canType(role: target.role)
                || ["AXStaticText", "AXText"].contains(target.role) { return true }
            // A compact control can own an editor; a broad container cannot
            // vouch for focus elsewhere inside it merely through ancestry.
            if ["AXButton", "AXPopUpButton", "AXMenuButton"].contains(target.role),
               let frame = target.frame, frame.w <= 320, frame.h <= 80,
               containsClick(target, point: clickPoint) { return true }
            return containsClick(focused, point: clickPoint)
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        repeat {
            guard !Task.isCancelled,
                  accessibilitySource.frontmostApp()?.processIdentifier == pid else { return nil }
            if let focused = accessibilityActSource.focusedElement(pid: pid),
               target.map({ accessibilityActSource.matchesTextInputTarget(focused, target: $0) }) ?? true,
               matchesClick(focused),
               let input = accessibilityActSource.textInput(focused),
               !selectedAll || input.selection == NSRange(location: 0, length: input.value.utf16.count),
               value == nil || input.value == value,
               before.map({ input.value != $0.value || input.selection != $0.selection }) ?? true {
                return input
            }
            if ContinuousClock.now >= deadline { break }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return nil }
        } while true
        return nil
    }

    // MARK: act — closed loop

    /// The physical tier behind the model-facing `act`. The caller already
    /// resolved a fresh named/ordinal target; this owner validates a bounded
    /// gesture, plans it through `MacHandRepertoire`, and posts the balanced
    /// sequence through the same gated event sink as click/keystroke/scroll.
    func handleHand(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        if let refusal = injectionPreconditions(action: "hand", requiresSink: true) { return refusal }
        if let refusal = await attentionActionRefusal(action: "hand", body: body) { return refusal }
        guard let gesture = body["gesture"]?.stringValue?.lowercased(), !gesture.isEmpty else {
            return injectionRefusal(action: "hand", error: "missing required field: gesture", status: 400)
        }
        let button: MacMouseButton
        if body["button"] != nil {
            guard let raw = body["button"]?.stringValue?.lowercased(),
                  let parsed = MacMouseButton(rawValue: raw),
                  ["click", "double_click", "hold", "drag"].contains(gesture) else {
                return injectionRefusal(action: "hand", error: "invalid mouse button for gesture", status: 400)
            }
            button = parsed
        } else {
            button = .left
        }

        func point(_ xKey: String = "x", _ yKey: String = "y") -> CGPoint? {
            guard let x = body[xKey]?.numberValue(coercingStrings: false, finiteOnly: true), let y = body[yKey]?.numberValue(coercingStrings: false, finiteOnly: true),
                  x.isFinite, y.isFinite, abs(x) <= 100_000, abs(y) <= 100_000 else { return nil }
            return CGPoint(x: x, y: y)
        }
        let waitMs = Self.handWaitMilliseconds(seconds: body["seconds"]?.numberValue(coercingStrings: false, finiteOnly: true))
        var dragTravelMs: Int?
        var plan: [MacHandStep]
        do {
            switch gesture {
            case "click", "double_click", "click_type":
                guard let at = point() else {
                    return injectionRefusal(action: "hand", error: "gesture needs finite x/y", status: 400)
                }
                let count = gesture == "double_click" ? 2 : 1
                var steps = MacHandRepertoire.click(button: button, at: at, count: count)
                if gesture == "click_type" {
                    guard let text = body["text"]?.stringValue, !text.isEmpty else {
                        return injectionRefusal(action: "hand", error: "click_type needs text", status: 400)
                    }
                    _ = try MacKeySyntax.validateText(text)
                    steps += MacHandRepertoire.type(text: text)
                }
                plan = steps
            case "type":
                // Keystrokes to whatever has focus, as a person types: no click first.
                guard let text = body["text"]?.stringValue, !text.isEmpty else {
                    return injectionRefusal(action: "hand", error: "type needs text", status: 400)
                }
                _ = try MacKeySyntax.validateText(text)
                plan = MacHandRepertoire.type(text: text)
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
                plan = MacHandRepertoire.pressAndHold(button: button, at: at, holdMs: waitMs)
            case "drag":
                guard let start = point(), let end = point("to_x", "to_y") else {
                    return injectionRefusal(action: "hand", error: "drag needs finite x/y and to_x/to_y", status: 400)
                }
                // Named drags use travel_seconds; low-level seconds remains endpoint dwell.
                if body["travel_seconds"] != nil {
                    dragTravelMs = Self.handDragMilliseconds(seconds: body["travel_seconds"]?.numberValue(coercingStrings: false, finiteOnly: true))
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
                let dy = max(-120, min(body["dy"]?.integerValue.flatMap(Int.init(exactly:)) ?? -6, 120))
                let dx = max(-120, min(body["dx"]?.integerValue.flatMap(Int.init(exactly:)) ?? 0, 120))
                plan = MacHandRepertoire.move(to: at)
                    + MacHandRepertoire.scroll(dx: Int32(dx), dy: Int32(dy), unit: .line)
            case "key":
                guard let keys = body["keys"]?.stringValue else {
                    return injectionRefusal(action: "hand", error: "key needs keys", status: 400)
                }
                plan = try MacKeySyntax.parseChords(keys).flatMap(MacHandRepertoire.chord)
            case "hold_key", "key_down", "key_up":
                guard let keys = body["keys"]?.stringValue else {
                    return injectionRefusal(action: "hand", error: "\(gesture) needs a held key set", status: 400)
                }
                let held = try MacKeySyntax.parseHeldKeys(keys)
                plan = MacHandRepertoire.hold(
                    modifiers: held.modifiers,
                    keys: held.keys,
                    whileDoing: gesture == "hold_key" ? [.wait(.milliseconds(waitMs))] : []
                )
                // Half a hold: only a watch's binding keeps the key down past this call.
                if gesture != "hold_key" {
                    guard MacDriverContext.holdsAcrossCalls else {
                        return injectionRefusal(action: "hand", error: "\(gesture) holds a key across calls only inside a watch", status: 400)
                    }
                    plan = plan.filter { $0.keyEvent?.down == (gesture == "key_down") }
                }
            default:
                return injectionRefusal(
                    action: "hand",
                    error: "unknown gesture: \(gesture)",
                    status: 400
                )
            }

            if let rawHolding = body["holding"]?.stringValue?
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
                plan = MacHandRepertoire.hold(modifiers: held.modifiers, keys: held.keys, whileDoing: plan)
            }
        } catch {
            return injectionRefusal(action: "hand", error: "invalid gesture: \(error)", status: 400)
        }

        guard !plan.isEmpty, MacHandRepertoire.isBalanced(plan) || ["key_down", "key_up"].contains(gesture) else {
            return injectionRefusal(action: "hand", error: "gesture plan was empty or unbalanced", status: 400)
        }
        if plan.contains(where: { $0.keyEvent != nil }),
           let refusal = MacActClosedLoop.secureInputRefusal(active: eventSink.secureKeyboardEntryActive) {
            return injectionRefusal(
                action: "hand",
                error: refusal.reason,
                extra: ["note": .string(refusal.note), "key_events": .int(0)]
            )
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
        var emittedEvents = 0
        func handback(_ execution: (emitted: Int, recovery: Int, refusal: MacControlResult?)) -> MacControlResult? {
            emittedEvents += execution.emitted
            guard let refusal = execution.refusal else { return nil }
            var output: [String: JSONValue] = [:]
            if case .object(let existing) = refusal.output { output = existing }
            output["gesture"] = .string(gesture)
            output["steps"] = .int(Int64(plan.count))
            output["requested_events_emitted"] = .int(Int64(emittedEvents))
            output["recovery_events_emitted"] = .int(Int64(execution.recovery))
            output["effects_may_have_occurred"] = .bool(emittedEvents > 0)
            return MacControlResult(ok: false, action: "hand", output: .object(output),
                                    error: refusal.error, durationMs: Int(now().timeIntervalSince(started) * 1000),
                                    httpStatus: 409, verification: .unverified)
        }
        // A targeted wheel gesture first moves the pointer into the named
        // region. That hover can change pixels by itself; it is positioning,
        // not proof that the subsequent scroll moved anything. Establish the
        // evidence baseline only after that leading move so a hover highlight
        // can never turn an inert scroll into a verified one.
        var executionPlan = plan
        if gesture == "scroll", let step = executionPlan.first, case .mouse = step {
            if let refusal = handback(await executeHand([step], action: "hand", body: body)) { return refusal }
            executionPlan.removeFirst()
        }

        let beforeView = defersVisualVerification ? nil : visibleEvidence(await handleView([
            "max_marks": .int(60),
            "max_text_items": .int(80),
        ]))

        // A front:true act: every event is posted only while that app is in
        // front — User switching mid-act stops the hand before it reaches his app.
        let requiredFront = body["require_front_pid"]?.integerValue.flatMap(Int.init(exactly:)).map { Int32(clamping: $0) }
        let surfacePid = ["click", "double_click", "key"].contains(gesture)
            ? requiredFront ?? accessibilitySource.frontmostApp()?.processIdentifier : nil
        let surfaceWindowBefore = surfacePid.flatMap { accessibilityActSource.focusedWindow(pid: $0) }
        // A watch's hand: every event lands on that exact window, read at the event.
        let requiredWindow = body["require_front_window"]?.integerValue.flatMap(Int.init(exactly:))
        let chords = gesture == "key" ? body["keys"]?.stringValue.flatMap { try? MacKeySyntax.parseChords($0) } : nil
        let selectsAll = chords?.count == 1 && chords?.first?.keyCode == 0x00 && chords?.first?.modifiers == .command
        let selectionTarget = selectsAll ? accessibilitySource.frontmostApp().flatMap {
            accessibilityActSource.focusedElement(pid: $0.processIdentifier)
        } : nil
        // Every point is checked before the first event too, so a drag that
        // would end on another window never presses the button.
        if let requiredFront, let requiredWindow, let missed = executionPlan.lazy.compactMap({ step -> String? in
            guard case .mouse = step else { return nil }
            return self.watchedWindowMiss(step, window: requiredWindow, pid: requiredFront)
        }).first {
            return injectionRefusal(action: "hand", error: missed, extra: ["requested_events_emitted": .int(0)])
        }
        var textInput: MacAXTextInput?
        var checkedTextInput = false
        var clickTarget: (pid: Int32, element: MacAXActTarget, point: CGPoint)?
        let execution = await executeHand(executionPlan, action: "hand", body: body) { step in
            let posts: Bool = if case .wait = step { false } else { true }
            if let requiredFront, posts, accessibilitySource.frontmostApp()?.processIdentifier != requiredFront {
                return injectionRefusal(action: "hand", error: "front_changed", extra: [
                    "requested_events_emitted": .int(Int64(emittedEvents)),
                    "effects_may_have_occurred": .bool(emittedEvents > 0),
                ])
            }
            if let requiredFront, let requiredWindow, posts,
               let missed = watchedWindowMiss(step, window: requiredWindow, pid: requiredFront) {
                return injectionRefusal(action: "hand", error: missed, extra: [
                    "requested_events_emitted": .int(Int64(emittedEvents)),
                    "effects_may_have_occurred": .bool(emittedEvents > 0),
                ])
            }
            if Task.isCancelled { return injectionRefusal(action: "hand", error: "gesture_cancelled") }
            switch step {
            case .key(let event):
                if event.unicodeText != nil, !checkedTextInput {
                    checkedTextInput = true
                    guard let pid = requiredFront ?? accessibilitySource.frontmostApp()?.processIdentifier else {
                        return injectionRefusal(action: "hand", error: "front_unknown")
                    }
                    // Bind click typing to the hit-tested target, even if it
                    // already had focus. Unrelated ready editors cannot pass.
                    if gesture == "click_type", clickTarget?.pid != pid {
                        return injectionRefusal(action: "hand", error: "front_changed")
                    }
                    let editorBefore = gesture == "click_type" ? clickTarget?.element
                        : accessibilityActSource.focusedElement(pid: pid).flatMap {
                            MacActClosedLoop.canType(role: $0.role) ? $0 : nil
                        }
                    textInput = await waitForTextInput(
                        pid: pid, target: editorBefore, clickPoint: clickTarget?.point
                    )
                    guard textInput != nil else {
                        return injectionRefusal(action: "hand", error: "text_editor_not_ready", extra: [
                            "requested_events_emitted": .int(Int64(emittedEvents)),
                            "text_events_emitted": .int(0),
                        ])
                    }
                    if Task.isCancelled { return injectionRefusal(action: "hand", error: "gesture_cancelled") }
                    if let refusal = await attentionActionRefusal(action: "hand", body: body) {
                        return refusal
                    }
                    guard accessibilitySource.frontmostApp()?.processIdentifier == pid else {
                        return injectionRefusal(action: "hand", error: "front_changed")
                    }
                }
                if let input = textInput, event.down,
                   let pid = requiredFront ?? accessibilitySource.frontmostApp()?.processIdentifier,
                   !accessibilityActSource.isFocusedElement(input.target, pid: pid) {
                    return injectionRefusal(action: "hand", error: "focus_moved", extra: [
                        "requested_events_emitted": .int(Int64(emittedEvents)),
                    ])
                }
            case .mouse(let event):
                if gesture == "click_type", event.phase == .down {
                    guard let pid = requiredFront ?? accessibilitySource.frontmostApp()?.processIdentifier else {
                        return injectionRefusal(action: "hand", error: "front_unknown")
                    }
                    guard let target = accessibilityActSource.elementAtPosition(x: event.x, y: event.y, pid: pid) else {
                        return injectionRefusal(action: "hand", error: "text_editor_not_ready", extra: [
                            "requested_events_emitted": .int(Int64(emittedEvents)),
                            "text_events_emitted": .int(0),
                        ])
                    }
                    clickTarget = (pid, target, CGPoint(x: event.x, y: event.y))
                }
            default: break
            }
            return nil
        }
        if let refusal = handback(execution) { return refusal }

        if let input = textInput, let text = body["text"]?.stringValue,
           let pid = requiredFront ?? accessibilitySource.frontmostApp()?.processIdentifier {
            // Existing bounded acknowledgement, followed by the complete read
            // the declared-effect judge consumes.
            _ = await waitForTextInput(
                pid: pid, target: input.target, value: input.inserting(text), changedFrom: input
            )
        }
        let afterView = defersVisualVerification ? nil : visibleEvidence(await handleView([
            "max_marks": .int(60),
            "max_text_items": .int(80),
        ]))
        if Task.isCancelled {
            if let refusal = handback(await executeHand([], action: "hand", body: body)) { return refusal }
        }
        let visibleChanged = beforeView != nil && afterView != nil && beforeView != afterView
        let declaration: MacActClosedLoop.DeclaredEffect = selectsAll ? .selectAll : checkedTextInput ? .text(textInput.flatMap { input in
            body["text"]?.stringValue.map { input.inserting($0) }
        }) : .surface(nil)
        // Compare complete values; excerpts lack caption/group context and stay redacted.
        let verdict = MacActClosedLoop.verify(declaration,
            value: (selectionTarget ?? textInput?.target).flatMap { accessibilityActSource.reread($0)?.value },
            selection: selectionTarget.flatMap { accessibilityActSource.textInput($0)?.selection },
            dismissed: surfaceWindowBefore.flatMap { accessibilityActSource.windowPresence($0) }.map { !$0 },
            processGone: surfacePid.map { accessibilitySource.appInfo(pid: $0) == nil } ?? false, redactingText: true)

        return MacControlResult(
            ok: true,
            action: "hand",
            output: .object([
                "status": .string(visibleChanged ? "emitted_observed" : "emitted_unobserved"),
                "gesture": .string(gesture),
                "steps": .int(Int64(plan.count)),
                "requested_events_emitted": .int(Int64(emittedEvents)),
                "visible_changed": .bool(visibleChanged),
                "text_value_verified": checkedTextInput ? .bool(verdict.status == "acted") : .null,
                "visual_verification_deferred": .bool(defersVisualVerification),
                "drag_travel_ms": dragTravelMs.map { .int(Int64($0)) } ?? .null,
                "holding": body["holding"] ?? .null,
                "button": body["button"] ?? .null,
                "hand_neutral": .bool(MacHandRepertoire.isBalanced(plan)),
            ].merging(verdict.receipt) { _, new in new }),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }

    /// One physical executor. Callers admit targets and judge effects; raw input needs no readable editor.
    func executeHand(
        _ plan: [MacHandStep], action: String, body: [String: JSONValue] = [:], toPid: Int32? = nil,
        prepare: (inout MacHandStep) async -> MacControlResult? = { _ in nil }
    ) async -> (emitted: Int, recovery: Int, refusal: MacControlResult?) {
        var heldKeys: [UInt16] = []
        var heldButtons: [MacMouseButton] = []
        var emitted = 0
        func stopped(_ refusal: MacControlResult) -> (Int, Int, MacControlResult?) {
            let released = heldKeys.count + heldButtons.count
            MacDriverContext.binding?.releaseHeldInputs()
            return (emitted, released, refusal)
        }
        func cancelled() -> MacControlResult {
            injectionRefusal(action: action, error: action == "hand" ? "gesture_cancelled" : "cancelled", extra: [
                "status": .string(action == "hand" ? "interrupted" : "cancelled"),
                "verified": .bool(false), "hand_neutral": .bool(true),
                "guidance": .string("Cancellation stopped further input. Already emitted input was not undone; observe the current screen before any further action."),
            ])
        }
        for var step in plan {
            if Task.isCancelled { return stopped(cancelled()) }
            if let refusal = await attentionActionRefusal(action: action, body: body) { return stopped(refusal) }
            if let refusal = await prepare(&step) { return stopped(refusal) }
            if Task.isCancelled { return stopped(cancelled()) }
            switch step {
            case .key(let event):
                if let toPid {
                    guard eventSink.post(key: event, toPid: toPid) else {
                        return stopped(injectionRefusal(action: action, error: "needs_front"))
                    }
                } else { eventSink.post(key: event) }
                emitted += 1
                if event.down { heldKeys.append(event.keyCode) }
                else { heldKeys.removeAll { $0 == event.keyCode } }
            case .mouse(let event):
                eventSink.post(mouse: event)
                emitted += 1
                if event.phase == .down { heldButtons.append(event.button) }
                else if event.phase == .up { heldButtons.removeAll { $0 == event.button } }
            case .scroll(let event):
                eventSink.post(scroll: event)
                emitted += 1
            case .wait(let duration):
                guard duration > .zero else { continue }
                let binding = MacDriverContext.binding
                let store = attentionStore
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await Task.sleep(for: duration) }
                        group.addTask {
                            for await _ in await store.driverChanges() {
                                if binding?.allowsAction != true { return }
                            }
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                } catch { return stopped(cancelled()) }
                if let refusal = await attentionActionRefusal(action: action, body: body) { return stopped(refusal) }
            }
        }
        return Task.isCancelled ? stopped(cancelled()) : (emitted, 0, nil)
    }

    /// Whether a watch's event would miss its window, read at the event: a
    /// pointer event must land on it (the topmost window at that point), a key
    /// down must go to it (its app's focused window, matched by its live frame).
    func watchedWindowMiss(_ step: MacHandStep, window number: Int, pid: Int32) -> String? {
        let windows = SystemMacVisualObstructionProbe.windows()
        switch step {
        case .mouse(let event):
            let hit = SystemMacVisualObstructionProbe.topmost(in: windows, x: event.x, y: event.y)
            guard hit?.number != number else { return nil }
            return "covered: " + (hit.map { "\($0.ownerName)'s window \($0.number)" } ?? "no window") + " is at that point, not the watched one"
        case .key(let event) where event.down:
            // The focused window is the app's one live window at that frame; two
            // at the same frame cannot be told apart, so that refuses too.
            let focused = accessibilityActSource.focusedWindow(pid: pid)?.identity.frame
            let matches = focused.map { focused in windows.filter { window in
                window.ownerPID == pid && window.layer == 0
                    && abs(focused.x - window.frame.x) <= 2 && abs(focused.y - window.frame.y) <= 2
                    && abs(focused.w - window.frame.w) <= 2 && abs(focused.h - window.frame.h) <= 2
            } } ?? []
            guard matches.count == 1, matches[0].number == number else {
                return "front_changed: another window has the keyboard focus, not the watched one"
            }
            return nil
        // A key-up types nothing anywhere and releases what the watch holds.
        case .key, .scroll, .wait: return nil
        }
    }

    // MARK: nudge

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
    /// Emits only a pointer move: no click, typing, scroll, AX mutation or lock bypass.
    /// Ordinary policy, Full Mac, category, driver, Accessibility grant and sink gates apply.
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

        // Read only the cursor, without probing login-session state.
        guard let origin = pointerPositionSource.currentPosition() else {
            return injectionRefusal(action: "nudge", error: "cursor_unreadable: no pointer move was posted", status: 503)
        }
        let emission = await executeHand([.mouse(MacMouseEvent(
            phase: .move,
            button: .left,
            x: origin.x + Self.nudgeOffsetPoints,
            y: origin.y
        ))], action: "nudge", body: body)
        if let refusal = emission.refusal { return refusal }
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
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }
}

import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CoreGraphics)
import CoreGraphics
// Blueprint: | `MacControl+HandAndWake.swift` | `SwiftNativeMacControl`: Event-judged editor focus and input; per-event image/window guards |
#endif

extension SwiftNativeMacControl {
    /// A caret/editor is enough to send text; AX readback is separate proof. Unknown focus and noneditable controls never admit literal keystrokes.
    func waitForTextFocus(pid: Int32, target: MacAXActTarget?, clickPoint: CGPoint?, signals: MacWaitSignals,
                          context: MacOperationContext) async -> MacAXActTarget? {
        var editor: MacAXActTarget?
        let end = await macSettle("text_focus", signals: signals, patience: 0.75) {
            guard !Task.isCancelled,
                  accessibilitySource(context: context).frontmostApp()?.processIdentifier == pid else { return false }
            if let focused = accessibilityActSource(context: context).focusedElement(pid: pid, context: context),
               accessibilityActSource(context: context).acceptsTextInput(focused, context: context) {
                let related = target.map { accessibilityActSource(context: context).matchesTextInputTarget(focused, target: $0, context: context) } ?? (
                    clickPoint == nil)
                let containsPoint = clickPoint.map { point in
                    focused.frame.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h).contains(point) } ?? false
                } ?? true
                let compactEditorOwner = target.map { hit in
                    if MacActClosedLoop.canType(role: hit.role) || ["AXStaticText", "AXText"].contains(hit.role) { return true }
                    guard ["AXButton", "AXPopUpButton", "AXMenuButton"].contains(hit.role),
                          let frame = hit.frame, frame.w <= 320, frame.h <= 80, let point = clickPoint else { return false }
                    return CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h).contains(point)
                } ?? false
                // Hit-testing a canvas can return only its broad container. A broad container requires the focused editor to contain the point; only compact
                // editor owners can vouch by ancestry.
                if clickPoint == nil ? related : containsPoint || (related && compactEditorOwner) {
                    editor = focused
                    return true
                }
            }
            return false
        }
        return end == .held ? editor : nil
    }
    /// Wait for the focused editor, not merely AXFocused on its outer control. Also serves as the acknowledgement for select-all and text delivery.
    func waitForTextInput(
        pid: Int32, target: MacAXActTarget? = nil, clickPoint: CGPoint? = nil,
        selectedAll: Bool = false, value: String? = nil,
        changedFrom before: MacAXTextInput? = nil,
        signals: MacWaitSignals, context: MacOperationContext
    ) async -> MacAXTextInput? {
        func containsClick(_ element: MacAXActTarget, point: CGPoint) -> Bool {
            guard let frame = element.frame, frame.w > 0, frame.h > 0 else { return false }
            return CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h).contains(point)
        }
        func matchesClick(_ focused: MacAXActTarget) -> Bool {
            guard let clickPoint, let target else { return true }
            if MacActClosedLoop.canType(role: target.role)
                || ["AXStaticText", "AXText"].contains(target.role) { return true }
            // A compact control can own an editor; a broad container cannot vouch for focus elsewhere inside it merely through ancestry.
            if ["AXButton", "AXPopUpButton", "AXMenuButton"].contains(target.role),
               let frame = target.frame, frame.w <= 320, frame.h <= 80,
               containsClick(target, point: clickPoint) { return true }
            return containsClick(focused, point: clickPoint)
        }
        var observed: MacAXTextInput?
        let end = await macSettle("text_input", signals: signals, patience: 0.75) {
            guard !Task.isCancelled,
                  accessibilitySource(context: context).frontmostApp()?.processIdentifier == pid else { return false }
            if let focused = accessibilityActSource(context: context).focusedElement(pid: pid, context: context),
               target.map({ accessibilityActSource(context: context).matchesTextInputTarget(focused, target: $0, context: context) }) ?? true,
               matchesClick(focused),
               let input = accessibilityActSource(context: context).textInput(focused, context: context),
               !selectedAll || input.selection == NSRange(location: 0, length: input.value.utf16.count),
               value == nil || input.value == value,
               before.map({ input.value != $0.value || input.selection != $0.selection }) ?? true {
                observed = input
                return true
            }
            return false
        }
        return end == .held ? observed : nil
    }

    // MARK: act — closed loop

    /// Plan physical gestures through the shared hand repertoire and gated sink so semantic and physical acts retain the same injection boundary.
    func handleHand(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult {
        let started = now()
        if let refusal = injectionPreconditions(action: "hand", requiresSink: true, context: context) { return refusal }
        if let refusal = await attentionActionRefusal(action: "hand", body: body, turn: turn, context: context) { return refusal }
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
            guard let x = body[xKey]?.numberValue(coercingStrings: false, finiteOnly: true), let y = body[yKey]?.numberValue(coercingStrings: false,
                finiteOnly: true),
                  x.isFinite, y.isFinite, abs(x) <= 100_000, abs(y) <= 100_000 else { return nil }
            return CGPoint(x: x, y: y)
        }
        let waitMs: Int
        let suppliedTravelMs: Int?
        do {
            waitMs = try Self.handDurationMilliseconds(body["seconds"], field: "seconds", defaultMilliseconds: 600, range: 0...10)
            suppliedTravelMs = body["travel_seconds"] == nil ? nil : try Self.handDurationMilliseconds(
                body["travel_seconds"], field: "travel_seconds", defaultMilliseconds: 240, range: 0.08...2)
        } catch { return injectionRefusal(action: "hand", error: error.localizedDescription, status: 400) }
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
                // Direct keystrokes use existing focus; a click would be an additional effect.
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
                // Named drags use travel_seconds; endpoint dwell is a separate timing contract.
                if body["travel_seconds"] != nil {
                    dragTravelMs = suppliedTravelMs
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
                // Only a watch binding can retain a held key beyond this call.
                if gesture != "hold_key" {
                    guard context.holdsAcrossCalls else {
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
                // Pointer hold + held keys is one balanced coordinated gesture. Only nesting a second KEY hold conflicts with the outer set.
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

        // When the composed act owns both observations, this hand reports emission only; its caller owns verification and all injection gates still apply.
        let defersVisualVerification = body["defer_visual_verification"] == .bool(true)
        // Capture evidence inside the same canonical operation. Browser scroll and Page Down often change pixels while the accessibility document remains
        // structurally identical, so the fused image participates in the comparison instead of relying on AX notifications alone.
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
        // Establish scroll evidence after the positioning move so a hover highlight cannot verify an inert wheel gesture.
        var executionPlan = plan
        if gesture == "scroll", let step = executionPlan.first, case .mouse = step {
            if let refusal = handback(await executeHand([step], action: "hand", body: body, turn: turn, context: context)) { return refusal }
            executionPlan.removeFirst()
        }

        let beforeView = defersVisualVerification ? nil : visibleEvidence(await handleView([
            "max_marks": .int(60),
            "max_text_items": .int(80),
        ], context: context))

        // Recheck the foreground PID per event so a person switching apps mid-act cannot receive agent input in the new app.
        let requiredFront = body["require_front_pid"]?.integerValue.flatMap(Int.init(exactly:)).map { Int32(clamping: $0) }
        let surfacePid = ["click", "double_click", "key"].contains(gesture)
            ? requiredFront ?? accessibilitySource(context: context).frontmostApp()?.processIdentifier : nil
        let surfaceWindowBefore = surfacePid.flatMap { accessibilityActSource(context: context).focusedWindow(pid: $0, context: context) }
        // A watch's hand: every event lands on that exact window, read at the event.
        let requiredWindow = body["require_front_window"]?.integerValue.flatMap(Int.init(exactly:))
        let requiredIdentity: MacAXWindowIdentity?
        if let frameID = body["require_frame_id"]?.stringValue {
            guard let identity = await lookFrameStore.frame(frameId: frameID, context: context)?.windowIdentity,
                  identity.pid == requiredFront else {
                return injectionRefusal(action: "hand", error: "stale_frame",
                    extra: ["requested_events_emitted": .int(0)])
            }
            requiredIdentity = identity
        } else { requiredIdentity = nil }
        let chords = gesture == "key" ? body["keys"]?.stringValue.flatMap { try? MacKeySyntax.parseChords($0) } : nil
        let selectsAll = chords?.count == 1 && chords?.first?.keyCode == 0x00 && chords?.first?.modifiers == .command
        let selectionTarget = selectsAll ? accessibilitySource(context: context).frontmostApp().flatMap {
            accessibilityActSource(context: context).focusedElement(pid: $0.processIdentifier, context: context)
        } : nil
        // Every point is checked before the first event too, so a drag that would end on another window never presses the button.
        if let requiredFront, let requiredWindow, let missed = executionPlan.lazy.compactMap({ step -> String? in
            guard case .mouse = step else { return nil }
            return self.watchedWindowMiss(step, window: requiredWindow, pid: requiredFront, context: context)
        }).first {
            return injectionRefusal(action: "hand", error: missed, extra: ["requested_events_emitted": .int(0)])
        }
        var textInput: MacAXTextInput?
        var textFocus: MacAXActTarget?
        var checkedTextInput = false
        var clickTarget: (pid: Int32, element: MacAXActTarget?, point: CGPoint)?
        // Freeze the session's selected image once. Never rebind an implicit point to a newer image while this gesture is suspended.
        let imageCapture: MacImageCapture?
        if let imageID = body["image_frame"]?.stringValue {
            guard let capture = MacImageFrames.frame(imageID, turn: turn)?.geometry.capture else {
                return injectionRefusal(action: "hand", error: MacLookFrameStore.ResolveFailure.staleFrame.rawValue,
                    extra: ["requested_events_emitted": .int(0),
                            "guidance": .string("That image has no capture identity. Look again with pixels:true before pointing.")])
            }
            imageCapture = capture
        } else { imageCapture = nil }
        // Check press and release positions; a drag's intervening path can cross unnamed background the capture never described.
        func imageMiss(_ step: MacHandStep) -> MacControlResult? {
            guard let imageCapture, case .mouse(let event) = step, event.phase == .down || event.phase == .up else { return nil }
            guard let point = MacPointerPosition(x: event.x, y: event.y) else {
                return injectionRefusal(action: "hand", error: MacLookFrameStore.ResolveFailure.staleFrame.rawValue,
                    extra: ["requested_events_emitted": .int(Int64(emittedEvents)),
                            "effects_may_have_occurred": .bool(emittedEvents > 0),
                            "guidance": .string("The image point is not finite; look again with pixels:true.")])
            }
            guard let failure = imageCapture.refusal(at: point, now: now(), context: context) else { return nil }
            return injectionRefusal(action: "hand", error: failure.code, extra: [
                "requested_events_emitted": .int(Int64(emittedEvents)),
                "effects_may_have_occurred": .bool(emittedEvents > 0),
                "guidance": .string(failure.reason),
            ])
        }
        // Preflight the whole drag before any mouse or modifier goes out.
        for step in executionPlan {
            if let refusal = imageMiss(step) { return refusal }
        }
        let textSignals = ["type", "click_type"].contains(gesture)
            ? MacWaitSignals(effects: effectObserverSource, activation: defaultMacAppActivationObserverSource(),
                pid: requiredFront ?? accessibilitySource(context: context).frontmostApp()?.processIdentifier) : nil
        defer { textSignals?.stop() }
        let execution = await executeHand(executionPlan, action: "hand", body: body, turn: turn, context: context) { step in
            let posts: Bool = if case .wait = step { false } else { true }
            if let requiredIdentity, posts {
                guard let focused = accessibilityActSource(context: context).focusedWindow(pid: requiredIdentity.pid, context: context),
                      case .matched = MacAXWindowIdentity.match(requiredIdentity, among: [(focused, focused.identity)]) else {
                    return injectionRefusal(action: "hand", error: "front_window_changed", extra: [
                        "requested_events_emitted": .int(Int64(emittedEvents)),
                        "effects_may_have_occurred": .bool(emittedEvents > 0)])
                }
            }
            if let requiredFront, posts, accessibilitySource(context: context).frontmostApp()?.processIdentifier != requiredFront {
                return injectionRefusal(action: "hand", error: "front_changed", extra: [
                    "requested_events_emitted": .int(Int64(emittedEvents)),
                    "effects_may_have_occurred": .bool(emittedEvents > 0),
                ])
            }
            if let requiredFront, let requiredWindow, posts,
               let missed = watchedWindowMiss(step, window: requiredWindow, pid: requiredFront, context: context) {
                return injectionRefusal(action: "hand", error: missed, extra: [
                    "requested_events_emitted": .int(Int64(emittedEvents)),
                    "effects_may_have_occurred": .bool(emittedEvents > 0),
                ])
            }
            if Task.isCancelled { return injectionRefusal(action: "hand", error: "gesture_cancelled") }
            // Recheck immediately before pointer input after every suspension because focus or authority may have changed.
            if let refusal = imageMiss(step) { return refusal }
            switch step {
            case .key(let event):
                if event.unicodeText != nil, !checkedTextInput {
                    checkedTextInput = true
                    guard let textSignals else { return injectionRefusal(action: "hand", error: "text_observer_unavailable") }
                    guard let pid = requiredFront ?? accessibilitySource(context: context).frontmostApp()?.processIdentifier else {
                        return injectionRefusal(action: "hand", error: "front_unknown")
                    }
                    // Bind click typing to the hit-tested target, even if it already had focus. Unrelated ready editors cannot pass.
                    if gesture == "click_type", clickTarget?.pid != pid {
                        return injectionRefusal(action: "hand", error: "front_changed")
                    }
                    let editorBefore = gesture == "click_type" ? clickTarget?.element : nil
                    textFocus = await waitForTextFocus(
                        pid: pid, target: editorBefore, clickPoint: clickTarget?.point, signals: textSignals
                    , context: context)
                    guard let textFocus else {
                        return injectionRefusal(action: "hand", error: "text_editor_not_ready", extra: [
                            "requested_events_emitted": .int(Int64(emittedEvents)),
                            "text_events_emitted": .int(0),
                            "guidance": .string("The editor has not acquired text focus yet. No text was typed; inspect the app before continuing."),
                        ])
                    }
                    textInput = accessibilityActSource(context: context).textInput(textFocus, context: context)
                    if Task.isCancelled { return injectionRefusal(action: "hand", error: "gesture_cancelled") }
                    if let refusal = await attentionActionRefusal(action: "hand", body: body, turn: turn, context: context) {
                        return refusal
                    }
                    guard accessibilitySource(context: context).frontmostApp()?.processIdentifier == pid else {
                        return injectionRefusal(action: "hand", error: "front_changed")
                    }
                }
                if let input = textFocus, event.down,
                   let pid = requiredFront ?? accessibilitySource(context: context).frontmostApp()?.processIdentifier,
                   !accessibilityActSource(context: context).isFocusedElement(input, pid: pid, context: context) {
                    return injectionRefusal(action: "hand", error: "focus_moved", extra: [
                        "requested_events_emitted": .int(Int64(emittedEvents)),
                    ])
                }
            case .mouse(let event):
                if gesture == "click_type", event.phase == .down {
                    guard let pid = requiredFront ?? accessibilitySource(context: context).frontmostApp()?.processIdentifier else {
                        return injectionRefusal(action: "hand", error: "front_unknown")
                    }
                    let target = accessibilityActSource(context: context).elementAtPosition(x: event.x, y: event.y, pid: pid, context: context)
                    clickTarget = (pid, target, CGPoint(x: event.x, y: event.y))
                }
            default: break
            }
            return nil
        }
        if let refusal = handback(execution) { return refusal }

        if let input = textInput, let text = body["text"]?.stringValue, let textSignals,
           let pid = requiredFront ?? accessibilitySource(context: context).frontmostApp()?.processIdentifier {
            // Read complete evidence after acknowledgement for the declared-effect judge.
            _ = await waitForTextInput(
                pid: pid, target: input.target, value: input.inserting(text), changedFrom: input, signals: textSignals
            , context: context)
        }
        let afterView = defersVisualVerification ? nil : visibleEvidence(await handleView([
            "max_marks": .int(60),
            "max_text_items": .int(80),
        ], context: context))
        if Task.isCancelled {
            if let refusal = handback(await executeHand([], action: "hand", body: body, turn: turn, context: context)) { return refusal }
        }
        let visibleChanged = beforeView != nil && afterView != nil && beforeView != afterView
        let declaration: MacActClosedLoop.DeclaredEffect = selectsAll ? .selectAll : checkedTextInput ? .text(textInput.flatMap { input in
            body["text"]?.stringValue.map { input.inserting($0) }
        }) : .surface(nil)
        // Compare complete values; excerpts lack caption/group context and stay redacted.
        let verdict = MacActClosedLoop.verify(declaration,
            value: (selectionTarget ?? textInput?.target).flatMap { accessibilityActSource(context: context).reread($0, context: context)?.value },
            valueBefore: selectionTarget == nil ? textInput?.value : nil,
            selection: selectionTarget.flatMap { accessibilityActSource(context: context).textInput($0, context: context)?.selection },
            dismissed: surfaceWindowBefore.flatMap { accessibilityActSource(context: context).windowPresence($0, context: context) }.map { !$0 },
            processGone: surfacePid.map { accessibilitySource(context: context).appInfo(pid: $0) == nil } ?? false, redactingText: true)

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
        turn: Turn, context: MacOperationContext, prepare: (inout MacHandStep) async -> MacControlResult? = { _ in nil }) async -> (emitted: Int, recovery: Int,
            refusal: MacControlResult?) {
        var heldKeys: [UInt16] = []
        var heldButtons: [MacMouseButton] = []
        var emitted = 0
        func stopped(_ refusal: MacControlResult) -> (Int, Int, MacControlResult?) {
            let released = heldKeys.count + heldButtons.count
            context.driver?.releaseHeldInputs()
            return (emitted, released, refusal)
        }
        func cancelled() -> MacControlResult {
            injectionRefusal(action: action, error: action == "hand" ? "gesture_cancelled" : "cancelled", extra: [
                "status": .string(action == "hand" ? "interrupted" : "cancelled"),
                "verified": .bool(false), "hand_neutral": .bool(true),
                "guidance": .string("""
                    Cancellation stopped further input. Already emitted input was not undone; observe the current screen before any further action.
                    """),
            ])
        }
        for var step in plan {
            if Task.isCancelled { return stopped(cancelled()) }
            if let refusal = await attentionActionRefusal(action: action, body: body, turn: turn, context: context) { return stopped(refusal) }
            if let refusal = await prepare(&step) { return stopped(refusal) }
            if Task.isCancelled { return stopped(cancelled()) }
            do {
                switch step {
                case .key(let event):
                    // A read-scroll exemption belongs to its navigation, never to an arbitrary chord wrapped around it by `holding`.
                    let posted = try await context.holding(\.looking, context.looking && MacAppActGate.holdingAllowsLooking(body)) { context in
                        try await eventSink.send(key: event, toPid: toPid, turn: turn, context: context)
                    }
                    guard posted else {
                        if let refusal = context.driver?.takeAppActRefusal() { return stopped(refusal.result(action: action)) }
                        return stopped(injectionRefusal(action: action, error: "needs_front"))
                    }
                    if let refusal = context.driver?.takeAppActRefusal() { return stopped(refusal.result(action: action)) }
                    emitted += 1
                    if event.down { heldKeys.append(event.keyCode) }
                    else { heldKeys.removeAll { $0 == event.keyCode } }
                case .mouse(let event):
                    try await eventSink.send(mouse: event, turn: turn, context: context)
                    emitted += 1
                    if event.phase == .down { heldButtons.append(event.button) }
                    else if event.phase == .up { heldButtons.removeAll { $0 == event.button } }
                case .scroll(let event):
                    try await eventSink.send(scroll: event, turn: turn, context: context)
                    emitted += 1
                case .wait(let duration):
                    guard duration > .zero else { continue }
                    let binding = context.driver
                    let store = attentionStore
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { try await Task.sleep(for: duration) }
                            group.addTask {
                                for await _ in await store.driverChanges() {
                                    if binding?.allowsAction(context: context) != true { return }
                                }
                            }
                            _ = try await group.next()
                            group.cancelAll()
                        }
                    } catch { return stopped(cancelled()) }
                    if let refusal = await attentionActionRefusal(action: action, body: body, turn: turn, context: context) { return stopped(refusal) }
                }
            } catch {
                return stopped(injectionRefusal(action: action, error: "window_motor_unconfirmed", extra: [
                    "message": .string(error.localizedDescription), "effects": .string("unknown")]))
            }
            if let refusal = context.driver?.takeAppActRefusal() { return stopped(refusal.result(action: action)) }
        }
        return Task.isCancelled ? stopped(cancelled()) : (emitted, 0, nil)
    }

    /// Recheck each watch event against the live window: pointer input must hit its topmost frame, and keys must reach its focused app/window.
    func watchedWindowMiss(_ step: MacHandStep, window number: Int, pid: Int32, context: MacOperationContext) -> String? {
        let windows = SystemMacVisualObstructionProbe.windows()
        switch step {
        case .mouse(let event):
            let hit = SystemMacVisualObstructionProbe.topmost(in: windows, x: event.x, y: event.y)
            guard hit?.number != number else { return nil }
            return "covered: " + (hit.map { "\($0.ownerName)'s window \($0.number)" } ?? "no window") + " is at that point, not the watched one"
        case .key(let event) where event.down:
            // The focused window is the app's one live window at that frame; two at the same frame cannot be told apart, so that refuses too.
            let focused = accessibilityActSource(context: context).focusedWindow(pid: pid, context: context)?.identity.frame
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

    /// One point is enough for a HID move while too small to meaningfully drag anything if a physical mouse button is already down.
    static let nudgeOffsetPoints: Double = 1

    /// An inert mouse move can wake an idle covered screen without clicking, typing or bypassing a lock. Keep ordinary policy, driver, Accessibility and sink
    /// admission.
    func handleNudge(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult {
        let started = now()

        // Reuse injection preflight because policy admission cannot supply a missing system grant or event sink.
        if let refusal = injectionPreconditions(action: "nudge", requiresSink: true, context: context) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "nudge", body: body, turn: turn, context: context) {
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
        ))], action: "nudge", body: body, turn: turn, context: context)
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

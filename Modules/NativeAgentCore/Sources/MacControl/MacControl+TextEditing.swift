import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import CryptoKit
import ApplicationServices
import CoreGraphics
import AppKit
import NativeAgentShared
import UserNotifications
import Experiences
import Senses
// Blueprint: | `MacControl+TextEditing.swift` | `SwiftNativeMacControl.typeText`: replacement, append and continuation typing preserve the act's mutation ledger, focus gate, exact expected text and partial-input receipts |

extension SwiftNativeMacControl {
    /// Replace or append text through the same act ledger and live input gate.
    func typeText(
        body: [String: JSONValue], entry: MacLookFrameEntry, framePid: Int32,
        actWindow: MacAXWindowRef, target: MacAXActTarget, handle: String,
        text: String?, typeMode: MacTypeMode, background: Bool, keystrokes: Bool,
        noteActuation: (String) -> Void, refuseInput: (String) -> MacActPerformed?,
        ledgeredSetFocused: (MacAXActTarget) -> MacAXActOutcome
    ) async -> MacActPerformed? {
        func ledgeredSetSelectedText(_ actTarget: MacAXActTarget, text: String) -> MacAXActOutcome {
            noteActuation("AXSelectedText")
            return accessibilityActSource.setSelectedText(actTarget, text: text)
        }
        func ledgeredSetSelectedTextRange(_ actTarget: MacAXActTarget, range: NSRange) -> MacAXActOutcome {
            noteActuation("AXSelectedTextRange")
            return accessibilityActSource.setSelectedTextRange(actTarget, range: range)
        }
        func ledgeredActuatorAct(
            action: String?,
            value: String?,
            target: MacAXActTarget
        ) async -> MacAccessibilityActuator.ActResult {
            // Ledgered by the caller before the await: this helper suspends, so it holds no mutable state of the act.
            await MacAccessibilityActuator.act(
                source: accessibilityActSource,
                sink: eventSink,
                target: target,
                action: action,
                value: value,
                emit: { await self.executeHand($0, action: "act", body: body).refusal?.error }
            )
        }

        /// Append never enters a whole-value writer, including after a failed insertion.
        func appendText(_ text: String) async -> MacActPerformed {
            var method = "none"
            var posted = 0
            var expected: String?
            func result(_ error: String? = nil) -> MacActPerformed {
                MacActPerformed(
                    ok: error == nil, method: method, requestedAction: "type",
                    fallbackReason: nil, error: error, target: target,
                    postState: accessibilityActSource.reread(target), actedHandle: handle,
                    extra: [
                        "mode": .string("append"),
                        "posted_events": .int(Int64(posted)),
                        "guidance": .string(error.map {
                            "Append stopped: \($0). The whole value was not replaced. Inspect the target before retrying; insertion may be partial if input was delivered."
                        } ?? "Append input was delivered."),
                    ], expectedText: expected
                )
            }
            guard let before = accessibilityActSource.textInput(target) else {
                return result("append_text_or_selection_unreadable")
            }
            let end = NSRange(location: before.value.utf16.count, length: 0)
            expected = before.value + text
            func waitForValue(_ value: String, selection: NSRange? = nil) async -> Bool {
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
                repeat {
                    guard !Task.isCancelled else { return false }
                    if let input = accessibilityActSource.textInput(target), input.value == value,
                       selection == nil || input.selection == selection { return true }
                    if ContinuousClock.now >= deadline { break }
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
                } while true
                return false
            }
            func atUnchangedEnd() -> Bool {
                guard let input = accessibilityActSource.textInput(target) else { return false }
                return input.value == before.value && input.selection == end
            }
            guard !Task.isCancelled else { return result("cancelled") }
            let positioned = ledgeredSetSelectedTextRange(target, range: end)
            switch positioned {
            case .performed:
                guard await waitForValue(before.value, selection: end) else {
                    return result("append_end_not_verified")
                }
                if !keystrokes {
                    guard !Task.isCancelled, atUnchangedEnd() else { return result("append_target_changed") }
                    method = "ax_selected_text"
                    switch ledgeredSetSelectedText(target, text: text) {
                    case .performed:
                        return result()
                    case .unsupported:
                        guard atUnchangedEnd() else { return result("append_insertion_outcome_unknown") }
                        method = "none"
                    case .invalidTarget, .failed:
                        return result("append_insertion_outcome_unknown")
                    }
                }
            case .unsupported:
                break
            case .invalidTarget, .failed:
                return result("append_end_position_failed")
            }
            // Only unsupported AX operations reach the explicit keyboard route.
            // A background call can be resumed in front before any text was sent.
            guard accessibilityActSource.textInput(target)?.value == before.value else {
                return result("append_target_changed")
            }
            if background {
                var refusal = result("needs_front")
                refusal.extra["ax_delivered"] = .bool(false)
                refusal.extra["needs_front_reason"] = .string("append needs verified focus and an end-of-document keystroke")
                return refusal
            }
            guard eventSink.isAvailable, !eventSink.secureKeyboardEntryActive else {
                return result("append_keyboard_unavailable")
            }
            if let refusal = refuseInput("type") { return result(refusal.error ?? "append_window_not_key") }
            _ = ledgeredSetFocused(target)
            func focusHolds() -> Bool {
                !Task.isCancelled && !eventSink.secureKeyboardEntryActive
                    && accessibilitySource.frontmostApp()?.processIdentifier == framePid
                    && accessibilityActSource.focusedWindow(pid: framePid)?.handle == actWindow.handle
                    && accessibilityActSource.isFocusedElement(target, pid: framePid)
            }
            guard focusHolds() else { return result("append_target_not_focused") }
            // One end-of-document chord, with a readback before any characters.
            method = "keystroke_injection"
            noteActuation("cmd+down")
            let positionedByKeys = await executeHand(MacHandRepertoire.chord(
                MacKeyChord(modifiers: .command, keyCode: 0x7D, source: "cmd+down")), action: "act", body: body)
            posted += positionedByKeys.emitted
            if let refusal = positionedByKeys.refusal { return result(refusal.error) }
            guard await waitForValue(before.value, selection: end), focusHolds(), atUnchangedEnd() else {
                return result("append_end_not_verified")
            }
            noteActuation("type")
            let typed = await executeHand(MacHandRepertoire.type(text: text), action: "act", body: body) { step in
                step.keyEvent?.down == true && !focusHolds()
                    ? self.injectionRefusal(action: "act", error: "append_focus_moved") : nil
            }
            posted += typed.emitted
            return result(typed.refusal?.error)
        }

        /// Background typing uses AXValue replacement or insertion through AXSelectedText.
        /// Only pre-write unsupported can choose another writer; uncertain effects stop with readback.
        /// Pid-addressed keys require the act window and field to retain their app's focus.
        func typeInBackground(_ text: String) async -> MacActPerformed {
            let expected = accessibilityActSource.textInput(target)?.inserting(text)
            func needsFront() -> MacActPerformed {
                MacActPerformed(
                    ok: false, method: "none", requestedAction: "type",
                    fallbackReason: "value_not_settable", error: "needs_front", target: target,
                    postState: accessibilityActSource.reread(target), actedHandle: handle,
                    extra: [
                        "posted_events": .int(0),
                        "needs_front_reason": .string(MacActClosedLoop.needsFrontReason("type")),
                    ]
                )
            }
            // A single-line field is replaced, as a person retyping it would.
            let replacesValue = ["AXTextField", "AXComboBox", "AXSearchField"].contains(target.role)
            if !replacesValue {
                let outcome = ledgeredSetSelectedText(target, text: text)
                if outcome != .unsupported {
                    return MacActPerformed(
                        ok: outcome == .performed, method: "ax_selected_text", requestedAction: "type",
                        fallbackReason: nil, error: outcome == .performed ? nil : "ax_selected_text_\(outcome.rawValue)",
                        target: target, postState: accessibilityActSource.reread(target), actedHandle: handle,
                        expectedText: expected
                    )
                }
            }
            noteActuation("AXSetValue")
            let result = await ledgeredActuatorAct(action: nil, value: text, target: target)
            if result.outcome != .unsupported {
                return summarize(result, target: target, actedHandle: handle,
                                 extra: ["background_route": .string("ax_value_replace")], text: text)
            }
            if replacesValue { return needsFront() }
            if let refusal = MacActClosedLoop.secureInputRefusal(active: eventSink.secureKeyboardEntryActive) {
                return MacActPerformed(
                    ok: false, method: "none", requestedAction: "type",
                    fallbackReason: refusal.reason, error: refusal.reason, target: target,
                    postState: nil, actedHandle: handle,
                    extra: ["posted_events": .int(0), "guidance": .string(refusal.note)]
                )
            }
            /// The keys go to the pid, and the app routes them to ITS focus:
            /// so the act window must be the app's focused window AND the
            /// target field its focused element — re-asked before every chunk.
            func focusHolds() -> Bool {
                guard !Task.isCancelled, MacDriverContext.binding?.allowsAction == true else { return false }
                guard let focused = accessibilityActSource.focusedWindow(pid: framePid),
                      focused.handle == actWindow.handle else { return false }
                return accessibilityActSource.isFocusedElement(target, pid: framePid)
            }
            guard eventSink.isAvailable,
                  ledgeredSetFocused(target) == .performed,
                  focusHolds() else { return needsFront() }
            var admitted = 0
            let execution = await executeHand(MacHandRepertoire.type(text: text), action: "act", body: body, toPid: framePid) { step in
                if step.keyEvent?.down == true {
                    if admitted % 4 == 0, !focusHolds() {
                        return self.injectionRefusal(action: "act", error: "focus_moved")
                    }
                    admitted += 1
                }
                return nil
            }
            let posted = execution.emitted
            let charactersSent = (posted + 1) / 2
            if execution.refusal?.error == "focus_moved" {
                return MacActPerformed(ok: false, method: "keystroke_to_pid", requestedAction: "type",
                    fallbackReason: "value_not_settable", error: "focus_moved", target: target,
                    postState: accessibilityActSource.reread(target), actedHandle: handle,
                    extra: ["posted_events": .int(Int64(posted)), "characters_sent": .int(Int64(charactersSent)),
                        "text_character_count": .int(Int64(text.count)),
                        "guidance": .string("focus moved off that field inside the app, so I stopped typing after \(charactersSent) of \(text.count) characters — check the screen below")])
            }
            guard posted > 0 else { return needsFront() }
            if execution.refusal != nil || charactersSent < text.count {
                return MacActPerformed(
                    ok: false, method: "keystroke_to_pid", requestedAction: "type",
                    fallbackReason: "value_not_settable", error: "keystroke_delivery_stopped", target: target,
                    postState: accessibilityActSource.reread(target), actedHandle: handle,
                    extra: ["posted_events": .int(Int64(posted)), "characters_sent": .int(Int64(charactersSent))]
                )
            }
            return MacActPerformed(
                ok: true, method: "keystroke_to_pid", requestedAction: "type",
                fallbackReason: "value_not_settable", error: nil, target: target,
                postState: accessibilityActSource.reread(target), actedHandle: handle,
                extra: ["posted_events": .int(Int64(posted)), "text_character_count": .int(Int64(text.count))],
                expectedText: expected
            )
        }

        guard let text, !text.isEmpty else { return nil }
        // Type only into editable roles; focusing with AXPress can activate a control and is never typing.
        guard MacActClosedLoop.canType(role: target.role) else { return nil }
        // Password fields are a credential boundary; refuse before every actuation so the person supplies the credential.
        if let refusal = MacActClosedLoop.secureFieldRefusal(role: target.role) {
            return MacActPerformed(
                ok: false,
                method: "none",
                requestedAction: "type",
                fallbackReason: refusal.reason,
                error: refusal.reason,
                target: target,
                postState: nil,
                actedHandle: handle,
                extra: [
                    "posted_events": .int(0),
                    "guidance": .string(refusal.note),
                ]
            )
        }
        if typeMode == .append {
            return await appendText(text)
        }
        if let continuation = MacWorkContinuation.current, continuation.isPending {
            var typingMethod = "ax_selected_text"
            var expected: String?
            let inputStartCount = MacDriverContext.binding?.inputCount ?? 0
            func continuationResult(_ error: String?, delivered: Bool = false) -> MacActPerformed {
                let posted = (MacDriverContext.binding?.inputCount ?? inputStartCount) - inputStartCount
                return MacActPerformed(ok: error == nil, method: delivered || posted > 0 ? typingMethod : "none",
                    requestedAction: "type", fallbackReason: nil, error: error, target: target,
                    postState: delivered || posted > 0 ? accessibilityActSource.reread(target) : nil, actedHandle: handle,
                    extra: ["ax_delivered": .bool(delivered),
                            "posted_events": .int(Int64(posted))], expectedText: expected)
            }
            guard continuation.app?.processIdentifier == framePid,
                  continuation.focusPath == entry.path,
                  let before = accessibilityActSource.textInput(target),
                  before.selection == continuation.selectionRange,
                  continuation.refusal() == nil else {
                return continuationResult("stale_continuation_target")
            }
            expected = before.inserting(text)
            guard !Task.isCancelled else { return continuationResult("cancelled") }
            if keystrokes {
                typingMethod = background ? "keystroke_to_pid" : "keystroke_injection"
                guard eventSink.isAvailable else { return continuationResult("event_injection_unavailable") }
                if let refusal = MacActClosedLoop.secureInputRefusal(active: eventSink.secureKeyboardEntryActive) {
                    return continuationResult(refusal.reason)
                }
                if !background, let refusal = refuseInput("type") {
                    return continuationResult(refusal.error ?? refusal.fallbackReason ?? "focus_moved")
                }
                let execution = await executeHand(MacHandRepertoire.type(text: text), action: "act", body: body, toPid: background ? framePid : nil) { step in
                    guard let event = step.keyEvent else { return nil }
                    if event.down {
                        guard !Task.isCancelled,
                              MacDriverContext.binding?.allowsEmission == true,
                              !eventSink.secureKeyboardEntryActive,
                              accessibilityActSource.focusedWindow(pid: framePid)?.handle == actWindow.handle,
                              accessibilityActSource.isFocusedElement(target, pid: framePid) else {
                            return self.injectionRefusal(action: "act", error: "focus_moved")
                        }
                        if continuation.isPending {
                            guard continuation.refusal() == nil,
                                  let current = accessibilityActSource.textInput(target),
                                  current.value == before.value, current.selection == before.selection else {
                                return self.injectionRefusal(action: "act", error: "stale_continuation_target")
                            }
                        }
                        if !background, let refusal = refuseInput("type") {
                            return self.injectionRefusal(action: "act", error: refusal.error ?? refusal.fallbackReason ?? "focus_moved")
                        }
                    }
                    return nil
                }
                if execution.emitted > 0 { noteActuation("type") }
                return continuationResult(execution.refusal?.error)
            }
            let outcome = ledgeredSetSelectedText(target, text: text)
            switch outcome {
            case .performed:
                return continuationResult(nil, delivered: true)
            case .unsupported:
                return continuationResult("selection_insertion_unsupported")
            case .invalidTarget:
                return continuationResult("stale_continuation_target")
            case .failed:
                return continuationResult("continuation_insertion_outcome_unknown")
            }
        }
        if background {
            return await typeInBackground(text)
        }
        // AXSetValue first: that is how you fill a field without
        // simulating 40 keystrokes, and it cannot be intercepted by
        // whatever else has focus. Not when real keystrokes were asked for.
        if !keystrokes {
            noteActuation("AXSetValue")
            let result = await ledgeredActuatorAct(action: nil, value: text, target: target)
            if result.ok || result.outcome != .unsupported {
                return summarize(result, target: target, actedHandle: handle, text: text)
            }
        }
        // Focus through AXFocused before keystroke injection; AXPress can submit an editable control.
        let focusOutcome = ledgeredSetFocused(target)
        var focusMethod = focusOutcome == .performed ? "ax_focus" : "none"
        guard focusOutcome == .performed else {
            // No focus, no honest keystroke target: typing now would land
            // wherever the focus already was. Report instead of scattering
            // text across the app.
            return MacActPerformed(
                ok: false,
                method: "none",
                requestedAction: "type",
                fallbackReason: "value_not_settable",
                error: "focus_not_settable",
                target: target,
                postState: accessibilityActSource.reread(target),
                actedHandle: handle,
                extra: ["focus_method": .string(focusMethod)]
            )
        }
        guard eventSink.isAvailable else {
            return MacActPerformed(
                ok: false,
                method: "none",
                requestedAction: "type",
                fallbackReason: "value_not_settable",
                error: "event_injection_unavailable",
                target: target,
                postState: accessibilityActSource.reread(target),
                actedHandle: handle,
                extra: ["focus_method": .string(focusMethod)]
            )
        }
        // Check secure input before any raise; synthesized typing would be discarded and must also pass the key-window gate.
        if let refusal = MacActClosedLoop.secureInputRefusal(
            active: eventSink.secureKeyboardEntryActive
        ) {
            return MacActPerformed(
                ok: false,
                method: "none",
                requestedAction: "type",
                fallbackReason: refusal.reason,
                error: refusal.reason,
                target: target,
                postState: accessibilityActSource.reread(target),
                actedHandle: handle,
                extra: [
                    "posted_events": .int(0),
                    "focus_method": .string(focusMethod),
                    "guidance": .string(refusal.note),
                ]
            )
        }
        // Confirm the field's focus; when AX focus does not take, click its centre before typing.
        func holdsFocus() -> Bool {
            for attempt in 0..<12 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.025) }
                if accessibilityActSource.isFocusedElement(target, pid: framePid) { return true }
            }
            return false
        }
        if !holdsFocus() {
            if let centre = target.centre {
                if let refusal = refuseInput("type") { return refusal }
                noteActuation("click")
                let emission = await executeHand(MacHandRepertoire.click(button: .left, at: centre), action: "act", body: body)
                if let refusal = emission.refusal { return MacActPerformed(ok: false, method: "click", requestedAction: "type", fallbackReason: nil, error: refusal.error, target: target, postState: accessibilityActSource.reread(target), actedHandle: handle) }
                focusMethod = "click"
            }
            guard focusMethod == "click", holdsFocus() else {
                return MacActPerformed(
                    ok: false,
                    method: focusMethod == "click" ? "click" : "none",
                    requestedAction: "type",
                    fallbackReason: "value_not_settable",
                    error: "target_not_focused",
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle,
                    extra: [
                        "focus_method": .string(focusMethod),
                        "guidance": .string(
                            "that field didn't take the keyboard focus, so I typed nothing — keys would have gone somewhere else"
                        ),
                    ]
                )
            }
        }
        if let refusal = refuseInput("type") {
            guard focusMethod == "click" else { return refusal }
            // The click went; the keys don't. Said as it happened, not as
            // "nothing was posted".
            return MacActPerformed(
                ok: false,
                method: "click",
                requestedAction: "type",
                fallbackReason: "key_window_changed_after_actuation",
                error: "key_window_changed_after_actuation",
                target: target,
                postState: accessibilityActSource.reread(target),
                actedHandle: handle,
                extra: [
                    "focus_method": .string(focusMethod),
                    "guidance": .string(
                        "I clicked that field to focus it, then another window took the keys, so I typed nothing"
                    ),
                ]
            )
        }
        // Select all only in single-line fields; document bodies retain their insertion selection.
        func typingFailure(_ error: String) -> MacActPerformed {
            MacActPerformed(
                ok: false, method: "keystroke_injection", requestedAction: "type",
                fallbackReason: "value_not_settable", error: error, target: target,
                postState: accessibilityActSource.reread(target), actedHandle: handle,
                extra: ["focus_method": .string(focusMethod)]
            )
        }
        guard let input = await waitForTextInput(pid: framePid, target: target) else {
            return typingFailure("text_editor_not_ready")
        }
        if let refusal = refuseInput("type") { return refusal }
        let replacesField = ["AXTextField", "AXComboBox", "AXSearchField"].contains(target.role)
        if replacesField, input.selection != NSRange(location: 0, length: input.value.utf16.count) {
            noteActuation("select_all")
            let emission = await executeHand(MacHandRepertoire.chord(MacKeyChord(modifiers: .command, keyCode: 0x00, source: "cmd+a")), action: "act", body: body)
            if let refusal = emission.refusal { return typingFailure(refusal.error ?? "text_selection_not_ready") }
            guard await waitForTextInput(pid: framePid, target: input.target, selectedAll: true) != nil else {
                return typingFailure("text_selection_not_ready")
            }
        }
        if let refusal = refuseInput("type") { return refusal }
        var typingRefusal: MacActPerformed?
        let execution = await executeHand(MacHandRepertoire.type(text: text), action: "act", body: body) { step in
            guard let event = step.keyEvent else { return nil }
            if event.down {
                guard !Task.isCancelled,
                      accessibilityActSource.isFocusedElement(input.target, pid: framePid) else {
                    return self.injectionRefusal(action: "act", error: "focus_moved")
                }
                if let refusal = refuseInput("type") {
                    typingRefusal = refusal
                    return self.injectionRefusal(action: "act", error: refusal.error ?? "focus_moved")
                }
            }
            return nil
        }
        if let typingRefusal { return typingRefusal }
        if let refusal = execution.refusal { return typingFailure(refusal.error ?? "focus_moved") }
        let expectedValue = replacesField ? text : input.inserting(text)
        return MacActPerformed(
            ok: true,
            method: "keystroke_injection",
            requestedAction: "type",
            fallbackReason: "value_not_settable",
            error: nil,
            target: target,
            postState: accessibilityActSource.reread(target),
            actedHandle: handle,
            extra: [
                "focus_method": .string(focusMethod),
                "text_character_count": .int(Int64(text.count)),
            ], expectedText: expectedValue
        )
    }
}

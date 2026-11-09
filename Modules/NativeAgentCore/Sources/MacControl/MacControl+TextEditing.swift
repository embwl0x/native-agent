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
// Blueprint: | `MacControl+TextEditing.swift` | `SwiftNativeMacControl.typeText`: One writer; event-judged focus and selection acknowledgement |

extension SwiftNativeMacControl {
    /// Share the act ledger and live gate so text editing retains ordinary motor admission.
    func typeText(
        body: [String: JSONValue], entry: MacLookFrameEntry, framePid: Int32,
        actWindow: MacAXWindowRef, target: MacAXActTarget, handle: String,
        text: String?, typeMode: MacTypeMode, background: Bool, keystrokes: Bool,
        noteActuation: (String) -> Void, recordAXOutcome: (MacAXActOutcome) -> Void, refuseInput: (String) -> MacActPerformed?,
        turn: Turn, context: MacOperationContext, ledgeredSetFocused: (MacAXActTarget) -> MacAXActOutcome) async -> MacActPerformed? {
        func ledgeredSetSelectedText(_ actTarget: MacAXActTarget, text: String) -> MacAXActOutcome {
            let outcome = accessibilityActSource(context: context).setSelectedText(actTarget, text: text, turn: turn, context: context)
            recordAXOutcome(outcome)
            if outcome.emissionAttempted { noteActuation("AXSelectedText") }
            return outcome
        }
        func ledgeredSetSelectedTextRange(_ actTarget: MacAXActTarget, range: NSRange) -> MacAXActOutcome {
            let outcome = accessibilityActSource(context: context).setSelectedTextRange(actTarget, range: range, turn: turn, context: context)
            recordAXOutcome(outcome)
            if outcome.emissionAttempted { noteActuation("AXSelectedTextRange") }
            return outcome
        }
        func ledgeredActuatorAct(
            action: String?,
            value: String?,
            target: MacAXActTarget
        ) async -> MacAccessibilityActuator.ActResult {
            let result = await MacAccessibilityActuator.act(
                source: accessibilityActSource(context: context),
                target: target,
                action: action,
                value: value
            , turn: turn, context: context)
            recordAXOutcome(result.outcome)
            if result.outcome.emissionAttempted { noteActuation(result.requestedAction) }
            return result
        }

        /// Append never enters a whole-value writer, including after a failed insertion.
        func appendText(_ text: String, signals: MacWaitSignals) async -> MacActPerformed {
            var method = "none"
            var posted = 0
            var expected: String?
            func result(_ error: String? = nil) -> MacActPerformed {
                MacActPerformed(
                    ok: error == nil, method: method, requestedAction: "type",
                    error: error, target: target,
                    postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle,
                    extra: [
                        "mode": .string("append"),
                        "posted_events": .int(Int64(posted)),
                        "guidance": .string(error.map {
                            """
                                Append stopped: \($0). The whole value was not replaced. Inspect the target before retrying; insertion may be partial if \
                                input was delivered.
                                """
                        } ?? "Append input was delivered."),
                    ], expectedText: expected
                )
            }
            guard let before = accessibilityActSource(context: context).textInput(target, context: context) else {
                return result("append_text_or_selection_unreadable")
            }
            let end = NSRange(location: before.value.utf16.count, length: 0)
            expected = before.value + text
            func waitForValue(_ value: String, selection: NSRange? = nil) async -> Bool {
                let end = await macSettle("append_selection", signals: signals, patience: 0.75) {
                    guard !Task.isCancelled else { return false }
                    if let input = accessibilityActSource(context: context).textInput(target, context: context), input.value == value,
                       selection == nil || input.selection == selection { return true }
                    return false
                }
                return end == .held
            }
            func atUnchangedEnd() -> Bool {
                guard let input = accessibilityActSource(context: context).textInput(target, context: context) else { return false }
                return input.value == before.value && input.selection == end
            }
            guard !Task.isCancelled else { return result("cancelled") }
            let positioned = ledgeredSetSelectedTextRange(target, range: end)
            switch positioned.status {
            case .performed:
                guard await waitForValue(before.value, selection: end) else {
                    return result("append_end_not_verified")
                }
                if !keystrokes {
                    guard !Task.isCancelled, atUnchangedEnd() else { return result("append_target_changed") }
                    method = "ax_selected_text"
                    switch ledgeredSetSelectedText(target, text: text).status {
                    case .performed:
                        return result()
                    case .unsupported:
                        return result("append_insertion_unsupported")
                    case .invalidTarget, .failed, .unverified:
                        return result("append_insertion_outcome_unknown")
                    }
                }
            case .unsupported:
                guard keystrokes else { return result("append_end_position_unsupported") }
            case .unverified:
                return result("append_end_not_verified")
            case .invalidTarget, .failed:
                return result("append_end_position_failed")
            }
            // Only a preselected keystroke contract reaches the keyboard writer.
            guard accessibilityActSource(context: context).textInput(target, context: context)?.value == before.value else {
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
                    && accessibilitySource(context: context).frontmostApp()?.processIdentifier == framePid
                    && accessibilityActSource(context: context).focusedWindow(pid: framePid, context: context)?.handle == actWindow.handle
                    && accessibilityActSource(context: context).isFocusedElement(target, pid: framePid, context: context)
            }
            guard focusHolds() else { return result("append_target_not_focused") }
            // One end-of-document chord, with a readback before any characters.
            method = "keystroke_injection"
            noteActuation("cmd+down")
            let positionedByKeys = await executeHand(MacHandRepertoire.chord(
                MacKeyChord(modifiers: .command, keyCode: 0x7D, source: "cmd+down")), action: "act", body: body, turn: turn, context: context)
            posted += positionedByKeys.emitted
            if let refusal = positionedByKeys.refusal { return result(refusal.error) }
            guard await waitForValue(before.value, selection: end), focusHolds(), atUnchangedEnd() else {
                return result("append_end_not_verified")
            }
            noteActuation("type")
            let typed = await executeHand(MacHandRepertoire.type(text: text), action: "act", body: body, turn: turn, context: context) { step in
                step.keyEvent?.down == true && !focusHolds()
                    ? self.injectionRefusal(action: "act", error: "append_focus_moved") : nil
            }
            posted += typed.emitted
            return result(typed.refusal?.error)
        }

        /// Background typing selects one writer from the requested contract: replace single-line values, insert at multiline selection, or explicit keys.
        /// Unsupported operations stop with their own readback. Pid-addressed keys require the act window and field to retain their app's focus.
        func typeInBackground(_ text: String) async -> MacActPerformed {
            let expected = accessibilityActSource(context: context).textInput(target, context: context)?.inserting(text)
            func needsFront() -> MacActPerformed {
                MacActPerformed(
                    ok: false, method: "none", requestedAction: "type",
                    error: "needs_front", target: target,
                    postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle,
                    extra: [
                        "posted_events": .int(0),
                        "needs_front_reason": .string(MacActClosedLoop.needsFrontReason("type")),
                    ]
                )
            }
            if !keystrokes {
                let replacesValue = ["AXTextField", "AXComboBox", "AXSearchField"].contains(target.role)
                if !replacesValue {
                    let outcome = ledgeredSetSelectedText(target, text: text)
                    return MacActPerformed(
                        ok: outcome == .performed, method: "ax_selected_text", requestedAction: "type",
                        error: outcome == .performed ? nil : "ax_selected_text_\(outcome.rawValue)",
                        target: target, postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle,
                        expectedText: expected
                    )
                }
                    let result = await ledgeredActuatorAct(action: nil, value: text, target: target)
                return summarize(result, target: target, actedHandle: handle,
                    extra: ["background_route": .string("ax_value_replace")], text: text)
            }
            if let refusal = MacActClosedLoop.secureInputRefusal(active: eventSink.secureKeyboardEntryActive) {
                return MacActPerformed(
                    ok: false, method: "none", requestedAction: "type",
                    error: refusal.reason, target: target,
                    postState: nil, actedHandle: handle,
                    extra: ["posted_events": .int(0), "guidance": .string(refusal.note)]
                )
            }
            /// The keys go to the pid, and the app routes them to ITS focus: so the act window must be the app's focused window AND the target field its
            /// focused element — re-asked before every key-down.
            func focusHolds() -> Bool {
                guard !Task.isCancelled, context.driver?.allowsAction(context: context) == true else { return false }
                guard let focused = accessibilityActSource(context: context).focusedWindow(pid: framePid, context: context),
                      focused.handle == actWindow.handle else { return false }
                return accessibilityActSource(context: context).isFocusedElement(target, pid: framePid, context: context)
            }
            guard eventSink.isAvailable,
                  ledgeredSetFocused(target) == .performed,
                  focusHolds() else { return needsFront() }
            let execution = await executeHand(MacHandRepertoire.type(text: text), action: "act", body: body, toPid: framePid, turn: turn,
                context: context) { step in
                if step.keyEvent?.down == true {
                    if !focusHolds() {
                        return self.injectionRefusal(action: "act", error: "focus_moved")
                    }
                }
                return nil
            }
            let posted = execution.emitted
            let charactersSent = (posted + 1) / 2
            if execution.refusal?.error == "focus_moved" {
                return MacActPerformed(ok: false, method: "keystroke_to_pid", requestedAction: "type",
                    error: "focus_moved", target: target,
                    postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle,
                    extra: ["posted_events": .int(Int64(posted)), "characters_sent": .int(Int64(charactersSent)),
                        "text_character_count": .int(Int64(text.count)),
                        "guidance": .string("""
                            focus moved off that field inside the app, so I stopped typing after \(charactersSent) of \(text.count) characters — check the \
                            screen below
                            """)])
            }
            guard posted > 0 else { return needsFront() }
            if execution.refusal != nil || charactersSent < text.count {
                return MacActPerformed(
                    ok: false, method: "keystroke_to_pid", requestedAction: "type",
                    error: "keystroke_delivery_stopped", target: target,
                    postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle,
                    extra: ["posted_events": .int(Int64(posted)), "characters_sent": .int(Int64(charactersSent))]
                )
            }
            return MacActPerformed(
                ok: true, method: "keystroke_to_pid", requestedAction: "type",
                error: nil, target: target,
                postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle,
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
        let textSignals = MacWaitSignals(effects: effectObserverSource, activation: defaultMacAppActivationObserverSource(), pid: framePid)
        defer { textSignals.stop() }
        if typeMode == .append {
            return await appendText(text, signals: textSignals)
        }
        if let continuation = turn.macContinuation, continuation.isPending {
            var typingMethod = "ax_selected_text"
            var expected: String?
            let inputStartCount = context.driver?.inputCount ?? 0
            func continuationResult(_ error: String?, delivered: Bool = false) -> MacActPerformed {
                let posted = (context.driver?.inputCount ?? inputStartCount) - inputStartCount
                return MacActPerformed(ok: error == nil, method: delivered || posted > 0 ? typingMethod : "none",
                    requestedAction: "type", error: error, target: target,
                    postState: delivered || posted > 0 ? accessibilityActSource(context: context).reread(target, context: context) : nil, actedHandle: handle,
                    extra: ["ax_delivered": .bool(delivered),
                            "posted_events": .int(Int64(posted))], expectedText: expected)
            }
            guard continuation.app?.processIdentifier == framePid,
                  continuation.focusPath == entry.path,
                  let before = accessibilityActSource(context: context).textInput(target, context: context),
                  before.selection == continuation.selectionRange,
                  continuation.refusal(context: context) == nil else {
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
                    return continuationResult(refusal.error ?? "focus_moved")
                }
                let execution = await executeHand(MacHandRepertoire.type(text: text), action: "act", body: body, toPid: background ? framePid : nil, turn: turn,
                    context: context) { step in
                    guard let event = step.keyEvent else { return nil }
                    if event.down {
                        guard !Task.isCancelled,
                              context.driver?.allowsEmission(context: context) == true,
                              !eventSink.secureKeyboardEntryActive,
                              accessibilityActSource(context: context).focusedWindow(pid: framePid, context: context)?.handle == actWindow.handle,
                              accessibilityActSource(context: context).isFocusedElement(target, pid: framePid, context: context) else {
                            return self.injectionRefusal(action: "act", error: "focus_moved")
                        }
                        if continuation.isPending {
                            guard continuation.refusal(context: context) == nil,
                                  let current = accessibilityActSource(context: context).textInput(target, context: context),
                                  current.value == before.value, current.selection == before.selection else {
                                return self.injectionRefusal(action: "act", error: "stale_continuation_target")
                            }
                        }
                        if !background, let refusal = refuseInput("type") {
                            return self.injectionRefusal(action: "act", error: refusal.error ?? "focus_moved")
                        }
                    }
                    return nil
                }
                if execution.emitted > 0 { noteActuation("type") }
                return continuationResult(execution.refusal?.error)
            }
            let outcome = ledgeredSetSelectedText(target, text: text)
            switch outcome.status {
            case .performed:
                return continuationResult(nil, delivered: true)
            case .unsupported:
                return continuationResult("selection_insertion_unsupported")
            case .invalidTarget:
                return continuationResult("stale_continuation_target")
            case .failed, .unverified:
                return continuationResult("continuation_insertion_outcome_unknown")
            }
        }
        let beforeValueWrite = accessibilityActSource(context: context).reread(target, context: context)?.value
        var valueWrite: MacActPerformed?
        if background { valueWrite = await typeInBackground(text) }
        // AXSetValue cannot be intercepted by another focused field; explicit keystroke requests still select the keyboard contract.
        else if !keystrokes {
            let result = await ledgeredActuatorAct(action: nil, value: text, target: target)
            valueWrite = summarize(result, target: target, actedHandle: handle, text: text)
        }
        if var valueWrite {
            valueWrite.textBeforeWrite = beforeValueWrite
            return valueWrite
        }
        return await typeWithKeys()

        func typeWithKeys() async -> MacActPerformed {
            // Focus through AXFocused before keystroke injection; AXPress can submit an editable control.
            let focusOutcome = ledgeredSetFocused(target)
            let focusMethod = focusOutcome == .performed ? "ax_focus" : "none"
            guard focusOutcome == .performed else {
                // No focus, no honest keystroke target: typing now would land wherever the focus already was. Report instead of scattering text across the app.
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "type",
                    error: "focus_not_settable",
                    target: target,
                    postState: accessibilityActSource(context: context).reread(target, context: context),
                    actedHandle: handle,
                    extra: ["focus_method": .string(focusMethod)]
                )
            }
            guard eventSink.isAvailable else {
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "type",
                    error: "event_injection_unavailable",
                    target: target,
                    postState: accessibilityActSource(context: context).reread(target, context: context),
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
                    error: refusal.reason,
                    target: target,
                    postState: accessibilityActSource(context: context).reread(target, context: context),
                    actedHandle: handle,
                    extra: [
                        "posted_events": .int(0),
                        "focus_method": .string(focusMethod),
                        "guidance": .string(refusal.note),
                    ]
                )
            }
            // AX focus must establish the exact recipient; a click is a different effect.
            func holdsFocus() async -> Bool {
                let end = await macSettle("text_exact_focus", signals: textSignals, patience: 0.3) {
                    !Task.isCancelled && accessibilityActSource(context: context).isFocusedElement(target, pid: framePid, context: context)
                }
                return end == .held
            }
            guard await holdsFocus() else {
                return MacActPerformed(ok: false, method: "ax_focus", requestedAction: "type",
                    error: "target_not_focused", target: target,
                    postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle,
                    extra: ["posted_events": .int(0), "focus_method": .string(focusMethod),
                        "guidance": .string("""
                            Accessibility focus was accepted but this field has not acquired keyboard focus yet. Read the app before typing; no keys were \
                            posted.
                            """)])
            }
            if let refusal = refuseInput("type") { return refusal }
            // Select all only in single-line fields; document bodies retain their insertion selection.
            func typingFailure(_ error: String) -> MacActPerformed {
                MacActPerformed(
                    ok: false, method: "keystroke_injection", requestedAction: "type",
                    error: error, target: target,
                    postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle,
                    extra: ["focus_method": .string(focusMethod)]
                )
            }
            guard let focused = await waitForTextFocus(pid: framePid, target: target, clickPoint: nil, signals: textSignals, context: context) else {
                var pending = typingFailure("text_editor_not_ready")
                pending.extra["guidance"] = .string("The editor has not acquired text focus yet. No text was typed; inspect the app before continuing.")
                return pending
            }
            let input = accessibilityActSource(context: context).textInput(focused, context: context)
            if let refusal = refuseInput("type") { return refusal }
            let replacesField = ["AXTextField", "AXComboBox", "AXSearchField"].contains(target.role)
            if replacesField {
                guard let input else { return typingFailure("text_selection_not_ready") }
                if input.selection != NSRange(location: 0, length: input.value.utf16.count) {
                    noteActuation("select_all")
                    let emission = await executeHand(MacHandRepertoire.chord(MacKeyChord(modifiers: .command, keyCode: 0x00, source: "cmd+a")), action: "act",
                        body: body, turn: turn, context: context)
                    if let refusal = emission.refusal { return typingFailure(refusal.error ?? "text_selection_not_ready") }
                    guard await waitForTextInput(pid: framePid, target: input.target, selectedAll: true,
                                                signals: textSignals, context: context) != nil else {
                        var pending = typingFailure("text_selection_not_ready")
                        pending.extra["guidance"] = .string("Select-all input was delivered; its selection is not verified yet. No replacement text was typed.")
                        return pending
                    }
                }
            }
            if let refusal = refuseInput("type") { return refusal }
            var typingRefusal: MacActPerformed?
            let execution = await executeHand(MacHandRepertoire.type(text: text), action: "act", body: body, turn: turn, context: context) { step in
                guard let event = step.keyEvent else { return nil }
                if event.down {
                    guard !Task.isCancelled,
                          accessibilityActSource(context: context).isFocusedElement(focused, pid: framePid, context: context) else {
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
            let expectedValue = replacesField ? text : input?.inserting(text)
            return MacActPerformed(
                ok: true,
                method: "keystroke_injection",
                requestedAction: "type",
                error: nil,
                target: target,
                postState: accessibilityActSource(context: context).reread(target, context: context),
                actedHandle: handle,
                extra: [
                    "focus_method": .string(focusMethod),
                    "text_character_count": .int(Int64(text.count)),
                ], expectedText: expectedValue
            )
        }
    }
}

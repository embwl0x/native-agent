import Foundation
import NativeAgentShared
import NativeAgentCore
import TrustCenter
import PersistenceCore
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(UserNotifications)
import UserNotifications
import ApplicationServices
import Senses
import Experiences
import CryptoKit
import os
import CoreText
import ScreenCaptureKit
#endif
// Blueprint: | `MacNativeAction.swift` | Native act execution through the existing text-editing owner and act verification loop |

extension SwiftNativeMacControl {
    func summarize(
        _ result: MacAccessibilityActuator.ActResult,
        target: MacAXActTarget,
        actedHandle: String,
        extra: [String: JSONValue] = [:], text: String?
    ) -> MacActPerformed {
        MacActPerformed(
            ok: result.ok,
            method: result.method,
            requestedAction: result.requestedAction,
            fallbackReason: result.fallbackReason,
            error: result.error,
            target: target,
            postState: result.postState,
            actedHandle: actedHandle,
            extra: extra,
            expectedText: result.method == "ax_set_value" ? text : nil
        )
    }

    func performAct(
        body: [String: JSONValue], verb: MacActVerb,
        handle: String,
        entry: MacLookFrameEntry,
        frame: MacLookFrame,
        /// All later resolution, including dismiss buttons, stays anchored to the frame's pid.
        framePid: Int32,
        /// All element paths resolve within the frame's matched window, not whichever window is focused.
        actWindow: MacAXWindowRef,
        target: MacAXActTarget,
        text: String?,
        typeMode: MacTypeMode,
        direction: MacActScrollDirection,
        /// Background acts never raise; sites needing the front refuse `needs_front`, while typing addresses the app through AX or pid.
        background: Bool = false,
        /// `type` as real keystrokes, never AXSetValue: a search field (or one
        /// a return is about to submit) runs its action only on real typing.
        keystrokes: Bool = false
    ) async -> MacActPerformed? {
        /// One raise per call. A second attempt after the first failed to take
        /// would be a retry loop against the window server, and the window
        /// server wins.
        var raiseAttempted = false
        var didActuate = false
        var actuationsAttempted: [String] = []
        func noteActuation(_ action: String) {
            didActuate = true
            if !actuationsAttempted.contains(action) { actuationsAttempted.append(action) }
        }

        // Ledger every AX mutation before inspecting its return status: a failed reply does not prove no effect occurred.
        func ledgeredPerform(_ actTarget: MacAXActTarget, action: String) -> MacAXActOutcome {
            noteActuation(action)
            return accessibilityActSource.perform(actTarget, action: action)
        }
        func ledgeredSetSelected(_ actTarget: MacAXActTarget) -> MacAXActOutcome {
            noteActuation("AXSelected")
            return accessibilityActSource.setSelected(actTarget)
        }
        func ledgeredSetFocused(_ actTarget: MacAXActTarget) -> MacAXActOutcome {
            noteActuation("AXFocused")
            return accessibilityActSource.setFocused(actTarget)
        }
        /// Read front/focus together and name both windows in a refusal.
        func liveKeyWindowRefusal() -> MacActClosedLoop.KeyWindowRefusal? {
            let frontmost = accessibilitySource.frontmostApp()
            let focused = accessibilityActSource.focusedWindow(pid: framePid)
            return MacActClosedLoop.keyWindowRefusal(
                framePid: framePid,
                frontmostPid: frontmost?.processIdentifier,
                frontmostName: frontmost?.name,
                frameWindowHandle: actWindow.handle,
                focusedWindowHandle: focused?.handle,
                frameWindowTitle: actWindow.identity.title,
                focusedWindowTitle: focused?.identity.title,
                // Counted ONLY when the focused window could not be named —
                // that is the single branch that consults it, and enumerating
                // an app's windows is several AX round-trips at a gate that
                // runs more than once per act.
                appWindowCount: focused == nil
                    ? accessibilityActSource.windows(pid: framePid).count
                    : nil
            )
        }

        func refuseInput(_ requestedAction: String) -> MacActPerformed? {
            if let refusal = MacWorkContinuation.current?.refusal() {
                return MacActPerformed(ok: false, method: "none", requestedAction: requestedAction,
                    fallbackReason: nil, error: "continuation_unavailable", target: target,
                    postState: nil, actedHandle: handle, extra: ["guidance": .string(refusal)])
            }
            // Reread at each emission boundary: intervening AX work can change focus, and the window server owns the remaining race.
            guard var inputRefusal = liveKeyWindowRefusal() else { return nil }

            // Raise only before actuation; confirm with two consecutive clear focus reads within the bounded wait.
            func raiseSettled() -> Bool {
                /// ~500 ms of budget in 20 ms steps. Deliberately short: this
                /// blocks the act, and an app switch the window server has not
                /// made in half a second is not being made.
                let reads = 25
                let stepSeconds = 0.02
                /// One matching read is the optimistic answer; two in a row is
                /// a state.
                let clearReadsRequired = 2
                var consecutiveClear = 0
                for attempt in 0..<reads {
                    if attempt > 0 { Thread.sleep(forTimeInterval: stepSeconds) }
                    if liveKeyWindowRefusal() == nil {
                        consecutiveClear += 1
                        if consecutiveClear >= clearReadsRequired { return true }
                    } else {
                        // A flicker back is a failed switch, not progress.
                        consecutiveClear = 0
                    }
                }
                return false
            }

            if !didActuate, !raiseAttempted, !background {
                raiseAttempted = true
                let outcome = accessibilityActSource.raise(actWindow)
                if outcome == .performed, raiseSettled() { return nil }
                // Raise did not take. Say so in the refusal rather than
                // repeating advice she already followed.
                inputRefusal = MacActClosedLoop.KeyWindowRefusal(
                    reason: inputRefusal.reason,
                    note: inputRefusal.note
                        + " Raising the window returned \(outcome.rawValue), but it did not remain key within 0.5s. Inspect the affected app with mac.look before continuing."
                        // The one raise failure with a fixable cause, when the
                        // source knows it: a missing Automation grant. Silence
                        // here would report "could not raise" for "you were
                        // never allowed to."
                        + (accessibilityActSource.raiseDiagnostic.map { " \($0)" } ?? "")
                )
            }
            // Background refusal preserves any delivered AX attempt; its return status cannot establish that nothing happened.
            if background {
                return MacActPerformed(
                    ok: false,
                    method: didActuate ? "ax_action" : "none",
                    requestedAction: requestedAction,
                    fallbackReason: inputRefusal.reason,
                    error: "needs_front",
                    target: target,
                    postState: didActuate ? accessibilityActSource.reread(target) : nil,
                    actedHandle: handle,
                    extra: [
                        "posted_events": .int(0),
                        "ax_delivered": .bool(didActuate),
                        "actuations_attempted": .array(actuationsAttempted.map { .string($0) }),
                        "needs_front_reason": .string(MacActClosedLoop.needsFrontReason(requestedAction)),
                    ]
                )
            }
            // Stop synthetic input after focus changes, while reporting any AX mutation already delivered and its unverified outcome.
            guard !didActuate else {
                return MacActPerformed(
                    ok: true,
                    method: "ax_action",
                    requestedAction: requestedAction,
                    fallbackReason: "key_window_changed_after_actuation",
                    error: nil,
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle,
                    extra: [
                        "posted_events": .int(0),
                        "actuations_attempted": .array(actuationsAttempted.map { .string($0) }),
                        "key_window_changed_after_actuation": .bool(true),
                        "guidance": .string(
                            "The Accessibility action was delivered, but this frame's window is no longer key or could not be confirmed key. No synthetic input was posted. Read effect for observed changes; the requested outcome remains unverified."
                        ),
                    ]
                )
            }
            return MacActPerformed(
                ok: false,
                method: "none",
                requestedAction: requestedAction,
                fallbackReason: inputRefusal.reason,
                error: inputRefusal.reason,
                target: target,
                postState: nil,
                actedHandle: handle,
                extra: [
                    "posted_events": .int(0),
                    "guidance": .string(inputRefusal.note),
                ]
            )
        }

        /// AXPress with the actuator's own synthesized-click fallback — the
        /// shared mechanism behind click / select / toggle, and behind the
        /// dismiss button once it has been found.
        func press(_ pressTarget: MacAXActTarget, actedHandle: String, extra: [String: JSONValue] = [:]) async -> MacActPerformed {
            // Pure AXPress retains background targeting; the actuator's synthesized click must pass the key-window gate at emission.
            var gateRefusal: MacActPerformed?
            let result = await MacAccessibilityActuator.act(
                source: accessibilityActSource,
                sink: eventSink,
                target: pressTarget,
                action: MacAccessibilityActuator.defaultAction,
                value: nil,
                syntheticFallbackGate: {
                    if let refusal = refuseInput(MacAccessibilityActuator.defaultAction) {
                        gateRefusal = refusal
                        return false
                    }
                    return true
                },
                emit: { await self.executeHand($0, action: "act", body: body).refusal?.error }
            )
            if let gateRefusal { return gateRefusal }
            return summarize(result, target: pressTarget, actedHandle: actedHandle, extra: extra, text: text)
        }

        if let refusal = MacWorkContinuation.current?.refusal() {
            return MacActPerformed(ok: false, method: "none", requestedAction: verb.rawValue,
                fallbackReason: nil, error: "continuation_unavailable", target: target,
                postState: nil, actedHandle: handle, extra: ["guidance": .string(refusal)])
        }
        switch verb {
        case .focus:
            let outcome = ledgeredSetFocused(target)
            return MacActPerformed(ok: outcome == .performed, method: outcome == .performed ? "ax_focus" : "none",
                requestedAction: "AXFocused", fallbackReason: nil,
                error: outcome == .performed ? nil : "focus_refused", target: target,
                postState: accessibilityActSource.reread(target), actedHandle: handle)
        case .click, .select, .toggle:
            // Background: pressing something whose job is to open a menu would
            // pop that menu over the person's screen. It needs the front.
            if background, ["AXMenuBarItem", "AXMenuButton", "AXPopUpButton"].contains(target.role) {
                return MacActPerformed(
                    ok: false, method: "none", requestedAction: MacAccessibilityActuator.defaultAction,
                    fallbackReason: "opens_a_menu", error: "needs_front", target: target,
                    postState: nil, actedHandle: handle,
                    extra: [
                        "posted_events": .int(0),
                        "needs_front_reason": .string("it opens a menu, and menus need the app in front"),
                    ]
                )
            }
            // One mechanism, three intentions. AXPress runs the app's OWN
            // handler — which is what "select this row" and "toggle this
            // checkbox" mean to the app — and the actuator falls back to a
            // synthesized click at the element's frame centre when the control
            // advertises no action, saying which one fired.
            return await press(target, actedHandle: handle)

        case .open:
            // Choose an open mechanism before mutating; an attempted AX action requires readback rather than another mutation.
            // Gate foreground work before the first actuation; background AXOpen retains its exact target.
            if !background, let refusal = refuseInput("AXOpen") { return refusal }

            if target.actions.contains("AXOpen") {
                let outcome = ledgeredPerform(target, action: "AXOpen")
                return MacActPerformed(
                    ok: outcome == .performed,
                    method: "ax_action",
                    requestedAction: "AXOpen",
                    fallbackReason: nil,
                    error: outcome == .performed ? nil : "ax_open_outcome_unknown",
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle,
                    extra: ["acted_on": MacActClosedLoop.OpenTargetResolution(
                        path: entry.path,
                        hops: 0,
                        role: target.role,
                        advertisesOpen: true,
                        reason: "handle_opened"
                    ).toJSON()]
                )
            }
            // The handle has no AXOpen. Resolve an implementation first.
            let openPlan = MacActClosedLoop.planOpenFallback(
                path: entry.path
            ) { ancestorPath in
                // The SAME window-anchored resolve the act itself used, so the
                // walk cannot reach another window or another app.
                guard case .resolved(let hit) = accessibilityActSource.resolve(
                    path: ancestorPath, inWindow: actWindow
                ) else { return nil }
                return (role: hit.role, actions: hit.actions)
            }

            /// Re-resolve a chosen ancestor and prove it is STILL what the walk
            /// chose. The named handle's drift guard ran before this function;
            /// an ancestor we climbed to has no guard of its own, so it gets one
            /// here. Nil ⇒ do not act on it.
            enum LiveAncestor {
                case live(MacAXActTarget)
                /// The path no longer resolves at all.
                case vanished
                /// It resolves, but is not the thing the walk chose.
                case drifted(found: String)

                var target: MacAXActTarget? {
                    if case .live(let hit) = self { return hit }
                    return nil
                }
                var refusalReason: String? {
                    switch self {
                    case .live: return nil
                    case .vanished: return "openable_ancestor_vanished"
                    case .drifted: return "openable_ancestor_drifted"
                    }
                }
            }
            func liveAncestor(_ choice: MacActClosedLoop.OpenTargetResolution) -> LiveAncestor {
                guard case .resolved(let hit) = accessibilityActSource.resolve(
                    path: choice.path, inWindow: actWindow
                ) else { return .vanished }
                guard hit.role == choice.role else { return .drifted(found: hit.role) }
                return .live(hit)
            }

            // Recheck focus after ancestor resolution and before actuation.
            if !background, let refusal = refuseInput("AXOpen") { return refusal }

            // 1. THE SEMANTIC PATH, any role. `AXUIElementPerformAction` does
            //    what the app says it does; it cannot land somewhere else, so a
            //    cell is a fine target for it.
            if let semantic = openPlan.semantic, let live = liveAncestor(semantic).target {
                // Record the attempt before inspecting the status; a failed AX reply leaves the effect unknown.
                let semanticOutcome: MacAXActOutcome? = live.actions.contains("AXOpen")
                    ? ledgeredPerform(live, action: "AXOpen")
                    : nil
                if let semanticOutcome {
                    return MacActPerformed(
                        ok: semanticOutcome == .performed,
                        method: "ax_action",
                        requestedAction: "AXOpen",
                        fallbackReason: nil,
                        error: semanticOutcome == .performed ? nil : "ax_open_outcome_unknown",
                        target: live,
                        postState: accessibilityActSource.reread(live),
                        actedHandle: handle,
                        extra: ["acted_on": semantic.toJSON()]
                    )
                }
            }

            // Double-click uses the row candidate, never a semantic cell whose text could enter rename mode.
            var openTarget = target
            var openResolutionReported = MacActClosedLoop.OpenTargetResolution(
                path: entry.path,
                hops: 0,
                role: target.role,
                advertisesOpen: target.actions.contains("AXOpen"),
                reason: openPlan.click == nil && openPlan.semantic == nil
                    ? "no_openable_ancestor"
                    : "fell_back_to_handle"
            )
            if let click = openPlan.click {
                let live = liveAncestor(click)
                guard let hit = live.target else {
                    // REFUSE, never revert. Falling back to the handle here
                    // would re-run the exact rename gesture this resolution
                    // exists to avoid, on a window that just changed under us.
                    // Nothing is performed and nothing is posted.
                    let reason = live.refusalReason ?? "openable_ancestor_vanished"
                    // `attempted_on` names the intended redirect; no actuation occurred.
                    var extra: [String: JSONValue] = ["attempted_on": click.toJSON()]
                    if case .drifted(let found) = live {
                        extra["openable_ancestor_drift"] = .object([
                            "expected_role": .string(click.role),
                            "found_role": .string(found),
                        ])
                    }
                    return MacActPerformed(
                        ok: false,
                        method: "none",
                        requestedAction: "AXOpen",
                        fallbackReason: reason,
                        error: reason,
                        target: target,
                        postState: accessibilityActSource.reread(target),
                        actedHandle: handle,
                        extra: extra
                    )
                }
                openTarget = hit
                openResolutionReported = click
            }
            // ALWAYS reported, redirect or not: an act that lands somewhere
            // other than the handle she named must never be silent.
            let openTargetJSON = openResolutionReported.toJSON()

            // Use a verified app-specific Open chord only after selecting the resolved row.
            if let chord = MacActClosedLoop.openCommandChord(forBundleId: frame.bundleId),
               eventSink.isAvailable {
                // Require a live openable row and gate before selection; selection itself is a visible mutation.
                if let refusal = refuseInput("AXOpen") { return refusal }
                let selectTarget = openPlan.click.flatMap { liveAncestor($0).target }
                let selectable = selectTarget.map {
                    MacActClosedLoop.openableAncestorRoles.contains($0.role)
                } ?? false
                let selected = selectable ? selectTarget.map(ledgeredSetSelected) ?? .unsupported : .unsupported
                if let selectTarget, selected == .performed {
                    // Recheck before the chord: selection can change focus, and any refusal must preserve that mutation in its receipt.
                    if let refusal = refuseInput("AXOpen") { return refusal }
                    let emission = await executeHand(MacHandRepertoire.chord(chord), action: "act", body: body)
                    if let refusal = emission.refusal { return MacActPerformed(ok: false, method: "select_and_open_command", requestedAction: "AXOpen", fallbackReason: nil, error: refusal.error, target: selectTarget, postState: accessibilityActSource.reread(selectTarget), actedHandle: handle) }
                    return MacActPerformed(
                        ok: true,
                        method: "select_and_open_command",
                        requestedAction: "AXOpen",
                        fallbackReason: "ax_open_unsupported_by_app",
                        error: nil,
                        target: selectTarget,
                        postState: accessibilityActSource.reread(selectTarget),
                        actedHandle: handle,
                        extra: [
                            "acted_on": openTargetJSON,
                            "open_command": .string(chord.source),
                            "selected_role": .string(selectTarget.role),
                        ]
                    )
                }
                if selected != .unsupported {
                    return MacActPerformed(ok: false, method: "ax_action", requestedAction: "AXSelected",
                        fallbackReason: nil, error: "selection_outcome_unknown", target: selectTarget ?? target,
                        postState: accessibilityActSource.reread(selectTarget ?? target), actedHandle: handle)
                }
            }

            let openFallbackReason = openTarget.actions.contains("AXOpen")
                ? "ax_action_refused"
                : "element_does_not_advertise_AXOpen"
            guard eventSink.isAvailable else {
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "AXOpen",
                    fallbackReason: openFallbackReason,
                    error: "event_injection_unavailable",
                    target: openTarget,
                    postState: accessibilityActSource.reread(openTarget),
                    actedHandle: handle,
                    extra: ["attempted_on": openTargetJSON]
                )
            }
            guard let centre = openTarget.centre else {
                // No frame, no honest place to double-click. Refused by name
                // rather than clicking the screen corner.
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "AXOpen",
                    fallbackReason: openFallbackReason,
                    error: "no_ax_open_and_no_frame",
                    target: openTarget,
                    postState: accessibilityActSource.reread(openTarget),
                    actedHandle: handle,
                    extra: ["attempted_on": openTargetJSON]
                )
            }
            if let refusal = refuseInput("AXOpen") { return refusal }
            let emission = await executeHand(MacHandRepertoire.click(button: .left, at: centre, count: 2), action: "act", body: body)
            return MacActPerformed(
                ok: emission.refusal == nil,
                method: "cgevent_double_click_fallback",
                requestedAction: "AXOpen",
                fallbackReason: openFallbackReason,
                error: emission.refusal?.error,
                target: openTarget,
                postState: accessibilityActSource.reread(openTarget),
                actedHandle: handle,
                extra: ["click_count": .int(2), "acted_on": openTargetJSON]
            )

        case .type:
            return await typeText(body: body, entry: entry, framePid: framePid, actWindow: actWindow,
                target: target, handle: handle, text: text, typeMode: typeMode, background: background,
                keystrokes: keystrokes, noteActuation: noteActuation, refuseInput: refuseInput,
                ledgeredSetFocused: ledgeredSetFocused)

        case .dismiss:
            // The modal's OWN Cancel/Close/Dismiss/Done/OK button, found in the
            // CURRENT frame and scoped by path prefix to the modal — a window
            // behind a sheet often has its own "Close", and pressing that would
            // act on the wrong surface entirely.
            // The press must answer to what she named: the named control itself
            // when it IS a Cancel/Close/Done/OK, else the dismiss button of the
            // SAME modal the named thing sits in. "dismiss Delete" never presses
            // some other modal's Cancel.
            let namedDismiss = MacActClosedLoop.normalizedLabel(entry.label).map {
                MacActClosedLoop.dismissLabels.contains($0.lowercased())
            } ?? false
            let sameModalDismiss: MacLookFrameEntry? = {
                if namedDismiss { return entry }
                guard let modalPath = frame.modalPath, entry.path.starts(with: modalPath) else { return nil }
                return MacActClosedLoop.dismissTarget(in: frame)
            }()
            if let dismissEntry = sameModalDismiss,
               case .resolved(let dismissTarget) = accessibilityActSource.resolve(
                   path: dismissEntry.path,
                   inWindow: actWindow
               ),
               MacActClosedLoop.driftReason(
                   expectedRole: dismissEntry.role,
                   expectedLabel: dismissEntry.label,
                   liveRole: dismissTarget.role,
                   liveTitle: dismissTarget.title,
                   liveValue: dismissTarget.value
               ) == nil {
                return await press(
                    dismissTarget,
                    actedHandle: dismissEntry.handle,
                    extra: [
                        "dismiss_target": .object([
                            "handle": .string(dismissEntry.handle),
                            "label": dismissEntry.label.map {
                                MacScreenViewTextRedaction.redactedLegendString(
                                    $0,
                                    valueChars: MacAXLimits.hardValueChars
                                )
                            } ?? .null,
                        ]),
                    ]
                )
            }
            // No button: the element's own AXCancel, if it advertises one.
            guard target.actions.contains("AXCancel") else { return nil }
            let outcome = ledgeredPerform(target, action: "AXCancel")
            return MacActPerformed(
                ok: outcome == .performed,
                method: outcome == .performed ? "ax_action" : "none",
                requestedAction: "AXCancel",
                fallbackReason: "no_dismiss_button_in_frame",
                error: outcome == .performed ? nil : "ax_action_\(outcome.rawValue)",
                target: target,
                postState: accessibilityActSource.reread(target),
                actedHandle: handle
            )

        case .scroll:
            // Directional wheel input lands at the target's centre when available.
            guard eventSink.isAvailable else {
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "scroll",
                    fallbackReason: nil,
                    error: "event_injection_unavailable",
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle
                )
            }
            if let refusal = refuseInput("scroll") { return refusal }
            // `down` moves the CONTENT up, which is what a human means by
            // scrolling down. Three lines: one notch of a physical wheel.
            let deltaY: Int32 = direction == .down ? -3 : 3
            let plan = (target.centre.map { MacHandRepertoire.move(to: $0) } ?? [])
                + MacHandRepertoire.scroll(dx: 0, dy: deltaY, unit: .line)
            let emission = await executeHand(plan, action: "act", body: body)
            return MacActPerformed(
                ok: emission.refusal == nil,
                method: "cgevent_scroll_fallback",
                requestedAction: "scroll",
                fallbackReason: nil,
                error: emission.refusal?.error,
                target: target,
                postState: accessibilityActSource.reread(target),
                actedHandle: handle,
                extra: [
                    "direction": .string(direction.rawValue),
                    "dy": .int(Int64(deltaY)),
                ]
            )
        }
    }
}

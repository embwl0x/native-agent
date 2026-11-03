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
// Blueprint: | `MacNativeAction.swift` | Native acts through the existing text-editing and hand owners; exact double/right click and hover retain the resolved element and per-event key-window gate; canonical effect verification |

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
            error: result.error,
            target: target,
            postState: result.postState,
            actedHandle: actedHandle,
            extra: extra.merging(result.outcome.receipt) { _, new in new },
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
        var didActuate = false
        var axOutcomes: [JSONValue] = []
        func recordAXOutcome(_ outcome: MacAXActOutcome) { axOutcomes.append(.object(outcome.receipt)) }
        var actuationsAttempted: [String] = []
        func noteActuation(_ action: String) {
            didActuate = true
            if !actuationsAttempted.contains(action) { actuationsAttempted.append(action) }
        }

        // Ledger every AX mutation before inspecting its return status: a failed reply does not prove no effect occurred.
        func ledgeredPerform(_ actTarget: MacAXActTarget, action: String) -> MacAXActOutcome {
            let outcome = accessibilityActSource.perform(actTarget, action: action)
            recordAXOutcome(outcome)
            if outcome.emissionAttempted { noteActuation(action) }
            return outcome
        }
        func ledgeredSetFocused(_ actTarget: MacAXActTarget) -> MacAXActOutcome {
            let outcome = accessibilityActSource.setFocused(actTarget)
            recordAXOutcome(outcome)
            if outcome.emissionAttempted { noteActuation("AXFocused") }
            return outcome
        }
        /// Read front/focus together and name both windows in a refusal.
        func liveKeyWindowRefusal() -> MacActClosedLoop.KeyWindowRefusal? {
            let frontmost = accessibilitySource.frontmostApp()
            let focused = accessibilityActSource.focusedWindow(pid: framePid)
            let appWindowCount: Int?
            do { appWindowCount = focused == nil ? try accessibilityActSource.windows(pid: framePid).count : nil }
            catch { return MacActClosedLoop.KeyWindowRefusal(reason: "window_evidence_unavailable", note: error.localizedDescription) }
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
                appWindowCount: appWindowCount
            )
        }

        func refuseInput(_ requestedAction: String) -> MacActPerformed? {
            if let refusal = MacWorkContinuation.current?.refusal() {
                return MacActPerformed(ok: false, method: "none", requestedAction: requestedAction,
                    error: "continuation_unavailable", target: target,
                    postState: nil, actedHandle: handle, extra: ["guidance": .string(refusal)])
            }
            // Reread at each emission boundary: intervening AX work can change focus, and the window server owns the remaining race.
            guard let inputRefusal = liveKeyWindowRefusal() else { return nil }

            // Background refusal preserves any delivered AX attempt; its return status cannot establish that nothing happened.
            if background {
                return MacActPerformed(
                    ok: false,
                    method: didActuate ? "ax_action" : "none",
                    requestedAction: requestedAction,
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

        /// Semantic presses use only the app's advertised AXPress handler.
        func press(_ pressTarget: MacAXActTarget, actedHandle: String, extra: [String: JSONValue] = [:]) async -> MacActPerformed {
            let result = await MacAccessibilityActuator.act(
                source: accessibilityActSource, target: pressTarget,
                action: MacAccessibilityActuator.defaultAction, value: nil
            )
            recordAXOutcome(result.outcome)
            if result.outcome.emissionAttempted { noteActuation(result.requestedAction) }
            return summarize(result, target: pressTarget, actedHandle: actedHandle, extra: extra, text: text)
        }

        let performed = await { () async -> MacActPerformed? in
        if let refusal = MacWorkContinuation.current?.refusal() {
            return MacActPerformed(ok: false, method: "none", requestedAction: verb.rawValue,
                error: "continuation_unavailable", target: target,
                postState: nil, actedHandle: handle, extra: ["guidance": .string(refusal)])
        }
        switch verb {
        case .doubleClick, .rightClick, .hover:
            // The handle's process/window/identity have already been resolved
            // by handleAct. Keep that element through the physical emission.
            guard target.enabled, eventSink.isAvailable else {
                return MacActPerformed(ok: false, method: "none", requestedAction: verb.rawValue,
                    error: target.enabled ? "event_injection_unavailable" : "element_disabled",
                    target: target, postState: nil, actedHandle: handle,
                    extra: ["posted_events": .int(0)])
            }
            guard let centre = target.centre, centre.x.isFinite, centre.y.isFinite else { return nil }
            if let refusal = refuseInput(verb.rawValue) { return refusal }
            noteActuation(verb.rawValue)
            let plan = verb == .hover ? MacHandRepertoire.hover(at: centre, dwellMs: 300)
                : MacHandRepertoire.click(button: verb == .rightClick ? .right : .left,
                    at: centre, count: verb == .doubleClick ? 2 : 1)
            let emission = await executeHand(plan, action: "act", body: body) { _ in
                if let refusal = refuseInput(verb.rawValue) {
                    return self.injectionRefusal(action: "act", error: refusal.error ?? "focus_moved")
                }
                return nil
            }
            return MacActPerformed(ok: emission.refusal == nil,
                method: "cgevent_\(verb.rawValue)", requestedAction: verb.rawValue,
                error: emission.refusal?.error, target: target,
                postState: accessibilityActSource.reread(target), actedHandle: handle,
                extra: ["posted_events": .int(Int64(emission.emitted))])
        case .focus:
            let outcome = ledgeredSetFocused(target)
            return MacActPerformed(ok: outcome == .performed, method: outcome == .performed ? "ax_focus" : "none",
                requestedAction: "AXFocused", error: outcome == .performed ? nil : "focus_refused", target: target,
                postState: accessibilityActSource.reread(target), actedHandle: handle)
        case .click, .select, .toggle:
            // Background: pressing something whose job is to open a menu would
            // pop that menu over the person's screen. It needs the front.
            if background, ["AXMenuBarItem", "AXMenuButton", "AXPopUpButton"].contains(target.role) {
                return MacActPerformed(
                    ok: false, method: "none", requestedAction: MacAccessibilityActuator.defaultAction,
                    error: "needs_front", target: target,
                    postState: nil, actedHandle: handle,
                    extra: [
                        "posted_events": .int(0),
                        "needs_front_reason": .string("it opens a menu, and menus need the app in front"),
                    ]
                )
            }
            // One semantic handler, three intentions; unsupported stays unsupported.
            return await press(target, actedHandle: handle)

        case .open:
            guard target.actions.contains("AXOpen") else {
                return MacActPerformed(ok: false, method: "none", requestedAction: "AXOpen",
                    error: "verb_not_supported_on_element", target: target,
                    postState: accessibilityActSource.reread(target), actedHandle: handle,
                    extra: ["posted_events": .int(0), "guidance": .string(
                        "This control does not advertise AXOpen. Inspect this app's controls and choose an observed supported action.")])
            }
            let outcome = ledgeredPerform(target, action: "AXOpen")
            return MacActPerformed(ok: outcome == .performed, method: "ax_action", requestedAction: "AXOpen",
                error: outcome == .performed ? nil : "ax_open_outcome_unknown",
                target: target, postState: accessibilityActSource.reread(target), actedHandle: handle)

        case .type:
            return await typeText(body: body, entry: entry, framePid: framePid, actWindow: actWindow,
                target: target, handle: handle, text: text, typeMode: typeMode, background: background,
                keystrokes: keystrokes, noteActuation: noteActuation, recordAXOutcome: recordAXOutcome, refuseInput: refuseInput,
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
            return MacActPerformed(ok: false, method: "none", requestedAction: "dismiss",
                error: "dismiss_target_unavailable", target: target,
                postState: accessibilityActSource.reread(target), actedHandle: handle,
                extra: ["posted_events": .int(0), "guidance": .string(
                    "The observed dismiss button is missing, unreadable or changed. Read this modal again before dismissing it.")])

        case .scroll:
            // Targeted wheel input requires a readable target centre.
            guard eventSink.isAvailable else {
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "scroll",
                    error: "event_injection_unavailable",
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle
                )
            }
            guard let centre = target.centre, centre.x.isFinite, centre.y.isFinite else {
                return MacActPerformed(ok: false, method: "none", requestedAction: "scroll",
                    error: "target_geometry_unavailable", target: target,
                    postState: accessibilityActSource.reread(target), actedHandle: handle,
                    extra: ["posted_events": .int(0), "guidance": .string(
                        "This scroll target has no readable frame. Read its window again before scrolling it.")])
            }
            if let refusal = refuseInput("scroll") { return refusal }
            // `down` moves the CONTENT up, which is what a human means by
            // scrolling down. Three lines: one notch of a physical wheel.
            let deltaY: Int32 = direction == .down ? -3 : 3
            let plan = MacHandRepertoire.move(to: centre)
                + MacHandRepertoire.scroll(dx: 0, dy: deltaY, unit: .line)
            let emission = await executeHand(plan, action: "act", body: body)
            return MacActPerformed(
                ok: emission.refusal == nil,
                method: "cgevent_scroll",
                requestedAction: "scroll",
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
        }()
        guard var performed else { return nil }
        if !axOutcomes.isEmpty { performed.extra["ax_outcomes"] = .array(axOutcomes) }
        return performed
    }
}

import Foundation
import NativeAgentShared
import NativeAgentCore
import TrustCenter
import PersistenceCore
import AppKit
import CoreGraphics
import UserNotifications
import ApplicationServices
import Senses
import Experiences
import os
import CoreText
import ScreenCaptureKit
// Blueprint: | `MacNativeAction.swift` | `SwiftNativeMacControl.performAct`, `NativeActLedger`: Native actions share text/hand owners, exact resolved targets, per-event focus checks and effect verification; one act's ledger is read by its verb stages (pointer, dismiss, scroll) |

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

    /// One native act's inputs and its actuation ledger (each AX outcome, each emission attempted), which the act's stages read and write and the
    /// act attaches at the end. Lives for one call and never crosses isolation.
    final class NativeActLedger {
        let body: [String: JSONValue]
        let verb: MacActVerb
        let handle: String
        let entry: MacLookFrameEntry
        let frame: MacLookFrame
        let framePid: Int32
        let actWindow: MacAXWindowRef
        let target: MacAXActTarget
        let text: String?
        let typeMode: MacTypeMode
        let direction: MacActScrollDirection
        let scrollAmount: Int
        let background: Bool
        let keystrokes: Bool
        var didActuate = false
        var axOutcomes: [JSONValue] = []
        var actuationsAttempted: [String] = []

        init(body: [String: JSONValue], verb: MacActVerb, handle: String, entry: MacLookFrameEntry, frame: MacLookFrame, framePid: Int32,
             actWindow: MacAXWindowRef, target: MacAXActTarget, text: String?, typeMode: MacTypeMode, direction: MacActScrollDirection,
             scrollAmount: Int, background: Bool, keystrokes: Bool) {
            self.body = body
            self.verb = verb
            self.handle = handle
            self.entry = entry
            self.frame = frame
            self.framePid = framePid
            self.actWindow = actWindow
            self.target = target
            self.text = text
            self.typeMode = typeMode
            self.direction = direction
            self.scrollAmount = scrollAmount
            self.background = background
            self.keystrokes = keystrokes
        }

        func recordAXOutcome(_ outcome: MacAXActOutcome) { axOutcomes.append(.object(outcome.receipt)) }
        func noteActuation(_ action: String) {
            didActuate = true
            if !actuationsAttempted.contains(action) { actuationsAttempted.append(action) }
        }
    }

    // Ledger every AX mutation before inspecting its return status: a failed reply does not prove no effect occurred.
    func ledgeredPerform(_ actTarget: MacAXActTarget, action: String, ledger: NativeActLedger, turn: Turn, context: MacOperationContext) -> MacAXActOutcome {
        let outcome = accessibilityActSource(context: context).perform(actTarget, action: action, turn: turn, context: context)
        ledger.recordAXOutcome(outcome)
        if outcome.emissionAttempted { ledger.noteActuation(action) }
        return outcome
    }
    func ledgeredSetFocused(_ actTarget: MacAXActTarget, ledger: NativeActLedger, turn: Turn, context: MacOperationContext) -> MacAXActOutcome {
        let outcome = accessibilityActSource(context: context).setFocused(actTarget, turn: turn, context: context)
        ledger.recordAXOutcome(outcome)
        if outcome.emissionAttempted { ledger.noteActuation("AXFocused") }
        return outcome
    }
    /// Read front/focus together and name both windows in a refusal.
    func liveKeyWindowRefusal(_ ledger: NativeActLedger, context: MacOperationContext) -> MacActClosedLoop.KeyWindowRefusal? {
        let frontmost = accessibilitySource(context: context).frontmostApp()
        let focused = accessibilityActSource(context: context).focusedWindow(pid: ledger.framePid, context: context)
        let appWindowCount: Int?
        do { appWindowCount = focused == nil ? try accessibilityActSource(context: context).windows(pid: ledger.framePid, context: context).count : nil }
        catch { return MacActClosedLoop.KeyWindowRefusal(reason: "window_evidence_unavailable", note: error.localizedDescription) }
        return MacActClosedLoop.keyWindowRefusal(
            framePid: ledger.framePid,
            frontmostPid: frontmost?.processIdentifier,
            frontmostName: frontmost?.name,
            frameWindowHandle: ledger.actWindow.handle,
            focusedWindowHandle: focused?.handle,
            frameWindowTitle: ledger.actWindow.identity.title,
            focusedWindowTitle: focused?.identity.title,
            // Count windows only when focus lacks identity; repeated enumeration would burden every emission gate.
            appWindowCount: appWindowCount
        )
    }

    func refuseInput(_ requestedAction: String, ledger: NativeActLedger, turn: Turn, context: MacOperationContext) -> MacActPerformed? {
        if let refusal = turn.macContinuation?.refusal(context: context) {
            return MacActPerformed(ok: false, method: "none", requestedAction: requestedAction,
                error: "continuation_unavailable", target: ledger.target,
                postState: nil, actedHandle: ledger.handle, extra: ["guidance": .string(refusal)])
        }
        // Reread at each emission boundary: intervening AX work can change focus, and the window server owns the remaining race.
        guard let inputRefusal = liveKeyWindowRefusal(ledger, context: context) else { return nil }

        // Background refusal preserves any delivered AX attempt; its return status cannot establish that nothing happened.
        if ledger.background {
            return MacActPerformed(
                ok: false,
                method: ledger.didActuate ? "ax_action" : "none",
                requestedAction: requestedAction,
                error: "needs_front",
                target: ledger.target,
                postState: ledger.didActuate ? accessibilityActSource(context: context).reread(ledger.target, context: context) : nil,
                actedHandle: ledger.handle,
                extra: [
                    "posted_events": .int(0),
                    "ax_delivered": .bool(ledger.didActuate),
                    "actuations_attempted": .array(ledger.actuationsAttempted.map { .string($0) }),
                    "needs_front_reason": .string(MacActClosedLoop.needsFrontReason(requestedAction)),
                    // Nothing posted and no AX action delivered: the refusal changed nothing.
                    "effects": .string(ledger.didActuate ? "unknown" : "none"),
                ]
            )
        }
        // Stop synthetic input after focus changes, while reporting any AX mutation already delivered and its unverified outcome.
        guard !ledger.didActuate else {
            return MacActPerformed(
                ok: true,
                method: "ax_action",
                requestedAction: requestedAction,
                error: nil,
                target: ledger.target,
                postState: accessibilityActSource(context: context).reread(ledger.target, context: context),
                actedHandle: ledger.handle,
                extra: [
                    "posted_events": .int(0),
                    "actuations_attempted": .array(ledger.actuationsAttempted.map { .string($0) }),
                    "key_window_changed_after_actuation": .bool(true),
                    "guidance": .string(
                        """
                            The Accessibility action was delivered, but this frame's window is no longer key or could not be confirmed key. No synthetic \
                            input was posted. Read effect for observed changes; the requested outcome remains unverified.
                            """
                    ),
                ]
            )
        }
        return MacActPerformed(
            ok: false,
            method: "none",
            requestedAction: requestedAction,
            error: inputRefusal.reason,
            target: ledger.target,
            postState: nil,
            actedHandle: ledger.handle,
            extra: [
                "posted_events": .int(0),
                "guidance": .string(inputRefusal.note),
            ]
        )
    }

    /// Semantic presses use only the app's advertised AXPress handler.
    func press(_ pressTarget: MacAXActTarget, actedHandle: String, extra: [String: JSONValue] = [:], ledger: NativeActLedger,
               turn: Turn, context: MacOperationContext) async -> MacActPerformed {
        let result = await MacAccessibilityActuator.act(
            source: accessibilityActSource(context: context), target: pressTarget,
            action: MacAccessibilityActuator.defaultAction, value: nil
        , turn: turn, context: context)
        ledger.recordAXOutcome(result.outcome)
        if result.outcome.emissionAttempted { ledger.noteActuation(result.requestedAction) }
        return summarize(result, target: pressTarget, actedHandle: actedHandle, extra: extra, text: ledger.text)
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
        scrollAmount: Int,
        /// Background acts never raise; sites needing the front refuse `needs_front`, while typing addresses the app through AX or pid.
        background: Bool = false,
        /// Search and submit handlers need real typing; AXSetValue alone may not invoke them.
        keystrokes: Bool = false,
        turn: Turn, context: MacOperationContext
    ) async -> MacActPerformed? {
        let ledger = NativeActLedger(body: body, verb: verb, handle: handle, entry: entry, frame: frame, framePid: framePid, actWindow: actWindow,
            target: target, text: text, typeMode: typeMode, direction: direction, scrollAmount: scrollAmount,
            background: background, keystrokes: keystrokes)

        guard var performed = await performVerb(ledger, turn: turn, context: context) else { return nil }
        if !ledger.axOutcomes.isEmpty { performed.extra["ax_outcomes"] = .array(ledger.axOutcomes) }
        return performed
    }

    /// The act's verb, run on the actor with its ledger; every reply returns through performAct's `ax_outcomes` attach.
    private func performVerb(_ ledger: NativeActLedger, turn: Turn, context: MacOperationContext) async -> MacActPerformed? {
        let body = ledger.body, verb = ledger.verb, handle = ledger.handle, entry = ledger.entry, framePid = ledger.framePid
        let actWindow = ledger.actWindow, target = ledger.target, text = ledger.text, typeMode = ledger.typeMode
        let background = ledger.background, keystrokes = ledger.keystrokes
        if let refusal = turn.macContinuation?.refusal(context: context) {
            return MacActPerformed(ok: false, method: "none", requestedAction: verb.rawValue,
                error: "continuation_unavailable", target: target,
                postState: nil, actedHandle: handle, extra: ["guidance": .string(refusal)])
        }
        switch verb {
        case .doubleClick, .rightClick, .hover:
            return await performPointer(ledger, turn: turn, context: context)
        case .focus:
            let outcome = ledgeredSetFocused(target, ledger: ledger, turn: turn, context: context)
            return MacActPerformed(ok: outcome == .performed, method: outcome == .performed ? "ax_focus" : "none",
                requestedAction: "AXFocused", error: outcome == .performed ? nil : "focus_refused", target: target,
                postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle)
        case .click, .select, .toggle:
            // Opening a background menu would cover the person’s screen, so it requires the front.
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
            return await press(target, actedHandle: handle, ledger: ledger, turn: turn, context: context)

        case .open:
            guard target.actions.contains("AXOpen") else {
                return MacActPerformed(ok: false, method: "none", requestedAction: "AXOpen",
                    error: "verb_not_supported_on_element", target: target,
                    postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle,
                    extra: ["posted_events": .int(0), "guidance": .string(
                        "This control does not advertise AXOpen. Inspect this app's controls and choose an observed supported action.")])
            }
            let outcome = ledgeredPerform(target, action: "AXOpen", ledger: ledger, turn: turn, context: context)
            return MacActPerformed(ok: outcome == .performed, method: "ax_action", requestedAction: "AXOpen",
                error: outcome == .performed ? nil : "ax_open_outcome_unknown",
                target: target, postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle)

        case .type:
            return await typeText(body: body, entry: entry, framePid: framePid, actWindow: actWindow, target: target, handle: handle, text: text,
                typeMode: typeMode, background: background, keystrokes: keystrokes, noteActuation: ledger.noteActuation, recordAXOutcome: ledger.recordAXOutcome,
                refuseInput: { self.refuseInput($0, ledger: ledger, turn: turn, context: context) }, turn: turn, context: context,
                ledgeredSetFocused: { self.ledgeredSetFocused($0, ledger: ledger, turn: turn, context: context) })

        case .dismiss:
            return await performDismiss(ledger, turn: turn, context: context)

        case .scroll:
            return await performScroll(ledger, turn: turn, context: context)
        }
    }

    /// Double-click, right-click and hover: physical pointer emission at the validated target's centre.
    func performPointer(_ ledger: NativeActLedger, turn: Turn, context: MacOperationContext) async -> MacActPerformed {
        // Keep the element already validated by handleAct through physical emission.
        guard ledger.target.enabled == true, eventSink.isAvailable else {
            return MacActPerformed(ok: false, method: "none", requestedAction: ledger.verb.rawValue,
                error: ledger.target.enabled == true ? "event_injection_unavailable" : "element_disabled",
                target: ledger.target, postState: nil, actedHandle: ledger.handle,
                extra: ["posted_events": .int(0)])
        }
        guard let centre = ledger.target.centre, centre.x.isFinite, centre.y.isFinite else {
            return MacActPerformed(ok: false, method: "none", requestedAction: ledger.verb.rawValue,
                error: "target_geometry_unavailable", target: ledger.target,
                postState: accessibilityActSource(context: context).reread(ledger.target, context: context), actedHandle: ledger.handle,
                extra: ["posted_events": .int(0), "guidance": .string(
                    "This target has no readable frame. Read its window again before a pointer action.")])
        }
        if let refusal = refuseInput(ledger.verb.rawValue, ledger: ledger, turn: turn, context: context) { return refusal }
        ledger.noteActuation(ledger.verb.rawValue)
        let plan = ledger.verb == .hover ? MacHandRepertoire.hover(at: centre, dwellMs: 300)
            : MacHandRepertoire.click(button: ledger.verb == .rightClick ? .right : .left,
                at: centre, count: ledger.verb == .doubleClick ? 2 : 1)
        let emission = await executeHand(plan, action: "act", body: ledger.body, turn: turn, context: context) { _ in
            if let refusal = self.refuseInput(ledger.verb.rawValue, ledger: ledger, turn: turn, context: context) {
                return self.injectionRefusal(action: "act", error: refusal.error ?? "focus_moved")
            }
            return nil
        }
        return MacActPerformed(ok: emission.refusal == nil,
            method: "cgevent_\(ledger.verb.rawValue)", requestedAction: ledger.verb.rawValue,
            error: emission.refusal?.error, target: ledger.target,
            postState: accessibilityActSource(context: context).reread(ledger.target, context: context), actedHandle: ledger.handle,
            extra: ["posted_events": .int(Int64(emission.emitted))])
    }

    /// Dismiss presses the named control or its own modal's observed dismiss button, revalidated live.
    func performDismiss(_ ledger: NativeActLedger, turn: Turn, context: MacOperationContext) async -> MacActPerformed {
        // Dismiss only the named control or its own modal’s dismiss button; a behind-sheet Close must never receive the press.
        let namedDismiss = MacActClosedLoop.normalizedLabel(ledger.entry.label).map {
            MacActClosedLoop.dismissLabels.contains($0.lowercased())
        } ?? false
        let sameModalDismiss: MacLookFrameEntry? = {
            if namedDismiss { return ledger.entry }
            guard let modalPath = ledger.frame.modalPath, ledger.entry.path.starts(with: modalPath) else { return nil }
            return MacActClosedLoop.dismissTarget(in: ledger.frame)
        }()
        if let dismissEntry = sameModalDismiss,
           case .resolved(let dismissTarget) = accessibilityActSource(context: context).resolve(
               path: dismissEntry.path,
               inWindow: ledger.actWindow
           , context: context),
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
            , ledger: ledger, turn: turn, context: context)
        }
        return MacActPerformed(ok: false, method: "none", requestedAction: "dismiss",
            error: "dismiss_target_unavailable", target: ledger.target,
            postState: accessibilityActSource(context: context).reread(ledger.target, context: context), actedHandle: ledger.handle,
            extra: ["posted_events": .int(0), "guidance": .string(
                "The observed dismiss button is missing, unreadable or changed. Read this modal again before dismissing it.")])
    }

    /// Scroll posts wheel input over the target's readable centre.
    func performScroll(_ ledger: NativeActLedger, turn: Turn, context: MacOperationContext) async -> MacActPerformed {
        // Targeted wheel input requires a readable target centre.
        guard eventSink.isAvailable else {
            return MacActPerformed(
                ok: false,
                method: "none",
                requestedAction: "scroll",
                error: "event_injection_unavailable",
                target: ledger.target,
                postState: accessibilityActSource(context: context).reread(ledger.target, context: context),
                actedHandle: ledger.handle
            )
        }
        guard let centre = ledger.target.centre, centre.x.isFinite, centre.y.isFinite else {
            return MacActPerformed(ok: false, method: "none", requestedAction: "scroll",
                error: "target_geometry_unavailable", target: ledger.target,
                postState: accessibilityActSource(context: context).reread(ledger.target, context: context), actedHandle: ledger.handle,
                extra: ["posted_events": .int(0), "guidance": .string(
                    "This scroll target has no readable frame. Read its window again before scrolling it.")])
        }
        if let refusal = refuseInput("scroll", ledger: ledger, turn: turn, context: context) { return refusal }
        // Three lines match one physical wheel notch when no amount is specified.
        let lines = Int32(ledger.scrollAmount == 0 ? 3 : ledger.scrollAmount)
        let (deltaX, deltaY): (Int32, Int32) = switch ledger.direction {
        case .up: (0, lines)
        case .down: (0, -lines)
        case .left: (lines, 0)
        case .right: (-lines, 0)
        }
        let plan = MacHandRepertoire.move(to: centre)
            + MacHandRepertoire.scroll(dx: deltaX, dy: deltaY, unit: .line)
        let emission = await executeHand(plan, action: "act", body: ledger.body, turn: turn, context: context)
        return MacActPerformed(
            ok: emission.refusal == nil,
            method: "cgevent_scroll",
            requestedAction: "scroll",
            error: emission.refusal?.error,
            target: ledger.target,
            postState: accessibilityActSource(context: context).reread(ledger.target, context: context),
            actedHandle: ledger.handle,
            extra: [
                "direction": .string(ledger.direction.rawValue),
                "dx": .int(Int64(deltaX)),
                "dy": .int(Int64(deltaY)),
            ]
        )
    }
}

import Foundation
import NativeAgentShared
import NativeAgentCore
import DeskCore
import PersistenceCore
import AppKit
import CoreGraphics
import UserNotifications
import SenseCore
// Blueprint: | `MacControl+ClosedLoopAction+Effect.swift` | `SwiftNativeMacControl`: `actEffectBaseline`, `installActObserver`, `actuateAct`, `settleActEffect`, `cleanupActText`, `composeActReceipt`, `reportActWithoutFrame`, `reportActFreshFrame` (baseline, observer, one forward actuation, event-paced verdict, and a text restore through ordinary act dispatch and receipt settlement) |

extension SwiftNativeMacControl {
    /// The effect baseline: the act's window as the fresh identity read saw it, under the presentation cap the settled read will use.
    func actEffectBaseline(_ body: [String: JSONValue], started: Date, frame: MacLookFrame, framePid: Int32, actWindow: MacAXWindowRef,
                           identityLimits: MacAXLimits, identityRead: MacAXRead, identityScoped: MacAXRead,
                           identityPercept: MacLookPercept) -> (effectAffordanceCap: Int, effectBefore: MacLookFrame) {
        // Identity comes from the retained observation; effect evidence starts NOW. Earlier batch steps must never prove this step's consequence. Identity
        // lookup is uncapped; effects use the same presentation cap on both sides so omitted controls cannot look like removals.
        let effectAffordanceCap = body["max_affordances"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacPerceptionCompiler.maxAffordances
        let effectPercept = frame.completeWindow ? identityPercept : MacPerceptionCompiler.compile(snapshot: identityScoped.snapshot,
            secretContext: MacScreenViewTextRedaction.nodeSecretContext(identityScoped.snapshot.nodes),
            app: identityScoped.app, windowTitle: identityScoped.rootTitle, focusPath: identityScoped.focusPath,
            maxAffordances: effectAffordanceCap)
        let effectBefore = MacLookFrame(frameId: frame.frameId, capturedAt: started,
            appName: frame.appName, bundleId: frame.bundleId, windowTitle: identityRead.rootTitle,
            entries: MacLookFrame.entries(from: effectPercept), pid: framePid,
            focusHandle: effectPercept.focus?.handle, hasModal: effectPercept.modal != nil,
            modalPath: effectPercept.modal?.path, readouts: MacLookFrame.readoutRecords(from: effectPercept),
            windowIdentity: actWindow.identity,
            caps: MacLookCompileCaps(truncated: effectPercept.truncated,
                maxAffordances: frame.completeWindow ? nil : effectAffordanceCap, maxNodes: frame.completeWindow ? nil : identityLimits.maxNodes,
                maxDepth: frame.completeWindow ? nil : identityLimits.maxDepth), completeWindow: frame.completeWindow)
        return (effectAffordanceCap, effectBefore)
    }

    /// Subscribe to the frame's process before acting; the caller stops the observation on every exit.
    func installActObserver(_ loop: MacClosedLoopAct) -> MacControlResult? {
        // Install observation before acting and stop it on every exit; an unavailable observer refuses before emission.
        let collector = loop.collector
        loop.observation = effectObserverSource.install(
                pid: loop.framePid,
                kinds: MacActClosedLoop.notificationKinds,
                onNotification: { [collector] notification in collector.record(notification) }
        )
        loop.observerInstalled = loop.observation != nil
        guard loop.observerInstalled else {
            return injectionRefusal(
                action: "act",
                error: "observer_unavailable",
                status: 409,
                extra: [
                    "effects": .string("none"),
                    "handle": .string(loop.handle),
                    "pid": .int(Int64(loop.framePid)),
                    "guidance": .string(
                        "no accessibility notification could be subscribed on that app, so the effect "
                        + "of this action could not be observed — NOTHING WAS ACTED ON. Check that the app "
                        + "is still running and try mac.look again."
                    ),
                ]
            )
        }
        return nil
    }

    /// Act once: report an effect already held, place a save-panel path, or perform the verb natively.
    func actuateAct(_ loop: MacClosedLoopAct, turn: Turn, context: MacOperationContext) async -> MacActPerformed? {
        let performed: MacActPerformed?
        let heldEffect: MacActClosedLoop.DeclaredEffect?
        switch loop.verb {
        case .focus: heldEffect = .focus
        case .select: heldEffect = .selected
        case .type where loop.typeMode == .replace && loop.placement == nil
            && turn.macContinuation?.isPending != true
            && MacActClosedLoop.replacesTextValue(role: loop.target.role)
            && (!loop.background || loop.body["keystrokes"] != .bool(true)): heldEffect = .text(loop.text)
        default: heldEffect = nil
        }
        let held = heldEffect.map {
            MacActClosedLoop.verify($0, value: loop.target.value,
                selected: loop.identityScoped.snapshot.nodes.first { $0.path == loop.live.path }?.attributes.selected,
                focused: accessibilityActSource(context: context).isFocusedElement(loop.target, pid: loop.framePid, context: context)
                    && accessibilityActSource(context: context).focusedWindow(pid: loop.framePid, context: context)?.handle == loop.actWindow.handle)
        }
        if held?.status == "acted" {
            performed = MacActPerformed(ok: true, method: "already_held", requestedAction: loop.verb.rawValue,
                target: loop.target, postState: loop.target, actedHandle: loop.handle,
                extra: ["already_held": .bool(true), "posted_events": .int(0)], expectedText: loop.verb == .type ? loop.text : nil)
        } else if let placement = loop.placement {
            performed = await placeInSavePanel(placement, target: loop.target, window: loop.actWindow, pid: loop.framePid,
                                              handle: loop.handle, frontBefore: loop.frontBefore, turn: turn, context: context)
        } else { performed = await performAct(
            body: loop.body, verb: loop.verb,
            handle: loop.handle,
            entry: loop.entry,
            frame: loop.effectBefore,
            framePid: loop.framePid,
            actWindow: loop.actWindow,
            target: loop.target,
            text: loop.text,
            typeMode: loop.typeMode,
            direction: loop.direction,
            scrollAmount: loop.scrollAmount,
            background: loop.background,
            keystrokes: loop.body["keystrokes"] == .bool(true)
        , turn: turn, context: context) }
        await screenViewStore.invalidate()
        return performed
    }

    /// The refusal when no mechanism performed the verb.
    func actMechanismRefusal(_ loop: MacClosedLoopAct) -> MacControlResult {
        // Missing mechanisms produce named refusals so unsupported verbs cannot report silent success.
        return injectionRefusal(
            action: "act",
            error: loop.verb == .dismiss ? "no_dismiss_target" : "verb_not_supported_on_element",
            status: 409,
            extra: [
                "verb": .string(loop.verb.rawValue),
                "handle": .string(loop.handle),
                "element": .object([
                    "role": .string(loop.target.role),
                    "actions": .array(loop.target.actions.map { .string($0) }),
                ]),
                "guidance": .string(
                    loop.verb == .dismiss
                        ? "no modal with a Cancel/Close/Dismiss/Done/OK button in this frame, and the "
                            + "element advertises no AXCancel — look again, or act on a specific handle"
                        : "this element exposes no mechanism for that verb"
                ),
            ]
        )
    }

    func settleActEffect(_ loop: MacClosedLoopAct, performed: MacActPerformed, textBeforeInput: String?, performedAt: Date, turn: Turn,
                         context: MacOperationContext) async -> (signals: MacWaitSignals, effectWaitMs: Int, limits: MacAXLimits) {
        // No notification within wait_ms is an unobserved outcome, never proof that the action failed or did nothing.
        // Navigation waits for a transition, not a selection reaction; explicit `wait_ms` overrides the bounded default.
        let navigationVerb = MacActClosedLoop.navigationVerbs.contains(loop.verb)
        let effectWaitMs = navigationVerb && loop.body["wait_ms"]?.integerValue.flatMap(Int.init(exactly:)) == nil
            ? MacActClosedLoop.clampedWaitMs(MacActClosedLoop.navigationWaitMs)
            : loop.waitMs
        let limits = Self.axLimits(from: loop.body)
        let declaration: MacActClosedLoop.DeclaredEffect
        switch loop.verb {
        case .hover: declaration = .pointer
        case .type: declaration = loop.placement.map { .placement($0, performed.extra["directory_url_after"]?.stringValue) } ?? .text(performed.expectedText)
        case .focus: declaration = .focus
        case .select: declaration = .selected
        case .toggle:
            declaration = .state(["0": "1", "1": "0", "off": "on", "on": "off",
                                  "true": "false", "false": "true"][performed.target.value ?? ""])
        case .dismiss: declaration = .dismissed
        case .scroll: declaration = .scroll
        default: declaration = .surface(loop.verb == .open ? loop.entry.label : nil)
        }
        let actedEntry = loop.entry
        // The read is an argument: the settle holds the only reference while it waits.
        func verdict(_ diff: MacActClosedLoop.EffectDiff?, selected: Bool? = nil, read: MacAXRead?) -> MacActClosedLoop.ActClassification {
            let entry = actedEntry
            let windowsAfter: [MacAXWindowRef]
            do { windowsAfter = try accessibilityActSource(context: context).windows(pid: loop.framePid, context: context) }
            catch { return MacActClosedLoop.ActClassification(status: "acted_unobserved", reason: "window_readback_unavailable",
                note: "The action was delivered, but its window readback failed: " + error.localizedDescription + " Inspect this app before another action.") }
            if loop.verb == .type, performed.method == "ax_set_value",
               let before = performed.textBeforeWrite, before != performed.expectedText,
               accessibilityActSource(context: context).reread(performed.target, context: context)?.value == before {
                return MacActClosedLoop.ActClassification(status: "acted_unobserved",
                    reason: "text_write_unverified",
                    note: "AX acknowledged the text write, but the value reads unchanged. Inspect the readback before another write.")
            }
            return MacActClosedLoop.verify(declaration,
                value: accessibilityActSource(context: context).reread(performed.target, context: context)?.value,
                valueBefore: performed.textBeforeWrite ?? textBeforeInput,
                selected: selected,
                focused: accessibilityActSource(context: context).focusedElement(pid: loop.framePid, context: context).flatMap { _ in
                    accessibilityActSource(context: context).focusedWindow(pid: loop.framePid, context: context).map {
                        accessibilityActSource(context: context).isFocusedElement(performed.target, pid: loop.framePid, context: context) && $0.handle == loop.actWindow
                            .handle
                    }
                },
                surfaceChanged: windowsAfter.contains { window in
                    !loop.actWindows.contains { $0.handle == window.handle }
                } ? true : nil,
                dismissed: accessibilityActSource(context: context).windowPresence(loop.actWindow, context: context).map { !$0 },
                processGone: accessibilitySource(context: context).appInfo(pid: loop.framePid) == nil,
                diff: diff, notifications: loop.collector.kinds(),
                pointerOnTarget: accessibilityActSource(context: context).reread(performed.target, context: context)?.frame.flatMap { frame in
                    self.pointerPositionSource.currentPosition().map { $0.isInside(frame) }
                },
                redactingText: loop.entrySecret,
                // A readout verifies only after an element-by-element stable reread.
                press: loop.verb == .click ? (loop.effectBefore, entry, { row in
                    guard let node = read?.snapshot.nodes.first(where: { $0.path == row.path }), let element = node.element,
                          let fresh = self.accessibilitySource(context: context).attributes(of: element, context: context) else { return false }
                    return fresh.value == node.attributes.value && fresh.title == node.attributes.title
                }) : nil,
                destinationJSON: entry.labelJSON ?? .null,
                windowTitleJSON: read?.rootTitle.map { MacScreenViewTextRedaction.redactedLegendString($0, valueChars: limits.valueChars) })
        }

        let signals = MacWaitSignals(collector: loop.collector, startedAt: performedAt)
        _ = await macSettle("act", signals: signals, patience: Double(effectWaitMs) / 1000,
            until: navigationVerb ? MacActClosedLoop.navigationNotificationKinds.union(loop.background ? ["AXMenuOpened"] : []) : []) {
            if loop.after == nil, loop.background, loop.collector.kinds().contains("AXMenuOpened"), loop.menuLeftOpen == nil {
                loop.menuLeftOpen = self.accessibilityActSource(context: context).perform(
                    performed.target, action: "AXCancel", turn: turn, context: context) != .performed
            }
            (loop.read, loop.seam, loop.postAnchor) = await self.lookSnapshot(
                limits: limits, scope: MacLookScope.parse(loop.body["scope"]?.stringValue) ?? .page,
                anchorPid: loop.framePid, anchorWindow: loop.frame.windowIdentity, completeWindow: loop.frame.completeWindow, context: context)
            loop.postEffect = nil
            if let read = loop.read, loop.seam["window_minimized"] != .bool(true) {
                let percept = MacPerceptionCompiler.compile(snapshot: read.snapshot,
                    secretContext: MacScreenViewTextRedaction.nodeSecretContext(read.snapshot.nodes),
                    app: read.app, windowTitle: read.rootTitle, focusPath: read.focusPath,
                    maxAffordances: loop.effectAffordanceCap, uncapped: loop.frame.completeWindow)
                let caps = MacLookCompileCaps(truncated: percept.truncated,
                    maxAffordances: loop.frame.completeWindow ? nil : loop.effectAffordanceCap,
                    maxNodes: loop.frame.completeWindow ? nil : limits.maxNodes, maxDepth: loop.frame.completeWindow ? nil : limits.maxDepth)
                let diff = MacActClosedLoop.diff(before: loop.effectBefore, after: percept, afterWindowTitle: read.rootTitle, afterCaps: caps)
                loop.postEffect = (percept, diff, caps)
            }
            loop.settledTarget = self.accessibilityActSource(context: context).reread(performed.target, context: context)
            if let after = loop.after {
                let value = self.observedDeedText(loop)
                loop.settledText = value
                let intrinsic = MacActClosedLoop.verify(declaration, value: value,
                    valueBefore: performed.textBeforeWrite ?? textBeforeInput, redactingText: true)
                let condition = MacActClosedLoop.verify(.textDigest(after), value: value)
                loop.afterVerdict = condition
                loop.settledVerdict = condition.status == "acted" ? intrinsic : condition
                return loop.settledVerdict.status == "acted"
                    || (condition.status == "acted_mismatch" && intrinsic.status == "acted")
            }
            loop.settledVerdict = verdict(loop.postEffect?.diff, selected: loop.read?.snapshot.nodes.first { $0.path == loop.live.path }?.attributes.selected, read: loop.read)
            return loop.settledVerdict.status == "acted" || loop.menuLeftOpen != nil
        }
        return (signals, effectWaitMs, limits)
    }

    static func deedTextIsReadable(_ value: String, at node: MacAXNode, in nodes: [MacAXNode]) -> Bool {
        let attributes = node.attributes
        guard attributes.role == "AXTextField", !attributes.labelUnreadable,
              !attributes.attributeGaps.contains(where: { $0.hasPrefix("AXValue:") }),
              !MacScreenViewBuilder.isSecretField(role: attributes.role, subrole: attributes.subrole, label: attributes.title, value: value) else { return false }
        let candidate = MacAXNode(attributes: MacAXAttributes(role: attributes.role, subrole: attributes.subrole,
            title: attributes.title, value: value, frame: attributes.frame, attributeGaps: attributes.attributeGaps), path: node.path)
        let captions = MacScreenViewTextRedaction.nodeSecretContext(nodes)
        let redacted = MacScreenViewTextRedaction.redactedNodeFields(candidate, context: captions)
        guard case .string(let visible)? = redacted["value"] else { return false }
        return visible.utf8.elementsEqual(value.utf8)
    }

    private func observedDeedText(_ loop: MacClosedLoopAct) -> String? {
        guard let nodes = loop.read?.snapshot.nodes, let percept = loop.postEffect?.percept,
              let entry = MacLookFrame.entries(from: percept).values.first(where: { $0.path == loop.live.path }),
              !entry.secret, !entry.ambiguous, let node = nodes.first(where: { $0.path == entry.path }),
              let target = loop.settledTarget, target.role == "AXTextField", let value = target.value,
              value.utf8.elementsEqual((node.attributes.value ?? "").utf8),
              Self.deedTextIsReadable(value, at: node, in: nodes) else { return nil }
        return value
    }

    func cleanupActText(_ loop: MacClosedLoopAct, performed: MacActPerformed, stop: URL?, turn: Turn,
                        context: MacOperationContext) async -> [String: JSONValue] {
        func skipped(_ reason: String, note: String? = nil) -> [String: JSONValue] {
            var receipt: [String: JSONValue] = ["ran": .bool(false), "verified": .bool(false),
                "status": .string("skipped"), "skipped_reason": .string(reason)]
            receipt["note"] = note.map(JSONValue.string)
            return receipt
        }
        let attempted = performed.extra["ax_emission_attempted"] == .bool(true)
        func stopped() -> [String: JSONValue] {
            skipped("stopped", note: attempted
                ? "The deed attempted a write. The field was left as it stood at Stop. Read it to confirm what landed."
                : "The deed attempted no value write before Stop.")
        }
        if Task.isCancelled || ChatCancelFlag.isRaised(stop) { return stopped() }
        guard performed.method == "ax_set_value", attempted,
              let previous = performed.textBeforeWrite,
              let written = performed.expectedText, !previous.utf8.elementsEqual(written.utf8) else { return skipped("no_reversible_write") }
        guard loop.afterVerdict?.status != "acted" else { return skipped("after_satisfied") }
        guard loop.afterVerdict?.status == "acted_mismatch" else { return skipped("after_unobserved") }
        guard loop.settledText?.utf8.elementsEqual(written.utf8) == true,
              let read = loop.read, let postEffect = loop.postEffect else {
            return skipped("write_not_held")
        }
        guard let driver = context.driver, driver.allowsAction(context: context) else { return skipped("act_authority_ended") }
        let frame = MacLookFrame.from(percept: postEffect.percept, frameId: UUID().uuidString, capturedAt: now(),
            windowTitle: read.rootTitle, windowIdentity: loop.actWindow.identity,
            caps: postEffect.caps, completeWindow: loop.frame.completeWindow)
        guard let entry = frame.entries.values.first(where: { $0.path == loop.live.path }),
              let app = frame.bundleId ?? frame.appName else { return skipped("restore_target_unobserved") }
        let body: [String: JSONValue] = [
            "verb": .string("type"), "mode": .string("replace"), "text": .string(previous),
            "handle": .string(entry.handle), "frame_id": .string(frame.frameId),
            "app": .string(app),
            "background": .bool(loop.background),
            "after": .object(["expect": .string("text"), "value": .string(SHA256Hex.of(utf8: previous))]),
        ]
        let restore = MacTextRestore(targetHandle: performed.target.handle, written: written)
        let inverseContext = context.with(\.batchFrames, [frame.frameId: frame]).with(\.capture, nil)
            .with(\.textRestore, restore).with(\.textDeedStop, stop)
        let traceBus = TurnTraceContext.bus
        let result: MacControlResult? = await withTaskCancellationHandler {
            await settle {
                guard !ChatCancelFlag.isRaised(stop), driver.allowsAction(context: inverseContext) else {
                    return nil
                }
                do {
                    return try await TurnTraceContext.$bus.withValue(traceBus) {
                        try await TurnTraceContext.$turnId.withValue(turn.id) {
                            try await self.dispatchActTextRestore(body, turn: turn, context: inverseContext)
                        }
                    }
                }
                catch { return MacControlResult(ok: false, action: "act", output: .object(["status": .string("outcome_unknown")]),
                    error: "restore_dispatch_unconfirmed", durationMs: 0) }
            }
        } onCancel: {
            driver.cancel()
        }
        guard let result else {
            if Task.isCancelled || ChatCancelFlag.isRaised(stop) { return stopped() }
            return skipped("act_authority_ended")
        }
        let reply = result.output.objectValue ?? [:]
        let bodyResult = reply["body_result"]?.objectValue?["output"]?.objectValue
        let output = bodyResult ?? reply
        let settlementFailed = reply["status"] == .string("settlement_failed")
        let unknown = reply["status"] == .string("outcome_unknown") || (settlementFailed && bodyResult == nil)
        let ran = output["ax_emission_attempted"] == .bool(true)
        var receipt: [String: JSONValue]
        if !ran, !unknown, Task.isCancelled || ChatCancelFlag.isRaised(stop) {
            receipt = stopped()
        } else {
            let status: JSONValue = unknown ? .string("outcome_unknown") : settlementFailed ? .string("settlement_failed")
                : ran ? output["status"] ?? .string("acted_unobserved") : .string("refused")
            receipt = ["ran": unknown ? .null : .bool(ran), "verified": .bool(ran && output["verified"] == .bool(true)), "status": status]
            receipt["note"] = settlementFailed ? result.error.map(JSONValue.string)
                : (output["status_note"]?.stringValue ?? output["ax_cause"]?.stringValue ?? result.error).map(JSONValue.string)
        }
        receipt["operation_id"] = result.operationId.map(JSONValue.string)
        return receipt
    }

    private func dispatchActTextRestore(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async throws -> MacControlResult {
        let response = try await dispatch(action: "act", body: body, turn: turn, context: context)
        guard response.output.objectValue?["status"] == .string("outcome_unknown"),
              let id = response.operationId, let operationStore else { return response }
        let key = MacControlInFlightRegistry.Key(store: operationStore.registryIdentity, operationId: id)
        guard let execution = MacControlInFlightRegistry.shared.execution(key: key) else { return response }
        do { try await execution.waitForSettlement() }
        catch { if let settled = execution.settledResult { return settled }; throw error }
        return execution.settledResult ?? response
    }

    /// Write the receipt both report forms share: what was observed, the acted element before and after, and how the act was delivered.
    func composeActReceipt(_ loop: MacClosedLoopAct, performed: MacActPerformed, performedAt: Date, effectWaitMs: Int, context: MacOperationContext) {
        loop.observation?.stop()
        let wait = MacActClosedLoop.effectWait(collector: loop.collector, startedAt: performedAt)
        let redactValue = loop.verb == .type
        loop.effect = [
            "observed": .bool(wait.observed),
            "observer_installed": .bool(loop.observerInstalled),
            "wait_ms": .int(Int64(effectWaitMs)),
            "notifications": .array(wait.notifications.map { .string($0) }),
            "notification_count": .int(Int64(wait.notificationCount)),
            "acted_element": .object([
                "handle": .string(performed.actedHandle),
                "before": MacActReceiptRendering.actedElementJSON(
                    performed.target,
                    redactingValue: redactValue || loop.entrySecret,
                    labelJSON: loop.entry.labelJSON,
                    valueJSON: loop.entry.valueJSON
                ),
                // Post-act reads lack caption context; preserve the frame's secret verdict and expose only a digest for values it withheld.
                "after": loop.settledTarget.map {
                    MacActReceiptRendering.actedElementJSON(
                        $0,
                        redactingValue: redactValue || loop.entrySecret,
                        labelJSON: loop.entrySecret ? loop.entry.labelJSON : nil
                    )
                } ?? .null,
            ]),
        ]
        if let firstMs = wait.firstNotificationMs {
            loop.effect["first_notification_ms"] = .int(Int64(firstMs))
        }
        // An unavailable observer refuses before action; an installed observer may honestly report no notifications inside `wait_ms`.
        if !wait.observed {
            loop.effect["reason"] = .string("none_observed")
        }

        loop.output = [
            "ok": .bool(performed.ok),
            // Delivery does not confirm an effect: seed the unobserved status until post-action readback supplies verification.
            "status": .string(performed.ok ? "acted_unobserved" : "failed"),
            "verb": .string(loop.verb.rawValue),
            "handle": .string(loop.handle),
            "performed": .bool(performed.ok),
            "method": .string(performed.method),
            "requested_action": .string(performed.requestedAction),
            "path": .array(loop.live.path.map { .int(Int64($0)) }),
            "seam": .object(loop.seam),
            // Leave the verdict unset until post-action evidence arrives.
            "verified": .bool(false),
            "value_redacted": .bool(redactValue),
        ]
        // Report positional ambiguity even when ordinal handles remain actionable.
        if loop.entry.ambiguous {
            loop.output["handle_ambiguous"] = .bool(true)
            loop.output["handle_ambiguity"] = .string(
                "that handle was a position-derived ordinal among identical elements — it names "
                + "whatever now sits at that position; re-look if the container may have reordered"
            )
        }
        for (key, value) in performed.extra { loop.output[key] = value }
        if let error = performed.error { loop.output["error"] = .string(error) }
        // Compare front-app reads so the receipt reports whether this act touched the person's screen.
        let frontAfter = accessibilitySource(context: context).frontmostApp()
        loop.output["front_app_changed"] = .bool(loop.frontBefore?.processIdentifier != frontAfter?.processIdentifier)
        loop.output["background"] = .bool(loop.background)
        if let menuLeftOpen = loop.menuLeftOpen {
            loop.output["menu_opened"] = .bool(true)
            loop.output["menu_left_open"] = .bool(menuLeftOpen)
        }
    }

    /// No fresh frame can be read: discard the old one and say why, with the verdict the settle reached.
    func reportActWithoutFrame(_ loop: MacClosedLoopAct, performed: MacActPerformed, framePredatesCleanup: Bool,
                               restoringText: Bool) async -> MacControlResult {
        if framePredatesCleanup {
            await lookFrameStore.discard(frameId: loop.frame.frameId)
        } else if !restoringText {
            await lookFrameStore.invalidate()
        }
        let (percept, note): (String, String) = {
            if framePredatesCleanup {
                return ("frame_predates_cleanup", "The deed's post-write frame predates cleanup. Read this window again before acting.")
            }
            if loop.seam["window_minimized"] == .bool(true) {
                let name = loop.read?.app?.name ?? "The app"
                return (
                    "window_minimized",
                    "\(name)'s window is minimized. go name:\"\(name)\" brings it back. "
                    + "Its menu bar still works: mac.act app:\"\(name)\" target:\"File > New\" makes a new window."
                )
            }
            switch loop.postAnchor {
            case .appGone?:
                return (
                    "frame_app_gone",
                    "the action ran, but the app you looked at no longer publishes a window — the old "
                    + "frame is discarded; call mac.look when it is back"
                )
            case .windowGone?:
                return (
                    "frame_window_gone",
                    "the action ran, and the window you looked at is gone (it closed, or the action closed "
                    + "it) — the old frame is discarded; call mac.look at whatever is up now"
                )
            case .windowDrifted(let reason)?:
                return (
                    "window_drifted:\(reason)",
                    "the action ran, but that app now has more than one window that could be the one "
                    + "you looked at, so nothing was re-read — the old frame is discarded; call "
                    + "mac.look to re-anchor"
                )
            case .rendererUnavailable(let reason)?:
                return ("renderer_accessibility_unavailable", "The action ran, but renderer accessibility could not be read back: " + reason)
            case .selfProcess?:
                return (
                    Self.selfInspectionError,
                    "the action ran, but the target now resolves to NativeAgent's own process, which "
                    + "AX must not re-read — the old frame is discarded; call mac.look at another "
                    + "app's window"
                )
            case .read?, nil:
                return (
                    "no_frontmost_window",
                    "the action ran, but there is no window to look at afterwards — the old frame is "
                    + "discarded; call mac.look when a window is up again"
                )
            }
        }()
        loop.effect["percept"] = .string(percept)
        if performed.ok || (loop.after != nil && performed.method == "ax_set_value") {
            let classification = loop.settledVerdict
            loop.output.merge(classification.receipt) { _, new in new }
            loop.effect["observed"] = .bool(classification.status != "acted_unobserved")
            loop.effect["reason"] = classification.reason.map(JSONValue.string)
        }
        loop.output["effect"] = .object(loop.effect)
        loop.output["frame_id"] = .null
        loop.output["frame_invalidated"] = .bool(true)
        loop.output["glance"] = .null
        loop.output["how_to_read"] = .string(note)
        return actResult(loop, performed: performed)
    }

    /// Report the diff and verdict, and publish a fresh frame compiled after the act so the next verb acts on what this one produced.
    func reportActFreshFrame(_ loop: MacClosedLoopAct, performed: MacActPerformed, read: MacAXRead,
                             postEffect: (percept: MacLookPercept, diff: MacActClosedLoop.EffectDiff, caps: MacLookCompileCaps),
                             limits: MacAXLimits, context: MacOperationContext) async -> MacControlResult {
        let after = postEffect.percept
        let diff = postEffect.diff
        for (key, value) in MacActReceiptRendering.effectDiffJSON(diff, valueChars: limits.valueChars) {
            loop.effect[key] = value
        }
        // One verdict from the declared effect and the target's own AX state.
        let classification = loop.settledVerdict
        let judged = performed.ok || (loop.after != nil && performed.method == "ax_set_value")
        if judged { loop.output.merge(classification.receipt) { _, new in new } }
        loop.effect["observed"] = .bool(judged && classification.status != "acted_unobserved")
        if let reason = classification.reason { loop.effect["reason"] = .string(reason) }
        else { loop.effect.removeValue(forKey: "reason") }
        // Bulk changes include role counts and focus context alongside capped rows.
        if diff.addedTotal > MacActClosedLoop.maxDiffRows {
            loop.effect["summary"] = MacActReceiptRendering.denseEffectSummaryJSON(
                diff: diff,
                after: after,
                snapshot: read.snapshot
            )
        }
        loop.output["effect"] = .object(loop.effect)
        if context.textRestore != nil { return actResult(loop, performed: performed) }

        // The verb's reply look reads this same post-effect walk (a timed-out walk is read afresh).
        if loop.frame.completeWindow, !read.snapshot.truncationReasons.contains("time_budget") {
            context.capture?.walked = (read, loop.seam)
            context.capture?.percept = after
        }

        // Publish a fresh frame so the next verb sees the state produced by this act.
        let capturedAt = now()
        let newFrameId = UUID().uuidString
        await lookFrameStore.record(MacLookFrame.from(
            percept: after,
            frameId: newFrameId,
            capturedAt: capturedAt,
            windowTitle: read.rootTitle,
            // Retain the acted-on window and refresh its identity so moves and retitles carry forward without switching surfaces.
            windowIdentity: read.windowIdentity ?? loop.frame.windowIdentity,
            caps: postEffect.caps,
            completeWindow: loop.frame.completeWindow
        ), context: context)
        loop.output["frame_id"] = .string(newFrameId)
        loop.output["captured_at"] = .string(NativeTimestampFormat.plainZulu(capturedAt))
        loop.output["frame_ttl_seconds"] = .int(Int64(MacLookFrameStore.ttlSeconds))
        // Lead the act's glance with the readout it changed, rather than the generic look ranking.
        loop.output["glance"] = .string(after.glanceLine(leading: MacActReceiptRendering.actedReadout(diff: diff, after: after)))
        loop.output["how_to_read"] = .string(
            "`effect` is what changed: the notifications the app fired, the acted element before/after, "
            + "`readouts_changed` (the read-only values — a total, a display, a status line — that moved, "
            + "which is where the ANSWER to what you just did usually is), and "
            + "the affordances added/removed/changed by handle. `frame_id` is a FRESH frame compiled after "
            + "the action — keep acting on handles from it. Handles from the previous frame are dead. You do "
            + "NOT need to call mac.look to find out whether this landed."
        )

        return actResult(loop, performed: performed)
    }

    private func actResult(_ loop: MacClosedLoopAct, performed: MacActPerformed) -> MacControlResult {
        let judgedDeed = loop.after != nil && (performed.method == "ax_set_value" || performed.method == "already_held")
        let verdict = loop.settledVerdict
        let ok = judgedDeed ? verdict.status == "acted" : performed.ok
        let error = judgedDeed ? (ok ? nil : verdict.reason ?? performed.error ?? verdict.status) : performed.error
        loop.output["ok"] = .bool(ok)
        loop.output["error"] = error.map(JSONValue.string)
        return MacControlResult(
            ok: ok,
            action: "act",
            output: .object(loop.output),
            error: error,
            durationMs: Int(now().timeIntervalSince(loop.started) * 1000)
        )
    }
}

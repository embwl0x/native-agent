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
#endif
// Blueprint: | `MacControl+ClosedLoopAction.swift` | `SwiftNativeMacControl`: `handleAct`, `pointerRestoredJSON` |

extension SwiftNativeMacControl {
    /// What one verb's mechanism did, before the effect is measured.
    struct MacActPerformed {
        var ok: Bool
        /// `ax_action` | `ax_set_value` | `cgevent_click_fallback` |
        /// `keystroke_injection` | `cgevent_scroll_fallback` | `none`
        var method: String
        var requestedAction: String
        var fallbackReason: String?
        var error: String?
        /// The element the verb actually acted ON. For `dismiss` this is the
        /// modal's button, not the handle she named.
        var target: MacAXActTarget
        var postState: MacAXActTarget?
        var actedHandle: String
        var extra: [String: JSONValue] = [:]
        var expectedText: String? = nil
    }

    /// `act` — perceive-act-verify in ONE call.
    ///
    /// Observe before acting, then return the declared-effect verdict and fresh
    /// percept together. Notifications wake the read; they do not prove its effect.
    ///
    /// Ordinary acts use policy, Full Mac, category, TCC and driver admission.
    /// Explicit approved replays also validate and consume a body-bound single-use
    /// capability. A frame/handle names a target and grants no authority.
    func handleAct(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()

        // 1. THE REQUEST. Every malformed field is refused, never defaulted:
        //    an act aimed at a guessed target is the failure this whole tool
        //    exists to prevent.
        guard let rawVerb = body["verb"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawVerb.isEmpty else {
            return injectionRefusal(
                action: "act",
                error: "missing required field: verb (one of \(MacActVerb.allCases.map(\.rawValue).joined(separator: ", ")))",
                status: 400
            )
        }
        guard let verb = MacActVerb(rawValue: rawVerb.lowercased()) else {
            return injectionRefusal(
                action: "act",
                error: "unknown_verb: \(rawVerb) is not one of "
                    + MacActVerb.allCases.map(\.rawValue).joined(separator: ", "),
                status: 400
            )
        }
        guard let handle = body["handle"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !handle.isEmpty else {
            return injectionRefusal(
                action: "act",
                error: "missing required field: handle (from the latest mac.look)",
                status: 400
            )
        }
        guard let frameId = body["frame_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !frameId.isEmpty else {
            return injectionRefusal(
                action: "act",
                error: "missing required field: frame_id (the frame_id mac.look returned with that handle)",
                status: 400
            )
        }
        let text = body["text"]?.stringValue
        let typeMode: MacTypeMode
        if let raw = body["mode"], raw != .null, raw != .string("") {
            guard case .string(let value) = raw, let parsed = MacTypeMode(rawValue: value),
                  parsed == .replace || verb == .type else {
                return injectionRefusal(action: "act", error: "invalid_type_mode: use replace or append; append requires type", status: 400)
            }
            typeMode = parsed
        } else {
            typeMode = .replace
        }
        if verb == .type, (text ?? "").isEmpty {
            return injectionRefusal(
                action: "act",
                error: "missing required field: text (verb \"type\" needs the characters to type)",
                status: 400
            )
        }
        let direction: MacActScrollDirection = {
            guard let raw = body["direction"]?.stringValue?.lowercased() else { return .down }
            return MacActScrollDirection(rawValue: raw) ?? .down
        }()
        if verb == .scroll, let raw = body["direction"]?.stringValue?.lowercased(),
           MacActScrollDirection(rawValue: raw) == nil {
            return injectionRefusal(
                action: "act",
                error: "unknown_direction: \(raw) — direction must be up or down",
                status: 400
            )
        }
        let waitMs = MacActClosedLoop.clampedWaitMs(body["wait_ms"]?.integerValue.flatMap(Int.init(exactly:)))
        // Anchored background AX actions stay in their app; work needing foreground input returns `needs_front` without raising.
        let background = body["background"] == .bool(true)
        let frontBefore = accessibilitySource.frontmostApp()

        // 2. HANDLE → PATH, through the frame store and its own failure
        //    vocabulary. Each failure names what to do next, because "that
        //    didn't work" with no reason is what sends a model into a retry
        //    loop against a screen that has moved on.
        let resolved = await lookFrameStore.resolve(handle: handle, frameId: frameId, now: started)
        let entry: MacLookFrameEntry
        switch resolved {
        case .failure(let failure):
            return injectionRefusal(
                action: "act",
                error: failure.rawValue,
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "frame_id": .string(frameId),
                    "guidance": .string(failure.guidance),
                ]
            )
        case .success(let hit):
            entry = hit
        }
        guard let frame = await lookFrameStore.frame(frameId: frameId) else {
            return injectionRefusal(
                action: "act",
                error: MacLookFrameStore.ResolveFailure.noFrame.rawValue,
                status: 409,
                extra: ["guidance": .string(MacLookFrameStore.ResolveFailure.noFrame.guidance)]
            )
        }

        // 3. THE SAME GATES `ax_act` clears. The TCC grant, then the human's
        //    physical priority.
        if let refusal = injectionPreconditions(action: "act", requiresSink: false) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "act", body: body) {
            return refusal
        }

        // Resolve only through the actuator in the frame's pid; frontmost-app changes must not retarget the action.
        guard let framePid = frame.pid else {
            return injectionRefusal(
                action: "act",
                error: "frame_app_gone",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "reason": .string("frame_recorded_no_pid"),
                    "guidance": .string(
                        "this frame recorded no process id, so the action cannot be anchored to the app "
                        + "you looked at — call mac.look again"
                    ),
                ]
            )
        }
        if let continuation = MacWorkContinuation.current, continuation.isPending,
           let captured = continuation.window {
            guard framePid == captured.pid, let observed = frame.windowIdentity,
                  observed.role == captured.role, observed.subrole == captured.subrole,
                  observed.title == captured.title, observed.frame == captured.frame else {
                return injectionRefusal(action: "act", error: "continuation_target_mismatch", status: 409,
                    extra: ["guidance": .string(continuation.modelContext)])
            }
        }
        // 4a½. A frame that names OUR OWN process (only possible from a store
        //      populated before the self-inspection fence shipped) must refuse
        //      BEFORE `windows(pid:)` or any other actuator call starts an AX
        //      transaction against ourselves — see `MacAnchoredRead.selfProcess`.
        if framePid == getpid() {
            await lookFrameStore.invalidate()
            return injectionRefusal(
                action: "act",
                error: Self.selfInspectionError,
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "reason": .string("cannot_act_on_own_process"),
                    "guidance": .string(
                        "this frame points at NativeAgent's own window, which AX must never touch — "
                        + "the frame is discarded; call mac.look at another app's window"
                    ),
                ]
            )
        }
        // Match the observed window by persistent identity; missing or ambiguous matches refuse instead of choosing current focus.
        let actWindows = accessibilityActSource.windows(pid: framePid)
        if actWindows.isEmpty, MacScreenLock.isLocked() {
            return injectionRefusal(
                action: "act",
                error: "display_obstructed",
                status: 409,
                extra: ["guidance": .string(MacScreenLock.reply)]
            )
        }
        guard !actWindows.isEmpty else {
            return injectionRefusal(
                action: "act",
                error: "frame_app_gone",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "reason": .string("app_publishes_no_window"),
                    "guidance": .string(
                        "the app this frame was captured from publishes no window any more — nothing "
                        + "was acted on; call mac.look again"
                    ),
                ]
            )
        }
        let actWindow: MacAXWindowRef
        if let recorded = frame.windowIdentity {
            switch MacAXWindowIdentity.match(
                recorded,
                among: actWindows.map { (handle: $0, identity: $0.identity) }
            ) {
            case .matched(let hit, _):
                actWindow = hit
            case .gone:
                return injectionRefusal(
                    action: "act",
                    error: "frame_window_gone",
                    status: 409,
                    extra: [
                        "handle": .string(handle),
                        "pid": .int(Int64(framePid)),
                        "window": recorded.toJSON(),
                        "windows_now": .int(Int64(actWindows.count)),
                        "guidance": .string(
                            "the window you looked at is not there any more (it closed, or the app "
                            + "replaced it) — NOTHING was acted on; call mac.look at whatever is up now"
                        ),
                    ]
                )
            case .ambiguous(let reason):
                return injectionRefusal(
                    action: "act",
                    error: "window_drifted",
                    status: 409,
                    extra: [
                        "handle": .string(handle),
                        "pid": .int(Int64(framePid)),
                        "drifted_on": .string(reason),
                        "window": recorded.toJSON(),
                        "windows_now": .int(Int64(actWindows.count)),
                        "guidance": .string(
                            "this app now has more than one window that could be the one you looked at, "
                            + "and acting on the wrong one is not recoverable — NOTHING was acted on; "
                            + "call mac.look to re-anchor"
                        ),
                    ]
                )
            }
        } else {
            // A frame recorded before the window anchor existed, or by a source
            // that cannot name a window. The pid anchor still holds and the act
            // proceeds; it is not silently claimed to be window-anchored.
            actWindow = actWindows[0]
        }

        let target: MacAXActTarget
        switch accessibilityActSource.resolve(path: entry.path, inWindow: actWindow) {
        case .resolved(let hit):
            target = hit
        case .windowGone:
            return injectionRefusal(
                action: "act",
                error: "frame_window_gone",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "guidance": .string(
                        "the window you looked at went away between matching it and resolving that "
                        + "handle — NOTHING was acted on; call mac.look again"
                    ),
                ]
            )
        case .appGone:
            return injectionRefusal(
                action: "act",
                error: "frame_app_gone",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "app": frame.appName.map { .string($0) } ?? .null,
                    "guidance": .string(
                        "the app this frame was captured from is no longer running (or publishes no "
                        + "window any more) — nothing was acted on; call mac.look again"
                    ),
                ]
            )
        case .pathNotFound, .menuPathDrifted:
            return injectionRefusal(
                action: "act",
                error: MacAccessibilityActuator.pathNotFoundError,
                status: 404,
                extra: [
                    "handle": .string(handle),
                    "path": .array(entry.path.map { .int(Int64($0)) }),
                    "pid": .int(Int64(framePid)),
                    "guidance": .string("the element that handle named is gone — call mac.look again"),
                ]
            )
        }

        let placement = verb == .type && MacSavePanelPlacement.isNameField(role: target.role, label: target.title)
            ? text.flatMap(MacSavePanelPlacement.split) : nil

        // 5. THE DRIFT GUARD. Between the look and the act the app may have
        //    rebuilt the window, and a child-index path would then address a
        //    DIFFERENT control. Pressing it would be "press Save" pressing
        //    "Delete". Never act on something she did not name.
        if let reason = MacActClosedLoop.driftReason(
            expectedRole: entry.role,
            expectedLabel: entry.label,
            liveRole: target.role,
            liveTitle: target.title,
            liveValue: target.value
        ) {
            return injectionRefusal(
                action: "act",
                error: "handle_drifted",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "drifted_on": .string(reason),
                    "expected": .object([
                        "role": .string(entry.role),
                        "label": entry.labelJSON ?? .null,
                    ]),
                    "found": .object([
                        "role": .string(target.role),
                        "label": (target.title ?? target.value).map {
                            MacInjectionResultRedaction.redactedSecret($0)
                        } ?? .null,
                    ]),
                    "guidance": .string(
                        "that handle no longer names the control it did — the window changed; call mac.look again"
                    ),
                ]
            )
        }

        // Recompile with the same walker/compiler and verify the rendered handle; positional identities also require stable cohort and geometry.
        let identityLimits = Self.axLimits(from: body)
        // Read the frame's window for identity verification; current focus may refer to another tree.
        let identityAnchor = anchoredSnapshot(
            limits: identityLimits,
            pid: framePid,
            window: frame.windowIdentity,
            complete: frame.completeWindow
        )
        let identityRead: MacAXRead
        switch identityAnchor {
        case .read(let hit):
            identityRead = hit
        case .appGone, .windowGone, .windowDrifted, .selfProcess:
            // Nothing to verify against and nothing to act on: the frame is
            // dead, so it must stop resolving handles as well.
            await lookFrameStore.invalidate()
            let (error, reason): (String, String) = {
                switch identityAnchor {
                case .windowGone: return ("frame_window_gone", "window_gone_before_verify")
                case .windowDrifted(let why): return ("window_drifted", why)
                case .selfProcess: return (Self.selfInspectionError, "cannot_act_on_own_process")
                default: return ("frame_app_gone", "no_window_to_verify_against")
                }
            }()
            return injectionRefusal(
                action: "act",
                error: error,
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "reason": .string(reason),
                    "guidance": .string(
                        "there is no window to re-check that handle against — NOTHING was acted on; "
                        + "call mac.look again"
                    ),
                ]
            )
        }
        // The SAME scoping the look ran under, or a page handle would be
        // compared against a window walk that never reaches the page and every
        // act on a web control would refuse as drift.
        let identityScoped = pageScoped(
            identityRead,
            limits: identityLimits,
            scope: MacLookScope.parse(body["scope"]?.stringValue) ?? .page,
            completeWindow: frame.completeWindow
        ).read
        let identityPercept = MacPerceptionCompiler.compile(
            snapshot: identityScoped.snapshot,
            secretContext: MacScreenViewTextRedaction.nodeSecretContext(identityScoped.snapshot.nodes),
            app: identityScoped.app,
            windowTitle: identityScoped.rootTitle,
            focusPath: identityScoped.focusPath,
            uncapped: true
        )
        // The live element is looked up in the SAME channels the frame entry
        // could have been minted from — affordances at that path, else the
        // recompiled FOCUS when the focus sits there. An unlabeled focused
        // control (Notes' empty note body) is never an affordance, so an
        // affordance-only lookup refused every act on it as `element_absent`.
        if let drift = MacActClosedLoop.identityDrift(
            entry: entry,
            live: MacActClosedLoop.liveIdentity(entry: entry, percept: identityPercept)
        ) {
            return injectionRefusal(
                action: "act",
                error: "handle_drifted",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "drifted_on": .string(drift.on),
                    "expected": .object([
                        "role": .string(entry.role),
                        "handle": .string(entry.handle),
                        "label": entry.labelJSON ?? entry.label.map {
                            MacScreenViewTextRedaction.redactedLegendString($0, valueChars: MacAXLimits.hardValueChars)
                        } ?? .null,
                    ]),
                    "found": drift.found,
                    "guidance": .string(
                        "the control at that position is no longer the one that handle named — the "
                        + "window changed under you; call mac.look again"
                    ),
                ]
            )
        }
        // A position-derived handle inside a list row: rows are recycled as
        // the list scrolls, so its position cannot prove which record it is.
        if entry.ambiguous, identityScoped.snapshot.nodes.contains(where: {
            MacLookHandle.contentIdentityRoles.contains($0.attributes.role) && entry.path.starts(with: $0.path)
        }) {
            return injectionRefusal(
                action: "act",
                error: "handle_ambiguous",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "guidance": .string(
                        "that control sits in a row that reads exactly like another row, so its position "
                        + "cannot prove which record it belongs to — NOTHING was acted on; name it by "
                        + "text that only its row shows"
                    ),
                ]
            )
        }

        // Install observation before acting and stop it on every exit; an unavailable observer refuses before emission.
        let collector = MacAXEffectCollector()
        let observation = effectObserverSource.install(
                pid: framePid,
                kinds: MacActClosedLoop.notificationKinds,
                onNotification: { [collector] notification in collector.record(notification) }
        )
        defer { observation?.stop() }
        let observerInstalled = observation != nil
        guard observerInstalled else {
            return injectionRefusal(
                action: "act",
                error: "observer_unavailable",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "guidance": .string(
                        "no accessibility notification could be subscribed on that app, so the effect "
                        + "of this action could not be observed — NOTHING WAS ACTED ON. Check that the app "
                        + "is still running and try mac.look again."
                    ),
                ]
            )
        }

        // 7. PERFORM.
        let performedAt = now()
        let performed: MacActPerformed?
        if let placement {
            performed = await placeInSavePanel(placement, target: target, window: actWindow, pid: framePid,
                                              handle: handle, frontBefore: frontBefore)
        } else { performed = await performAct(
            body: body, verb: verb,
            handle: handle,
            entry: entry,
            frame: frame,
            framePid: framePid,
            actWindow: actWindow,
            target: target,
            text: text,
            typeMode: typeMode,
            direction: direction,
            background: background,
            keystrokes: body["keystrokes"] == .bool(true)
        ) }
        await screenViewStore.invalidate()

        guard let performed else {
            // Only reachable for a verb whose mechanism does not exist on this
            // element — reported by name, never as a silent no-op.
            return injectionRefusal(
                action: "act",
                error: verb == .dismiss ? "no_dismiss_target" : "verb_not_supported_on_element",
                status: 409,
                extra: [
                    "verb": .string(verb.rawValue),
                    "handle": .string(handle),
                    "element": .object([
                        "role": .string(target.role),
                        "actions": .array(target.actions.map { .string($0) }),
                    ]),
                    "guidance": .string(
                        verb == .dismiss
                            ? "no modal with a Cancel/Close/Dismiss/Done/OK button in this frame, and the "
                                + "element advertises no AXCancel — look again, or act on a specific handle"
                            : "this element exposes no mechanism for that verb"
                    ),
                ]
            )
        }

        // 8. WAIT FOR THE EFFECT. Nothing arriving inside wait_ms is a REAL
        //    outcome, not a failure: it means this app published no
        //    notification, which the caller needs to know.
        let clock = now
        // Navigation waits for a transition, not a selection reaction; explicit `wait_ms` overrides the bounded default.
        let navigationVerb = MacActClosedLoop.navigationVerbs.contains(verb)
        let effectWaitMs = navigationVerb && body["wait_ms"]?.integerValue.flatMap(Int.init(exactly:)) == nil
            ? MacActClosedLoop.clampedWaitMs(MacActClosedLoop.navigationWaitMs)
            : waitMs
        let wait = await MacActClosedLoop.waitForEffect(
            collector: collector,
            waitMs: effectWaitMs,
            startedAt: performedAt,
            clock: { clock() },
            until: navigationVerb ? MacActClosedLoop.navigationNotificationKinds : []
        )
        observation?.stop()
        // Close a background-opened menu through its owning element and report whether it closed.
        var menuLeftOpen: Bool?
        if background, wait.notifications.contains("AXMenuOpened") {
            menuLeftOpen = accessibilityActSource.perform(performed.target, action: "AXCancel") != .performed
        }

        // 9. RE-COMPILE the same look percept and DIFF it against the frame.
        let limits = Self.axLimits(from: body)
        // Post-action readback stays anchored to the frame's window so its effect and next frame describe the acted-on surface.
        let (read, seam, postAnchor) = await lookSnapshot(
            limits: limits,
            scope: MacLookScope.parse(body["scope"]?.stringValue) ?? .page,
            anchorPid: framePid,
            anchorWindow: frame.windowIdentity,
            completeWindow: frame.completeWindow
        )
        let redactValue = verb == .type
                // Did `open` land on an ancestor of the handle she named? `acted_on`
        // is set by performAct only for the open verb, and only it knows.
        let actRedirected: Bool = {
            guard case .object(let actedOn)? = performed.extra["acted_on"],
                  case .bool(true)? = actedOn["redirected"] else { return false }
            return true
        }()
        var effect: [String: JSONValue] = [
            "observed": .bool(wait.observed),
            "observer_installed": .bool(observerInstalled),
            "wait_ms": .int(Int64(effectWaitMs)),
            "notifications": .array(wait.notifications.map { .string($0) }),
            "notification_count": .int(Int64(wait.notificationCount)),
            "acted_element": .object([
                "handle": .string(performed.actedHandle),
                // After a redirect, withhold the original entry's text; `acted_on` and the actual element carry the receipt and redaction.
                "before": MacActReceiptRendering.actedElementJSON(
                    performed.target,
                    redactingValue: redactValue || entry.secret,
                    labelJSON: actRedirected ? nil : entry.labelJSON,
                    valueJSON: actRedirected ? nil : entry.valueJSON
                ),
                // The post-act read carries NO compile context, so a value the
                // look hid would come back in the clear here. The frame's own
                // verdict decides: secret before ⇒ secret after, digest only.
                "after": performed.postState.map {
                    MacActReceiptRendering.actedElementJSON(
                        $0,
                        redactingValue: redactValue || entry.secret,
                        labelJSON: (entry.secret && !actRedirected) ? entry.labelJSON : nil
                    )
                } ?? .null,
            ]),
        ]
        if let firstMs = wait.firstNotificationMs {
            effect["first_notification_ms"] = .int(Int64(firstMs))
        }
        if wait.dropped > 0 { effect["notifications_dropped"] = .int(Int64(wait.dropped)) }
        // An unavailable observer refuses before action; an installed observer may honestly report no notifications inside `wait_ms`.
        if !wait.observed {
            effect["reason"] = .string("none_observed")
        }

        var output: [String: JSONValue] = [
            "ok": .bool(performed.ok),
            // Delivery does not confirm an effect: seed the unobserved status until post-action readback supplies verification.
            "status": .string(performed.ok ? "acted_unobserved" : "failed"),
            "verb": .string(verb.rawValue),
            "handle": .string(handle),
            "performed": .bool(performed.ok),
            "method": .string(performed.method),
            "requested_action": .string(performed.requestedAction),
            "path": .array(entry.path.map { .int(Int64($0)) }),
            "seam": .object(seam),
            // Until the post-action read supplies evidence there is no verdict.
            "verified": .bool(false),
            "value_redacted": .bool(redactValue),
        ]
        output["fallback_reason"] = performed.fallbackReason.map { .string($0) } ?? .null
        // Ordinal handles remain actionable but report their positional ambiguity.
        if entry.ambiguous {
            output["handle_ambiguous"] = .bool(true)
            output["handle_ambiguity"] = .string(
                "that handle was a position-derived ordinal among identical elements — it names "
                + "whatever now sits at that position; re-look if the container may have reordered"
            )
        }
        for (key, value) in performed.extra { output[key] = value }
        if let error = performed.error { output["error"] = .string(error) }
        // Whether the person's front app moved during this act — the proof
        // flag for "User's screen touched".
        let frontAfter = accessibilitySource.frontmostApp()
        output["front_app_changed"] = .bool(frontBefore?.processIdentifier != frontAfter?.processIdentifier)
        output["background"] = .bool(background)
        if let menuLeftOpen {
            output["menu_opened"] = .bool(true)
            output["menu_left_open"] = .bool(menuLeftOpen)
        }

        let declaration: MacActClosedLoop.DeclaredEffect
        switch verb {
        case .type: declaration = placement.map { .placement($0, performed.extra["where_after"]?.stringValue) } ?? .text(performed.expectedText)
        case .focus: declaration = .focus
        case .select: declaration = .selected
        case .toggle:
            declaration = .state(["0": "1", "1": "0", "off": "on", "on": "off",
                                  "true": "false", "false": "true"][performed.target.value ?? ""])
        case .dismiss: declaration = .dismissed
        case .scroll: declaration = .scroll
        default: declaration = .surface(verb == .open ? entry.label : nil)
        }
        func verdict(_ diff: MacActClosedLoop.EffectDiff?, selected: Bool? = nil) -> MacActClosedLoop.ActClassification {
            MacActClosedLoop.verify(declaration,
                value: accessibilityActSource.reread(performed.target)?.value,
                selected: selected,
                focused: accessibilityActSource.focusedElement(pid: framePid).flatMap { _ in
                    accessibilityActSource.focusedWindow(pid: framePid).map {
                        accessibilityActSource.isFocusedElement(performed.target, pid: framePid) && $0.handle == actWindow.handle
                    }
                },
                surfaceChanged: accessibilityActSource.windows(pid: framePid).contains { window in
                    !actWindows.contains { $0.handle == window.handle }
                } ? true : nil,
                dismissed: accessibilityActSource.windowPresence(actWindow).map { !$0 },
                processGone: accessibilitySource.appInfo(pid: framePid) == nil,
                diff: diff, notifications: wait.notifications, redactingText: entry.secret,
                // A readout counts once it reads the same again, element by element.
                press: verb == .click ? (frame, entry, { row in
                    guard let node = read?.snapshot.nodes.first(where: { $0.path == row.path }), let element = node.element,
                          let fresh = self.accessibilitySource.attributes(of: element) else { return false }
                    return fresh.value == node.attributes.value && fresh.title == node.attributes.title
                }) : nil,
                destinationJSON: entry.labelJSON ?? .null, windowTitleJSON: effect["window_title"])
        }

        guard let read, seam["window_minimized"] != .bool(true) else {
            // An absent or minimized window cannot supply a fresh frame; invalidate it and name the app/window identity failure.
            await lookFrameStore.invalidate()
            let (percept, note): (String, String) = {
                if seam["window_minimized"] == .bool(true) {
                    let name = read?.app?.name ?? "The app"
                    return (
                        "window_minimized",
                        "\(name)'s window is minimized. go name:\"\(name)\" brings it back. "
                        + "Its menu bar still works: mac.act app:\"\(name)\" target:\"File > New\" makes a new window."
                    )
                }
                switch postAnchor {
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
            effect["percept"] = .string(percept)
            if performed.ok {
                let classification = verdict(nil)
                output.merge(classification.receipt) { _, new in new }
                effect["observed"] = .bool(classification.status != "acted_unobserved")
                effect["reason"] = classification.reason.map(JSONValue.string)
            }
            output["effect"] = .object(effect)
            output["frame_id"] = .null
            output["frame_invalidated"] = .bool(true)
            output["glance"] = .null
            output["how_to_read"] = .string(note)
            return MacControlResult(
                ok: performed.ok,
                action: "act",
                output: .object(output),
                error: performed.error,
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }

        let after = MacPerceptionCompiler.compile(
            snapshot: read.snapshot,
            secretContext: MacScreenViewTextRedaction.nodeSecretContext(read.snapshot.nodes),
            app: read.app,
            windowTitle: read.rootTitle,
            // Same read epoch as the post-act walk, anchored to its root.
            focusPath: read.focusPath,
            maxAffordances: body["max_affordances"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacPerceptionCompiler.maxAffordances,
            uncapped: frame.completeWindow
        )
        // Record compile bounds so census comparison cannot mistake truncation for navigation.
        let afterCaps = MacLookCompileCaps(
            truncated: after.truncated,
            maxAffordances: frame.completeWindow ? nil : body["max_affordances"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacPerceptionCompiler.maxAffordances,
            maxNodes: frame.completeWindow ? nil : limits.maxNodes,
            maxDepth: frame.completeWindow ? nil : limits.maxDepth
        )
        let diff = MacActClosedLoop.diff(
            before: frame,
            after: after,
            afterWindowTitle: read.rootTitle,
            afterCaps: afterCaps
        )
        for (key, value) in MacActReceiptRendering.effectDiffJSON(diff, valueChars: limits.valueChars) {
            effect[key] = value
        }
        // One verdict from the declared effect and the target's own AX state.
        let classification = verdict(diff, selected: read.snapshot.nodes.first { $0.path == entry.path }?.attributes.selected)
        if performed.ok { output.merge(classification.receipt) { _, new in new } }
        effect["observed"] = .bool(performed.ok && classification.status != "acted_unobserved")
        if let reason = classification.reason { effect["reason"] = .string(reason) }
        else { effect.removeValue(forKey: "reason") }
        // Bulk or dropped-event changes include role counts and focus context alongside capped rows.
        if diff.addedTotal > MacActClosedLoop.maxDiffRows || wait.dropped > 0 {
            effect["summary"] = MacActReceiptRendering.denseEffectSummaryJSON(
                diff: diff,
                after: after,
                snapshot: read.snapshot,
                valueChars: limits.valueChars
            )
        }
        output["effect"] = .object(effect)

        // The verb's reply look reads this same post-effect walk (a timed-out walk is read afresh).
        if frame.completeWindow, !read.snapshot.truncationReasons.contains("time_budget") {
            MacSightCaptureBinding.current?.walked = (read, seam)
            MacSightCaptureBinding.current?.percept = after
        }

        // 10. A NEW FRAME, so the next verb continues from the state the act
        //     produced instead of from a description of the screen before it.
        let capturedAt = now()
        let newFrameId = UUID().uuidString
        await lookFrameStore.record(MacLookFrame.from(
            percept: after,
            frameId: newFrameId,
            capturedAt: capturedAt,
            windowTitle: read.rootTitle,
            // The new frame is anchored to the window the ACT happened in —
            // the same window the read above was anchored to, re-read fresh so
            // a moved or retitled window carries its new identity forward.
            windowIdentity: read.windowIdentity ?? frame.windowIdentity,
            caps: afterCaps,
            completeWindow: frame.completeWindow
        ))
        output["frame_id"] = .string(newFrameId)
        output["captured_at"] = .string(NativeTimestampFormat.plainZulu(capturedAt))
        output["frame_ttl_seconds"] = .int(Int64(MacLookFrameStore.ttlSeconds))
        // Lead the act's glance with the readout it changed, rather than the generic look ranking.
        output["glance"] = .string(after.glanceLine(leading: MacActReceiptRendering.actedReadout(diff: diff, after: after)))
        output["how_to_read"] = .string(
            "`effect` is what changed: the notifications the app fired, the acted element before/after, "
            + "`readouts_changed` (the read-only values — a total, a display, a status line — that moved, "
            + "which is where the ANSWER to what you just did usually is), and "
            + "the affordances added/removed/changed by handle. `frame_id` is a FRESH frame compiled after "
            + "the action — keep acting on handles from it. Handles from the previous frame are dead. You do "
            + "NOT need to call mac.look to find out whether this landed."
        )

        return MacControlResult(
            ok: performed.ok,
            action: "act",
            output: .object(output),
            error: performed.error,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }

    /// Plan and run ONE verb. Every mechanism here is an EXISTING one:
    /// `MacAccessibilityActuator.act` (which owns the AXPress → synthesized
    /// click fallback), the actuator's own `perform`, and `MacHandRepertoire` +
    /// the event sink (the same path `mac_keystroke` / `mac_scroll` use).
    /// Nothing new posts events and nothing new mutates AX.
    ///
    /// Returns nil when the element exposes NO mechanism for the verb — the
    /// caller turns that into a named refusal, never a silent no-op.
    /// Did the pointer end where it started? Computed from the two READS, so a
    /// nudge that failed to return the cursor cannot report success — and a
    /// null (either position unreadable) stays null rather than collapsing to
    /// `true`.
    ///
    /// SUB-PIXEL tolerance, not one pixel. The nudge's displacement IS one
    /// pixel, so a 1.0 slack would call "moved one pixel and stayed there" a
    /// successful restore — the precise failure this exists to catch. Only
    /// float noise is forgiven; any real displacement, including the user's own
    /// hand during the settle wait, reads `false`, which is the truth.
    static func pointerRestoredJSON(before: MacSessionState, after: MacSessionState) -> JSONValue {
        guard let bx = before.cursorX, let by = before.cursorY,
              let ax = after.cursorX, let ay = after.cursorY else { return .null }
        return .bool(abs(ax - bx) < 0.5 && abs(ay - by) < 0.5)
    }
}

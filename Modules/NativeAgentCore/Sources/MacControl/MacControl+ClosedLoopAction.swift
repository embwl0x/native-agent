import Foundation
import NativeAgentCore
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

extension SwiftNativeMacControl {
    /// What one verb's mechanism did, before the effect is measured.
    private struct MacActPerformed {
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
    }

    /// `act` — perceive-act-verify in ONE call.
    ///
    /// The whole point of native-look item 3: today a computer-use step costs
    /// three model turns (look, act, look again) and only the middle one is a
    /// decision. This installs an AXObserver on the target app BEFORE it acts,
    /// performs the verb, waits for the first notification plus an 80 ms quiet
    /// window, re-compiles the look percept and DIFFS it against the frame she
    /// acted from — and returns what changed, plus a NEW frame, in the same
    /// result. The model never has to look again to learn whether it landed.
    ///
    /// GATES: identical to `ax_act`. It is in
    /// `macControlAccessibilityInjectionActions`, so `dispatchCore` demands a
    /// body-bound single-use `MacInjectionCapability`; `gatePreflightOutcome`
    /// demands the accessibility category and an ACTIVE Full Mac window; and
    /// `injectionPreconditions` demands the macOS TCC grant. A handle grants NO
    /// authority — it only names a better target for an act that already
    /// cleared every one of those.
    func handleAct(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()

        // 1. THE REQUEST. Every malformed field is refused, never defaulted:
        //    an act aimed at a guessed target is the failure this whole tool
        //    exists to prevent.
        guard let rawVerb = body.stringValue("verb")?.trimmingCharacters(in: .whitespacesAndNewlines),
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
        guard let handle = body.stringValue("handle")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !handle.isEmpty else {
            return injectionRefusal(
                action: "act",
                error: "missing required field: handle (from the latest mac_look)",
                status: 400
            )
        }
        guard let frameId = body.stringValue("frame_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !frameId.isEmpty else {
            return injectionRefusal(
                action: "act",
                error: "missing required field: frame_id (the frame_id mac_look returned with that handle)",
                status: 400
            )
        }
        let text = body.stringValue("text")
        if verb == .type, (text ?? "").isEmpty {
            return injectionRefusal(
                action: "act",
                error: "missing required field: text (verb \"type\" needs the characters to type)",
                status: 400
            )
        }
        let direction: MacActScrollDirection = {
            guard let raw = body.stringValue("direction")?.lowercased() else { return .down }
            return MacActScrollDirection(rawValue: raw) ?? .down
        }()
        if verb == .scroll, let raw = body.stringValue("direction")?.lowercased(),
           MacActScrollDirection(rawValue: raw) == nil {
            return injectionRefusal(
                action: "act",
                error: "unknown_direction: \(raw) — direction must be up or down",
                status: 400
            )
        }
        let waitMs = MacActClosedLoop.clampedWaitMs(Self.intValue(body, "wait_ms"))

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

        // 4. LIVE RESOLVE — through the ACTUATOR's resolver, never a second
        //    one, and ANCHORED TO THE FRAME'S PID (gpt-5.5 round-2 B2).
        //
        //    The old resolve walked `NSWorkspace.frontmostApplication` while the
        //    effect observer went on the FRAME's pid: if anything stole front
        //    between the look and the act, the same path/role/label could name a
        //    plausible control in the WRONG app and the verb fired there, with
        //    an observer watching an app that never moved. The pid she looked at
        //    is the only app this may touch.
        guard let framePid = frame.pid else {
            return injectionRefusal(
                action: "act",
                error: "frame_app_gone",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "reason": .string("frame_recorded_no_pid"),
                    "guidance": .string(
                        "this frame recorded no process id, so the act cannot be anchored to the app "
                        + "you looked at — call mac_look again"
                    ),
                ]
            )
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
                        + "the frame is discarded; call mac_look at another app's window"
                    ),
                ]
            )
        }
        // 4b. …AND TO THE FRAME'S WINDOW (gpt-5.5 round-3 B1).
        //
        //     The pid anchor was necessary and not sufficient: inside the right
        //     app the resolve still took "focused, else main, else first", so
        //     two windows of one app plus a focus change between the look and
        //     the act put the verb in the WRONG window while every pid check
        //     passed. The window she looked at is matched by an identity that
        //     outlives the element handle — pid + role/subrole + title + rect +
        //     window index — and no match, or an ambiguous one, REFUSES.
        let actWindows = accessibilityActSource.windows(pid: framePid)
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
                        + "was acted on; call mac_look again"
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
                            + "replaced it) — NOTHING was acted on; call mac_look at whatever is up now"
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
                            + "call mac_look to re-anchor"
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
                        + "handle — NOTHING was acted on; call mac_look again"
                    ),
                ]
            )
        case .windowDrifted(let reason):
            return injectionRefusal(
                action: "act",
                error: "window_drifted",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "drifted_on": .string(reason),
                    "guidance": .string(
                        "that app's windows can no longer be told apart — NOTHING was acted on; call "
                        + "mac_look to re-anchor"
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
                        + "window any more) — nothing was acted on; call mac_look again"
                    ),
                ]
            )
        case .pathNotFound:
            return injectionRefusal(
                action: "act",
                error: MacAccessibilityActuator.Failure.pathNotFound.rawValue,
                status: 404,
                extra: [
                    "handle": .string(handle),
                    "path": .array(entry.path.map { .int(Int64($0)) }),
                    "pid": .int(Int64(framePid)),
                    "guidance": .string("the element that handle named is gone — call mac_look again"),
                ]
            )
        }

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
                        "label": entry.label.map {
                            MacScreenViewTextRedaction.redactedLegendString($0, valueChars: MacAXLimits.hardValueChars)
                        } ?? .null,
                    ]),
                    "found": .object([
                        "role": .string(target.role),
                        "label": (target.title ?? target.value).map {
                            MacScreenViewTextRedaction.redactedLegendString($0, valueChars: MacAXLimits.hardValueChars)
                        } ?? .null,
                    ]),
                    "guidance": .string(
                        "that handle no longer names the control it did — the window changed; call mac_look again"
                    ),
                ]
            )
        }

        // 5b. THE IDENTITY RE-CHECK (gpt-5.5 round-2 B3 / Agent #3b).
        //
        //     Role+label alone passes the worst realistic drift: two buttons
        //     both labeled "Send", the one above disappears, and the handle she
        //     named now addresses the OTHER one — same role, same label, wrong
        //     control. So the live window is RE-COMPILED through the same
        //     walker and the same compiler the look used, and the element at
        //     her path must still render the SAME handle. For a handle that was
        //     position-derived to begin with (`ambiguous`), the rendered handle
        //     is by construction unable to tell the siblings apart, so the
        //     recorded frame RECT must match too.
        let identityLimits = Self.axLimits(from: body)
        // B1 — re-read the FRAME'S WINDOW, not the app's focused one. Comparing
        // the handle against a walk of the app's other window is a drift check
        // that verifies the wrong tree: it either passes by luck or refuses
        // every act while the real target sits there untouched.
        let identityAnchor = anchoredSnapshot(
            limits: identityLimits,
            pid: framePid,
            window: frame.windowIdentity
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
                        + "call mac_look again"
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
            scope: MacLookScope.parse(body.stringValue("scope")) ?? .page
        ).read
        let identityPercept = MacPerceptionCompiler.compile(
            snapshot: identityScoped.snapshot,
            app: identityScoped.app,
            windowTitle: identityScoped.rootTitle,
            focusPath: identityScoped.focusPath,
            maxAffordances: Self.intValue(body, "max_affordances") ?? MacPerceptionCompiler.maxAffordances
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
                        + "window changed under you; call mac_look again"
                    ),
                ]
            )
        }

        // 6. ARM THE OBSERVER *BEFORE* ACTING. A loop that installs after the
        //    act races the effect and loses on a fast app (the spike measured
        //    30 ms). The guard removes it on EVERY exit — success, error,
        //    timeout, or an unwinding cancellation.
        //
        //    NO OBSERVER, NO ACT (gpt-5.5 round-2 B2). The closed loop's whole
        //    promise is that she never has to re-look to learn whether the act
        //    landed; firing a verb with nothing watching the app is a blind
        //    press wearing the loop's costume. `none_observed` (the app fired
        //    nothing) stays a real, reported outcome — this is the different
        //    case where the subscription itself could not be made.
        // 6b. THE KEY-WINDOW GATE (Agent round 7, envelope 173E1B08).
        //
        //     Every anchor up to here constrains where we READ and where we
        //     perform AX ACTIONS. None of them constrains a CGEvent: the window
        //     server delivers synthesized input to whatever is KEY. With Chrome
        //     frontmost and a Finder frame, `open`'s select-then-⌘↓ posted the
        //     chord into Chrome and the envelope still said `acted`.
        //
        //     Computed HERE (one pair of AX reads, before anything is performed)
        //     and handed to `performAct`, which consults it at each site that
        //     would synthesize input — and ONLY there. A verb that carries out
        //     through pure AX (`AXPress`, `AXSetValue`) targets its element
        //     directly, steals no focus and reaches no other app, and acting on
        //     a background window that way is an established capability with a
        //     test behind it (`pidAnchoredRead_neverReportsTheFrontmostAppsIdentity`).
        //     Gating those too would have traded a real bug for a real
        //     regression.
        let focusedWindowNow = accessibilityActSource.focusedWindow(pid: framePid)
        let inputRefusal = MacActClosedLoop.keyWindowRefusal(
            framePid: framePid,
            frontmostPid: accessibilitySource.frontmostApp()?.processIdentifier,
            frontmostName: accessibilitySource.frontmostApp()?.name,
            // `actWindow` is the window this frame was already matched to, so
            // the key question is plain handle equality against the focused one
            // — and since round 9 the live source mints ONE handle per element,
            // so that equality answers about the window rather than about two
            // counter values (`SystemMacAXActSource.mint`).
            frameWindowHandle: actWindow.handle,
            focusedWindowHandle: focusedWindowNow?.handle,
            frameWindowTitle: actWindow.identity.title,
            focusedWindowTitle: focusedWindowNow?.identity.title,
            appWindowCount: focusedWindowNow == nil ? actWindows.count : nil
        )

        let collector = MacAXEffectCollector()
        let observerGuard = MacAXEffectObserverGuard(
            effectObserverSource.install(
                pid: framePid,
                kinds: MacActClosedLoop.notificationKinds,
                onNotification: { [collector] notification in collector.record(notification) }
            )
        )
        defer { observerGuard.stop() }
        let observerInstalled = observerGuard.isInstalled
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
                        + "of this act could not be observed — NOTHING WAS ACTED ON. Check that the app "
                        + "is still running and try mac_look again."
                    ),
                ]
            )
        }

        // 7. PERFORM.
        let performedAt = now()
        let performed = performAct(
            verb: verb,
            handle: handle,
            entry: entry,
            frame: frame,
            framePid: framePid,
            actWindow: actWindow,
            target: target,
            text: text,
            direction: direction,
            inputRefusal: inputRefusal
        )
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
        // A NAVIGATION verb is watched until the surface actually transitions,
        // not until the first notification of any kind (Agent round 7, envelope
        // 4E998341: the selection fired in milliseconds, the loop stopped
        // watching, and Finder's retitle — the signal `navigated` is DEFINED by
        // — arrived after the recompile had already read the old title). An
        // explicit `wait_ms` from the caller still wins; this only raises the
        // DEFAULT, and it is a deadline, not a sleep.
        let navigationVerb = MacActClosedLoop.navigationVerbs.contains(verb)
        let effectWaitMs = navigationVerb && Self.intValue(body, "wait_ms") == nil
            ? MacActClosedLoop.clampedWaitMs(MacActClosedLoop.navigationWaitMs)
            : waitMs
        let wait = await MacActClosedLoop.waitForEffect(
            collector: collector,
            waitMs: effectWaitMs,
            startedAt: performedAt,
            clock: { clock() },
            until: navigationVerb ? MacActClosedLoop.navigationNotificationKinds : []
        )
        observerGuard.stop()

        // 9. RE-COMPILE the same look percept and DIFF it against the frame.
        let limits = Self.axLimits(from: body)
        // B2 — the post-act read is of the FRAME'S WINDOW, never of whatever is
        // frontmost by now. The act itself was already pid+window anchored; a
        // frontmost re-read would then describe another app's window as "what
        // changed" AND store it as the new frame, so the next verb would act
        // from a description of something she never looked at.
        let (read, seam, postAnchor) = await lookSnapshot(
            limits: limits,
            scope: MacLookScope.parse(body.stringValue("scope")) ?? .page,
            anchorPid: framePid,
            anchorWindow: frame.windowIdentity
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
            "wait_ms": .int(Int64(waitMs)),
            "notifications": .array(wait.notifications.map { .string($0) }),
            "notification_count": .int(Int64(wait.notificationCount)),
            "acted_element": .object([
                "handle": .string(performed.actedHandle),
                // REDIRECT-AWARE (gpt-5.5 round-5 review). `open` can act on an
                // ANCESTOR of the handle, and then the frame entry's label and
                // value belong to a DIFFERENT element than the one described
                // here — "handle = filename cell, before = row" was readable as
                // the row being named `.agents`. When the act was redirected the
                // entry's label/value are withheld and the element speaks for
                // itself; `acted_on` carries the redirect, and the redaction
                // verdict stays the conservative one either way.
                "before": MacActReceiptRendering.actedElementJSON(
                    performed.target,
                    redactingValue: redactValue || (actRedirected && entry.secret),
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
        // An observer that could not be installed never gets here: B2 refuses
        // the act outright rather than pressing with nothing watching. The only
        // remaining "no evidence" case is the honest one — the app fired
        // nothing inside wait_ms, which is itself an answer.
        if !wait.observed {
            effect["reason"] = .string("none_observed")
        }

        var output: [String: JSONValue] = [
            "ok": .bool(performed.ok),
            // Agent acceptance round 2, Finder `open` — the event WAS delivered
            // (AXOpen refused, the CGEvent double-click fallback ran) and the
            // app published nothing, the title did not move and the glance was
            // identical. Reporting that as `acted` calls an unobserved act a
            // success. `ok`/`performed` keep their meaning — the event went out;
            // the STATUS says whether anything was seen to happen. `verified`
            // stays false either way: observation is evidence, not settlement.
            // Round 4, Finder `open`: one AXRowCountChanged was enough to call
            // an act that navigated NOWHERE `acted`. The classifier below is
            // the single place that verdict is made; this seeds it with the
            // no-diff-yet answer (correct for the window-died early return
            // just past this point) and the post-diff recompute overrides it
            // once there is a percept to weigh.
            "status": .string(MacActClosedLoop.classify(
                performedOK: performed.ok,
                verb: verb,
                notificationObserved: wait.observed,
                diff: nil
            ).status),
            "verb": .string(verb.rawValue),
            "handle": .string(handle),
            "performed": .bool(performed.ok),
            "method": .string(performed.method),
            "requested_action": .string(performed.requestedAction),
            "path": .array(entry.path.map { .int(Int64($0)) }),
            "seam": .object(seam),
            // The closed loop OBSERVES; it does not claim the intended
            // consequence happened. `effect.observed` is the evidence, and it
            // is the caller's to judge — same honesty line `ax_act` holds.
            "verified": .bool(false),
            "value_redacted": .bool(redactValue),
        ]
        output["fallback_reason"] = performed.fallbackReason.map { .string($0) } ?? .null
        // Agent acceptance round 1, finding B — the act is NOT refused for an
        // ordinal handle (that would make Finder unusable), but a caller must be
        // able to see that it acted on a POSITION rather than on an identity.
        if entry.ambiguous {
            output["handle_ambiguous"] = .bool(true)
            output["handle_ambiguity"] = .string(
                "that handle was a position-derived ordinal among identical elements — it names "
                + "whatever now sits at that position; re-look if the container may have reordered"
            )
        }
        for (key, value) in performed.extra { output[key] = value }
        if let error = performed.error { output["error"] = .string(error) }

        guard let read else {
            // The window went away under the act (she closed it, or dismissed
            // the last sheet, or the act itself closed it). That is a real
            // outcome and the frame must die with it — a handle from a window
            // that no longer exists must never resolve.
            //
            // B2 — and it is NAMED. "no_frontmost_window" was the only answer
            // when the post-act read was frontmost-anchored; an anchored read
            // can distinguish the app exiting from the window closing from two
            // windows now being indistinguishable, and the caller acts
            // differently on each.
            await lookFrameStore.invalidate()
            let (percept, note): (String, String) = {
                switch postAnchor {
                case .appGone?:
                    return (
                        "frame_app_gone",
                        "the act ran, but the app you looked at no longer publishes a window — the old "
                        + "frame is discarded; call mac_look when it is back"
                    )
                case .windowGone?:
                    return (
                        "frame_window_gone",
                        "the act ran, and the window you looked at is gone (it closed, or the act closed "
                        + "it) — the old frame is discarded; call mac_look at whatever is up now"
                    )
                case .windowDrifted(let reason)?:
                    return (
                        "window_drifted:\(reason)",
                        "the act ran, but that app now has more than one window that could be the one "
                        + "you looked at, so nothing was re-read — the old frame is discarded; call "
                        + "mac_look to re-anchor"
                    )
                case .selfProcess?:
                    return (
                        Self.selfInspectionError,
                        "the act ran, but the target now resolves to NativeAgent's own process, which "
                        + "AX must not re-read — the old frame is discarded; call mac_look at another "
                        + "app's window"
                    )
                case .read?, nil:
                    return (
                        "no_frontmost_window",
                        "the act ran, but there is no window to look at afterwards — the old frame is "
                        + "discarded; call mac_look when a window is up again"
                    )
                }
            }()
            effect["percept"] = .string(percept)
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
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }

        let after = MacPerceptionCompiler.compile(
            snapshot: read.snapshot,
            app: read.app,
            windowTitle: read.rootTitle,
            // Same read epoch as the post-act walk, anchored to its root.
            focusPath: read.focusPath,
            maxAffordances: Self.intValue(body, "max_affordances") ?? MacPerceptionCompiler.maxAffordances
        )
        // The bounds THIS compile ran under, so the diff can say whether its
        // added/removed census is comparable with the look's (Agent round 2:
        // 29 added / 1 removed was a capped recompile, not navigation).
        let afterCaps = MacLookCompileCaps(
            truncated: after.truncated,
            maxAffordances: Self.intValue(body, "max_affordances") ?? MacPerceptionCompiler.maxAffordances,
            maxNodes: limits.maxNodes,
            maxDepth: limits.maxDepth
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
        // THE VERDICT, now that there is evidence to weigh. A navigation verb
        // whose window did not move is `acted_unobserved` even though the app
        // published something — see `MacActClosedLoop.classify`.
        let classification = MacActClosedLoop.classify(
            performedOK: performed.ok,
            verb: verb,
            notificationObserved: wait.observed,
            diff: diff,
            // The label she NAMED — Finder retitles to the opened folder, so
            // this is what the destination is checked against.
            intendedTarget: entry.label,
            // VERB-SEMANTIC for `type`: the text we tried to land, the acted
            // element's value BEFORE (from the pre-act resolve — without it, a
            // pre-existing substring reads as a landed edit), and what the
            // field reads back after. Compared in memory only — none of these
            // are ever echoed into a payload, so a secret stays a secret.
            // A secure field reads back a MASK — a non-empty string that can
            // never contain the typed text — so comparing against it would
            // call a landed edit "not in field". The SAME breadth the look
            // lane uses to redact (role + label hints; subrole is not carried
            // on MacAXActTarget) gates it to the honest `edit_unverifiable`
            // branch instead.
            typedText: verb == .type ? body.stringValue("text") : nil,
            valueBefore: MacScreenViewBuilder.isSecretField(
                role: performed.target.role, subrole: nil, label: entry.label
            ) ? nil : performed.target.value,
            valueAfter: MacScreenViewBuilder.isSecretField(
                role: performed.target.role, subrole: nil, label: entry.label
            ) ? nil : performed.postState?.value
        )
        output["status"] = .string(classification.status)
        if let reason = classification.reason {
            output["status_reason"] = .string(reason)
            // Same value as the `none_observed` written above when nothing was
            // published, so this is a no-op there rather than a clobber. A
            // `failed` classification carries no reason and writes nothing —
            // an earlier `none_observed` on a failed act is still TRUE (the app
            // published nothing) and stays.
            effect["reason"] = .string(reason)
        }
        if let note = classification.note { output["status_note"] = .string(note) }
        // Agent round 2 — a Finder view switch dropped 222 notifications and
        // showed 10 of 44 additions. A truncated list of a bulk change is not a
        // description of it, so past the cap the payload also carries a
        // SEMANTIC summary: what appeared and vanished by role, and what the
        // focus is now inside.
        if diff.addedTotal > MacActClosedLoop.maxDiffRows || wait.dropped > 0 {
            effect["summary"] = MacActReceiptRendering.denseEffectSummaryJSON(
                diff: diff,
                after: after,
                snapshot: read.snapshot,
                valueChars: limits.valueChars
            )
        }
        output["effect"] = .object(effect)

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
            caps: afterCaps
        ))
        output["frame_id"] = .string(newFrameId)
        output["captured_at"] = .string(ISO8601DateFormatter().string(from: capturedAt))
        output["frame_ttl_seconds"] = .int(Int64(MacLookFrameStore.ttlSeconds))
        // The ACT's glance leads with the readout THIS act moved, not with the
        // top-ranked one (Agent round 2: Equals produced "42" and the glance
        // still opened with the expression "7×6", so she had to re-look for the
        // one number she pressed Equals to get). `mac_look`'s ranking is
        // untouched — a look has no act to describe.
        output["glance"] = .string(after.glanceLine(leading: MacActReceiptRendering.actedReadout(diff: diff, after: after)))
        output["how_to_read"] = .string(
            "`effect` is what changed: the notifications the app fired, the acted element before/after, "
            + "`readouts_changed` (the read-only values — a total, a display, a status line — that moved, "
            + "which is where the ANSWER to what you just did usually is), and "
            + "the affordances added/removed/changed by handle. `frame_id` is a FRESH frame compiled after "
            + "the act — keep acting on handles from it. Handles from the previous frame are dead. You do "
            + "NOT need to call mac_look to find out whether this landed."
        )

        return MacControlResult(
            ok: performed.ok,
            action: "act",
            output: .object(output),
            error: performed.error,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// Plan and run ONE verb. Every mechanism here is an EXISTING one:
    /// `MacAccessibilityActuator.act` (which owns the AXPress → synthesized
    /// click fallback), the actuator's own `perform`, and `MacEventPlanner` +
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

    private func performAct(
        verb: MacActVerb,
        handle: String,
        entry: MacLookFrameEntry,
        frame: MacLookFrame,
        /// B2 — the pid the frame was captured from. Every resolve this function
        /// still has to make (the dismiss button) is anchored to it, so no verb
        /// can reach into whatever app is frontmost by now.
        framePid: Int32,
        /// B1 — and to the WINDOW the frame was captured from. The dismiss
        /// button is looked up by path, and a path resolved in the app's other
        /// window presses whatever sits at that position there.
        actWindow: MacAXWindowRef,
        target: MacAXActTarget,
        text: String?,
        direction: MacActScrollDirection,
        /// Round 7 — non-nil when the frame's window is NOT key, i.e. when any
        /// synthesized event would land somewhere other than the window she
        /// looked at. Consulted at every posting site; pure-AX paths ignore it.
        inputRefusal: MacActClosedLoop.KeyWindowRefusal?
    ) -> MacActPerformed? {
        /// Every synthesized-input site calls this FIRST. Non-nil ⇒ return it:
        /// nothing posted, nothing selected, nothing pressed. The AX paths above
        /// each site are untouched — this gates the window server, not the API.
        /// Has this call already INVOKED an actuation on the app?
        ///
        /// Agent round 8, envelope 70DA30C4 — the lying receipt. `AXOpen` on a
        /// .json filename LAUNCHED Xcode (the same envelope carries
        /// `AXWindowCreated` at 139 ms and the file was on screen), and the
        /// AX call still reported a status other than `.performed`, so step 1
        /// fell through. The chord branch then re-read the frontmost app, saw
        /// XCODE — the window the act had just opened — and returned
        /// `window_not_key, performed: false, method: none, posted_events: 0`.
        /// A successful open reported as "nothing was posted".
        ///
        /// AN AX ACTION'S RETURN STATUS IS NOT EVIDENCE THAT IT DID NOTHING.
        /// Once an action has been delivered, a later focus change is EVIDENCE
        /// OF SUCCESS, not grounds for a pre-emission refusal. So the gate is
        /// strictly pre-actuation: after this flips, `refuseInput` may still
        /// stop us POSTING (an event into the wrong app is never right), but it
        /// may never again describe the call as having done nothing.
        /// The ENTRY-TIME verdict, mutable because a successful raise makes it
        /// obsolete. Its own doc calls a stale verdict "a memory, not a gate" —
        /// so once we have RAISED the window and a fresh read says it is key,
        /// the memory must not veto the live fact.
        var entryRefusal = inputRefusal
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

        // ROUND 9, envelope 62D093EB — THE LEDGER MUST COVER EVERY MUTATION.
        //
        // Round 8 bought the rule "an AX action's return status is not evidence
        // that it did nothing" and paid for it with `noteActuation`. It was then
        // applied to the actuation sites the round-8 receipt happened to name,
        // and the FIRST actuation in `open` — the handle's own `AXOpen`, which
        // runs above the verb gate — was left outside the ledger. Agent's
        // round-9 Finder receipt is the same lie by the same mechanism: that
        // AXOpen navigated window-a into TargetFolder (title change, sentinel
        // visible, 34 notifications) and returned something other than
        // `.performed`, so the code fell through to the gate, `didActuate` was
        // still false, and the envelope said `performed: false, posted_events:
        // 0` about an act that had already happened.
        //
        // The defence is structural, not another remembered call site: every AX
        // mutation this function makes goes through one of these wrappers, and
        // each ledgers BEFORE it reads a status. Adding an AX mutation without
        // a wrapper is now the visible thing to review for.
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
        func ledgeredActuatorAct(
            action: String?,
            value: String?,
            resolved: MacAXActTarget
        ) -> Result<MacAccessibilityActuator.ActResult, MacAccessibilityActuator.Failure> {
            noteActuation(value != nil ? "AXSetValue" : (action ?? MacAccessibilityActuator.defaultAction))
            return MacAccessibilityActuator.act(
                source: accessibilityActSource,
                sink: eventSink,
                path: [],
                action: action,
                value: value,
                resolved: resolved
            )
        }

        /// The LIVE key-window verdict — one pair of AX reads, both windows
        /// named. Round 9 second finding: the two call sites below each built
        /// this by hand, called `frontmostApp()` twice, and passed
        /// `focusedWindowTitle: nil`, so every wrong-window refusal Agent ever
        /// received said "key: untitled" no matter what the key window was
        /// actually called. The refusal names the window she has to deal with;
        /// it cannot be a placeholder.
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
            // RE-READ at the emission boundary, never trust the entry-time
            // verdict alone (gpt-5.5 round-7 BLOCKING). Between the gate in
            // `handleAct` and this line the verb has done real AX work — an
            // AXOpen attempt, an ancestor re-resolve — and the front can move
            // under it. The residual race is one AX read wide and no lock can
            // close it (the window server owns focus), but a stale verdict from
            // hundreds of milliseconds ago is not a gate, it is a memory.
            let live = liveKeyWindowRefusal()
            guard var inputRefusal = live ?? entryRefusal else { return nil }

            // HANDS, NOT HOMEWORK (User, 2026-08-22: "a live screen with hands
            // she can use"). The window she is acting in is not key. Every
            // previous round answered that by refusing and telling her to bring
            // it forward and look again — bookkeeping handed back to the caller
            // for something this tool can simply DO. So do it: raise THAT
            // window (AXRaise + activate, since either alone leaves the wrong
            // thing key), then re-ask. Only a raise that fails to make it key
            // is a refusal.
            //
            // Not attempted once an actuation has been delivered: raising after
            // the fact cannot un-deliver it, and the honest report of what
            // already happened (below) is the right answer there.
            /// Did the raise actually LAND? Agent's 7FCDC92E receipt is what
            /// this exists for. Two live measurements, background process,
            /// Chrome frontmost, 2026-08-22:
            ///
            ///   * `NSRunningApplication.activate()` returns `true` and the
            ///     front does not move. The Bool is a receipt for the REQUEST.
            ///   * activation, when it is honoured at all, is ASYNCHRONOUS —
            ///     the call returns before the window server has moved
            ///     anything.
            ///
            /// So one read immediately after the raise decides nothing, and it
            /// can decide it in the dangerous direction: a single matching
            /// answer cleared the gate and a coordinate click went out while
            /// Chrome still owned the screen. The verdict has to HOLD — two
            /// consecutive clear reads — and it is given a bounded budget to
            /// become true rather than being asked once and abandoned.
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

            if !didActuate, !raiseAttempted {
                raiseAttempted = true
                let outcome = accessibilityActSource.raise(actWindow)
                if outcome == .performed, raiseSettled() {
                    // It is key now. Retire the stale entry verdict so the NEXT
                    // gate call in this same act (step 1 and the chord branch
                    // each consult it) does not refuse on a fact that stopped
                    // being true when we raised the window.
                    entryRefusal = nil
                    return nil
                }
                // Raise did not take. Say so in the refusal rather than
                // repeating advice she already followed.
                inputRefusal = MacActClosedLoop.KeyWindowRefusal(
                    reason: inputRefusal.reason,
                    note: inputRefusal.note
                        + " This call also tried to RAISE that window itself (raise outcome: "
                        + "\(outcome.rawValue)) and then WAITED up to half a second for the window "
                        + "server to honour it; the window never became key and stayed key, so the "
                        + "block is real rather than a matter of ordering. A raise that reports "
                        + "success and does not move the front is what an activation request looks "
                        + "like from a background process — the front app itself has to yield."
                        // The one raise failure with a fixable cause, when the
                        // source knows it: a missing Automation grant. Silence
                        // here would report "could not raise" for "you were
                        // never allowed to."
                        + (accessibilityActSource.raiseDiagnostic.map { " \($0)" } ?? "")
                )
            }
            // ALREADY ACTUATED. We still refuse to POST — an event into the app
            // that is key now is never what she asked for — but the envelope
            // must describe what this call actually did. `performed: false` and
            // "nothing was posted" here would be the round-8 lie.
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
                            "an accessibility action was DELIVERED to the element and the key window "
                            + "was not (or is no longer) the one this frame describes — which is also "
                            + "what a successful open or launch looks like from here. No synthesized "
                            + "event was posted (that would have gone to the key window). Read "
                            + "`effect` for what was actually observed; this call does not claim the "
                            + "result is what you asked for, only that something was delivered."
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

        func summarize(
            _ result: MacAccessibilityActuator.ActResult,
            target: MacAXActTarget,
            actedHandle: String,
            extra: [String: JSONValue] = [:]
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
                extra: extra
            )
        }

        /// AXPress with the actuator's own synthesized-click fallback — the
        /// shared mechanism behind click / select / toggle, and behind the
        /// dismiss button once it has been found.
        func press(_ pressTarget: MacAXActTarget, actedHandle: String, extra: [String: JSONValue] = [:]) -> MacActPerformed? {
            // AXPress itself is pure AX and stays ungated — acting on a
            // background window that way is an established capability. But the
            // actuator's own SYNTHESIZED-CLICK fallback is window-server input,
            // and until round 9 it was the one CGEvent emitter in this file the
            // key-window gate never saw. Gate it where it happens.
            var gateRefusal: MacActPerformed?
            let outcome = MacAccessibilityActuator.act(
                source: accessibilityActSource,
                sink: eventSink,
                path: [],
                action: MacAccessibilityActuator.defaultAction,
                value: nil,
                resolved: pressTarget,
                syntheticFallbackGate: { reason in
                    // `ax_action_*` means the AX action was DELIVERED and only
                    // its status disappointed us — round 8's rule. Ledger it
                    // before the gate can describe this call as having done
                    // nothing.
                    // …but NOT `invalidTarget`, which the actuator returns
                    // when the element handle no longer resolves — that path
                    // returns BEFORE AXUIElementPerformAction, so nothing was
                    // delivered and ledgering it would let a refusal claim an
                    // actuation that never happened (gpt-5.5 round-9 BLOCKING).
                    if reason.hasPrefix("ax_action_"), reason != "ax_action_invalidTarget" {
                        noteActuation(MacAccessibilityActuator.defaultAction)
                    }
                    if let refusal = refuseInput(MacAccessibilityActuator.defaultAction) {
                        gateRefusal = refusal
                        return false
                    }
                    return true
                }
            )
            if let gateRefusal { return gateRefusal }
            switch outcome {
            case .failure:
                return nil
            case .success(let result):
                return summarize(result, target: pressTarget, actedHandle: actedHandle, extra: extra)
            }
        }

        switch verb {
        case .click, .select, .toggle:
            // One mechanism, three intentions. AXPress runs the app's OWN
            // handler — which is what "select this row" and "toggle this
            // checkbox" mean to the app — and the actuator falls back to a
            // synthesized click at the element's frame centre when the control
            // advertises no action, saying which one fired.
            return press(target, actedHandle: handle)

        case .open:
            // Agent round 2 — navigating Finder by handle needs the DOUBLE
            // click, and there was no verb for it. `AXOpen` is the semantic
            // form; when the element does not advertise it, the fallback is the
            // EXISTING click injection path with a click count of two. No new
            // event poster, no new AX mutator.
            //
            // Round 4, finding 1(a) — and this is what made Finder `open` a
            // no-op: the verb was aimed at the handle SHE HELD. Her handle was
            // the filename `AXTextField` (a cell); AXOpen was refused there and
            // the double-click landed on the text, which is Finder's RENAME
            // gesture. Resolve to the element that actually opens FIRST, then
            // run the same two mechanisms against it.
            // ORDER IS THE FIX. Try the handle's own AXOpen FIRST — and only
            // escalate when it did not PERFORM. Her cell advertised AXOpen and
            // refused it (`fallback_reason=ax_action_refused`), so a redirect
            // gated on "does not advertise AXOpen" would never have fired for
            // the case it was written for. Advertising is not doing.
            //
            // ROUND 9: THE GATE IS HERE, ABOVE THE FIRST ACTUATION. It used to
            // sit below this attempt, under a comment claiming it ran "BEFORE
            // THE FIRST ACTUATION" — it did not, and the handle's own AXOpen
            // therefore fired on a window that was not key AND outside the
            // actuation ledger. Both halves of Agent's round-9 receipt come
            // from those two lines of distance.
            if let refusal = refuseInput("AXOpen") { return refusal }

            if target.actions.contains("AXOpen"),
               ledgeredPerform(target, action: "AXOpen") == .performed {
                return MacActPerformed(
                    ok: true,
                    method: "ax_action",
                    requestedAction: "AXOpen",
                    fallbackReason: nil,
                    error: nil,
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
            // The handle would not open. Climb to the element that will.
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

            // RE-CHECK before the escalated attempt. The whole-verb gate now
            // runs above the handle's own AXOpen (Agent round 8: "emission gate
            // strictly before selection/event"; round 9: it has to be above the
            // FIRST one, not the second). This call is the emission-boundary
            // re-read the fallback path is entitled to — and if the first
            // AXOpen already delivered, the ledger makes this report what
            // happened instead of claiming nothing did.
            if let refusal = refuseInput("AXOpen") { return refusal }

            // 1. THE SEMANTIC PATH, any role. `AXUIElementPerformAction` does
            //    what the app says it does; it cannot land somewhere else, so a
            //    cell is a fine target for it.
            if let semantic = openPlan.semantic, let live = liveAncestor(semantic).target {
                // NOTE THE ATTEMPT BEFORE READING THE STATUS. Round 8 proved the
                // status is not a verdict on the effect: this exact call opened
                // a .json in Xcode and did NOT come back `.performed`.
                let semanticOutcome: MacAXActOutcome? = live.actions.contains("AXOpen")
                    ? ledgeredPerform(live, action: "AXOpen")
                    : nil
                if semanticOutcome == .performed {
                    return MacActPerformed(
                        ok: true,
                        method: "ax_action",
                        requestedAction: "AXOpen",
                        fallbackReason: nil,
                        error: nil,
                        target: live,
                        postState: accessibilityActSource.reread(live),
                        actedHandle: handle,
                        extra: ["acted_on": semantic.toJSON()]
                    )
                }
            }

            // 2. THE CLICK PATH, ROWS ONLY. A synthesized double-click is a
            //    POSITION on User's screen. The semantic candidate above is NOT
            //    reused here: if a cell's AXOpen refused, double-clicking that
            //    same cell is the rename gesture — the original bug by a new
            //    route (gpt-5.5 round-5 review, second pass).
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
                    // NOT `acted_on` — nothing was performed and nothing was
                    // posted. It names what the redirect was AIMING at when the
                    // window moved under it (gpt-5.5 round-5, third pass).
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

            // 3. SELECT + THE APP'S OPEN COMMAND — the only mechanism round 6
            //    measured as actually navigating. Finder advertises AXOpen on
            //    the filename and returns kAXErrorActionUnsupported for it,
            //    AXConfirm reports success and does nothing, and a synthesized
            //    double-click is inert at BOTH the row centre and the filename.
            //    Selecting the row and pressing the app's Open chord works.
            //    Only fires for apps whose chord is PROVEN (see the table).
            if let chord = MacActClosedLoop.openCommandChord(forBundleId: frame.bundleId),
               eventSink.isAvailable {
                // ONLY a live, still-verified ROW may be selected-and-opened.
                // gpt-5.5 round-7 review: `?? target` let a Finder element with
                // settable AXSelected but NO openable row ancestor reach the
                // chord — Cmd-Down would then open whatever Finder had selected,
                // which is not what the caller named. No row ⇒ no chord.
                // Before the SELECTION, not just before the chord: selecting a
                // row is a visible mutation whose only purpose is to feed a
                // chord we are about to refuse to post. Zero input means zero
                // side effects.
                if let refusal = refuseInput("AXOpen") { return refusal }
                let selectTarget = openPlan.click.flatMap { liveAncestor($0).target }
                let selectable = selectTarget.map {
                    MacActClosedLoop.openableAncestorRoles.contains($0.role)
                } ?? false
                let selected = selectable && selectTarget != nil
                    ? ledgeredSetSelected(selectTarget!)
                    : MacAXActOutcome.unsupported
                if let selectTarget, selected == .performed {
                    // THE EMISSION BOUNDARY IS THE POST, NOT THE PRE-SELECTION
                    // CHECK (gpt-5.5 round-9 BLOCKING). Selecting the row is
                    // itself a mutation that can move focus, and an external
                    // race has the same window it always has. Re-ask here, one
                    // line above the chord — and because the selection IS in
                    // the ledger, a refusal at this point reports what was
                    // already done instead of claiming nothing was.
                    if let refusal = refuseInput("AXOpen") { return refusal }
                    for event in MacEventPlanner.chord(chord) { eventSink.post(key: event) }
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
            for event in MacEventPlanner.click(x: centre.x, y: centre.y, button: .left, count: 2) {
                eventSink.post(mouse: event)
            }
            return MacActPerformed(
                ok: true,
                method: "cgevent_double_click_fallback",
                requestedAction: "AXOpen",
                fallbackReason: openFallbackReason,
                error: nil,
                target: openTarget,
                postState: accessibilityActSource.reread(openTarget),
                actedHandle: handle,
                extra: ["click_count": .int(2), "acted_on": openTargetJSON]
            )

        case .type:
            guard let text, !text.isEmpty else { return nil }
            // Editable elements ONLY. Below this line the fallback focuses the
            // control and injects keystrokes, and the old way of "focusing" it
            // was AXPress — which on a button is ACTIVATION: `type` aimed at
            // Mail's Send pressed Send. A verb that cannot be carried out is
            // refused by name (`verb_not_supported_on_element`), never
            // approximated with a different act.
            guard MacActClosedLoop.canType(role: target.role) else { return nil }
            // A PASSWORD FIELD IS A BOUNDARY, NOT A MECHANISM FAILURE (sweep
            // item 8). AXSetValue would happily fill one, and the keystroke
            // fallback below would post into a void — macOS has secure
            // keyboard entry on whenever such a field holds focus. Both
            // answers are wrong for the same reason: the credential is User's
            // to type. Refuse here, above every actuation, in words.
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
            // AXSetValue first: that is how you fill a field without
            // simulating 40 keystrokes, and it cannot be intercepted by
            // whatever else has focus.
            let setOutcome = ledgeredActuatorAct(action: nil, value: text, resolved: target)
            if case .success(let result) = setOutcome, result.ok {
                return summarize(result, target: target, actedHandle: handle)
            }
            // Not settable (a web input, a terminal, a rich-text view). Focus
            // it the app's own way, then use the EXISTING keystroke injection
            // path — the same planner + sink `mac_keystroke` runs through.
            // Focus WITHOUT invoking the handler. Even on an editable role,
            // AXPress runs the app's own action (a search field's press can
            // submit); AXFocused is the attribute that means "the cursor is
            // here" and nothing else.
            let focusOutcome = ledgeredSetFocused(target)
            let focusMethod = focusOutcome == .performed ? "ax_focus" : "none"
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
            // The keystroke fallback: AXSetValue could not carry this, so the
            // characters go through the window server and land wherever the key
            // window is. Refuse rather than type into another app.
            //
            // SECURE KEYBOARD ENTRY FIRST (sweep item 8), because it is a pure
            // read and the key-window gate below can RAISE a window — no point
            // moving User's screen around for keystrokes that cannot be
            // delivered to anything.
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
            if let refusal = refuseInput("type") { return refusal }
            for event in MacEventPlanner.typeText(text) {
                eventSink.post(key: event)
            }
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
                ]
            )

        case .dismiss:
            // The modal's OWN Cancel/Close/Dismiss/Done/OK button, found in the
            // CURRENT frame and scoped by path prefix to the modal — a window
            // behind a sheet often has its own "Close", and pressing that would
            // act on the wrong surface entirely.
            if let dismissEntry = MacActClosedLoop.dismissTarget(in: frame),
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
                return press(
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
            // AXScrollToVisible is the semantic form and needs no coordinates.
            if target.actions.contains("AXScrollToVisible") {
                let outcome = ledgeredPerform(target, action: "AXScrollToVisible")
                if outcome == .performed {
                    return MacActPerformed(
                        ok: true,
                        method: "ax_action",
                        requestedAction: "AXScrollToVisible",
                        fallbackReason: nil,
                        error: nil,
                        target: target,
                        postState: accessibilityActSource.reread(target),
                        actedHandle: handle
                    )
                }
            }
            // Otherwise the EXISTING wheel path, aimed at the element's centre
            // so the scroll lands on the intended view rather than wherever the
            // cursor happened to sit.
            guard eventSink.isAvailable else {
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "scroll",
                    fallbackReason: "element_does_not_advertise_AXScrollToVisible",
                    error: "event_injection_unavailable",
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle
                )
            }
            if let refusal = refuseInput("scroll") { return refusal }
            if let centre = target.centre {
                eventSink.post(mouse: MacMouseEvent(phase: .move, button: .left, x: centre.x, y: centre.y))
            }
            // `down` moves the CONTENT up, which is what a human means by
            // scrolling down. Three lines: one notch of a physical wheel.
            let deltaY: Int32 = direction == .down ? -3 : 3
            eventSink.post(scroll: MacScrollEvent(deltaX: 0, deltaY: deltaY, unit: .line))
            return MacActPerformed(
                ok: true,
                method: "cgevent_scroll_fallback",
                requestedAction: "scroll",
                fallbackReason: "element_does_not_advertise_AXScrollToVisible",
                error: nil,
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

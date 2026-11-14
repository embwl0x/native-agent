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
// Blueprint: | `MacControl+ClosedLoopAction.swift` | `SwiftNativeMacControl.handleAct`: Same-window live identity and per-step declared effects |

extension SwiftNativeMacControl {
    struct MacActPerformed {
        var ok: Bool
        var method: String
        var requestedAction: String

        var error: String?
        /// Dismissal acts on the modal button, which can differ from the handle originally named.
        var target: MacAXActTarget
        var postState: MacAXActTarget?
        var actedHandle: String
        var extra: [String: JSONValue] = [:]
        var expectedText: String? = nil
        var textBeforeWrite: String? = nil
    }

    /// Return the declared-effect verdict with fresh perception; notifications only wake reads. Frame handles grant no authority, and explicit replays still
    /// consume a body-bound capability after normal admission.
    func handleAct(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult {
        let started = now()

        // Refuse malformed fields rather than inventing a target.
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
        let frontBefore = accessibilitySource(context: context).frontmostApp()

        // Frame resolution failures retain their own remedies so callers cannot blindly retry against a changed screen.
        let resolved = await lookFrameStore.resolve(handle: handle, frameId: frameId, now: started, context: context)
        var entry: MacLookFrameEntry
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
        guard let frame = await lookFrameStore.frame(frameId: frameId, context: context) else {
            return injectionRefusal(
                action: "act",
                error: MacLookFrameStore.ResolveFailure.noFrame.rawValue,
                status: 409,
                extra: ["guidance": .string(MacLookFrameStore.ResolveFailure.noFrame.guidance)]
            )
        }

        // Recheck the system grant and physical-input priority before resolving an action target.
        if let refusal = injectionPreconditions(action: "act", requiresSink: false, context: context) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "act", body: body, turn: turn, context: context) {
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
        if let continuation = turn.macContinuation, continuation.isPending,
           let captured = continuation.window {
            guard framePid == captured.pid, let observed = frame.windowIdentity,
                  observed.role == captured.role, observed.subrole == captured.subrole,
                  observed.title == captured.title, observed.frame == captured.frame else {
                return injectionRefusal(action: "act", error: "continuation_target_mismatch", status: 409,
                    extra: ["guidance": .string(continuation.modelContext(context: context))])
            }
        }
        // A recorded frame cannot authorize touching person-only UI.
        if PersonOnlyWindows.isOwnProcess(framePid) {
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
        if let refusal = await macAdmissionRefusal(pid: framePid, action: "act", reading: false, context: context) { return refusal }
        // Match the observed window by persistent identity; missing or ambiguous matches refuse instead of choosing current focus.
        let actWindows: [MacAXWindowRef]
        do { actWindows = try accessibilityActSource(context: context).windows(pid: framePid, context: context) }
        catch { return injectionRefusal(action: "act", error: "window_evidence_unavailable", status: 409,
            extra: ["guidance": .string(error.localizedDescription), "posted_events": .int(0)]) }
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
            return injectionRefusal(action: "act", error: "window_identity_unavailable", status: 409,
                extra: ["handle": .string(handle), "posted_events": .int(0),
                    "guidance": .string("This frame has no window identity. Call mac.look again to observe the exact window before acting.")])
        }

        // Recompile with the same walker/compiler and verify the rendered handle; positional identities also require stable cohort and geometry.
        let identityLimits = Self.axLimits(from: body)
        // Read the frame's window for identity verification; current focus may refer to another tree.
        let identityAnchor = anchoredSnapshot(
            limits: identityLimits,
            pid: framePid,
            window: frame.windowIdentity,
            complete: frame.completeWindow
        , context: context)
        let identityRead: MacAXRead
        switch identityAnchor {
        case .read(let hit):
            identityRead = hit
        case .appGone, .windowGone, .windowDrifted, .rendererUnavailable, .selfProcess:
            // Nothing to verify against and nothing to act on: the frame is dead, so it must stop resolving handles as well.
            await lookFrameStore.invalidate()
            let (error, reason): (String, String) = {
                switch identityAnchor {
                case .windowGone: return ("frame_window_gone", "window_gone_before_verify")
                case .windowDrifted(let why): return ("window_drifted", why)
                case .rendererUnavailable(let why): return ("renderer_accessibility_unavailable", why)
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
        // Reuse the look's scope so a page handle is not compared with a window walk that cannot reach it.
        let identityScoped: MacAXRead
        do {
            identityScoped = try pageScoped(identityRead, limits: identityLimits,
                scope: MacLookScope.parse(body["scope"]?.stringValue) ?? .page,
                completeWindow: frame.completeWindow, context: context).read
        } catch {
            return injectionRefusal(action: "act", error: "renderer_classification_unavailable", status: 409,
                extra: ["guidance": .string(error.localizedDescription), "posted_events": .int(0)])
        }
        let identityPercept = MacPerceptionCompiler.compile(
            snapshot: identityScoped.snapshot,
            secretContext: MacScreenViewTextRedaction.nodeSecretContext(identityScoped.snapshot.nodes),
            app: identityScoped.app,
            windowTitle: identityScoped.rootTitle,
            focusPath: identityScoped.focusPath,
            uncapped: true
        )
        // Resolve through every channel that can mint a frame entry, including focus; an unlabeled focused editor need not be an affordance.
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
        // A position-derived handle inside a list row: rows are recycled as the list scrolls, so its position cannot prove which record it is.
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

        guard let live = MacActClosedLoop.liveIdentity(entry: entry, percept: identityPercept) else {
            return injectionRefusal(action: "act", error: "handle_drifted", status: 409)
        }
        let target: MacAXActTarget
        switch accessibilityActSource(context: context).resolve(path: live.path, inWindow: actWindow, context: context) {
        case .unavailable(let detail):
            return injectionRefusal(action: "act", error: "ax_evidence_unavailable", status: 409,
                extra: ["guidance": .string(detail), "posted_events": .int(0)])
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

        guard let currentEntry = MacLookFrame.entries(from: identityPercept)[handle] else {
            return injectionRefusal(action: "act", error: "handle_drifted", status: 409)
        }
        let entrySecret = entry.secret || currentEntry.secret
        entry = currentEntry
        // Check the resolved target against fresh rendered identity; prior batch input can change a value-derived label, while later path drift must still
        // refuse.
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

        // Identity comes from the retained observation; effect evidence starts NOW. Earlier batch steps must never prove this step's consequence. Identity
        // lookup is uncapped; effects use the same presentation cap on both sides so omitted controls cannot look like removals.
        let effectAffordanceCap = body["max_affordances"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacPerceptionCompiler.maxAffordances
        let effectPercept = MacPerceptionCompiler.compile(snapshot: identityScoped.snapshot,
            secretContext: MacScreenViewTextRedaction.nodeSecretContext(identityScoped.snapshot.nodes),
            app: identityScoped.app, windowTitle: identityScoped.rootTitle, focusPath: identityScoped.focusPath,
            maxAffordances: effectAffordanceCap, uncapped: frame.completeWindow)
        let effectBefore = MacLookFrame(frameId: frame.frameId, capturedAt: started,
            appName: frame.appName, bundleId: frame.bundleId, windowTitle: identityRead.rootTitle,
            entries: MacLookFrame.entries(from: effectPercept), pid: framePid,
            focusHandle: effectPercept.focus?.handle, hasModal: effectPercept.modal != nil,
            modalPath: effectPercept.modal?.path, readouts: MacLookFrame.readoutRecords(from: effectPercept),
            windowIdentity: actWindow.identity,
            caps: MacLookCompileCaps(truncated: effectPercept.truncated,
                maxAffordances: frame.completeWindow ? nil : effectAffordanceCap, maxNodes: frame.completeWindow ? nil : identityLimits.maxNodes,
                maxDepth: frame.completeWindow ? nil : identityLimits.maxDepth), completeWindow: frame.completeWindow)
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

        // Capture pre-input field value so readback can distinguish a change from unchanged state.
        let textBeforeInput = verb == .type ? accessibilityActSource(context: context).reread(target, context: context)?.value : nil
        let performedAt = now()
        let performed: MacActPerformed?
        let heldEffect: MacActClosedLoop.DeclaredEffect?
        switch verb {
        case .focus: heldEffect = .focus
        case .select: heldEffect = .selected
        case .type where typeMode == .replace && placement == nil: heldEffect = .text(text)
        default: heldEffect = nil
        }
        let held = heldEffect.map {
            MacActClosedLoop.verify($0, value: target.value,
                selected: identityScoped.snapshot.nodes.first { $0.path == live.path }?.attributes.selected,
                focused: accessibilityActSource(context: context).isFocusedElement(target, pid: framePid, context: context)
                    && accessibilityActSource(context: context).focusedWindow(pid: framePid, context: context)?.handle == actWindow.handle)
        }
        if held?.status == "acted" {
            performed = MacActPerformed(ok: true, method: "already_held", requestedAction: verb.rawValue,
                target: target, postState: target, actedHandle: handle,
                extra: ["already_held": .bool(true), "posted_events": .int(0)], expectedText: verb == .type ? text : nil)
        } else if let placement {
            performed = await placeInSavePanel(placement, target: target, window: actWindow, pid: framePid,
                                              handle: handle, frontBefore: frontBefore, turn: turn, context: context)
        } else { performed = await performAct(
            body: body, verb: verb,
            handle: handle,
            entry: entry,
            frame: effectBefore,
            framePid: framePid,
            actWindow: actWindow,
            target: target,
            text: text,
            typeMode: typeMode,
            direction: direction,
            background: background,
            keystrokes: body["keystrokes"] == .bool(true)
        , turn: turn, context: context) }
        await screenViewStore.invalidate()

        guard let performed else {
            // Missing mechanisms produce named refusals so unsupported verbs cannot report silent success.
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

        // No notification within wait_ms is an unobserved outcome, never proof that the action failed or did nothing.
        // Navigation waits for a transition, not a selection reaction; explicit `wait_ms` overrides the bounded default.
        let navigationVerb = MacActClosedLoop.navigationVerbs.contains(verb)
        let effectWaitMs = navigationVerb && body["wait_ms"]?.integerValue.flatMap(Int.init(exactly:)) == nil
            ? MacActClosedLoop.clampedWaitMs(MacActClosedLoop.navigationWaitMs)
            : waitMs
        var read: MacAXRead?
        var seam: [String: JSONValue] = [:]
        var postAnchor: MacAnchoredRead?
        var menuLeftOpen: Bool?
        let limits = Self.axLimits(from: body)
        let declaration: MacActClosedLoop.DeclaredEffect
        switch verb {
        case .hover: declaration = .pointer
        case .type: declaration = placement.map { .placement($0, performed.extra["directory_url_after"]?.stringValue) } ?? .text(performed.expectedText)
        case .focus: declaration = .focus
        case .select: declaration = .selected
        case .toggle:
            declaration = .state(["0": "1", "1": "0", "off": "on", "on": "off",
                                  "true": "false", "false": "true"][performed.target.value ?? ""])
        case .dismiss: declaration = .dismissed
        case .scroll: declaration = .scroll
        default: declaration = .surface(verb == .open ? entry.label : nil)
        }
        let actedEntry = entry
        // The read is an argument: the settle holds the only reference while it waits.
        func verdict(_ diff: MacActClosedLoop.EffectDiff?, selected: Bool? = nil, read: MacAXRead?) -> MacActClosedLoop.ActClassification {
            let entry = actedEntry
            let windowsAfter: [MacAXWindowRef]
            do { windowsAfter = try accessibilityActSource(context: context).windows(pid: framePid, context: context) }
            catch { return MacActClosedLoop.ActClassification(status: "acted_unobserved", reason: "window_readback_unavailable",
                note: "The action was delivered, but its window readback failed: " + error.localizedDescription + " Inspect this app before another action.") }
            if verb == .type, performed.method == "ax_set_value",
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
                focused: accessibilityActSource(context: context).focusedElement(pid: framePid, context: context).flatMap { _ in
                    accessibilityActSource(context: context).focusedWindow(pid: framePid, context: context).map {
                        accessibilityActSource(context: context).isFocusedElement(performed.target, pid: framePid, context: context) && $0.handle == actWindow
                            .handle
                    }
                },
                surfaceChanged: windowsAfter.contains { window in
                    !actWindows.contains { $0.handle == window.handle }
                } ? true : nil,
                dismissed: accessibilityActSource(context: context).windowPresence(actWindow, context: context).map { !$0 },
                processGone: accessibilitySource(context: context).appInfo(pid: framePid) == nil,
                diff: diff, notifications: collector.kinds(),
                pointerOnTarget: accessibilityActSource(context: context).reread(performed.target, context: context)?.frame.flatMap { frame in
                    self.pointerPositionSource.currentPosition().map { $0.isInside(frame) }
                },
                redactingText: entrySecret,
                // A readout verifies only after an element-by-element stable reread.
                press: verb == .click ? (effectBefore, entry, { row in
                    guard let node = read?.snapshot.nodes.first(where: { $0.path == row.path }), let element = node.element,
                          let fresh = self.accessibilitySource(context: context).attributes(of: element, context: context) else { return false }
                    return fresh.value == node.attributes.value && fresh.title == node.attributes.title
                }) : nil,
                destinationJSON: entry.labelJSON ?? .null,
                windowTitleJSON: read?.rootTitle.map { MacScreenViewTextRedaction.redactedLegendString($0, valueChars: limits.valueChars) })
        }

        var settledTarget: MacAXActTarget?
        var settledVerdict = MacActClosedLoop.ActClassification(status: "acted_unobserved", reason: "effect_unreadable")
        let signals = MacWaitSignals(collector: collector, startedAt: performedAt)
        defer { signals.stop() }
        _ = await macSettle("act", signals: signals, patience: Double(effectWaitMs) / 1000,
            until: navigationVerb ? MacActClosedLoop.navigationNotificationKinds.union(background ? ["AXMenuOpened"] : []) : []) {
            if background, collector.kinds().contains("AXMenuOpened"), menuLeftOpen == nil {
                menuLeftOpen = self.accessibilityActSource(context: context).perform(
                    performed.target, action: "AXCancel", turn: turn, context: context) != .performed
            }
            (read, seam, postAnchor) = await self.lookSnapshot(
                limits: limits, scope: MacLookScope.parse(body["scope"]?.stringValue) ?? .page,
                anchorPid: framePid, anchorWindow: frame.windowIdentity, completeWindow: frame.completeWindow, context: context)
            var passDiff: MacActClosedLoop.EffectDiff?
            if let read, seam["window_minimized"] != .bool(true) {
                let percept = MacPerceptionCompiler.compile(snapshot: read.snapshot,
                    secretContext: MacScreenViewTextRedaction.nodeSecretContext(read.snapshot.nodes),
                    app: read.app, windowTitle: read.rootTitle, focusPath: read.focusPath,
                    maxAffordances: effectAffordanceCap, uncapped: frame.completeWindow)
                passDiff = MacActClosedLoop.diff(before: effectBefore, after: percept, afterWindowTitle: read.rootTitle,
                    afterCaps: MacLookCompileCaps(truncated: percept.truncated,
                        maxAffordances: frame.completeWindow ? nil : effectAffordanceCap,
                        maxNodes: frame.completeWindow ? nil : limits.maxNodes, maxDepth: frame.completeWindow ? nil : limits.maxDepth))
            }
            settledTarget = self.accessibilityActSource(context: context).reread(performed.target, context: context)
            settledVerdict = verdict(passDiff, selected: read?.snapshot.nodes.first { $0.path == live.path }?.attributes.selected, read: read)
            return settledVerdict.status == "acted" || menuLeftOpen != nil
        }
        observation?.stop()
        let wait = MacActClosedLoop.effectWait(collector: collector, startedAt: performedAt)
        let redactValue = verb == .type
        var effect: [String: JSONValue] = [
            "observed": .bool(wait.observed),
            "observer_installed": .bool(observerInstalled),
            "wait_ms": .int(Int64(effectWaitMs)),
            "notifications": .array(wait.notifications.map { .string($0) }),
            "notification_count": .int(Int64(wait.notificationCount)),
            "acted_element": .object([
                "handle": .string(performed.actedHandle),
                "before": MacActReceiptRendering.actedElementJSON(
                    performed.target,
                    redactingValue: redactValue || entrySecret,
                    labelJSON: entry.labelJSON,
                    valueJSON: entry.valueJSON
                ),
                // Post-act reads lack caption context; preserve the frame's secret verdict and expose only a digest for values it withheld.
                "after": settledTarget.map {
                    MacActReceiptRendering.actedElementJSON(
                        $0,
                        redactingValue: redactValue || entrySecret,
                        labelJSON: entrySecret ? entry.labelJSON : nil
                    )
                } ?? .null,
            ]),
        ]
        if let firstMs = wait.firstNotificationMs {
            effect["first_notification_ms"] = .int(Int64(firstMs))
        }
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
            "path": .array(live.path.map { .int(Int64($0)) }),
            "seam": .object(seam),
            // Leave the verdict unset until post-action evidence arrives.
            "verified": .bool(false),
            "value_redacted": .bool(redactValue),
        ]
        // Report positional ambiguity even when ordinal handles remain actionable.
        if entry.ambiguous {
            output["handle_ambiguous"] = .bool(true)
            output["handle_ambiguity"] = .string(
                "that handle was a position-derived ordinal among identical elements — it names "
                + "whatever now sits at that position; re-look if the container may have reordered"
            )
        }
        for (key, value) in performed.extra { output[key] = value }
        if let error = performed.error { output["error"] = .string(error) }
        // Compare front-app reads so the receipt reports whether this act touched the person's screen.
        let frontAfter = accessibilitySource(context: context).frontmostApp()
        output["front_app_changed"] = .bool(frontBefore?.processIdentifier != frontAfter?.processIdentifier)
        output["background"] = .bool(background)
        if let menuLeftOpen {
            output["menu_opened"] = .bool(true)
            output["menu_left_open"] = .bool(menuLeftOpen)
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
            effect["percept"] = .string(percept)
            if performed.ok {
                let classification = settledVerdict
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
            // Anchor focus to the same root and epoch as the post-act walk.
            focusPath: read.focusPath,
            maxAffordances: body["max_affordances"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacPerceptionCompiler.maxAffordances,
            uncapped: frame.completeWindow
        )
        // Record compile bounds so census comparison cannot mistake truncation for navigation.
        let afterCaps = MacLookCompileCaps(
            truncated: after.truncated,
            maxAffordances: frame.completeWindow ? nil : body["max_affordances"]?.integerValue.flatMap(Int.init(exactly:))
                ?? MacPerceptionCompiler.maxAffordances,
            maxNodes: frame.completeWindow ? nil : limits.maxNodes,
            maxDepth: frame.completeWindow ? nil : limits.maxDepth
        )
        let diff = MacActClosedLoop.diff(
            before: effectBefore,
            after: after,
            afterWindowTitle: read.rootTitle,
            afterCaps: afterCaps
        )
        for (key, value) in MacActReceiptRendering.effectDiffJSON(diff, valueChars: limits.valueChars) {
            effect[key] = value
        }
        // One verdict from the declared effect and the target's own AX state.
        let classification = settledVerdict
        if performed.ok { output.merge(classification.receipt) { _, new in new } }
        effect["observed"] = .bool(performed.ok && classification.status != "acted_unobserved")
        if let reason = classification.reason { effect["reason"] = .string(reason) }
        else { effect.removeValue(forKey: "reason") }
        // Bulk changes include role counts and focus context alongside capped rows.
        if diff.addedTotal > MacActClosedLoop.maxDiffRows {
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
            context.capture?.walked = (read, seam)
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
            windowIdentity: read.windowIdentity ?? frame.windowIdentity,
            caps: afterCaps,
            completeWindow: frame.completeWindow
        ), context: context)
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

    /// Use the shared actuator and event sink so every verb retains their gates. Unsupported mechanisms return nil for a named refusal. Cursor restoration
    /// compares two reads; unreadable positions stay unknown. Only subpixel noise is tolerated because the nudge itself moves one point, and a one-point
    /// tolerance would falsely verify a cursor left displaced.
    static func pointerRestoredJSON(before: MacSessionState, after: MacSessionState) -> JSONValue {
        guard let bx = before.cursorX, let by = before.cursorY,
              let ax = after.cursorX, let ay = after.cursorY else { return .null }
        return .bool(abs(ax - bx) < 0.5 && abs(ay - by) < 0.5)
    }
}

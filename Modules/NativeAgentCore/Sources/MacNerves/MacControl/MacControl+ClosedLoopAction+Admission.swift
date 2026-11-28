import Foundation
import NativeAgentShared
import NativeAgentCore
import DeskCore
import PersistenceCore
import AppKit
import CoreGraphics
import UserNotifications
// Blueprint: | `MacControl+ClosedLoopAction+Admission.swift` | `SwiftNativeMacControl`: `parseActRequest`, `anchorActFrame`, `matchActWindow`, `readActIdentity`, `resolveActTarget`, `refreshActEntry` (the act's admission gates, in order: its fields, its recorded frame and process, the same window by persistent identity, a fresh identity read, the live target and its current rendered entry; each refuses before anything is touched) |

extension SwiftNativeMacControl {
    /// Parse the act's fields; a malformed field is refused before anything is read.
    func parseActRequest(_ body: [String: JSONValue], restoringText: Bool) -> MacActGate<MacActRequest> {
        // Refuse malformed fields rather than inventing a target.
        guard let rawVerb = body["verb"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawVerb.isEmpty else {
            return .refused(injectionRefusal(
                action: "act",
                error: "missing required field: verb (one of \(MacActVerb.allCases.map(\.rawValue).joined(separator: ", ")))",
                status: 400
            ))
        }
        guard let verb = MacActVerb(rawValue: rawVerb.lowercased()) else {
            return .refused(injectionRefusal(
                action: "act",
                error: "unknown_verb: \(rawVerb) is not one of "
                    + MacActVerb.allCases.map(\.rawValue).joined(separator: ", "),
                status: 400
            ))
        }
        guard let handle = body["handle"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !handle.isEmpty else {
            return .refused(injectionRefusal(
                action: "act",
                error: "missing required field: handle (from the latest mac.look)",
                status: 400
            ))
        }
        guard let frameId = body["frame_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !frameId.isEmpty else {
            return .refused(injectionRefusal(
                action: "act",
                error: "missing required field: frame_id (the frame_id mac.look returned with that handle)",
                status: 400
            ))
        }
        let text = body["text"]?.stringValue
        let typeMode: MacTypeMode
        if let raw = body["mode"], raw != .null, raw != .string("") {
            guard case .string(let value) = raw, let parsed = MacTypeMode(rawValue: value),
                  parsed == .replace || verb == .type else {
                return .refused(injectionRefusal(action: "act", error: "invalid_type_mode: use replace or append; append requires type", status: 400))
            }
            typeMode = parsed
        } else {
            typeMode = .replace
        }
        if verb == .type, text == nil || (text == "" && !restoringText) {
            return .refused(injectionRefusal(
                action: "act",
                error: "missing required field: text (verb \"type\" needs the characters to type)",
                status: 400
            ))
        }
        guard verb == .scroll || ["direction", "scroll_amount"].allSatisfy({ body[$0] == nil || body[$0] == .null }) else {
            return .refused(injectionRefusal(action: "act", error: "Only scroll takes direction and scroll_amount", status: 400))
        }
        let direction: MacActScrollDirection
        if let raw = body["direction"], raw != .null {
            guard let value = raw.trimmedString?.lowercased(), let parsed = MacActScrollDirection(rawValue: value) else {
                return .refused(injectionRefusal(action: "act", error: "unknown_direction: direction must be up, down, left or right", status: 400))
            }
            direction = parsed
        } else { direction = .down }
        let scrollAmount: Int
        if let raw = body["scroll_amount"], raw != .null {
            guard let value = raw.exactIntegerValue, (0...120).contains(value) else {
                return .refused(injectionRefusal(action: "act",
                    error: "invalid_scroll_amount: scroll_amount must be an integer from 0 to 120; 0 means default", status: 400))
            }
            scrollAmount = value
        } else { scrollAmount = 0 }
        let afterFields = body["after"]?.objectValue
        let cleanupFields = body["cleanup"]?.objectValue
        let after = afterFields?["value"]?.stringValue
        let withinMs = afterFields?["within_ms"]?.exactIntegerValue
        let waitMs = MacActClosedLoop.clampedWaitMs(withinMs ?? body["wait_ms"]?.integerValue.flatMap(Int.init(exactly:)))
        let restoreText = cleanupFields != nil
        let hasAfter = body["after"] != nil && body["after"] != .null
        let hasCleanup = body["cleanup"] != nil && body["cleanup"] != .null
        if hasAfter || hasCleanup {
            guard verb == .type, typeMode == .replace, body["keystrokes"] != .bool(true), let afterFields,
                  afterFields["expect"] == .string("text"),
                  afterFields.keys.allSatisfy({ ["expect", "value", "target", "within_ms"].contains($0) }),
                  afterFields["target"] == nil || afterFields["target"] == .string(handle),
                  afterFields["within_ms"] == nil || withinMs.map({ (0...MacActClosedLoop.maxWaitMs).contains($0) }) == true,
                  let after, after.utf8.count == 64, after.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                return .refused(injectionRefusal(action: "act", error: "invalid_reversible_deed", status: 400,
                    extra: ["effects": .string("none"), "guidance": .string("Use exact type/replace with after.expect text and after.value a lowercase UTF-8 SHA-256. surface, state, selected, focus, dismissed, window_title and ax_path_exists are unavailable.")]))
            }
            if hasCleanup {
                guard let cleanupFields, cleanupFields["verb"] == .string("restore_text"),
                      cleanupFields["when"] == .string("mismatch"),
                      cleanupFields.keys.allSatisfy({ ["verb", "when", "reversible_only", "target"].contains($0) }),
                      cleanupFields["target"] == nil || cleanupFields["target"] == .string(handle),
                      cleanupFields["reversible_only"] == nil || cleanupFields["reversible_only"] == .bool(true),
                      !restoringText else {
                    return .refused(injectionRefusal(action: "act", error: "unsupported_deed_cleanup", status: 400,
                        extra: ["effects": .string("none"), "guidance": .string("cleanup requires verb restore_text and when mismatch. press, key, dismiss and unobserved are unavailable.")]))
                }
            }
        }
        // Anchored background AX actions stay in their app; work needing foreground input returns `needs_front` without raising.
        let background = body["background"] == .bool(true)
        return .admitted(MacActRequest(verb: verb, handle: handle, frameId: frameId, text: text, typeMode: typeMode, direction: direction,
            scrollAmount: scrollAmount, waitMs: waitMs, background: background, after: after, restoreText: restoreText))
    }

    /// Resolve the handle in its recorded frame and admit the act on the frame's own process.
    func anchorActFrame(_ body: [String: JSONValue], handle: String, frameId: String, started: Date, turn: Turn,
                        context: MacOperationContext) async -> MacActGate<(entry: MacLookFrameEntry, frame: MacLookFrame, framePid: Int32)> {
        // Frame resolution failures retain their own remedies so callers cannot blindly retry against a changed screen.
        let resolved = await lookFrameStore.resolve(handle: handle, frameId: frameId, now: started, context: context)
        let entry: MacLookFrameEntry
        switch resolved {
        case .failure(let failure):
            return .refused(injectionRefusal(
                action: "act",
                error: failure.rawValue,
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "frame_id": .string(frameId),
                    "guidance": .string(failure.guidance),
                ]
            ))
        case .success(let hit):
            entry = hit
        }
        guard let frame = await lookFrameStore.frame(frameId: frameId, context: context) else {
            return .refused(injectionRefusal(
                action: "act",
                error: MacLookFrameStore.ResolveFailure.noFrame.rawValue,
                status: 409,
                extra: ["guidance": .string(MacLookFrameStore.ResolveFailure.noFrame.guidance)]
            ))
        }

        // Recheck the system grant and physical-input priority before resolving an action target.
        if let refusal = injectionPreconditions(action: "act", requiresSink: false, context: context) {
            return .refused(refusal)
        }
        if let refusal = await attentionActionRefusal(action: "act", body: body, turn: turn, context: context) {
            return .refused(refusal)
        }

        // Resolve only through the actuator in the frame's pid; frontmost-app changes must not retarget the action.
        guard let framePid = frame.pid else {
            return .refused(injectionRefusal(
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
            ))
        }
        if let continuation = turn.macContinuation, continuation.isPending,
           let captured = continuation.window {
            guard framePid == captured.pid, let observed = frame.windowIdentity,
                  observed.role == captured.role, observed.subrole == captured.subrole,
                  observed.title == captured.title, observed.frame == captured.frame else {
                return .refused(injectionRefusal(action: "act", error: "continuation_target_mismatch", status: 409,
                    extra: ["guidance": .string(continuation.modelContext(context: context))]))
            }
        }
        // A recorded frame cannot authorize touching person-only UI.
        if PersonOnlyWindows.isOwnProcess(framePid) {
            await lookFrameStore.invalidate()
            return .refused(injectionRefusal(
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
            ))
        }
        if let refusal = await macAdmissionRefusal(pid: framePid, action: "act", reading: false, context: context) { return .refused(refusal) }
        return .admitted((entry, frame, framePid))
    }

    /// Find the frame's own window among the app's windows now, by persistent identity.
    func matchActWindow(handle: String, frame: MacLookFrame, framePid: Int32,
                        context: MacOperationContext) -> MacActGate<(actWindows: [MacAXWindowRef], actWindow: MacAXWindowRef)> {
        // Match the observed window by persistent identity; missing or ambiguous matches refuse instead of choosing current focus.
        let actWindows: [MacAXWindowRef]
        do { actWindows = try accessibilityActSource(context: context).windows(pid: framePid, context: context) }
        catch { return .refused(injectionRefusal(action: "act", error: "window_evidence_unavailable", status: 409,
            extra: ["guidance": .string(error.localizedDescription), "posted_events": .int(0), "effects": .string("none")])) }
        if actWindows.isEmpty, MacScreenLock.isLocked() {
            return .refused(injectionRefusal(
                action: "act",
                error: "display_obstructed",
                status: 409,
                extra: ["guidance": .string(MacScreenLock.reply)]
            ))
        }
        guard !actWindows.isEmpty else {
            return .refused(injectionRefusal(
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
            ))
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
                return .refused(injectionRefusal(
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
                ))
            case .ambiguous(let reason):
                return .refused(injectionRefusal(
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
                ))
            }
        } else {
            return .refused(injectionRefusal(action: "act", error: "window_identity_unavailable", status: 409,
                extra: ["handle": .string(handle), "posted_events": .int(0),
                    "guidance": .string("This frame has no window identity. Call mac.look again to observe the exact window before acting.")]))
        }
        return .admitted((actWindows, actWindow))
    }

    /// Read the frame's window afresh, in the look's scope, and compile it for identity checks.
    func readActIdentity(_ body: [String: JSONValue], handle: String, frame: MacLookFrame, framePid: Int32, context: MacOperationContext) async
        -> MacActGate<(identityLimits: MacAXLimits, identityRead: MacAXRead, identityScoped: MacAXRead, identityPercept: MacLookPercept)> {
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
            return .refused(injectionRefusal(
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
            ))
        }
        // Reuse the look's scope so a page handle is not compared with a window walk that cannot reach it.
        let identityScoped: MacAXRead
        do {
            identityScoped = try pageScoped(identityRead, limits: identityLimits,
                scope: MacLookScope.parse(body["scope"]?.stringValue) ?? .page,
                completeWindow: frame.completeWindow, context: context).read
        } catch {
            return .refused(injectionRefusal(action: "act", error: "renderer_classification_unavailable", status: 409,
                extra: ["guidance": .string(error.localizedDescription), "posted_events": .int(0)]))
        }
        let identityPercept = MacPerceptionCompiler.compile(
            snapshot: identityScoped.snapshot,
            secretContext: MacScreenViewTextRedaction.nodeSecretContext(identityScoped.snapshot.nodes),
            app: identityScoped.app,
            windowTitle: identityScoped.rootTitle,
            focusPath: identityScoped.focusPath,
            uncapped: true
        )
        return .admitted((identityLimits, identityRead, identityScoped, identityPercept))
    }

    /// Prove the handle still names its control in the fresh read, then resolve it to a live target inside the matched window.
    func resolveActTarget(entry: MacLookFrameEntry, handle: String, frame: MacLookFrame, framePid: Int32, actWindow: MacAXWindowRef,
                          identityScoped: MacAXRead, identityPercept: MacLookPercept,
                          verb: MacActVerb, context: MacOperationContext) -> MacActGate<(live: MacLookAffordance, target: MacAXActTarget)> {
        // Resolve through every channel that can mint a frame entry, including focus; an unlabeled focused editor need not be an affordance.
        if let drift = MacActClosedLoop.identityDrift(
            entry: entry,
            live: MacActClosedLoop.liveIdentity(entry: entry, percept: identityPercept)
        ) {
            return .refused(injectionRefusal(
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
            ))
        }
        // A position-derived handle inside a list row: rows are recycled as the list scrolls, so its position cannot prove which record it is.
        if entry.ambiguous, identityScoped.snapshot.nodes.contains(where: {
            MacLookHandle.contentIdentityRoles.contains($0.attributes.role) && entry.path.starts(with: $0.path)
        }) {
            return .refused(injectionRefusal(
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
            ))
        }

        guard let live = MacActClosedLoop.liveIdentity(entry: entry, percept: identityPercept) else {
            return .refused(injectionRefusal(action: "act", error: "handle_drifted", status: 409))
        }
        let target: MacAXActTarget
        switch accessibilityActSource(context: context).resolve(path: live.path, inWindow: actWindow, readEnabled: verb != .scroll, context: context) {
        case .unavailable(let detail):
            return .refused(injectionRefusal(action: "act", error: "ax_evidence_unavailable", status: 409,
                extra: ["guidance": .string(detail), "posted_events": .int(0)]))
        case .resolved(let hit):
            target = hit
        case .windowGone:
            return .refused(injectionRefusal(
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
            ))
        case .appGone:
            return .refused(injectionRefusal(
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
            ))
        case .pathNotFound, .menuPathDrifted:
            return .refused(injectionRefusal(
                action: "act",
                error: MacAccessibilityActuator.pathNotFoundError,
                status: 404,
                extra: [
                    "handle": .string(handle),
                    "path": .array(entry.path.map { .int(Int64($0)) }),
                    "pid": .int(Int64(framePid)),
                    "guidance": .string("the element that handle named is gone — call mac.look again"),
                ]
            ))
        }
        return .admitted((live, target))
    }

    /// Take the handle's current rendered entry and check the resolved target still answers to it.
    func refreshActEntry(_ entry: MacLookFrameEntry, verb: MacActVerb, text: String?, handle: String, target: MacAXActTarget,
                         identityPercept: MacLookPercept) -> MacActGate<(placement: MacSavePanelPlacement?, entrySecret: Bool, entry: MacLookFrameEntry)> {
        var entry = entry
        let placement = verb == .type && MacSavePanelPlacement.isNameField(role: target.role, label: target.title)
            ? text.flatMap(MacSavePanelPlacement.split) : nil

        guard let currentEntry = MacLookFrame.entries(from: identityPercept)[handle] else {
            return .refused(injectionRefusal(action: "act", error: "handle_drifted", status: 409))
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
            return .refused(injectionRefusal(
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
            ))
        }
        return .admitted((placement, entrySecret, entry))
    }
}

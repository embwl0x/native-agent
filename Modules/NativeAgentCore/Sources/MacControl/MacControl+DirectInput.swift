import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CoreGraphics)
import CoreGraphics
// Blueprint: | `MacControl+DirectInput.swift` | `SwiftNativeMacControl`: `handleKeystroke`, `handleClick`, `handleScroll` |
#endif

extension SwiftNativeMacControl {
    /// A mark is a reference into the latest view, not injection authority. Dispatch retains its policy and execution gates.
    private enum MarkResolution {
        case absent
        case resolved(MacScreenViewMark, MacScreenViewSnapshot)
        case refused(MacControlResult)
    }

    private func resolveMarkReference(
        action: String,
        body: [String: JSONValue]
    ) async -> MarkResolution {
        guard let mark = body["mark"]?.integerValue.flatMap(Int.init(exactly:)) else { return .absent }
        guard let viewId = body["view"]?.stringValue,
              !viewId.isEmpty else {
            return .refused(injectionRefusal(
                action: action,
                error: "missing required field: view (the view id mac_view returned with this mark)",
                status: 400,
                extra: ["mark": .int(Int64(mark))]
            ))
        }
        switch await screenViewStore.resolve(viewId: viewId, mark: mark, now: now()) {
        case .success(let hit):
            guard let snapshot = await screenViewStore.snapshot(viewId: viewId) else {
                return .refused(injectionRefusal(action: action, error: "stale_view", status: 409))
            }
            return .resolved(hit, snapshot)
        case .failure(let failure):
            return .refused(injectionRefusal(
                action: action,
                error: "\(failure.rawValue): \(failure.guidance)",
                status: 409,
                extra: [
                    "mark": .int(Int64(mark)),
                    "view": .string(viewId),
                    "mark_resolution": .string(failure.rawValue),
                ]
            ))
        }
    }

    /// Resolve only in the captured window. Only observed names establish element identity; unnamed or unreadable marks need a fresh semantic target. A row
    /// named by its own child text re-resolves by it.
    private func liveMarkedTarget(
        _ mark: MacScreenViewMark,
        snapshot: MacScreenViewSnapshot,
        context: MacOperationContext
    ) throws -> MacAXActTarget? {
        guard let identity = snapshot.windowIdentity,
              !PersonOnlyWindows.isOwnProcess(identity.pid),
              accessibilitySource(context: context).frontmostApp()?.processIdentifier == identity.pid,
              let label = mark.label, !label.isEmpty,
              ["title", "value", "descendant_text"].contains(mark.labelSource)
        else { return nil }
        let windows = try accessibilityActSource(context: context).windows(pid: identity.pid, context: context)
        guard case .matched(let window, _) = MacAXWindowIdentity.match(
            identity, among: windows.map { (handle: $0, identity: $0.identity) }
        ), let focused = accessibilityActSource(context: context).focusedWindow(pid: identity.pid, context: context),
           focused.handle == window.handle,
           let target = try accessibilityActSource(context: context).uniqueTarget(
               role: mark.role, label: label, labelSource: mark.labelSource, inWindow: window
           , context: context), target.enabled
        else { return nil }
        return target
    }

    /// Type text before chords so combined input executes in the submitted order; at least one is required.
    func handleKeystroke(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult {
        let started = now()
        let rawText = body["text"]?.stringValue
        let rawKeys = body["keys"]?.stringValue
        if (rawText?.isEmpty ?? true) && (rawKeys?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return injectionRefusal(
                action: "keystroke",
                error: "missing required field: text|keys",
                status: 400
            )
        }
        var text: String?
        var chords: [MacKeyChord] = []
        do {
            if let rawText, !rawText.isEmpty {
                text = try MacKeySyntax.validateText(rawText)
            }
            if let rawKeys, !rawKeys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chords = try MacKeySyntax.parseChords(rawKeys)
            }
        } catch {
            // Parse failure is a 400, and NOTHING is emitted — a half-understood chord spec must never be partially executed.
            let message = (error as? MacKeySyntaxError)?.errorDescription ?? "\(error)"
            return injectionRefusal(action: "keystroke", error: message, status: 400)
        }
        if let refusal = injectionPreconditions(action: "keystroke", requiresSink: true, context: context) {
            return refusal
        }
        // Secure keyboard entry discards synthesized keys; refuse before posting rather than claiming they were typed.
        if let refusal = MacActClosedLoop.secureInputRefusal(
            active: eventSink.secureKeyboardEntryActive
        ) {
            return injectionRefusal(
                action: "keystroke",
                error: refusal.reason,
                extra: ["note": .string(refusal.note), "key_events": .int(0)]
            )
        }

        let plan = text.map { MacHandRepertoire.type(text: $0) } ?? []
        let execution = await executeHand(plan + chords.flatMap(MacHandRepertoire.chord), action: "keystroke", body: body, turn: turn, context: context)
        await screenViewStore.invalidate()
        if let refusal = execution.refusal { return refusal }
        return MacControlResult(
            ok: true,
            action: "keystroke",
            output: .object([
                "ok": .bool(true),
                "status": .string("typed"),
                // Receipts expose counts; the operation store retains no payload or result.
                "text_characters": .int(Int64(text?.count ?? 0)),
                "chords": .array(chords.map { $0.toJSON() }),
                "key_events": .int(Int64(execution.emitted)),
                // The window server acknowledges nothing; we emitted events, we did not observe an effect.
                "verified": .bool(false),
            ]),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }

    /// Point clicks and two-point drags share the same physical input owner and gates.
    func handleClick(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult {
        let started = now()
        // Marks retain the captured window; live geometry is resolved at injection.
        var markedTarget: MacScreenViewMark?
        var markedSnapshot: MacScreenViewSnapshot?
        switch await resolveMarkReference(action: "click", body: body) {
        case .refused(let refusal): return refusal
        case .resolved(let hit, let snapshot):
            markedTarget = hit
            markedSnapshot = snapshot
        case .absent: break
        }
        let button: MacMouseButton
        if let supplied = body["button"] {
            guard let raw = supplied.stringValue?.lowercased(), let parsed = MacMouseButton(rawValue: raw) else {
                return injectionRefusal(action: "click", error: "button must be left or right", status: 400)
            }
            button = parsed
        } else { button = body["right"] == .bool(true) ? .right : .left }
        if let right = body["right"], right != .bool(true), right != .bool(false) {
            return injectionRefusal(action: "click", error: "right must be a boolean", status: 400)
        }
        let durationMs: Int
        if let supplied = body["duration_ms"] {
            guard let ms = supplied.integerValue.flatMap(Int.init(exactly:)), (80...2_000).contains(ms) else {
                return injectionRefusal(action: "click", error: "duration_ms must be an integer in 80...2000", status: 400)
            }
            durationMs = ms
        } else { durationMs = 240 }

        func point(_ key: String) -> (Double, Double)? {
            if case .object(let obj)? = body[key],
               let x = obj["x"]?.numberValue(coercingStrings: false, finiteOnly: true), let y = obj["y"]?.numberValue(coercingStrings: false,
                   finiteOnly: true) {
                return (x, y)
            }
            if let x = body["\(key)_x"]?.numberValue(coercingStrings: false, finiteOnly: true), let y = body["\(key)_y"]?.numberValue(coercingStrings: false,
                finiteOnly: true) {
                return (x, y)
            }
            return nil
        }

        // Approval and execution must name the same single target.
        if let markedTarget {
            let coordinateKeys = ["x", "y", "from", "to", "from_x", "from_y", "to_x", "to_y"]
            let conflicting = coordinateKeys.filter { body[$0] != nil && body[$0] != .null }
            if !conflicting.isEmpty {
                return injectionRefusal(
                    action: "click",
                    error: "ambiguous_target: this call names both mark \(markedTarget.mark) "
                        + "and coordinates (\(conflicting.sorted().joined(separator: ", "))); "
                        + "send one or the other",
                    status: 400,
                    extra: [
                        "mark": .int(Int64(markedTarget.mark)),
                        "conflicting_fields": .array(conflicting.sorted().map { .string($0) }),
                    ]
                )
            }
        }

        let plan: [MacHandStep]
        var describe: [String: JSONValue]
        if let markedTarget {
            let x = markedTarget.frame.x + markedTarget.frame.w / 2.0
            let y = markedTarget.frame.y + markedTarget.frame.h / 2.0
            var count = body["count"]?.integerValue.flatMap(Int.init(exactly:)) ?? 1
            if case .bool(true)? = body["double"] { count = max(count, 2) }
            count = max(1, min(count, 3))
            plan = MacHandRepertoire.click(button: button, at: CGPoint(x: x, y: y), count: count)
            describe = [
                "gesture": .string("click"),
                "targeted_by": .string("mark"),
                "mark": .int(Int64(markedTarget.mark)),
                // Stored labels are raw; receipt serialization must redact them.
                "element": .object([
                    "role": .string(markedTarget.role),
                    "label": markedTarget.label.map {
                        MacScreenViewTextRedaction.redactedLegendString(
                            $0,
                            valueChars: MacAXLimits.hardValueChars,
                            enclosing: markedTarget.enclosingCaption
                        )
                    } ?? .null,
                    "path": .array(markedTarget.path.map { .int(Int64($0)) }),
                ]),
                "x": .double(x),
                "y": .double(y),
                "count": .int(Int64(count)),
            ]
        } else if let from = point("from"), let to = point("to") {
            let steps = max(4, min(60, durationMs / 16))
            let start = CGPoint(x: from.0, y: from.1)
            let end = CGPoint(x: to.0, y: to.1)
            let delay = UInt64(durationMs) * 1_000_000 / UInt64(steps)
            do {
                let drag = try MacHandRepertoire.drag(button: button, from: start, to: end, steps: steps)
                // Raw drags wait after the press and each move, including the last.
                plan = MacHandRepertoire.move(to: start, button: button) + drag.flatMap { step in
                    if case .mouse(let event) = step, event.phase == .down || event.phase == .drag {
                        return [step, .wait(.nanoseconds(delay))]
                    }
                    return [step]
                }
            } catch {
                return injectionRefusal(action: "click", error: "invalid drag: \(error)", status: 400)
            }
            describe = [
                "gesture": .string("drag"),
                "from": .object(["x": .double(from.0), "y": .double(from.1)]),
                "to": .object(["x": .double(to.0), "y": .double(to.1)]),
                "duration_ms": .int(Int64(durationMs)),
                "drag_steps": .int(Int64(steps)),
            ]
        } else {
            guard let x = body["x"]?.numberValue(coercingStrings: false, finiteOnly: true), let y = body["y"]?.numberValue(coercingStrings: false,
                finiteOnly: true) else {
                return injectionRefusal(
                    action: "click",
                    error: "missing required field: x,y (or from/to for a drag)",
                    status: 400
                )
            }
            var count = body["count"]?.integerValue.flatMap(Int.init(exactly:)) ?? 1
            if case .bool(true)? = body["double"] { count = max(count, 2) }
            count = max(1, min(count, 3))
            plan = MacHandRepertoire.click(button: button, at: CGPoint(x: x, y: y), count: count)
            describe = [
                "gesture": .string("click"),
                "x": .double(x),
                "y": .double(y),
                "count": .int(Int64(count)),
            ]
        }

        if let refusal = injectionPreconditions(action: "click", requiresSink: true, context: context) {
            return refusal
        }
        var pressed = false
        var lastPosted: MacMouseEvent?
        let execution = await executeHand(plan, action: "click", body: body, turn: turn, context: context) { step in
            guard case .mouse(var event) = step else { return nil }
            if let markedTarget, let markedSnapshot {
                let x: Double
                let y: Double
                if event.phase == .up, pressed, let lastPosted {
                    // Mouse-down may itself change the label or remove the target. Finish that click at its accepted position.
                    x = lastPosted.x
                    y = lastPosted.y
                } else {
                    let live: MacAXActTarget?
                    do { live = try liveMarkedTarget(markedTarget, snapshot: markedSnapshot, context: context) }
                    catch { return injectionRefusal(action: "click", error: "ax_evidence_unavailable", status: 409,
                        extra: ["guidance": .string(error.localizedDescription)]) }
                    guard let target = live,
                          let centre = target.centre else {
                        return injectionRefusal(action: "click", error: "mark_drifted: take a fresh view", status: 409)
                    }
                    x = centre.x
                    y = centre.y
                }
                event = MacMouseEvent(
                    phase: event.phase, button: event.button, x: x, y: y,
                    clickCount: event.clickCount, modifiers: event.modifiers
                )
                describe["x"] = .double(x)
                describe["y"] = .double(y)
            }
            step = .mouse(event)
            lastPosted = event
            if event.phase == .down { pressed = true }
            if event.phase == .up { pressed = false }
            return nil
        }
        await screenViewStore.invalidate()
        if let refusal = execution.refusal { return refusal }

        describe["ok"] = .bool(true)
        describe["status"] = .string("clicked")
        describe["button"] = .string(button.rawValue)
        describe["mouse_events"] = .int(Int64(execution.emitted))
        describe["verified"] = .bool(false)
        return MacControlResult(
            ok: true,
            action: "click",
            output: .object(describe),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }

    /// Aim optional pointer moves before scrolling so wheel events reach the intended view.
    func handleScroll(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult {
        let started = now()
        let dy = body["dy"]?.integerValue.flatMap(Int.init(exactly:)) ?? 0
        let dx = body["dx"]?.integerValue.flatMap(Int.init(exactly:)) ?? 0
        if dx == 0 && dy == 0 {
            return injectionRefusal(
                action: "scroll",
                error: "missing required field: dx|dy (a zero scroll is not an action)",
                status: 400
            )
        }
        // Bounded: a runaway delta is a denial-of-attention event.
        let clampedX = Int32(max(-10_000, min(dx, 10_000)))
        let clampedY = Int32(max(-10_000, min(dy, 10_000)))
        let unit: MacScrollUnit
        if let supplied = body["units"] {
            guard let raw = supplied.stringValue?.lowercased(), let parsed = MacScrollUnit(rawValue: raw) else {
                return injectionRefusal(action: "scroll", error: "units must be line or pixel", status: 400)
            }
            unit = parsed
        } else { unit = .line }
        let at: (Double, Double)? = {
            guard let x = body["x"]?.numberValue(coercingStrings: false, finiteOnly: true), let y = body["y"]?.numberValue(coercingStrings: false,
                finiteOnly: true) else { return nil }
            return (x, y)
        }()

        if let refusal = injectionPreconditions(action: "scroll", requiresSink: true, context: context) {
            return refusal
        }
        let plan = (at.map { [MacHandStep.mouse(MacMouseEvent(phase: .move, button: .left, x: $0.0, y: $0.1))] } ?? [])
            + MacHandRepertoire.scroll(dx: clampedX, dy: clampedY, unit: unit)
        let execution = await executeHand(plan, action: "scroll", body: body, turn: turn, context: context)
        await screenViewStore.invalidate()
        if let refusal = execution.refusal { return refusal }

        var output: [String: JSONValue] = [
            "ok": .bool(true),
            "status": .string("scrolled"),
            "dx": .int(Int64(clampedX)),
            "dy": .int(Int64(clampedY)),
            "units": .string(unit.rawValue),
            "verified": .bool(false),
        ]
        if let at {
            output["x"] = .double(at.0)
            output["y"] = .double(at.1)
        }
        return MacControlResult(
            ok: true,
            action: "scroll",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }

    /// Run the resolved element's advertised AX action. Unreadable action names retain their cause; pointer or keyboard input must never substitute.
    func handleAXAct(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult {
        let started = now()
        // Marks carry their captured window through to the actuator.
        var markedTarget: MacScreenViewMark?
        var markedSnapshot: MacScreenViewSnapshot?
        switch await resolveMarkReference(action: "ax_act", body: body) {
        case .refused(let refusal): return refusal
        case .resolved(let hit, let snapshot):
            markedTarget = hit
            markedSnapshot = snapshot
        case .absent: break
        }
        // A malformed path must never become []: that names the window itself.
        let rawPath: [JSONValue]
        if let markedTarget {
            if let supplied = body["path"] {
                // A mark and path must name the same element; conflicting targets cannot be safely chosen between.
                let literal: [Int]? = {
                    guard case .array(let entries) = supplied else { return nil }
                    var out: [Int] = []
                    for entry in entries {
                        switch entry {
                        case .int(let n): out.append(Int(n))
                        case .double(let d) where d.isFinite && d == d.rounded():
                            guard let index = Int(exactly: d) else { return nil }
                            out.append(index)
                        default: return nil
                        }
                    }
                    return out
                }()
                if literal != markedTarget.path {
                    return injectionRefusal(
                        action: "ax_act",
                        error: "ambiguous_target: this call names both mark \(markedTarget.mark) "
                            + "and a different path; send one or the other",
                        status: 400,
                        extra: [
                            "mark": .int(Int64(markedTarget.mark)),
                            "mark_path": .array(markedTarget.path.map { .int(Int64($0)) }),
                        ]
                    )
                }
            }
            rawPath = markedTarget.path.map { .int(Int64($0)) }
        } else {
            guard case .array(let entries)? = body["path"] else {
                return injectionRefusal(
                    action: "ax_act",
                    error: "missing required field: path (from mac_ax_tree / mac_ax_find) "
                        + "or mark+view (from mac_view)",
                    status: 400
                )
            }
            rawPath = entries
        }
        var path: [Int] = []
        for entry in rawPath {
            switch entry {
            case .int(let n) where n >= 0: path.append(Int(n))
            // Fractional indices cannot be rounded into a different target.
            case .double(let d)
                where d.isFinite && d >= 0
                    && d == d.rounded()
                    && d <= 100_000:
                path.append(Int(d))
            default:
                return injectionRefusal(
                    action: "ax_act",
                    error: "invalid path component: path must be non-negative integers",
                    status: 400
                )
            }
        }
        if path.count > MacAXLimits.hardMaxDepth {
            return injectionRefusal(
                action: "ax_act",
                error: "path deeper than the reader's depth cap (\(MacAXLimits.hardMaxDepth))",
                status: 400
            )
        }
        if let refusal = injectionPreconditions(action: "ax_act", requiresSink: false, context: context) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "ax_act", body: body, turn: turn, context: context) {
            return refusal
        }
        // Refuse frontmost self-process AX acts with the same self-inspection cause as reads, before path lookup can obscure it.
        if PersonOnlyWindows.isOwnProcess(accessibilitySource(context: context).frontmostApp()?.processIdentifier) {
            return injectionRefusal(
                action: "ax_act",
                error: Self.selfInspectionError,
                status: 409,
                extra: ["guidance": .string(Self.selfInspectionNote)]
            )
        }

        let requestedAction = body["action"]?.stringValue
        let value = body["value"]?.stringValue
        var resolvedTarget: MacAXActTarget?
        if let markedTarget, let markedSnapshot {
            let live: MacAXActTarget?
            do { live = try liveMarkedTarget(markedTarget, snapshot: markedSnapshot, context: context) }
            catch { return injectionRefusal(action: "ax_act", error: "ax_evidence_unavailable", status: 409,
                extra: ["guidance": .string(error.localizedDescription)]) }
            guard let target = live else {
                return injectionRefusal(action: "ax_act", error: "mark_drifted: take a fresh view", status: 409)
            }
            resolvedTarget = target
        }
        let pathJSON = JSONValue.array(path.map { .int(Int64($0)) })
        if resolvedTarget == nil, let app = accessibilitySource(context: context).frontmostApp() {
            switch accessibilityActSource(context: context).resolve(path: path, inAppPid: app.processIdentifier, context: context) {
            case .resolved(let hit): resolvedTarget = hit
            case .unavailable(let detail):
                return injectionRefusal(action: "ax_act", error: "ax_evidence_unavailable", status: 409,
                    extra: ["guidance": .string(detail)])
            default: break
            }
        }
        guard let target = resolvedTarget else {
            await screenViewStore.invalidate()
            return injectionRefusal(
                action: "ax_act",
                error: MacAccessibilityActuator.pathNotFoundError,
                status: 404,
                extra: ["path": pathJSON]
            )
        }
        let result = await MacAccessibilityActuator.act(
            source: accessibilityActSource(context: context),
            target: target,
            action: requestedAction,
            value: value
        , turn: turn, context: context)
        await screenViewStore.invalidate()
        // Written/secure values use count+digest. Path-only calls lack the caption context needed to safely expose even an unwritten value.
        let redactValue = (value?.isEmpty == false) || markedTarget == nil || markedTarget?.secret == true
            || markedTarget?.valueRedaction != nil
            || (markedTarget?.labelSource == "value" && markedTarget?.labelRedaction != nil)
        func elementReceipt(_ target: MacAXActTarget, postState: Bool = false) -> JSONValue {
            guard case .object(var object) = target.toJSON(redactingValue: redactValue || postState) else {
                return .null
            }
            if let title = target.title {
                if postState {
                    object["title"] = MacInjectionResultRedaction.redactedSecret(title)
                } else if let redaction = markedTarget?.labelRedaction {
                    object["title"] = title == markedTarget?.label
                        ? redaction : MacInjectionResultRedaction.redactedSecret(title)
                }
            }
            if !postState, target.value == markedTarget?.value,
               let redaction = markedTarget?.valueRedaction {
                object["value"] = redaction
            }
            return MacScreenViewTextRedaction.redactedElementJSON(
                .object(object),
                under: markedTarget?.label,
                enclosing: markedTarget?.enclosingCaption ?? .none
            )
        }
        var output: [String: JSONValue] = [
            "ok": .bool(result.ok),
            "status": .string(result.ok ? "acted" : "failed"),
            "method": .string(result.method),
            "requested_action": .string(result.requestedAction),
            "outcome": .string(result.outcome.rawValue),
            "path": pathJSON,
            // Receipt fields retain the legend's contextual redaction.
            "element": elementReceipt(result.target),
            // Post-state is evidence, not verification. Without fresh caption context, its values leave only as count and digest.
            "post_state": result.postState.map {
                elementReceipt($0, postState: true)
            } ?? .null,
            "verified": .bool(false),
            "value_redacted": .bool(redactValue),
        ]
        output.merge(result.outcome.receipt) { _, new in new }
        if let markedTarget {
            output["targeted_by"] = .string("mark")
            output["mark"] = .int(Int64(markedTarget.mark))
        }
        if let error = result.error { output["error"] = .string(error) }
        return MacControlResult(
            ok: result.ok,
            action: "ax_act",
            output: .object(output),
            error: result.error,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }

}

import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension SwiftNativeMacControl {
    /// A mark is a reference into the latest view, not injection authority.
    /// Dispatch admission still requires the normal capability and policy gates.
    private enum MarkResolution {
        /// The call named no mark at all — the coordinate/path forms apply.
        case absent
        case resolved(MacScreenViewMark, MacScreenViewSnapshot)
        case refused(MacControlResult)
    }

    private func resolveMarkReference(
        action: String,
        body: [String: JSONValue]
    ) async -> MarkResolution {
        guard let mark = Self.intValue(body, "mark") else { return .absent }
        guard let viewId = body.stringValue("view") ?? body.stringValue("view_id"),
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

    /// Resolve only in the captured window. Inferred or duplicate labels cannot
    /// establish element identity, so those marks require a fresh semantic target.
    private func liveMarkedTarget(
        _ mark: MacScreenViewMark,
        snapshot: MacScreenViewSnapshot
    ) -> MacAXActTarget? {
        guard let identity = snapshot.windowIdentity,
              identity.pid != getpid(),
              accessibilitySource.frontmostApp()?.processIdentifier == identity.pid,
              let label = mark.label, !label.isEmpty,
              mark.labelSource == "title" || mark.labelSource == "value"
        else { return nil }
        let windows = accessibilityActSource.windows(pid: identity.pid)
        guard case .matched(let window, _) = MacAXWindowIdentity.match(
            identity, among: windows.map { (handle: $0, identity: $0.identity) }
        ), let focused = accessibilityActSource.focusedWindow(pid: identity.pid),
           focused.handle == window.handle,
           let target = accessibilityActSource.uniqueTarget(
               role: mark.role, label: label, labelSource: mark.labelSource,
               ancestorPath: Array(mark.path.dropLast()), inWindow: window
           ), target.enabled
        else { return nil }
        return target
    }

    /// `keystroke` — literal Unicode typing and/or key chords.
    ///
    /// `text` is typed first, then `keys`, so `{text:"hello", keys:"cmd+s"}`
    /// reads in the order it happens. At least one must be present.
    func handleKeystroke(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        let rawText = body.stringValue("text")
        let rawKeys = body.stringValue("keys")
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
            // Parse failure is a 400, and NOTHING is emitted — a half-understood
            // chord spec must never be partially executed.
            let message = (error as? MacKeySyntaxError)?.errorDescription ?? "\(error)"
            return injectionRefusal(action: "keystroke", error: message, status: 400)
        }
        if let refusal = injectionPreconditions(action: "keystroke", requiresSink: true) {
            return refusal
        }
        // SECURE KEYBOARD ENTRY (sweep item 8). The sink is available and
        // `CGEvent.post` will report nothing wrong — the window server just
        // never delivers synthesized keys while secure input is on, so every
        // character below would vanish and the receipt would say `typed`.
        // Preflighted once, before a single event, and refused in words.
        if let refusal = MacActClosedLoop.secureInputRefusal(
            active: eventSink.secureKeyboardEntryActive
        ) {
            return injectionRefusal(
                action: "keystroke",
                error: refusal.reason,
                extra: ["note": .string(refusal.note), "key_events": .int(0)]
            )
        }

        var keyEvents = 0
        if let text {
            for event in MacEventPlanner.typeText(text) {
                if let refusal = await attentionActionRefusal(action: "keystroke", body: body) {
                    await screenViewStore.invalidate()
                    return refusal
                }
                eventSink.post(key: event)
                keyEvents += 1
            }
        }
        for chord in chords {
            for event in MacEventPlanner.chord(chord) {
                if let refusal = await attentionActionRefusal(action: "keystroke", body: body) {
                    await screenViewStore.invalidate()
                    return refusal
                }
                eventSink.post(key: event)
                keyEvents += 1
            }
        }
        await screenViewStore.invalidate()
        return MacControlResult(
            ok: true,
            action: "keystroke",
            output: .object([
                "ok": .bool(true),
                "status": .string("typed"),
                // Character COUNT, never the characters themselves: a keystroke
                // payload routinely carries passwords and private prose, and
                // this result is persisted in the operation store.
                "text_characters": .int(Int64(text?.count ?? 0)),
                "chords": .array(chords.map { $0.toJSON() }),
                "key_events": .int(Int64(keyEvents)),
                // The window server acknowledges nothing; we emitted events, we
                // did not observe an effect.
                "verified": .bool(false),
            ]),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// `click` — a click at a point, or a drag between two points.
    ///
    /// Drag form: `{from:{x,y}, to:{x,y}}` (also accepts flat
    /// `from_x/from_y/to_x/to_y`). Point form: `{x, y}` plus optional
    /// `button:"left"|"right"`, `count:1…3`, `double:true`.
    func handleClick(_ body: [String: JSONValue]) async -> MacControlResult {
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
        let button: MacMouseButton = {
            let raw = (body.stringValue("button") ?? "").lowercased()
            if raw == "right" { return .right }
            if case .bool(true)? = body["right"] { return .right }
            return .left
        }()

        func point(_ key: String) -> (Double, Double)? {
            if case .object(let obj)? = body[key],
               let x = Self.doubleValue(obj, "x"), let y = Self.doubleValue(obj, "y") {
                return (x, y)
            }
            if let x = Self.doubleValue(body, "\(key)_x"), let y = Self.doubleValue(body, "\(key)_y") {
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

        var events: [MacMouseEvent]
        var describe: [String: JSONValue]
        var dragStepDelayNanoseconds: UInt64 = 0
        if let markedTarget {
            let x = markedTarget.frame.x + markedTarget.frame.w / 2.0
            let y = markedTarget.frame.y + markedTarget.frame.h / 2.0
            var count = Self.intValue(body, "count") ?? 1
            if case .bool(true)? = body["double"] { count = max(count, 2) }
            count = max(1, min(count, 3))
            events = MacEventPlanner.click(x: x, y: y, button: button, count: count)
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
                            valueChars: MacAXLimits.hardValueChars
                        )
                    } ?? .null,
                    "path": .array(markedTarget.path.map { .int(Int64($0)) }),
                ]),
                "x": .double(x),
                "y": .double(y),
                "count": .int(Int64(count)),
            ]
        } else if let from = point("from"), let to = point("to") {
            let durationMs = max(80, min(Self.intValue(body, "duration_ms") ?? 240, 2_000))
            let steps = max(4, min(60, durationMs / 16))
            events = MacEventPlanner.smoothDrag(
                fromX: from.0,
                fromY: from.1,
                toX: to.0,
                toY: to.1,
                button: button,
                steps: steps
            )
            dragStepDelayNanoseconds = UInt64(durationMs) * 1_000_000 / UInt64(steps)
            describe = [
                "gesture": .string("drag"),
                "from": .object(["x": .double(from.0), "y": .double(from.1)]),
                "to": .object(["x": .double(to.0), "y": .double(to.1)]),
                "duration_ms": .int(Int64(durationMs)),
                "drag_steps": .int(Int64(steps)),
            ]
        } else {
            guard let x = Self.doubleValue(body, "x"), let y = Self.doubleValue(body, "y") else {
                return injectionRefusal(
                    action: "click",
                    error: "missing required field: x,y (or from/to for a drag)",
                    status: 400
                )
            }
            var count = Self.intValue(body, "count") ?? 1
            if case .bool(true)? = body["double"] { count = max(count, 2) }
            count = max(1, min(count, 3))
            events = MacEventPlanner.click(x: x, y: y, button: button, count: count)
            describe = [
                "gesture": .string("click"),
                "x": .double(x),
                "y": .double(y),
                "count": .int(Int64(count)),
            ]
        }

        if let refusal = injectionPreconditions(action: "click", requiresSink: true) {
            return refusal
        }
        var pressed = false
        var lastPosted: MacMouseEvent?
        var cancelled = false
        func releasePressedButton() {
            guard pressed, let lastPosted else { return }
            eventSink.post(mouse: MacMouseEvent(
                phase: .up, button: lastPosted.button, x: lastPosted.x, y: lastPosted.y
            ))
        }
        for var event in events {
            if Task.isCancelled { cancelled = true; break }
            if let refusal = await attentionActionRefusal(action: "click", body: body) {
                releasePressedButton()
                await screenViewStore.invalidate()
                return refusal
            }
            if Task.isCancelled { cancelled = true; break }
            if let markedTarget, let markedSnapshot {
                let x: Double
                let y: Double
                if event.phase == .up, pressed, let lastPosted {
                    // Mouse-down may itself change the label or remove the
                    // target. Finish that click at its accepted position.
                    x = lastPosted.x
                    y = lastPosted.y
                } else {
                    guard let target = liveMarkedTarget(markedTarget, snapshot: markedSnapshot),
                          let centre = target.centre else {
                        releasePressedButton()
                        await screenViewStore.invalidate()
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
            eventSink.post(mouse: event)
            lastPosted = event
            if event.phase == .down { pressed = true }
            if event.phase == .up { pressed = false }
            if dragStepDelayNanoseconds > 0,
               event.phase == .down || event.phase == .drag {
                do {
                    try await Task.sleep(nanoseconds: dragStepDelayNanoseconds)
                } catch {
                    cancelled = true
                    break
                }
            }
        }
        if cancelled { releasePressedButton() }
        await screenViewStore.invalidate()
        if cancelled {
            return injectionRefusal(
                action: "click", error: "cancelled", status: 409,
                extra: ["status": .string("cancelled")]
            )
        }

        describe["ok"] = .bool(true)
        describe["status"] = .string("clicked")
        describe["button"] = .string(button.rawValue)
        describe["mouse_events"] = .int(Int64(events.count))
        describe["verified"] = .bool(false)
        return MacControlResult(
            ok: true,
            action: "click",
            output: .object(describe),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// `scroll` — wheel events, optionally after moving the pointer so the
    /// scroll lands on the intended view rather than wherever the cursor sat.
    func handleScroll(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        let dy = Self.intValue(body, "dy") ?? Self.intValue(body, "delta_y") ?? 0
        let dx = Self.intValue(body, "dx") ?? Self.intValue(body, "delta_x") ?? 0
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
        let unit: MacScrollUnit = (body.stringValue("units") ?? body.stringValue("unit") ?? "line")
            .lowercased() == "pixel" ? .pixel : .line
        let at: (Double, Double)? = {
            guard let x = Self.doubleValue(body, "x"), let y = Self.doubleValue(body, "y") else { return nil }
            return (x, y)
        }()

        if let refusal = injectionPreconditions(action: "scroll", requiresSink: true) {
            return refusal
        }
        if let at {
            if let refusal = await attentionActionRefusal(action: "scroll", body: body) {
                return refusal
            }
            eventSink.post(mouse: MacMouseEvent(phase: .move, button: .left, x: at.0, y: at.1))
        }
        if let refusal = await attentionActionRefusal(action: "scroll", body: body) {
            await screenViewStore.invalidate()
            return refusal
        }
        eventSink.post(scroll: MacScrollEvent(deltaX: clampedX, deltaY: clampedY, unit: unit))
        await screenViewStore.invalidate()

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
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// `ax_act` — THE semantic act. Target an element by the `path` that
    /// `ax_tree`/`ax_find` handed out and run its own AX action, so the app
    /// executes its real handler instead of guessing at a coordinate. Falls
    /// back to a synthesized click at the element's frame centre only when the
    /// element advertises no usable action — and says which one it used.
    func handleAXAct(_ body: [String: JSONValue]) async -> MacControlResult {
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
                // A mark AND a path in one call. Allowed only when they name
                // the same element; otherwise two targets were named and there
                // is no safe way to choose.
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
        if let refusal = injectionPreconditions(action: "ax_act", requiresSink: false) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "ax_act", body: body) {
            return refusal
        }
        // ax_act resolves against the FRONTMOST app; when that is ourselves
        // the act source's own fence would refuse as path-not-found, but the
        // reason belongs in the payload — same vocabulary as the read tools.
        if accessibilitySource.frontmostApp()?.processIdentifier == getpid() {
            return injectionRefusal(
                action: "ax_act",
                error: Self.selfInspectionError,
                status: 409,
                extra: ["guidance": .string(Self.selfInspectionNote)]
            )
        }

        let requestedAction = body.stringValue("action")
        let value = body.stringValue("value")
        var resolvedTarget: MacAXActTarget?
        if let markedTarget, let markedSnapshot {
            guard let target = liveMarkedTarget(markedTarget, snapshot: markedSnapshot) else {
                return injectionRefusal(action: "ax_act", error: "mark_drifted: take a fresh view", status: 409)
            }
            resolvedTarget = target
        }
        let outcome = MacAccessibilityActuator.act(
            source: accessibilityActSource,
            sink: eventSink,
            path: path,
            action: requestedAction,
            value: value,
            resolved: resolvedTarget
        )
        await screenViewStore.invalidate()
        let pathJSON = JSONValue.array(path.map { .int(Int64($0)) })
        switch outcome {
        case .failure(let error):
            return injectionRefusal(
                action: "ax_act",
                error: error.rawValue,
                status: 404,
                extra: ["path": pathJSON]
            )
        case .success(let result):
            // Written/secure values use count+digest. Path-only calls lack the
            // caption context needed to safely expose even an unwritten value.
            let redactValue = (value?.isEmpty == false) || markedTarget == nil || markedTarget?.secret == true
            var output: [String: JSONValue] = [
                "ok": .bool(result.ok),
                "status": .string(result.ok ? "acted" : "failed"),
                "method": .string(result.method),
                "requested_action": .string(result.requestedAction),
                "outcome": .string(result.outcome.rawValue),
                "path": pathJSON,
                // Receipt fields retain the legend's contextual redaction.
                "element": MacScreenViewTextRedaction.redactedElementJSON(
                    result.target.toJSON(redactingValue: redactValue),
                    under: markedTarget?.label,
                    enclosing: markedTarget?.enclosingCaption ?? .none
                ),
                // The post-state read is offered so the caller can CHECK
                // whether the state changed; it is not itself a claim that it
                // did (see `verificationState`).
                "post_state": result.postState.map {
                    MacScreenViewTextRedaction.redactedElementJSON(
                        $0.toJSON(redactingValue: redactValue),
                        under: markedTarget?.label,
                        enclosing: markedTarget?.enclosingCaption ?? .none
                    )
                } ?? .null,
                "verified": .bool(false),
                "value_redacted": .bool(redactValue),
            ]
            output["fallback_reason"] = result.fallbackReason.map { .string($0) } ?? .null
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
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
    }

}

import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacFourVerbs+Foreground.swift` | `MacFourVerbs`, `FrontExpectation`, `actBroughtForward`, `settlementDispatch`, `missBeforeRaise` |

extension MacFourVerbs {
    /// After a `front:true` raise: the exact process and window that must be in front when the act looks, or it refuses.
    typealias FrontExpectation = (pid: Int32, frame: MacAXFrame?)

    /// Release an act's temporary foreground/AX state even after Stop. The original generation still yields to takeover and explicit handback.
    func settlementDispatch(action: String, body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult? {
        let driver = context.driver?.settlementBinding()
        // `settle` detaches: carry the exact foreground lease through the whole dispatch, including its retained native execution task.
        let restoration = context.restoring
        return await settle {
            let context = context.settling()
            return await context.holding(\.restoring, restoration) { context in
                await context.holding(\.driver, driver) { context in
                    do { return try await host.dispatch(action: action, body: body, turn: turn, context: context) }
                    catch {
                        return MacControlResult(ok: false, action: action,
                            output: .object(["status": .string("settlement_failed"),
                                             "message": .string(error.localizedDescription)]),
                            error: error.localizedDescription, durationMs: 0)
                    }
                }
            }
        }
    }

    func actBroughtForward(
        app: String,
        seek: String,
        menuOrKey: Bool,
        raise: Bool,
        missBefore: (Sighting?) async -> MacFourVerbsReply?,
        inBack: (Sighting?) async -> MacFourVerbsReply,
        turn: Turn, context: MacOperationContext, run: (FrontExpectation?, Sighting?) async -> MacFourVerbsReply) async -> MacFourVerbsReply {
        var anchored: Sighting?
        var windowless: MacFourVerbsReply?
        let capture = MacSightCaptureBinding(frameID: UUID().uuidString)
        switch await sight(part: nil, app: app, seek: seek, observed: capture, turn: turn, context: context) {
        case .blind(let reply):
            let front = Self.object(reply.detail["frontmost_app"])
            let frontName = Self.string(front["name"])
            let inFront = frontName != nil && frontName == Self.string(reply.detail["requested_app"])
            guard raise || inFront else { return await inBack(nil) }
            guard menuOrKey, Self.windowlessApp(reply.detail) else { return reply }
            if let miss = await missBefore(nil) { return miss }
            // Already in front with no window: act there, refused at each event if the front moves. Only a permitted raise activates anything.
            if inFront, let pid = Self.int(front["pid"]).flatMap(Int32.init(exactly:)) { return await run((pid, nil), nil) }
            windowless = reply
        case .seen(let hit): anchored = hit
        }
        if let anchored, !anchored.isFront, !raise { return await inBack(anchored) }
        let appName = anchored?.appName ?? app
        func stamped(_ reply: MacFourVerbsReply, note: String?, _ extra: [String: JSONValue]) -> MacFourVerbsReply {
            MacFourVerbsReply(
                ok: reply.ok,
                text: note.map { $0 + "\n" + reply.text } ?? reply.text,
                detail: reply.detail.merging(extra) { _, new in new }
            )
        }
        if let anchored, anchored.pid == nil {
            return MacFourVerbsReply(
                ok: false,
                text: "I can't tell which process \(appName) is, so I won't bring it forward. Nothing moved.",
                detail: ["error": .string("front_unknown"), "owner_front_changed": .bool(false)]
            )
        }
        if let anchored, anchored.isFront, let targetPid = anchored.pid {
            let reply = await run((targetPid, anchored.windowFrame), anchored)
            return stamped(reply, note: nil, ["owner_front_changed": .bool(
                Self.bool(reply.detail["owner_front_changed"]) == true
                    || Self.string(reply.detail["error"]) == "owner_changed_apps"
            )])
        }
        guard let lease = capture.foreground else {
            if let windowless { return windowless }
            return MacFourVerbsReply(
                ok: false,
                text: "I can't tell which app is in front, so I won't bring \(appName) forward — I couldn't put it back. Nothing moved.",
                detail: ["error": .string("front_unknown"), "owner_front_changed": .bool(false)]
            )
        }
        let previous = (name: lease.app.name, pid: lease.app.processIdentifier)
        if let anchored, let miss = await missBefore(anchored) { return miss }
        let startedAt = clock.monotonicSeconds()
        func restore() async -> (String, [String: JSONValue]) {
            let elapsed = clock.monotonicSeconds() - startedAt
            let result = await context.holding(\.restoring, lease) {
                context in await settlementDispatch(action: "focus_app", body: ["pid": .int(Int64(previous.pid))], turn: turn, context: context)
            }
            let status = Self.string(Self.object(result?.output)["status"])
            var extra: [String: JSONValue] = [
                "restore_target": .string(previous.name),
                "foreground_restore": result?.toJSON(readContent: context.readContent) ?? .null,
            ]
            if status == "restore_requested" {
                extra["front_seconds"] = .int(Int64(elapsed.rounded()))
                return ("Restoration of \(previous.name) was requested and is not yet confirmed.", extra)
            }
            if status == "app_gone" {
                extra["error_restore"] = .string("owner_front_gone")
                return ("\(previous.name) has quit since, so there was nothing to put back.", extra)
            }
            return ("Restoration of \(previous.name) is unconfirmed. Inspect the current screen.", extra)
        }
        // Raise and verify the observed window, never another window of the same app.
        let focusBody: [String: JSONValue]
        if let anchored, let targetPid = anchored.pid {
            focusBody = ["pid": .int(Int64(targetPid)), "frame_id": .string(anchored.frameId)]
        } else { focusBody = ["app": .string(app)] }
        let raised = try? await host.dispatch(action: "focus_app", body: focusBody, turn: turn, context: context)
        let raisedOutput = Self.object(raised?.output)
        if let raised, let error = raised.error, error.hasPrefix("human_takeover:") {
            return MacFourVerbsReply(ok: false, text: error,
                detail: Self.operationDetail(raised).merging(["error": .string(error)]) { _, new in new })
        }
        let targetPid = anchored?.pid ?? Self.int(raisedOutput["process_identifier"]).flatMap(Int32.init(exactly:))
        guard raised?.ok == true, let targetPid else {
            let (words, extra) = await restore()
            if let windowless { return stamped(windowless, note: words, extra) }
            let windowChanged = Self.string(raisedOutput["status"]) == "front_window_changed"
            return MacFourVerbsReply(
                ok: false,
                text: (windowChanged
                    ? "The \(appName) window I looked at isn't there to bring forward any more (front_window_changed). "
                    : "I couldn't bring that \(appName) window forward (\(raised?.error ?? "the switch was refused")). ")
                    + "I haven't acted. " + words,
                detail: extra.merging([
                    "error": .string(windowChanged ? "front_window_changed" : "front_raise_failed"),
                    "owner_front_changed": .bool(true),
                ]) { _, new in new }
            )
        }
        let frame = anchored.flatMap { MacFourVerbs.frame(raisedOutput["window_frame"]) ?? $0.windowFrame }
        var reply = await run((targetPid, frame), nil)
        if Self.string(reply.detail["error"]) == "owner_changed_apps" {
            if windowless != nil { return reply }
            // A person's mid-act focus choice wins; restoring the captured foreground would undo that choice.
            return stamped(reply, note: nil, [
                "brought_forward": .string(appName), "owner_front_changed": .bool(true), "owner_front_restored": .bool(false),
            ])
        }
        if targetPid == previous.pid {
            return stamped(reply, note: windowless == nil ? nil : "\(app) had no window, so I used its menu bar.",
                           ["owner_front_changed": reply.detail["owner_front_changed"] ?? .bool(false)])
        }
        let (words, extra) = await restore()
        if let range = reply.text.range(of: " · FRONT") {
            reply = MacFourVerbsReply(ok: reply.ok, text: reply.text.replacingCharacters(in: range, with: " · in front during the act"),
                detail: reply.detail)
        }
        let note = (windowless == nil ? "Brought \(appName) forward for the act. "
            : "\(app) had no window, so I brought it forward to use its menu bar. ") + words
        return stamped(reply, note: note, extra.merging([
            "brought_forward": .string(appName),
            "owner_front_changed": .bool(true),
        ]) { _, new in new })
    }

    /// Before raising, resolve the named target in the background; a miss moves nothing.
    func missBeforeRaise(verb rawVerb: String, target: String, in seen: Sighting, turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply? {
        var verbName = Self.parseVerb(rawVerb).0
        if verbName == "press" { verbName = Self.pressMeansKey(target) ? "key" : "click" }
        guard let verb = MacActVerb(rawValue: verbName), !Self.isPotentialDynamicVisualReference(target),
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let clickish = [MacActVerb.click, .open, .select, .toggle].contains(verb)
        if !(clickish && Self.isMenuPath(target)) {
            switch verb == .scroll ? Self.resolveScrollTarget(target, among: seen.targets, viewport: seen.visibleFrame ?? seen.windowFrame)
                : Self.resolve(target, among: seen.targets) {
            case .ambiguous: return nil
            case .hit(let candidate) where candidate.regionOnly || Self.answers(target, candidate): return nil
            default: break
            }
            if verb != .scroll {
                do { if case .hit? = try await mapResolve(target, in: seen) { return nil } }
                catch { return Self.appMapFailure(error) }
            }
            if verb != .scroll, Self.bareField(target, in: seen)?.hit != nil { return nil }
            if verb == .type, Self.typesAtFocus(target, in: seen) { return nil }
        }
        // Background menu titles can reflect stale key-window validation. Judge only after raising; on a real miss, refuse and restore.
        if clickish, Self.isMenuPath(target) { return nil }
        let name = seen.appName ?? "that app"
        let hint = await menuHint(target, verb: verb, app: seen.appName, turn: turn, context: context)
        return MacFourVerbsReply(
            ok: false,
            text: "Nothing in \(name)'s window is called \"\(target)\", so I didn't bring \(name) forward. Nothing moved."
                + hint.text + "\n" + seen.render,
            detail: hint.detail.merging([
                "error": .string("no_match"), "target": .string(target), "owner_front_changed": .bool(false)
            ]) { _, new in new }
        )
    }
}

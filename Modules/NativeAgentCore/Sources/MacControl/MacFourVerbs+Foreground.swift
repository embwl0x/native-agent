import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacFourVerbs+Foreground.swift` | `MacFourVerbs`: `FrontExpectation`, `actBroughtForward`, `settlementDispatch`, `missBeforeRaise`; named-app acts borrow and settle the exact foreground window under the driver generation |

extension MacFourVerbs {
    /// After a `front:true` raise: the exact process and window that must be
    /// in front when the act looks, or it refuses.
    typealias FrontExpectation = (pid: Int32, frame: MacAXFrame?)

    /// Release an act's temporary foreground/AX state even after Stop. The
    /// original generation still yields to takeover and explicit handback.
    func settlementDispatch(action: String, body: [String: JSONValue]) async -> MacControlResult? {
        let driver = MacDriverContext.binding?.settlementBinding()
        return await settle {
            await MacDriverContext.$binding.withValue(driver) {
                try? await host.dispatch(action: action, body: body)
            }
        }
    }

    /// Named-app acts use that window in place; explicit raising remembers and restores the person's front app and reports the move.
    func actBroughtForward(
        app: String,
        seek: String,
        menuOrKey: Bool,
        raise: Bool,
        missBefore: (Sighting?) async -> MacFourVerbsReply?,
        inBack: (Sighting?) async -> MacFourVerbsReply,
        run: (FrontExpectation?, Sighting?) async -> MacFourVerbsReply
    ) async -> MacFourVerbsReply {
        var anchored: Sighting?
        var windowless: MacFourVerbsReply?
        switch await sight(part: nil, app: app, seek: seek) {
        case .blind(let reply):
            let front = Self.object(reply.detail["frontmost_app"])
            let frontName = Self.string(front["name"])
            let inFront = frontName != nil && frontName == Self.string(reply.detail["requested_app"])
            guard raise || inFront else { return await inBack(nil) }
            guard menuOrKey, Self.string(reply.detail["error"]) == "no_window_in_app" else { return reply }
            if let miss = await missBefore(nil) { return miss }
            // Already in front with no window: act there, refused at each event
            // if the front moves. Only a permitted raise activates anything.
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
        let front = Self.object(windowless?.detail["frontmost_app"])
        let previous = anchored?.frontmostApp ?? Self.int(front["pid"]).flatMap(Int32.init(exactly:)).map {
            (name: Self.string(front["name"]) ?? "the previous app", pid: $0, window: front["window"].flatMap { $0 == .null ? nil : $0 })
        }
        guard let previous else {
            if let windowless { return windowless }
            return MacFourVerbsReply(
                ok: false,
                text: "I can't tell which app is in front, so I won't bring \(appName) forward — I couldn't put it back. Nothing moved.",
                detail: ["error": .string("front_unknown"), "owner_front_changed": .bool(false)]
            )
        }
        if let anchored, let miss = await missBefore(anchored) { return miss }
        /// Restore the exact previous pid and key window; confirm its pid is frontmost.
        func restore() async -> (restored: Bool, gone: Bool) {
            var body: [String: JSONValue] = ["pid": .int(Int64(previous.pid))]
            if let window = previous.window { body["window"] = window }
            let result = await settlementDispatch(action: "focus_app", body: body)
            let output = Self.object(result?.output)
            return (
                result?.ok == true && Self.bool(output["frontmost_pid_matches"]) == true,
                Self.string(output["status"]) == "app_gone"
            )
        }
        func restoreWords(_ restore: (restored: Bool, gone: Bool)) -> (String, [String: JSONValue]) {
            let extra: [String: JSONValue] = [
                "owner_front_restored": .bool(restore.restored),
                "restored_app": .string(previous.name),
            ].merging(restore.gone ? ["error_restore": .string("owner_front_gone")] : [:]) { _, new in new }
            if restore.restored { return ("\(previous.name) is back in front", extra) }
            if restore.gone { return ("\(previous.name) has quit since, so there was nothing to put back (owner_front_gone)", extra) }
            return ("I couldn't put \(previous.name) back, so \(appName) is still in front", extra)
        }
        let startedAt = clock.monotonicSeconds()
        // Raise and verify the observed window, never another window of the same app.
        let focusBody: [String: JSONValue]
        if let anchored, let targetPid = anchored.pid {
            focusBody = ["pid": .int(Int64(targetPid)), "frame_id": .string(anchored.frameId)]
        } else { focusBody = ["app": .string(app)] }
        let raised = try? await host.dispatch(action: "focus_app", body: focusBody)
        let raisedOutput = Self.object(raised?.output)
        if let raised, let error = raised.error, error.hasPrefix("human_takeover:") {
            return MacFourVerbsReply(ok: false, text: error,
                detail: Self.operationDetail(raised).merging(["error": .string(error)]) { _, new in new })
        }
        let targetPid = anchored?.pid ?? Self.int(raisedOutput["process_identifier"]).flatMap(Int32.init(exactly:))
        guard raised?.ok == true, let targetPid else {
            if let windowless { _ = await restore(); return windowless }
            let windowChanged = Self.string(raisedOutput["status"]) == "front_window_changed"
            let (words, extra) = restoreWords(await restore())
            return MacFourVerbsReply(
                ok: false,
                text: (windowChanged
                    ? "The \(appName) window I looked at isn't there to bring forward any more (front_window_changed). "
                    : "I couldn't bring that \(appName) window forward (\(raised?.error ?? "the switch was refused")). ")
                    + "I haven't acted; " + words + ".",
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
            // He picked a new front app mid-act; putting his old one back would undo him.
            return stamped(reply, note: nil, [
                "brought_forward": .string(appName), "owner_front_changed": .bool(true), "owner_front_restored": .bool(false),
            ])
        }
        let wasFront = targetPid == previous.pid
        var restored = wasFront ? (restored: true, gone: false) : await restore()
        // The raised app can still be settling its own activation; one more
        // try after it has, so the person's app always comes back.
        if anchored != nil, !restored.restored, !restored.gone {
            await settle { await clock.sleep(seconds: 0.3) }
            restored = await restore()
        }
        if windowless != nil {
            return stamped(reply, note: wasFront ? "\(app) had no window, so I used its menu bar."
                : "\(app) had no window, so I brought it forward to use its menu bar, then "
                    + (restored.restored ? "put \(previous.name) back." : "couldn't put \(previous.name) back, so \(app) is still in front."),
                ["brought_forward": .string(app), "owner_front_changed": .bool(true), "owner_front_restored": .bool(restored.restored)])
        }
        let (words, extra) = restoreWords(restored)
        // The screen in the reply was read while the app was in front; once
        // the person's app is back it no longer is.
        if restored.restored, let range = reply.text.range(of: " · FRONT") {
            reply = MacFourVerbsReply(ok: reply.ok, text: reply.text.replacingCharacters(in: range, with: " · back now (\(previous.name) restored)"), detail: reply.detail)
        }
        let seconds = max(1, Int((clock.monotonicSeconds() - startedAt).rounded()))
        let note = "Brought \(appName) forward for ~\(seconds)s"
            + (restored.restored ? ", then put \(previous.name) back." : "; " + words + ".")
        return stamped(reply, note: note, extra.merging([
            "brought_forward": .string(appName),
            "front_seconds": .int(Int64(seconds)),
            "owner_front_changed": .bool(true),
        ]) { _, new in new })
    }

    /// Before raising, resolve the named target in the background; a miss moves nothing.
    func missBeforeRaise(verb rawVerb: String, target: String, in seen: Sighting) async -> MacFourVerbsReply? {
        var verbName = Self.parseVerb(rawVerb).0
        if verbName == "press" { verbName = Self.pressMeansKey(target) ? "key" : "click" }
        guard let verb = MacActVerb(rawValue: verbName), !Self.isPotentialDynamicVisualReference(target),
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let clickish = [MacActVerb.click, .open, .select, .toggle].contains(verb)
        if !(clickish && Self.isMenuPath(target)) {
            switch verb == .scroll ? Self.resolveScrollTarget(target, among: seen.targets) : Self.resolve(target, among: seen.targets) {
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
        // A menu path is never judged from the back: a background app's menus
        // keep the last key window's titles (Make Plain Text reads Make Rich
        // Text), so only the press after the raise can tell. It refuses and
        // restores if the item really isn't there.
        if clickish, Self.isMenuPath(target) { return nil }
        let name = seen.appName ?? "that app"
        return MacFourVerbsReply(
            ok: false,
            text: "Nothing in \(name)'s window is called \"\(target)\", so I didn't bring \(name) forward. Nothing moved."
                + (await menuHint(target, verb: verb, app: seen.appName)) + "\n" + seen.render,
            detail: ["error": .string("no_match"), "target": .string(target), "owner_front_changed": .bool(false)]
        )
    }
}

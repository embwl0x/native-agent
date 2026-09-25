import Foundation
import NativeAgentCore
import PersistenceCore

/// One act at a time, in arrival order. Every act reads and moves a real
/// window, and the pid it will touch is only known after its first look, so
/// the queue is process-wide: parallel calls run one after another.
actor MacActSerial {
    static let shared = MacActSerial()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

extension MacFourVerbs {
    // MARK: 2 — HANDS

    /// The core: perceive → resolve a NAME → act → say what changed → show the
    /// fresh screen. All inside ONE call, so there is nothing for her to carry
    /// between turns. A bounded repeat is still one natural act: every attempt
    /// re-sees and re-resolves the named target, so a moving visual region is
    /// followed rather than clicked at an old coordinate.
    ///
    /// Ambiguity is an ANSWER, not an error: two matches return the candidates
    /// as a question and act on NOTHING.
    public func act(
        verb rawVerb: String,
        target: String,
        text: String? = nil,
        to destination: String? = nil,
        /// fable51 item 32b — WHOSE window `to` lives in. Absent (the ordinary
        /// case) is the single-window drag, byte-for-byte as it was.
        toApp destinationApp: String? = nil,
        seconds: Double? = nil,
        repeat requestedRepeat: Int? = nil,
        interval: Double? = nil,
        holding: String? = nil,
        button: String? = nil,
        scrollAmount: Int? = nil,
        /// Her-screen Phase 4 — act in THIS running app's window without
        /// bringing it forward. Absent is the ordinary frontmost act.
        app: String? = nil,
        /// With `app`: bring it forward for this act, then put the person's
        /// front app back. Only after a background act answered `needs_front`.
        front: Bool = false,
        /// Her-screen Phase 5 — a short ordered batch, run in ONE call. When
        /// given, `verb`/`target` are ignored.
        steps: [MacActStep] = []
    ) async -> MacFourVerbsReply {
        // Her-screen 09-24 — acts run one at a time: two parallel calls on one
        // app interleaved their presses (7×7×6). Then the app maps this act
        // taught or corrected are written once, and the next act may start.
        await MacActSerial.shared.acquire()
        defer {
            Task {
                await MacAppMapStore.shared.flush()
                await MacActSerial.shared.release()
            }
        }
        let anchor = app.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let run: (String?, FrontExpectation?) async -> MacFourVerbsReply = { anchorApp, expect in
            guard steps.isEmpty else { return await self.actSteps(steps, app: anchorApp, expect: expect) }
            return await self.actCore(
                verb: rawVerb, target: target, text: text, to: destination, toApp: destinationApp,
                seconds: seconds, repeat: requestedRepeat, interval: interval, holding: holding,
                button: button, scrollAmount: scrollAmount, app: anchorApp, expect: expect
            )
        }
        guard let anchor else { return await run(nil, nil) }
        // A miss never touches the screen: the (first) thing to act on is
        // resolved in the background read before anything is raised.
        let missBefore: (Sighting) async -> MacFourVerbsReply? = { seen in
            // Every verb is checked before anything is raised.
            for (index, step) in (steps.isEmpty ? [MacActStep(verb: rawVerb, target: target)] : steps).enumerated() {
                guard let bad = Self.unknownVerb(step.verb, target: step.target) else { continue }
                guard !steps.isEmpty else { return bad }
                return MacFourVerbsReply(
                    ok: false, text: "Step \(index + 1): " + bad.text,
                    detail: bad.detail.merging(["failed_step": .int(Int64(index + 1)), "steps_completed": .int(0)]) { _, new in new }
                )
            }
            guard let first = steps.first else { return await self.missBeforeRaise(verb: rawVerb, target: target, in: seen) }
            guard let miss = await self.missBeforeRaise(verb: first.verb, target: first.target, in: seen) else { return nil }
            return MacFourVerbsReply(
                ok: false,
                text: "Stopped at step 1 of \(steps.count) (no_match); the rest were not run.\n" + miss.text,
                detail: miss.detail.merging([
                    "failed_step": .int(1), "steps_completed": .int(0), "steps_total": .int(Int64(steps.count)),
                ]) { _, new in new }
            )
        }
        var reply = front
            ? await actBroughtForward(app: anchor, missBefore: missBefore) { await run(nil, $0) }
            : await run(anchor, nil)
        if front, steps.isEmpty, reply.ok {
            reply = MacFourVerbsReply(ok: true, text: Self.oneCallNudge + "\n" + reply.text, detail: reply.detail)
        }
        // Electron/Chromium: the enhanced-AX flag was only for this act.
        let release = try? await host.dispatch(action: "look", body: [
            "app": .string(anchor), "release_enhanced_ax": .bool(true),
        ])
        guard Self.bool(Self.object(release?.output)["enhanced_ax_still_on"]) == true else { return reply }
        return MacFourVerbsReply(
            ok: reply.ok,
            text: reply.text + "\n(\(anchor)'s screen-reader accessibility mode did not switch back off; I'll retry next time.)",
            detail: reply.detail.merging(["enhanced_ax_still_on": .bool(true)]) { _, new in new }
        )
    }

    /// After a `front:true` raise: the exact process and window that must be
    /// in front when the act looks, or it refuses.
    typealias FrontExpectation = (pid: Int32, frame: MacAXFrame?)

    /// Her-screen Phase 4 — the one sanctioned way a background act takes the
    /// screen: remember who is in front, bring the target forward, act, put the
    /// person's app back, and say so in one line.
    private func actBroughtForward(
        app: String,
        missBefore: (Sighting) async -> MacFourVerbsReply?,
        run: (FrontExpectation?) async -> MacFourVerbsReply
    ) async -> MacFourVerbsReply {
        let anchored: Sighting
        switch await sight(part: nil, app: app) {
        case .blind(let reply): return reply
        case .seen(let hit): anchored = hit
        }
        let appName = anchored.appName ?? app
        func stamped(_ reply: MacFourVerbsReply, note: String?, _ extra: [String: JSONValue]) -> MacFourVerbsReply {
            MacFourVerbsReply(
                ok: reply.ok,
                text: note.map { $0 + "\n" + reply.text } ?? reply.text,
                detail: reply.detail.merging(extra) { _, new in new }
            )
        }
        guard let targetPid = anchored.pid else {
            return MacFourVerbsReply(
                ok: false,
                text: "I can't tell which process \(appName) is, so I won't bring it forward. Nothing moved.",
                detail: ["error": .string("front_unknown"), "user_front_changed": .bool(false)]
            )
        }
        if anchored.isFront {
            return stamped(await run((targetPid, anchored.windowFrame)), note: nil, ["user_front_changed": .bool(false)])
        }
        guard let previous = anchored.frontmostApp else {
            return MacFourVerbsReply(
                ok: false,
                text: "I can't tell which app is in front, so I won't bring \(appName) forward — I couldn't put it back. Nothing moved.",
                detail: ["error": .string("front_unknown"), "user_front_changed": .bool(false)]
            )
        }
        if let miss = await missBefore(anchored) { return miss }
        /// Put back EXACTLY the process (and key window) that was in front —
        /// by pid, never by name, never a launch. Restored only when the
        /// frontmost pid is that pid afterwards.
        func restore() async -> (restored: Bool, gone: Bool) {
            var body: [String: JSONValue] = ["pid": .int(Int64(previous.pid))]
            if let window = previous.window { body["window"] = window }
            let result = try? await host.dispatch(action: "focus_app", body: body)
            let output = Self.object(result?.output)
            return (
                result?.ok == true && Self.bool(output["frontmost_pid_matches"]) == true,
                Self.string(output["status"]) == "app_gone"
            )
        }
        func restoreWords(_ restore: (restored: Bool, gone: Bool)) -> (String, [String: JSONValue]) {
            let extra: [String: JSONValue] = [
                "user_front_restored": .bool(restore.restored),
                "restored_app": .string(previous.name),
            ].merging(restore.gone ? ["error_restore": .string("user_front_gone")] : [:]) { _, new in new }
            if restore.restored { return ("\(previous.name) is back in front", extra) }
            if restore.gone { return ("\(previous.name) has quit since, so there was nothing to put back (user_front_gone)", extra) }
            return ("I couldn't put \(previous.name) back, so \(appName) is still in front", extra)
        }
        let startedAt = clock.monotonicSeconds()
        // The EXACT window the look above was of: raised and verified front +
        // focused, or refused — never "some window of that app".
        let raised = try? await host.dispatch(action: "focus_app", body: [
            "pid": .int(Int64(targetPid)),
            "frame_id": .string(anchored.frameId),
        ])
        let raisedOutput = Self.object(raised?.output)
        guard raised?.ok == true else {
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
                    "user_front_changed": .bool(true),
                ]) { _, new in new }
            )
        }
        let frame = MacFourVerbs.frame(raisedOutput["window_frame"]) ?? anchored.windowFrame
        var reply = await run((targetPid, frame))
        if Self.string(reply.detail["error"]) == "user_changed_apps" {
            // He picked a new front app mid-act; putting his old one back would undo him.
            return stamped(reply, note: nil, [
                "brought_forward": .string(appName), "user_front_changed": .bool(true), "user_front_restored": .bool(false),
            ])
        }
        var restored = await restore()
        // The raised app can still be settling its own activation; one more
        // try after it has, so the person's app always comes back.
        if !restored.restored, !restored.gone {
            await clock.sleep(seconds: 0.3)
            restored = await restore()
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
            "user_front_changed": .bool(true),
        ]) { _, new in new })
    }

    private func actCore(
        verb rawVerb: String,
        target: String,
        text: String?,
        to destination: String?,
        toApp destinationApp: String?,
        seconds: Double?,
        repeat requestedRepeat: Int?,
        interval: Double?,
        holding: String?,
        button: String?,
        scrollAmount: Int?,
        app: String?,
        expect: FrontExpectation?
    ) async -> MacFourVerbsReply {
        let requestedInput = requestedRepeat ?? 1
        let requested = max(1, requestedInput)
        let accepted = min(requested, Self.maximumActRepeats)
        let pause = max(0, min(interval ?? 0, Self.maximumActIntervalSeconds))
        let perAttemptBudget = max(0, min(seconds ?? 0, 10)) + pause
        let durationBound = perAttemptBudget > 0
            ? max(1, Int(Self.maximumActBurstSeconds / perAttemptBudget))
            : Self.maximumActRepeats
        let attempts = min(accepted, durationBound)
        if attempts == 1 {
            return await actOnce(
                verb: rawVerb,
                target: target,
                text: text,
                to: destination,
                toApp: destinationApp,
                seconds: seconds,
                holding: holding,
                button: button,
                scrollAmount: scrollAmount,
                attention: nil,
                app: app,
                expect: expect
            )
        }

        let attention: BurstAttention
        switch await beginBurstAttention() {
        case .success(let lease): attention = lease
        case .failure(let message):
            return MacFourVerbsReply(
                ok: false,
                text: "I couldn't start a continuous act safely. \(message)",
                detail: ["error": .string("continuous_attention_unavailable")]
            )
        }
        let burstStartedAt = clock.monotonicSeconds()
        var completed = 0
        var visiblyVerified = 0
        var runtimeLimited = false
        var finalReply: MacFourVerbsReply?
        for attempt in 1...attempts {
            guard !Task.isCancelled else { break }
            if attempt > 1,
               clock.monotonicSeconds() - burstStartedAt >= Self.maximumActBurstSeconds {
                runtimeLimited = true
                break
            }
            let reply = await actOnce(
                verb: rawVerb,
                target: target,
                text: text,
                to: destination,
                toApp: destinationApp,
                seconds: seconds,
                holding: holding,
                button: button,
                scrollAmount: scrollAmount,
                attention: attention,
                app: app,
                expect: expect
            )
            finalReply = reply
            guard reply.ok else { break }
            completed += 1
            if Self.string(reply.detail["verification"]) == MotorVerificationState.satisfied.rawValue {
                visiblyVerified += 1
            }
            if attempt < attempts, pause > 0 {
                let elapsed = max(0, clock.monotonicSeconds() - burstStartedAt)
                let remaining = max(0, Self.maximumActBurstSeconds - elapsed)
                guard remaining > 0 else {
                    runtimeLimited = true
                    break
                }
                await clock.sleep(seconds: min(pause, remaining))
            }
        }
        if attention.owned {
            _ = try? await host.dispatch(action: "attention", body: ["mode": .string("stop")])
        }

        guard let finalReply else {
            return MacFourVerbsReply(
                ok: false,
                text: "The repeated act was cancelled before the first attempt.",
                detail: ["error": .string("cancelled")]
            )
        }
        var detail = finalReply.detail
        detail["repeat_requested"] = .int(Int64(requested))
        detail["repeat_requested_input"] = .int(Int64(requestedInput))
        detail["repeat_accepted"] = .int(Int64(accepted))
        detail["repeat_planned"] = .int(Int64(attempts))
        detail["repeat_completed"] = .int(Int64(completed))
        detail["repeat_visibly_verified"] = .int(Int64(visiblyVerified))
        detail["repeat_stopped_early"] = .bool(completed < requested)
        let elapsed = max(0, clock.monotonicSeconds() - burstStartedAt)
        detail["repeat_elapsed_seconds"] = .double(elapsed)
        detail["repeat_runtime_limited"] = .bool(runtimeLimited)
        if let holding { detail["holding"] = .string(holding) }
        if let button { detail["button"] = .string(button) }
        if completed == attempts, visiblyVerified == completed {
            detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
            detail["verification_evidence"] = .string("fresh_visible_evidence_for_every_burst_attempt")
        } else if finalReply.ok {
            detail["verification"] = .string(MotorVerificationState.unverified.rawValue)
            detail.removeValue(forKey: "verification_evidence")
        }

        let hardCapNote = accepted < requested
            ? " The \(Self.maximumActRepeats)-attempt safety cap limited this burst before execution."
            : ""
        let durationNote = attempts < accepted
            ? " The 30-second safety bound limited this burst to \(attempts)."
            : ""
        let runtimeNote = runtimeLimited
            ? " The 30-second runtime boundary stopped the burst before another attempt."
            : ""
        let proof: String
        if completed == 0 {
            proof = "No attempt completed."
        } else if visiblyVerified == completed {
            proof = "Every completed attempt had fresh visible proof."
        } else {
            proof = "\(visiblyVerified) had fresh visible proof; \(completed - visiblyVerified) remained unverified."
        }
        let lead: String
        if completed == attempts {
            lead = "Completed \(completed)/\(requested) requested attempts. \(proof)\(hardCapNote)\(durationNote)\(runtimeNote)"
        } else {
            lead = "Stopped after \(completed)/\(requested) requested attempts. \(proof)\(hardCapNote)\(durationNote)\(runtimeNote)"
        }
        return MacFourVerbsReply(
            ok: finalReply.ok && completed == attempts,
            text: lead + "\n" + finalReply.text,
            detail: detail
        )
    }

    static let maximumActRepeats = 12
    static let maximumActIntervalSeconds = 2.0
    static let maximumActBurstSeconds = 30.0

    struct BurstAttention: Sendable {
        let session: String
        let userSequence: Int64
        let owned: Bool
    }

    enum BurstAttentionStart {
        case success(BurstAttention)
        case failure(String)
    }

    private func beginBurstAttention() async -> BurstAttentionStart {
        func lease(from result: MacControlResult, owned: Bool) -> BurstAttention? {
            guard result.ok else { return nil }
            let output = Self.object(result.output)
            let attention = Self.object(output["attention"])
            guard let session = Self.string(attention["session"]),
                  let userSequence = Self.int(attention["user_sequence"]),
                  Self.bool(attention["yield_required"]) != true,
                  Self.bool(attention["refresh_required"]) != true else { return nil }
            return BurstAttention(session: session, userSequence: userSequence, owned: owned)
        }

        do {
            let status = try await host.dispatch(action: "attention", body: ["mode": .string("status")])
            if Self.bool(Self.object(status.output)["active"]) == true {
                guard let current = lease(from: status, owned: false) else {
                    return .failure("The existing attention session needs a fresh observation first.")
                }
                return .success(current)
            }
            let started = try await host.dispatch(action: "attention", body: [
                "mode": .string("start"),
                "duration_seconds": .int(Int64(Self.maximumActBurstSeconds)),
            ])
            guard let created = lease(from: started, owned: true) else {
                return .failure("The Mac's bounded human-takeover observer did not become ready.")
            }
            return .success(created)
        } catch {
            return .failure("The human-takeover observer refused: \(error).")
        }
    }

    static func addAttention(_ attention: BurstAttention?, to body: inout [String: JSONValue]) {
        guard let attention else { return }
        body["attention_session"] = .string(attention.session)
        body["attention_user_sequence"] = .int(attention.userSequence)
    }

    private func actOnce(
        verb rawVerb: String,
        target: String,
        text: String?,
        to destination: String?,
        toApp destinationApp: String?,
        seconds: Double?,
        holding: String?,
        button rawButton: String?,
        scrollAmount: Int?,
        attention: BurstAttention?,
        /// Her-screen Phase 4 — the background anchor: every look in this act
        /// reads THAT app's window, and nothing is raised.
        app: String? = nil,
        /// After a `front:true` raise: the pid that must be in front, or the
        /// act refuses rather than land in whatever took the front instead.
        expect: FrontExpectation? = nil,
        /// Batched steps: hands the post-act read to the next step.
        carry: SightCarry? = nil
    ) async -> MacFourVerbsReply {
        let parsedVerb = Self.parseVerb(rawVerb)
        var verbName = parsedVerb.0
        let parsedDirection = parsedVerb.1
        // "press" is how people say both: a key or chord → key, a name → click.
        if verbName == "press" { verbName = Self.pressMeansKey(target) ? "key" : "click" }
        // {verb:key, target:"Save As", text:"cmd+a"}: the chord rode in text
        // and target named the field (09-24: unknownKey("Save")).
        let target = verbName == "key" && (try? MacKeySyntax.parseChords(Self.keySpec(target) ?? target)) == nil
            && text.map(Self.pressMeansKey) == true ? text ?? target : target
        /// The escalation ladder's middle rung, in words: nothing was touched,
        /// here is why the front is needed, and how to ask for it.
        func needsFront(_ reason: String, screen: String? = nil, delivered: Bool = false) -> MacFourVerbsReply {
            let name = app ?? "that app"
            let touched = delivered
                ? "An accessibility action already went to \(name) without confirming, so check the screen below before repeating; nothing came to the front. "
                : "I haven't touched \(name) and nothing came to the front. "
            return MacFourVerbsReply(
                ok: false,
                text: "needs_front: \(reason). " + touched
                    + "Repeat with front: true and I'll bring \(name) forward briefly, then put the front app back: "
                    + "act app:\"\(name)\" verb:\"\(verbName)\" target:\"\(target)\" front:true"
                    + (verbName == "key" || reason.contains("menu") ? ". " + Self.oneCallNudge : "")
                    + (screen.map { "\n" + $0 } ?? ""),
                detail: [
                    "error": .string("needs_front"),
                    "status": .string("needs_front"),
                    "needs_front_reason": .string(reason),
                    "background": .bool(true),
                    "user_front_changed": .bool(false),
                ]
            )
        }
        if app != nil {
            if PhysicalVerb(rawValue: verbName) != nil {
                return needsFront("\(verbName) moves the real pointer or keyboard, which only reaches the app in front")
            }
            if holding != nil || rawButton.map({ ["left", "right"].contains($0.lowercased()) }) == true {
                return needsFront("held keys and explicit mouse buttons are real input, which only reaches the app in front")
            }
        }
        // fable51 item 32b — `to_app` says whose window the DROP lands in, so
        // it is meaningless anywhere but a drag. Refused before a look, because
        // silently ignoring it would let the model believe a cross-app act
        // happened when a same-window one did.
        let namedDestinationApp = destinationApp
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let namedDestinationApp {
            guard verbName == PhysicalVerb.drag.rawValue else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.verbNotDraggableWords(verbName),
                    detail: ["error": .string(MacCrossAppDrag.verbNotDraggableReason)]
                )
            }
            guard let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.missingDestinationWords(namedDestinationApp),
                    detail: ["error": .string(MacCrossAppDrag.missingDestinationReason)]
                )
            }
        }
        let amount = scrollAmount ?? 0
        guard (0...120).contains(amount), amount == 0 || verbName == "scroll" else {
            return MacFourVerbsReply(ok: false,
                text: "Scroll amount must be 1–120 lines, or 0 for the ordinary/default action. I haven't sent input.",
                detail: ["error": .string("invalid_scroll_amount")])
        }
        let normalizedButton = rawButton?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Some tool bindings require every declared field. An explicit auto
        // value preserves ordinary semantic/key/hover actions in those bindings.
        let button = normalizedButton == "auto" ? nil : normalizedButton
        if let button {
            guard MacMouseButton(rawValue: button) != nil,
                  ["click", "open", "drag", "hold"].contains(verbName),
                  !(verbName == "hold" && Self.keySpec(target) != nil) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "Use auto for the ordinary action, or left/right on a click, open, drag, or pointer hold. I haven't sent input.",
                    detail: ["error": .string("invalid_mouse_button_action")]
                )
            }
        }
        let direction: ScrollDirection = {
            guard verbName == MacActVerb.scroll.rawValue else { return parsedDirection }
            let hint = Self.normalize(text ?? "")
            if hint == "up" || hint.contains("scroll up") { return .up }
            if hint == "down" || hint.contains("scroll down") { return .down }
            if hint == "left" || hint.contains("scroll left") { return .left }
            if hint == "right" || hint.contains("scroll right") { return .right }
            return parsedDirection
        }()
        // In a front:true flow a command chord that a menu item carries
        // presses that item: right after a menu or sheet closes a posted key
        // can be dropped, and the menu route is verified by its effect.
        if verbName == "key", expect != nil, holding == nil,
           let chords = try? MacKeySyntax.parseChords(Self.keySpec(target) ?? target),
           chords.count == 1, chords[0].modifiers.contains(.command) {
            let before: Sighting? = if let carried = carry?.take() { carried }
                else if case .seen(let hit) = await sight(part: nil) { hit } else { nil }
            if let before {
                var body: [String: JSONValue] = ["chord": .string(Self.keySpec(target) ?? target)]
                if let name = before.appName { body["app"] = .string(name) }
                if let found = try? await host.dispatch(action: "menu", body: body),
                   let row = Self.array(Self.object(found.output)["found"]).first.map({ Self.object($0) }),
                   let path = Self.string(row["path"]),
                   let menu = await menuCommandReply(path, verb: .click, app: nil, screen: before.render, pressIn: before) {
                    return menu
                }
            }
        }
        if let physical = PhysicalVerb(rawValue: verbName) {
            // A real key or pointer reaches whatever is in front: after a
            // front:true raise the hand refuses, at the moment of posting,
            // when the front is no longer that app (User switched mid-act).
            let reply = await Self.$requiredFrontPid.withValue(expect?.pid) {
                await performPhysical(
                    physical,
                    target: target,
                    destination: destination,
                    destinationApp: namedDestinationApp,
                    seconds: seconds,
                    holding: holding,
                    button: button,
                    attention: attention
                )
            }
            guard Self.string(reply.detail["error"]) == "front_changed" else { return reply }
            return MacFourVerbsReply(
                ok: false,
                text: "Another app came to the front before I could \(verbName) (user_changed_apps), so I sent nothing more.\n" + reply.text,
                detail: reply.detail.merging(["error": .string("user_changed_apps")]) { _, new in new }
            )
        }
        guard let verb = MacActVerb(rawValue: verbName) else {
            return MacFourVerbsReply(
                ok: false,
                text: "I don't have a \"\(rawVerb.trimmingCharacters(in: .whitespacesAndNewlines))\" "
                    + "hand yet. What I can do: "
                    + (MacActVerb.allCases.map(\.rawValue) + PhysicalVerb.allCases.map(\.rawValue))
                        .joined(separator: ", ") + ".",
                detail: ["error": .string("unknown_verb"), "verb": .string(rawVerb)]
            )
        }
        if verb == .type, (text ?? "").isEmpty {
            return MacFourVerbsReply(
                ok: false,
                text: "Nothing to type — give me the words and I'll put them in \"\(target)\".",
                detail: ["error": .string("missing_text")]
            )
        }

        // a. A FRESH percept. Never a stored one: resolution happens against the
        //    screen as it is at the moment of acting, which is the entire reason
        //    `frame_id` can leave her hands.
        var sighting: Sighting
        if let carried = carry?.take() {
            // A batched step: the previous step's post-act read IS this step's
            // fresh pre-read — the window is not read twice.
            sighting = carried
        } else {
            switch await sight(part: nil, app: app) {
            case .blind(let reply):
                if reply.detail["status"] == .string("in_process_route") {
                    return Self.ownAppRoute(verb: rawVerb, target: target, text: text)
                }
                return reply
            case .seen(let hit): sighting = hit
            }
        }
        // After a `front:true` raise the front must be THAT process AND that
        // window (by its rect) — another window of the same app is refused.
        if let expect, sighting.pid != expect.pid
            || (expect.frame != nil && !MacAXWindowIdentity.rectsMatch(expect.frame, sighting.windowFrame)) {
            return MacFourVerbsReply(
                ok: false,
                text: "The front window changed before I could act (front_window_changed), so I haven't touched anything.\n"
                    + sighting.render,
                // Another app took the front (User, mostly): his choice stands, nothing is put back over it.
                detail: ["error": .string(sighting.pid != expect.pid ? "user_changed_apps" : "front_window_changed")]
            )
        }
        // An explicit menu path goes straight to the menu organ.
        if Self.isMenuPath(target),
           let menu = await menuCommandReply(target, verb: verb, app: app, screen: sighting.render, pressIn: expect != nil ? sighting : nil) {
            return menu
        }

        // b. RESOLVE BY NAME.
        var resolution = verb == .scroll
            ? Self.resolveScrollTarget(target, among: sighting.targets)
            : Self.resolve(target, among: sighting.targets)
        var reobservedAfterTransientMiss = false
        var acquisitionSamples = 0
        // Motion sampling reads the FRONT screen; a background act never uses it.
        if app == nil, case .none = resolution, Self.isPotentialDynamicVisualReference(target) {
            // Fast appearance-only association needs a third frame to establish
            // motion. Spend the same two-frame acquisition budget on a temporal
            // name that cannot exist yet, without stripping its qualifier.
            let temporal = Self.hasTemporalQualifier(target)
            let sampledApp = sighting.bundleIdentifier ?? sighting.appName
            var previousTargets = sighting.targets
            for sample in 0..<(temporal ? 3 : 1) {
                guard case .none = resolution else { break }
                if sample == 2, !Self.canConfirmTemporalTurn(target, previous: previousTargets, current: sighting.targets) { break }
                switch await resampleSight(temporal: temporal, expectedApp: sampledApp) {
                case .blind(let reply): return reply
                case .seen(let refreshed):
                    previousTargets = sighting.targets
                    sighting = refreshed
                    resolution = verb == .scroll
                        ? Self.resolveScrollTarget(target, among: sighting.targets)
                        : Self.resolve(target, among: sighting.targets)
                    acquisitionSamples += 1
                    reobservedAfterTransientMiss = true
                }
            }
        }
        if app == nil, verb == .click || verb == .open {
            // A model round trip can leave only one usable motion sample.
            // Acquire at most two more, inside this act, and always resolve
            // again against the newest evidence. No click is sent while the
            // target is absent/ambiguous, and no remembered point is reused.
            let sampledApp = sighting.bundleIdentifier ?? sighting.appName
            for _ in 0..<max(0, 2 - acquisitionSamples) {
                guard case .hit(let candidate) = resolution,
                      candidate.physicalOnly, candidate.motionUncertain else { break }
                switch await sight(part: nil) {
                case .blind(let reply): return reply
                case .seen(let refreshed):
                    guard (refreshed.bundleIdentifier ?? refreshed.appName) == sampledApp else {
                        return MacFourVerbsReply(
                            ok: false,
                            text: "The foreground app changed while I was observing motion. I haven't clicked.\n" + refreshed.render,
                            detail: ["error": .string("motion_sampling_app_changed")]
                        )
                    }
                    sighting = refreshed
                    resolution = Self.resolve(target, among: refreshed.targets)
                }
            }
        }
        // Her-screen Phase 5 — muscle memory. The fresh read has no such name;
        // a remembered control is used only when the live element at its path
        // still is that control (kind, label, and it answers the name).
        var fromMemory = false
        if case .none = resolution, verb != .scroll,
           let remembered = await mapResolve(target, in: sighting) {
            resolution = remembered
            if case .hit = remembered { fromMemory = true }
        }
        switch resolution {
        case .none(let nearest):
            if let menu = await menuCommandReply(target, verb: verb, app: app, screen: sighting.render, pressIn: expect != nil ? sighting : nil) {
                return menu
            }
            var line = "Nothing on this screen is called \"\(target)\"."
            if !nearest.isEmpty {
                line += " What I can see: " + nearest.joined(separator: " · ") + "."
            } else {
                line += " Nothing here is named at all — the screen below is everything I can read."
            }
            return MacFourVerbsReply(
                ok: false,
                text: line + "\n" + sighting.render,
                detail: [
                    "error": .string("no_match"),
                    "target": .string(target),
                    "dynamic_reobserved": .bool(reobservedAfterTransientMiss),
                ]
            )

        case .ambiguous(let candidates):
            // The reply IS the question. Nothing is acted on.
            let listed = candidates.map { candidate -> String in
                Self.recoveryName(candidate) + " (\(candidate.kind))"
            }
            return MacFourVerbsReply(
                ok: false,
                text: "\(candidates.count) things match \"\(target)\": "
                    + listed.joined(separator: ", ")
                    + ". Which one? I haven't touched anything.\n" + sighting.render,
                detail: [
                    "error": .string("ambiguous"),
                    "target": .string(target),
                    "candidates": .array(candidates.map(Self.candidateDetail)),
                ]
            )

        case .hit(let candidate):
            // Her-screen 09-23 — the thing we would act on must answer to the
            // name asked. A resolution that does not is a miss, never an act.
            if !candidate.regionOnly, !Self.answers(target, candidate) {
                if let menu = await menuCommandReply(target, verb: verb, app: app, screen: sighting.render, pressIn: expect != nil ? sighting : nil) {
                    return menu
                }
                return MacFourVerbsReply(
                    ok: false,
                    text: "Nothing here answers to \"\(target)\" exactly — the closest is \(Self.name(candidate)), "
                        + "which isn't it. I haven't touched anything.\n" + sighting.render,
                    detail: ["error": .string("no_match"), "target": .string(target),
                             "nearest": .array([.string(Self.recoveryName(candidate))])]
                )
            }
            guard candidate.enabled else {
                return MacFourVerbsReply(
                    ok: false, text: "\(Self.name(candidate)) is disabled. I haven't touched it.\n" + sighting.render,
                    detail: ["error": .string("target_disabled"), "target": .string(target)]
                )
            }
            if candidate.regionOnly, verb != .scroll {
                return MacFourVerbsReply(
                    ok: false,
                    text: "\(Self.name(candidate)) is a region, not a control. I can scroll it; name a visible thing inside it to click, open, type, select, toggle, or dismiss.",
                    detail: ["error": .string("region_needs_inner_target")]
                )
            }
            if candidate.physicalOnly,
               ![MacActVerb.click, .open, .scroll].contains(verb) {
                return MacFourVerbsReply(
                    ok: false,
                    text: "\(Self.name(candidate)) is an unlabeled visual region, so I can physically click, open, scroll, move, hover, hold, or drag there without pretending I know its semantic role.",
                    detail: ["error": .string("visual_region_needs_physical_action")]
                )
            }
            // Scrolling a scroll container is a physical wheel gesture aimed at
            // that region. The semantic closed-loop meaning of scroll is
            // "bring this element into view", which is inert when the named
            // thing is the web area/list itself. Route containers through the
            // same hand so a page or game surface actually moves.
            let physicalScroll = verb == .scroll
                && (amount > 0 || direction.isHorizontal || Self.physicalScrollKinds.contains(candidate.kind))
                && (amount > 0 || direction.isHorizontal || candidate.kind == "web area" || candidate.frame != nil)
            // Background: only the app's own accessibility actions run in the
            // back. A pixel-found target or a wheel gesture is window-server
            // input, so it asks for the front instead of taking it.
            if app != nil, physicalScroll || candidate.isSupplemental {
                return needsFront(
                    physicalScroll
                        ? "scrolling it needs the wheel over the window"
                        : "\(Self.name(candidate)) was found in pixels, not accessibility, so it needs a real click",
                    screen: sighting.render
                )
            }
            if physicalScroll {
                return await performSupplementalSemantic(
                    verb,
                    direction: direction,
                    scrollAmount: amount,
                    candidate: candidate,
                    target: target,
                    text: text,
                    holding: holding,
                    attention: attention,
                    before: sighting
                )
            }
            if holding != nil || button != nil {
                guard verb != .type else {
                    return MacFourVerbsReply(
                        ok: false,
                        text: "I can't hold keys while typing text; use a key or chord action instead.",
                        detail: ["error": .string("holding_not_supported_for_type")]
                    )
                }
                return await performSupplementalSemantic(
                    verb,
                    direction: direction,
                    scrollAmount: amount,
                    candidate: candidate,
                    target: target,
                    text: text,
                    holding: holding,
                    button: button,
                    attention: attention,
                    before: sighting
                )
            }
            if candidate.isSupplemental {
                let reply = await performSupplementalSemantic(
                    verb,
                    direction: direction,
                    scrollAmount: amount,
                    candidate: candidate,
                    target: target,
                    text: text,
                    holding: holding,
                    attention: attention,
                    before: sighting
                )
                guard reobservedAfterTransientMiss else { return reply }
                var detail = reply.detail
                detail["dynamic_reobserved"] = .bool(true)
                return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
            }
            // Select on a popup means choose an item in it, verified by its
            // value — pressing it only opens the menu.
            if verb == .select, app == nil, candidate.kind == "popup" {
                return await selectInPopup(candidate, option: text ?? target, before: sighting, attention: attention)
            }
            // c. DRIVE THE EXISTING ACT PATH. The handle and the frame id are
            //    OURS — they are read off the look we just took and never
            //    appear in the reply. Raise/focus setup, the observer, the
            //    diff and every gate are the closed loop's, unchanged.
            var body: [String: JSONValue] = [
                "verb": .string(verb.rawValue),
                "handle": .string(candidate.handle),
                "frame_id": .string(sighting.frameId),
            ]
            if let text { body["text"] = .string(text) }
            if verb == .scroll { body["direction"] = .string(direction.rawValue) }
            if app != nil { body["background"] = .bool(true) }
            Self.addAttention(attention, to: &body)

            let result: MacControlResult
            do {
                result = try await host.dispatch(action: "act", body: body)
            } catch {
                return MacFourVerbsReply(
                    ok: false,
                    text: "I couldn't \(verb.rawValue) \(Self.name(candidate)): \(error).",
                    detail: ["error": .string("\(error)")]
                )
            }
            let output = Self.object(result.output)

            // d. THE REPLY, IN WORDS — then the fresh screen.
            guard result.ok else {
                // A refusal from below is translated, never echoed as a code.
                // Its own `guidance` is already plain words written for her, so
                // it is used when present rather than paraphrased.
                let mechanism = Self.plainWords(
                    Self.string(output["guidance"]) ?? Self.string(output["message"])
                ) ?? Self.refusalWords(result.error ?? "unknown")
                let after = await sight(part: nil, app: app)
                if result.error == "needs_front" {
                    var screen: String?
                    if case .seen(let hit) = after { screen = hit.render }
                    return needsFront(
                        Self.string(output["needs_front_reason"]) ?? "it needs real input to the window in front",
                        screen: screen,
                        delivered: Self.bool(output["ax_delivered"]) == true
                    )
                }
                var line = "Didn't \(verb.rawValue) \(Self.name(candidate)). " + mechanism
                if case .seen(let hit) = after { line += "\n" + hit.render }
                var detail = Self.operationDetail(result).merging([
                    "error": .string(result.error ?? "refused"),
                    "verb": .string(verb.rawValue),
                    "target": .string(target),
                ]) { current, _ in current }
                if let changed = output["front_app_changed"] { detail["user_front_changed"] = changed }
                return MacFourVerbsReply(ok: false, text: line, detail: detail)
            }

            var effect = Self.effectWords(output: output, verb: verb, typed: text)
            let after = await sight(part: nil, app: app)
            if case .seen(let hit) = after { carry?.last = hit }
            let stayedInApp: Bool = {
                guard case .seen(let hit) = after else { return false }
                if let beforeID = sighting.bundleIdentifier, let afterID = hit.bundleIdentifier {
                    return beforeID == afterID
                }
                return sighting.appName.map(Self.normalize) == hit.appName.map(Self.normalize)
            }()
            if effect.status == "acted", !stayedInApp {
                effect = EffectWords(
                    sentence: "The fresh screen is in a different app, so that outcome is not verified.",
                    status: "acted_unobserved"
                )
            }
            // Name the element the app ACTUALLY acted on, not the address she
            // used for it: `type row 1` lands in a text area, and a field's
            // label may be its content, so an editable one is named by place.
            let acted = Self.object(Self.object(Self.object(output["effect"])["acted_element"])["before"])
            let actedKind = Self.string(acted["role"]).map { MacScreenRender.kindName(role: $0) }
            let actedOn = Self.object(output["acted_on"])
            let redirected = Self.bool(actedOn["redirected"]) == true
            let dismissPressed = Self.string(Self.object(output["dismiss_target"])["label"])
            func answersLabel(_ label: String) -> Bool {
                Self.answers(target, ActTarget(handle: candidate.handle, label: label, aliases: candidate.aliases,
                                               kind: candidate.kind, ordinal: candidate.ordinal,
                                               roleOrdinal: candidate.roleOrdinal, enabled: true))
            }
            let matchedName: String = {
                if verb == .dismiss, let pressed = dismissPressed {
                    return "\"\(pressed)\"" + (answersLabel(pressed) ? "" : " in the same dialog as \(Self.name(candidate))")
                }
                if redirected {
                    let kind = Self.string(actedOn["role"]).map { MacScreenRender.kindName(role: $0) } ?? "item"
                    return "the \(kind) containing \(Self.name(candidate))"
                }
                guard let actedKind else { return Self.name(candidate) }
                if Self.editableKinds.contains(actedKind) { return "the \(actedKind) in \(sighting.place)" }
                if let label = Self.string(acted["label"]), !label.isEmpty { return "\(actedKind) \"\(label)\"" }
                return "\(actedKind) \(Self.name(candidate))"
            }()
            // Typing says what went where: `Typed "hello.txt" into "Save As"`.
            let typedInto = verb == .type
                ? " \"\(String((text ?? "").prefix(60)))\" into \"\(target.trimmingCharacters(in: .whitespacesAndNewlines))\""
                : nil
            var line = (effect.status == "acted"
                ? (typedInto == nil ? Self.pastTense(verb, direction: direction) : "Typed")
                : (typedInto == nil ? Self.attempted(verb, direction: direction) : "Tried to type"))
                + (typedInto ?? " " + matchedName) + ". " + effect.sentence
            let frontChanged = Self.bool(output["front_app_changed"])
            if app != nil, !sighting.isFront, frontChanged == false {
                line += " Done in \(sighting.appName ?? "that app")'s window in the background; nothing came to the front."
            }
            if let note = Self.bareNumberNote(target, chose: candidate, among: sighting.targets) { line += " " + note }
            if let leftOpen = Self.bool(output["menu_left_open"]) {
                line += leftOpen
                    ? " It opened a menu I couldn't close — it may still be open in \(sighting.appName ?? "that app")."
                    : " It opened a menu; I closed it."
            }
            if case .seen(let hit) = after { line += "\n" + hit.render }
            var detail = Self.operationDetail(result)
            if let frontChanged { detail["user_front_changed"] = .bool(frontChanged) }
            if app != nil { detail["background"] = .bool(true) }
            if let leftOpen = output["menu_left_open"] { detail["menu_left_open"] = leftOpen }
            detail["verb"] = .string(verb.rawValue)
            detail["target"] = .string(target)
            detail["matched"] = .string(matchedName)
            detail["status"] = .string(effect.status)
            detail["dynamic_reobserved"] = .bool(reobservedAfterTransientMiss)
            // `acted` is the closed loop's semantic verdict, not merely "an
            // event was emitted": navigation moved structurally and matched
            // its destination; typing read the intended edit back from the
            // field; other verbs produced an observed app reaction. Promote
            // that evidence on the model-facing receipt while leaving every
            // acted_unobserved branch honestly unverified.
            if effect.status == "acted" {
                detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
                detail["verification_evidence"] = .string("closed_loop_semantic_effect")
            } else {
                detail["verification"] = .string(MotorVerificationState.unverified.rawValue)
                detail.removeValue(forKey: "verification_evidence")
            }
            // "Satisfied" means the INTENDED control was hit. The element the
            // app acted on must answer to the name asked; a redirected open must
            // be an ANCESTOR of the named thing; a dismiss press must be the
            // named control or a Cancel/Close/Done/OK (the lower layer keeps it
            // to the named thing's own modal).
            let wrongLabel: String? = {
                if verb == .dismiss {
                    guard let pressed = dismissPressed, !answersLabel(pressed),
                          !MacActClosedLoop.dismissLabels.contains(pressed.lowercased()) else { return nil }
                    return pressed
                }
                if redirected {
                    let ancestor = Self.path(actedOn["path"])
                    return Self.path(output["path"]).starts(with: ancestor) ? nil
                        : (Self.string(actedOn["role"]).map { MacScreenRender.kindName(role: $0) } ?? "another element")
                }
                guard let actedLabel = Self.string(acted["label"]), !answersLabel(actedLabel) else { return nil }
                return actedLabel
            }()
            if fromMemory {
                detail["from_memory"] = .bool(true)
                line = "(From memory of this app, checked live.) " + line
            }
            if let actedLabel = wrongLabel {
                if fromMemory, let bundle = sighting.bundleIdentifier, let window = sighting.windowKind,
                   let path = candidate.sourceAXPath {
                    await MacAppMapStore.shared.penalize(bundle: bundle, window: window, path: path, evict: true)
                }
                detail["status"] = .string("wrong_target")
                detail["verification"] = .string(MotorVerificationState.failed.rawValue)
                detail.removeValue(forKey: "verification_evidence")
                var wrong = "\(Self.pastTense(verb, direction: direction)) \"\(actedLabel)\", not \"\(target)\" — "
                    + "that isn't what was asked, so this act failed."
                if case .seen(let hit) = after { wrong += "\n" + hit.render }
                return MacFourVerbsReply(ok: false, text: wrong, detail: detail)
            }
            // Verified, and the element acted on answered the name: remember
            // where it lives (or refresh it).
            if effect.status == "acted", !redirected, [MacActVerb.click, .open, .select, .toggle].contains(verb) {
                await rememberVerified(target, candidate, in: sighting)
            }
            // Calculator's key reads "Clear" while an entry is live and only
            // then "All Clear": "AC" that landed on Clear finishes the job when
            // the fresh read now shows All Clear. "C" stays just Clear.
            if ["ac", "all clear"].contains(Self.normalize(target)),
               Self.normalize(candidate.label ?? "") == "clear",
               case .seen(let hit) = after,
               hit.targets.contains(where: { !$0.isSupplemental && Self.normalize($0.label ?? "") == "all clear" }) {
                let second = await actOnce(
                    verb: rawVerb, target: "All Clear", text: nil, to: nil, toApp: nil, seconds: nil,
                    holding: nil, button: nil, scrollAmount: nil, attention: attention,
                    app: app, expect: expect, carry: carry
                )
                return MacFourVerbsReply(
                    ok: second.ok,
                    text: (second.ok ? "Pressed Clear, then All Clear. " : "Pressed Clear; All Clear then failed. ")
                        + second.text,
                    detail: second.detail.merging(["pressed_first": .string("Clear")]) { current, _ in current }
                )
            }
            return MacFourVerbsReply(
                ok: true,
                text: line,
                detail: detail
            )
        }
    }

    private func performSupplementalSemantic(
        _ verb: MacActVerb,
        direction: ScrollDirection,
        scrollAmount: Int = 0,
        candidate: ActTarget,
        target: String,
        text: String?,
        holding: String?,
        button: String? = nil,
        attention: BurstAttention?,
        before: Sighting
    ) async -> MacFourVerbsReply {
        let spokenTarget = Self.spokenName(candidate, requestedAs: target)
        if let viewId = candidate.viewId, let mark = candidate.mark,
           verb != .open, verb != .scroll, holding == nil, button == nil {
            var body: [String: JSONValue] = [
                "view": .string(viewId),
                "mark": .int(Int64(mark)),
            ]
            if verb == .type {
                guard let text, !text.isEmpty else {
                    return MacFourVerbsReply(ok: false, text: "Nothing to type into \(spokenTarget).")
                }
                body["value"] = .string(text)
            } else {
                body["action"] = .string("AXPress")
            }
            let first = await performObservedDispatch(
                action: "ax_act",
                body: body,
                description: Self.pastTense(verb, direction: direction) + " " + spokenTarget + ".",
                before: before,
                target: target,
                verb: verb.rawValue,
                attention: attention
            )
            // 2026-09-22: a live screen shifts between look and act; one fresh
            // look and re-resolve by the same name, then one dispatch. No loop.
            guard !first.ok, Self.string(first.detail["error"])?.hasPrefix("mark_drifted") == true,
                  case .seen(let fresh) = await sight(part: nil),
                  case .hit(let again) = Self.resolve(target, among: fresh.targets),
                  let freshView = again.viewId, let freshMark = again.mark else { return first }
            body["view"] = .string(freshView)
            body["mark"] = .int(Int64(freshMark))
            return await performObservedDispatch(
                action: "ax_act",
                body: body,
                description: Self.pastTense(verb, direction: direction) + " " + Self.spokenName(again, requestedAs: target) + ".",
                before: fresh,
                target: target,
                verb: verb.rawValue,
                attention: attention
            )
        }

        var body: [String: JSONValue] = [:]
        let usesPageKey = verb == .scroll && candidate.kind == "web area"
            && !direction.isHorizontal && scrollAmount == 0
        if !usesPageKey {
            guard let candidateFrame = Self.visiblePortion(of: candidate.frame, within: before.visibleFrame) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "I can see \(spokenTarget), but I do not have a safe point for it.",
                    detail: ["error": .string("target_has_no_physical_point")]
                )
            }
            let exactAppearanceAlias = candidate.aliases.contains {
                Self.normalize($0) == Self.normalize(target)
            }
            guard let point = Self.safeAimPoint(for: candidate, in: candidateFrame,
                describedBy: exactAppearanceAlias ? "" : target) else {
                return Self.obstructedPointReply(screen: before.render)
            }
            body["x"] = .double(point.x)
            body["y"] = .double(point.y)
        }
        if let holding { body["holding"] = .string(holding) }
        if let button { body["button"] = .string(button) }
        switch verb {
        case .click, .select, .toggle, .dismiss:
            body["gesture"] = .string("click")
        case .open:
            body["gesture"] = .string("double_click")
        case .type:
            guard let text, !text.isEmpty else {
                return MacFourVerbsReply(ok: false, text: "Nothing to type into \(spokenTarget).")
            }
            body["gesture"] = .string("click_type")
            body["text"] = .string(text)
        case .scroll:
            if usesPageKey {
                // Live Chrome proof: synthesized wheel events were accepted
                // but inert on the AX web area, while the ordinary Page key
                // moved the same visible document and produced fresh proof.
                // Keep that physical distinction below the natural scroll
                // verb; the caller still names the region and direction.
                body["gesture"] = .string("key")
                body["keys"] = .string(direction == .up ? "pageup" : "pagedown")
            } else {
                body["gesture"] = .string("scroll")
                let magnitude = Int64(scrollAmount == 0 ? 6 : scrollAmount)
                body["dx"] = .int(direction == .left ? magnitude : direction == .right ? -magnitude : 0)
                body["dy"] = .int(direction == .up ? magnitude : direction == .down ? -magnitude : 0)
            }
        }
        let reply = await performHand(
            body: body,
            description: (button == "right" ? (verb == .open ? "Double-right-clicked" : "Right-clicked")
                : Self.pastTense(verb, direction: direction)) + " " + spokenTarget + ".",
            unverifiedDescription: verb == .scroll
                ? "Tried to scroll \(direction.rawValue) in \(spokenTarget)."
                : nil,
            attention: attention,
            before: before,
            allowGenericScreenChangeVerification: !candidate.physicalOnly,
            afterPart: candidate.physicalOnly ? "visual surface" : nil
        )
        var detail = reply.detail
        detail["verb"] = .string(verb.rawValue)
        if let button { detail["button"] = .string(button) }
        detail["target"] = .string(target)
        detail["matched"] = .string(Self.name(candidate))
        let physicalRoute: String
        switch verb {
        case .click, .select, .toggle, .dismiss: physicalRoute = "click"
        case .open: physicalRoute = "double_click"
        case .type: physicalRoute = "click_type"
        case .scroll: physicalRoute = usesPageKey ? "page_key" : "wheel"
        }
        detail["physical_route"] = .string(physicalRoute)
        detail["status"] = .string(
            Self.string(detail["verification"]) == MotorVerificationState.satisfied.rawValue
                ? "acted"
                : "acted_unobserved"
        )
        return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
    }

    private func performObservedDispatch(
        action: String,
        body: [String: JSONValue],
        description: String,
        before: Sighting,
        target: String,
        verb: String,
        attention: BurstAttention?
    ) async -> MacFourVerbsReply {
        let result: MacControlResult
        var request = body
        Self.addAttention(attention, to: &request)
        do { result = try await host.dispatch(action: action, body: request) }
        catch {
            return MacFourVerbsReply(ok: false, text: "I couldn't act on \(target): \(error).")
        }
        guard result.ok else {
            return MacFourVerbsReply(
                ok: false,
                text: "Didn't \(verb) \"\(target)\". \(result.error ?? "The Mac refused the action.")\n" + before.render,
                detail: Self.operationDetail(result).merging(["error": .string(result.error ?? "refused")]) { current, _ in current }
            )
        }
        return await observedReply(result: result, description: description, before: before)
    }

    /// After a `front:true` raise: the pid every posted hand event requires in front.
    @TaskLocal static var requiredFrontPid: Int32?

    func performHand(
        body: [String: JSONValue],
        description: String,
        unverifiedDescription: String? = nil,
        attention: BurstAttention? = nil,
        before: Sighting?,
        allowGenericScreenChangeVerification: Bool = true,
        afterPart: String? = nil,
        pointerTarget: String? = nil
    ) async -> MacFourVerbsReply {
        let result: MacControlResult
        var request = body
        Self.addAttention(attention, to: &request)
        if let pid = Self.requiredFrontPid { request["require_front_pid"] = .int(Int64(pid)) }
        // This composed physical-only act already owns a fresh pre-observation
        // and the mandatory observedReply below. Recapturing inside the hand
        // delays input after its motion-compensated point was calculated.
        if before != nil, afterPart == "visual surface", !allowGenericScreenChangeVerification {
            request["defer_visual_verification"] = .bool(true)
        }
        do { result = try await host.dispatch(action: "hand", body: request) }
        catch { return MacFourVerbsReply(ok: false, text: "I couldn't use that hand: \(error).") }
        guard result.ok else {
            return MacFourVerbsReply(
                ok: false,
                text: "Couldn't do that. \(result.error ?? "The Mac refused the gesture.")"
                    + (before.map { "\n" + $0.render } ?? ""),
                detail: Self.operationDetail(result).merging(["error": .string(result.error ?? "refused")]) { current, _ in current }
            )
        }
        return await observedReply(
            result: result,
            description: description,
            unverifiedDescription: unverifiedDescription,
            before: before,
            allowGenericScreenChangeVerification: allowGenericScreenChangeVerification,
            afterPart: afterPart,
            pointerTarget: pointerTarget
        )
    }

    // MARK: Her-screen Phase 5 — batched steps

    static let maximumActSteps = 12
    static let oneCallNudge = "A whole flow (menu, sheet, name, Save) fits in one act call with steps."

    /// One batch's hand-off: the post-act read of step N, taken once and used
    /// as step N+1's pre-read. Sequential use inside one call only.
    final class SightCarry: @unchecked Sendable {
        var last: Sighting?
        func take() -> Sighting? {
            defer { last = nil }
            return last
        }
    }

    /// Each step is resolved against a FRESH read of the anchored window (the
    /// previous step's post-act read, never a second read), verified by the
    /// same effect and wrong_target checks, and the batch stops at the first
    /// failure. One line per step, the final screen once.
    func actSteps(_ steps: [MacActStep], app: String?, expect: FrontExpectation?) async -> MacFourVerbsReply {
        guard steps.count <= Self.maximumActSteps else {
            return MacFourVerbsReply(
                ok: false,
                text: "That's \(steps.count) steps; one act takes at most \(Self.maximumActSteps). Nothing was touched.",
                detail: ["error": .string("too_many_steps")]
            )
        }
        let carry = SightCarry()
        var lines: [String] = []
        var screen: String?
        var frontChanged = false
        for (index, asked) in steps.enumerated() {
            // "OK?" — an optional step (a confirm that only sometimes appears):
            // skipped, not failed, when nothing answers to it.
            let optional = asked.target.hasSuffix("?") && asked.target.count > 1
            let step = optional ? MacActStep(verb: asked.verb, target: String(asked.target.dropLast()), text: asked.text) : asked
            // After step 1 the app's own sheet or dialog (a save sheet) may be
            // what's in front: the same process is still required, not the
            // same window rect.
            let stepExpect: FrontExpectation? = index == 0 ? expect : expect.map { (pid: $0.pid, frame: nil) }
            var reply = await actOnce(
                verb: step.verb, target: step.target, text: step.text, to: nil, toApp: nil,
                seconds: nil, holding: nil, button: nil, scrollAmount: nil, attention: nil,
                app: app, expect: stepExpect, carry: carry
            )
            // A step may name what the previous one is still bringing up (a
            // sheet sliding in): look again briefly before calling it a miss.
            // A drift refusal (the window changed since the read the step
            // resolved on — a sheet still settling) is refused BEFORE acting:
            // one fresh read and re-resolve by name.
            var looks = 0
            var reResolved = false
            while true {
                let error = Self.string(reply.detail["error"])
                if index > 0, looks < 3, error == "no_match" {
                    looks += 1
                } else if !reResolved, ["handle_drifted", "window_drifted", "frame_window_gone", "stale_frame"].contains(error) {
                    reResolved = true
                } else {
                    break
                }
                await clock.sleep(seconds: 0.4)
                reply = await actOnce(
                    verb: step.verb, target: step.target, text: step.text, to: nil, toApp: nil,
                    seconds: nil, holding: nil, button: nil, scrollAmount: nil, attention: nil,
                    app: app, expect: stepExpect, carry: carry
                )
            }
            if optional, Self.string(reply.detail["error"]) == "no_match" {
                lines.append("\(index + 1) \(step.target) — not there, skipped (optional)")
                continue
            }
            let parts = reply.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count > 1 { screen = String(parts[1]) }
            if Self.bool(reply.detail["user_front_changed"]) == true { frontChanged = true }
            let verified = Self.string(reply.detail["verification"]) == MotorVerificationState.satisfied.rawValue
            let mark = !reply.ok ? "✗" : (verified ? "✓" : "~ (unverified)")
            lines.append("\(index + 1) \(parts.first.map(String.init) ?? step.target) \(mark)")
            if !reply.ok, Self.string(reply.detail["error"]) == "no_match" {
                lines[lines.count - 1] += " (if it only sometimes appears, write it as \"\(step.target)?\")"
            }
            guard reply.ok else {
                let why = Self.string(reply.detail["error"]) ?? Self.string(reply.detail["status"]) ?? "failed"
                var detail = reply.detail
                detail["failed_step"] = .int(Int64(index + 1))
                detail["steps_completed"] = .int(Int64(index))
                detail["steps_total"] = .int(Int64(steps.count))
                detail["user_front_changed"] = .bool(frontChanged)
                return MacFourVerbsReply(
                    ok: false,
                    text: "Stopped at step \(index + 1) of \(steps.count) (\(why)); the rest were not run.\n"
                        + lines.joined(separator: "\n") + (screen.map { "\n" + $0 } ?? ""),
                    detail: detail
                )
            }
        }
        if screen == nil, case .seen(let hit) = await sight(part: nil, app: app) { screen = hit.render }
        return MacFourVerbsReply(
            ok: true,
            text: "Did all \(steps.count) steps.\n" + lines.joined(separator: "\n") + (screen.map { "\n" + $0 } ?? ""),
            detail: [
                "steps_completed": .int(Int64(steps.count)),
                "steps_total": .int(Int64(steps.count)),
                "user_front_changed": .bool(frontChanged),
                "background": .bool(app != nil),
            ]
        )
    }

    /// Her-screen Phase 5 — a name the window doesn't have may be a MENU
    /// command. Ask the menu organ (menus only, never a window walk) and, when
    /// it is there, say where and its key equivalent instead of a bare miss.
    /// `pressIn` (the app was brought in front with `front: true`): the menu
    /// command is pressed through the app's own menu, not described.
    func menuCommandReply(
        _ target: String, verb: MacActVerb, app: String?, screen: String, pressIn: Sighting? = nil
    ) async -> MacFourVerbsReply? {
        guard [.click, .open, .select, .toggle].contains(verb) else { return nil }
        if let before = pressIn {
            guard let row = await menuFind(target, app: before.appName),
                  let path = Self.string(row["path"]) else { return nil }
            var press: [String: JSONValue] = ["path": .string(path), "require_front": .bool(true)]
            if let name = before.appName { press["app"] = .string(name) }
            let pressed = try? await host.dispatch(action: "menu_press", body: press)
            if pressed?.error == "front_changed" {
                // User took the front during the lookup: his choice stands.
                return MacFourVerbsReply(
                    ok: false, text: "The person changed apps; nothing pressed.",
                    detail: ["error": .string("user_changed_apps"), "menu_path": .string(path)]
                )
            }
            guard pressed?.ok == true else {
                let why = Self.string(Self.object(pressed?.output)["message"]) ?? "the app refused it"
                return MacFourVerbsReply(
                    ok: false, text: "Couldn't press the menu command \(path): \(why)\n" + screen,
                    detail: ["error": .string(pressed?.error ?? "menu_press_failed"), "menu_path": .string(path)]
                )
            }
            // Menus run the app's own handler; the fresh read is the evidence.
            var detail: [String: JSONValue] = ["menu_path": .string(path), "status": .string("acted_unobserved"),
                                               "verification": .string(MotorVerificationState.unverified.rawValue)]
            var text = "Pressed the menu command \(path)."
            // A sheet, dialog or window the command opens can take a moment:
            // re-look briefly (as steps do) before calling the screen unchanged.
            var after: Sighting?
            for look in 0..<4 {
                if look > 0 { await clock.sleep(seconds: 0.4) }
                guard case .seen(let hit) = await sight(part: nil) else { break }
                after = hit
                if hit.effectRender != before.effectRender { break }
            }
            // The render carries sheets, dialogs and the window title; the item's
            // own title flipping (Make Plain Text → Make Rich Text) counts too —
            // only when the menus read back, not when the read itself failed.
            let changed = after.map { $0.effectRender != before.effectRender } == true
            let recheck = changed ? nil : await menuLookup(path, app: before.appName)
            let evidence: String? = changed ? "fresh_visible_screen_change"
                : (recheck.map { $0.row == nil && $0.readable } == true ? "menu_item_title_changed" : nil)
            if let evidence {
                text += evidence == "fresh_visible_screen_change"
                    ? " The fresh screen changed after it." : " The menu item itself changed after it."
                detail["status"] = .string("acted")
                detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
                detail["verification_evidence"] = .string(evidence)
            } else {
                text += " The fresh screen did not visibly change."
            }
            if let after { text += "\n" + after.render }
            return MacFourVerbsReply(ok: true, text: text, detail: detail)
        }
        guard let row = await menuFind(target, app: app), let path = Self.string(row["path"]) else { return nil }
        let menuName = MacMenuBar.components(path).first ?? path
        let glyphs = Self.string(row["shortcut"])
        let chord = Self.string(row["chord"])
        let greyed = Self.bool(row["enabled"]) == false ? " It's greyed out right now."
            : (row["enabled"] == nil ? " Whether it's greyed out is unknown until \(app ?? "the app") is in front." : "")
        let shortcut = glyphs.map { " (\($0))" } ?? ""
        var detail: [String: JSONValue] = [
            "menu_path": .string(path),
            "target": .string(target),
            "user_front_changed": .bool(false),
        ]
        if let glyphs { detail["shortcut"] = .string(glyphs) }
        if let chord { detail["chord"] = .string(chord) }
        let text: String
        if let app {
            detail["error"] = .string("needs_front")
            detail["status"] = .string("needs_front")
            detail["needs_front_reason"] = .string("it's a menu command")
            detail["background"] = .bool(true)
            // The exact ready-to-use call, so the next turn is one step.
            let call = chord.map { "act app:\"\(app)\" verb:\"key\" target:\"\($0)\" front:true" }
                ?? "act app:\"\(app)\" verb:\"click\" target:\"\(path)\" front:true"
            text = "\"\(target)\" is in \(app)'s \(menuName) menu\(shortcut) — that needs \(app) in front. Use: \(call)"
                + ". Nothing was touched. " + Self.oneCallNudge + greyed
        } else {
            detail["error"] = .string("in_menu")
            detail["status"] = .string("in_menu")
            text = "\"\(target)\" isn't in the window; it's the menu command \(path)\(shortcut). Use: "
                + (chord.map { "act verb:\"key\" target:\"\($0)\"" } ?? "menu_press \"\(path)\"")
                + ". Nothing was touched." + greyed
        }
        return MacFourVerbsReply(ok: false, text: text + "\n" + screen, detail: detail)
    }

    /// Her-screen 09-24 — `select` on a popup: open it, click the named item
    /// in the open menu, and verify the popup's value now reads it. An item
    /// the menu lacks closes the menu and fails with the options it has.
    func selectInPopup(_ popup: ActTarget, option: String, before: Sighting, attention: BurstAttention?) async -> MacFourVerbsReply {
        func fail(_ words: String, _ error: String, screen: String) -> MacFourVerbsReply {
            MacFourVerbsReply(ok: false, text: words + "\n" + screen,
                              detail: ["error": .string(error), "verb": .string("select"), "target": .string(option)])
        }
        var body: [String: JSONValue] = [
            "verb": .string("click"), "handle": .string(popup.handle), "frame_id": .string(before.frameId),
        ]
        Self.addAttention(attention, to: &body)
        guard let opened = try? await host.dispatch(action: "act", body: body), opened.ok,
              case .seen(let open) = await sight(part: nil) else {
            return fail("Couldn't open \(Self.name(popup)).", "popup_not_opened", screen: before.render)
        }
        let items = open.targets.filter { $0.kind == "menu item" }
        guard case .hit(let item) = Self.resolve(option, among: items), Self.answers(option, item), item.enabled else {
            _ = try? await host.dispatch(action: "hand", body: ["gesture": .string("key"), "keys": .string("escape")])
            let offered = items.compactMap { $0.enabled ? $0.label : nil }.filter { !$0.isEmpty }
            return fail(
                "\(Self.name(popup)) has no \"\(option)\" to choose"
                    + (offered.isEmpty ? "." : "; it offers: " + offered.joined(separator: ", ") + ".")
                    + " I closed it; nothing changed.",
                "option_not_offered", screen: before.render
            )
        }
        let picked = await performSupplementalSemantic(
            .click, direction: .down, candidate: item, target: option, text: nil, holding: nil,
            attention: attention, before: open
        )
        guard picked.ok, case .seen(let after) = await sight(part: nil) else { return picked }
        // The popup's own value is the evidence, not the menu closing.
        let value = Self.array(Self.object(after.controls)["affordances"]).map { Self.object($0) }.first { row in
            (popup.sourceAXPath.map { Self.path(row["path"]) == $0 } ?? false)
                || Self.string(row["handle"]) == popup.handle
        }.flatMap { Self.string($0["value"]) }
        let wanted = item.label ?? option
        var detail: [String: JSONValue] = ["verb": .string("select"), "target": .string(option), "matched": .string(wanted)]
        guard let value else {
            detail["status"] = .string("acted_unobserved")
            detail["verification"] = .string(MotorVerificationState.unverified.rawValue)
            return MacFourVerbsReply(ok: true, text: "Chose \"\(wanted)\" in \(Self.name(popup)); its value didn't read back.\n" + after.render, detail: detail)
        }
        guard Self.normalize(value) == Self.normalize(wanted) else {
            detail["error"] = .string("wrong_value")
            detail["status"] = .string("wrong_target")
            detail["verification"] = .string(MotorVerificationState.failed.rawValue)
            return MacFourVerbsReply(ok: false, text: "Chose \"\(wanted)\" but \(Self.name(popup)) reads \"\(value)\".\n" + after.render, detail: detail)
        }
        detail["status"] = .string("acted")
        detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
        detail["verification_evidence"] = .string("popup_value_matches")
        return MacFourVerbsReply(ok: true, text: "Selected \"\(wanted)\" in \(Self.name(popup)); it now reads that.\n" + after.render, detail: detail)
    }

    /// The menu item `target` names: a path ("Format › Make Plain Text") or a
    /// bare name. Menu titles are literal, so the name is tried as said first
    /// ("Make Plain Text" keeps its "Text"), then without a trailing role word.
    func menuFind(_ target: String, app: String?) async -> [String: JSONValue]? {
        await menuLookup(target, app: app).row
    }

    /// `readable`: the walk reached real items (a level under a menu) in the
    /// menus it looked in. An app launched in the back may publish a missing
    /// or bare menu bar until it is first activated — absent there is unknown.
    func menuLookup(_ target: String, app: String?) async -> (row: [String: JSONValue]?, readable: Bool) {
        let said = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = Self.stripRoleWords(said)
        let names = MacMenuBar.isPath(said) || stripped == Self.normalize(said) ? [said] : [said, stripped]
        var readable = false
        for name in names {
            var body: [String: JSONValue] = ["find": .string(name)]
            if let app { body["app"] = .string(app) }
            guard let found = try? await host.dispatch(action: "menu", body: body) else { continue }
            let output = Self.object(found.output)
            if Self.array(output["paths"]).contains(where: { (Self.string(Self.object($0)["path"]) ?? "").contains("›") }) {
                readable = true
            }
            if found.ok, let first = Self.array(output["found"]).first { return (Self.object(first), true) }
        }
        return (nil, readable)
    }

    /// An act verb this hand has, or the short answer listing them.
    static func unknownVerb(_ rawVerb: String, target: String) -> MacFourVerbsReply? {
        var name = parseVerb(rawVerb).0
        if name == "press" { name = pressMeansKey(target) ? "key" : "click" }
        guard MacActVerb(rawValue: name) == nil, PhysicalVerb(rawValue: name) == nil else { return nil }
        let verbs = (MacActVerb.allCases.map(\.rawValue) + PhysicalVerb.allCases.map(\.rawValue) + ["press"])
        return MacFourVerbsReply(
            ok: false,
            text: "No \"\(rawVerb.trimmingCharacters(in: .whitespacesAndNewlines))\" verb. Use: "
                + verbs.joined(separator: ", ") + ". Nothing moved.",
            detail: ["error": .string("unknown_verb"), "verb": .string(rawVerb), "user_front_changed": .bool(false)]
        )
    }

    /// "Format › Make Plain Text": an explicit menu path, never a window name.
    static func isMenuPath(_ target: String) -> Bool {
        MacMenuBar.isPath(target) && MacMenuBar.components(target).count > 1
    }

    /// Her-screen 09-24 — before `front: true` raises anything: does the app's
    /// background read (window, app map, menus) have what this act names? A
    /// miss is answered here and nothing moves. Keys, motion targets and
    /// unknown verbs are left to the act itself.
    func missBeforeRaise(verb rawVerb: String, target: String, in seen: Sighting) async -> MacFourVerbsReply? {
        var verbName = Self.parseVerb(rawVerb).0
        if verbName == "press" { verbName = Self.pressMeansKey(target) ? "key" : "click" }
        guard let verb = MacActVerb(rawValue: verbName), !Self.isPotentialDynamicVisualReference(target) else { return nil }
        let clickish = [MacActVerb.click, .open, .select, .toggle].contains(verb)
        if !(clickish && Self.isMenuPath(target)) {
            switch verb == .scroll ? Self.resolveScrollTarget(target, among: seen.targets) : Self.resolve(target, among: seen.targets) {
            case .ambiguous: return nil
            case .hit(let candidate) where candidate.regionOnly || Self.answers(target, candidate): return nil
            default: break
            }
            if verb != .scroll, case .hit? = await mapResolve(target, in: seen) { return nil }
        }
        // A menu path is never judged from the back: a background app's menus
        // keep the last key window's titles (Make Plain Text reads Make Rich
        // Text), so only the press after the raise can tell. It refuses and
        // restores if the item really isn't there.
        if clickish, Self.isMenuPath(target) { return nil }
        if clickish {
            // Found, or menus not readable in the back yet: the real press decides.
            let menu = await menuLookup(target, app: seen.appName)
            if menu.row != nil || !menu.readable { return nil }
        }
        let name = seen.appName ?? "that app"
        return MacFourVerbsReply(
            ok: false,
            text: "Nothing in \(name) is called \"\(target)\" — not in its window or its menus — so I didn't bring \(name) forward. Nothing moved.\n"
                + seen.render,
            detail: ["error": .string("no_match"), "target": .string(target), "user_front_changed": .bool(false)]
        )
    }

    static func keySpec(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in ["key ", "key:", "chord ", "chord:"] where lower.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }


}

import Foundation
import NativeAgentCore
import PersistenceCore
import AppKit
import Experiences
import CryptoKit
// Blueprint: | `MacFourVerbs+Act.swift` | `MacFourVerbs`: `act`, `addAttention`, `frontChangedWords`; named/exact act dispatch, repetition and semantic/physical effect receipts |

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
        mode: MacTypeMode = .replace,
        to destination: String? = nil,
        /// Destination app for `to`; nil keeps both drag endpoints in the same window.
        toApp destinationApp: String? = nil,
        seconds: Double? = nil,
        repeat requestedRepeat: Int? = nil,
        interval: Double? = nil,
        holding: String? = nil,
        button: String? = nil,
        scrollAmount: Int? = nil,
        /// Act in the named running app's window without raising it; nil selects the ordinary frontmost act.
        app: String? = nil,
        /// With `app`: bring it forward for this act, then put the person's
        /// front app back. Requires an explicit foreground request from the task.
        front: Bool = false,
        /// Run an ordered batch in one call; when supplied, steps replace `verb` and `target`.
        steps: [MacActStep] = [],
        again: Bool = false,
        /// A place on an image instead of a target name.
        place: MacImagePlace? = nil
    ) async -> MacFourVerbsReply {
        let started = ContinuousClock.now
        let reply = await { () async -> MacFourVerbsReply in
            if steps.isEmpty, Self.parseVerb(rawVerb).0 == "key",
               (try? MacKeySyntax.parseChords(Self.keySpec(target) ?? target)) == nil,
               let holding, let chords = try? MacKeySyntax.parseChords(holding),
               chords.count == 1, !chords[0].modifiers.isEmpty {
                return .init(ok: false,
                    text: "For key, target is the chord; app names the application. Nothing was pressed. Use next_call.",
                    detail: ["error": .string("key_chord_in_holding"), "effects": .string("none"),
                        "next_call": .object(["tool": .string("app"), "input": .object([
                            "action": .string("mac.act"), "args": .object([
                                "app": .string(app ?? target), "verb": .string("key"), "target": .string(holding)])])])])
            }
            if MacDriverContext.binding == nil {
                let binding = await MacAttentionSessionStore.shared.bindDriver()
                return await withTaskCancellationHandler {
                    defer { binding.releaseHeldInputs() }
                    return await MacDriverContext.$binding.withValue(binding) {
                        await act(verb: rawVerb, target: target, text: text, mode: mode,
                                  to: destination, toApp: destinationApp, seconds: seconds,
                                  repeat: requestedRepeat, interval: interval, holding: holding,
                                  button: button, scrollAmount: scrollAmount, app: app, front: front, steps: steps, again: again, place: place)
                    }
                } onCancel: { binding.cancel() }
            }
            // Acts serialize through app-map persistence before the next act starts.
            guard await MacActSerial.shared.acquire() else {
                return .init(ok: false, text: "The action was cancelled before it started.", detail: ["error": .string("cancelled")])
            }
            await MacActSerial.shared.ownInputs(MacDriverContext.binding)
            let acted: MacFourVerbsReply = await Self.$holdsActSerial.withValue(true) {
            let continuation = MacWorkContinuation.current.flatMap { $0.isPending ? $0 : nil }
            if let refusal = continuation?.refusal() {
                return .init(ok: false, text: refusal, detail: ["error": .string("continuation_unavailable")])
            }
            if let continuation, let app, let captured = continuation.app,
               app.caseInsensitiveCompare(captured.name) != .orderedSame,
               app.caseInsensitiveCompare(captured.bundleIdentifier ?? "") != .orderedSame {
                return .init(ok: false, text: continuation.modelContext,
                    detail: ["error": .string("continuation_target_mismatch")])
            }
            let anchor = (continuation?.app?.bundleIdentifier ?? continuation?.app?.name ?? app)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            // The screen decides, not the flags: an app already in front is acted
            // on in front (every event still requires its pid), and while Shotgun
            // is up the person has handed her the screen, so an app behind is
            // brought forward for the act. A native surface is never raised.
            let mayRaise = front || (PersonOnlyWindows.isShowing && Self.nativeSurfaceApp == nil)
            // Her stopped batch is continued by her next act in this chat when that
            // act is a batch that starts with the steps that landed; any other act
            // has moved the screen on, so the stopped batch is over.
            var flow: ActFlow?
            if let root = flowRoot, let session = flowSession {
                let scope = Self.actFlowScope(session)
                // The app is the anchor, or the one in front when the batch runs there.
                flow = ActFlow(digests: Self.actStepDigests(steps, app: anchor ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
                if !again, !steps.isEmpty {
                    let open: Experience?
                    do { open = try await Flow.open(root, scope: scope) } catch {
                        return .init(ok: false,
                            text: "I can't read whether a stopped batch in this chat already did some of these steps (\(error.localizedDescription)), "
                                + "so none ran. Send it with again:true to run every step.",
                            detail: ["error": .string("flow_unreadable"), "effects": .string("none")])
                    }
                    if let open, flow?.continues(Flow.landed(open)) == true {
                        flow?.landed = Flow.landed(open)
                        flow?.at = open.updatedAt ?? open.at
                    } else {
                        Flow.dropped(root, scope: scope)
                    }
                } else {
                    Flow.dropped(root, scope: scope)
                }
            }
            let run: ([MacActStep], String?, FrontExpectation?, Sighting?) async -> MacFourVerbsReply = { steps, anchorApp, expect, seen in
                // In front, every hand event of this act requires that app's pid.
                await Self.$requiredFrontPid.withValue(expect?.pid) { await Self.$foregroundRequested.withValue(mayRaise) {
                    guard steps.isEmpty else { return await self.actSteps(steps, app: anchorApp, expect: expect, seen: seen, flow: flow) }
                    return await self.actCore(
                        verb: rawVerb, target: target, text: text, mode: mode, to: destination, toApp: destinationApp,
                        seconds: seconds, repeat: requestedRepeat, interval: interval, holding: holding,
                        button: button, scrollAmount: scrollAmount, app: anchorApp, expect: expect, seen: seen, place: place
                    )
                } }
            }
            guard let anchor else { return Self.withUncertainActionOutcome(await run(steps, nil, nil, nil)) }
            // A miss never touches the screen: the (first) thing to act on is
            // resolved in the background read before anything is raised.
            let missBefore: ([MacActStep], Sighting?) async -> MacFourVerbsReply? = { steps, seen in
                // Every verb is checked before anything is raised.
                for (index, step) in (steps.isEmpty ? [MacActStep(verb: rawVerb, target: target)] : steps).enumerated() {
                    guard let bad = Self.unknownVerb(step.verb, target: step.target) else { continue }
                    guard !steps.isEmpty else { return bad }
                    return MacFourVerbsReply(
                        ok: false, text: "Step \(index + 1): " + bad.text,
                        detail: bad.detail.merging(["failed_step": .int(Int64(index + 1)), "steps_completed": .int(0)]) { _, new in new }
                    )
                }
                guard let seen else { return nil }
                guard !steps.isEmpty else { return await self.missBeforeRaise(verb: rawVerb, target: target, in: seen) }
                // The first step still to do; the kept ones are not looked for.
                guard let at = steps.indices.first(where: { flow?.kept($0) != true }) else { return nil }
                let first = steps[at]
                // An optional first step ("OK?") that isn't here is skipped once
                // raised, like any optional step — it never stops the batch here.
                if first.target.hasSuffix("?"), first.target.count > 1 { return nil }
                guard let miss = await self.missBeforeRaise(verb: first.verb, target: first.target, in: seen) else { return nil }
                let reason = Self.string(miss.detail["error"]) ?? "no_match"
                return MacFourVerbsReply(
                    ok: false,
                    text: Self.keptLine(flow) + "Stopped at step \(at + 1) of \(steps.count) (\(reason)); the rest were not run.\n" + miss.text,
                    detail: miss.detail.merging([
                        "failed_step": .int(Int64(at + 1)), "steps_completed": .int(Int64(at)), "steps_total": .int(Int64(steps.count)),
                    ]) { _, new in new }
                )
            }
            let first = steps.first ?? MacActStep(verb: rawVerb, target: target)
            let menuOrKey = Self.isMenuPath(first.target) || Self.parseVerb(first.verb).0 == "key" || Self.pressMeansKey(first.target)
            var reply = await actBroughtForward(
                app: anchor, seek: steps.first?.target ?? target, menuOrKey: menuOrKey, raise: mayRaise,
                missBefore: { await missBefore(steps, $0) },
                inBack: { await run(steps, anchor, nil, $0) }
            ) { await run(steps, nil, $0, $1) }
            if front, steps.isEmpty, reply.ok {
                // What happened leads; the nudge follows it.
                let lines = reply.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                reply = MacFourVerbsReply(ok: true, text: ([String(lines[0]), Self.oneCallNudge] + lines.dropFirst().map(String.init))
                    .joined(separator: "\n"), detail: reply.detail)
            }
            if !mayRaise, menuOrKey, Self.string(reply.detail["error"]) == "no_window_in_app" {
                let reason = "\(anchor) has no window, so its menu bar or keys need it in front"
                reply = MacFourVerbsReply(
                    ok: false,
                    text: "I need the screen because " + reason + ". Nothing came to the front. "
                        + "Only use front:true when the task explicitly asks to bring \(anchor) forward.\n" + reply.text,
                    detail: reply.detail.merging([
                        "error": .string("needs_front"), "status": .string("needs_front"),
                        "needs_front_reason": .string(reason), "owner_front_changed": .bool(false),
                    ]) { _, new in new }
                )
            }
            // Electron/Chromium: the enhanced-AX flag was only for this act.
            let release = await settlementDispatch(action: "look", body: [
                "app": .string(anchor), "release_enhanced_ax": .bool(true),
            ])
            guard Self.bool(Self.object(release?.output)["enhanced_ax_still_on"]) == true else {
                return Self.withUncertainActionOutcome(reply)
            }
            return Self.withUncertainActionOutcome(MacFourVerbsReply(
                ok: reply.ok,
                text: reply.text + "\n(\(anchor)'s screen-reader accessibility mode did not switch back off; I'll retry next time.)",
                detail: reply.detail.merging(["enhanced_ax_still_on": .bool(true)]) { _, new in new }
            ))
            }
            return await settle {
                let failures = await MacAppMapStore.shared.flush()
                await MacActSerial.shared.release()
                guard !failures.isEmpty else { return acted }
                var detail = acted.detail
                detail["app_map_saved"] = .bool(false)
                detail["app_map_persistence_errors"] = .object(failures.mapValues(JSONValue.string))
                return MacFourVerbsReply(ok: acted.ok,
                    text: acted.text + "\nApp-map changes were not saved: " + failures.keys.sorted().compactMap { failures[$0] }.joined(separator: "; "),
                    detail: detail)
            }
        }()
        var detail = reply.detail
        let elapsed = started.duration(to: .now).components
        detail["duration_ms"] = .int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
    }

    private func actCore(
        verb rawVerb: String,
        target: String,
        text: String?,
        mode: MacTypeMode,
        to destination: String?,
        toApp destinationApp: String?,
        seconds: Double?,
        repeat requestedRepeat: Int?,
        interval: Double?,
        holding: String?,
        button: String?,
        scrollAmount: Int?,
        app: String?,
        expect: FrontExpectation?,
        /// A read already taken of the window for this act (an app behind).
        seen: Sighting?,
        place: MacImagePlace?
    ) async -> MacFourVerbsReply {
        let requestedInput = requestedRepeat ?? 1
        let requested = max(1, requestedInput)
        if place != nil, requested > 1 {
            return MacFourVerbsReply(ok: false,
                text: "A point can't be found again between attempts, so repeat doesn't apply to it. Nothing was sent.",
                detail: ["error": .string("repeat_with_point")])
        }
        let accepted = min(requested, Self.maximumActRepeats)
        let pause = max(0, min(interval ?? 0, Self.maximumActIntervalSeconds))
        let perAttemptBudget = max(0, min(seconds ?? 0, 10)) + pause
        let durationBound = perAttemptBudget > 0
            ? max(1, Int(min(Double(accepted), Self.maximumActBurstSeconds / perAttemptBudget)))
            : Self.maximumActRepeats
        let attempts = min(accepted, durationBound)
        if attempts == 1 {
            let observed = SightCarry()
            let first = SightCarry()
            first.last = seen
            func attempt(_ expected: FrontExpectation?, capture: SightCarry?, carry: SightCarry? = nil) async -> MacFourVerbsReply { await actOnce(
                verb: rawVerb,
                target: target,
                text: text,
                mode: mode,
                to: destination,
                toApp: destinationApp,
                seconds: seconds,
                holding: holding,
                button: button,
                scrollAmount: scrollAmount,
                attention: nil,
                app: app,
                expect: expected,
                carry: carry,
                retrySighting: capture,
                place: place
            ) }
            let reply = await attempt(expect, capture: observed, carry: first)
            let error = Self.string(reply.detail["error"])
            // These exact refusals happen before input is delivered. A second
            // actOnce takes one fresh look and resolves the same name again;
            // it never reuses the old handle or point. Other failures may have
            // acted, so they cannot authorize another dispatch.
            guard !reply.ok, error.map({ ["no_match", "handle_drifted", "window_drifted",
                                         "frame_window_gone", "stale_frame"].contains($0) }) == true,
                  let seen = observed.last, let pid = seen.pid else {
                return reply
            }
            return await attempt((pid, seen.windowFrame ?? expect?.frame), capture: nil)
        }

        let attention: BurstAttention
        switch await beginBurstAttention() {
        case .success(let lease): attention = lease
        case .failure(let message):
            return MacFourVerbsReply(
                ok: false,
                text: "I couldn't start a continuous act safely. \(message)",
                detail: ["error": .string(message.hasPrefix("human_takeover:") ? message : "continuous_attention_unavailable")]
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
                mode: mode,
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

    /// A failed act that may still have acted: input delivered, or an outcome it could not observe.
    static func outcomeUnknown(_ reply: MacFourVerbsReply) -> Bool {
        let status = string(reply.detail["status"])
        let state = string(reply.detail["operationState"])
        return !reply.ok && (inputLeftTheHand(reply)
            || bool(reply.detail["ax_delivered"]) == true
            || bool(reply.detail["outcome_unknown"]) == true
            || status.map({ ["wrong_target", "acted_on_different_target", "acted_mismatch", "acted_unobserved", "outcome_unknown"].contains($0) }) == true
            || state.map({ ["started", "cancel_requested", "outcome_unknown", "timed_out", "failed"].contains($0) }) == true)
    }

    private static func withUncertainActionOutcome(_ reply: MacFourVerbsReply) -> MacFourVerbsReply {
        guard outcomeUnknown(reply) else { return reply }
        let note = "Outcome unknown — inspect the affected app before another action."
        return MacFourVerbsReply(
            ok: false,
            text: reply.text.hasSuffix(note) ? reply.text : reply.text + "\n" + note,
            detail: reply.detail
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
                    return .failure(Self.bool(Self.object(Self.object(status.output)["attention"])["yield_required"]) == true
                        ? MacAttentionSessionStore.driverRefusal
                        : "The existing attention session needs a fresh observation first.")
                }
                return .success(current)
            }
            let started = try await host.dispatch(action: "attention", body: [
                "mode": .string("start"),
                "duration_seconds": .int(Int64(Self.maximumActBurstSeconds)),
            ])
            guard let created = lease(from: started, owned: true) else {
                return .failure(Self.bool(Self.object(Self.object(started.output)["attention"])["yield_required"]) == true
                    ? MacAttentionSessionStore.driverRefusal
                    : "The Mac's bounded human-takeover observer did not become ready.")
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
}

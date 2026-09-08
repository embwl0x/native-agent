import Foundation
import NativeAgentCore
import PersistenceCore

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
        scrollAmount: Int? = nil
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
                attention: nil
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
                attention: attention
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
        attention: BurstAttention?
    ) async -> MacFourVerbsReply {
        let (verbName, parsedDirection) = Self.parseVerb(rawVerb)
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
        if let physical = PhysicalVerb(rawValue: verbName) {
            return await performPhysical(
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
        switch await sight(part: nil) {
        case .blind(let reply): return reply
        case .seen(let hit): sighting = hit
        }

        // b. RESOLVE BY NAME.
        var resolution = verb == .scroll
            ? Self.resolveScrollTarget(target, among: sighting.targets)
            : Self.resolve(target, among: sighting.targets)
        var reobservedAfterTransientMiss = false
        var acquisitionSamples = 0
        if case .none = resolution, Self.isPotentialDynamicVisualReference(target) {
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
        if verb == .click || verb == .open {
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
        switch resolution {
        case .none(let nearest):
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
                    "candidates": .array(listed.map { .string($0) }),
                ]
            )

        case .hit(let candidate):
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
            if verb == .scroll,
               (amount > 0 || direction.isHorizontal || Self.physicalScrollKinds.contains(candidate.kind)),
               amount > 0 || direction.isHorizontal || candidate.kind == "web area" || candidate.frame != nil {
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
                let after = await sight(part: nil)
                var line = "Didn't \(verb.rawValue) \(Self.name(candidate)). " + mechanism
                if case .seen(let hit) = after { line += "\n" + hit.render }
                return MacFourVerbsReply(
                    ok: false,
                    text: line,
                    detail: Self.operationDetail(result).merging([
                        "error": .string(result.error ?? "refused"),
                        "verb": .string(verb.rawValue),
                        "target": .string(target),
                    ]) { current, _ in current }
                )
            }

            var effect = Self.effectWords(output: output, verb: verb, typed: text)
            let after = await sight(part: nil)
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
            var line = (effect.status == "acted"
                ? Self.pastTense(verb, direction: direction)
                : Self.attempted(verb, direction: direction))
                + " " + Self.name(candidate) + ". " + effect.sentence
            if case .seen(let hit) = after { line += "\n" + hit.render }
            var detail = Self.operationDetail(result)
            detail["verb"] = .string(verb.rawValue)
            detail["target"] = .string(target)
            detail["matched"] = .string(Self.name(candidate))
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
            return await performObservedDispatch(
                action: "ax_act",
                body: body,
                description: Self.pastTense(verb, direction: direction) + " " + spokenTarget + ".",
                before: before,
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

    static func keySpec(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in ["key ", "key:", "chord ", "chord:"] where lower.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }


}

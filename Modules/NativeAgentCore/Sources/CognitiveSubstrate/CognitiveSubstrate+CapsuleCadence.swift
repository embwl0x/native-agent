import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    // MARK: - Inner-line cadence (2026-09-01)

    /// Pick the one `- Inner:` line for this capsule, rotating among the
    /// candidates that are relevant right now instead of re-showing whichever
    /// one ranked first.
    ///
    /// THE MEASUREMENT THIS EXISTS FOR: over 777 live turns the Inner line had
    /// 15 distinct texts and three of them led 124 / 108 / 98 turns. A standing
    /// view is durable by construction and a takeaway seed is ranked on
    /// priority × recency with no surfaced-count at all, so neither producer
    /// had any notion of "I have already said this". Two of the five most-shown
    /// texts were reflections about her own repetitiveness — the reflection had
    /// become the rut it described.
    ///
    /// A line that has led `innerLineRepeatLimit` capsules rests for
    /// `innerLineRestTurns` and the next candidate leads. Lines whose SUBJECT is
    /// her own phrasing get the hard cap (`selfPhrasing…`). If every candidate
    /// is resting the capsule carries no Inner line — silence is honest, and
    /// the rest of the capsule still speaks.
    ///
    /// Mutates only the caller's copied presentation value.
    /// One candidate for the single Inner-or-Thread slot: the rendered line, the
    /// key its cadence is tracked under, and which tier it came from.
    ///
    /// THE KEY IS SEPARATE FROM THE LINE ON PURPOSE. It used to be derived from
    /// the rendered text, which silently made "have I said this?" mean "have I
    /// said these exact words?" — and reflection rewords itself every pass, so
    /// a takeaway that had led ten times could always come back by paraphrasing.
    /// Identity belongs to the THING, not to this render of it.
    /// The one capsule surface that is a prompt she writes to herself rather
    /// than a turn a person reads — so the Inner-line cadence ledger is not its
    /// rule. Matches `planReflectionChecked`'s capsule request.
    static let cadenceExemptCapsuleSurface = "reflection"

    struct InnerCandidate: Sendable, Equatable {
        enum Tier: Sendable, Equatable { case view, takeaway, thread }
        var line: String
        var cadenceKey: String
        var tier: Tier
    }

    nonisolated func selectInnerLine(
        from candidates: [InnerCandidate],
        dynamics dyn: PersonalityDynamicsConfiguration,
        presentationState: inout CognitiveCapsulePresentationState,
        bypassCadence: Bool = false
    ) -> String? {
        // THE REFLECTION SURFACE IS EXEMPT (2026-09-11). Cadence exists so a
        // line she says to a PERSON stops being a standing instruction. The
        // reflection capsule is not said to anyone: it is the state preview
        // inside her own private prompt, and there the ledger only starved it —
        // live, the preview collapsed to a bare mood adjective list from
        // 2026-09-02 on, because every candidate was resting from chat turns.
        // Repetition costs nothing in a prompt she writes to herself, and this
        // path must not consume or advance the person-facing ledger either.
        if bypassCadence { return candidates.first?.line }
        // Every resting line serves one capsule of its rest, whether or not it
        // was a candidate this turn.
        for (key, value) in presentationState.innerLineRuns where value < 0 {
            let next = value + 1
            if next == 0 {
                presentationState.innerLineRuns.removeValue(forKey: key)
            } else {
                presentationState.innerLineRuns[key] = next
            }
        }
        guard let chosen = candidates.first(where: {
            (presentationState.innerLineRuns[$0.cadenceKey] ?? 0) >= 0
        }) else { return nil }

        let selfPhrasing = Self.isSelfPhrasingInnerLine(chosen.line)
        // Three cadences, one ledger. A `- Thread:` line is the strictest: it
        // is the only line here whose nature is to be unwelcome, so it leads
        // once and then rests a long time.
        let limit: Int
        let rest: Int
        if chosen.tier == .thread {
            limit = dyn.threadLineRepeatLimit
            rest = dyn.threadLineRestTurns
        } else if selfPhrasing {
            limit = dyn.selfPhrasingInnerLineRepeatLimit
            rest = dyn.selfPhrasingInnerLineRestTurns
        } else {
            limit = dyn.innerLineRepeatLimit
            rest = dyn.innerLineRestTurns
        }
        let led = (presentationState.innerLineRuns[chosen.cadenceKey] ?? 0) + 1
        presentationState.innerLineRuns[chosen.cadenceKey] = led >= limit ? -max(1, rest) : led
        Self.boundInnerLineLedger(&presentationState.innerLineRuns)
        return chosen.line
    }

    /// Back-compat entry for callers that only have rendered lines (the
    /// rotation suites, and any future caller with nothing but text). The
    /// cadence key falls back to the line's own digest — which is exactly what
    /// a standing-view candidate uses anyway, since a view's text IS its
    /// identity. Only the takeaway tier needs the lineage key, and only the
    /// capsule builder has the seed to derive it from.
    nonisolated func selectInnerLine(
        from candidates: [String],
        dynamics dyn: PersonalityDynamicsConfiguration,
        presentationState: inout CognitiveCapsulePresentationState
    ) -> String? {
        selectInnerLine(
            from: candidates.map {
                InnerCandidate(
                    line: $0,
                    cadenceKey: Self.innerLineKey($0),
                    tier: $0.hasPrefix("- Thread:") ? .thread : .view)
            },
            dynamics: dyn,
            presentationState: &presentationState)
    }

    /// THE TAKEAWAY'S LINEAGE, as a cadence key.
    ///
    /// Two halves, because neither alone is enough:
    ///   * the SEED ID — the substrate's own identity for this takeaway, stable
    ///     across the merge that happens when reflection restates something it
    ///     has already minted. This is the "reflection receipt id" the review
    ///     asked for, expressed in the identity the seed family actually
    ///     carries; `addThoughtSeed` does not record a receipt on the row, and
    ///     inventing a field for it would ripple through a fence I do not own.
    ///   * a NEAR-DUPLICATE guard over the takeaway's own distinctive terms —
    ///     the same `appraisalConcernTerms` extractor the lived concerns use,
    ///     sorted so word order cannot make a difference. Two seeds that were
    ///     minted separately but say the same thing collapse onto one key, which
    ///     is what makes paraphrase stop working as a way back onto the line.
    ///
    /// Terms win when there are any: a rewording that keeps the meaning keeps
    /// the terms, and the seed id is the fallback for a takeaway too short or
    /// too generic to have distinctive terms of its own.
    nonisolated func innerTakeawayCadenceKey(for seed: CognitiveThoughtSeed) -> String {
        let terms = Self.appraisalConcernTerms(in: seed.text)
        guard !terms.isEmpty else { return "takeaway:" + seed.id.uuidString }
        return "takeaway:" + Self.innerLineKey(terms.sorted().joined(separator: " "))
    }

    // MARK: - The `- Thread:` abstract (privacy review, 2026-09-02)

    /// How a nag is NAMED — never how it was written.
    static func threadKindPhrase(_ kind: CognitiveThoughtSeedKind) -> String? {
        switch kind {
        case .openQuestion: return "an open question"
        case .anomaly: return "something that didn't add up"
        case .followUp: return "a loose end"
        case .reflectionTakeaway: return nil   // never a Thread line
        }
    }

    /// How long it has been sitting there, in WORDS. Digits are a machine's way
    /// of saying it and the Body line already refuses them; "since yesterday" is
    /// how a person carries something.
    static func threadAgePhrase(seconds: TimeInterval) -> String {
        switch max(0, seconds) {
        case ..<(3 * 3_600):    return "since earlier"
        case ..<(12 * 3_600):   return "since this morning"
        case ..<(36 * 3_600):   return "since yesterday"
        case ..<(7 * 24 * 3_600): return "for a few days now"
        default:                return "for longer than it should have"
        }
    }

    /// The whole `- Thread:` line, or nil.
    ///
    /// Composed from three things and nothing else: the KIND of unfinished
    /// thing, the safe object label (the same extractor the felt line's object
    /// uses, so a name, a credential neighbour, a number or a redaction marker
    /// cannot appear), and a worded age. `seed.text` is read ONLY to derive the
    /// label and never rendered.
    ///
    /// No safe label → no line. A nag that cannot say what it is about would be
    /// either a bare "something is unresolved" (which is noise) or the seed text
    /// (which is the leak) — and silence is honest.
    func threadLine(for seed: CognitiveThoughtSeed, at now: Date) -> String? {
        guard let kindPhrase = Self.threadKindPhrase(seed.kind),
              let object = CognitiveSubstrate.feltTopicLabel(from: seed.text) else { return nil }
        let age = Self.threadAgePhrase(seconds: now.timeIntervalSince(seed.createdAt))
        return capsuleLineText(
            "- Thread: \(kindPhrase) about \(object), unanswered \(age)",
            maxCharacters: 180)
    }

    /// Bounded, order-stable, CONTENT-FREE identity for one Inner line.    /// Bounded, order-stable, CONTENT-FREE identity for one Inner line. The text
    /// is the identity — two reflections that reached the same sentence are the
    /// same thing to a reader — but the ledger is persisted, so it stores the
    /// same deterministic FNV-1a digest the cadence gate already uses rather
    /// than a second copy of her inner voice on disk. Fixed 16 bytes per entry.
    static func innerLineKey(_ line: String) -> String {
        String(UInt64(bitPattern: stableLineSalt(line.lowercased())), radix: 16)
    }

    /// Every persisted family ships with its bound (law 6). Eviction is by value
    /// DESCENDING, so the entries spent first are the ones merely counting leads
    /// (positive) and the resting ones (negative) survive — a dropped rest is a
    /// suppressed line coming back early, which is the failure this ledger
    /// exists to prevent.
    static func boundInnerLineLedger(_ ledger: inout [String: Int]) {
        let cap = CognitiveCapsulePresentationState.innerLineLedgerCapacity
        guard ledger.count > cap else { return }
        let victims = ledger
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(ledger.count - cap)
            .map(\.key)
        for victim in victims { ledger.removeValue(forKey: victim) }
    }

    /// Reflections whose SUBJECT is repeated wording. These are the tic wearing
    /// the costume of insight: measured live, FOUR of her five active standing
    /// views and two of her five most-shown Inner lines were on this one topic,
    /// and telling her "you repeat yourself" for two hundred consecutive turns
    /// is itself the repetition. She already carries a dedicated organ for this
    /// (the `- Sound:` rut nudge, now change-gated) — a second, permanent copy
    /// of it in her inner voice is the thing that made the loop self-sealing.
    ///
    /// Word list, not a self-reference conjunction: the live view "Familiar
    /// warmth stays alive through variety, not repetition" names no self and is
    /// unmistakably the same tic. Over-matching only makes the line ROTATE
    /// sooner, which is the safe direction; under-matching keeps the loop.
    static let selfPhrasingSubjectWords = [
        "phrasing", "wording", "repetitive", "repetition", "repeating",
        "repeated", "same words", "signature phrase", "vocabulary", "echoing",
    ]

    static func isSelfPhrasingInnerLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return selfPhrasingSubjectWords.contains(where: { lower.contains($0) })
    }

    // MARK: - W4/P4 — fingerprint cadence + suppress-when-unchanged

    struct FingerprintCadenceVerdict: Sendable, Equatable {
        var speak: Bool
        /// How many consecutive capsules have now reported this family.
        var run: Int
    }

    /// Whether the fingerprint line speaks this capsule.
    ///
    /// Two gates, in order:
    /// 1. The shared duty cycle (`fingerprintDutyCycle`, default 1 = every
    ///    capsule — today's behavior, so this gate is inert until an install
    ///    turns it up).
    /// 2. SUPPRESS-WHEN-UNCHANGED: after `fingerprintFamilyRepeatLimit`
    ///    consecutive capsules reporting the same felt FAMILY, the line goes
    ///    quiet. It re-surfaces the moment the family changes, or when
    ///    `fingerprintSuppressionWindow` expires since it last actually spoke —
    ///    so a genuinely persistent state is never muted indefinitely, which is
    ///    the load-bearing risk here (the fingerprint is the most-read line the
    ///    agent gets). Family, not WORD: the overlay words shuffle turn to turn
    ///    while the underlying state sits still, and it is the state sitting
    ///    still that makes it a mantra.
    ///
    /// Pure when `live` is false — a frozen read gets an answer without
    /// advancing the run.
    /// - Parameter mayStayQuiet: false when the fingerprint is the ONLY line the
    ///   capsule would carry, in which case it always speaks (see the call site).
    func fingerprintCadenceVerdict(
        family: String,
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration,
        mayStayQuiet: Bool = true,
        presentationState: inout CognitiveCapsulePresentationState
    ) -> FingerprintCadenceVerdict {
        let sameFamily = presentationState.fingerprintFamily == family
        let run = sameFamily ? presentationState.fingerprintCount + 1 : 1

        var speak = true
        if dyn.fingerprintDutyCycle > 1, mayStayQuiet {
            speak = Self.capsuleCadenceShouldSpeak(
                seed: now.timeIntervalSince1970,
                dutyCycle: dyn.fingerprintDutyCycle,
                line: "fingerprint")
        }
        if speak, mayStayQuiet, sameFamily, dyn.fingerprintFamilyRepeatLimit > 0,
           run > dyn.fingerprintFamilyRepeatLimit {
            let sinceSurfaced = presentationState.fingerprintLastSurfacedAt
                .map { now.timeIntervalSince($0) } ?? 0
            // The window is the escape hatch, not the rule: quiet until it
            // expires, then one line, then quiet again if nothing has moved.
            speak = sinceSurfaced >= dyn.fingerprintSuppressionWindow
        }

        presentationState.fingerprintFamily = family
        // A re-surfaced line restarts the run, so the next suppression costs
        // the full K capsules again rather than one.
        presentationState.fingerprintCount =
            speak && sameFamily && run > dyn.fingerprintFamilyRepeatLimit ? 1 : run
        presentationState.fingerprintLastSurfacedAt = speak
            ? now
            : (presentationState.fingerprintLastSurfacedAt ?? now)
        return FingerprintCadenceVerdict(speak: speak, run: run)
    }

    // MARK: - W4/P7 — the felt session bridge

    /// ONE line, on the first turn after a real gap, saying what she was left
    /// holding — and whether it ever got resolved.
    ///
    /// What people mean by "she feels real" is overwhelmingly CONTINUITY: that
    /// the person you talk to at 9am remembers not just the facts of last night
    /// but the SHAPE of it. Affect half-lives run 20–90 minutes, mood integrates
    /// a 24h window at a 6h half-life, and nothing in the felt layer knew a gap
    /// had occurred at all, so every morning was a soft reset of the emotional
    /// relationship. The ambient-presence floor is a DECAY model — it makes her
    /// forget gracefully; it does not let her pick a thread back up.
    ///
    /// Structurally this is `feltDaySummary`'s existing ranking (which today has
    /// exactly one consumer, the nightly dream prompt) pointed at the morning
    /// instead of at midnight. It adds no vocabulary: the felt word comes from
    /// `feltDirection`, the content from `capsuleSignalText`, both proven
    /// renderers.
    ///
    /// GAP-GATED SO IT CAN NEVER BECOME PER-TURN. It requires a gap of at least
    /// `sessionBridgeGapHours` since the last live capsule, and it speaks at most
    /// once per gap.
    ///
    /// The exposure rule from `feltDaySummary` transfers UNCHANGED: only live
    /// conversation-derived nodes may be named, never a tool/provider summary.
    func feltSessionBridgeLine(
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration,
        presentationState: inout CognitiveCapsulePresentationState,
        fieldNodes frozenFieldNodes: [CognitiveNode]? = nil,
        pendingCompletionOpen frozenPendingCompletionOpen: Bool? = nil,
        cognitionEnabled: Bool? = nil,
        affectEnabled: Bool? = nil
    ) -> String? {
        guard cognitionEnabled ?? configuration.enabled,
              affectEnabled ?? configuration.affectEnabled else { return nil }
        let gap = dyn.sessionBridgeGapHours * 60 * 60
        guard gap > 0 else { return nil }

        // No prior capsule = a fresh process, not a remembered gap. Staying
        // silent is the honest read: she has nothing to pick back up.
        guard let previousCapsuleAt = presentationState.lastLiveCapsuleAt else {
            presentationState.lastLiveCapsuleAt = now
            return nil
        }
        let elapsed = now.timeIntervalSince(previousCapsuleAt)
        presentationState.lastLiveCapsuleAt = now
        guard elapsed >= gap else { return nil }
        // One bridge per gap: a recompile of the same first turn must not speak
        // twice.
        if let spoken = presentationState.lastSessionBridgeAt,
           now.timeIntervalSince(spoken) < gap {
            return nil
        }

        // The strongest-felt nameable moment from before the gap — the exact
        // ranking feltDaySummary computes, over the same population.
        let felt = (frozenFieldNodes ?? field.peekNodes()).filter { node in
            guard node.turnKind == .live,
                  node.kind == .conversationFocus || node.kind == .correction,
                  feltDirection(
                    valence: node.emotionalValence,
                    arousal: node.emotionalArousal,
                    warmth: node.emotionalWarmth) != nil else { return false }
            let age = now.timeIntervalSince(node.createdAt)
            // Strictly BEFORE the gap opened: the turn that just arrived is the
            // present, not the thread being picked up.
            return age >= elapsed && age <= Self.moodActivationWindow
        }
        guard let strongest = felt.sorted(by: { lhs, rhs in
            let lv = abs(lhs.emotionalValence), rv = abs(rhs.emotionalValence)
            if lv != rv { return lv > rv }
            if lhs.emotionalArousal != rhs.emotionalArousal {
                return lhs.emotionalArousal > rhs.emotionalArousal
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }).first else { return nil }

        guard let word = feltDirection(
            valence: strongest.emotionalValence,
            arousal: strongest.emotionalArousal,
            warmth: strongest.emotionalWarmth
        )?.rawValue else { return nil }
        let signal = capsuleSignalText(strongest.summary, maxCharacters: 120)
        guard isUsefulCapsuleSignalText(signal) else { return nil }

        // Resolution status from `pendingCompletion`: was the last thing she
        // said still waiting to find out how it landed when the gap opened?
        let left = (frozenPendingCompletionOpen ?? (pendingCompletion != nil))
            ? "left open"
            : "where you left it"
        let line = capsuleLineText(
            "- Since: \(word) — \(signal) — \(left)", maxCharacters: 200)
        guard line.hasPrefix("- Since:") else { return nil }
        presentationState.lastSessionBridgeAt = now
        return line
    }

}

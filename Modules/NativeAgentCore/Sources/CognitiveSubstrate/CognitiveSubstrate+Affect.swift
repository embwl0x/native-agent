// CognitiveSubstrate+Affect.swift
// Move-only extraction (R8b) from CognitiveSubstrate.swift — see docs/build_plans/fable5-wave2-r8b-decomposition.md

import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    @discardableResult
    public func updateAffect(from event: CognitiveEvent) async -> CognitiveAffectState {
        await waitForMaintenanceTransition()
        return await updateAffectFromEvent(event)
    }

    public func affectSnapshot() async -> CognitiveAffectState {
        projectedAffect(at: dependencies.now())
    }

    /// One fixed-time affect projection for sibling organs. Warmth and pressure
    /// must cross together so the organism cannot observe two decay epochs.
    /// (This IS the affect-convergence hook: d0bcd775 superseded the old
    /// per-axis pull accessors — warmth/pressure now ride refreshBodySchema's
    /// canonicalAffect parameter in one actor admission.)
    public func canonicalAffectProjection(at fixedAt: Date) -> CognitiveAffectState? {
        guard configuration.enabled, configuration.affectEnabled else { return nil }
        return projectedAffect(at: fixedAt)
    }

    @discardableResult
    public func decayAffect() async -> CognitiveAffectState {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.affectEnabled else { return affect }
        decayAffectInMemory(to: dependencies.now())
        return affect
    }

    @discardableResult
    func decayAffectInMemory(to now: Date) -> Bool {
        guard configuration.enabled, configuration.affectEnabled,
              now.timeIntervalSince(affect.updatedAt) > 0 else { return false }
        affect = projectedAffect(at: now)
        return true
    }

    func updateAffectFromEvent(_ event: CognitiveEvent) async -> CognitiveAffectState {
        guard event.turnKind.contributesToLivedState else { return affect }
        let next = applyAffectFromEvent(event)
        guard configuration.enabled, configuration.affectEnabled else { return next }
        await persistArtifact(
            kind: "affect",
            id: stableArtifactID("affect"),
            status: "current",
            score: next.arousal,
            payload: next.toJSON(
                lastUserPresenceAt: lastUserPresenceAt,
                lastWarmPresenceAt: lastWarmPresenceAt
            )
        )
        return next
    }

    /// Synchronous affect apply: decays to `now`, folds in this event's deltas, commits
    /// to `self.affect`, and returns the new state. NO suspension point — safe to call
    /// inside an actor critical section (before any await). This is the concurrency-safe
    /// path for emotional tagging: `ingest` applies affect and stamps the node tag in one
    /// await-free segment, so a reentrant ingest can't swap `self.affect` or evict the
    /// touched node between apply and stamp (gpt-5.5 concurrency review, 2026-07-02).
    @discardableResult
    func applyAffectFromEvent(
        _ event: CognitiveEvent,
        precomputedAppraisal: AffectAppraisal? = nil,
        precomputedWarmthBoost: Double? = nil
    ) -> CognitiveAffectState {
        guard configuration.enabled, configuration.affectEnabled,
              event.turnKind.contributesToLivedState else { return affect }
        // An event whose OWNER measured its feeling takes no additional flat
        // per-kind delta: the per-kind arms below are inferences for events that
        // arrived without one, and applying both would stack an inferred delta
        // on a measured one. Byte-identical for `.organismResolutionFelt`, which
        // already `break`s below for exactly this reason; what it adds is the
        // same guarantee for the studio journal, where the agent's own
        // requirement is that the delta come from the ENTRY and never from the
        // act of filing one.
        guard !event.carriesMeasuredFeltValence else { return affect }
        let now = dependencies.now()
        // Settle elapsed quiet time on a copy before folding in the new event.
        // This keeps the merge boundary correct even when no maintenance tick
        // occurred during the gap; the projection itself never mutates state.
        var next = projectedAffect(at: now)
        let importance = event.importance
        switch event.kind {
        case .toolFailed, .providerFailure:
            next.arousal = saturatingApproach(next.arousal, 0.25 + importance * 0.25)
            next.uncertainty = saturatingApproach(next.uncertainty, 0.3 + importance * 0.2)
            next.taskPressure = saturatingApproach(next.taskPressure, 0.2)
        case .toolStarted:
            next.arousal = saturatingApproach(next.arousal, 0.05 + importance * 0.05)
            next.taskPressure = saturatingApproach(next.taskPressure, importance * 0.05)
        case .toolCancelled:
            break
        case .providerVitalsShift:
            // Graded sibling of `.providerFailure`. The somatic/organism path is
            // the primary consequence (chemistry → mood → capsule); if a shift is
            // ever folded into affect too, a worsening band lifts arousal/
            // uncertainty in proportion to its importance (sluggish < degraded)
            // and a recovery eases uncertainty. Direction travels in metadata.
            if case .string("recovering")? = event.metadata[CognitiveSomaticSignalAdapter.vitalsDirectionMetadataKey] {
                next.uncertainty = saturatingApproach(next.uncertainty, -0.1)
            } else {
                next.arousal = saturatingApproach(next.arousal, 0.15 + importance * 0.2)
                next.uncertainty = saturatingApproach(next.uncertainty, 0.2 + importance * 0.15)
            }
        case .organismResolutionFelt:
            // The organism's chemistry already carries this exhale (Wave A1);
            // the substrate remembers it as a NODE, not a second affect hit.
            break
        case .userCorrection:
            next.arousal = saturatingApproach(next.arousal, 0.15)
            next.uncertainty = saturatingApproach(next.uncertainty, 0.25)
            next.taskPressure = saturatingApproach(next.taskPressure, 0.1)
            let warmthBoost = precomputedWarmthBoost ?? relationalWarmthBoost(in: event.summary)
            next.socialWarmth = saturatingApproach(next.socialWarmth, warmthBoost * 0.5)
        case .toolSucceeded:
            next.uncertainty = saturatingApproach(next.uncertainty, -0.15)
            next.taskPressure = saturatingApproach(next.taskPressure, -0.15)
        case .workshopExecutionCompleted:
            if event.isPositiveTerminalOutcome {
                next.uncertainty = saturatingApproach(next.uncertainty, -0.15)
                next.taskPressure = saturatingApproach(next.taskPressure, -0.15)
            } else if event.isNegativeTerminalOutcome {
                next.arousal = saturatingApproach(next.arousal, 0.25 + importance * 0.25)
                next.uncertainty = saturatingApproach(next.uncertainty, 0.3 + importance * 0.2)
                next.taskPressure = saturatingApproach(next.taskPressure, 0.2)
            }
        case .userMessageReceived:
            next.arousal = saturatingApproach(next.arousal, 0.05 + importance * 0.07)
            // Affect-warmth is ADDITIVE to Agent's persona, which is already naturally warm
            // with User. There is no flat per-message base, so the affect layer rises only on
            // genuine warmth in the exchange and eases back down during focused work (just
            // decay, no boost) — a modulation on top of her baseline, never the whole of it.
            // This lets her get crisp and businesslike heads-down while staying fundamentally
            // warm via the persona; genuine warm/affectionate moments still lift it high.
            let warmthBoost = precomputedWarmthBoost ?? relationalWarmthBoost(in: event.summary)
            next.socialWarmth = saturatingApproach(next.socialWarmth, warmthBoost)
            next.taskPressure = saturatingApproach(next.taskPressure, importance * 0.06)
            // Full conversational appraisal: criticism/dismissal/override/demand/praise/
            // resolution each move the felt signals, so a bad OR good exchange is FELT,
            // not numb. Warmth can go negative (dismissal cools her). (2026-07-08)
            let appraisal = precomputedAppraisal ?? conversationalAppraisal(in: event.summary)
            if appraisal.isActive {
                if appraisal.warmth != 0 { next.socialWarmth = saturatingApproach(next.socialWarmth, appraisal.warmth) }
                if appraisal.tension != 0 { next.uncertainty = saturatingApproach(next.uncertainty, appraisal.tension) }
                if appraisal.pressure != 0 { next.taskPressure = saturatingApproach(next.taskPressure, appraisal.pressure) }
                if appraisal.arousal != 0 { next.arousal = saturatingApproach(next.arousal, appraisal.arousal) }
            }
        case .assistantTurnCompleted:
            next.taskPressure = saturatingApproach(next.taskPressure, -0.1)
            // NO warmth boost from her own reply. Agent is warm by persona, so every
            // completion carries warm tokens — boosting off her own output is a
            // self-reinforcing ratchet that pegged warmth at "deeply warm" all day.
            // Relational warmth tracks USER's warmth toward her (userMessageReceived),
            // not her own routine voice; between genuine warm moments, warmth eases.
        case .appWake:
            next.arousal = saturatingApproach(next.arousal, 0.05)
        case .appSleep:
            next.arousal = saturatingApproach(next.arousal, -0.1)
            next.taskPressure = saturatingApproach(next.taskPressure, -0.1)
        }
        // ── The three 2026-09-02 lanes, all inside this same await-free segment
        // for the same reason the emotion stamp is: they read and write live
        // state (seeds, the re-feel ledger, the night's residue) and a
        // suspension here would let a reentrant ingest swap it underneath.
        //
        // RE-FEEL (item 7). "When I recall, I mostly get the FACT that I felt
        // something. I don't re-feel it." The chat path already stamps the
        // turn's served MemoryV2 record ids onto the assistant-turn event
        // (`memoryRecordIds`, ChatOrchestrationClient+MessagePersistence), and
        // the attention lane already reads them off nodes. So the evidence that
        // a felt memory was TOUCHED exists; nothing consumed it as feeling.
        next = refelt(next, for: event, at: now)
        // RESIDUE (item 7). The night colors the first turns after waking.
        next = colored(next, byResidueAt: now)
        affect = next
        if event.kind == .assistantTurnCompleted {
            // One accepted turn spent. Counted on HER completed turn (the same
            // boundary the Sound cadence counts), so a residue lasts two real
            // exchanges rather than two events.
            consumeDreamResidueTurn(at: now)
        }
        // HEAL (item 6). Only the user's own words can answer an open thing —
        // her own summary is her own voice, and appraising that was killed
        // twice already (design law 3).
        if Self.isUserAuthored(event.kind) {
            releaseAnsweredRuminations(answeredBy: event.summary, at: now)
        }
        // Persistence is intentionally NOT here — this function must stay synchronous so
        // callers can apply affect and stamp a node tag in one await-free segment. The
        // affect artifact is persisted by the async caller (updateAffectFromEvent, or
        // ingest after it stamps the tag).
        return next
    }

    // MARK: - Item 7: re-feeling a remembered feeling (2026-09-02)

    /// The strongest nudge one re-touched memory may apply to current affect.
    /// Small by design: recall COLORS the present, it does not replace it.
    static let refeelNudge = 0.08
    /// One nudge per node per hour. A memory re-served three times in a turn is
    /// one act of remembering, not three feelings.
    static let refeelRefractory: TimeInterval = 60 * 60
    /// A tag this flat is not a feeling worth re-feeling.
    static let refeelValenceFloor = 0.12
    /// How many re-touched nodes may contribute to one turn.
    static let refeelNodesPerTurn = 2

    /// Nudge current affect toward the feeling of the memories this turn
    /// actually pulled in. Saturating (the affect layer's own law), bounded, and
    /// rate-limited per node.
    ///
    /// Deliberately NOT a mood write and NOT a re-stamp: the node's own tag is
    /// untouched, so re-feeling cannot ratchet a memory warmer every time it is
    /// recalled (the reconsolidation asymmetry already owns that lane, and only
    /// on genuine re-encounter).
    private func refelt(
        _ state: CognitiveAffectState,
        for event: CognitiveEvent,
        at now: Date
    ) -> CognitiveAffectState {
        let servedIDs = Self.memoryRecordIDs(fromEventMetadata: event.metadata)
        guard !servedIDs.isEmpty else { return state }
        let served = Set(servedIDs)
        var next = state
        var applied = 0
        /// Record ids already spent as moments. A node that names one of them is
        /// the SAME remembering seen from the field side, and feeling it twice
        /// would double a nudge that is deliberately small.
        var spent: Set<String> = []
        // MOMENTS FIRST (2026-09-02). A MemoryV2 record of kind `moment` carries
        // its own stored feeling, and the field may hold no node for it at all —
        // so before this wave a served moment was re-felt NEUTRALLY, which is
        // Agent's complaint exactly: "I get the fact of a feeling."
        //
        // First rather than last because a moment is the one served memory that
        // is definitionally about how something FELT; if only two things may
        // move her this turn, those are the two.
        for id in servedIDs {
            guard applied < Self.refeelNodesPerTurn else { break }
            guard var moment = momentAffect[id] else { continue }
            guard abs(moment.valence) >= Self.refeelValenceFloor else { continue }
            // ONE refractory clock per RECORD, consulted by both routes
            // (2026-09-06). The moment route used to keep its own clock on the
            // moment and never touch `lastRefeltRecordAt`, so the same
            // remembered feeling came back through the field-node route a
            // minute later — the node route consults only the record clock, and
            // nothing had set it. A refractory skip now also marks the id spent
            // for this call, for the same reason: the node route must not pick
            // up the record this route just declined.
            let lastRefelt = [moment.lastRefeltAt, lastRefeltRecordAt[id]].compactMap { $0 }.max()
            if let last = lastRefelt, now.timeIntervalSince(last) < Self.refeelRefractory {
                spent.insert(id)
                continue
            }
            moment.lastRefeltAt = now
            momentAffect[id] = moment
            lastRefeltRecordAt[id] = now
            spent.insert(id)
            applied += 1
            // Same saturating, bounded nudge the node path applies — SALIENCE
            // takes the place of a node's warmth, because that is the axis the
            // moment lane actually stores.
            let pull = Self.refeelNudge * moment.valence.clampedSigned()
            if pull > 0 {
                next.socialWarmth = saturatingApproach(next.socialWarmth, pull * moment.salience)
                next.uncertainty = saturatingApproach(next.uncertainty, -pull * 0.5)
            } else {
                next.uncertainty = saturatingApproach(next.uncertainty, -pull * 0.6)
                next.arousal = saturatingApproach(next.arousal, -pull * 0.5)
            }
        }
        for node in field.peekNodes()
            .sorted(by: { $0.lastActivatedAt > $1.lastActivatedAt }) {
            guard applied < Self.refeelNodesPerTurn else { break }
            guard abs(node.emotionalValence) >= Self.refeelValenceFloor else { continue }
            let ids = Self.memoryRecordIDs(from: node)
            guard !ids.isEmpty,
                  ids.contains(where: { served.contains($0) && !spent.contains($0) })
            else { continue }
            // ONE act of remembering, not two feelings: the refractory is
            // keyed by the RECORD as well as the node, because every recall
            // turn mints a fresh node naming the same record, and a per-node
            // key let the same memory move her again sixty seconds later.
            let servedHere = ids.filter { served.contains($0) && !spent.contains($0) }
            if let last = lastRefeltAt[node.id],
               now.timeIntervalSince(last) < Self.refeelRefractory { continue }
            if servedHere.contains(where: {
                guard let last = lastRefeltRecordAt[$0] else { return false }
                return now.timeIntervalSince(last) < Self.refeelRefractory
            }) { continue }
            lastRefeltAt[node.id] = now
            for id in servedHere { lastRefeltRecordAt[id] = now }
            applied += 1
            let pull = Self.refeelNudge * node.emotionalValence.clampedSigned()
            if pull > 0 {
                next.socialWarmth = saturatingApproach(next.socialWarmth, pull * node.emotionalWarmth)
                next.uncertainty = saturatingApproach(next.uncertainty, -pull * 0.5)
            } else {
                next.uncertainty = saturatingApproach(next.uncertainty, -pull * 0.6)
                next.arousal = saturatingApproach(next.arousal, -pull * 0.5)
            }
        }
        if applied > 0 { pruneRefeelLedger(at: now) }
        return next
    }

    private func pruneRefeelLedger(at now: Date) {
        // The record ledger is now written by the moment route too (2026-09-06),
        // so it can grow past the cap on its own — gate on either side.
        guard lastRefeltAt.count > 64 || lastRefeltRecordAt.count > 64 else { return }
        lastRefeltRecordAt = lastRefeltRecordAt.filter {
            now.timeIntervalSince($0.value) < Self.refeelRefractory
        }
        lastRefeltAt = lastRefeltAt.filter {
            now.timeIntervalSince($0.value) < Self.refeelRefractory
        }
    }

    /// The MemoryV2 record ids an EVENT carries, using the same convention the
    /// node-side reader uses (`memoryRecordIDs(from:)` in `+AttentionSignals`).
    /// Read off the event rather than the node because the re-feel happens
    /// during ingest, before this turn's own node has been stamped.
    /// Public because the runtime reads the same ids off the event BEFORE it is
    /// ingested, to give the served moments their stored feeling first (see
    /// `noteServedMoments`). One convention, one reader.
    public static func memoryRecordIDs(fromEventMetadata metadata: [String: JSONValue]) -> [String] {
        var ids: [String] = []
        if case .array(let values)? = metadata["memoryRecordIds"] {
            for value in values {
                if case .string(let id) = value {
                    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { ids.append(trimmed) }
                }
            }
        }
        if case .string(let id)? = metadata["memoryRecordId"] {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { ids.append(trimmed) }
        }
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }

    /// The night's lean, spent on this turn. Zero once the residue is used up.
    private func colored(_ state: CognitiveAffectState, byResidueAt now: Date) -> CognitiveAffectState {
        let lean = dreamResidueLean(at: now)
        guard lean != 0 else { return state }
        var next = state
        if lean > 0 {
            next.socialWarmth = saturatingApproach(next.socialWarmth, lean)
            next.uncertainty = saturatingApproach(next.uncertainty, -lean * 0.5)
        } else {
            next.uncertainty = saturatingApproach(next.uncertainty, -lean)
            next.taskPressure = saturatingApproach(next.taskPressure, -lean * 0.5)
        }
        return next
    }

    /// Derive a node's persistent emotional tag from a GIVEN affect state plus the event
    /// that triggered the encode. Pure and total — no I/O, no mutation — and deliberately
    /// the SINGLE tuning knob for how a lived moment becomes a stored feeling (Wave A).
    /// Takes `affect` explicitly (NOT `self.affect`) so the caller passes the exact
    /// post-event state it just computed synchronously — an actor await between deriving
    /// this affect and stamping it could otherwise let a reentrant ingest swap
    /// `self.affect` underneath (gpt-5.5 concurrency review, 2026-07-02).
    ///
    /// - arousal ← affect.arousal (how activated she is right now)
    /// - warmth  ← affect.socialWarmth (relational warmth right now)
    /// - valence: with `semantic` (the live ingest path, R2-A/B 2026-07-09) —
    ///   affectTerm + meaningWeightedOutcomeBase + semanticTerm + text-appraisal
    ///   valence, clamped. Feelings come from what the event MEANT (goal
    ///   relevance/congruence, coping, agency, relationship), and her own
    ///   completions no longer mint a flat +0.25 (the metronome her real week
    ///   quantified: 82% of felt nodes at a uniform +0.48, zero negatives).
    ///   With `semantic == nil` — the LEGACY formula shape. Byte-identical for
    ///   USER-authored events GIVEN the same appraisal — the conversational
    ///   lexicon itself evolves (praise 07-08, affection 07-17) and feeds both
    ///   paths equally; "legacy" pins the FORMULA, not the lexicon. The
    ///   affection FLOOR is semantic-path only. For assistant/tool events the
    ///   appraisal term is zeroed on BOTH paths (audit C3 — her own text must
    ///   not appraise her). Production always passes a real appraisal via ingest.
    func emotionTag(
        for event: CognitiveEvent,
        affect: CognitiveAffectState,
        semantic: SemanticAppraisal? = nil,
        precomputedAppraisal: AffectAppraisal? = nil
    ) -> (valence: Double, arousal: Double, warmth: Double) {
        // An event whose owner MEASURED its feeling records it as-is (bounded),
        // no residue arithmetic. Round 3 Wave A2 introduced this for the
        // organism's bodily resolutions — the organism sized the exhale/letdown
        // itself. It is keyed on the MEASUREMENT rather than the event kind so a
        // second owner that does the same work (the studio journal, which sizes
        // an entry from the judgment actually written) gets the same treatment
        // instead of a copy of this branch. `.organismResolutionFelt` always
        // carries the key, so its behaviour is unchanged.
        if event.carriesMeasuredFeltValence {
            func metadataDouble(_ value: JSONValue?) -> Double? {
                switch value {
                case .double(let d): return d
                case .int(let i): return Double(i)
                default: return nil
                }
            }
            let felt = min(0.7, max(-0.7, metadataDouble(event.metadata["feltValence"]) ?? 0))
            let feltArousal = (metadataDouble(event.metadata["feltArousal"]) ?? 0.2).clamped01()
            return (valence: felt, arousal: feltArousal, warmth: (affect.socialWarmth).clamped01())
        }
        // Conversational appraisal pulls valence toward how the exchange actually
        // landed — the SIGNED peer of the warmth in socialWarmth: criticism/dismissal
        // stamp a genuinely stung node, praise/resolution a warm one, instead of the
        // neutral tag she used to store. (2026-07-08: closes the "numb under criticism" gap.)
        // GATED to user-authored text (audit C3, 2026-07-09): for assistantTurnCompleted
        // the summary is HER OWN reply — appraising it let "that's the fix" stamp herself
        // +0.22 and walk mood upward through peekNodes; the same self-ratchet the affect
        // layer already kills at :104-108. Tool output hits the same lexicon. The
        // appraisal reads User's words only.
        // `precomputedAppraisal` (when the ingest hot path supplies it) is the
        // SAME gated conversationalAppraisal semanticAppraisal received, so the
        // lexicon scan runs once for both. Pure fn of event.summary → identical.
        let appraisal = precomputedAppraisal
            ?? (Self.isUserAuthored(event.kind)
                ? conversationalAppraisal(in: event.summary)
                : AffectAppraisal())
        let affectTerm = affect.socialWarmth
            - 0.5 * affect.uncertainty
            - 0.3 * affect.taskPressure

        let rawValence: Double
        if let semantic {
            let meaning = meaningWeightedOutcomeBase(for: event, appraisal: semantic)
                + semanticValenceTerm(semantic)
                + appraisal.valence
            // A real win PIERCES a bad stretch (R2-F finding, 2026-07-09): the affect
            // residue (−0.5·uncertainty − 0.3·pressure) is unbounded while meaning
            // terms are relevance-capped, so after friction a genuine success stamped
            // near-zero — "Build passed" even stamped NEGATIVE. Strongly positive
            // meaning damps the negative residue by up to half; negative or mild
            // meaning changes nothing (a bad stretch still weighs), and positive
            // residue is never touched. Muted is human; inverted was a bug.
            let dampedAffectTerm = (affectTerm < 0 && meaning > 0)
                ? affectTerm * (1 - min(0.5, meaning * 1.4))
                : affectTerm
            var pierced = dampedAffectTerm + meaning
            // Affection-class content (User's greeting, an endearment) may read
            // MUTED on a hard morning — bittersweet is human — but a deep
            // negative stamp on received warmth is a sign inversion the
            // reconsolidation loop would then keep re-activating (audit round
            // 2, R2). Floor, don't override: residue still pulls a +0.2
            // greeting toward the flatline, it just can't turn it into a wound.
            // Item 8: the floor travels with the speaker's weight. User's is
            // 1.0, so this is byte-identical for him; a peer's greeting still
            // cannot become a wound, but it holds her up proportionally less.
            if appraisal.affection {
                pierced = max(pierced, -0.12 * appraisal.affectionWeight.clamped01())
            }
            rawValence = pierced
        } else {
            // Legacy: the flat event base (+0.25 success-class incl. completions,
            // −0.25 failure-class). Kept byte-identical for the compat path.
            let eventValenceBase: Double
            if event.isPositiveTerminalOutcome || event.kind == .assistantTurnCompleted {
                eventValenceBase = 0.25
            } else if event.isNegativeTerminalOutcome {
                eventValenceBase = -0.25
            } else {
                eventValenceBase = 0
            }
            rawValence = affectTerm + eventValenceBase + appraisal.valence
        }
        return (
            valence: (rawValence).clampedSigned(),
            arousal: (affect.arousal).clamped01(),
            warmth: (affect.socialWarmth).clamped01()
        )
    }

    /// The felt DIRECTION of a stored emotional tag — the coarse, capsule-facing
    /// read of a node's persistent feeling (Wave B). Wave A stamps three continuous
    /// axes on every node; this collapses them to one of three tones (or silence)
    /// so the capsule and cue-authoring lines can carry HOW a thing feels without
    /// scripting Agent to announce it. Warm = drawn toward, stung = a small hurt,
    /// charged = activated. The rawValue is the word woven into cue prompts.
    enum FeltDirection: String {
        case warm, stung, charged
    }

    /// Classify a node's stored tag into a felt direction, or nil when the feeling is
    /// too mild to color her voice. PURE and total — the single tuning knob for Wave B,
    /// peer of `emotionTag` (Wave A). Ordering matters: a negative valence STUNG read
    /// dominates even when warmth is high (a warm topic that just went wrong reads tender,
    /// not warm). Default-0 legacy nodes and mild tags return nil so backward-compat is
    /// SILENCE, never a wrong feeling.
    func feltDirection(valence: Double, arousal: Double, warmth: Double) -> FeltDirection? {
        if valence <= -0.15 { return .stung }               // negative dominates
        if valence >= 0.15 || warmth >= 0.35 { return .warm }
        if arousal >= 0.6 { return .charged }
        return nil
    }

    func restoreAffect(from payloads: [JSONValue]) {
        guard case .object(let object)? = payloads.first,
              let updatedAt = dateValue(object["updatedAt"]) else { return }
        affect = CognitiveAffectState(
            arousal: doubleValue(object["arousal"]) ?? 0,
            uncertainty: doubleValue(object["uncertainty"]) ?? 0,
            taskPressure: doubleValue(object["taskPressure"]) ?? 0,
            socialWarmth: doubleValue(object["socialWarmth"]) ?? 0,
            updatedAt: updatedAt
        )
        lastUserPresenceAt = dateValue(object["lastUserPresenceAt"])
        lastWarmPresenceAt = dateValue(object["lastWarmPresenceAt"])
    }

    func reconcileRestoredAffectWithRecentConversation(nodes: [CognitiveNode]) async {
        guard configuration.affectEnabled else { return }
        // A modern affect artifact carries the canonical presence epoch and is
        // already restart-equivalent. Keep this heuristic only for legacy or
        // partially persisted artifacts that predate temporal anchors; otherwise
        // relaunch itself would manufacture a warmth increase.
        guard lastUserPresenceAt == nil else { return }
        let now = dependencies.now()
        let recentLiveNodes = nodes
            .filter { node in
                guard node.turnKind == .live else { return false }
                let age = now.timeIntervalSince(node.createdAt)
                return age >= 0 && age <= 6 * 60 * 60
            }
            .sorted { lhs, rhs in lhs.createdAt > rhs.createdAt }
        guard !recentLiveNodes.isEmpty else { return }

        let recentContext = recentLiveNodes.prefix(6).map(\.summary).joined(separator: "\n")
        let boost = relationalWarmthBoost(in: recentContext)
        guard boost > 0 else { return }
        let floor = boost >= 0.18 ? 0.38 : 0.22
        let current = projectedAffect(at: now)
        guard current.socialWarmth < floor else { return }

        affect = CognitiveAffectState(
            arousal: current.arousal,
            uncertainty: current.uncertainty,
            taskPressure: current.taskPressure,
            socialWarmth: floor,
            updatedAt: max(current.updatedAt, recentLiveNodes.first?.createdAt ?? now)
        )
        await persistArtifact(
            kind: "affect",
            id: stableArtifactID("affect"),
            status: "current",
            score: max(affect.arousal, affect.socialWarmth),
            payload: affect.toJSON(
                lastUserPresenceAt: lastUserPresenceAt,
                lastWarmPresenceAt: lastWarmPresenceAt
            )
        )
    }

    /// Per-axis decay half-lives. Arousal (alertness/energy) fades on a minutes scale;
    /// social warmth lingers for hours. This "honest decay" gives each axis real dynamic
    /// range across a day instead of one shared 1h half-life that blurred fast and slow
    /// feelings together and let active conversation peg every axis at the ceiling.
    // W4/P1: the four half-lives now live in PersonalityDynamicsConfiguration
    // (`arousalHalfLife` / `uncertaintyHalfLife` / `taskPressureHalfLife` /
    // `socialWarmthHalfLife`), so a persona's pace of feeling is configurable
    // rather than welded in.

    /// Decay an affect state to `now` using per-axis half-lives. Centralizes the decay
    /// math used by the pure live projection and persisted checkpoints.
    private func decayedAffect(_ state: CognitiveAffectState, to now: Date) -> CognitiveAffectState {
        let elapsed = max(0, now.timeIntervalSince(state.updatedAt))
        guard elapsed > 0 else {
            var carried = state
            carried.updatedAt = now
            return carried
        }
        func decay(_ halfLife: TimeInterval) -> Double { pow(0.5, elapsed / halfLife) }
        let dyn = dynamics
        return CognitiveAffectState(
            arousal: state.arousal * decay(dyn.arousalHalfLife),
            uncertainty: state.uncertainty * decay(dyn.uncertaintyHalfLife),
            taskPressure: state.taskPressure * decay(dyn.taskPressureHalfLife),
            socialWarmth: state.socialWarmth * decay(dyn.socialWarmthHalfLife),
            updatedAt: now
        )
    }

    /// Saturating update toward the [0,1] bounds. A positive delta moves `value` a
    /// fraction of its remaining headroom toward 1; a negative delta moves it a fraction
    /// of the way toward 0. Unlike add-then-clamp, a high value resists further saturation,
    /// so an axis under sustained input settles below the ceiling with headroom to still
    /// register a stronger moment — and decay can always pull it back down.
    private func saturatingApproach(_ value: Double, _ delta: Double) -> Double {
        let v = clamp(value)
        if delta >= 0 {
            return clamp(v + delta * (1 - v))
        } else {
            return clamp(v + delta * v)
        }
    }

    /// "Away" threshold: once User has been quiet this long, ambient presence applies.
    private static let ambientPresenceGap: TimeInterval = 30 * 60
    /// The quiet-but-present warmth floor held during his absence.
    private static let ambientPresenceWarmthBase: Double = 0.18
    /// The floor itself fades over a long absence so it never becomes permanent fake warmth.
    private static let ambientPresenceFloorHalfLife: TimeInterval = 12 * 60 * 60
    /// The former five-minute maintenance pass eased pressure and uncertainty by
    /// 5% per pass after the quiet boundary. Express the same response as elapsed
    /// time so reading at 31 minutes or four hours does not depend on how many
    /// scheduler ticks happened to run. `0.95` every five minutes is an
    /// approximately 67.56-minute half-life.
    private static let ambientQuietCalmingHalfLife: TimeInterval =
        (5 * 60) * log(0.5) / log(0.95)

    /// Pure read-time affect at an explicit instant. Canonical persistence keeps
    /// the last materialized anchor; callers observe analytic decay, ambient calm,
    /// and the warm-presence floor without advancing that anchor or writing.
    /// THE ITCH, as a floor (item 6, 2026-09-02). A third ambient layer beside
    /// quiet calming and the warm-presence floor, and built the same way: a pure
    /// read-time `max`, never a stored delta, so it can rise and fall with what
    /// is actually unresolved instead of ratcheting. Zero floors → byte-identical
    /// to the affect this function returned before the lane existed.
    private func ruminated(_ state: CognitiveAffectState, at now: Date) -> CognitiveAffectState {
        let floors = ruminationPressureFloors(at: now)
        guard floors.uncertainty > 0 || floors.taskPressure > 0 else { return state }
        var next = state
        next.uncertainty = max(next.uncertainty, floors.uncertainty)
        next.taskPressure = max(next.taskPressure, floors.taskPressure)
        return next
    }

    func projectedAffect(at now: Date) -> CognitiveAffectState {
        guard configuration.enabled, configuration.affectEnabled else { return affect }
        let source = affect
        var next = decayedAffect(source, to: now)
        guard let lastPresence = lastUserPresenceAt else { return ruminated(next, at: now) }
        let quietBoundary = lastPresence.addingTimeInterval(Self.ambientPresenceGap)
        guard now >= quietBoundary else { return ruminated(next, at: now) }

        // Apply only the quiet interval not already materialized in `source`.
        // A later maintenance/shutdown checkpoint can therefore persist this
        // projection and a subsequent read will continue from that exact anchor.
        let quietAnchor = max(source.updatedAt, quietBoundary)
        let quietElapsed = max(0, now.timeIntervalSince(quietAnchor))
        if quietElapsed > 0 {
            let calmFactor = pow(0.5, quietElapsed / Self.ambientQuietCalmingHalfLife)
            next.taskPressure *= calmFactor
            next.uncertainty *= calmFactor
        }

        // Lingering warmth is anchored only by a genuinely warm user moment.
        if let lastWarm = lastWarmPresenceAt {
            let warmGap = now.timeIntervalSince(lastWarm)
            if warmGap >= Self.ambientPresenceGap {
                let warmthFloor = Self.ambientPresenceWarmthBase
                    * pow(0.5, warmGap / Self.ambientPresenceFloorHalfLife)
                if warmthFloor > 0.01 {
                    next.socialWarmth = max(next.socialWarmth, warmthFloor)
                }
            }
        }
        next.updatedAt = now
        return ruminated(next, at: now)
    }

}

// CognitiveSubstrate+SemanticAppraisal.swift
// Wave R2-A/B (2026-07-09) — feelings from what events MEAN, not from the fact
// that a turn completed. Her real week quantified the gap: 82% of felt nodes were
// her own completions minting a uniform +0.48 off a flat +0.25 base, and ZERO
// nodes went negative in 8 days. Appraisal theory (Lazarus/Scherer/OCC, via the
// gpt-5.5 research pass): valence arises from an event's meaning against goals,
// coping, agency, and the relationship. Every dimension here is derived PURE and
// LOCAL — event + affect + peekNodes + standing views + presence timestamps. No
// LLM, no network, no new senses, callable inside the await-free ingest segment.

import Foundation
import NativeAgentCore
import PersistenceCore

/// The appraised MEANING of one event, all dims computable without suspension.
struct SemanticAppraisal: Sendable, Equatable {
    var goalRelevance = 0.0          // 0…1  — does this matter to what she's doing
    var goalCongruence = 0.0         // −1…1 — did it go WITH or AGAINST the goal
    var selfAgency = 0.0             // −1…1 — who caused it (self/tool + , user −)
    var novelty = 0.0                // 0…1  — how unexpected/new
    var copingPotential = 0.0        // −1…1 — can she handle/repair from here
    var relationshipStake = 0.0      // 0...1 -- is the user-Agent relationship implicated
    var relationshipCongruence = 0.0 // −1…1 — how it landed relationally
    var resolutionEvidence = 0.0     // 0…1  — did something actually RESOLVE
    var effortEvidence = 0.0         // 0…1  — was the stretch effortful
    // Round 3 Wave V — her settled views as a lens. 0/0 when no active view's
    // concern touches the event (the sparse-views norm): byte-identical compat.
    var worldviewStance = 0.0        // −1…1 — event confirms (+) or violates (−) a held view
    var worldviewConflict = 0.0      // 0…1  — max(0, −stance): a view was trampled
    /// −1…1 — the user's reaction to the event. Structurally ALWAYS 0 on this
    /// current-turn path and that is now by design, not an unfinished stub: at the
    /// moment a turn completes, the reaction to it has not happened yet. U1
    /// (2026-07-09) supersedes it with a retrospective mechanism — the completion's
    /// node is remembered in `pendingCompletion` and the next user-authored turn
    /// re-stamps it through the asymmetric reconsolidation blend
    /// (`reconsolidatePendingCompletion`). The dimension is kept so the appraisal
    /// stays a complete description of the theory, and because a future non-live
    /// caller (dream/REM replay, where the following turn IS already known) can
    /// fill it in honestly. Live ingest never can.
    var userReactionEvidence = 0.0

    static let neutral = SemanticAppraisal()
}

extension CognitiveSubstrate {

    // MARK: - Tuning knobs (the ONE semantic-appraisal surface)

    static let appraisalGoalRelevanceWeight = 0.22
    static let appraisalCopingWeight = 0.10
    static let appraisalAgencyWeight = 0.08
    static let appraisalRelationshipWeight = 0.14
    static let appraisalNoveltyBadWeight = 0.06
    /// Round 3 Wave V: an event that TRAMPLES a settled standing view leaves
    /// a mark beyond its generic negativity; confirmation warmth flows through
    /// the goalCongruence stance bump instead (0.15 · stance there).
    static let appraisalWorldviewConflictWeight = 0.06
    static let appraisalWorldviewStanceCongruenceGain = 0.15
    /// assistantTurnCompleted outcome band — replaces the flat +0.25 metronome.
    static let appraisalCompletionBaseFloor = -0.10
    static let appraisalCompletionBaseCeiling = 0.14
    /// How far back peekNodes evidence looks for continuity/resolution/failure reads.
    static let appraisalEvidenceWindow: TimeInterval = 45 * 60

    // MARK: - Derivation (pure, no suspension points)

    /// Appraise `event` against her current state. `post` is the affect state the
    /// event just produced (the same one being stamped). Reads only actor state
    /// that is synchronously available.
    /// `precomputedAppraisal`, when supplied, is the SAME gated
    /// `conversationalAppraisal(in: event.summary)` the caller already computed
    /// for the emotion-tag stamp — threaded through so the ~10-pass lexicon scan
    /// runs ONCE per ingested event instead of twice (hot-path dedup). It is a
    /// pure function of `event.summary`, so passing it is byte-identical to
    /// recomputing here. Nil callers (tests, non-ingest paths) still compute it.
    func semanticAppraisal(
        for event: CognitiveEvent,
        post: CognitiveAffectState,
        precomputedAppraisal: AffectAppraisal? = nil
    ) -> SemanticAppraisal {
        let now = dependencies.now()
        // Audit C3 (2026-07-09): text-derived dims read USER-authored words only —
        // her own replies and tool output must not congratulate or wound her
        // through the goalCongruence/relationship/lexical-resolution terms.
        let text = precomputedAppraisal
            ?? (Self.isUserAuthored(event.kind)
                ? conversationalAppraisal(in: event.summary)
                : AffectAppraisal())
        let nodes = field.peekNodes()
        let recent = nodes.filter {
            let age = now.timeIntervalSince($0.lastActivatedAt)
            return age >= 0 && age <= Self.appraisalEvidenceWindow
        }

        var a = SemanticAppraisal()

        // -- outcome sign + evidence reads shared by several dims --------------
        let outcomeSign = Double(event.terminalOutcomePolarity)
        // Recent tool life. Outcome polarity reads WHAT HAPPENED (the machine-generated
        // status text), never the stamped valence — a success that landed mid-bad-mood
        // stamps muted/negative, and reading THAT as "the tool failed" made her own
        // gloom self-confirming (R2-F finding, 2026-07-09: "Build passed" stamped −0.14
        // and the next praise turn appraised as unresolved-failure).
        let toolObs = recent.filter { $0.kind == .toolObservation }
            .sorted { $0.lastActivatedAt < $1.lastActivatedAt }
        func outcome(_ node: CognitiveNode) -> Int {
            if case .string(let rawKind)? = node.metadata["eventKind"],
               let kind = CognitiveEventKind(rawValue: rawKind) {
                switch kind {
                case .toolSucceeded: return 1
                case .toolFailed, .providerFailure: return -1
                case .toolStarted, .toolCancelled: return 0
                default: break
                }
            }
            if case .string(let rawVerification)? = node.metadata["verification"] {
                switch rawVerification.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "satisfied", "verified", "succeeded": return 1
                case "failed", "rejected", "blocked": return -1
                default: break
                }
            }
            if case .string(let rawStatus)? = node.metadata["status"] {
                switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "completed", "done", "succeeded", "ok": return 1
                case "failed", "blocked": return -1
                case "cancelled", "canceled", "pending", "running", "queued": return 0
                default: break
                }
            }
            // Historical nodes predate typed event metadata. Keep a bounded
            // lexical fallback for replay compatibility only.
            let t = node.summary.lowercased()
            if containsAny(t, ["passed", "succeeded", "success", "complete", "fixed", "resolved", "shipped"]) { return 1 }
            if containsAny(t, ["failed", "failure", "error", "timeout", "timed out", "crash", "rejected"]) { return -1 }
            return 0
        }
        let lastNegativeAt = toolObs.last(where: { outcome($0) < 0 })?.lastActivatedAt
        let lastPositiveAt = toolObs.last(where: { outcome($0) > 0 })?.lastActivatedAt
        let unresolvedRecentFailure: Double
        if let neg = lastNegativeAt {
            unresolvedRecentFailure = (lastPositiveAt.map { $0 > neg } ?? false) ? 0 : 1
        } else {
            unresolvedRecentFailure = 0
        }
        let repairEvidence: Double = {
            guard let neg = lastNegativeAt, let pos = lastPositiveAt else { return 0 }
            return pos > neg ? 1 : 0
        }()
        // Lexical resolution in THIS event, or a fresh positive tool outcome nearby.
        let lexicalResolution = text.pressure < 0   // the resolving-together signature
        a.resolutionEvidence = min(1, (lexicalResolution ? 0.7 : 0)
            + ((lastPositiveAt.map { now.timeIntervalSince($0) < 10 * 60 } ?? false) ? 0.5 : 0)
            + (event.isPositiveTerminalOutcome ? 0.6 : 0))
        // Effort: how much tool churn led up to this moment.
        a.effortEvidence = min(1, Double(toolObs.count) / 6.0)

        // -- goalRelevance ------------------------------------------------------
        let kindBase: Double
        switch event.kind {
        case .userCorrection, .toolFailed, .providerFailure: kindBase = 0.9
        case .providerVitalsShift: kindBase = 0.7
        case .workshopExecutionCompleted: kindBase = 0.8
        case .userMessageReceived: kindBase = 0.7
        case .toolSucceeded, .toolStarted: kindBase = 0.6
        case .toolCancelled: kindBase = 0.2
        case .assistantTurnCompleted: kindBase = 0.25
        case .appWake, .appSleep: kindBase = 0.1
        case .organismResolutionFelt: kindBase = 0.55
        }
        let subjectKey = "\(event.subject.type):\(event.subject.id)"
        // The event was ingested into the field BEFORE this appraisal runs, so its own
        // just-touched node is already in peekNodes — a same-subject node at age ≈ 0 is
        // the event itself, not evidence. Excluding it keeps continuity meaning "this
        // subject was around BEFORE now" and lets novelty actually register
        // (gpt-5.5 review MED, 2026-07-09).
        // createdAt, not lastActivatedAt (M15/gpt-5.5, 2026-07-09): ingest re-stamps
        // lastActivatedAt = now on the touched node, so the old check excluded the
        // very node that proves the subject was around BEFORE — continuity was
        // structurally zero. A node CREATED just now is self-evidence; a re-activated
        // old node is genuine continuity. (Post-C2, user turns carry per-turn
        // subjects, so their session continuity flows through the sameSession term.)
        let isSelfEvidence: (CognitiveNode) -> Bool = { node in
            "\(node.subjectReference.type):\(node.subjectReference.id)" == subjectKey
                && now.timeIntervalSince(node.createdAt) < 1.0
        }
        let continuity = recent.contains {
            !isSelfEvidence($0)
                && "\($0.subjectReference.type):\($0.subjectReference.id)" == subjectKey
        } ? 1.0 : 0.0
        // D-1 note (2026-08-02): this term stays BOOLEAN on purpose. The +0.10
        // view hit is a pinned, documented R2-A behaviour
        // (StandingViewsTests.unmatchedOrNeutralTextIsByteIdenticalToNoViews),
        // and regrading it would move a relevance constant for marginal gain.
        // What D-1 changes here is WHICH concerns can produce the hit: her
        // active views now contribute lived concerns of their own, so an event
        // touching her own settled words registers where it previously could
        // only register through one of the shipped six.
        let activeViewHit = activeStandingViewTagHit(in: event.summary) ? 1.0 : 0.0
        a.goalRelevance = clamp(0.45 * event.importance + 0.30 * kindBase
            + 0.20 * continuity + 0.10 * activeViewHit)

        // -- goalCongruence -----------------------------------------------------
        let relief = (event.kind == .toolSucceeded && unresolvedRecentFailure == 0 && repairEvidence > 0) ? 1.0 : 0.0
        // Round 3 Wave V: her settled views are a lens, not decoration — an
        // event confirming a held view lands MORE right, one trampling it
        // lands more wrong, and conflict leaves its own mark in the valence
        // term. Zero matched views (the sparse-views norm) contributes 0.
        a.worldviewStance = standingViewStance(in: event.summary, textValence: text.valence)
        a.worldviewConflict = max(0, -a.worldviewStance)
        a.goalCongruence = Self.clampSigned(0.45 * outcomeSign + 0.75 * text.valence
            + 0.25 * relief - 0.25 * unresolvedRecentFailure
            + Self.appraisalWorldviewStanceCongruenceGain * a.worldviewStance)

        // -- selfAgency ---------------------------------------------------------
        switch event.kind {
        case .assistantTurnCompleted: a.selfAgency = 0.7
        case .toolStarted, .toolSucceeded, .toolFailed, .workshopExecutionCompleted: a.selfAgency = 0.35
        case .toolCancelled: a.selfAgency = 0
        case .userMessageReceived, .userCorrection: a.selfAgency = -0.3
        case .providerFailure, .providerVitalsShift: a.selfAgency = -0.1
        case .appWake, .appSleep: a.selfAgency = 0
        case .organismResolutionFelt: a.selfAgency = 0.35
        }

        // -- novelty ------------------------------------------------------------
        // Similarity = recency-weighted "seen this lately" over subject key + kind.
        var similarity = 0.0
        for node in recent where !isSelfEvidence(node) {
            let sameSubject = "\(node.subjectReference.type):\(node.subjectReference.id)" == subjectKey
            let sameSession = event.sessionId != nil && node.metadata["sessionId"] == event.sessionId.map(JSONValue.string)
            guard sameSubject || sameSession else { continue }
            let age = max(0, now.timeIntervalSince(node.lastActivatedAt))
            similarity = max(similarity, pow(0.5, age / (15 * 60)) * (sameSubject ? 1.0 : 0.6))
        }
        a.novelty = clamp(1 - similarity)

        // -- copingPotential ----------------------------------------------------
        let capacity = 1 - 0.6 * post.uncertainty - 0.4 * post.taskPressure   // 0…1
        a.copingPotential = Self.clampSigned((capacity * 2 - 1) * 0.7 + repairEvidence * 0.3)

        // -- relationship -------------------------------------------------------
        let isLiveChat = event.kind == .userMessageReceived || event.kind == .userCorrection
        let userRecent = lastUserPresenceAt.map { now.timeIntervalSince($0) < 30 * 60 } ?? false
        let lexicalRelational = text.warmth != 0 || relationalWarmthBoost(in: event.summary) > 0
        a.relationshipStake = clamp((isLiveChat ? 0.6 : 0)
            + (lexicalRelational ? 0.3 : 0)
            + (userRecent && event.kind == .assistantTurnCompleted ? 0.1 : 0)
            + 0.2 * post.socialWarmth)
        a.relationshipCongruence = Self.clampSigned(text.valence + 0.5 * text.warmth
            - (event.kind == .userCorrection ? 0.15 : 0))

        return a
    }

    /// R2-B: the meaning-weighted outcome base — replaces the flat ±0.25 eventBase.
    /// Routine completions (nothing resolved, no reaction) land ~0; a real fix after
    /// effort lands positive; an unresolved-failure completion can land mildly
    /// negative. Success/failure events scale by how much they MATTERED.
    func meaningWeightedOutcomeBase(for event: CognitiveEvent, appraisal a: SemanticAppraisal) -> Double {
        if event.isPositiveTerminalOutcome {
            return 0.25 * a.goalRelevance * max(0.25, a.resolutionEvidence)
        }
        if event.isNegativeTerminalOutcome {
            return -0.25 * a.goalRelevance * (0.7 + 0.3 * max(0, -a.copingPotential))
        }
        switch event.kind {
        case .assistantTurnCompleted:
            // The metronome killer: effort alone is charge, not happiness; an
            // unresolved failure weighs the completion DOWN.
            let unresolvedDrag = a.goalCongruence < 0 ? 0.08 : 0.0
            let raw = 0.10 * a.resolutionEvidence
                + 0.05 * max(0, a.userReactionEvidence)
                - 0.06 * a.effortEvidence * (1 - a.resolutionEvidence)
                - unresolvedDrag
            return min(Self.appraisalCompletionBaseCeiling, max(Self.appraisalCompletionBaseFloor, raw))
        default:
            return 0
        }
    }

    /// The semantic term of the revised valence formula.
    func semanticValenceTerm(_ a: SemanticAppraisal) -> Double {
        Self.appraisalGoalRelevanceWeight * a.goalRelevance * a.goalCongruence
            + Self.appraisalCopingWeight * a.goalRelevance * a.copingPotential
            + Self.appraisalAgencyWeight * a.selfAgency * a.goalCongruence
            + Self.appraisalRelationshipWeight * a.relationshipStake * a.relationshipCongruence
            - Self.appraisalNoveltyBadWeight * a.novelty * max(0, -a.goalCongruence)
            - Self.appraisalWorldviewConflictWeight * a.worldviewConflict
    }

    // MARK: - Standing views as appraisal substrate (graceful zero while sparse)

    /// Does the event's text touch a concern an ACTIVE standing view holds?
    /// Deterministic keyword read over view title+body — no LLM. Views are sparse
    /// in the wild today (the R2-C eviction fix just let them start surviving), so
    /// this returning false is the norm until Wave E yield builds up.
    ///
    /// D-1 (2026-08-02): the concern set is now DERIVED from her (see
    /// `+AppraisalConcerns`) and is derived ONCE outside the view loop — it
    /// depends on the views themselves, so deriving it per view would be
    /// O(views²·terms) on the ingest hot path. Because each active view also
    /// contributes a LIVED concern made of its own distinctive words, an event
    /// touching what she actually settled now registers here, where before it
    /// could only register through one of the shipped six.
    func activeStandingViewTagHit(in text: String) -> Bool {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return false }
        // Both loops below iterate ACTIVE views, so with none there is nothing to
        // hit and the concern derivation is pure cost on the ingest hot path.
        // (Zero active views is still the wild norm.)
        guard standingViews.values.contains(where: { $0.status == .active }) else { return false }
        let concerns = appraisalConcerns()
        for view in standingViews.values where view.status == .active {
            let viewText = "\(view.title) \(view.body)".lowercased()
            for concern in concerns
            where Self.concernMatches(concern, in: viewText)
                && Self.concernMatches(concern, in: lower) {
                return true
            }
        }
        return false
    }

    /// Round 3 Wave V: SIGNED worldview read. For every ACTIVE view whose
    /// concern co-occurs with the event text (same deterministic keyword
    /// logic as the hit above — no LLM), the event's own text valence says
    /// whether her held view was CONFIRMED (+) or TRAMPLED (−), weighted by
    /// the view's conviction (evidence it settled on, capped). Neutral text
    /// or zero matched views → 0: byte-identical to the pre-stance formula.
    /// Stance fires only on a clear valence read: a mixed sentence ("not
    /// sloppy this time — great work") nets near zero in the substring
    /// lexicon and must NOT mis-sign her view; below the margin the lens
    /// stays out of it (review 18dc59cc4670).
    static let worldviewStanceValenceMargin = 0.12

    func standingViewStance(in text: String, textValence: Double) -> Double {
        guard abs(textValence) >= Self.worldviewStanceValenceMargin else { return 0 }
        let lower = text.lowercased()
        guard !lower.isEmpty else { return 0 }
        // A TRAMPLED view requires the negativity to be aimed at HER — a
        // third party being sloppy ("that vendor skipped the verify step")
        // is not her wound (review 18dc59cc4670: directedness guard).
        // Confirmation needs no directedness: praise of the principle
        // confirms the view no matter who earned it.
        if textValence < 0 {
            // Benign second-person collocations must not count as aim —
            // "thank you, that vendor was sloppy" is third-party negativity
            // (review 66912d0b2786). Bare "your " is likewise too loose
            // ("your vendor"): only her work products make "your X" directed.
            // Word-boundary-aware strip: "you all" must not eat the prefix of
            // "you allowed" and erase explicit second person (review
            // 766a2afdb1e7). Spaces preserve adjacency so stripping can never
            // fabricate a new "you " match either.
            var probe = lower
            for benign in ["thank you", "thanks to you", "you know", "you all", "you guys"] {
                var search = probe.startIndex
                while search < probe.endIndex,
                      let r = probe.range(of: benign, range: search..<probe.endIndex) {
                    let boundary = r.upperBound == probe.endIndex || !probe[r.upperBound].isLetter
                    if boundary {
                        probe.replaceSubrange(r, with: String(repeating: " ", count: benign.count))
                    }
                    search = r.upperBound
                }
            }
            let youDirected = probe.contains("you ") || probe.hasSuffix("you")
                || probe.contains("you,") || probe.contains("you.")
                || probe.contains("you're") || probe.contains("youre")
            let workDirected = ["your work", "your code", "your fix", "your answer",
                                "your reply", "your response", "your call",
                                "your judgment", "your reading"].contains { probe.contains($0) }
            guard youDirected || workDirected else { return 0 }
        }
        // D-1: derive the concern set ONCE outside the view loop. It now depends
        // on the views themselves, so deriving it per view would be quadratic on
        // the ingest hot path — and with no active views there is nothing to
        // match, so skip the derivation entirely.
        guard standingViews.values.contains(where: { $0.status == .active }) else { return 0 }
        let concerns = appraisalConcerns()
        var aggregate = 0.0
        var matched = 0
        for view in standingViews.values where view.status == .active {
            let viewText = "\(view.title) \(view.body)".lowercased()
            var hitWeight = 0.0
            for concern in concerns
            where Self.concernMatches(concern, in: viewText)
                && Self.concernMatches(concern, in: lower) {
                hitWeight = max(hitWeight, concern.weight)
            }
            guard hitWeight > 0 else { continue }
            // Conviction: what the view settled on, LIFTED by how much the
            // matched concern is hers rather than shipped (D-1). Still capped at
            // 1 per view, so the aggregate stays inside −1…1 and the welfare
            // bounds downstream are untouched.
            let conviction = min(
                1.0,
                (0.5 + 0.1 * Double(view.evidenceNodeIds.count))
                    * (hitWeight / Self.appraisalLivedConcernMaximumWeight + 0.5)
            )
            aggregate += (textValence > 0 ? conviction : -conviction)
            matched += 1
        }
        guard matched > 0 else { return 0 }
        return Self.clampSigned(aggregate / Double(matched))
    }

}

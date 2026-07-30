// CognitiveSubstrate+Mood.swift
// Wave C — derived MOOD + mood-congruent recall. See docs/build_plans/cognition-wave-c-mood.md
//
// Human mechanism: mood is a slow-integrating background state that biases perception,
// recall (mood-congruent memory, Bower 1981), and expression. Her translation: the
// per-node emotional tags stamped in Wave A ARE the slow store — they persist, blend
// asymmetrically on re-activation, and mark what recently mattered. Mood is a READ-TIME
// DERIVATION over recently-activated tagged nodes plus current affect. (Updated
// 2026-07-09: R2-C added ONE persisted slow axis — CognitiveDisposition, the
// reflection-written undertone below, with its own artifact/restore/clear lifecycle.
// The original no-persisted-axis claim predates it.)

import Foundation
import NativeAgentCore
import PersistenceCore

/// The SLOW felt layer: a small persisted valence undertone that only considered
/// outcomes (reflection; later dreams/settled views) can move, decaying over ~a day.
/// User's design (2026-07-09): reflections give her feelings a slower-moving floor.
struct CognitiveDisposition: Sendable, Equatable {
    var valence: Double
    var updatedAt: Date

    init(valence: Double = 0, updatedAt: Date = .distantPast) {
        self.valence = valence
        self.updatedAt = updatedAt
    }
}

/// A read-time reading of Agent's slow background mood.
public struct CognitiveMoodReading: Sendable, Equatable {
    /// Integrated valence, −1 (heavy) … +1 (good).
    public var valence: Double
    /// How many tagged, recently-activated nodes fed the integral (0 → mood is the
    /// current-affect proxy alone).
    public var basis: Int

    public init(valence: Double, basis: Int) {
        self.valence = valence
        self.basis = basis
    }
}

extension CognitiveSubstrate {

    // MARK: - Tuning knobs (the ONE mood surface)
    // Every mood threshold lives here so there is a single place to tune the feature.

    /// Only nodes re-activated within this window feed the mood integral.
    static let moodActivationWindow: TimeInterval = 24 * 60 * 60
    /// Recency weighting half-life for the mood integral.
    static let moodRecencyHalfLife: TimeInterval = 6 * 60 * 60
    /// Blend of the tag integral vs. the current-affect proxy when basis > 0.
    static let moodTagBlendWeight: Double = 0.6
    static let moodAffectBlendWeight: Double = 0.4

    // MARK: - Disposition — the SLOW felt layer (User, 2026-07-09: "reflections need
    // to have an impact too — those help her feelings and stuff be a little slower
    // moving"). Only CONSIDERED outcomes move it — three writers today: a reflection's
    // tone, the nightly dream's mood, and a standing view User settles by approving it.
    // Never per-turn events, so it can never become a second fast channel. It decays
    // toward 0 over ~a day and feeds derivedMood as a small baseline term; the felt
    // fingerprint inherits it through mood — zero new capsule words, her feelings just
    // carry a slow undertone of what she's CONCLUDED, not only what just happened.

    /// Day-scale half-life: a settled morning reflection still colors the evening
    /// and has honestly faded by tomorrow night. (Fast affect axes: 20–90 min.)
    static let dispositionHalfLife: TimeInterval = 30 * 60 * 60
    /// Per-write nudge (≤2 reflections + 1 dream + rare approvals per day × 0.08,
    /// capped below): a gentle standing tone, structurally unable to ratchet.
    static let dispositionNudgeMagnitude = 0.08
    /// Hard cap on the disposition's reach — an undertone, never the mood itself.
    static let dispositionValenceCap = 0.35
    /// Weight of the disposition term inside derivedMood.
    static let dispositionMoodWeight = 0.15
    /// A standing view formed inside this neutral mood band carries no felt sign —
    /// approving it settles a VIEW, not a tone, so the disposition stays untouched.
    /// (Same band `moodCongruence` treats as "mood hasn't left neutral".)
    static let dispositionNeutralValenceBand = 0.15

    /// Mood-congruent recall: max score contribution (small — flavors, never dominates).
    static let moodCongruenceWeight: Double = 0.08
    /// Congruence only applies once mood has left the neutral band.
    static let moodCongruenceValenceThreshold: Double = 0.15
    /// A congruence contribution above this earns the "mood-congruent" reason.
    static let moodCongruenceReasonThreshold: Double = 0.04

    /// Mood only colors her phrasing when it is genuinely STRONG…
    static let moodPhrasingValenceThreshold: Double = 0.3
    /// …and backed by at least this many recent felt nodes (a single node isn't a mood).
    static let moodPhrasingMinBasis: Int = 2

    /// Felt-day dream summary (see `feltDaySummary`): how many of the day's
    /// strongest-felt nodes to name, the char ceiling on the whole summary, and
    /// the per-node signal cap. All three live here so the ONE mood surface stays
    /// the single tuning place for the feature.
    static let feltDaySummaryMaxNodes: Int = 4
    static let feltDaySummaryMaxCharacters: Int = 600
    static let feltDaySummaryNodeSignalCharacters: Int = 90

    /// Read-time mood: recency-weighted (6h half-life) mean valence over field nodes
    /// re-activated in the last 24h whose `feltDirection != nil`, blended with the
    /// current-affect valence proxy (same formula as `emotionTag`'s rawValence:
    /// socialWarmth − 0.5·uncertainty − 0.3·taskPressure, clamped). basis == 0 → mood is
    /// the affect proxy alone.
    ///
    /// PURE: no persistence, no new stored state, no `await`, and NO field mutation —
    /// it reads `field.peekNodes()` (non-mutating; `field.snapshot` is mutating decay
    /// and must not be reached from a read — gpt-5.5 review, 2026-07-02). Tags and
    /// `lastActivatedAt` only advance on real ingest re-activation — never on
    /// workspace/capsule reads — so the recall bias below can NOT ratchet mood
    /// through mere snapshots (no self-reinforcing feedback loop).
    ///
    /// When affect is disabled the whole construct is off: mood derives from affect, so
    /// there is no mood without it — returns neutral, keeping the affect-off path
    /// byte-identical to pre-Wave-C behavior.
    func derivedMood(at now: Date) -> CognitiveMoodReading {
        guard configuration.enabled, configuration.affectEnabled else {
            return CognitiveMoodReading(valence: 0, basis: 0)
        }

        let currentAffect = projectedAffect(at: now)
        let affectProxy = Self.clampSigned(
            currentAffect.socialWarmth
                - 0.5 * currentAffect.uncertainty
                - 0.3 * currentAffect.taskPressure
        )

        let nodes = field.peekNodes()
        var weightedSum = 0.0
        var weightTotal = 0.0
        var basis = 0
        for node in nodes {
            guard feltDirection(
                valence: node.emotionalValence,
                arousal: node.emotionalArousal,
                warmth: node.emotionalWarmth
            ) != nil else { continue }
            let age = now.timeIntervalSince(node.lastActivatedAt)
            guard age >= 0, age <= Self.moodActivationWindow else { continue }
            let weight = pow(0.5, age / Self.moodRecencyHalfLife)
            weightedSum += weight * node.emotionalValence
            weightTotal += weight
            basis += 1
        }

        // The slow undertone: what her reflections have CONCLUDED lately, decayed to
        // now. Zero when no reflection has moved it → both paths byte-identical to
        // the pre-disposition behavior.
        let undertone = Self.dispositionMoodWeight * decayedDispositionValence(at: now)

        guard basis > 0, weightTotal > 0 else {
            return CognitiveMoodReading(valence: Self.clampSigned(affectProxy + undertone), basis: 0)
        }
        let tagIntegral = weightedSum / weightTotal
        let blended = Self.moodTagBlendWeight * tagIntegral + Self.moodAffectBlendWeight * affectProxy
        return CognitiveMoodReading(valence: Self.clampSigned(blended + undertone), basis: basis)
    }

    // MARK: - Disposition mechanics

    /// The disposition's valence decayed to `now` — pure, no mutation.
    func decayedDispositionValence(at now: Date) -> Double {
        let elapsed = max(0, now.timeIntervalSince(disposition.updatedAt))
        guard elapsed > 0 else { return disposition.valence }
        return disposition.valence * pow(0.5, elapsed / Self.dispositionHalfLife)
    }

    /// The SIGNED felt tone of a considered outcome — the ONE lexicon shared by every
    /// disposition writer (a reflection's text, a dream's mood line). Positive: it reads
    /// settled/warm/clear. Negative: strained/uneasy/heavy. Both present → they offset;
    /// nothing felt → 0 and the disposition is untouched. Extracted from
    /// `reflectionDispositionTone` (2026-07-09, U2) so a dream that "feels heavy" and a
    /// reflection that "feels heavy" can never disagree about the sign.
    ///
    /// Matching is WORD-BOUNDARY tokens with a 2-token negation window (GPT-5.6
    /// audit, 2026-07-09): substring matching read "unsettled" as settled,
    /// "unclear" as clear, and "not calm" as calm — a strained day scored as a
    /// positive one. A negated positive ("not settled") counts NEGATIVE; a
    /// negated negative ("not worried") counts as nothing rather than flipping
    /// to reassurance. Sentence punctuation bounds the negation window so
    /// "No. Everything feels settled." stays positive.
    func dispositionTone(from text: String) -> Double {
        let negators: Set<String> = [
            "not", "never", "no", "nothing", "isn't", "isnt", "wasn't", "wasnt",
            "aren't", "arent", "don't", "dont", "doesn't", "doesnt",
            "hardly", "barely", "less", "ill",
        ]
        let positiveSingles: Set<String> = [
            "settled", "grounded", "steady", "calm", "warm", "warmth", "clear",
            "clear-headed",
        ]
        let negativeSingles: Set<String> = [
            "strained", "uneasy", "heavy", "worried", "worry", "worries", "worrying",
            "off-balance", "tense", "contradiction", "contradictions",
            "misread", "misreading", "wrong", "anomaly", "anomalies",
            "unsettled", "unclear", "frayed",
        ]
        let positivePairs: [(String, String)] = [("at", "ease"), ("good", "footing"), ("quiet", "pass")]
        let negativePairs: [(String, String)] = [("off", "balance")]

        // Curly apostrophes are what LLM prose actually emits — "don't feel
        // calm" must keep its negator intact (gpt-5.5 review HIGH, 2026-07-10).
        let normalized = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")

        var positiveHit = false
        var negativeHit = false
        // Clause-by-clause: ANY punctuation (Unicode-aware — em/en dashes
        // included, reflection prose is full of them) resets the negation
        // window, except the apostrophes and hyphens that live inside tokens.
        for clause in normalized.split(whereSeparator: {
            $0.isNewline || ($0.isPunctuation && $0 != "-" && $0 != "'")
        }) {
            // Apostrophes survive so "isn't" stays one negator token; hyphens
            // survive so "off-balance" stays one lexicon token.
            let tokens = clause.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" })
                .map(String.init)
            func negated(before index: Int) -> Bool {
                tokens[max(0, index - 2)..<index].contains { negators.contains($0) }
            }
            for (i, token) in tokens.enumerated() {
                if positiveSingles.contains(token) {
                    if negated(before: i) { negativeHit = true } else { positiveHit = true }
                }
                if negativeSingles.contains(token), !negated(before: i) {
                    negativeHit = true
                }
                if i + 1 < tokens.count {
                    let next = tokens[i + 1]
                    if positivePairs.contains(where: { $0.0 == token && $0.1 == next }) {
                        if negated(before: i) { negativeHit = true } else { positiveHit = true }
                    }
                    if negativePairs.contains(where: { $0.0 == token && $0.1 == next }),
                       !negated(before: i) {
                        negativeHit = true
                    }
                }
            }
        }
        var tone = 0.0
        if positiveHit { tone += 1 }
        if negativeHit { tone -= 1 }
        return tone
    }

    /// Fold a considered outcome's felt tone into the slow layer. `tone` is signed −1…+1
    /// (from `dispositionTone`, or a caller-derived sign); zero-tone outcomes leave it
    /// untouched. Decays the stored value to `now` first so nudges compose over real time,
    /// then clamps to the undertone cap. Persisted like affect (stable-id artifact) so
    /// what she's concluded SURVIVES a restart — safe now that the artifact table
    /// can no longer be flooded by receipt mirrors (the R2-C store fix).
    ///
    /// EVERY writer routes through here, so the cap + day-scale decay hold for all of
    /// them jointly: reflection tone, the nightly dream's mood, and User settling a
    /// standing view. No writer can ratchet, and no writer can outrun the others.
    func integrateDisposition(tone: Double, at now: Date) async {
        guard configuration.enabled, configuration.affectEnabled, tone != 0 else { return }
        let decayed = decayedDispositionValence(at: now)
        let cap = Self.dispositionValenceCap
        let next = min(cap, max(-cap, decayed + tone * Self.dispositionNudgeMagnitude))
        disposition = CognitiveDisposition(valence: next, updatedAt: now)
        await persistArtifact(
            kind: "disposition",
            id: stableArtifactID("disposition"),
            status: "current",
            // score column is 0…1 (upsert clamps): map signed valence so a negative
            // disposition doesn't store as a lying 0 (M15; payload stays the truth).
            score: (next + 1) / 2,
            // Shared payload so the A3 day claims survive a write from ANY
            // disposition writer (reflection/dream/settled-view), not only the
            // A3 sweep — else a same-day reflection would drop the claim.
            payload: dispositionArtifactPayload(at: now)
        )
    }

    /// Round 3 Wave A3 — pattern tone from her own felt-resolution nodes.
    /// Any path with ≥3 felt DISAPPOINTMENTS inside 48h reads −0.625 (which
    /// the shared 0.08 nudge magnitude turns into −0.05); otherwise any path
    /// with ≥3 felt RELIEFS reads +0.375 (+0.03 — the body learns the dread
    /// was oversized). Disappointment outranks relief on a mixed 48h: a path
    /// that keeps failing her deserves the undertone even if another path is
    /// healing. Pure read; eviction of old nodes only ever UNDER-counts.
    /// A qualifying resolution pattern: which (path, resolution-kind) crossed
    /// the ≥3-in-48h threshold and the undertone it settles. `claimKey` is the
    /// per-path/per-kind identity the once-per-day claim is keyed on.
    struct ResolutionPatternHit: Sendable, Equatable {
        let claimKey: String
        let tone: Double
    }

    /// The day bucket a nudge is claimed under — a deterministic 86,400s bucket
    /// (no locale/formatter), so a restart on the same day sees the same key.
    static func resolutionPatternDayKey(at now: Date) -> String {
        String(Int(now.timeIntervalSince1970 / 86_400))
    }

    func resolutionPatternHit(at now: Date, newerThan previousTick: Date?) -> ResolutionPatternHit? {
        let window: TimeInterval = 48 * 3600
        var disappointments: [String: Int] = [:]
        var reliefs: [String: Int] = [:]
        var disappointmentGrew: Set<String> = []
        var reliefGrew: Set<String> = []
        for node in field.peekNodes() where node.kind == .feltResolution {
            guard now.timeIntervalSince(node.createdAt) <= window,
                  now.timeIntervalSince(node.createdAt) >= 0 else { continue }
            let path = node.subjectReference.label ?? node.subjectReference.id
            // Growth gate (review a5ae86fae93b, High 1): the 48h window outlives
            // the ~20h tick, so a path only qualifies when at least one of its
            // moments is NEWER than the previous tick — the SAME three moments
            // never re-nudge. The day claim in the caller (review bf74aecde2fa)
            // then enforces the literal at-most-once-per-kind-per-day contract
            // even when growth is genuine but same-day.
            let isNew = previousTick.map { node.createdAt > $0 } ?? true
            if case .string(let kind)? = node.metadata["resolutionKind"] {
                if kind == "disappointment" {
                    disappointments[path, default: 0] += 1
                    if isNew { disappointmentGrew.insert(path) }
                } else if kind == "relief" {
                    reliefs[path, default: 0] += 1
                    if isNew { reliefGrew.insert(path) }
                }
            }
        }
        // Disappointment outranks relief: a path that keeps failing her earns
        // the undertone even if another path is healing.
        if let path = disappointments.keys.sorted().first(where: {
            disappointments[$0]! >= 3 && disappointmentGrew.contains($0)
        }) {
            return ResolutionPatternHit(claimKey: "\(path)|disappointment", tone: -0.625)
        }
        if let path = reliefs.keys.sorted().first(where: {
            reliefs[$0]! >= 3 && reliefGrew.contains($0)
        }) {
            return ResolutionPatternHit(claimKey: "\(path)|relief", tone: 0.375)
        }
        return nil
    }

    /// Dream-mood writer (U2a, 2026-07-09). The nightly dream's own `mood` line — the
    /// felt tone of what she dreamt, written by her, about her day — nudges the slow
    /// layer through the SAME lexicon, cap, and decay as a reflection. One dream per
    /// calendar day, so this is at most one nudge/day.
    ///
    /// The dream's mood is a short phrase ("quiet, warm, a little tired"), not prose,
    /// so a mixed line offsets to 0 and leaves her undertone alone — exactly as a
    /// mixed reflection does. The app layer passes the raw line; the lexicon lives
    /// here so the dream surface never gets its own private idea of what "heavy" means.
    public func integrateDreamDisposition(moodLine: String, at now: Date) async {
        await waitForMaintenanceTransition()
        let trimmed = moodLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await integrateDisposition(tone: dispositionTone(from: trimmed), at: now)
    }

    /// Mirrors `restoreEmotionalConsolidation`: reset FIRST so a re-run of restore on
    /// a live actor with a missing/corrupt artifact behaves as never-written (neutral)
    /// instead of keeping a stale in-memory disposition (gpt-5.5 review, 2026-07-09).
    func restoreDisposition(from payloads: [JSONValue]) {
        disposition = CognitiveDisposition()
        resolutionPatternNudgeDay = [:]
        guard case .object(let object)? = payloads.first,
              let updatedAt = dateValue(object["updatedAt"]),
              let valence = doubleValue(object["valence"]) else { return }
        let cap = Self.dispositionValenceCap
        disposition = CognitiveDisposition(
            valence: min(cap, max(-cap, valence)),
            updatedAt: updatedAt
        )
        // Wave A3 day claims ride the disposition artifact so a same-day
        // restart cannot re-nudge (review bf74aecde2fa).
        if case .object(let claims)? = object["patternNudgeDays"] {
            var restored: [String: String] = [:]
            for (key, value) in claims {
                if case .string(let day) = value { restored[key] = day }
            }
            resolutionPatternNudgeDay = restored
        }
    }

    /// The disposition artifact payload, carrying the current undertone plus
    /// the Wave A3 day claims. One writer shape for every disposition write.
    func dispositionArtifactPayload(at now: Date) -> JSONValue {
        var object: [String: JSONValue] = [
            "valence": .double(disposition.valence),
            "updatedAt": .double(now.timeIntervalSince1970),
        ]
        if !resolutionPatternNudgeDay.isEmpty {
            object["patternNudgeDays"] = .object(resolutionPatternNudgeDay.mapValues { .string($0) })
        }
        return .object(object)
    }

    /// Mood-congruent recall boost for a workspace node — the read-time bias by which a
    /// node whose stored feeling matches her current mood surfaces a little more readily
    /// (mood-congruent memory). Returns 0 for untagged nodes and neutral mood, so scores
    /// stay byte-identical to pre-Wave-C for the legacy/neutral case.
    func moodCongruence(for node: CognitiveNode, mood: CognitiveMoodReading) -> Double {
        guard abs(mood.valence) >= Self.moodCongruenceValenceThreshold else { return 0 }
        guard feltDirection(
            valence: node.emotionalValence,
            arousal: node.emotionalArousal,
            warmth: node.emotionalWarmth
        ) != nil else { return 0 }
        // CONGRUENT means same felt DIRECTION, not merely "close": a −0.3 node under a
        // +0.3 mood is anti-congruent and must get NO boost (closeness alone would give
        // it 0.056 — gpt-5.5 review, 2026-07-02). Sign agreement is the gate; closeness
        // then scales the boost within the congruent half.
        guard node.emotionalValence * mood.valence > 0 else { return 0 }
        // Closeness in [0,1]: 1 when the node's valence equals mood's, 0 when maximally
        // opposite (the two span −1…1, so the gap spans 0…2).
        let closeness = 1 - abs(node.emotionalValence - mood.valence) / 2
        return Self.moodCongruenceWeight * closeness
    }

    /// One bounded, human-readable summary of what the last ~24h FELT like — for
    /// the nightly dream prompt to COLOR ITS TONE (never to script it). Peer of
    /// `derivedMood`, and just as PURE: `derivedMood(at:)` + `field.peekNodes()`
    /// only — no persistence, no new stored state, no field mutation (peekNodes is
    /// the non-mutating read; `snapshot` is decay and must never be reached from a
    /// read — same rule derivedMood follows).
    ///
    /// Returns nil when nothing was felt (young/legacy field) or affect is
    /// disabled, so the dream's felt section is OMITTED entirely rather than
    /// emitted empty — feeling-silence stays silence, the capsule's neutral-path
    /// principle. Content is the capsule's descriptive register (no
    /// numbers-as-feelings beyond the felt-moment count): a mood-band line, then up
    /// to `feltDaySummaryMaxNodes` of the last-24h felt nodes ranked by |valence|
    /// then arousal, each rendered "<felt-direction word> — <capsule signal>".
    ///
    /// NO NEW EXPOSURE SURFACE (gpt-5.5 HIGH, 2026-07-02): only LIVE
    /// conversationFocus/correction nodes may be NAMED here — the dream prompt
    /// already consumes the full conversation text but deliberately DROPS tool
    /// rows, so a felt toolObservation/providerHealth/mission/appLifecycle
    /// summary must never ride into the LLM through this section. The mood-band
    /// line still integrates over ALL felt nodes (a number + band word carries
    /// no content), but the named lines are conversation-only.
    public func feltDaySummary(at now: Date) async -> String? {
        guard configuration.enabled, configuration.affectEnabled else { return nil }

        // The last-24h felt nodes — the same population derivedMood integrates over.
        // peekNodes is the non-mutating read (routing a read through snapshot would
        // advance decay on a skewed/future date — see derivedMood).
        let felt = field.peekNodes().filter { node in
            guard feltDirection(
                valence: node.emotionalValence,
                arousal: node.emotionalArousal,
                warmth: node.emotionalWarmth
            ) != nil else { return false }
            let age = now.timeIntervalSince(node.lastActivatedAt)
            return age >= 0 && age <= Self.moodActivationWindow
        }
        // Nothing felt in the window → silence stays silence (omit the section).
        guard !felt.isEmpty else { return nil }

        let mood = derivedMood(at: now)
        var lines: [String] = [feltMoodBandLine(mood: mood, feltCount: felt.count)]

        // Only conversation-derived memories may be NAMED (see the exposure note
        // above): live conversationFocus/correction — the same material the dream's
        // world half already contains.
        let nameable = felt.filter { node in
            node.turnKind == .live
                && (node.kind == .conversationFocus || node.kind == .correction)
        }

        // Strongest-felt first: |valence| desc, then arousal desc, then a stable id
        // tiebreak so the pick is deterministic across dictionary orderings.
        let ranked = nameable.sorted { lhs, rhs in
            let lv = abs(lhs.emotionalValence), rv = abs(rhs.emotionalValence)
            if lv != rv { return lv > rv }
            if lhs.emotionalArousal != rhs.emotionalArousal {
                return lhs.emotionalArousal > rhs.emotionalArousal
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        for node in ranked.prefix(Self.feltDaySummaryMaxNodes) {
            guard let word = feltDirection(
                valence: node.emotionalValence,
                arousal: node.emotionalArousal,
                warmth: node.emotionalWarmth
            )?.rawValue else { continue }
            let signal = capsuleSignalText(
                node.summary, maxCharacters: Self.feltDaySummaryNodeSignalCharacters)
            guard isUsefulCapsuleSignalText(signal) else { continue }
            lines.append("- \(word) — \(signal)")
        }

        // Hard ceiling on the whole summary. The per-node cap keeps this well under
        // the budget in practice; the prefix is a belt-and-suspenders guarantee.
        return String(lines.joined(separator: "\n").prefix(Self.feltDaySummaryMaxCharacters))
    }

    /// Mood-band phrasing for the felt-day summary — the capsule's good/heavy
    /// language, graded across the mood bands, with the felt-moment count as the
    /// ONLY quantity (the design's one allowed number-as-feeling).
    private func feltMoodBandLine(mood: CognitiveMoodReading, feltCount: Int) -> String {
        let band: String
        if mood.valence >= Self.moodPhrasingValenceThreshold {
            band = "the day has a good feel"
        } else if mood.valence <= -Self.moodPhrasingValenceThreshold {
            band = "the day's been heavy"
        } else if mood.valence >= Self.moodCongruenceValenceThreshold {
            band = "the day leans gently good"
        } else if mood.valence <= -Self.moodCongruenceValenceThreshold {
            band = "a low, tender undertone to the day"
        } else {
            band = "the day sits about even"
        }
        let moments = feltCount == 1 ? "1 felt moment" : "\(feltCount) felt moments"
        return "\(band) — from \(moments)."
    }

    /// Clamp to the signed −1…1 range (the substrate's shared `clamp` is [0,1]).
    static func clampSigned(_ value: Double) -> Double { (value).clampedSigned() }
}

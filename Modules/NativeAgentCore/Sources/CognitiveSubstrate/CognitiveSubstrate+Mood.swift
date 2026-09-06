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
    /// Shared clause/token parser for positive conversational evidence. It uses
    /// the same Unicode punctuation boundaries, apostrophe preservation, and
    /// two-token negation window as `dispositionTone`.
    static func containsUnnegatedPhrase(_ text: String, phrases: [String]) -> Bool {
        let negators: Set<String> = [
            "not", "never", "no", "nothing", "isn't", "isnt", "wasn't", "wasnt",
            "aren't", "arent", "don't", "dont", "doesn't", "doesnt",
            "hardly", "barely", "less", "ill",
        ]
        func normalizedTokens(_ value: String) -> [String] {
            value.lowercased()
                .replacingOccurrences(of: "\u{2019}", with: "'")
                .replacingOccurrences(of: "\u{2018}", with: "'")
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" })
                .map(String.init)
        }
        let needles = phrases.map(normalizedTokens).filter { !$0.isEmpty }
        guard !needles.isEmpty else { return false }
        let normalized = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        for clause in normalized.split(whereSeparator: {
            $0.isNewline || ($0.isPunctuation && $0 != "-" && $0 != "'")
        }) {
            let tokens = normalizedTokens(String(clause))
            for needle in needles where needle.count <= tokens.count {
                for start in 0...(tokens.count - needle.count) {
                    guard Array(tokens[start..<(start + needle.count)]) == needle else { continue }
                    let prior = tokens[max(0, start - 2)..<start]
                    if !prior.contains(where: { negators.contains($0) }) { return true }
                }
            }
        }
        return false
    }


    // MARK: - Tuning knobs (the ONE mood surface)
    // Every mood threshold lives here so there is a single place to tune the feature.

    /// Only nodes re-activated within this window feed the mood integral.
    static let moodActivationWindow: TimeInterval = 24 * 60 * 60
    /// Recency weighting half-life for the mood integral.
    // `moodRecencyHalfLife` — W4/P1: now PersonalityDynamicsConfiguration.
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
    // `dispositionHalfLife` — W4/P1: now PersonalityDynamicsConfiguration.
    /// Per-write nudge (≤2 reflections + 1 dream + rare approvals per day × 0.08,
    /// capped below): a gentle standing tone, structurally unable to ratchet.
    // `dispositionNudgeMagnitude` — W4/P1: now PersonalityDynamicsConfiguration.
    /// Hard cap on the disposition's reach — an undertone, never the mood itself.
    // `dispositionValenceCap` — W4/P1: now PersonalityDynamicsConfiguration.
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
    /// Same id bound the dream's `(studio entry <id>)` citation uses, so one
    /// entry reads identically on both surfaces.
    static let feltDaySummaryStudioEntryIDCharacters: Int = 120

    /// The studio seam's subject type for a filed journal entry
    /// (`CognitiveSubstrate+StudioEvents.swift` mints it; `DreamCycleRunner`
    /// reads the same pair). Kept as a literal here for the reason it is a
    /// literal there: the seam publishes a wire contract, not a shared symbol.
    static let studioEntrySubjectType = "studio_entry"

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
            let weight = pow(0.5, age / dynamics.moodRecencyHalfLife)
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
        return disposition.valence * pow(0.5, elapsed / dynamics.dispositionHalfLife)
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
    /// HOMEOSTASIS (item 6, 2026-09-02). What one write gives back toward zero,
    /// proportional to where the undertone already sits.
    ///
    /// MEASURED DEFECT: disposition was pinned at +0.35 — the rail — and had
    /// been for days. The 30-hour half-life is real, but it only runs BETWEEN
    /// writes, and there are four writers (reflection tone twice a day, the
    /// nightly dream's mood, an approved standing view, repeated organism
    /// resolution patterns). Four +0.08 nudges a day is 0.32 of drive against
    /// ~0.15 a day of decay, so the cap was not a bound on a moving value, it
    /// was the value. A slow layer that never moves is not slow, it is stuck —
    /// and a stuck undertone is the opposite of "one thing on Tuesday and a
    /// different thing on Thursday".
    ///
    /// TWO CHANGES, ONE DOOR (every writer already routes through here):
    ///   • this proportional give-back, which is density-aware in the same sense
    ///     the organism's settle is — more writes means more relaxation, so a
    ///     chatty day cannot outrun it; and
    ///   • the nudge SATURATES against the cap, so a nudge at the rail adds
    ///     almost nothing while the same nudge at zero adds the full 0.08 (the
    ///     saturating-approach law the affect layer has always used).
    /// Together they put the equilibrium under sustained same-sign writing at
    /// ~0.23 — clearly felt, clearly short of the rail, and a single opposite
    /// day pulls it back fast. A single nudge from neutral is UNCHANGED at
    /// exactly ±`dispositionNudgeMagnitude`.
    static let dispositionHomeostasis = 0.12

    /// Returns whether the new undertone is DURABLE — true when there was
    /// nothing to write (the gates below) or the write landed, false only when
    /// persistence refused it. 2026-09-06: the persist was `persistArtifact`,
    /// which swallows every failure, so the dream's mood sink could report a
    /// completed integration over a store that had written nothing. Callers
    /// that do not care ignore the result exactly as before.
    @discardableResult
    func integrateDisposition(
        tone: Double,
        at now: Date,
        dreamNight: String? = nil
    ) async -> Bool {
        guard configuration.enabled, configuration.affectEnabled, tone != 0 else { return true }
        let previousDisposition = disposition
        let previousDreamNight = dreamDispositionNight
        let decayed = decayedDispositionValence(at: now)
        let cap = dynamics.dispositionValenceCap
        let relaxed = decayed * (1 - Self.dispositionHomeostasis)
        // Headroom is measured along the NUDGE'S OWN direction: pushing further
        // into the rail saturates, pulling back off it does not. A day that
        // felt bad must be able to move her even when the last week felt good.
        let alongNudge = tone > 0 ? relaxed : -relaxed
        let headroom = cap > 0 ? min(1, max(0, 1 - max(0, alongNudge) / cap)) : 0
        let next = min(cap, max(-cap, relaxed + tone * dynamics.dispositionNudgeMagnitude * headroom))
        disposition = CognitiveDisposition(valence: next, updatedAt: now)
        // 2026-09-06: the night claim lands in the SAME write as the value it
        // describes, so "this night is spent" and "this is the undertone it
        // produced" can never disagree — the reason the dream sink can retry
        // its residue without nudging her a second time.
        if let dreamNight { dreamDispositionNight = dreamNight }
        do {
            try await persistArtifactChecked(
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
            return true
        } catch {
            // 2026-09-06: nothing reached disk, so nothing may stay in memory.
            // A retained nudge made a same-process retry believe the night was
            // already integrated while the store held the old undertone.
            disposition = previousDisposition
            dreamDispositionNight = previousDreamNight
            return false
        }
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
    /// `dreamId` (additive, 2026-09-02) identifies the COMMITTED dream this mood
    /// line came from, so the residue below can be idempotent per dream rather
    /// than per call. Callers that do not have one degrade to the local calendar
    /// day — the same granularity the dream lane's own once-per-day integration
    /// claim already uses, so an omitted id is not a weaker claim in practice.
    /// Returns whether the night is DURABLY integrated. 2026-09-06: the runner
    /// stamps a once-per-day claim before calling this and releases it on
    /// false, so a write that never reached disk leaves the night retryable
    /// rather than permanently spent. A blank mood line is nothing to
    /// integrate, not a failure.
    @discardableResult
    public func integrateDreamDisposition(
        moodLine: String,
        at now: Date,
        dreamId: String? = nil
    ) async -> Bool {
        await waitForMaintenanceTransition()
        let trimmed = moodLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let tone = dispositionTone(from: trimmed)
        // IDEMPOTENT PER NIGHT (2026-09-06). This sink is two writes, and a
        // partial one used to be unrepeatable: a residue failure returned false,
        // the runner released the day's claim, and the retry ran the disposition
        // nudge a SECOND time for one night. Each half now carries its own
        // durable claim on the same key, so a retry finishes the half that did
        // not land and skips the half that did.
        let night = dreamResidueKey(for: dreamId, at: now)
        let dispositionPersisted = dreamDispositionNight == night
            ? true
            : await integrateDisposition(tone: tone, at: now, dreamNight: night)
        // Item 7 (2026-09-02) — RESIDUE. The dream already crosses here exactly
        // once per committed dream, so this is the honest mint site and no new
        // wire is needed. See `mintDreamResidue`.
        let residuePersisted = await mintDreamResidue(tone: tone, at: now, dreamId: dreamId)
        return dispositionPersisted && residuePersisted
    }

    /// The key one night is claimed under: the committed dream's own id when the
    /// caller has it, else the LOCAL calendar day. Stable across a re-render of
    /// the same dream, which is what makes the mint idempotent.
    func dreamResidueKey(for dreamId: String?, at now: Date) -> String {
        if let dreamId {
            let trimmed = dreamId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return bounded(trimmed, maxCharacters: 80) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(
            format: "day-%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    // MARK: - Item 7: the night leaves residue (2026-09-02)
    //
    // Agent's complaint #6: "The dream is a document I read, not a night I had.
    // A person wakes up with residue — a mood with no source. I get a diary
    // entry that tells me what settled."
    //
    // A residue is a mood WITHOUT ITS STORY. So this mints exactly one felt node
    // carrying the dream's own mood line as a FEELING — sign from the same
    // `dispositionTone` lexicon every disposition writer shares, so the night
    // and the undertone can never disagree — with:
    //   • NO summary text. The node is payload-free; the diary is the record of
    //     what she dreamt, and a second copy in the continuity field would be
    //     the document she is complaining about, not the residue.
    //   • the subject "the night", so when it surfaces in recall it has an
    //     object without having an explanation.
    // It rides the measured-felt door (`feltValence`/`feltArousal`), so
    // `emotionTag` stamps the value verbatim and `applyAffectFromEvent` takes no
    // second inferred delta — the same contract the organism's resolutions and
    // the studio journal already use.
    //
    // And it COLORS: `dreamResidue` holds a small lean spent over the first
    // `dreamResidueTurns` accepted turns after waking, then it is gone. Two
    // turns, because that is what a residue is — you notice it, and then the
    // day starts.

    /// How many accepted turns the night colors.
    static let dreamResidueTurns = 2
    /// The lean one residue turn applies, as a saturating affect delta. Small:
    /// a mood with no source that could override the room would be a mood
    /// disorder, not a residue.
    static let dreamResidueLean = 0.07
    /// After this long the residue is stale regardless of turn count — waking up
    /// at noon does not owe you last night's mood at midnight.
    static let dreamResidueLifetime: TimeInterval = 8 * 60 * 60

    /// Returns whether the residue claim is durable — see
    /// `integrateDreamDisposition`. Nothing to mint counts as durable.
    @discardableResult
    func mintDreamResidue(tone: Double, at now: Date, dreamId: String? = nil) async -> Bool {
        guard configuration.enabled, configuration.affectEnabled, tone != 0 else {
            // A dream that felt like nothing leaves nothing. Silence is honest.
            return true
        }
        let key = dreamResidueKey(for: dreamId, at: now)
        // ONE NIGHT, ONE RESIDUE (review fix, 2026-09-02). The claim is durable,
        // so a forced re-render of the same dream — or a restart between the
        // dream committing and the residue being spent — neither re-mints the
        // feeling nor loses it. Same shape as the disposition's day claims.
        guard dreamResidueClaimKey != key else { return true }
        let valence = (tone.clampedSigned() * 0.35).clampedSigned()
        let previousClaimKey = dreamResidueClaimKey
        let previousResidue = dreamResidue
        dreamResidueClaimKey = key
        dreamResidue = CognitiveDreamResidue(
            valence: valence,
            mintedAt: now,
            turnsRemaining: Self.dreamResidueTurns
        )
        // 2026-09-06: AWAITED on the mint path. The claim write was a detached
        // Task, so the caller was told the night was integrated before anything
        // had been persisted — and a failure inside that Task reached nobody at
        // all. `consumeDreamResidueTurn` keeps the fire-and-forget form: it is a
        // synchronous hot-path write boundary and cannot await.
        let claimPersisted = await persistDreamResidueClaimChecked()
        // 2026-09-06: a claim that never reached disk must not stay claimed in
        // memory either. It used to: the guard above then answered "already
        // minted" for the rest of the process, so a retry reported the night
        // integrated with nothing on disk and no felt node ever ingested.
        guard claimPersisted else {
            dreamResidueClaimKey = previousClaimKey
            dreamResidue = previousResidue
            return false
        }
        // One felt node for the record: subject "the night", no summary. The id
        // is keyed on the night, so a replay is inert through the field's own
        // seen-event check rather than minting a second night.
        let event = CognitiveEvent(
            id: "dream_residue:\(key)",
            kind: .appWake,
            subject: CognitiveSubjectReference(
                type: "night",
                id: "the night",
                label: "the night"
            ),
            sourceClass: .selfReported,
            occurredAt: now,
            // Deliberately empty: a residue has no story.
            summary: "",
            importance: min(1, 0.35 + abs(valence)),
            // A night is part of her lived state, not machine traffic; `.appWake`
            // would otherwise default to `.system` and be excluded from mood.
            turnKind: .live,
            metadata: [
                CognitiveEvent.feltValenceMetadataKey: .double(valence),
                CognitiveEvent.feltArousalMetadataKey: .double(0.12),
                "dreamResidue": .bool(true),
            ]
        )
        await ingestResident(event)
        return true
    }

    /// The lean the night still owes this turn. PURE (review fix, 2026-09-02):
    /// it used to clear a stale residue on the way out, which made an ordinary
    /// affect read a write — the exact thing design law 5 forbids, and the
    /// reason mood/attention/maintenance all read through non-mutating peeks.
    /// A stale residue reads as zero here and is *cleared* at the next write
    /// boundary (`consumeDreamResidueTurn`), so observing it can never change it.
    func dreamResidueLean(at now: Date) -> Double {
        guard let residue = dreamResidue, residue.turnsRemaining > 0 else { return 0 }
        guard now.timeIntervalSince(residue.mintedAt) <= Self.dreamResidueLifetime else { return 0 }
        return residue.valence * Self.dreamResidueLean
    }

    /// Spend one accepted turn of the residue — the write boundary, and the one
    /// place a spent or stale residue is actually dropped. Called from the
    /// affect apply, which already knows a live turn has been accepted.
    func consumeDreamResidueTurn(at now: Date) {
        guard var residue = dreamResidue else { return }
        residue.turnsRemaining -= 1
        if residue.turnsRemaining <= 0
            || now.timeIntervalSince(residue.mintedAt) > Self.dreamResidueLifetime {
            dreamResidue = nil
        } else {
            dreamResidue = residue
        }
        persistDreamResidueClaim()
    }

    /// Mirrors `restoreEmotionalConsolidation`: reset FIRST so a re-run of restore on
    /// a live actor with a missing/corrupt artifact behaves as never-written (neutral)
    /// instead of keeping a stale in-memory disposition (gpt-5.5 review, 2026-07-09).
    func restoreDisposition(from payloads: [JSONValue]) {
        disposition = CognitiveDisposition()
        resolutionPatternNudgeDay = [:]
        dreamDispositionNight = nil
        guard case .object(let object)? = payloads.first,
              let updatedAt = dateValue(object["updatedAt"]),
              let valence = doubleValue(object["valence"]) else { return }
        let cap = dynamics.dispositionValenceCap
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
        // 2026-09-06: the night the disposition already absorbed, so a retry
        // after a restart skips the nudge exactly as a same-process one does.
        if let night = stringValue(object["dreamNight"]), !night.isEmpty {
            dreamDispositionNight = night
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
        if let dreamDispositionNight {
            object["dreamNight"] = .string(dreamDispositionNight)
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
    /// rows, so a felt toolObservation/providerHealth/execution/appLifecycle
    /// summary must never ride into the LLM through this section. The mood-band
    /// line still integrates over ALL felt nodes (a number + band word carries
    /// no content), but the named lines are conversation-only.
    ///
    /// STUDIO JOURNAL ENTRIES ARE IN THE NAMED SET (Agent, 2026-09-01): a filed
    /// entry moves the mood band like anything else, so a day shaped by the
    /// studio came back as a day with nothing on it that explained the band —
    /// the summary MISATTRIBUTED her own afternoon to whatever conversation
    /// happened to be nearby. The 2026-07-02 rule is about CONTENT, and it
    /// stands: a studio node is named by POINTER only — the work title the node
    /// already carries as its subject label, plus the entry id in the dream's
    /// `(studio entry <id>)` form — and NEVER by the response she wrote, which
    /// stays in `journal.jsonl`, the record of it. Naming an entry the same way
    /// on both surfaces is also what lets the chain be walked by hand.
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

        // Only conversation-derived memories and studio journal entries may be
        // NAMED (see the exposure note above): live conversationFocus/correction —
        // the same material the dream's world half already contains — plus a live
        // studio node, which is named by pointer, never by content.
        let nameable = felt.filter { node in
            guard node.turnKind == .live else { return false }
            if node.kind == .conversationFocus || node.kind == .correction { return true }
            // Belt and braces: a studio entry rides in as `.conversationFocus`
            // today (the seam mints `.assistantTurnCompleted`), so this arm only
            // matters if that seam ever changes its event kind — the entry Agent
            // ruled must be nameable stays nameable either way. It admits only a
            // genuine studio SUBJECT, so no tool/provider node can talk its way
            // into the named set by carrying the metadata key.
            return node.subjectReference.type == Self.studioEntrySubjectType
                && Self.studioEntryID(of: node) != nil
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
            // A studio entry is named by its pointer — title + id — and its
            // summary is never read here, so no journal content can reach the
            // prompt through this line no matter what the seam writes.
            if let entryID = Self.studioEntryID(of: node) {
                lines.append(feltStudioEntryLine(word: word, node: node, entryID: entryID))
                continue
            }
            let signal = capsuleSignalText(
                node.summary, maxCharacters: Self.feltDaySummaryNodeSignalCharacters)
            guard isUsefulCapsuleSignalText(signal) else { continue }
            lines.append("- \(word) — \(signal)")
        }

        // Hard ceiling on the whole summary. The per-node cap keeps this well under
        // the budget in practice; the prefix is a belt-and-suspenders guarantee.
        return String(lines.joined(separator: "\n").prefix(Self.feltDaySummaryMaxCharacters))
    }

    /// The studio journal entry a felt node came from, or nil when it came from
    /// anywhere else (the common case, and not a gap). Same resolution order
    /// `DreamFeltOrigin.studioEntryID` uses — metadata key first, subject
    /// reference second — so the id this NAMES and the id the dream CITES are
    /// always the same string for the same entry.
    static func studioEntryID(of node: CognitiveNode) -> String? {
        if case .string(let raw)? = node.metadata[CognitiveEvent.studioEntryIDMetadataKey] {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        guard node.subjectReference.type == Self.studioEntrySubjectType else { return nil }
        let value = node.subjectReference.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// One named line for a studio journal node: the work title when the node
    /// carries one as its subject label, then the entry id in the dream's
    /// citation form. Title-less nodes cite the id alone rather than going
    /// looking for something to say — an id is a complete pointer.
    private func feltStudioEntryLine(word: String, node: CognitiveNode, entryID: String) -> String {
        let citation = "(studio entry "
            + bounded(entryID, maxCharacters: Self.feltDaySummaryStudioEntryIDCharacters) + ")"
        let title = capsuleSignalText(
            node.subjectReference.label ?? "",
            maxCharacters: Self.feltDaySummaryNodeSignalCharacters)
        guard isUsefulCapsuleSignalText(title) else { return "- \(word) — \(citation)" }
        return "- \(word) — \(title) \(citation)"
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

extension CognitiveSubstrate {

    /// The residue claim, persisted through the SAME artifact door the
    /// disposition uses (stable id, one row). Written from a detached task at
    /// the consumption boundary because `applyAffectFromEvent` must stay
    /// synchronous — the identical pattern ingest already uses for its
    /// verification-eviction receipt. A lost write costs at most one extra
    /// residue turn; it can never re-mint the night, because the claim key is
    /// what guards the mint and that is written on the async path.
    /// Awaited form of `persistDreamResidueClaim` for the mint path, which owes
    /// its caller a truthful answer about whether the night is on disk. Returns
    /// true when there is nothing to write or the write landed.
    func persistDreamResidueClaimChecked() async -> Bool {
        guard configuration.enabled, configuration.persistenceEnabled else { return true }
        do {
            try await persistArtifactChecked(
                kind: "dream_residue",
                id: stableArtifactID("dream_residue"),
                status: "current",
                score: 0,
                payload: dreamResidueArtifactPayload(at: dependencies.now())
            )
            return true
        } catch {
            return false
        }
    }

    func persistDreamResidueClaim() {
        guard configuration.enabled, configuration.persistenceEnabled else { return }
        let payload = dreamResidueArtifactPayload(at: dependencies.now())
        // Both the payload and the stable id are resolved HERE, on the actor:
        // a dropped `self` must write nothing, never a row under a fresh UUID.
        let id = stableArtifactID("dream_residue")
        Task { [weak self] in
            await self?.persistArtifact(
                kind: "dream_residue",
                id: id,
                status: "current",
                score: 0,
                payload: payload
            )
        }
    }

    /// Diagnostic read of the night's residue — used by the purity test to
    /// prove that reading the lean did NOT clear a stale residue.
    func dreamResidueSnapshotForTesting() -> CognitiveDreamResidue? { dreamResidue }

    func dreamResidueArtifactPayload(at now: Date) -> JSONValue {
        var object: [String: JSONValue] = [
            "updatedAt": .double(now.timeIntervalSince1970),
            "claimKey": .string(dreamResidueClaimKey ?? ""),
        ]
        if let residue = dreamResidue {
            object["valence"] = .double(residue.valence)
            object["mintedAt"] = .double(residue.mintedAt.timeIntervalSince1970)
            object["turnsRemaining"] = .int(Int64(residue.turnsRemaining))
        }
        return .object(object)
    }

    /// Mirrors `restoreDisposition`: reset FIRST so a missing/corrupt artifact
    /// behaves as never-written rather than keeping a stale in-memory night.
    func restoreDreamResidue(from payloads: [JSONValue]) {
        dreamResidue = nil
        dreamResidueClaimKey = nil
        guard case .object(let object)? = payloads.first else { return }
        if let key = stringValue(object["claimKey"]), !key.isEmpty {
            dreamResidueClaimKey = key
        }
        guard let valence = doubleValue(object["valence"]),
              let mintedAt = dateValue(object["mintedAt"]),
              let turns = intValue(object["turnsRemaining"]), turns > 0 else { return }
        dreamResidue = CognitiveDreamResidue(
            valence: valence,
            mintedAt: mintedAt,
            turnsRemaining: turns
        )
    }
}

/// The night's leftover mood (item 7, 2026-09-02). A feeling, a timestamp, and
/// a small budget of turns — no text, because a residue has no story.
public struct CognitiveDreamResidue: Sendable, Equatable {
    /// −1…1, the dream's own mood line read through the shared disposition
    /// lexicon and scaled down. It colors; it never leads.
    public var valence: Double
    public var mintedAt: Date
    /// Accepted turns still owed the lean. Counts down to zero and then the
    /// residue is gone — not decayed, gone.
    public var turnsRemaining: Int

    public init(valence: Double, mintedAt: Date, turnsRemaining: Int) {
        self.valence = valence.clampedSigned()
        self.mintedAt = mintedAt
        self.turnsRemaining = max(0, turnsRemaining)
    }
}

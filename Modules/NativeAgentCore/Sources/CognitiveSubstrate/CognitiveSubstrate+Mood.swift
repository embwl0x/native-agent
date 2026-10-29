// CognitiveSubstrate+Mood.swift
// Mood derives at read time from recent emotional tags and affect; persisted disposition supplies a slow undertone.

import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+Mood.swift` | `CognitiveSubstrate` mood: read-time emotional-tag integration, disposition, congruence, felt-day summaries |

/// Considered outcomes move the persisted disposition undertone, which decays over about a day.
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
    // MARK: - Mood

    /// Only nodes re-activated within this window feed the mood integral.
    static let moodActivationWindow: TimeInterval = 24 * 60 * 60
    /// Blend of the tag integral vs. the current-affect proxy when basis > 0.
    static let moodTagBlendWeight: Double = 0.6
    static let moodAffectBlendWeight: Double = 0.4

    // MARK: - Disposition
    // Considered outcomes move disposition; daily decay feeds a small mood baseline without a second fast channel.

    /// Weight of the disposition term inside derivedMood.
    static let dispositionMoodWeight = 0.15
    /// Mood-congruent recall: max score contribution (small — flavors, never dominates).
    static let moodCongruenceWeight: Double = 0.08
    /// Congruence only applies once mood has left the neutral band.
    static let moodCongruenceValenceThreshold: Double = 0.15
    /// A congruence contribution above this earns the "mood-congruent" reason.
    static let moodCongruenceReasonThreshold: Double = 0.04

    /// Mood only colors her phrasing when it is genuinely STRONG…
    static let moodPhrasingValenceThreshold: Double = 0.3

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

    /// The felt-day population, read without advancing decay or disclosing content.
    func feltDayNodes(at now: Date) -> [CognitiveNode] {
        field.peekNodes().filter { node in
            guard node.feltDirection != nil else { return false }
            let age = now.timeIntervalSince(node.lastActivatedAt)
            return age >= 0 && age <= Self.moodActivationWindow
        }
    }

    /// Read-time mood: recency-weighted (6h half-life) mean valence over field nodes
    /// re-activated in the last 24h whose `feltDirection != nil`, blended with the
    /// current-affect valence proxy (socialWarmth − 0.5·uncertainty −
    /// 0.3·taskPressure, clamped). basis == 0 → mood is
    /// the affect proxy alone.
    ///
    /// PURE: no persistence, no new stored state, no `await`, and NO field mutation —
    /// it reads `field.peekNodes()` (non-mutating; `field.snapshot` is mutating decay
    /// and must not be reached from a read). Tags and
    /// `lastActivatedAt` only advance on real ingest re-activation — never on
    /// workspace/capsule reads — so the recall bias below can NOT ratchet mood
    /// through mere snapshots (no self-reinforcing feedback loop).
    ///
    /// Disabled cognition returns neutral mood.
    func derivedMood(
        at now: Date,
        dynamics capturedDynamics: PersonalityDynamicsConfiguration? = nil,
        affect capturedAffect: CognitiveAffectState? = nil
    ) -> CognitiveMoodReading {
        guard configuration.enabled else {
            return CognitiveMoodReading(valence: 0, basis: 0)
        }

        let dyn = capturedDynamics ?? dynamics
        let currentAffect = capturedAffect ?? projectedAffect(at: now, dynamics: dyn)
        let affectProxy = (
            currentAffect.socialWarmth
                - 0.5 * currentAffect.uncertainty
                - 0.3 * currentAffect.taskPressure
        ).clampedSigned()

        var weightedSum = 0.0
        var weightTotal = 0.0
        var basis = 0
        for node in feltDayNodes(at: now) {
            let age = now.timeIntervalSince(node.lastActivatedAt)
            let weight = pow(0.5, age / dyn.moodRecencyHalfLife)
            weightedSum += weight * node.emotionalValence
            weightTotal += weight
            basis += 1
        }

        // The decayed disposition adds a slow undertone, zero until an outcome moves it.
        let undertone = Self.dispositionMoodWeight * decayedDispositionValence(at: now, dynamics: dyn)

        guard basis > 0, weightTotal > 0 else {
            return CognitiveMoodReading(valence: (affectProxy + undertone).clampedSigned(), basis: 0)
        }
        let tagIntegral = weightedSum / weightTotal
        let blended = Self.moodTagBlendWeight * tagIntegral + Self.moodAffectBlendWeight * affectProxy
        return CognitiveMoodReading(valence: (blended + undertone).clampedSigned(), basis: basis)
    }

    // MARK: - Disposition mechanics

    /// The disposition's valence decayed to `now` — pure, no mutation.
    func decayedDispositionValence(
        at now: Date,
        dynamics capturedDynamics: PersonalityDynamicsConfiguration? = nil
    ) -> Double {
        let elapsed = max(0, now.timeIntervalSince(disposition.updatedAt))
        guard elapsed > 0 else { return disposition.valence }
        return disposition.valence * pow(0.5, elapsed / (capturedDynamics ?? dynamics).dispositionHalfLife)
    }

    /// All disposition writers share capped, decaying, saturating nudges and proportional relaxation toward zero.
    static let dispositionHomeostasis = 0.12

    /// A week of writes at four writers a day, and no more. The trail exists to
    /// answer "what moved me this week"; anything older is not that question.
    static let maximumDispositionTransitions = 28

    /// Returns true when nothing needs writing or the undertone is durable, false when persistence refuses it.
    @discardableResult
    func integrateDisposition(
        tone: Double,
        at now: Date,
        dreamNight: String? = nil,
        // Each disposition writer names its source so experience remains distinguishable from decay.
        source: String = "experience",
        // Only her own reflection and dream updates are undoable.
        undoable: Bool = false,
        reflectionRequest: CognitiveReflectionRequest? = nil
    ) async -> Bool {
        if let reflectionRequest, !ownsReflectionReservation(reflectionRequest) { return false }
        guard configuration.enabled, tone != 0 else { return true }
        let previousDisposition = disposition
        let previousDreamNight = dreamDispositionNight
        let previousTransitions = dispositionTransitions
        integrateDispositionInMemory(tone: tone, at: now, dreamNight: dreamNight, source: source)
        // A newer revision keeps failed maintenance from replacing this writer.
        dirtyRevision &+= 1
        let written = disposition
        do {
            try await persistArtifactChecked(
                kind: "disposition",
                id: stableArtifactID("disposition"),
                status: "current",
                score: (written.valence + 1) / 2,
                payload: dispositionArtifactPayload(at: now)
            )
            if let reflectionRequest, !ownsReflectionReservation(reflectionRequest) { return false }
            if undoable { await recordDispositionUndo(what: "undertone nudge: \(source)",
                             previous: .object([
                                 "valence": .double(previousDisposition.valence),
                                 "updatedAt": .double(previousDisposition.updatedAt.timeIntervalSince1970),
                             ]),
                             stamp: Self.undoStamp(written)) }
            return true
        } catch {
            if let reflectionRequest, !ownsReflectionReservation(reflectionRequest) { return false }
            // Restore only this failed write; a later writer owns its own value.
            guard disposition == written else { return false }
            disposition = previousDisposition
            dreamDispositionNight = previousDreamNight
            dispositionTransitions = previousTransitions
            return false
        }
    }

    /// One synchronous disposition law, used inside each owner's transaction.
    /// Callers retain and restore its value, claims and evidence on write failure.
    func integrateDispositionInMemory(
        tone: Double, at now: Date, dreamNight: String? = nil, source: String
    ) {
        let previousDisposition = disposition
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
        // THE THREE NUMBERS, IN THE SAME WRITE AS THE VALUE THEY EXPLAIN.
        // `relaxed` is where time alone left her; `next` is where the
        // experience left her. Their difference IS the contribution, so the
        // readout never has to infer one from a pair of snapshots.
        dispositionTransitions.append(CognitiveDispositionTransition(
            before: previousDisposition.valence,
            afterDecay: relaxed,
            afterContribution: next,
            at: now,
            source: bounded(source, maxCharacters: 60)))
        if dispositionTransitions.count > Self.maximumDispositionTransitions {
            dispositionTransitions.removeFirst(
                dispositionTransitions.count - Self.maximumDispositionTransitions)
        }
        // The night claim and its undertone value share one write so retrying residue cannot nudge twice.
        if let dreamNight { dreamDispositionNight = dreamNight }
    }

    /// Pattern tone from her own felt-resolution nodes.
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
    /// (not a calendar day), so a restart on the same day sees the same key.
    static func resolutionPatternDayKey(at now: Date) -> String {
        String(format: "%.0f", (now.timeIntervalSince1970 / 86_400).rounded(.towardZero) + 0)
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
            // A path needs a moment newer than the previous tick to qualify.
            // The caller also limits nudges to one per path/kind/day.
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
            (disappointments[$0] ?? 0) >= 3 && disappointmentGrew.contains($0)
        }) {
            return ResolutionPatternHit(claimKey: "\(path)|disappointment", tone: -0.625)
        }
        if let path = reliefs.keys.sorted().first(where: {
            (reliefs[$0] ?? 0) >= 3 && reliefGrew.contains($0)
        }) {
            return ResolutionPatternHit(claimKey: "\(path)|relief", tone: 0.375)
        }
        return nil
    }

    /// Reset before restore so an absent artifact leaves a neutral disposition.
    func restoreDisposition(from payloads: [JSONValue]) {
        disposition = CognitiveDisposition()
        resolutionPatternNudgeDay = [:]
        dreamDispositionNight = nil
        dispositionTransitions = []
        guard case .object(let object)? = payloads.first,
              let updatedAt = dateValue(object["updatedAt"]),
              let valence = object["valence"]?.numberValue(coercingStrings: false, finiteOnly: false) else { return }
        let cap = dynamics.dispositionValenceCap
        disposition = CognitiveDisposition(
            valence: min(cap, max(-cap, valence)),
            updatedAt: updatedAt
        )
        // Day claims prevent another nudge after a same-day restart.
        if case .object(let claims)? = object["patternNudgeDays"] {
            var restored: [String: String] = [:]
            for (key, value) in claims {
                if case .string(let day) = value { restored[key] = day }
            }
            resolutionPatternNudgeDay = restored
        }
        // A night already absorbed cannot nudge again after restart.
        if let night = object["dreamNight"]?.stringValue, !night.isEmpty {
            dreamDispositionNight = night
        }
        // Historical rows without transitions retain an empty trail.
        if case .array(let rows)? = object["transitions"] {
            var restored: [CognitiveDispositionTransition] = []
            for row in rows {
                guard case .object(let fields) = row,
                      let before = fields["before"]?.numberValue(coercingStrings: false, finiteOnly: false),
                      let afterDecay = fields["afterDecay"]?.numberValue(coercingStrings: false, finiteOnly: false),
                      let afterContribution = fields["afterContribution"]?.numberValue(coercingStrings: false, finiteOnly: false),
                      let at = dateValue(fields["at"]) else { continue }
                restored.append(CognitiveDispositionTransition(
                    before: before,
                    afterDecay: afterDecay,
                    afterContribution: afterContribution,
                    at: at,
                    source: fields["source"]?.stringValue ?? "experience"))
            }
            dispositionTransitions = Array(restored.suffix(Self.maximumDispositionTransitions))
        }
    }

    /// One payload for every disposition write, carrying the current undertone and day claims.
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
        // Transitions share the disposition value's durable write; rows without a trail restore an empty one.
        if !dispositionTransitions.isEmpty {
            object["transitions"] = .array(dispositionTransitions.map { $0.toJSON() })
        }
        return .object(object)
    }

    /// Felt-day projections rank strength, arousal, then stable identity.
    static func feltDayStronger(_ lhs: CognitiveNode, _ rhs: CognitiveNode) -> Bool {
        let lv = abs(lhs.emotionalValence), rv = abs(rhs.emotionalValence)
        if lv != rv { return lv > rv }
        if lhs.emotionalArousal != rhs.emotionalArousal {
            return lhs.emotionalArousal > rhs.emotionalArousal
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Mood-congruent recall boost for a workspace node — the read-time bias by which a
    /// node whose stored feeling matches her current mood surfaces a little more readily.
    /// Returns zero for untagged nodes and neutral mood.
    func moodCongruence(for node: CognitiveNode, mood: CognitiveMoodReading) -> Double {
        guard abs(mood.valence) >= Self.moodCongruenceValenceThreshold else { return 0 }
        guard node.feltDirection != nil else { return 0 }
        // Mood congruence requires sign agreement before closeness scales the boost.
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
    /// All eligible tags color the mood band. Named content is limited to live
    /// conversation/correction nodes and studio pointers (title and entry id);
    /// studio response text stays in its journal.
    public func feltDaySummary(at now: Date) async -> String? {
        guard configuration.enabled else { return nil }

        let felt = feltDayNodes(at: now)
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
            // Studio subjects stay nameable by pointer, regardless of event kind.
            return node.subjectReference.type == Self.studioEntrySubjectType
                && CognitiveFeltOrigin(node: node).studioEntryID != nil
        }

        let ranked = nameable.sorted(by: Self.feltDayStronger)
        for node in ranked.prefix(Self.feltDaySummaryMaxNodes) {
            guard let word = node.feltDirection?.rawValue else { continue }
            // A studio entry is named by its pointer — title + id — and its
            // summary is never read here, so no journal content can reach the
            // prompt through this line no matter what the seam writes.
            if let entryID = CognitiveFeltOrigin(node: node).studioEntryID {
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
}

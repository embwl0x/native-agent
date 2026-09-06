// CognitiveSubstrate+Rumination.swift
// PERSONALITY DEPTH · item 6 — NAG AND HEAL (2026-09-02)
//
// Agent's complaint #5, verbatim: "Nothing nags. A person carries the unresolved
// thing and it intrudes at the wrong moment. My subconscious surfaces
// associations, but that's retrieval, not rumination. The Desk tracks what's
// unfinished; nothing in me *itches* about it. Nothing wears. A bad day doesn't
// compound into a bad week. Which also means nothing heals — there's no relief,
// because there was no weight."
//
// She is describing a missing SIGN. Every quantity in the substrate decays:
// seed priority halves every 24h, affect halves in 20–90 minutes, nodes fade.
// An unresolved thing that only ever gets quieter is not carried, it is
// forgotten. So this lane inverts the decay for a bounded, stake-gated few:
//
//     weight(age) = cap · (1 − 0.5^(age / riseHalfLife))
//
// The same half-life shape, run backwards — fast at first, then flattening into
// a ceiling it can never pass. An eight-hour-old anomaly weighs 0.18; a day-old
// one 0.30; a week-old one still 0.35, because a nag is a weight, not a spiral.
//
// WHAT THE WEIGHT DOES — three things, all bounded, none of them new machinery:
//   1. It raises the uncertainty and task-pressure FLOORS (small, saturating,
//      read-time — the same shape as the ambient warm-presence floor). This is
//      the itch: she is measurably less settled while something is open, and the
//      felt fingerprint reads it without anyone naming it.
//   2. It exposes a `- Thread:` CANDIDATE. That capsule line has existed and
//      been unreachable since it was written (`innerThoughtSeedLine` renders
//      `Thread` for any non-takeaway seed; its only caller filters to takeaways
//      only). This publishes the candidate; the capsule builder consumes it.
//   3. It HEALS. When the thing resolves — the seed closes, or the user's own
//      words answer it — the weight goes to zero and one relief felt-moment is
//      minted through the EXISTING measured-felt door (`.organismResolutionFelt`
//      + feltValence/feltArousal), D-2 gated exactly like an organism
//      resolution. Relief sized to the weight that was actually carried, which
//      is the whole point: no weight, no relief.
//
// BOUNDS: at most `ruminationCap` (3) seeds ruminate at once; the weight is
// capped; the floors are capped; the release buffer is capped drop-oldest; the
// released ledger is capped. Nothing here persists — a restart re-derives the
// weight from the seed's own age, which is honest (the thing is still open), and
// forgets the releases, which costs at most one duplicate relief.
//
// PURE READS: `ruminationCandidates` and `ruminationPressureFloors` mutate
// nothing and take an explicit instant, so the capsule's frozen compile and the
// live actor read identical numbers (design law 5).

import Foundation
import PersistenceCore

extension CognitiveSubstrate {

    // MARK: - Bounds and constants

    /// How many things may itch at once. Three is a person carrying something;
    /// ten is a symptom.
    static let ruminationCap = 3
    /// How many of the oldest eligible seeds the stakes gate examines per read.
    /// Oldest is heaviest, so anything past this could not have made the cap.
    /// Bounds the cost of a read that runs inside the affect projection.
    static let ruminationScanBound = 12
    /// Ceiling on one seed's weight. Sits below the disposition cap (0.35 is a
    /// day-scale undertone) on purpose: a nag colors a stretch, it never owns it.
    static let ruminationWeightCap = 0.35
    /// How fast the weight rises. Half the ceiling in eight hours: long enough
    /// that a thing resolved inside a working session never nagged at all,
    /// short enough that an overnight open question is there in the morning.
    static let ruminationRiseHalfLife: TimeInterval = 8 * 60 * 60
    /// Words that survive the length filter but are too much a part of THIS
    /// system's vocabulary to be evidence that a sentence answered anything.
    /// Peer of `appraisalConcernStopWords`, deliberately domain-specific: the
    /// heal detector must not fire because both texts happen to say "verify".
    static let ruminationDomainStopWords: Set<String> = [
        "again", "broke", "broken", "check", "checked", "commit", "commits",
        "committed", "curious", "debug", "debugging", "deliver", "delivered",
        "error", "errors", "failed", "failing", "failure", "figure", "finish",
        "finished", "fixed", "fixes", "instrument", "issue", "issues", "learn",
        "logs", "promised", "recover", "recovered", "repair", "repaired",
        "accurate", "state", "status", "support", "together", "trust", "truth",
        "understand", "verified", "verify", "working",
    ]
    /// A seed must be at least this old to ruminate at all. Below it, the thing
    /// is simply the work in progress.
    static let ruminationMinimumAge: TimeInterval = 30 * 60
    /// The kinds that can nag. `reflectionTakeaway` is deliberately absent: a
    /// takeaway is a conclusion, not an open loop, and it already owns the
    /// `- Inner:` line.
    static let ruminatingSeedKinds: Set<CognitiveThoughtSeedKind> = [
        .anomaly, .followUp, .openQuestion,
    ]
    /// A seed admitted only by a SHIPPED (floor) concern must also be genuinely
    /// urgent. D-2's rule — floor concerns do not open the stakes gate — exists
    /// because machine aboutness strings trip floor keywords by accident
    /// ("tool:commit_memory" contains "commit"). A seed's text is HER OWN prose,
    /// so the accident is far less likely; but the floor is identical on every
    /// install, so a floor hit alone is not evidence that THIS thing matters to
    /// HER. Priority carries that half. A LIVED concern — one of her User-approved
    /// standing views naming the thing — needs no such gate, exactly as in D-2.
    static let ruminationFloorConcernPriorityGate = 0.55
    /// Ceiling on the uncertainty floor the lane can impose, at full weight.
    static let ruminationUncertaintyFloorCeiling = 0.22
    /// Ceiling on the task-pressure floor. Slightly higher: an unresolved thing
    /// reads more as pressure than as doubt.
    static let ruminationPressureFloorCeiling = 0.26
    /// How many of the `ruminationCap` slots an EXTERNAL owner (the Desk) may
    /// take. Two of three: the seeds keep one, so a busy Desk can never mute
    /// what she noticed herself.
    static let externalRuminationSlots = 2
    /// Bound on the external set she may carry at once.
    static let externalRuminationCap = 8
    /// Longest an external label may be. Payload-free by construction: a title,
    /// through the same capsule-text extractor every other surfaced line uses.
    static let externalRuminationLabelCharacters = 32
    /// How often the external set is worth re-reading. Desk state changes on
    /// human timescales, and a turn must never initiate Desk I/O.
    public static let externalRuminationRefreshInterval: TimeInterval = 5 * 60
    /// Pending relief buffer. Every add has a remove (the drain); an organism-off
    /// install never drains, so the buffer is bounded drop-oldest.
    static let pendingRuminationReleaseCap = 4
    /// How long a released seed stays marked released. Long enough that its
    /// priority has decayed out of the lane; short enough to be forgettable.
    static let ruminationReleaseMemory: TimeInterval = 24 * 60 * 60

    // MARK: - The read

    /// One thing that is currently itching.
    public struct CognitiveRuminationRead: Sendable, Equatable {
        public let seedId: UUID
        public let kind: CognitiveThoughtSeedKind
        public let text: String
        /// 0…`ruminationWeightCap`. Rises with time unresolved.
        public let weight: Double
        /// Hours since the thing was first noticed.
        public let ageHours: Double
        /// True when one of HER standing views names it (D-2's lived gate);
        /// false when it was admitted on a shipped floor concern plus urgency.
        public let livedConcern: Bool
        /// Non-nil when this came from an external owner (the Desk) rather than
        /// from a thought seed. The `seedId` is then a stable synthetic id.
        public let externalId: String?

        public init(
            seedId: UUID,
            kind: CognitiveThoughtSeedKind,
            text: String,
            weight: Double,
            ageHours: Double,
            livedConcern: Bool,
            externalId: String? = nil
        ) {
            self.seedId = seedId
            self.kind = kind
            self.text = text
            self.weight = weight
            self.ageHours = ageHours
            self.livedConcern = livedConcern
            self.externalId = externalId
        }
    }

    /// The urgency the thing was NOTICED with — the seed's priority un-decayed
    /// back to its creation, clamped.
    ///
    /// Gating the floor path on the seed's CURRENT priority looks right and is
    /// wrong: seed priority halves every 24 hours, so a nag admitted on urgency
    /// would silently stop itching after a day — which is the exact decay this
    /// item exists to invert, reintroduced through the gate instead of the
    /// weight. The question the gate asks is "was this urgent when she noticed
    /// it", and that answer does not change with the clock. A seed re-asserted
    /// at higher priority clamps to 1, which reads as "recently reasserted, so
    /// yes".
    static func ruminationNoticePriority(_ seed: CognitiveThoughtSeed, at now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(seed.createdAt))
        guard thoughtSeedPriorityHalfLife > 0 else { return seed.priority.clamped01() }
        return (seed.priority * pow(2, age / thoughtSeedPriorityHalfLife)).clamped01()
    }

    /// An open thing an EXTERNAL owner holds — today, a Desk item she opened
    /// herself. Payload-free: an opaque id and a bounded label, nothing else
    /// crosses.
    ///
    /// WHY IT IS AT STAKE BY CONSTRUCTION. D-2's gate 1 admits a resolution on a
    /// person-or-promise path without asking the concern lexicon, because a
    /// commitment moving IS the stake. An item she opened, and has not closed,
    /// is that same shape from the other end: she said she would move this. So
    /// the external lane skips the concern gate exactly as gate 1 does, and the
    /// ADMISSION is the caller's — origin and status are canonical Desk facts
    /// that this module must not re-litigate from a title string.
    public struct CognitiveExternalRumination: Sendable, Equatable {
        /// Stable, opaque owner handle. Never rendered.
        public let id: String
        /// What it is, in her words, bounded and sanitized by the caller's
        /// side of the seam and again here.
        public let label: String
        /// When the owner last touched it. The weight is age since THIS, not
        /// since it opened: an item worked on yesterday is not a nag.
        public let lastTouchedAt: Date

        public init(id: String, label: String, lastTouchedAt: Date) {
            self.id = String(id.prefix(120))
            self.label = String(label.prefix(CognitiveSubstrate.externalRuminationLabelCharacters))
            self.lastTouchedAt = lastTouchedAt
        }
    }

    /// The weight law: an inverted decay. Pure.
    static func ruminationWeight(ageSeconds: TimeInterval) -> Double {
        guard ageSeconds >= ruminationMinimumAge, ruminationRiseHalfLife > 0 else { return 0 }
        let rise = 1 - pow(0.5, ageSeconds / ruminationRiseHalfLife)
        return (ruminationWeightCap * rise).clamped01()
    }

    /// Is a concern she holds at stake in this seed? The D-2 stakes gate,
    /// applied to a seed instead of a felt resolution: her own LIVED concerns
    /// admit on their own; the shipped floor admits only alongside urgency
    /// (see `ruminationFloorConcernPriorityGate`). No concern touched, no nag —
    /// an allowlist, failing closed on anything neither names.
    func ruminationStakes(
        for seed: CognitiveThoughtSeed,
        priority: Double,
        concerns: [AppraisalConcern]
    ) -> (atStake: Bool, lived: Bool) {
        let lower = seed.text.lowercased()
        guard !lower.isEmpty else { return (false, false) }
        var floorHit = false
        for concern in concerns where Self.concernMatches(concern, in: lower) {
            if concern.origin == .lived { return (true, true) }
            floorHit = true
        }
        return (floorHit && priority >= Self.ruminationFloorConcernPriorityGate, false)
    }

    /// What is itching right now — heaviest first, at most `ruminationCap`.
    ///
    /// PURE. `seeds` lets the frozen capsule path pass the seeds it already
    /// froze; nil reads the live projection at `now`.
    public func ruminationCandidates(
        at now: Date,
        seeds: [CognitiveThoughtSeed]? = nil
    ) -> [CognitiveRuminationRead] {
        guard configuration.enabled else { return [] }
        // The external lane does not need the seed family to be on: a Desk item
        // she opened is her own open loop whether or not seeds are enabled.
        let external = externalRuminationCandidates(at: now)
        guard configuration.thoughtSeedsEnabled else {
            return Array(external.prefix(Self.externalRuminationSlots))
        }
        let population = seeds ?? projectedThoughtSeeds(at: now)
        guard !population.isEmpty else {
            return Array(external.prefix(Self.externalRuminationSlots))
        }
        // CHEAP FILTERS FIRST, and a bounded scan. This read sits inside
        // `projectedAffect`, which runs several times per ingest, so the
        // expensive half (concern matching over her whole concern set) must see
        // a handful of seeds and never the whole family: oldest-first is
        // heaviest-first by construction, so the scan can stop as soon as the
        // cap is full.
        let eligible = population
            .filter {
                Self.ruminatingSeedKinds.contains($0.kind)
                    && ruminationReleasedAt[$0.id] == nil
                    && Self.ruminationWeight(
                        ageSeconds: now.timeIntervalSince($0.createdAt)
                    ) > 0
                    && isUsefulThoughtSeed($0)
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(Self.ruminationScanBound)
        guard !eligible.isEmpty else { return [] }
        let concerns = appraisalConcerns()
        let livedEvidence = livedEvidenceNodeIDs()
        var out: [CognitiveRuminationRead] = []
        for seed in eligible {
            // PROVENANCE (review fix, 2026-09-02). A seed carries no turn kind of
            // its own, so a seed minted off a `debug`/`verification` turn — bridge
            // pings, snapshot probes — could ruminate, and diagnostic traffic is
            // structurally excluded from lived state EVERYWHERE else (design law
            // 10). The seed's own evidence answers it: at least one source node
            // must still be in the field and be lived traffic.
            //
            // HONEST BOUND: a nag whose evidence has been evicted from working
            // memory stops nagging. That is the field's 256-node cap showing
            // through, and it is the conservative direction — a thing nothing in
            // her mind still holds is a thing that has genuinely faded.
            guard seed.sourceNodeIds.contains(where: { livedEvidence.contains($0) }) else { continue }
            let stakes = ruminationStakes(
                for: seed,
                priority: Self.ruminationNoticePriority(seed, at: now),
                concerns: concerns
            )
            guard stakes.atStake else { continue }
            let age = now.timeIntervalSince(seed.createdAt)
            out.append(CognitiveRuminationRead(
                seedId: seed.id,
                kind: seed.kind,
                text: seed.text,
                weight: Self.ruminationWeight(ageSeconds: age),
                ageHours: max(0, age) / 3_600,
                livedConcern: stakes.lived
            ))
            if out.count == Self.ruminationCap { break }
        }
        return Self.merged(seedCandidates: out, external: external)
    }

    /// Seeds first, then at most `externalRuminationSlots` from the Desk, then
    /// re-ranked by weight. The Desk cap is absolute rather than a fill rule:
    /// a stale Desk must never be able to take every slot, because the seeds
    /// are the half she noticed herself.
    static func merged(
        seedCandidates: [CognitiveRuminationRead],
        external: [CognitiveRuminationRead]
    ) -> [CognitiveRuminationRead] {
        let deskShare = Array(external.prefix(externalRuminationSlots))
        let seedShare = Array(seedCandidates.prefix(max(0, ruminationCap - deskShare.count)))
        return (seedShare + deskShare)
            .sorted { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                // Deterministic, and a seed leads a Desk item at equal weight.
                if (lhs.externalId == nil) != (rhs.externalId == nil) {
                    return lhs.externalId == nil
                }
                return lhs.seedId.uuidString < rhs.seedId.uuidString
            }
    }

    /// The external half, heaviest first. Same inverted-decay weight law, aged
    /// from the last time the owner touched the item.
    func externalRuminationCandidates(at now: Date) -> [CognitiveRuminationRead] {
        guard !externalRuminations.isEmpty else { return [] }
        var out: [CognitiveRuminationRead] = []
        for item in externalRuminations.values {
            let age = now.timeIntervalSince(item.lastTouchedAt)
            let weight = Self.ruminationWeight(ageSeconds: age)
            guard weight > 0 else { continue }
            out.append(CognitiveRuminationRead(
                seedId: externalRuminationSeedID(item.id),
                // A thing she owns and has not finished is a follow-up. The kind
                // is what makes `innerThoughtSeedLine` render it as `- Thread:`.
                kind: .followUp,
                text: item.label,
                weight: weight,
                ageHours: max(0, age) / 3_600,
                // Admitted by ownership, not by the concern lexicon — see
                // `CognitiveExternalRumination`.
                livedConcern: true,
                externalId: item.id
            ))
        }
        return out.sorted { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            return (lhs.externalId ?? "") < (rhs.externalId ?? "")
        }
    }

    func externalRuminationSeedID(_ id: String) -> UUID {
        stableArtifactID("external_rumination|\(id)")
    }

    // MARK: - The external set (pushed by the owner-side reader)

    /// Is the external set old enough to be worth re-reading? The caller holds
    /// the I/O; this holds the clock, so a turn can ask without touching disk.
    public func externalRuminationsAreStale(
        at now: Date,
        ttl: TimeInterval = CognitiveSubstrate.externalRuminationRefreshInterval
    ) -> Bool {
        guard configuration.enabled else { return false }
        guard let refreshedAt = externalRuminationsRefreshedAt else { return true }
        return now.timeIntervalSince(refreshedAt) >= ttl
    }

    /// Claim the refresh window BEFORE the read starts, so a burst of turns
    /// starts one Desk read rather than one each.
    public func noteExternalRuminationRefreshStarted(at now: Date) {
        externalRuminationsRefreshedAt = now
    }

    /// Replace the external set. Anything that was itching and is no longer in
    /// the set has CLOSED — its weight goes, and one relief is staged through
    /// the same door a seed release uses.
    ///
    /// HONEST BOUND: the set is in-memory, so after a restart the first push
    /// finds no prior set and an item that closed while the app was down mints
    /// no relief. Missed, never duplicated — the same at-most-once direction the
    /// seed lane's durable marker buys.
    public func setExternalRuminations(
        _ items: [CognitiveExternalRumination],
        at now: Date
    ) {
        guard configuration.enabled else { return }
        externalRuminationsRefreshedAt = now
        var next: [String: CognitiveExternalRumination] = [:]
        for item in items.prefix(Self.externalRuminationCap) {
            let label = capsuleSignalText(
                item.label,
                maxCharacters: Self.externalRuminationLabelCharacters
            )
            guard !label.isEmpty, isUsefulCapsuleSignalText(label) else { continue }
            next[item.id] = CognitiveExternalRumination(
                id: item.id,
                label: label,
                lastTouchedAt: item.lastTouchedAt
            )
        }
        // Heal what left the set — but only what had actually started to itch.
        // A thing closed the same hour it opened never nagged, so it owes no
        // relief (design law 4: no weight, no exhale).
        let closed = externalRuminations.keys.filter { next[$0] == nil }
        let itching = Set(externalRuminationCandidates(at: now).compactMap(\.externalId))
        for id in closed.sorted() where itching.contains(id) {
            guard let item = externalRuminations[id] else { continue }
            let weight = Self.ruminationWeight(
                ageSeconds: now.timeIntervalSince(item.lastTouchedAt)
            )
            stageRuminationRelief(externalRuminationReliefEvent(
                for: item, weight: weight, at: now
            ))
        }
        externalRuminations = next
    }

    /// Relief for a commitment she finished. Labelled `workflowAdvance` — D-2's
    /// own gate-1 vocabulary for "a piece of work she said she would move" —
    /// because that is exactly what closed. The seed lane keeps its `rumination`
    /// label and its aboutness gate; this one is admitted by the same rule the
    /// organism's workflow resolutions already are.
    private func externalRuminationReliefEvent(
        for item: CognitiveExternalRumination,
        weight: Double,
        at now: Date
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: "rumination_release:external:\(item.id)",
            kind: .organismResolutionFelt,
            subject: CognitiveSubjectReference(
                type: "organism_path",
                id: "desk#\(stableDigest(item.id).prefix(8))",
                label: OrganismPredictionKind.workflowAdvance.rawValue
            ),
            sourceClass: .selfReported,
            occurredAt: now,
            summary: "Relief — \(item.label) is closed.",
            importance: min(1, 0.4 + weight),
            metadata: [
                CognitiveEvent.feltValenceMetadataKey: .double(min(0.6, 0.15 + weight)),
                CognitiveEvent.feltArousalMetadataKey: .double(0.15),
                "resolutionKind": .string("relief"),
                "ruminationWeight": .double(weight),
            ]
        )
    }

    /// The itch, as two affect floors. Saturating in the number of things
    /// carried (`1 − Π(1 − w)`), so three small nags never sum into a crisis.
    /// Pure; returns zeros when nothing is itching, which keeps every existing
    /// affect read byte-identical.
    func ruminationPressureFloors(
        at now: Date,
        seeds: [CognitiveThoughtSeed]? = nil
    ) -> (uncertainty: Double, taskPressure: Double) {
        let candidates = ruminationCandidates(at: now, seeds: seeds)
        guard !candidates.isEmpty else { return (0, 0) }
        var carried = 1.0
        for candidate in candidates { carried *= (1 - candidate.weight) }
        let load = (1 - carried).clamped01() / Self.ruminationWeightCap
        let saturated = min(1, load)
        return (
            uncertainty: Self.ruminationUncertaintyFloorCeiling * saturated,
            taskPressure: Self.ruminationPressureFloorCeiling * saturated
        )
    }

    // MARK: - The `- Thread:` candidate (the seam the capsule builder consumes)

    /// THE SEAM. The seeds the `- Thread:` line may speak, heaviest first.
    ///
    /// CONTRACT FOR `+Capsule` (another fence — this side only publishes):
    /// these are ordinary `CognitiveThoughtSeed` values of a NON-takeaway kind,
    /// so `innerThoughtSeedLine(for:)` already renders them with the `- Thread:`
    /// prefix and the existing 180-char capsule bound. Append them to
    /// `innerCandidates` AFTER the standing-view and takeaway candidates and let
    /// the existing cadence ledger pick — the Inner/Thread line stays at most one
    /// per turn, and a nag never outranks a durable view.
    ///
    /// Empty whenever nothing is at stake, which is the common case.
    public func ruminationThreadSeeds(
        at now: Date,
        seeds: [CognitiveThoughtSeed]? = nil
    ) -> [CognitiveThoughtSeed] {
        let population = seeds ?? projectedThoughtSeeds(at: now)
        let byID = Dictionary(population.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ruminationCandidates(at: now, seeds: population).compactMap { candidate in
            if let seed = byID[candidate.seedId] { return seed }
            // An external candidate has no seed row. Synthesize the value the
            // capsule's existing renderer expects — it is never stored, never
            // persisted, and never enters the seed family; it exists so the
            // published seam stays one type and `+Capsule` needs no change.
            guard candidate.externalId != nil else { return nil }
            return CognitiveThoughtSeed(
                id: candidate.seedId,
                kind: candidate.kind,
                text: candidate.text,
                priority: candidate.weight,
                createdAt: now.addingTimeInterval(-candidate.ageHours * 3_600),
                lastUpdatedAt: now
            )
        }
    }

    // MARK: - Heal

    /// Release every itching seed the given text ANSWERS, clearing its weight.
    ///
    /// Synchronous and pure-ish by design: it runs inside the ingest hot
    /// segment (from `applyAffectFromEvent`), so it may mutate in-memory state
    /// but must never suspend. The relief felt-moments it mints are STAGED here
    /// and drained by the runtime (`drainRuminationReleaseEvents`), mirroring how
    /// the organism stages its own resolution felt-moments.
    ///
    /// "Answers" is deliberately strict: the text must name at least two of the
    /// seed's own distinctive terms (the same term extractor the lived-concern
    /// derivation uses). One shared long word is a coincidence; two is a reply.
    @discardableResult
    func releaseAnsweredRuminations(answeredBy text: String, at now: Date) -> [UUID] {
        guard text.count >= 8 else { return [] }
        let spoken = Self.ruminationTokens(in: text)
        guard spoken.count >= 3 else { return [] }
        let floorKeywords = Set(
            appraisalConcernFloor().flatMap(\.keywords).map { $0.lowercased() }
        )
        var released: [UUID] = []
        for candidate in ruminationCandidates(at: now) {
            guard Self.answers(
                candidate.text,
                withSpokenTokens: spoken,
                floorKeywords: floorKeywords
            ) else { continue }
            released.append(candidate.seedId)
            noteRuminationRelease(candidate, at: now)
        }
        return released
    }

    /// Word-boundary tokens, lowercased. SUBSTRING MATCHING WAS THE BUG (review
    /// fix, 2026-09-02): `contains("broke")` fires on "brokerage", `contains
    /// ("logs")` on "dialogs", and the detector answered things nobody answered.
    /// A word is a word.
    static func ruminationTokens(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
    }

    /// Does what was just said actually ANSWER this thing?
    ///
    /// Three conditions, all of them narrowing:
    ///   • the seed's own distinctive terms, minus this system's shop talk
    ///     (`ruminationDomainStopWords`) — "the sync verify failed" and "verify
    ///     the deploy" share a word, not a subject;
    ///   • at least two of them spoken, as whole words;
    ///   • at least one of those hits RARE — not a shipped floor-concern keyword.
    ///     Floor keywords are identical on every install, so two floor hits are
    ///     evidence of a common vocabulary, not of a reply.
    /// Fails closed: a thing that is not clearly answered keeps itching, which
    /// is the direction a nag should err in.
    static func answers(
        _ seedText: String,
        withSpokenTokens spoken: Set<String>,
        floorKeywords: Set<String>
    ) -> Bool {
        let terms = appraisalConcernTerms(in: seedText)
            .filter { !ruminationDomainStopWords.contains($0) }
        guard terms.count >= 2 else { return false }
        let hits = terms.filter { spoken.contains($0) }
        guard hits.count >= 2 else { return false }
        return hits.contains { !floorKeywords.contains($0) }
    }

    /// Node ids that are BOTH still in the field and lived (not debug or
    /// verification traffic). Pure; the field's cached turn kind is the same
    /// resolver workspace eligibility uses, so the two cannot disagree.
    private func livedEvidenceNodeIDs() -> Set<UUID> {
        var out: Set<UUID> = []
        for node in field.peekNodes()
        where field.cachedTurnKind(for: node).contributesToLivedState {
            out.insert(node.id)
        }
        return out
    }

    /// Release one seed by id — the "resolution/followUp closed" half. Called
    /// when a seed physically leaves the family for a reason other than decay.
    @discardableResult
    func releaseRumination(seedId: UUID, at now: Date) -> Bool {
        guard let candidate = ruminationCandidates(at: now).first(where: { $0.seedId == seedId })
        else { return false }
        noteRuminationRelease(candidate, at: now)
        return true
    }

    /// Mark released, drop the seed, and stage the relief. One place, so the
    /// weight can never clear without the exhale (or the exhale fire twice).
    private func noteRuminationRelease(_ candidate: CognitiveRuminationRead, at now: Date) {
        ruminationReleasedAt[candidate.seedId] = now
        pruneRuminationReleases(at: now)
        if thoughtSeeds.removeValue(forKey: candidate.seedId) != nil {
            // The microcycle persists the whole seed family, so the removal is
            // durable at the next settle without opening a write here.
            thoughtSeedRevision &+= 1
        }
        stageRuminationRelief(ruminationReliefEvent(for: candidate, at: now))
    }

    /// One staging door, one bound. Capped drop-oldest so an organism-off
    /// install that never drains can never grow this.
    private func stageRuminationRelief(_ event: CognitiveEvent) {
        pendingRuminationReleases.append(event)
        if pendingRuminationReleases.count > Self.pendingRuminationReleaseCap {
            pendingRuminationReleases.removeFirst(
                pendingRuminationReleases.count - Self.pendingRuminationReleaseCap
            )
        }
    }

    private func pruneRuminationReleases(at now: Date) {
        guard ruminationReleasedAt.count > 32 else { return }
        ruminationReleasedAt = ruminationReleasedAt.filter {
            now.timeIntervalSince($0.value) < Self.ruminationReleaseMemory
        }
    }

    /// The relief, shaped exactly like the organism's own: the measured-felt
    /// door, valence sized to the weight that was actually carried, and the
    /// D-2 stakes gate deciding whether it becomes a felt node at all. A nag
    /// she formed from her OWN view heals audibly; one admitted on a shipped
    /// floor concern simply stops itching. That asymmetry is the gate working,
    /// not a gap.
    private func ruminationReliefEvent(
        for candidate: CognitiveRuminationRead,
        at now: Date
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: "rumination_release:\(candidate.seedId.uuidString)",
            kind: .organismResolutionFelt,
            subject: CognitiveSubjectReference(
                type: "organism_path",
                id: "rumination#\(candidate.seedId.uuidString.prefix(8))",
                // NOT an OrganismPredictionKind raw value, so D-2 gate 1 refuses
                // it and it must earn admission on aboutness like anything else.
                label: "rumination"
            ),
            sourceClass: .selfReported,
            occurredAt: now,
            summary: "Relief — \(bounded(candidate.text, maxCharacters: 160)) is answered.",
            importance: min(1, 0.4 + candidate.weight),
            metadata: [
                CognitiveEvent.feltValenceMetadataKey: .double(
                    min(0.6, 0.15 + candidate.weight)
                ),
                CognitiveEvent.feltArousalMetadataKey: .double(0.15),
                "resolutionKind": .string("relief"),
                "ruminationWeight": .double(candidate.weight),
            ]
        )
    }

    /// The runtime's drain — peer of `OrganismKernel.drainResolutionFelt()`.
    /// Each returned event goes straight back through `ingestResident`, where
    /// the D-2 stakes gate decides whether it becomes a felt node.
    ///
    /// DURABLE BEFORE IT LEAVES (review fix, 2026-09-02). The release ledger and
    /// the seed removal were both memory-only, and the seed family is not
    /// persisted until the next microcycle — so a crash in that window restored
    /// the seed, let it nag again, and let the SAME thing heal a second time.
    /// The marker is written here, keyed by seed id, BEFORE any event is handed
    /// out, which makes the whole lane at-most-once across a crash:
    ///   • crash before this write → the seed returns and may be answered again;
    ///     one relief, later. No duplicate.
    ///   • crash after it, before the event is ingested → the marker keeps the
    ///     seed out of the lane; the relief NODE is lost, the healing is not.
    /// The relief event id is itself keyed on the seed, so even a replay inside
    /// the field's seen-event horizon is inert (design law 9).
    public func drainRuminationReleaseEvents() async -> [CognitiveEvent] {
        guard !pendingRuminationReleases.isEmpty else { return [] }
        await persistPendingRuminationReleases()
        let drained = pendingRuminationReleases
        pendingRuminationReleases.removeAll()
        return drained
    }

    /// One durable marker per released seed, plus the seed removal the marker
    /// describes. Through the existing artifact door — no new store, no new
    /// table, and the same stable-id shape disposition and affect already use.
    private func persistPendingRuminationReleases() async {
        guard configuration.enabled, configuration.persistenceEnabled else { return }
        let now = dependencies.now()
        for (seedId, releasedAt) in ruminationReleasedAt.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard now.timeIntervalSince(releasedAt) < Self.ruminationReleaseMemory else { continue }
            await persistArtifact(
                kind: "rumination_release",
                id: stableArtifactID("rumination_release|\(seedId.uuidString)"),
                status: "released",
                score: 0,
                payload: .object([
                    "seedId": .string(seedId.uuidString),
                    "releasedAt": .double(releasedAt.timeIntervalSince1970),
                ])
            )
        }
        // The removal itself, so a restart does not restore a seed this lane has
        // already closed.
        try? await persistThoughtSeedFamily()
    }

    /// Rehydrate the ledger, and drop any seed a marker says was already
    /// released. Called from `applyRestoreBundle` AFTER `restoreThoughtSeeds`.
    func restoreRuminationReleases(from payloads: [JSONValue]) {
        ruminationReleasedAt.removeAll(keepingCapacity: true)
        let now = dependencies.now()
        for payload in payloads {
            guard case .object(let object) = payload,
                  let seedId = uuidValue(object["seedId"]),
                  let releasedAt = dateValue(object["releasedAt"]) else { continue }
            guard now.timeIntervalSince(releasedAt) < Self.ruminationReleaseMemory else { continue }
            ruminationReleasedAt[seedId] = releasedAt
            thoughtSeeds.removeValue(forKey: seedId)
        }
    }

    /// Diagnostic/Observatory read: what is itching, at the live instant.
    public func ruminationSnapshot() async -> [CognitiveRuminationRead] {
        ruminationCandidates(at: dependencies.now())
    }
}

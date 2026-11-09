import Foundation
import NativeAgentCore
import Context
import PersistenceCore
import TurnTrace
// Blueprint: | `CognitiveSubstrate+CaresMind.swift` | `CognitiveSubstrate`: care pressure, turn cues, the stories attention reads and the hour's wondering |

// One story-derived pressure must serve cues, intentions and the hour.

/// The cares still pulling at this moment, read from the frozen story.
struct CognitiveCareCue: Sendable {
    var pulls: [CognitiveCare]
}

extension CognitiveSubstrate {
    public static let careReleasePressure = 0.35
    static let dateLedgerCapacity = 16
    static let careLineRestTurns = 6
    static let careMindPrefix = "- On your mind:"
    static let careIntentionPrefix = "- You've been wanting to bring up"
    static let caresForHourLimit = 3

    // MARK: - Pressure

    /// Open gaps add half again to charge so unfinished concerns press harder.
    public static func carePressure(_ care: CognitiveCare, at now: Date) -> Double {
        care.pressure(at: now)
    }

    /// Cares held with this speaker or the agent's alone, most pressing first. A nil speaker (the agent's own wake, a sender with no person key) has only the
    /// agent's.
    public func caresPressing(for speaker: String?, at now: Date) -> [(care: CognitiveCare, pressure: Double)] {
        guard configuration.enabled else { return [] }
        return Self.caresPressing(among: Array(cares.values),
            for: speaker.map { CognitiveCareProvenance.personKey($0, aliases: carePersonAliases) }
                .flatMap { carePeopleReadFailure == nil || CognitiveCareProvenance.independentPersonKey($0) ? $0 : nil }, at: now)
    }

    private static func caresPressing(among candidates: [CognitiveCare], for speaker: String?, at now: Date)
        -> [(care: CognitiveCare, pressure: Double)] {
        let key = speaker.map(CognitiveCareProvenance.personKey)
        return candidates
            .filter { $0.fadedAt == nil && ($0.with.isEmpty || key.map($0.with.contains) == true) }
            .map { ($0, Self.carePressure($0, at: now)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.updatedAt > $1.0.updatedAt }
    }

    /// Cosine of `text` to each care, embedding only the cares whose cached vector is stale. nil while the embedder is cold: the warm one is never loaded for
    /// this.
    func careCosines(to text: String, among candidates: [CognitiveCare], turn: Turn?) async throws -> [UUID: Double]? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !candidates.isEmpty else { return [:] }
        guard let lookup = try await careVectorLookup(queries: [query], among: candidates, turn: turn),
              let queryVector = lookup.queries[query] else { return nil }
        return lookup.cares.mapValues { VectorMath.cosine(queryVector, $0) }
    }

    /// One embedder batch for new words and stale care texts; all other vectors are reused. Callers retain the returned snapshot across suspension.
    func careVectorLookup(queries: [String], among candidates: [CognitiveCare], turn: Turn?) async throws
        -> (epoch: String, queries: [String: [Float]], cares: [UUID: [Float]])? {
        // Score against these candidates even if another lookup changes the resident cache while embedding suspends.
        var selected: [UUID: [Float]] = [:]
        var stale: [CognitiveCare] = []
        let epoch = mindEpoch
        // No warm identity means no cache admission. Still ask the checked embedder: it distinguishes a cold model from unreadable configuration.
        let embeddingEpoch = await dependencies.embeddingEpoch()
        for care in candidates {
            if let embeddingEpoch, let cached = careVectors[care.id], cached.epoch == embeddingEpoch,
               cached.text == Self.careEmbeddingText(care) {
                selected[care.id] = cached.vector
            } else { stale.append(care) }
        }
        let staleEpochs = Set(stale.compactMap { careVectors[$0.id]?.epoch })
        let queries = Array(Set(queries)).sorted()
        guard let batch = try await dependencies.embedTexts(queries + stale.map(Self.careEmbeddingText)) else { return nil }
        if let embeddingEpoch, batch.epoch != embeddingEpoch {
            throw CognitiveCareNotSaved(detail: "The resident embedding epoch changed during care lookup; these vectors cannot be compared.")
        }
        let vectors = batch.vectors
        guard vectors.count == stale.count + queries.count else {
            throw CognitiveCareNotSaved(detail: """
                The resident embedder returned the wrong number of vectors; repair the embedding owner before interpreting cares.
                """)
        }
        for (care, vector) in zip(stale, vectors.dropFirst(queries.count)) {
            selected[care.id] = vector
            if !forgettingInFlight, mindEpoch == epoch {
                careVectors[care.id] = (Self.careEmbeddingText(care), batch.epoch, vector)
            }
        }
        TurnTraceBus.fireFromContext(kind: "care.vector_lookup", payload: .object([
            "embeddingEpoch": .string(batch.epoch),
            "reused": .int(Int64(candidates.count - stale.count)),
            "recomputed": .int(Int64(stale.count)),
            "invalidatedEpochs": .array(staleEpochs.filter { $0 != batch.epoch }.sorted().map { .string($0) }),
        ]), turn: turn)
        return (batch.epoch, Dictionary(uniqueKeysWithValues: zip(queries, vectors.prefix(queries.count))), selected)
    }

    /// Birth and night share recall's two-deviation meaning bar, rather than the stricter chance bar for unsolicited attention. Every care contributes to the
    /// background; eligibility only limits which care may be selected.
    static func careMeaningStanding(_ cosines: [UUID: Double], among inventory: [CognitiveCare])
        -> [(care: CognitiveCare, deviation: Double)] {
        let scored = inventory.compactMap { care in cosines[care.id].map { (care, $0) } }
        let standing = VectorMath.standout(scored.map { $0.1 })
        return scored.indices.compactMap { index in
            guard let deviation = standing[index],
                  deviation >= ContextSelectionConfiguration.memoryStandoutDeviations else { return nil }
            return (care: scored[index].0, deviation: deviation)
        }.sorted { $0.deviation != $1.deviation ? $0.deviation > $1.deviation : $0.care.id.uuidString < $1.care.id.uuidString }
    }

    // MARK: - The turn

    /// Recent charge is enough to be on her mind. Reachability is supplied by the turn's privacy and suppression owner.
    func careCue(for request: CognitiveCapsuleRequest, from read: CognitiveFrozenRead,
                 among reachable: [CognitiveCare], unreadable _: inout [String], turn _: Turn) async -> CognitiveCareCue? {
        guard read.configuration.enabled,
              read.configuration.capsuleInjectionEnabled,
              request.mode == .inject,
              request.resolvedTurnKind == .live,
              !reachable.isEmpty else { return nil }
        let pulls = reachable.filter { Self.carePull($0) != nil }.sorted {
            let left = abs($0.charge(at: read.fixedAt)), right = abs($1.charge(at: read.fixedAt))
            if left != right { return left > right }
            return $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString
        }
        return pulls.isEmpty ? nil : CognitiveCareCue(pulls: Array(pulls.prefix(2)))
    }

    /// A judged response eases a pull; showing it is not evidence she acted on it.
    func careCueLines(
        _ cue: CognitiveCareCue,
        message _: String,
        gapOpened _: Date?,
        resting _: [String: CognitiveCapsulePresentationState.CareLineRest],
        at now: Date,
        presentationState _: inout CognitiveCapsulePresentationState,
        why: inout CapsuleCueWhy
    ) -> [String] {
        return cue.pulls.compactMap { care in
            guard let moment = Self.carePull(care) else { return nil }
            let line = careMindLine(care, moment: moment)
            why.sources[line] = "care:" + care.id.uuidString
            why.scores[line] = abs(care.charge(at: now))
            return line
        }
    }

    /// Only a subsequent lived response spends a movement. Missing interpretation leaves it open.
    static func carePull(_ care: CognitiveCare) -> CognitiveCare.Moment? {
        guard let movement = care.story.last(where: { $0.moved != 0 }) else { return nil }
        let answered = care.story.contains {
            $0.by == .her && ($0.at > movement.at || ($0.at == movement.at && $0.source == movement.source))
                && ($0.answered == true || $0.closedGap == true)
        }
        return answered ? nil : movement
    }

    func careMindLine(_ care: CognitiveCare, moment: CognitiveCare.Moment) -> String {
        let subject = care.origin == .seed ? moment.note : care.about
        let line = Self.careMindPrefix + " Under this moment, \(moment.felt): \(subject)"
        return capsuleLineText(line, maxCharacters: 280)
    }

    /// The cares `text` touches, closest first (`caresStandingOut`), on the warm vector cache. nil while the embedder is cold.
    func caresTouched(by text: String, among candidates: [CognitiveCare], turn: Turn) async throws -> [CognitiveCare]? {
        guard let cosines = try await careCosines(to: text, among: candidates, turn: turn) else { return nil }
        return Self.caresStandingOut(cosines, among: candidates).map(\.care)
    }

    /// Use relative cosine standing, not an absolute floor: high shared similarity moves the mean. All candidates count; eligibility only limits selection.
    static func caresStandingOut(_ cosines: [UUID: Double], among candidates: [CognitiveCare],
                                 eligible: (CognitiveCare) -> Bool = { _ in true })
        -> [(care: CognitiveCare, cosine: Double)] {
        let values = candidates.compactMap { care in cosines[care.id].map { (care: care, cosine: $0) } }
        return standingOut(values.map(\.cosine)).compactMap { index in
            eligible(values[index].care) ? values[index] : nil
        }
    }

    /// The one attention law for cares and world-moment intentions. No absolute cosine floor: each must stand out from the others past chance.
    private static func standingOut(_ cosines: [Double]) -> [Int] {
        let bar = VectorMath.chanceBar(.attention, among: cosines.count)
        let standing = VectorMath.standout(cosines)
        return cosines.indices.filter { standing[$0].map { $0 >= bar } ?? false }
            .sorted { cosines[$0] > cosines[$1] }
    }

    /// A watch line weighs open news intentions by the care law. Live, unsilenced cares remain among the comparisons, so even one intention has others to stand
    /// against. The same warm-only embedder judges both.
    package func newsIntentionsTouched(by line: String, among intentions: [(id: String, words: String)]) async -> [String]? {
        guard !intentions.isEmpty else { return [] }
        guard configuration.enabled else { return nil }
        let query = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let terms = Self.associationTerms(in: query)
        let live = cares.values.filter {
            $0.fadedAt == nil && !isSuppressed("care:" + $0.id.uuidString, messageTerms: terms)
        }
        let careScores: [UUID: Double]
        let vectors: [[Float]]
        do {
            guard let lookup = try await careVectorLookup(queries: [query] + intentions.map(\.words), among: live, turn: nil),
                  let queryVector = lookup.queries[query] else { return nil }
            careScores = lookup.cares.mapValues { VectorMath.cosine(queryVector, $0) }
            vectors = [queryVector] + (try intentions.map { intention in
                guard let vector = lookup.queries[intention.words] else {
                    throw CognitiveCareNotSaved(detail: "The resident embedder omitted an intention vector.")
                }
                return vector
            })
        } catch { oweCareEmbedding(error); return nil }
        let background = live.compactMap { careScores[$0.id] }
        let scores = background + vectors.dropFirst().map { VectorMath.cosine(vectors[0], $0) }
        return Self.standingOut(scores).compactMap { index in
            index >= background.count ? intentions[index - background.count].id : nil
        }
    }

    static func isCareCueLine(_ line: String) -> Bool {
        line.hasPrefix(careMindPrefix) || line.hasPrefix(careIntentionPrefix)
    }

    /// One accepted turn of rest for every plain care line; returns the rests as they stood before this turn.
    static func advanceCareLineRest(
        _ rests: inout [String: CognitiveCapsulePresentationState.CareLineRest]
    ) -> [String: CognitiveCapsulePresentationState.CareLineRest] {
        let before = rests
        for (key, rest) in before {
            rests[key] = rest.turnsLeft > 1 ? .init(shownAt: rest.shownAt, turnsLeft: rest.turnsLeft - 1) : nil
        }
        return before
    }

    static func boundDateLedger(_ ledger: inout [String: Date]) {
        guard ledger.count > dateLedgerCapacity else { return }
        for key in ledger.sorted(by: { $0.value < $1.value }).prefix(ledger.count - dateLedgerCapacity).map(\.key) {
            ledger.removeValue(forKey: key)
        }
    }

    // MARK: - What attention reads

    /// Every care with its story, for the runtime that posts each new judged movement. Nil while inner life is off: nothing moves then.
    public func careStories() -> [CognitiveCare]? {
        configuration.enabled ? Array(cares.values) : nil
    }

    /// A care wake lives only the agent's side against the care(s) that woke the agent. Meaning is already journaled; applyCares keeps the fold's
    /// watermark, so its save can be finished after a crash.
    func foldCareWake(_ context: AfterTurnContext, judgments: [CognitiveCareJudgment],
                      seq: UInt64, momentID: String) async throws {
        await waitForMaintenanceTransition()
        guard configuration.enabled, context.mindEpoch == mindEpoch else { return }
        let ids = Set(context.careWakes.compactMap { CognitiveCare.survivorID(for: $0.careID, among: cares) })
        let admitted = judgments.filter { judgment in
            guard judgment.by == .her, case .existing(let id) = judgment.target,
                  let survivor = CognitiveCare.survivorID(for: id, among: cares) else { return false }
            return ids.contains(survivor)
        }
        let event = context.event
        let provenance = CognitiveCareProvenance(speaker: "self", trusted: true, appAuthored: true,
            source: "exchange:\(event.sessionId ?? "")/\(event.metadata["messageId"]?.stringValue ?? event.subject.id)",
            at: event.occurredAt)
        _ = try await applyCares(admitted, provenance: provenance,
            generation: caringAppraisalGeneration, seq: seq, momentID: momentID)
    }

    // MARK: - The wander hour

    /// The authored care name decides where a concern belongs; similarity cannot overrule it, and life roots cannot hold open questions.
    public func pinConcern(_ text: String? = nil, in named: String? = nil, source: String) async throws -> String? {
        guard configuration.enabled else { return nil }
        let generation = caringAppraisalGeneration
        let pressing = caresPressing(for: nil, at: dependencies.now())
            .first { $0.pressure > 0 && $0.care.origin != .seed }?.care
        guard let concern = (text ?? pressing?.open ?? pressing?.about)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !concern.isEmpty else { return nil }
        let trimmed = named?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words: String? = trimmed.isEmpty ? nil : trimmed
        let holder: CognitiveCare?
        if let words {
            let key = Self.normalizedCareText(words)
            holder = cares.values.first { $0.origin != .seed && Self.normalizedCareText($0.about) == key }
        } else {
            holder = text == nil ? pressing : nil
        }
        let target: CognitiveCareJudgment.Target = holder.map { .existing($0.id) }
            ?? .new(about: String((words ?? careTitle(from: concern)).prefix(CognitiveCare.aboutCharacters)), between: false)
        let saved = try await applyCares([
            .init(target: target, moved: 0, by: .her, felt: "kept open", note: "pinned concern", open: concern)
        ], provenance: .init(speaker: CognitiveCare.ownerKey, trusted: true, appAuthored: true,
                            source: source, at: dependencies.now()), generation: generation)
        return saved.isEmpty ? nil : concern
    }

    /// A break in the person's day is lived, never a request to reach the person. The felt event's usual stakes gate admits it; its story note moves exactly
    /// zero, opens nothing, and never wakes or releases an intention. Replaying a pending break completes its story even if the event was already ingested.
    public func feelRhythmBreak(_ event: CognitiveEvent) async throws -> Bool {
        guard configuration.enabled, event.subject.type == "person_rhythm", event.kind == .organismResolutionFelt else { return false }
        let admitted = await ingestResident(event)
        guard admitted.accepted || field.hasSeenEvent(event) else { return false }
        await waitForMaintenanceTransition()
        if let kept = cares.values.first(where: { $0.story.contains(where: { $0.source == event.id }) }) {
            try await saveCares([kept.id], at: dependencies.now()).get()
            return true
        }
        let touched = try await appraisalCares(in: event.summary)
        guard let target = touched.first, cares[target.id]?.fadedAt == nil else { return true }
        let judgment = CognitiveCareJudgment(target: .existing(target.id), moved: 0, by: .her,
                                             felt: "noticed", note: event.summary)
        let provenance = CognitiveCareProvenance(speaker: CognitiveCare.ownerKey, trusted: true,
            appAuthored: true, source: event.id, at: event.occurredAt)
        _ = try await applyCares([judgment], provenance: provenance, generation: caringAppraisalGeneration)
        return true
    }

    public func caresForHour() -> (cares: [CognitiveCare], generation: UInt64) {
        let offered = caresPressing(for: nil, at: dependencies.now())
            .filter { $0.care.open != nil }
            .prefix(Self.caresForHourLimit)
            .map(\.care)
        return (offered, caringAppraisalGeneration)
    }

    /// The hour names the care it continues; otherwise its question starts a care. Both paths retain the hour as a story source.
    public func noteHourWondering(_ question: String, topic: String?, continuing: UUID?, generation: UInt64, source: String) async throws -> Bool {
        guard configuration.enabled else { throw CognitiveCareNotSaved(detail: "the inner life is off") }
        await waitForMaintenanceTransition()
        // Save a repeated hour's resident story entry before acknowledging durability.
        if let kept = cares.values.first(where: { $0.story.contains(where: { $0.source == source }) }) {
            try await saveCares([kept.id], at: dependencies.now()).get()
            return true
        }
        var match: CognitiveCare?
        if let continuing, let care = cares[continuing], care.origin != .seed { match = care }
        let target: CognitiveCareJudgment.Target = match.map { .existing($0.id) }
            ?? .new(about: String((topic ?? careTitle(from: question)).prefix(CognitiveCare.aboutCharacters)),
                    between: false)
        let judgment = CognitiveCareJudgment(
            target: target, moved: 0.5, by: .her, felt: "curious",
            note: "my hour" + (topic.map { ": \($0)" } ?? ""), open: question)
        let provenance = CognitiveCareProvenance(
            speaker: CognitiveCare.ownerKey, trusted: true, appAuthored: true, source: source, at: dependencies.now())
        let saved = try await applyCares([judgment], provenance: provenance, generation: generation)
        return !saved.isEmpty
    }
}

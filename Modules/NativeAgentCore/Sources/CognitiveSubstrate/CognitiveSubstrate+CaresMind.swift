import Foundation
import NativeAgentCore
import Context
import PersistenceCore
import TurnTrace
// Blueprint: | `CognitiveSubstrate+CaresMind.swift` | `CognitiveSubstrate`: care pressure, turn cues, watch attention and habituation |

// One story-derived pressure must serve cues, intentions, Reach and the hour.

/// The cares one turn's capsule may voice, read before the frozen render because touching needs the embedder and the render is synchronous.
struct CognitiveCareCue: Sendable {
    var touched: [CognitiveCare]
    var pressing: (care: CognitiveCare, pressure: Double)?
    /// At most one of the agent's own traits, grounded in a care this moment touched.
    var trait: (care: CognitiveCare, line: String)?
}

public enum CognitiveCareTouch: Sendable {
    case touches(CognitiveCare, resting: Bool)
    case untouched
    /// Nothing could judge it, so nothing says it does not matter.
    case unweighed
}

extension CognitiveSubstrate {
    public static let careReleasePressure = 0.35
    /// A surfaced care rests unless a later movement makes it relevant again.
    package static let careReleaseRest: TimeInterval = 12 * 3_600
    static let dateLedgerCapacity = 16
    /// A touched care's plain line needs this much charge to be on the agent's mind, and then rests this many accepted turns unless it moved again since.
    static let careLineCharge = 0.15
    static let careLineRestTurns = 6
    static let careWindingDownWords = 8
    static let careMindPrefix = "- On your mind:"
    static let careIntentionPrefix = "- You've been wanting to bring up"
    static let caresForHourLimit = 3

    // MARK: - Pressure

    /// Open gaps add half again to charge so unfinished concerns press harder.
    public static func carePressure(_ care: CognitiveCare, at now: Date) -> Double {
        guard care.depth != .life || care.open != nil else { return 0 }
        return abs(care.charge(at: now)) * (care.open != nil ? 1.5 : 1.0)
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

    /// What this turn could have on the agent's mind: the cares the message touches and the one pressing hardest for this speaker. A care held with someone
    /// else is never in a peer's turn; the owner's turn may touch any. One embedding of the message, on the same gates the dream lookup keeps.
    func careCue(for request: CognitiveCapsuleRequest, from read: CognitiveFrozenRead,
                 among reachable: [CognitiveCare], unreadable: inout [String], turn: Turn) async -> CognitiveCareCue? {
        guard read.configuration.enabled,
              read.configuration.capsuleInjectionEnabled,
              request.mode == .inject,
              request.resolvedTurnKind == .live,
              !reachable.isEmpty else { return nil }
        let touched: [CognitiveCare]
        do { touched = try await caresTouched(by: request.userMessage, among: reachable, turn: turn) ?? [] }
        catch { unreadable.append("care meaning (" + error.localizedDescription + ")"); oweCareEmbedding(error); return nil }
        let pressing = Self.caresPressing(among: reachable,
            for: request.speaker.map { CognitiveCareProvenance.personKey($0, aliases: read.carePersonAliases) }, at: read.fixedAt)
            .first { $0.pressure > 0 }
        guard !touched.isEmpty || pressing != nil else { return nil }
        let inventory = Dictionary(read.cares.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func supportingCare(_ ref: String) -> UUID? {
            CognitiveSelfKnowledge.survivorReference(ref, among: inventory).flatMap { CognitiveSelfKnowledge.careID(for: $0) }
        }
        let trait = touched.lazy.compactMap { care -> (care: CognitiveCare, line: String)? in
            guard let trait = read.selfTraits.first(where: { trait in
                trait.shownBy.contains { supportingCare($0) == care.id }
                    // A trait spanning another person's private cares cannot leak through the one care this speaker can touch.
                    && trait.shownBy.allSatisfy { ref in
                        reachable.contains { $0.id == supportingCare(ref) }
                    }
            }) else { return nil }
            return (care, trait.line)
        }.first
        return CognitiveCareCue(touched: touched, pressing: pressing, trait: trait)
    }

    /// A pressing care speaks once per 12h; a touched care rests six turns. Either rest ends when an outside movement renews it.
    func careCueLines(
        _ cue: CognitiveCareCue,
        message: String,
        gapOpened: Date?,
        resting: [String: CognitiveCapsulePresentationState.CareLineRest],
        at now: Date,
        presentationState: inout CognitiveCapsulePresentationState,
        why: inout CapsuleCueWhy
    ) -> [String] {
        var lines: [(line: String, care: CognitiveCare)] = []
        if let care = cue.pressing?.care, let pressure = cue.pressing?.pressure, pressure >= Self.careReleasePressure {
            let words = message.split(whereSeparator: \.isWhitespace).count
            let windingDown = words <= Self.careWindingDownWords && !message.contains("?")
            let stepFrom = cue.touched.contains { $0.id == care.id }
            let rested = Self.careRested(care, since: presentationState.careReleased[care.id.uuidString], at: now)
            if rested, gapOpened != nil || windingDown || stepFrom {
                // Name the actual gap or movement, never an abstract root value.
                let thing = care.open ?? care.story.last(where: { $0.moved != 0 })?.note ?? care.about
                let line = Self.careIntentionPrefix + " \(thing)"
                    + " — this is a natural moment to, in your own way."
                lines.append((capsuleLineText(line, maxCharacters: 280), care))
                why.careIntention = lines[0].line
                presentationState.careReleased[care.id.uuidString] = now
                Self.boundDateLedger(&presentationState.careReleased)
            }
        }
        let onMind = cue.touched.first { care in
            !lines.contains { $0.care.id == care.id }
                && (abs(care.charge(at: now)) >= Self.careLineCharge || cue.trait?.care.id == care.id)
                && resting[care.id.uuidString].map { rest in
                    care.story.contains { $0.at > rest.shownAt && $0.by != .her }
                } ?? true
        }
        if let care = onMind {
            let line = cue.trait.flatMap { $0.care.id == care.id ? Self.careMindPrefix + " " + $0.line : nil }
                ?? careMindLine(care)
            lines.append((line, care))
            presentationState.careLineRest[care.id.uuidString] = .init(shownAt: now, turnsLeft: Self.careLineRestTurns)
        }
        for (line, care) in lines {
            why.sources[line] = "care:" + care.id.uuidString
            if let pressing = cue.pressing, pressing.care.id == care.id { why.scores[line] = pressing.pressure }
        }
        return lines.map(\.line)
    }

    /// Only a real newest movement can supply the felt word; absent evidence stays unspoken.
    func careMindLine(_ care: CognitiveCare) -> String {
        let newest = care.story.last { $0.moved != 0 }
        let felt = newest?.felt
        // A root speaks through what last moved it, never its own title.
        let subject = care.origin == .seed ? (newest?.note ?? care.about) : care.about
        let line = Self.careMindPrefix + " \(subject)" + (felt.map { " (\($0))" } ?? "")
            + (care.stance.map { " — I think: \($0.text)" } ?? "")
            + (care.open.map { " — still wondering: \($0)" } ?? "")
        return capsuleLineText(line, maxCharacters: 280)
    }

    /// Brought up at `said`, a care rests 12 h, or until someone or something other than the agent moved it since.
    static func careRested(_ care: CognitiveCare, since said: Date?, at now: Date) -> Bool {
        guard let said else { return true }
        return now.timeIntervalSince(said) >= careReleaseRest || care.story.contains { $0.at > said && $0.by != .her }
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

    // MARK: - What crosses into the agent's mind

    /// Life roots compare but cannot win watch attention. A prior wake rests; disabled, empty or cold readings remain unweighed.
    public func careTouched(by line: String, watch: String) async -> CognitiveCareTouch {
        let live = cares.values.filter { $0.fadedAt == nil }
        let now = dependencies.now()
        guard configuration.enabled, !live.isEmpty else {
            Self.traceCrossing(line, watch: watch, outcome: configuration.enabled ? "unweighed: no live cares" : "unweighed: inner life off", at: now)
            return .unweighed
        }
        let terms = Self.associationTerms(in: line)
        let weighed = live.filter { !isSuppressed("care:" + $0.id.uuidString, messageTerms: terms) }
        let cosines: [UUID: Double]
        do {
            guard let scored = try await careCosines(to: line, among: weighed, turn: nil) else {
                Self.traceCrossing(line, watch: watch, outcome: "unweighed: embedder cold", at: now)
                return .unweighed
            }
            cosines = scored
        } catch {
            oweCareEmbedding(error)
            Self.traceCrossing(line, watch: watch, outcome: "unweighed: embedding failed: \(error.localizedDescription)", at: now)
            return .unweighed
        }
        // Use the past-chance attention bar: two deviations alone can select an unrelated care from the inventory.
        let touched = Self.caresStandingOut(cosines, among: weighed) { $0.origin != .seed }.map(\.care)
        guard let care = touched.first(where: { abs($0.charge(at: now)) >= Self.careLineCharge }) else {
            Self.traceCrossing(line, watch: watch, outcome: touched.isEmpty ? "untouched" : "untouched: below charge",
                               cosines: cosines, among: weighed, at: now)
            return .untouched
        }
        let rest = careWatchWoke[watch + "|" + care.id.uuidString]
        let resting = rest.map { rest in
            let duration = min(Self.careReleaseRest * pow(2, Double(min(rest.streak, 5))), 14 * 86_400)
            return now.timeIntervalSince(rest.at) < duration
                && !care.story.contains { $0.at > rest.at && $0.by != .her }
        } ?? false
        Self.traceCrossing(line, watch: watch, outcome: resting ? "resting" : "touches", care: care,
                           cosines: cosines, among: weighed, at: now)
        return .touches(care, resting: resting)
    }

    /// Record each weighing so unweighed evidence cannot masquerade as untouched cares.
    static func traceCrossing(_ line: String, watch: String, outcome: String, care: CognitiveCare? = nil,
                              cosines: [UUID: Double]? = nil, among weighed: [CognitiveCare] = [], at now: Date) {
        var payload: [String: JSONValue] = ["watch": .string(watch), "outcome": .string(outcome),
                                            "line": .string(String(line.prefix(120)))]
        if let care { payload["care"] = .string(care.about) }
        if let cosines {
            let scored = weighed.compactMap { care in cosines[care.id].map { (care: care, cosine: $0) } }
            let deviations = VectorMath.standout(scored.map(\.cosine))
            if let best = scored.indices.max(by: { scored[$0].cosine < scored[$1].cosine }) {
                payload["nearest"] = .string(scored[best].care.about)
                payload["cosine"] = .double(scored[best].cosine)
                payload["deviation"] = deviations[best].map { $0.isFinite ? .double($0) : .string("infinity") } ?? .null
                payload["bar"] = .double(VectorMath.chanceBar(.attention, among: scored.count))
                payload["charge"] = .double(scored[best].care.charge(at: now))
            }
        }
        TurnTraceBus.fire(TurnTraceEvent(turnId: TurnTraceContext.turnId ?? "cross:" + watch, kind: "care.cross",
                                         sessionId: "resident-wake", surface: "chat", payload: .object(payload), turn: nil))
    }

    /// Wake claims share the capsule cadence ledger so relaunch cannot erase their rest.
    public func watchWoke(_ watch: String, about care: CognitiveCare, at: Date) async {
        let key = watch + "|" + care.id.uuidString
        var rest = careWatchWoke[key] ?? CareWatchRest(at: at)
        rest.at = max(rest.at, at)
        careWatchWoke[key] = rest
        boundCareWatchLedger()
        capsulePresentationDirty = true
        await flushCapsulePresentationIfNeeded(at: dependencies.now())
    }

    func boundCareWatchLedger() {
        guard careWatchWoke.count > Self.dateLedgerCapacity else { return }
        let oldest = careWatchWoke.sorted { $0.value.at < $1.value.at }
            .prefix(careWatchWoke.count - Self.dateLedgerCapacity).map(\.key)
        for key in oldest { careWatchWoke.removeValue(forKey: key) }
    }

    /// A care wake lives only the agent's side against the care(s) that woke the agent. Meaning is already journaled; applyCares and this ledger each keep the
    /// fold's watermark, so either save can be finished after a crash.
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
        // applyCares suspends while saving; a Clear meanwhile must not restore cadence.
        guard configuration.enabled, context.mindEpoch == mindEpoch else { return }
        for wake in context.careWakes {
            var rest = careWatchWoke[wake.key] ?? CareWatchRest(at: wake.at)
            guard rest.lived < seq else { continue }
            let survivor = CognitiveCare.survivorID(for: wake.careID, among: cares)
            let moved = admitted.contains { judgment in
                guard case .existing(let id) = judgment.target else { return false }
                return CognitiveCare.survivorID(for: id, among: cares) == survivor
                    && judgment.moved != 0
            }
            let settled = survivor.flatMap { cares[$0] }?.story.contains {
                $0.source == provenance.source && $0.by == .her && $0.closedGap == true
            } == true
            rest.at = max(rest.at, wake.at)
            rest.streak = moved || settled ? 0 : (rest.streak < Int.max ? rest.streak + 1 : Int.max)
            rest.lived = seq
            careWatchWoke[wake.key] = rest
            capsulePresentationDirty = true
        }
        boundCareWatchLedger()
        try await persistCapsulePresentationChecked(at: dependencies.now())
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

    /// Record Reach silence as zero movement, never pressure. Save resident dedup matches before claiming durability; a missing care has nothing to move.
    public func noteReachLanded(care id: UUID, answered: Bool, person: String, source: String,
                                at: Date) async throws -> Bool {
        guard configuration.enabled else { throw CognitiveCareNotSaved(detail: "the inner life is off") }
        await waitForMaintenanceTransition()
        guard let care = cares[id] else { return true }
        if care.story.contains(where: { $0.source == source }) {
            try await saveCares([id], at: dependencies.now()).get()
            return true
        }
        let lead = answered ? "\(person) answered when I reached out about " : "I reached out about "
        let tail = answered ? "" : " and heard nothing back"
        let about = capsuleLineText(care.about, maxCharacters: CognitiveCare.noteCharacters - lead.count - tail.count)
        let judgment = CognitiveCareJudgment(
            target: .existing(id), moved: answered ? 0.2 : 0, by: .them,
            felt: answered ? "welcomed" : "unanswered", note: lead + about + tail)
        let provenance = CognitiveCareProvenance(
            speaker: CognitiveCare.ownerKey, trusted: true, appAuthored: false, source: source, at: at)
        let saved = try await applyCares([judgment], provenance: provenance, generation: caringAppraisalGeneration)
        return !saved.isEmpty
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

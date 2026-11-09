
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Affect.swift` | `CognitiveSubstrate`: `canonicalAffectProjection`, `decayAffectInMemory`, `applyAffectFromEvent` |

/// One grounded choice from the existing shared interpretation, independent of another speaker's affect.
public struct CognitiveRegisterChoice: Codable, Sendable, Equatable {
    public enum Stretch: String, Codable, Sendable { case conversation, until, untilReplaced = "until_replaced", released }
    public let name: String
    public let source: String
    public let stretch: Stretch
    public let until: Date?

    init?(payload: JSONValue) {
        guard let fields = payload.objectValue,
              let name = fields["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, !name.contains(where: { $0.isNewline }),
              !JSONValueBounding.containsSecretLikeValue(name),
              let source = fields["source"]?.stringValue, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.count <= 240,
              let raw = fields["stretch"]?.stringValue, let stretch = Stretch(rawValue: raw) else { return nil }
        let until: Date?
        if stretch == .until {
            guard let value = fields["until"]?.stringValue,
                  let date = ISO8601DateFormatter().date(from: value) else { return nil }
            until = date
        } else {
            guard fields["until"] == nil || fields["until"] == .null else { return nil }
            until = nil
        }
        self.name = name
        self.source = source
        self.stretch = stretch
        self.until = until
    }

    var payload: JSONValue { .object([
        "name": .string(name), "source": .string(source), "stretch": .string(stretch.rawValue),
        "until": until.map { .string($0.ISO8601Format()) } ?? .null,
    ]) }

    public init(from decoder: any Decoder) throws {
        guard let choice = Self(payload: try JSONValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid chosen register"))
        }
        self = choice
    }

    public func encode(to encoder: any Encoder) throws { try payload.encode(to: encoder) }
}

/// Canonical affect holds the last choice, including its source and stretch; expiration stops its color without erasing what was chosen.
public struct CognitiveChosenRegister: Codable, Sendable, Equatable {
    public let choice: CognitiveRegisterChoice
    public let session: String
    public let moment: String
    public let at: Date

    init(choice: CognitiveRegisterChoice, session: String, moment: String, at: Date) {
        self.choice = choice
        self.session = session
        self.moment = moment
        self.at = at
    }

    init?(payload: JSONValue) {
        guard let fields = payload.objectValue, let rawChoice = fields["choice"],
              let choice = CognitiveRegisterChoice(payload: rawChoice),
              let session = fields["session"]?.stringValue, !session.isEmpty,
              let moment = fields["moment"]?.stringValue, !moment.isEmpty,
              let at = fields["at"]?.numberValue(coercingStrings: false, finiteOnly: true) else { return nil }
        self.init(choice: choice, session: session, moment: moment, at: Date(timeIntervalSince1970: at))
    }

    var payload: JSONValue { .object([
        "choice": choice.payload, "session": .string(session), "moment": .string(moment), "at": .double(at.timeIntervalSince1970),
    ]) }

    public func isActive(in session: String?, at now: Date) -> Bool {
        guard now >= at else { return false }
        switch choice.stretch {
        case .conversation: return session == self.session
        case .until: return choice.until.map { now < $0 } == true
        case .untilReplaced: return true
        case .released: return false
        }
    }

    public init(from decoder: any Decoder) throws {
        guard let chosen = Self(payload: try JSONValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid held register"))
        }
        self = chosen
    }

    public func encode(to encoder: any Encoder) throws { try payload.encode(to: encoder) }
}

extension CognitiveSubstrate {
    /// Only the reply's grounded self-choice writes register state; incoming requests and affect signs cannot choose for her.
    func holdRegister(_ choice: CognitiveRegisterChoice?, for event: CognitiveEvent, moment: String) {
        guard let choice, let session = event.sessionId, !session.isEmpty else { return }
        affect.chosenRegister = CognitiveChosenRegister(choice: choice, session: session, moment: moment, at: event.occurredAt)
    }
    /// One fixed-time affect projection for sibling organs. Warmth and pressure must cross together so the organism cannot observe two decay epochs.
    public func canonicalAffectProjection(at fixedAt: Date) -> OrganismLifeReading? {
        guard configuration.enabled else { return nil }
        let current = projectedAffect(at: fixedAt)
        var novelty = topicNovelty(at: fixedAt)
        var careTension = 0.0
        var careValence = 0.0
        for care in cares.values where care.fadedAt == nil && care.createdAt <= fixedAt {
            let charge = care.charge(at: fixedAt)
            careValence += charge
            careTension += max(0, -charge)
            // A newly encountered concern invites curiosity; rereading it adds nothing.
            if care.origin == .grown, let first = care.story.first {
                let age = max(0, fixedAt.timeIntervalSince(care.createdAt))
                novelty += abs(first.moved) * pow(0.5, age / CognitiveCare.Depth.now.halfLife)
            }
        }
        return OrganismLifeReading(
            affect: current, novelty: novelty.clamped01(), careTension: careTension.clamped01(),
            careValence: careValence.clampedSigned(), handPain: currentHandPain())
    }

    /// Lexical unfamiliarity is evidence of novelty, not a semantic judgment. Reuse retained words; no embedder or interpretation call is needed.
    func topicNovelty(at now: Date) -> Double {
        func terms(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let nodes = field.peekNodes().filter {
            $0.turnKind.contributesToLivedState && $0.lastActivatedAt <= now
                && ($0.kind == .conversationFocus || $0.kind == .correction || $0.kind == .care)
        }
        // Read the latest actual human arrival, not the agent's reply or operational output.
        guard let incoming = nodes.filter({ node in
            let kind = node.metadata["eventKind"]?.stringValue.flatMap(CognitiveEventKind.init(rawValue:))
            return (kind == .userMessageReceived || kind == .userCorrection)
                && (node.sourceClass == .userStated || node.metadata["origin"]?.objectValue?["authored"] == .string("human"))
        }).max(by: { $0.lastActivatedAt < $1.lastActivatedAt }) else { return 0 }
        let brought = terms(incoming.summary)
        guard !brought.isEmpty else { return 0 }
        var familiar: [String: Double] = [:]
        func remember(_ text: String, at seenAt: Date) {
            // The care owner's present-depth half-life also defines "recently" for this transient reading.
            let age = max(0, incoming.lastActivatedAt.timeIntervalSince(seenAt))
            let recency = pow(0.5, age / CognitiveCare.Depth.now.halfLife)
            for term in terms(text).intersection(brought) { familiar[term] = max(familiar[term] ?? 0, recency) }
        }
        for node in nodes where node.id != incoming.id && node.lastActivatedAt < incoming.lastActivatedAt {
            remember(node.summary, at: node.lastActivatedAt)
        }
        for care in cares.values where care.fadedAt == nil && care.createdAt < incoming.lastActivatedAt {
            // Touching an existing care in this exchange confirms familiarity; a care born from it is not prior evidence.
            remember(care.about, at: min(care.updatedAt, incoming.lastActivatedAt))
        }
        // Each brought term has an equal share; neither a keyword list nor an absolute novelty threshold chooses the topic.
        let unfamiliar = brought.reduce(0.0) { $0 + (1 - (familiar[$1] ?? 0)) } / Double(brought.count)
        let age = max(0, now.timeIntervalSince(incoming.lastActivatedAt))
        return (unfamiliar * pow(0.5, age / CognitiveCare.Depth.now.halfLife)).clamped01()
    }

    /// The field holds failed receipts through progress and cancellation. Only a success of that act resolves its pain, never an earlier failed effect.
    /// A tool receipt's own words for what went wrong, not its JSON: its detail, error or accepted shape, in that order.
    static func plainCause(_ summary: String) -> String {
        guard let open = summary.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(summary[open...].utf8)) as? [String: Any] else {
            return String(summary.prefix(160))
        }
        for key in ["detail", "error", "message", "accepted"] {
            if let text = object[key] as? String, !text.isEmpty { return String(text.prefix(160)) }
        }
        return String(summary[..<open]).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ":")))
    }

    private func currentHandPain() -> [OrganismHandPain] {
        var seen = Set<String>()
        var pain: [OrganismHandPain] = []
        let nodes = field.peekNodes().filter { $0.kind == .toolObservation && $0.turnKind.contributesToLivedState }
            .sorted {
                if $0.lastActivatedAt != $1.lastActivatedAt { return $0.lastActivatedAt > $1.lastActivatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        for node in nodes {
            guard let raw = node.metadata["eventKind"]?.stringValue,
                  let kind = CognitiveEventKind(rawValue: raw),
                  kind == .toolFailed || kind == .toolSucceeded else { continue }
            let act: String
            let identity: String
            switch node.subjectReference.type {
            case "tool":
                guard let name = node.metadata["toolName"]?.stringValue, !name.isEmpty else { continue }
                act = name
                identity = "tool:" + name
            case "motor_action":
                guard let domain = node.metadata["motorDomain"]?.stringValue, !domain.isEmpty else { continue }
                act = domain
                identity = "motor:" + node.subjectReference.id
            default:
                continue
            }
            guard seen.insert(identity).inserted else { continue }
            if kind == .toolFailed {
                pain.append(OrganismHandPain(act: act, cause: Self.plainCause(node.summary)))
            }
        }
        return Array(pain.prefix(2))
    }

    @discardableResult
    func decayAffectInMemory(to now: Date) -> Bool {
        guard configuration.enabled,
              now.timeIntervalSince(affect.updatedAt) > 0 else { return false }
        affect = projectedAffect(at: now)
        return true
    }

    /// Decays and applies affect without suspension so ingest can stamp the same state atomically.
    @discardableResult
    func applyAffectFromEvent(
        _ event: CognitiveEvent,
        precomputedAppraisal: AffectAppraisal,
        precomputedWarmthBoost: Double
    ) -> CognitiveAffectState {
        guard configuration.enabled,
              event.turnKind.contributesToLivedState else { return affect }
        // Measured feeling takes no inferred per-kind delta; applying both would count one experience twice.
        guard !event.carriesMeasuredFeltValence else { return affect }
        let now = dependencies.now()
        // Settle elapsed quiet time on a copy before folding in the new event. This keeps the merge boundary correct even when no maintenance tick occurred
        // during the gap; the projection itself never mutates state.
        var next = projectedAffect(at: now)
        switch event.kind {
        case .toolFailed, .toolStarted, .toolSucceeded, .toolCancelled, .providerFailure, .providerVitalsShift:
            // Dispatch traffic neither doses feeling nor spends dream residue.
            return affect
        case .organismResolutionFelt:
            // Body chemistry already carries the resolution; retaining its node must not apply a second affect hit.
            break
        case .userCorrection, .userMessageReceived:
            // Warmth modulates the persona baseline only for received warmth; focused work decays that modulation without erasing the baseline.
            next.socialWarmth = saturatingApproach(next.socialWarmth, precomputedWarmthBoost)
            // Conversational appraisal moves felt signals for good and bad exchanges; dismissal can make warmth negative.
            let appraisal = precomputedAppraisal
            if appraisal.isActive {
                if appraisal.warmth != 0 { next.socialWarmth = saturatingApproach(next.socialWarmth, appraisal.warmth) }
                if appraisal.tension != 0 { next.uncertainty = saturatingApproach(next.uncertainty, appraisal.tension) }
                if appraisal.pressure != 0 { next.taskPressure = saturatingApproach(next.taskPressure, appraisal.pressure) }
                if appraisal.arousal != 0 { next.arousal = saturatingApproach(next.arousal, appraisal.arousal) }
            }
        case .assistantTurnCompleted:
            // Speaking establishes no landing. The person's response and the agent's appraised care movements supply it.
            break
        case .appWake:
            next.arousal = saturatingApproach(next.arousal, 0.05)
        case .appSleep:
            next.arousal = saturatingApproach(next.arousal, -0.1)
            next.taskPressure = saturatingApproach(next.taskPressure, -0.1)
        }
        // Re-feel and dream residue share this await-free state update.
        next = refelt(next, for: event, at: now)
        next = colored(next, byResidueAt: now)
        affect = next
        if event.kind == .assistantTurnCompleted {
            // Spend residue on completed exchanges, not individual events, so it lasts two real turns.
            consumeDreamResidueTurn(at: now)
        }
        // Keep affect and its node tag in one await-free segment; the async caller persists them afterward.
        return next
    }

    // MARK: - Re-feeling a remembered feeling

    /// The strongest nudge one re-touched memory may apply to current affect. Small by design: recall COLORS the present, it does not replace it.
    static let refeelNudge = 0.08
    /// One nudge per node per hour. A memory re-served three times in a turn is one act of remembering, not three feelings.
    static let refeelRefractory: TimeInterval = 60 * 60
    /// A tag this flat is not a feeling worth re-feeling.
    static let refeelValenceFloor = 0.12
    /// How many re-touched nodes may contribute to one turn.
    static let refeelNodesPerTurn = 2

    /// Recall nudges only present affect, bounded per node; re-stamping the memory would ratchet its feeling on every recall.
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
        for node in field.peekNodes()
            .sorted(by: { $0.lastActivatedAt > $1.lastActivatedAt }) {
            guard applied < Self.refeelNodesPerTurn else { break }
            guard abs(node.emotionalValence) >= Self.refeelValenceFloor else { continue }
            let ids = Self.memoryRecordIDs(from: node)
            guard !ids.isEmpty,
                  ids.contains(where: { served.contains($0) })
            else { continue }
            // Key the refractory by record and node: recalled records can receive fresh node identities on each turn.
            let servedHere = ids.filter { served.contains($0) }
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
        guard lastRefeltAt.count > 64 || lastRefeltRecordAt.count > 64 else { return }
        lastRefeltRecordAt = lastRefeltRecordAt.filter {
            now.timeIntervalSince($0.value) < Self.refeelRefractory
        }
        lastRefeltAt = lastRefeltAt.filter {
            now.timeIntervalSince($0.value) < Self.refeelRefractory
        }
    }

    /// Preserve first-seen record order so event and node decoding agree.
    static func memoryRecordIDs(fromEventMetadata metadata: [String: JSONValue]) -> [String] {
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

    /// Stamp measured feeling as given; otherwise combine the exact post-event affect with care-weighted meaning and the caller's gated appraisal.
    func emotionTag(
        for event: CognitiveEvent,
        affect: CognitiveAffectState,
        semantic: SemanticAppraisal,
        precomputedAppraisal appraisal: AffectAppraisal
    ) -> (valence: Double, arousal: Double, warmth: Double) {
        switch event.kind {
        case .toolStarted, .toolSucceeded, .toolFailed, .toolCancelled, .providerFailure, .providerVitalsShift:
            // Keep the receipt, without turning dispatch bookkeeping into the day's mood.
            return (0, 0, 0)
        default:
            break
        }
        // A measured feeling bypasses residue arithmetic, regardless of its owner.
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
        let affectTerm = affect.socialWarmth
            - 0.5 * affect.uncertainty
            - 0.3 * affect.taskPressure
        // A completion's nearby tool traffic is no verdict on what the agent said. Its care movements are read from their owner at the body crossing.
        let meaning = event.kind == .assistantTurnCompleted ? 0
            : meaningWeightedOutcomeBase(for: event, appraisal: semantic) + semanticValenceTerm(semantic) + appraisal.valence
        // Positive meaning damps negative residue by at most half.
        let dampedAffectTerm = (affectTerm < 0 && meaning > 0)
            ? affectTerm * (1 - min(0.5, meaning * 1.4))
            : affectTerm
        var pierced = dampedAffectTerm + meaning
        // Received affection may be muted but cannot become a wound; the floor follows the speaker's relational weight.
        if appraisal.affection {
            pierced = max(pierced, -0.12 * appraisal.affectionWeight.clamped01())
        }
        return (
            valence: (pierced).clampedSigned(),
            arousal: (affect.arousal).clamped01(),
            warmth: (affect.socialWarmth).clamped01()
        )
    }

    func restoreAffect(from payloads: [JSONValue]) {
        guard case .object(let object)? = payloads.first,
              let updatedAt = dateValue(object["updatedAt"]) else { return }
        affect = CognitiveAffectState(
            arousal: object["arousal"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0,
            uncertainty: object["uncertainty"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0,
            taskPressure: object["taskPressure"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0,
            socialWarmth: object["socialWarmth"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0,
            updatedAt: updatedAt,
            lived: object["lived"]?.stringValue.flatMap(UInt64.init)
                ?? UInt64(max(0, object["lived"]?.integerValue.flatMap(Int.init(exactly:)) ?? 0)),
            chosenRegister: object["chosenRegister"].flatMap(CognitiveChosenRegister.init(payload:))
        )
        lastUserPresenceAt = dateValue(object["lastUserPresenceAt"])
        lastWarmPresenceAt = dateValue(object["lastWarmPresenceAt"])
    }

    /// Arousal fades over minutes and warmth over hours so alertness can settle without losing relational continuity.

    /// Decay an affect state to `now` using per-axis half-lives. Centralizes the decay math used by the pure live projection and persisted checkpoints.
    private func decayedAffect(
        _ state: CognitiveAffectState,
        to now: Date,
        dynamics capturedDynamics: PersonalityDynamicsConfiguration?
    ) -> CognitiveAffectState {
        let elapsed = max(0, now.timeIntervalSince(state.updatedAt))
        guard elapsed > 0 else {
            var carried = state
            carried.updatedAt = now
            return carried
        }
        func decay(_ halfLife: TimeInterval) -> Double { pow(0.5, elapsed / halfLife) }
        let dyn = capturedDynamics ?? dynamics
        return CognitiveAffectState(
            arousal: state.arousal * decay(dyn.arousalHalfLife),
            uncertainty: state.uncertainty * decay(dyn.uncertaintyHalfLife),
            taskPressure: state.taskPressure * decay(dyn.taskPressureHalfLife),
            socialWarmth: state.socialWarmth * decay(dyn.socialWarmthHalfLife),
            updatedAt: now,
            lived: state.lived,
            chosenRegister: state.chosenRegister
        )
    }

    /// Use remaining headroom so sustained input settles below the ceiling while stronger moments can still register.
    private func saturatingApproach(_ value: Double, _ delta: Double) -> Double {
        let v = (value).clamped01()
        if delta >= 0 {
            return (v + delta * (1 - v)).clamped01()
        } else {
            return (v + delta * v).clamped01()
        }
    }

    /// Quiet must last this long before ambient presence applies.
    private static let ambientPresenceGap: TimeInterval = 30 * 60
    /// Hold a quiet-presence floor during the user's absence.
    private static let ambientPresenceWarmthBase: Double = 0.18
    /// The floor itself fades over a long absence so it never becomes permanent fake warmth.
    private static let ambientPresenceFloorHalfLife: TimeInterval = 12 * 60 * 60
    /// Elapsed quiet time determines calm independently of scheduler ticks: 0.95 per five minutes is a 67.56-minute half-life.
    private static let ambientQuietCalmingHalfLife: TimeInterval =
        (5 * 60) * log(0.5) / log(0.95)

    /// Pure read-time affect at an explicit instant. Canonical persistence keeps the last materialized anchor; callers observe analytic decay, ambient calm,
    /// and the warm-presence floor without advancing that anchor or writing.
    func projectedAffect(
        at now: Date,
        dynamics capturedDynamics: PersonalityDynamicsConfiguration? = nil
    ) -> CognitiveAffectState {
        guard configuration.enabled else { return affect }
        let source = affect
        var next = decayedAffect(source, to: now, dynamics: capturedDynamics)
        guard let lastPresence = lastUserPresenceAt else { return next }
        let quietBoundary = lastPresence.addingTimeInterval(Self.ambientPresenceGap)
        guard now >= quietBoundary else { return next }

        // Apply only the quiet interval not already materialized in `source`. A later maintenance/shutdown checkpoint can therefore persist this projection and
        // a subsequent read will continue from that exact anchor.
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
        return next
    }

}

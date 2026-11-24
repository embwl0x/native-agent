import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Attention.swift` | Checked care identity, atomic worth landing, drive claims and returns |

/// How a line touches the agent's cares: the nearest live care and how far it stands out from the others, against the chance bar for attention,
/// and the care whose stated condition for changing its stance the line stands out against, if one does.
public enum CareTouchReading: Sendable, Equatable {
    public struct Crossing: Sendable, Equatable {
        public let care: CognitiveCare
        public let standout: Double
        public let bar: Double
    }
    case touches(care: CognitiveCare, standout: Double?, bar: Double, charge: Double, crossed: Crossing?)
    /// Nothing could judge it (the embedder is cold or failed): never a verdict that it does not matter.
    case unavailable(String)
    /// The agent holds no live care, or inner life is off.
    case none
}

/// A node of the field worth gathers on: a care's anchor or a happening's own subject.
public struct AttentionNode: Sendable, Equatable {
    public let key: String
    public let about: String
    /// The care it anchors, when it is one.
    public let care: UUID?
}

public enum AttentionInputError: Error, LocalizedError, Sendable, Equatable {
    case missingCare(UUID)
    case invalidWorth
    case invalidDrive
    case invalidHalfLife

    public var errorDescription: String? {
        switch self {
        case .missingCare(let id): "the selected attention care \(id.uuidString) is missing; repair the care reference"
        case .invalidWorth: "attention worth must be finite and nonnegative; repair the weighing result"
        case .invalidDrive: "attention drive must be finite and nonnegative; repair its source"
        case .invalidHalfLife: "attention half-life must be finite and positive; repair the care depth or field configuration"
        }
    }
}

/// Unfinished record settlement, stored atomically with the field application it describes.
public struct AttentionLanding: Sendable {
    public struct Row: Sendable {
        public let subject: String
        public let fields: [String: JSONValue]
    }
    public let id: UUID
    public let at: Date
    public let rows: [Row]

    var payload: JSONValue {
        .object(["id": .string(id.uuidString), "at": .double(at.timeIntervalSince1970),
                 "rows": .array(rows.map { .object(["subject": .string($0.subject), "fields": .object($0.fields)]) })])
    }

    init(id: UUID, at: Date, rows: [Row]) { self.id = id; self.at = at; self.rows = rows }
    init?(payload: JSONValue) {
        guard let fields = payload.objectValue, let rawID = fields["id"]?.stringValue, let id = UUID(uuidString: rawID),
              let at = fields["at"]?.numberValue(coercingStrings: false, finiteOnly: true),
              let values = fields["rows"]?.arrayValue, !values.isEmpty else { return nil }
        var rows: [Row] = []
        for value in values {
            guard let row = value.objectValue, let subject = row["subject"]?.stringValue, !subject.isEmpty,
                  let contents = row["fields"]?.objectValue,
                  let worth = contents["worth"]?.numberValue(coercingStrings: false, finiteOnly: true), worth >= 0,
                  let drive = contents["drive"]?.numberValue(coercingStrings: false, finiteOnly: true), drive >= 0,
                  contents["node"]?.stringValue != nil, contents["mode"]?.stringValue != nil else { return nil }
            rows.append(Row(subject: subject, fields: contents))
        }
        self.init(id: id, at: Date(timeIntervalSince1970: at), rows: rows)
    }
}

extension CognitiveSubstrate {
    public func hasRestoredAttention() -> Bool {
        persistenceRestored && !persistenceHealth.writesBlocked && !forgettingInFlight
    }

    /// The nearest live care to `line`, its standing past chance and its charge, and any stance whose `wouldChangeMind` the line crosses. Seed cares
    /// compare and may be nearest; what a seed or a crossing is worth is the weigher's to say.
    public func careTouch(by line: String) async -> CareTouchReading {
        guard configuration.enabled else { return .none }
        let terms = Self.associationTerms(in: line)
        let live = cares.values.filter { $0.fadedAt == nil && !isSuppressed("care:" + $0.id.uuidString, messageTerms: terms) }
        guard !live.isEmpty else { return .none }
        let query = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .unavailable("the care reading has no words") }
        var falsifiers: [UUID: String] = [:]
        for care in live {
            if let text = care.stance?.wouldChangeMind, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                falsifiers[care.id] = text
            }
        }
        do {
            guard let lookup = try await careVectorLookup(queries: [query], among: live, falsifiers: falsifiers, turn: nil),
                  let vector = lookup.queries[query] else { return .unavailable("the embedder is not warm") }
            func best(_ vectors: [UUID: [Float]]) -> (care: CognitiveCare, standout: Double?)? {
                let scored = live.compactMap { care in vectors[care.id].map { (care, VectorMath.cosine(vector, $0)) } }
                guard let index = scored.indices.max(by: { scored[$0].1 < scored[$1].1 }) else { return nil }
                let standing = VectorMath.standout(scored.map { $0.1 })[index]
                return (scored[index].0, standing.flatMap { $0.isFinite ? $0 : nil })
            }
            guard lookup.cares.count == live.count, let nearest = best(lookup.cares) else {
                return .unavailable("the care reading did not include every live care")
            }
            // What would change her mind competes among everything the line could be about: every live care and every stated condition
            // stand in one population, so a single stated condition can be crossed.
            var crossed: CareTouchReading.Crossing?
            let careScores = live.compactMap { care in lookup.cares[care.id].map { VectorMath.cosine(vector, $0) } }
            let conditions = live.compactMap { care in lookup.falsifiers[care.id].map { (care: care, cosine: VectorMath.cosine(vector, $0)) } }
            if let strongest = conditions.indices.max(by: { conditions[$0].cosine < conditions[$1].cosine }) {
                let standings = VectorMath.standout(careScores + conditions.map(\.cosine))
                let bar = VectorMath.chanceBar(.attention, among: standings.count)
                if let standout = standings[careScores.count + strongest], standout.isFinite, standout >= bar {
                    crossed = .init(care: conditions[strongest].care, standout: standout, bar: bar)
                }
            }
            guard nearest.standout != nil || crossed != nil else { return .unavailable("the cares could not be told apart for this line") }
            return .touches(care: nearest.care, standout: nearest.standout, bar: VectorMath.chanceBar(.attention, among: live.count),
                            charge: nearest.care.charge(at: dependencies.now()), crossed: crossed)
        } catch {
            oweCareEmbedding(error)
            return .unavailable(error.localizedDescription)
        }
    }

    /// The node worth lands on: the touched care's anchor, or else the happening's own subject.
    public func attentionNode(care: UUID?, subject: String, words: String) throws -> AttentionNode {
        let landing = try attentionLanding(care: care, subject: subject, words: words)
        return AttentionNode(key: field.key(of: landing), about: landing.summary, care: care)
    }

    private func attentionLanding(care: UUID?, subject: String, words: String) throws -> ContinuityField.Landing {
        if let id = care {
            guard let care = cares[id] else { throw AttentionInputError.missingCare(id) }
            return .init(kind: .care, subject: .init(type: "care", id: care.id.uuidString, label: care.about),
                         halfLife: care.depth.halfLife, summary: care.about)
        }
        return .init(kind: .happening, subject: .init(type: "happening", id: subject), halfLife: configuration.defaultDecayHalfLife, summary: words)
    }

    /// A batch applies atomically at one field clock reading; disabled background thinking leaves its inputs unweighed.
    public func land(
        _ weights: [(worth: Double, care: UUID?, subject: String, words: String, happening: String, row: [String: JSONValue])]
    ) async throws -> (at: Date, landed: [(node: AttentionNode, drive: Double)])? {
        await waitForMaintenanceTransition()
        let at = dependencies.now()
        guard attentionLanding == nil else { throw CognitivePersistenceError.storeUnavailable }
        guard configuration.enabled, configuration.backgroundMicrocyclesEnabled else { return nil }
        guard !forgettingInFlight, !persistenceHealth.writesBlocked else { throw CognitivePersistenceError.storeUnavailable }
        guard !weights.isEmpty else { return (at, []) }
        var nextField = field
        let landed = try weights.map { weight -> (node: AttentionNode, drive: Double) in
            let landing = try attentionLanding(care: weight.care, subject: weight.subject, words: weight.words)
            let landed = try nextField.land(weight.worth, on: landing, now: at, makeUUID: dependencies.makeUUID,
                                            configuration: configuration)
            return (AttentionNode(key: landed.key, about: landing.summary,
                                  care: weight.care), landed.drive)
        }
        let rows = zip(weights, landed).map { weight, landed in
            var row = weight.row
            row["node"] = .string(landed.node.key)
            row["drive"] = .double(landed.drive)
            return AttentionLanding.Row(subject: weight.happening, fields: row)
        }
        field = nextField
        attentionLanding = AttentionLanding(id: dependencies.makeUUID(), at: at, rows: rows)
        markDirty(at: at)
        return (at, landed)
    }

    /// Checkpoint the application marker and rows with the field before recording or igniting. A failed write leaves this same phase owed.
    public func checkpointAttentionLanding() async throws -> AttentionLanding? {
        await waitForMaintenanceTransition()
        guard let landing = attentionLanding else { return nil }
        guard configuration.enabled, configuration.persistenceEnabled else { throw CognitivePersistenceError.storeUnavailable }
        try await persistAffectAndNodes()
        return landing
    }

    public func settleAttentionLanding(_ id: UUID) {
        guard attentionLanding?.id == id else { return }
        attentionLanding = nil
        markDirty(at: dependencies.now())
    }

    func attentionCheckpoint() -> CognitiveArtifactWrite {
        .init(kind: "attention_landing", id: stableArtifactID("attention_landing"), status: "current", score: 0,
              payload: .object(["pending": attentionLanding?.payload ?? .null]))
    }

    /// Drain a crossing already selected at the admitted batch's clock reading. The runtime holds admission until its record and thought are handed on;
    /// later decay cannot revoke that crossing or supply a second clock for the thought's drive.
    public func attend(_ node: String, at: Date) -> Double? {
        guard let drive = field.drain(node) else { return nil }
        markDirty(at: at)
        return drive
    }

    /// Return drive to its node without igniting it; zero preserves the field unchanged.
    public func restoreDrive(_ node: String, _ drive: Double) throws -> Bool {
        let now = dependencies.now()
        guard try field.restore(drive, to: node, now: now) else { return false }
        if drive > 0 { markDirty(at: now) }
        return true
    }

    /// Nodes whose drive has reached one thought: what attention ignites when admission opens or the agent wakes.
    public func igniting() -> (at: Date, nodes: [(node: AttentionNode, drive: Double)]) {
        let at = dependencies.now()
        guard configuration.enabled, configuration.backgroundMicrocyclesEnabled else { return (at, []) }
        let nodes: [(node: AttentionNode, drive: Double)] = field.igniting(at: at).map { key, node in
            let care = node.kind == .care ? UUID(uuidString: node.subjectReference.id).flatMap { cares[$0] == nil ? nil : $0 } : nil
            return (AttentionNode(key: key, about: node.summary, care: care), node.drive)
        }
        return (at, nodes)
    }

    /// How the agent feels now, read without advancing anything: what the weigher is given.
    public func attentionAffect() -> (arousal: Double, taskPressure: Double, warmth: Double)? {
        guard configuration.enabled else { return nil }
        let affect = projectedAffect(at: dependencies.now())
        return (affect.arousal, affect.taskPressure, affect.socialWarmth)
    }

    /// The care a movement is about, by id, for the `self` happening that carries it.
    public func liveCare(_ id: UUID) -> CognitiveCare? {
        cares[id].flatMap { $0.fadedAt == nil ? $0 : nil }
    }
}

import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Attention.swift` | Checked care identity, atomic worth landing, drive claims and returns |

/// How a line touches the agent's cares: the nearest live care and how far it stands out from the others, against the chance bar for attention.
public enum CareTouchReading: Sendable, Equatable {
    case touches(care: CognitiveCare, standout: Double, bar: Double, charge: Double)
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

    /// The nearest live care to `line`, its standing past chance and its charge. Seed cares compare and may be nearest; what a seed is worth is the
    /// weigher's to say.
    public func careTouch(by line: String) async -> CareTouchReading {
        guard configuration.enabled else { return .none }
        let terms = Self.associationTerms(in: line)
        let live = cares.values.filter { $0.fadedAt == nil && !isSuppressed("care:" + $0.id.uuidString, messageTerms: terms) }
        guard !live.isEmpty else { return .none }
        let cosines: [UUID: Double]
        do {
            guard let scored = try await careCosines(to: line, among: live, turn: nil) else { return .unavailable("the embedder is not warm") }
            cosines = scored
        } catch {
            oweCareEmbedding(error)
            return .unavailable(error.localizedDescription)
        }
        let scored = live.compactMap { care in cosines[care.id].map { (care: care, cosine: $0) } }
        guard scored.count == live.count else { return .unavailable("the care reading did not include every live care") }
        let standings = zip(scored, VectorMath.standout(scored.map(\.cosine)))
        guard let best = standings.max(by: { $0.0.cosine < $1.0.cosine }) else {
            return .unavailable("the care reading did not include any live care")
        }
        let bar = VectorMath.chanceBar(.attention, among: scored.count)
        // A lone care, or one the others cannot be told from, stands nowhere: its standing is unknown, not past chance.
        guard let standout = best.1, standout.isFinite else {
            return .unavailable("the cares could not be told apart for this line")
        }
        let care = best.0.care
        return .touches(care: care, standout: standout, bar: bar, charge: care.charge(at: dependencies.now()))
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

    /// Drive a failed thought drained returns to its node, without igniting it.
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

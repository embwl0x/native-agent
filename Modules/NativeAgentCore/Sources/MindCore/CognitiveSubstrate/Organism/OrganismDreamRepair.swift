import Foundation
import PersistenceCore
import NativeAgentShared
// Blueprint: | `OrganismDreamRepair.swift` | Typed field repair readings, plan validation and durable receipts |

public enum OrganismRepairOperationKind: String, Codable, Sendable, Equatable, CaseIterable {
    case softenHighArousal
    case strengthenWarmAssociation
    case weakenNoisyLoop
    case flagContradiction
}

public struct OrganismRepairOperation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: OrganismRepairOperationKind
    public var targetID: String
    public var delta: Double

    public init(
        id: String,
        kind: OrganismRepairOperationKind,
        targetID: String,
        delta: Double
    ) {
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.kind = kind
        self.targetID = String(targetID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.delta = (delta).clampedSigned()
    }
}

public struct OrganismDreamRepairEvidence: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var summary: String

    public init(id: String, label: String, summary: String) {
        self.id = Self.clean(id, limit: 120, fallback: "evidence")
        self.label = Self.clean(label, limit: 80, fallback: "Evidence")
        self.summary = Self.clean(summary, limit: 220, fallback: "bounded local repair evidence")
    }

    static func clean(_ value: String, limit: Int, fallback: String) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return fallback }
        let lower = oneLine.lowercased()
        // Share credential-shape detection; evidence key markers apply an additional conservative text rule.
        if JSONValueBounding.containsSecretLikeValue(oneLine)
            || lower.contains("authorization:")
            || lower.contains("api_key")
            || lower.contains("secret") {
            return "private evidence hidden"
        }
        return String(oneLine.prefix(limit))
    }
}

public struct OrganismDreamRepairReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var generatedAt: Date
    public var reason: String
    public var feltDaySummaryCharacters: Int
    public var operations: [OrganismRepairOperation]
    public var evidence: [OrganismDreamRepairEvidence]
    public var flagCount: Int
    public var sourceFieldGeneration: UInt64

    public init(
        id: UUID,
        generatedAt: Date,
        reason: String,
        feltDaySummaryCharacters: Int,
        operations: [OrganismRepairOperation],
        evidence: [OrganismDreamRepairEvidence] = [],
        flagCount: Int = 0,
        sourceFieldGeneration: UInt64 = 0
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.reason = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.feltDaySummaryCharacters = max(0, feltDaySummaryCharacters)
        self.operations = Array(operations.prefix(32))
        self.evidence = Array(evidence.prefix(16))
        self.flagCount = max(0, flagCount)
        self.sourceFieldGeneration = sourceFieldGeneration
    }

    enum CodingKeys: String, CodingKey {
        case id
        case generatedAt
        case reason
        case feltDaySummaryCharacters
        case operations
        case evidence
        case flagCount
        case sourceFieldGeneration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            generatedAt: try c.decode(Date.self, forKey: .generatedAt),
            reason: try c.decode(String.self, forKey: .reason),
            feltDaySummaryCharacters: try c.decodeIfPresent(Int.self, forKey: .feltDaySummaryCharacters) ?? 0,
            operations: try c.decodeIfPresent([OrganismRepairOperation].self, forKey: .operations) ?? [],
            evidence: try c.decodeIfPresent([OrganismDreamRepairEvidence].self, forKey: .evidence) ?? [],
            flagCount: try c.decodeIfPresent(Int.self, forKey: .flagCount) ?? 0,
            sourceFieldGeneration: try c.decodeIfPresent(UInt64.self, forKey: .sourceFieldGeneration) ?? 0
        )
    }

    public static let empty = OrganismDreamRepairReceipt(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
        generatedAt: Date(timeIntervalSince1970: 0),
        reason: "none",
        feltDaySummaryCharacters: 0,
        operations: []
    )
}

public struct OrganismDreamRepairSummary: Codable, Sendable, Equatable {
    public var receiptCount: Int
    public var lastRepairAt: Date?
    public var lastReason: String?
    public var lastOperationCount: Int
    public var softenedNodes: Int
    public var strengthenedEdges: Int
    public var weakenedEdges: Int
    public var flaggedContradictions: Int
    public var feltDaySummaryCharacters: Int
    public var latestEvidence: [OrganismDreamRepairEvidence]

    public init(
        receiptCount: Int = 0,
        lastRepairAt: Date? = nil,
        lastReason: String? = nil,
        lastOperationCount: Int = 0,
        softenedNodes: Int = 0,
        strengthenedEdges: Int = 0,
        weakenedEdges: Int = 0,
        flaggedContradictions: Int = 0,
        feltDaySummaryCharacters: Int = 0,
        latestEvidence: [OrganismDreamRepairEvidence] = []
    ) {
        self.receiptCount = max(0, receiptCount)
        self.lastRepairAt = lastRepairAt
        self.lastReason = lastReason
        self.lastOperationCount = max(0, lastOperationCount)
        self.softenedNodes = max(0, softenedNodes)
        self.strengthenedEdges = max(0, strengthenedEdges)
        self.weakenedEdges = max(0, weakenedEdges)
        self.flaggedContradictions = max(0, flaggedContradictions)
        self.feltDaySummaryCharacters = max(0, feltDaySummaryCharacters)
        self.latestEvidence = Array(latestEvidence.prefix(12))
    }

    public static let empty = OrganismDreamRepairSummary()
}

public struct OrganismDreamRepairState: Codable, Sendable, Equatable {
    public var receiptCount: Int
    public var lastReceipt: OrganismDreamRepairReceipt?

    public init(
        receiptCount: Int = 0,
        lastReceipt: OrganismDreamRepairReceipt? = nil
    ) {
        self.receiptCount = max(0, receiptCount)
        self.lastReceipt = lastReceipt
    }

    private enum CodingKeys: String, CodingKey {
        case receiptCount, lastReceipt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            receiptCount: try container.decodeIfPresent(Int.self, forKey: .receiptCount) ?? 0,
            lastReceipt: try container.decodeIfPresent(OrganismDreamRepairReceipt.self, forKey: .lastReceipt)
        )
    }

    public static let empty = OrganismDreamRepairState()

    public func summary() -> OrganismDreamRepairSummary {
        guard let receipt = lastReceipt else { return .empty }
        return OrganismDreamRepairSummary(
            receiptCount: receiptCount,
            lastRepairAt: receipt.generatedAt,
            lastReason: receipt.reason,
            lastOperationCount: receipt.operations.count,
            softenedNodes: receipt.operations.filter { $0.kind == .softenHighArousal }.count,
            strengthenedEdges: receipt.operations.filter { $0.kind == .strengthenWarmAssociation }.count,
            weakenedEdges: receipt.operations.filter { $0.kind == .weakenNoisyLoop }.count,
            flaggedContradictions: receipt.flagCount,
            feltDaySummaryCharacters: receipt.feltDaySummaryCharacters,
            latestEvidence: receipt.evidence
        )
    }
}

public enum OrganismDreamRepair {
    private static let maximumOperations = 16
    private static let maximumFeltSummaryCharacters = 1_200

    static func hasRepairableCharge(_ node: OrganismNode) -> Bool {
        node.charge >= 0.12
    }

    static func hasRepairableNoise(_ edge: OrganismEdge) -> Bool {
        edge.uncertainty >= 0.18 || (edge.eligibility >= 0.45 && edge.weight >= 0.12)
    }

    package struct Plan: Sendable {
        var field: OrganismField
        var operations: [OrganismRepairOperation]
    }

    package struct Reading: Sendable {
        private let field: OrganismField
        private let nodes: [OrganismNode]
        private let edges: [OrganismEdge]
        private let residual: Bool

        init(field: OrganismField, opportunity: OrganismResidualRepairOpportunity? = nil) {
            self.field = field
            residual = opportunity != nil
            nodes = (opportunity.map { $0.chargedNodeIDs.compactMap { field.nodes[$0] } } ?? Array(field.nodes.values))
                .sorted { $0.id < $1.id }
            edges = (opportunity.map { $0.noisyEdgeIDs.compactMap { field.edges[$0] } } ?? Array(field.edges.values))
                .sorted { $0.id < $1.id }
        }

        package var input: JSONValue {
            .object([
                "residual": .bool(residual),
                "nodes": .array(nodes.map { .array([.double($0.charge), .double($0.activation)]) }),
                "edges": .array(edges.map { .array([.double($0.weight), .double($0.uncertainty), .double($0.eligibility)]) }),
            ])
        }

        private struct Edit: Decodable {
            var kind: OrganismRepairOperationKind
            var target: Int
            var values: [Double]
        }

        package func verify(_ answer: JSONValue) throws -> Plan {
            let edits = try JSONDecoder().decode([Edit].self, from: answer.serializedData(pretty: false))
            guard edits.count <= maximumOperations else { throw invalidPlan }
            var plan = Plan(field: field, operations: [])
            var seen: [OrganismRepairOperationKind: Set<Int>] = [:]
            for edit in edits {
                guard seen[edit.kind, default: []].insert(edit.target).inserted,
                      edit.values.enumerated().allSatisfy({ index, value in
                          (0...1).contains(value) || (edit.kind == .strengthenWarmAssociation && index == 1 && value.isFinite)
                      }) else { throw invalidPlan }
                let id: String, delta: Double, verb: String
                switch edit.kind {
                case .softenHighArousal:
                    guard nodes.indices.contains(edit.target), edit.values.count == 2,
                          var node = plan.field.nodes[nodes[edit.target].id], hasRepairableCharge(node),
                          edit.values[0] < node.charge, edit.values[1] >= 0.05,
                          edit.values[1] <= max(0.05, node.activation) else { throw invalidPlan }
                    id = node.id; delta = edit.values[0] - node.charge; verb = "soften"
                    node.charge = edit.values[0]
                    node.activation = edit.values[1]
                    plan.field.nodes[id] = node
                case .strengthenWarmAssociation, .weakenNoisyLoop:
                    guard edges.indices.contains(edit.target), edit.values.count == 3,
                          var edge = plan.field.edges[edges[edit.target].id],
                          edit.values[2] <= edge.eligibility.clamped01() else { throw invalidPlan }
                    id = edge.id; delta = edit.values[0] - edge.weight
                    if edit.kind == .weakenNoisyLoop {
                        guard hasRepairableNoise(edge), edit.values[0] >= 0.01, edit.values[0] <= max(0.01, edge.weight),
                              edit.values[1] <= edge.uncertainty.clamped01() else { throw invalidPlan }
                        verb = "weaken"
                    } else {
                        guard !residual, edit.values[0] >= edge.weight.clamped01(),
                              edit.values[1] == edge.uncertainty else { throw invalidPlan }
                        verb = "warm"
                    }
                    edge.weight = edit.values[0]
                    edge.uncertainty = edit.values[1]
                    edge.eligibility = edit.values[2]
                    plan.field.edges[id] = edge
                case .flagContradiction:
                    throw invalidPlan
                }
                plan.operations.append(.init(id: "\(verb):\(id)", kind: edit.kind, targetID: id, delta: delta))
            }
            return plan
        }

        private var invalidPlan: PartCallError {
            .init(code: "bad_field_repair", message: "The field repair returned an invalid operation for its captured evidence.")
        }
    }

    static func record(
        _ plan: Plan,
        into body: inout OrganismPersistentState,
        at date: Date,
        signal: SomaticSignal? = nil,
        residualEvidenceCount: Int = 0,
        makeUUID: () -> UUID
    ) {
        let state = body.dreamRepairState
        var field = plan.field
        var operations = plan.operations
        let feltSummary = signal.map { feltDaySummary(from: $0.metadata, limit: maximumFeltSummaryCharacters) } ?? ""
        let flags = contradictionFlags(in: feltSummary, remaining: maximumOperations - operations.count)
        operations.append(contentsOf: flags)
        let evidence = if signal != nil {
            evidenceLinks(feltSummary: feltSummary, operations: operations, flags: flags)
        } else {
            [OrganismDreamRepairEvidence(
                id: "evidence:residual-pressure",
                label: "Prediction and field residuals",
                summary: "Local residual repair used \(residualEvidenceCount) bounded evidence signal(s)."
            )]
        }
        let generation = field.mutationGeneration
        let hasTargets = field.nodes.values.contains(where: hasRepairableCharge)
            || field.edges.values.contains(where: hasRepairableNoise)
        let receipt = OrganismDreamRepairReceipt(
            id: makeUUID(), generatedAt: date, reason: signal?.kind.rawValue ?? "residual_pressure",
            feltDaySummaryCharacters: feltSummary.count, operations: operations, evidence: evidence, flagCount: flags.count,
            sourceFieldGeneration: hasTargets ? min(state.lastReceipt?.sourceFieldGeneration ?? 0, generation) : generation
        )
        field.lastUpdatedAt = date
        body.field = field
        body.dreamRepairState = .init(receiptCount: min(state.receiptCount, Int.max - 1) + 1, lastReceipt: receipt)
    }

    private static func contradictionFlags(in feltSummary: String, remaining: Int) -> [OrganismRepairOperation] {
        guard remaining > 0 else { return [] }
        let lower = feltSummary.lowercased()
        guard lower.contains("contradict")
            || lower.contains("conflict")
            || lower.contains("inconsistent")
            || lower.contains("tension") else {
            return []
        }
        return [
            OrganismRepairOperation(
                id: "flag:felt-summary-contradiction",
                kind: .flagContradiction,
                targetID: "felt-summary",
                delta: 0
            ),
        ]
    }

    private static func evidenceLinks(
        feltSummary: String,
        operations: [OrganismRepairOperation],
        flags: [OrganismRepairOperation]
    ) -> [OrganismDreamRepairEvidence] {
        var evidence: [OrganismDreamRepairEvidence] = []
        if !feltSummary.isEmpty {
            evidence.append(OrganismDreamRepairEvidence(
                id: "evidence:felt-summary",
                label: "Felt-day summary",
                summary: "Bounded felt summary excerpt: \(feltSummary)"
            ))
        }
        if !flags.isEmpty {
            evidence.append(OrganismDreamRepairEvidence(
                id: "evidence:contradiction",
                label: "Contradiction flag",
                summary: "Dream repair found contradiction or tension language that needs review."
            ))
        }
        let softened = operations.filter { $0.kind == .softenHighArousal }.count
        let strengthened = operations.filter { $0.kind == .strengthenWarmAssociation }.count
        let weakened = operations.filter { $0.kind == .weakenNoisyLoop }.count
        if softened + strengthened + weakened > 0 {
            evidence.append(OrganismDreamRepairEvidence(
                id: "evidence:field-repair",
                label: "Field repair",
                summary: "Field repair softened \(softened), strengthened \(strengthened), weakened \(weakened)."
            ))
        }
        return Array(evidence.prefix(12))
    }

    private static func feltDaySummary(from metadata: [String: JSONValue], limit: Int) -> String {
        guard case .string(let raw)? = metadata["feltDaySummary"] else { return "" }
        return String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

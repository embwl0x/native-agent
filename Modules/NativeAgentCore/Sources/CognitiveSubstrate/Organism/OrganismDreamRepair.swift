import Foundation
import PersistenceCore

public enum OrganismRepairOperationKind: String, Codable, Sendable, Equatable, CaseIterable {
    case softenHighArousal
    case strengthenWarmAssociation
    case weakenNoisyLoop
    case flagContradiction
    case proposeStandingView
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
        if lower.contains("bearer ")
            || lower.contains("sk-")
            || lower.contains("xoxb-")
            || lower.contains("xapp-")
            || lower.contains("authorization:")
            || lower.contains("api_key")
            || lower.contains("secret") {
            return "private evidence hidden"
        }
        return String(oneLine.prefix(limit))
    }
}

public struct OrganismStandingViewProposal: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var rationale: String
    public var evidenceIDs: [String]
    public var reviewRequired: Bool

    public init(
        id: String,
        title: String,
        rationale: String,
        evidenceIDs: [String],
        reviewRequired: Bool = true
    ) {
        self.id = OrganismDreamRepairEvidence.clean(id, limit: 120, fallback: "standing-view-proposal")
        self.title = OrganismDreamRepairEvidence.clean(title, limit: 100, fallback: "Review recurring pattern")
        self.rationale = OrganismDreamRepairEvidence.clean(rationale, limit: 220, fallback: "Dream repair found a recurring pattern.")
        self.evidenceIDs = evidenceIDs.prefix(6).map {
            OrganismDreamRepairEvidence.clean($0, limit: 120, fallback: "evidence")
        }
        self.reviewRequired = reviewRequired
    }
}

public struct OrganismDreamRepairReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var generatedAt: Date
    public var reason: String
    public var feltDaySummaryCharacters: Int
    public var operations: [OrganismRepairOperation]
    public var evidence: [OrganismDreamRepairEvidence]
    public var standingViewProposals: [OrganismStandingViewProposal]
    public var proposedStandingViewCount: Int
    public var flagCount: Int
    public var sourceFieldGeneration: UInt64

    public init(
        id: UUID,
        generatedAt: Date,
        reason: String,
        feltDaySummaryCharacters: Int,
        operations: [OrganismRepairOperation],
        evidence: [OrganismDreamRepairEvidence] = [],
        standingViewProposals: [OrganismStandingViewProposal] = [],
        proposedStandingViewCount: Int = 0,
        flagCount: Int = 0,
        sourceFieldGeneration: UInt64 = 0
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.reason = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.feltDaySummaryCharacters = max(0, feltDaySummaryCharacters)
        self.operations = Array(operations.prefix(32))
        self.evidence = Array(evidence.prefix(16))
        self.standingViewProposals = Array(standingViewProposals.prefix(8))
        self.proposedStandingViewCount = max(0, proposedStandingViewCount)
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
        case standingViewProposals
        case proposedStandingViewCount
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
            standingViewProposals: try c.decodeIfPresent([OrganismStandingViewProposal].self, forKey: .standingViewProposals) ?? [],
            proposedStandingViewCount: try c.decodeIfPresent(Int.self, forKey: .proposedStandingViewCount) ?? 0,
            flagCount: try c.decodeIfPresent(Int.self, forKey: .flagCount) ?? 0,
            sourceFieldGeneration: try c.decodeIfPresent(UInt64.self, forKey: .sourceFieldGeneration) ?? 0
        )
    }

    public static let empty = OrganismDreamRepairReceipt(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
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
    public var proposedStandingViews: Int
    public var feltDaySummaryCharacters: Int
    public var latestEvidence: [OrganismDreamRepairEvidence]
    public var standingViewProposals: [OrganismStandingViewProposal]

    public init(
        receiptCount: Int = 0,
        lastRepairAt: Date? = nil,
        lastReason: String? = nil,
        lastOperationCount: Int = 0,
        softenedNodes: Int = 0,
        strengthenedEdges: Int = 0,
        weakenedEdges: Int = 0,
        flaggedContradictions: Int = 0,
        proposedStandingViews: Int = 0,
        feltDaySummaryCharacters: Int = 0,
        latestEvidence: [OrganismDreamRepairEvidence] = [],
        standingViewProposals: [OrganismStandingViewProposal] = []
    ) {
        self.receiptCount = max(0, receiptCount)
        self.lastRepairAt = lastRepairAt
        self.lastReason = lastReason
        self.lastOperationCount = max(0, lastOperationCount)
        self.softenedNodes = max(0, softenedNodes)
        self.strengthenedEdges = max(0, strengthenedEdges)
        self.weakenedEdges = max(0, weakenedEdges)
        self.flaggedContradictions = max(0, flaggedContradictions)
        self.proposedStandingViews = max(0, proposedStandingViews)
        self.feltDaySummaryCharacters = max(0, feltDaySummaryCharacters)
        self.latestEvidence = Array(latestEvidence.prefix(12))
        self.standingViewProposals = Array(standingViewProposals.prefix(8))
    }

    public static let empty = OrganismDreamRepairSummary()
}

public struct OrganismDreamRepairLimits: Sendable, Equatable {
    public var maximumOperations: Int
    public var maximumFeltSummaryCharacters: Int

    public init(maximumOperations: Int = 16, maximumFeltSummaryCharacters: Int = 1_200) {
        self.maximumOperations = max(0, maximumOperations)
        self.maximumFeltSummaryCharacters = max(0, maximumFeltSummaryCharacters)
    }

    public static let defaults = OrganismDreamRepairLimits()
}

public struct OrganismDreamRepairState: Codable, Sendable, Equatable {
    public var receiptCount: Int
    public var lastReceipt: OrganismDreamRepairReceipt?
    public var sleepControl: OrganismSleepControlState

    public init(
        receiptCount: Int = 0,
        lastReceipt: OrganismDreamRepairReceipt? = nil,
        sleepControl: OrganismSleepControlState = .empty
    ) {
        self.receiptCount = max(0, receiptCount)
        self.lastReceipt = lastReceipt
        self.sleepControl = sleepControl
    }

    private enum CodingKeys: String, CodingKey {
        case receiptCount, lastReceipt, sleepControl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            receiptCount: try container.decodeIfPresent(Int.self, forKey: .receiptCount) ?? 0,
            lastReceipt: try container.decodeIfPresent(OrganismDreamRepairReceipt.self, forKey: .lastReceipt),
            sleepControl: try container.decodeIfPresent(OrganismSleepControlState.self, forKey: .sleepControl) ?? .empty
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
            // Legacy receipts may carry the pre-2026-07-12 generic
            // "review recurring pattern" suggestion. It was never an actual
            // CognitiveStandingView and had no durable resolution path, so it
            // must not keep presenting itself as work awaiting review.
            proposedStandingViews: 0,
            feltDaySummaryCharacters: receipt.feltDaySummaryCharacters,
            latestEvidence: receipt.evidence,
            standingViewProposals: []
        )
    }
}

public enum OrganismDreamRepair {
    public static func applying(
        signal: SomaticSignal,
        to field: OrganismField,
        state: OrganismDreamRepairState,
        limits: OrganismDreamRepairLimits = .defaults,
        makeUUID: () -> UUID = { UUID() }
    ) -> (field: OrganismField, state: OrganismDreamRepairState) {
        guard signal.kind == .dreamCompleted || signal.kind == .remIntegrated else {
            return (field, state)
        }

        let feltSummary = feltDaySummary(from: signal.metadata, limit: limits.maximumFeltSummaryCharacters)
        var nextField = field
        var operations: [OrganismRepairOperation] = []

        repairHighChargeNodes(in: &nextField, operations: &operations, limit: limits.maximumOperations)
        strengthenWarmAssociations(in: &nextField, operations: &operations, limit: limits.maximumOperations)
        weakenNoisyLoops(in: &nextField, operations: &operations, limit: limits.maximumOperations)

        let flags = contradictionFlags(in: feltSummary, remaining: max(0, limits.maximumOperations - operations.count))
        operations.append(contentsOf: flags)
        let evidence = evidenceLinks(
            feltSummary: feltSummary,
            operations: operations,
            flags: flags
        )

        let receipt = OrganismDreamRepairReceipt(
            id: makeUUID(),
            generatedAt: signal.occurredAt,
            reason: signal.kind.rawValue,
            feltDaySummaryCharacters: feltSummary.count,
            operations: operations,
            evidence: evidence,
            standingViewProposals: [],
            proposedStandingViewCount: 0,
            flagCount: flags.count,
            sourceFieldGeneration: acknowledgedGeneration(
                after: nextField,
                currentGeneration: nextField.mutationGeneration,
                previousGeneration: state.lastReceipt?.sourceFieldGeneration ?? 0
            )
        )
        nextField.lastUpdatedAt = signal.occurredAt
        return (
            nextField,
            OrganismDreamRepairState(
                receiptCount: state.receiptCount + 1,
                lastReceipt: receipt,
                sleepControl: state.sleepControl
            )
        )
    }

    /// Quiet local repair driven by exact residual evidence rather than a clock
    /// or an LLM-authored dream. The caller must supply the current derived
    /// opportunity; stale/not-ready opportunities are harmless no-ops. This is
    /// field maintenance only: it creates no standing view, memory, prompt,
    /// notification, or action.
    public static func applyingResidualPressure(
        _ opportunity: OrganismResidualRepairOpportunity,
        at date: Date,
        to field: OrganismField,
        state: OrganismDreamRepairState,
        limits: OrganismDreamRepairLimits = .defaults,
        makeUUID: () -> UUID = { UUID() }
    ) -> (field: OrganismField, state: OrganismDreamRepairState) {
        guard opportunity.ready,
              opportunity.localRepairPressure >= OrganismResidualRepair.minimumPressure,
              opportunity.evidenceCount > 0 else { return (field, state) }

        var nextField = field
        var operations: [OrganismRepairOperation] = []
        repairResidualCharge(
            ids: opportunity.chargedNodeIDs,
            in: &nextField,
            operations: &operations,
            limit: limits.maximumOperations
        )
        repairResidualNoise(
            ids: opportunity.noisyEdgeIDs,
            in: &nextField,
            operations: &operations,
            limit: limits.maximumOperations
        )
        guard !operations.isEmpty else { return (field, state) }

        let evidence = [OrganismDreamRepairEvidence(
            id: "evidence:residual-pressure",
            label: "Prediction and field residuals",
            summary: "Local residual repair used \(opportunity.evidenceCount) bounded evidence signal(s)."
        )]
        let receipt = OrganismDreamRepairReceipt(
            id: makeUUID(),
            generatedAt: date,
            reason: "residual_pressure",
            feltDaySummaryCharacters: 0,
            operations: operations,
            evidence: evidence,
            standingViewProposals: [],
            proposedStandingViewCount: 0,
            flagCount: 0,
            sourceFieldGeneration: acknowledgedGeneration(
                after: nextField,
                currentGeneration: nextField.mutationGeneration,
                previousGeneration: state.lastReceipt?.sourceFieldGeneration ?? 0
            )
        )
        nextField.lastUpdatedAt = date
        return (
            nextField,
            OrganismDreamRepairState(
                receiptCount: state.receiptCount + 1,
                lastReceipt: receipt,
                sleepControl: state.sleepControl
            )
        )
    }

    private static func repairResidualCharge(
        ids: [String],
        in field: inout OrganismField,
        operations: inout [OrganismRepairOperation],
        limit: Int
    ) {
        for id in ids.prefix(max(0, limit - operations.count)) {
            guard var node = field.nodes[id], node.charge >= 0.12 else { continue }
            let before = node.charge
            node.charge = OrganismNode.clamp01(node.charge * 0.52)
            node.activation = max(0.05, OrganismNode.clamp01(node.activation * 0.82))
            field.nodes[id] = node
            operations.append(OrganismRepairOperation(
                id: "soften:\(id)",
                kind: .softenHighArousal,
                targetID: id,
                delta: node.charge - before
            ))
        }
    }

    /// A field generation is acknowledged only after every repairable charge
    /// or noisy-loop target from that generation has fallen below threshold.
    /// Bounded passes therefore keep re-arming without replaying settled
    /// targets or losing the fifth-and-later target behind an operation cap.
    private static func acknowledgedGeneration(
        after field: OrganismField,
        currentGeneration: UInt64,
        previousGeneration: UInt64
    ) -> UInt64 {
        let hasChargedNode = field.nodes.values.contains { $0.charge >= 0.12 }
        let hasNoisyEdge = field.edges.values.contains {
            $0.uncertainty >= 0.18 || ($0.eligibility >= 0.45 && $0.weight >= 0.12)
        }
        return hasChargedNode || hasNoisyEdge
            ? min(previousGeneration, currentGeneration)
            : currentGeneration
    }

    private static func repairResidualNoise(
        ids: [String],
        in field: inout OrganismField,
        operations: inout [OrganismRepairOperation],
        limit: Int
    ) {
        for id in ids.prefix(max(0, limit - operations.count)) {
            guard var edge = field.edges[id],
                  edge.uncertainty >= 0.18 || (edge.eligibility >= 0.45 && edge.weight >= 0.12)
            else { continue }
            let before = edge.weight
            edge.weight = max(0.01, OrganismNode.clamp01(edge.weight * 0.76))
            edge.uncertainty = OrganismNode.clamp01(edge.uncertainty * 0.62)
            edge.eligibility = OrganismNode.clamp01(edge.eligibility * 0.50)
            field.edges[id] = edge
            operations.append(OrganismRepairOperation(
                id: "weaken:\(id)",
                kind: .weakenNoisyLoop,
                targetID: id,
                delta: edge.weight - before
            ))
        }
    }

    private static func repairHighChargeNodes(
        in field: inout OrganismField,
        operations: inout [OrganismRepairOperation],
        limit: Int
    ) {
        guard operations.count < limit else { return }
        let targets = field.nodes.values
            .filter { $0.charge >= 0.12 }
            .sorted {
                if $0.charge != $1.charge { return $0.charge > $1.charge }
                return $0.id < $1.id
            }
            .prefix(max(0, limit - operations.count))
        for node in targets {
            guard var copy = field.nodes[node.id] else { continue }
            let before = copy.charge
            copy.charge = OrganismNode.clamp01(copy.charge * 0.52)
            copy.activation = max(0.05, OrganismNode.clamp01(copy.activation * 0.82))
            field.nodes[node.id] = copy
            operations.append(OrganismRepairOperation(
                id: "soften:\(node.id)",
                kind: .softenHighArousal,
                targetID: node.id,
                delta: copy.charge - before
            ))
        }
    }

    private static func strengthenWarmAssociations(
        in field: inout OrganismField,
        operations: inout [OrganismRepairOperation],
        limit: Int
    ) {
        guard operations.count < limit else { return }
        let targets = field.edges.values
            .filter { $0.uncertainty <= 0.12 && $0.weight > 0 }
            .sorted {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                return $0.id < $1.id
            }
            .prefix(min(3, max(0, limit - operations.count)))
        for edge in targets {
            guard var copy = field.edges[edge.id] else { continue }
            let before = copy.weight
            copy.weight = OrganismNode.clamp01(copy.weight + 0.035)
            copy.eligibility = OrganismNode.clamp01(copy.eligibility * 0.65)
            field.edges[edge.id] = copy
            operations.append(OrganismRepairOperation(
                id: "warm:\(edge.id)",
                kind: .strengthenWarmAssociation,
                targetID: edge.id,
                delta: copy.weight - before
            ))
        }
    }

    private static func weakenNoisyLoops(
        in field: inout OrganismField,
        operations: inout [OrganismRepairOperation],
        limit: Int
    ) {
        guard operations.count < limit else { return }
        let targets = field.edges.values
            .filter { $0.uncertainty >= 0.18 || ($0.eligibility >= 0.45 && $0.weight >= 0.12) }
            .sorted {
                if $0.uncertainty != $1.uncertainty { return $0.uncertainty > $1.uncertainty }
                if $0.eligibility != $1.eligibility { return $0.eligibility > $1.eligibility }
                return $0.id < $1.id
            }
            .prefix(min(4, max(0, limit - operations.count)))
        for edge in targets {
            guard var copy = field.edges[edge.id] else { continue }
            let before = copy.weight
            copy.weight = max(0.01, OrganismNode.clamp01(copy.weight * 0.76))
            copy.uncertainty = OrganismNode.clamp01(copy.uncertainty * 0.62)
            copy.eligibility = OrganismNode.clamp01(copy.eligibility * 0.50)
            field.edges[edge.id] = copy
            operations.append(OrganismRepairOperation(
                id: "weaken:\(edge.id)",
                kind: .weakenNoisyLoop,
                targetID: edge.id,
                delta: copy.weight - before
            ))
        }
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
        for key in ["feltDaySummary", "felt_day_summary", "feltSummary", "summary"] {
            guard case .string(let raw)? = metadata[key] else { continue }
            return String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        return ""
    }
}

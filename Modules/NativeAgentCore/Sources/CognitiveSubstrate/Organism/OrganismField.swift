import Foundation
import PersistenceCore

public enum OrganismNodeKind: String, Codable, Sendable, Equatable, CaseIterable {
    case organ
    case signal
    case body
}

public struct OrganismNode: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: OrganismNodeKind
    public var label: String
    public var activation: Double
    public var charge: Double
    public var lastActivatedAt: Date

    public init(
        id: String,
        kind: OrganismNodeKind,
        label: String,
        activation: Double = 0,
        charge: Double = 0,
        lastActivatedAt: Date
    ) {
        self.id = Self.boundedID(id)
        self.kind = kind
        self.label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.activation = Self.clamp01(activation)
        self.charge = Self.clamp01(charge)
        self.lastActivatedAt = lastActivatedAt
    }

    private static func boundedID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : String(trimmed.prefix(96))
    }

    static func clamp01(_ value: Double) -> Double {
        (value).clamped01()
    }
}

public struct OrganismEdge: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sourceID: String
    public var targetID: String
    public var weight: Double
    public var uncertainty: Double
    public var eligibility: Double
    public var coActivations: Int
    public var lastUpdatedAt: Date

    public init(
        sourceID: String,
        targetID: String,
        weight: Double = 0,
        uncertainty: Double = 0,
        eligibility: Double = 0,
        coActivations: Int = 0,
        lastUpdatedAt: Date
    ) {
        let pair = Self.canonicalPair(sourceID, targetID)
        self.sourceID = pair.0
        self.targetID = pair.1
        self.id = Self.edgeID(sourceID: pair.0, targetID: pair.1)
        self.weight = OrganismNode.clamp01(weight)
        self.uncertainty = OrganismNode.clamp01(uncertainty)
        self.eligibility = OrganismNode.clamp01(eligibility)
        self.coActivations = max(0, coActivations)
        self.lastUpdatedAt = lastUpdatedAt
    }

    static func edgeID(sourceID: String, targetID: String) -> String {
        let pair = canonicalPair(sourceID, targetID)
        return "\(pair.0)|\(pair.1)"
    }

    private static func canonicalPair(_ a: String, _ b: String) -> (String, String) {
        a <= b ? (a, b) : (b, a)
    }
}

public struct OrganismFieldLimits: Sendable, Equatable {
    public var maximumNodes: Int
    public var maximumEdges: Int

    public init(maximumNodes: Int = 96, maximumEdges: Int = 192) {
        self.maximumNodes = max(0, maximumNodes)
        self.maximumEdges = max(0, maximumEdges)
    }

    public static let defaults = OrganismFieldLimits()
}

public struct OrganismFieldSummary: Codable, Sendable, Equatable {
    public var nodeCount: Int
    public var edgeCount: Int
    public var strongestEdgeWeight: Double
    public var highestActivation: Double
    public var totalCharge: Double
    public var averageUncertainty: Double

    public init(
        nodeCount: Int = 0,
        edgeCount: Int = 0,
        strongestEdgeWeight: Double = 0,
        highestActivation: Double = 0,
        totalCharge: Double = 0,
        averageUncertainty: Double = 0
    ) {
        self.nodeCount = max(0, nodeCount)
        self.edgeCount = max(0, edgeCount)
        self.strongestEdgeWeight = OrganismNode.clamp01(strongestEdgeWeight)
        self.highestActivation = OrganismNode.clamp01(highestActivation)
        self.totalCharge = max(0, totalCharge)
        self.averageUncertainty = OrganismNode.clamp01(averageUncertainty)
    }

    public static let empty = OrganismFieldSummary()
}

public struct OrganismField: Codable, Sendable, Equatable {
    public var nodes: [String: OrganismNode]
    public var edges: [String: OrganismEdge]
    public var lastUpdatedAt: Date?
    /// Monotonic local mutation generation. Source timestamps remain
    /// provenance; repair acknowledgement uses this generation so delayed
    /// events cannot be lost and repaired tissue is not replayed.
    public var mutationGeneration: UInt64

    public init(
        nodes: [String: OrganismNode] = [:],
        edges: [String: OrganismEdge] = [:],
        lastUpdatedAt: Date? = nil,
        mutationGeneration: UInt64 = 0
    ) {
        self.nodes = nodes
        self.edges = edges
        self.lastUpdatedAt = lastUpdatedAt
        self.mutationGeneration = mutationGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case nodes, edges, lastUpdatedAt, mutationGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            nodes: try container.decodeIfPresent([String: OrganismNode].self, forKey: .nodes) ?? [:],
            edges: try container.decodeIfPresent([String: OrganismEdge].self, forKey: .edges) ?? [:],
            lastUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt),
            mutationGeneration: try container.decodeIfPresent(UInt64.self, forKey: .mutationGeneration) ?? 0
        )
    }

    public static let empty = OrganismField()

    public func summary() -> OrganismFieldSummary {
        let strongestEdgeWeight = edges.values.map(\.weight).max() ?? 0
        let highestActivation = nodes.values.map(\.activation).max() ?? 0
        let totalCharge = nodes.values.reduce(0) { $0 + $1.charge }
        let averageUncertainty = edges.isEmpty
            ? 0
            : edges.values.reduce(0) { $0 + $1.uncertainty } / Double(edges.count)
        return OrganismFieldSummary(
            nodeCount: nodes.count,
            edgeCount: edges.count,
            strongestEdgeWeight: strongestEdgeWeight,
            highestActivation: highestActivation,
            totalCharge: totalCharge,
            averageUncertainty: averageUncertainty
        )
    }

    public func edge(sourceID: String, targetID: String) -> OrganismEdge? {
        edges[OrganismEdge.edgeID(sourceID: sourceID, targetID: targetID)]
    }
}

public enum OrganismPlasticity {
    public static func applying(
        signal: SomaticSignal,
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        to field: OrganismField,
        limits: OrganismFieldLimits = .defaults
    ) -> OrganismField {
        // 2026-07-21 audit fix: NO wall-clock decay here. The kernel's
        // settleElapsedTime (anchored at lastSettledAt) is now the SINGLE
        // wall-clock decay path — this function previously ran a SECOND decay
        // over the same inter-signal interval with a drifted factor table
        // (0.86/0.94/0.72 vs the kernel's 0.82/0.90/0.65), so activation,
        // charge, and Hebbian eligibility decayed at roughly double the
        // intended rate (eligibility half-life ~0.9h vs the designed ~1.7h).
        var next = field
        next.mutationGeneration &+= 1
        if isRepairSignal(signal.kind) {
            next = softened(next, intensity: signal.intensity)
        }

        let activeNodes = nodes(for: signal, bodySchema: bodySchema)
        guard !activeNodes.isEmpty else {
            next.lastUpdatedAt = signal.occurredAt
            return enforcingCapacity(next, limits: limits)
        }

        let activationImpulse = activationImpulse(for: signal)
        let chargeImpulse = chargeImpulse(for: signal)
        for template in activeNodes {
            var node = next.nodes[template.id] ?? template
            node.activation = OrganismNode.clamp01(node.activation + activationImpulse)
            node.charge = OrganismNode.clamp01(node.charge + chargeImpulse)
            node.lastActivatedAt = signal.occurredAt
            next.nodes[node.id] = node
        }

        for pair in unorderedPairs(activeNodes.map(\.id)) {
            let edgeID = OrganismEdge.edgeID(sourceID: pair.0, targetID: pair.1)
            var edge = next.edges[edgeID] ?? OrganismEdge(
                sourceID: pair.0,
                targetID: pair.1,
                lastUpdatedAt: signal.occurredAt
            )
            applyPlasticity(
                signal: signal,
                chemicalState: chemicalState,
                edge: &edge
            )
            next.edges[edge.id] = edge
        }

        if isRepairSignal(signal.kind) {
            next = softened(next, intensity: signal.intensity * 0.5)
        }
        next.lastUpdatedAt = signal.occurredAt
        return enforcingCapacity(next, limits: limits)
    }

    private static func softened(_ field: OrganismField, intensity: Double) -> OrganismField {
        let bounded = OrganismNode.clamp01(intensity)
        let chargeFactor = 1 - (0.42 * bounded)
        let eligibilityFactor = 1 - (0.50 * bounded)
        let uncertaintyFactor = 1 - (0.16 * bounded)
        var next = field
        next.nodes = field.nodes.mapValues { node in
            var copy = node
            copy.charge = OrganismNode.clamp01(copy.charge * chargeFactor)
            copy.activation = OrganismNode.clamp01(copy.activation * (1 - 0.16 * bounded))
            return copy
        }
        next.edges = field.edges.mapValues { edge in
            var copy = edge
            copy.eligibility = OrganismNode.clamp01(copy.eligibility * eligibilityFactor)
            copy.uncertainty = OrganismNode.clamp01(copy.uncertainty * uncertaintyFactor)
            return copy
        }
        return next
    }

    private static func applyPlasticity(
        signal: SomaticSignal,
        chemicalState: ChemicalState,
        edge: inout OrganismEdge
    ) {
        let intensity = OrganismNode.clamp01(signal.intensity)
        let warmBoost = 1 + (chemicalState.warmth * 0.45) + (chemicalState.coherence * 0.25)
        let cautionDrag = max(0.55, 1 - (chemicalState.vigilance * 0.15) - (chemicalState.fatigue * 0.10))
        let baseLearning = 0.035 * (0.35 + intensity * 0.65) * warmBoost * cautionDrag
        let sign = learningSign(for: signal.kind)

        switch sign {
        case .strengthen(let multiplier):
            edge.weight = OrganismNode.clamp01(edge.weight + baseLearning * multiplier)
            edge.uncertainty = OrganismNode.clamp01(edge.uncertainty * (1 - 0.08 * intensity))
        case .weaken(let multiplier):
            edge.weight = max(0.02, OrganismNode.clamp01(edge.weight - baseLearning * multiplier))
            edge.uncertainty = OrganismNode.clamp01(edge.uncertainty + 0.10 * intensity)
        case .uncertain(let multiplier):
            edge.weight = OrganismNode.clamp01(edge.weight + baseLearning * multiplier)
            edge.uncertainty = OrganismNode.clamp01(edge.uncertainty + 0.08 * intensity)
        }

        edge.eligibility = OrganismNode.clamp01(edge.eligibility + 0.18 * intensity)
        edge.coActivations += 1
        edge.lastUpdatedAt = signal.occurredAt
    }

    private enum LearningSign {
        case strengthen(Double)
        case weaken(Double)
        case uncertain(Double)
    }

    private static func learningSign(for kind: SomaticSignalKind) -> LearningSign {
        switch kind {
        case .toolSucceeded, .providerSucceeded, .providerRecovered, .phoneDeliveryReceived,
             .deskItemClosed, .memoryCommitted, .memoryHygieneCompleted,
             .dreamCompleted, .remIntegrated, .iPhoneReachable,
             .approvalResolved, .assistantSpoke:
            return .strengthen(1.2)
        case .correctionReceived, .memoryCorrected:
            return .weaken(0.65)
        case .toolFailed, .providerFailed, .phoneDeliveryFailed, .deskItemBlocked, .iPhoneStale,
             .approvalRequested, .resourcePressureChanged:
            return .uncertain(0.35)
        case .userSpoke, .toolStarted, .toolCancelled, .providerStarted, .providerCancelled,
             .phoneDeliveryStarted, .deskItemCreated, .appWake, .appSleep:
            return .strengthen(0.7)
        }
    }

    private static func activationImpulse(for signal: SomaticSignal) -> Double {
        let base = isRepairSignal(signal.kind) ? 0.12 : 0.16
        return OrganismNode.clamp01(base + 0.54 * signal.intensity)
    }

    private static func chargeImpulse(for signal: SomaticSignal) -> Double {
        let intensity = OrganismNode.clamp01(signal.intensity)
        let arousal = signal.arousal.map(OrganismNode.clamp01) ?? defaultArousal(for: signal.kind)
        let negativeValence = max(0, -(signal.valence ?? defaultValence(for: signal.kind)))
        let base = 0.03 + (0.12 * arousal) + (0.08 * negativeValence)
        return isRepairSignal(signal.kind)
            ? OrganismNode.clamp01(base * intensity * 0.18)
            : OrganismNode.clamp01(base * intensity)
    }

    private static func defaultArousal(for kind: SomaticSignalKind) -> Double {
        switch kind {
        case .toolFailed, .providerFailed, .resourcePressureChanged, .correctionReceived:
            return 0.8
        case .deskItemBlocked, .approvalRequested, .iPhoneStale, .memoryCorrected:
            return 0.6
        case .toolStarted, .appWake:
            return 0.45
        case .appSleep, .dreamCompleted, .remIntegrated:
            return 0.12
        default:
            return 0.3
        }
    }

    // Fallback valence for a signal that reaches the field with nil valence.
    // Single source of truth: SomaticSignalKind.canonicalValence (audit C10 —
    // adapter numbers win, so the former −0.50/0.40 defaults now match the
    // adapter's −0.55/0.45 for the kinds both define; field-fallback-only kinds
    // keep their historical values inside canonicalValence).
    private static func defaultValence(for kind: SomaticSignalKind) -> Double {
        kind.canonicalValence
    }

    private static func nodes(for signal: SomaticSignal, bodySchema: BodySchema) -> [OrganismNode] {
        var nodes: [OrganismNode] = [
            OrganismNode(
                id: "organ:\(canonicalToken(signal.sourceOrgan))",
                kind: .organ,
                label: "organ \(canonicalToken(signal.sourceOrgan))",
                lastActivatedAt: signal.occurredAt
            ),
            OrganismNode(
                id: "signal:\(signal.kind.rawValue)",
                kind: .signal,
                label: signal.kind.rawValue,
                lastActivatedAt: signal.occurredAt
            ),
        ]

        for id in bodyNodeIDs(for: signal.kind, bodySchema: bodySchema, metadata: signal.metadata) {
            nodes.append(OrganismNode(
                id: id,
                kind: .body,
                label: id.replacingOccurrences(of: "body:", with: ""),
                lastActivatedAt: signal.occurredAt
            ))
        }

        var seen: Set<String> = []
        return nodes.filter { seen.insert($0.id).inserted }
    }

    private static func bodyNodeIDs(
        for kind: SomaticSignalKind,
        bodySchema: BodySchema,
        metadata: [String: JSONValue]
    ) -> [String] {
        switch kind {
        case .providerStarted, .providerSucceeded, .providerFailed, .providerCancelled, .providerRecovered:
            return ["body:provider:\(bodySchema.providersHealthy ? "healthy" : "brittle")"]
        case .toolStarted, .toolSucceeded, .toolFailed, .toolCancelled:
            return ["body:tools:\(bodySchema.toolHandsAvailable ? "available" : "unavailable")"]
        case .memoryCommitted, .memoryCorrected, .memoryHygieneCompleted:
            return ["body:memory:\(bodySchema.memoryHealthy ? "healthy" : "brittle")"]
        case .dreamCompleted, .remIntegrated:
            return ["body:dream:\(bodySchema.dreamHealthy ? "healthy" : "brittle")"]
        case .iPhoneReachable, .iPhoneStale, .phoneDeliveryStarted,
             .phoneDeliveryReceived, .phoneDeliveryFailed:
            return ["body:phone:\(bodySchema.iPhoneReachable ? "reachable" : "stale")"]
        case .approvalRequested, .approvalResolved:
            return ["body:approval:\(bodySchema.approvalChannelsOpen ? "open" : "closed")"]
        case .appWake, .appSleep:
            return ["body:mac:\(bodySchema.macAwake ? "awake" : "sleeping")"]
        case .resourcePressureChanged:
            return ["body:resource:\(resourcePressure(from: metadata)?.rawValue ?? bodySchema.resourcePressure.rawValue)"]
        case .userSpoke, .assistantSpoke, .correctionReceived, .deskItemCreated, .deskItemBlocked, .deskItemClosed:
            return []
        }
    }

    private static func resourcePressure(from metadata: [String: JSONValue]) -> OrganismResourcePressure? {
        for key in ["resourcePressure", "resource_pressure", "pressure", "level"] {
            guard case .string(let value)? = metadata[key] else { continue }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let pressure = OrganismResourcePressure(rawValue: normalized) {
                return pressure
            }
            if normalized == "normal" || normalized == "low" { return .nominal }
            if normalized == "medium" { return .elevated }
            if normalized == "thermal" || normalized == "low_power" || normalized == "low-power" {
                return .critical
            }
        }
        return nil
    }

    private static func unorderedPairs(_ ids: [String]) -> [(String, String)] {
        guard ids.count >= 2 else { return [] }
        let sorted = ids.sorted()
        var pairs: [(String, String)] = []
        for i in 0..<(sorted.count - 1) {
            for j in (i + 1)..<sorted.count {
                pairs.append((sorted[i], sorted[j]))
            }
        }
        return pairs
    }

    private static func enforcingCapacity(
        _ field: OrganismField,
        limits: OrganismFieldLimits
    ) -> OrganismField {
        var next = field
        if next.nodes.count > limits.maximumNodes {
            let keep = Set(next.nodes.values.sorted(by: nodeSort).prefix(limits.maximumNodes).map(\.id))
            next.nodes = next.nodes.filter { keep.contains($0.key) }
            next.edges = next.edges.filter { keep.contains($0.value.sourceID) && keep.contains($0.value.targetID) }
        }
        if next.edges.count > limits.maximumEdges {
            let keep = Set(next.edges.values.sorted(by: edgeSort).prefix(limits.maximumEdges).map(\.id))
            next.edges = next.edges.filter { keep.contains($0.key) }
        }
        return next
    }

    private static func nodeSort(_ lhs: OrganismNode, _ rhs: OrganismNode) -> Bool {
        if lhs.activation != rhs.activation { return lhs.activation > rhs.activation }
        if lhs.charge != rhs.charge { return lhs.charge > rhs.charge }
        if lhs.lastActivatedAt != rhs.lastActivatedAt { return lhs.lastActivatedAt > rhs.lastActivatedAt }
        return lhs.id < rhs.id
    }

    private static func edgeSort(_ lhs: OrganismEdge, _ rhs: OrganismEdge) -> Bool {
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        if lhs.eligibility != rhs.eligibility { return lhs.eligibility > rhs.eligibility }
        if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt > rhs.lastUpdatedAt }
        return lhs.id < rhs.id
    }

    private static func isRepairSignal(_ kind: SomaticSignalKind) -> Bool {
        switch kind {
        case .appSleep, .dreamCompleted, .remIntegrated, .memoryHygieneCompleted:
            return true
        default:
            return false
        }
    }

    private static func canonicalToken(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var output = ""
        var previousWasDash = false
        for scalar in lower.unicodeScalars {
            let value = scalar.value
            let isLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            if isLetter || isDigit {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                output.append("-")
                previousWasDash = true
            }
            if output.count >= 48 { break }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}

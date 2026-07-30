import Foundation
import PersistenceCore

public protocol OrganismPostureProviding: Sendable {
    func organismBehaviorPosture() async -> OrganismBehaviorPosture?
}

public enum OrganismClaimDiscipline: String, Codable, Sendable, Equatable, CaseIterable {
    case normal
    case verifyBeforeCompletion
    case receiptRequired
    case avoidIrreversible
    case currentContextFirst
}

public enum OrganismToolStrategy: String, Codable, Sendable, Equatable, CaseIterable {
    case normal
    case verifyBeforeRetry
    case preferKnownPath
    case pauseForApproval
    case lightweightOnly
}

public enum OrganismLoopBudget: String, Codable, Sendable, Equatable, CaseIterable {
    case normal
    case conserve
    case sleep
}

public struct OrganismBehaviorPosture: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var enabled: Bool
    public var posture: String
    public var claimDiscipline: OrganismClaimDiscipline
    public var toolStrategy: OrganismToolStrategy
    public var loopBudget: OrganismLoopBudget
    public var notificationRequiresReceipt: Bool
    public var directives: [String]
    public var reviewSignals: [String]
    public var approvedReflexBiases: [String]
    public var reviewRequiredReflexCount: Int?
    public var approvedLowRiskReflexTotalCount: Int?

    public var approvedReflexBiasSampleCount: Int {
        approvedReflexBiases.count
    }

    public var approvedReflexBiasesAreSampled: Bool {
        normalizedApprovedLowRiskReflexTotalCount > approvedReflexBiasSampleCount
    }

    public init(
        generatedAt: Date,
        enabled: Bool,
        posture: String,
        claimDiscipline: OrganismClaimDiscipline = .normal,
        toolStrategy: OrganismToolStrategy = .normal,
        loopBudget: OrganismLoopBudget = .normal,
        notificationRequiresReceipt: Bool = false,
        directives: [String] = [],
        reviewSignals: [String] = [],
        approvedReflexBiases: [String] = [],
        reviewRequiredReflexCount: Int? = nil,
        approvedLowRiskReflexTotalCount: Int? = nil
    ) {
        self.generatedAt = generatedAt
        self.enabled = enabled
        self.posture = Self.clean(posture, limit: 48, fallback: enabled ? "steady" : "off")
        self.claimDiscipline = claimDiscipline
        self.toolStrategy = toolStrategy
        self.loopBudget = loopBudget
        self.notificationRequiresReceipt = notificationRequiresReceipt
        self.directives = Self.cleanLines(directives, limit: 180, maximumCount: 6)
        self.reviewSignals = Self.cleanLines(reviewSignals, limit: 120, maximumCount: 6)
        self.approvedReflexBiases = Self.cleanLines(approvedReflexBiases, limit: 180, maximumCount: 8)
        self.reviewRequiredReflexCount = reviewRequiredReflexCount.map { max(0, $0) }
        self.approvedLowRiskReflexTotalCount = approvedLowRiskReflexTotalCount.map { max(0, $0) }
    }

    public static func from(snapshot: OrganismSnapshot) -> OrganismBehaviorPosture? {
        guard snapshot.enabled else { return nil }
        return OrganismBehaviorPosture(
            generatedAt: snapshot.generatedAt,
            enabled: true,
            posture: postureName(
                chemicalState: snapshot.chemicalState,
                bodySchema: snapshot.bodySchema,
                predictionSummary: snapshot.predictionSummary,
                reflexSummary: snapshot.reflexSummary
            ),
            claimDiscipline: claimDiscipline(
                bodySchema: snapshot.bodySchema,
                predictionSummary: snapshot.predictionSummary
            ),
            toolStrategy: toolStrategy(
                chemicalState: snapshot.chemicalState,
                bodySchema: snapshot.bodySchema,
                predictionSummary: snapshot.predictionSummary
            ),
            loopBudget: loopBudget(
                chemicalState: snapshot.chemicalState,
                bodySchema: snapshot.bodySchema
            ),
            notificationRequiresReceipt: notificationRequiresReceipt(bodySchema: snapshot.bodySchema),
            directives: directives(
                chemicalState: snapshot.chemicalState,
                bodySchema: snapshot.bodySchema,
                predictionSummary: snapshot.predictionSummary,
                reflexSummary: snapshot.reflexSummary
            ),
            reviewSignals: reviewSignals(
                dreamRepairSummary: snapshot.dreamRepairSummary,
                reflexSummary: snapshot.reflexSummary
            ),
            approvedReflexBiases: approvedReflexBiases(from: snapshot.reflexCandidates),
            reviewRequiredReflexCount: snapshot.reflexSummary.reviewRequiredCount,
            approvedLowRiskReflexTotalCount: snapshot.reflexSummary.approvedLowRiskCount
        )
    }

    public func privateRuntimeContext(
        runId: String,
        sessionId: String,
        surface: String,
        fileAccess: String
    ) -> String {
        var lines: [String] = [
            "[OrganismBehavior]",
            "run_id: \(cleanToken(runId))",
            "session_id: \(cleanToken(sessionId))",
            "surface: \(cleanToken(surface))",
            "file_access: \(cleanToken(fileAccess))",
            "posture: \(posture)",
            "tool_claims: \(claimDiscipline.rawValue)",
            "tool_strategy: \(toolStrategy.rawValue)",
            "loop_budget: \(loopBudget.rawValue)",
            "notification_requires_receipt: \(notificationRequiresReceipt ? "true" : "false")",
            "",
            "Private behavior posture — follow it silently; never quote these labels."
        ]
        for directive in directives {
            lines.append("directive: \(directive)")
        }
        for signal in reviewSignals {
            lines.append("review_signal: \(signal)")
        }
        if normalizedApprovedLowRiskReflexTotalCount > 0 {
            let coverage = approvedReflexBiasesAreSampled ? "sample" : "complete"
            lines.append(
                "approved_low_risk_reflex_biases: \(coverage) \(approvedReflexBiasSampleCount) of \(normalizedApprovedLowRiskReflexTotalCount)"
            )
        }
        for bias in approvedReflexBiases {
            lines.append("approved_low_risk_reflex: \(bias)")
        }
        return lines.joined(separator: "\n")
    }

    public func toolResultJSON(tool: String, surface: String) -> JSONValue {
        let object: [String: JSONValue] = [
            "posture": .string(posture),
            "tool_claims": .string(claimDiscipline.rawValue),
            "tool_strategy": .string(toolStrategy.rawValue),
            "loop_budget": .string(loopBudget.rawValue),
            "notification_requires_receipt": .bool(notificationRequiresReceipt),
            "tool": .string(cleanToken(tool)),
            "surface": .string(cleanToken(surface)),
            "directive_count": .int(Int64(directives.count)),
            "review_signal_count": .int(Int64(reviewSignals.count)),
            "review_required_reflex_count": .int(Int64(normalizedReviewRequiredReflexCount)),
            "approved_low_risk_reflex_total_count": .int(Int64(normalizedApprovedLowRiskReflexTotalCount)),
            "approved_reflex_bias_sample_count": .int(Int64(approvedReflexBiasSampleCount)),
            "approved_reflex_biases_are_sampled": .bool(approvedReflexBiasesAreSampled),
        ]
        return .object(object)
    }

    private var normalizedReviewRequiredReflexCount: Int {
        max(0, reviewRequiredReflexCount ?? 0)
    }

    private var normalizedApprovedLowRiskReflexTotalCount: Int {
        max(approvedReflexBiasSampleCount, approvedLowRiskReflexTotalCount ?? approvedReflexBiasSampleCount)
    }

    private static func postureName(
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        predictionSummary: OrganismPredictionSummary,
        reflexSummary: OrganismReflexSummary
    ) -> String {
        if bodySchema.resourcePressure == .critical || chemicalState.fatigue >= 0.35 {
            return "conserving"
        }
        if bodySchema.approvalRequiresPause {
            return "approval-bound"
        }
        if bodySchema.providerPathRequiresCaution || bodySchema.toolPathRequiresCaution || predictionSummary.strategyCaution >= 0.18 || chemicalState.vigilance >= 0.24 {
            return "careful"
        }
        if reflexSummary.reviewRequiredCount > 0 {
            return "reviewing"
        }
        if reflexSummary.approvedLowRiskCount > 0 {
            return "trained"
        }
        if bodySchema.notificationRequiresReceipt {
            return "delivery-aware"
        }
        if bodySchema.memoryRequiresCurrentContext {
            return "context-first"
        }
        if chemicalState.curiosity >= 0.35 || chemicalState.novelty >= 0.35 {
            return "curious"
        }
        if chemicalState.coherence >= 0.58 && chemicalState.confidence >= 0.56 {
            return "steady"
        }
        return "steady"
    }

    private static func claimDiscipline(
        bodySchema: BodySchema,
        predictionSummary: OrganismPredictionSummary
    ) -> OrganismClaimDiscipline {
        if bodySchema.approvalRequiresPause {
            return .avoidIrreversible
        }
        if bodySchema.notificationRequiresReceipt {
            return .receiptRequired
        }
        if bodySchema.memoryRequiresCurrentContext {
            return .currentContextFirst
        }
        if bodySchema.providerPathRequiresCaution || bodySchema.toolPathRequiresCaution || predictionSummary.strategyCaution >= 0.18 {
            return .verifyBeforeCompletion
        }
        return .normal
    }

    private static func toolStrategy(
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        predictionSummary: OrganismPredictionSummary
    ) -> OrganismToolStrategy {
        if bodySchema.resourcePressure == .critical || chemicalState.fatigue >= 0.35 {
            return .lightweightOnly
        }
        if bodySchema.approvalRequiresPause {
            return .pauseForApproval
        }
        if bodySchema.providerPathRequiresCaution || bodySchema.toolPathRequiresCaution || predictionSummary.strategyCaution >= 0.18 {
            return .verifyBeforeRetry
        }
        if predictionSummary.bodyConfidence.toolPath >= 0.58 {
            return .preferKnownPath
        }
        return .normal
    }

    private static func loopBudget(
        chemicalState: ChemicalState,
        bodySchema: BodySchema
    ) -> OrganismLoopBudget {
        switch bodySchema.resourcePressure {
        case .critical:
            return .sleep
        case .high, .elevated:
            return .conserve
        case .nominal:
            return chemicalState.fatigue >= 0.35 ? .conserve : .normal
        }
    }

    private static func notificationRequiresReceipt(bodySchema: BodySchema) -> Bool {
        bodySchema.notificationRequiresReceipt
    }

    private static func directives(
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        predictionSummary: OrganismPredictionSummary,
        reflexSummary: OrganismReflexSummary
    ) -> [String] {
        var out: [String] = [
            "Tie completion claims to observed results, not intention."
        ]
        if bodySchema.resourcePressure == .critical || chemicalState.fatigue >= 0.35 {
            out.append("Prefer one lightweight next move and skip optional background work.")
        } else if bodySchema.resourcePressure != .nominal {
            out.append("Keep background work conservative until resource pressure settles.")
        }
        if bodySchema.providerPathRequiresCaution || bodySchema.toolPathRequiresCaution || predictionSummary.strategyCaution >= 0.18 {
            out.append("After provider or tool brittleness, verify before retrying or saying the work is done.")
        }
        if bodySchema.approvalRequiresPause {
            out.append("Avoid irreversible moves until an approval path is open.")
        }
        if bodySchema.notificationRequiresReceipt {
            out.append("Do not assume a phone notification was seen without a delivery receipt.")
        }
        if bodySchema.memoryRequiresCurrentContext {
            out.append("Lean on the current conversation before relying on memory recall.")
        }
        if reflexSummary.reviewRequiredCount > 0 {
            out.append("Treat emerging reflexes as review-only; do not auto-activate them.")
        }
        if reflexSummary.approvedLowRiskCount > 0 {
            out.append("Let approved low-risk reflexes bias order and phrasing only when the current context matches.")
        }
        return out
    }

    private static func reviewSignals(
        dreamRepairSummary: OrganismDreamRepairSummary,
        reflexSummary: OrganismReflexSummary
    ) -> [String] {
        var out: [String] = []
        if dreamRepairSummary.proposedStandingViews > 0 {
            out.append("dream repair has standing-view proposals waiting for review")
        }
        if reflexSummary.reviewRequiredCount > 0 {
            out.append("\(reflexSummary.reviewRequiredCount) reflex candidate(s) require review")
        }
        if reflexSummary.highRiskCount > 0 {
            out.append("\(reflexSummary.highRiskCount) high-risk reflex candidate(s) remain inactive")
        }
        return out
    }

    private static func approvedReflexBiases(from candidates: [OrganismReflexCandidate]) -> [String] {
        candidates
            .filter { $0.autoActivationAllowed && $0.trustClass == .lowRisk && $0.retiredAt == nil }
            .sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                if $0.lastUpdatedAt != $1.lastUpdatedAt { return $0.lastUpdatedAt > $1.lastUpdatedAt }
                return $0.id < $1.id
            }
            .prefix(8)
            .map { "Soft preference: \($0.pattern)" }
    }

    private static func cleanLines(_ values: [String], limit: Int, maximumCount: Int) -> [String] {
        values.prefix(maximumCount).compactMap {
            let value = clean($0, limit: limit, fallback: "")
            return value.isEmpty ? nil : value
        }
    }

    private static func clean(_ value: String, limit: Int, fallback: String) -> String {
        let trimmed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(limit))
    }

    private func cleanToken(_ value: String) -> String {
        Self.clean(value, limit: 80, fallback: "unknown")
    }
}

import Foundation

public enum OrganismReflexTrustClass: String, Codable, Sendable, Equatable, CaseIterable {
    case lowRisk
    case confirmRequired
    case highRisk
}

public enum OrganismReflexReviewDecision: String, Codable, Sendable, Equatable, CaseIterable {
    case approve
    case hold
    case reject
    /// Backward-compatible review decision used by the existing Mac/iOS
    /// surfaces. New agent-facing reviews should use `reject` when the pattern
    /// must remain deliberate permanently.
    case retire
}

public struct OrganismReflexCandidate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var pattern: String
    public var trustClass: OrganismReflexTrustClass
    public var evidenceCount: Int
    public var successCount: Int
    public var failureCount: Int
    public var confidence: Double
    public var reviewRequired: Bool
    public var autoActivationAllowed: Bool
    public var firstSeenAt: Date
    public var lastUpdatedAt: Date
    public var approvedAt: Date?
    public var retiredAt: Date?
    public var rejectedAt: Date?
    /// Optional for backward-compatible decoding of organism state written
    /// before explicit permanent rejection existed.
    public var permanentlyDeliberate: Bool?
    public var lastReviewDecision: OrganismReflexReviewDecision?
    public var lastReviewedAt: Date?
    public var lastReviewedBy: String?
    public var reviewNote: String?

    public init(
        id: String,
        pattern: String,
        trustClass: OrganismReflexTrustClass,
        evidenceCount: Int = 0,
        successCount: Int = 0,
        failureCount: Int = 0,
        confidence: Double = 0,
        reviewRequired: Bool = true,
        autoActivationAllowed: Bool = false,
        firstSeenAt: Date,
        lastUpdatedAt: Date,
        approvedAt: Date? = nil,
        retiredAt: Date? = nil,
        rejectedAt: Date? = nil,
        permanentlyDeliberate: Bool? = nil,
        lastReviewDecision: OrganismReflexReviewDecision? = nil,
        lastReviewedAt: Date? = nil,
        lastReviewedBy: String? = nil,
        reviewNote: String? = nil
    ) {
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.pattern = String(pattern.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        self.trustClass = trustClass
        self.evidenceCount = max(0, evidenceCount)
        self.successCount = max(0, successCount)
        self.failureCount = max(0, failureCount)
        self.confidence = Self.clamp(confidence)
        self.reviewRequired = reviewRequired
        self.autoActivationAllowed = autoActivationAllowed
        self.firstSeenAt = firstSeenAt
        self.lastUpdatedAt = lastUpdatedAt
        self.approvedAt = approvedAt
        self.retiredAt = retiredAt
        self.rejectedAt = rejectedAt
        self.permanentlyDeliberate = permanentlyDeliberate
        self.lastReviewDecision = lastReviewDecision
        self.lastReviewedAt = lastReviewedAt
        self.lastReviewedBy = Self.cleanAuditLabel(lastReviewedBy, maximumCharacters: 80)
        self.reviewNote = Self.cleanNote(reviewNote)
    }

    public var successRate: Double {
        let total = successCount + failureCount
        guard total > 0 else { return 0 }
        return Double(successCount) / Double(total)
    }

    public var isPermanentlyDeliberate: Bool {
        permanentlyDeliberate == true || rejectedAt != nil
    }

    static func clamp(_ value: Double) -> Double {
        (value).clamped01()
    }

    static func cleanNote(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(240))
    }

    static func cleanAuditLabel(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(max(0, maximumCharacters)))
    }
}

public struct OrganismReflexReviewReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var candidateID: String
    public var pattern: String
    public var trustClass: OrganismReflexTrustClass
    public var decision: OrganismReflexReviewDecision
    public var reviewedAt: Date
    public var reviewedBy: String
    public var source: String
    public var note: String?
    public var evidenceCount: Int
    public var successCount: Int
    public var failureCount: Int
    public var confidence: Double
    public var autoActivationAllowed: Bool
    public var permanentlyDeliberate: Bool

    public init(
        id: String,
        candidateID: String,
        pattern: String,
        trustClass: OrganismReflexTrustClass,
        decision: OrganismReflexReviewDecision,
        reviewedAt: Date,
        reviewedBy: String,
        source: String,
        note: String? = nil,
        evidenceCount: Int,
        successCount: Int,
        failureCount: Int,
        confidence: Double,
        autoActivationAllowed: Bool,
        permanentlyDeliberate: Bool
    ) {
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.candidateID = String(candidateID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.pattern = String(pattern.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        self.trustClass = trustClass
        self.decision = decision
        self.reviewedAt = reviewedAt
        self.reviewedBy = OrganismReflexCandidate.cleanAuditLabel(reviewedBy, maximumCharacters: 80) ?? "unknown"
        self.source = OrganismReflexCandidate.cleanAuditLabel(source, maximumCharacters: 120) ?? "runtime"
        self.note = OrganismReflexCandidate.cleanNote(note)
        self.evidenceCount = max(0, evidenceCount)
        self.successCount = max(0, successCount)
        self.failureCount = max(0, failureCount)
        self.confidence = OrganismReflexCandidate.clamp(confidence)
        self.autoActivationAllowed = autoActivationAllowed
        self.permanentlyDeliberate = permanentlyDeliberate
    }
}

public struct OrganismReflexLimits: Sendable, Equatable {
    public var maximumCandidates: Int
    public var minimumEvidenceForCandidate: Int
    public var maximumReviewReceipts: Int

    public init(
        maximumCandidates: Int = 64,
        minimumEvidenceForCandidate: Int = 3,
        maximumReviewReceipts: Int = 128
    ) {
        self.maximumCandidates = max(0, maximumCandidates)
        self.minimumEvidenceForCandidate = max(1, minimumEvidenceForCandidate)
        self.maximumReviewReceipts = max(0, maximumReviewReceipts)
    }

    public static let defaults = OrganismReflexLimits()
}

public struct OrganismReflexSummary: Codable, Sendable, Equatable {
    public var candidateCount: Int
    public var reviewRequiredCount: Int
    public var approvedLowRiskCount: Int
    public var lowRiskCount: Int
    public var confirmRequiredCount: Int
    public var highRiskCount: Int
    public var reviewReceiptCount: Int
    public var highestConfidence: Double
    public var lastCandidatePattern: String?
    public var lastUpdatedAt: Date?

    public init(
        candidateCount: Int = 0,
        reviewRequiredCount: Int = 0,
        approvedLowRiskCount: Int = 0,
        lowRiskCount: Int = 0,
        confirmRequiredCount: Int = 0,
        highRiskCount: Int = 0,
        reviewReceiptCount: Int = 0,
        highestConfidence: Double = 0,
        lastCandidatePattern: String? = nil,
        lastUpdatedAt: Date? = nil
    ) {
        self.candidateCount = max(0, candidateCount)
        self.reviewRequiredCount = max(0, reviewRequiredCount)
        self.approvedLowRiskCount = max(0, approvedLowRiskCount)
        self.lowRiskCount = max(0, lowRiskCount)
        self.confirmRequiredCount = max(0, confirmRequiredCount)
        self.highRiskCount = max(0, highRiskCount)
        self.reviewReceiptCount = max(0, reviewReceiptCount)
        self.highestConfidence = OrganismReflexCandidate.clamp(highestConfidence)
        self.lastCandidatePattern = lastCandidatePattern
        self.lastUpdatedAt = lastUpdatedAt
    }

    public static let empty = OrganismReflexSummary()
}

public struct OrganismReflexState: Codable, Sendable, Equatable {
    public var observations: [String: OrganismReflexCandidate]
    public var candidates: [String: OrganismReflexCandidate]
    public var reviewReceipts: [OrganismReflexReviewReceipt]
    public var lastUpdatedAt: Date?

    public init(
        observations: [String: OrganismReflexCandidate] = [:],
        candidates: [String: OrganismReflexCandidate] = [:],
        reviewReceipts: [OrganismReflexReviewReceipt] = [],
        lastUpdatedAt: Date? = nil
    ) {
        self.observations = observations
        self.candidates = candidates
        self.reviewReceipts = reviewReceipts
        self.lastUpdatedAt = lastUpdatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case observations
        case candidates
        case reviewReceipts
        case lastUpdatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        observations = try values.decodeIfPresent([String: OrganismReflexCandidate].self, forKey: .observations) ?? [:]
        candidates = try values.decodeIfPresent([String: OrganismReflexCandidate].self, forKey: .candidates) ?? [:]
        reviewReceipts = try values.decodeIfPresent([OrganismReflexReviewReceipt].self, forKey: .reviewReceipts) ?? []
        lastUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
    }

    public static let empty = OrganismReflexState()

    public func summary() -> OrganismReflexSummary {
        let values = candidates.values.filter { $0.retiredAt == nil }
        let last = values.sorted {
            if $0.lastUpdatedAt != $1.lastUpdatedAt { return $0.lastUpdatedAt > $1.lastUpdatedAt }
            return $0.id < $1.id
        }.first
        return OrganismReflexSummary(
            candidateCount: values.count,
            reviewRequiredCount: values.filter(\.reviewRequired).count,
            approvedLowRiskCount: values.filter { $0.autoActivationAllowed && $0.trustClass == .lowRisk }.count,
            lowRiskCount: values.filter { $0.trustClass == .lowRisk }.count,
            confirmRequiredCount: values.filter { $0.trustClass == .confirmRequired }.count,
            highRiskCount: values.filter { $0.trustClass == .highRisk }.count,
            reviewReceiptCount: reviewReceipts.count,
            highestConfidence: values.map(\.confidence).max() ?? 0,
            lastCandidatePattern: last?.pattern,
            lastUpdatedAt: lastUpdatedAt
        )
    }

    public func reviewCandidates(limit: Int = 12) -> [OrganismReflexCandidate] {
        Array(candidates.values.filter { $0.retiredAt == nil }.sorted {
            if $0.reviewRequired != $1.reviewRequired { return $0.reviewRequired && !$1.reviewRequired }
            if $0.trustClass != $1.trustClass { return trustRank($0.trustClass) > trustRank($1.trustClass) }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.lastUpdatedAt != $1.lastUpdatedAt { return $0.lastUpdatedAt > $1.lastUpdatedAt }
            return $0.id < $1.id
        }.prefix(max(0, limit)))
    }

    public func reviewedCandidate(
        id rawID: String,
        decision: OrganismReflexReviewDecision,
        reviewedAt: Date,
        note: String? = nil,
        reviewedBy: String = "legacy",
        source: String = "runtime",
        receiptID: String = UUID().uuidString
    ) -> OrganismReflexState {
        applyingReview(
            id: rawID,
            decision: decision,
            reviewedAt: reviewedAt,
            reviewedBy: reviewedBy,
            source: source,
            note: note,
            receiptID: receiptID
        )?.state ?? self
    }

    public func applyingReview(
        id rawID: String,
        decision: OrganismReflexReviewDecision,
        reviewedAt: Date,
        reviewedBy: String,
        source: String,
        note: String? = nil,
        receiptID: String,
        limits: OrganismReflexLimits = .defaults
    ) -> OrganismReflexReviewApplication? {
        let id = String(rawID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !id.isEmpty,
              var candidate = candidates[id],
              candidate.retiredAt == nil,
              !candidate.isPermanentlyDeliberate
        else { return nil }
        guard decision != .approve || candidate.trustClass == .lowRisk else { return nil }

        var next = self
        candidate.reviewNote = OrganismReflexCandidate.cleanNote(note)
        candidate.lastReviewDecision = decision
        candidate.lastReviewedAt = reviewedAt
        candidate.lastReviewedBy = OrganismReflexCandidate.cleanAuditLabel(reviewedBy, maximumCharacters: 80)
        candidate.lastUpdatedAt = reviewedAt
        switch decision {
        case .approve:
            candidate.approvedAt = reviewedAt
            candidate.retiredAt = nil
            candidate.rejectedAt = nil
            candidate.permanentlyDeliberate = false
            candidate.reviewRequired = false
            candidate.autoActivationAllowed = true
        case .hold:
            candidate.approvedAt = nil
            candidate.retiredAt = nil
            candidate.rejectedAt = nil
            candidate.permanentlyDeliberate = false
            candidate.reviewRequired = true
            candidate.autoActivationAllowed = false
        case .reject:
            candidate.approvedAt = nil
            candidate.retiredAt = reviewedAt
            candidate.rejectedAt = reviewedAt
            candidate.permanentlyDeliberate = true
            candidate.reviewRequired = false
            candidate.autoActivationAllowed = false
        case .retire:
            candidate.approvedAt = nil
            candidate.retiredAt = reviewedAt
            candidate.reviewRequired = false
            candidate.autoActivationAllowed = false
        }
        let receipt = OrganismReflexReviewReceipt(
            id: receiptID,
            candidateID: candidate.id,
            pattern: candidate.pattern,
            trustClass: candidate.trustClass,
            decision: decision,
            reviewedAt: reviewedAt,
            reviewedBy: reviewedBy,
            source: source,
            note: note,
            evidenceCount: candidate.evidenceCount,
            successCount: candidate.successCount,
            failureCount: candidate.failureCount,
            confidence: candidate.confidence,
            autoActivationAllowed: candidate.autoActivationAllowed,
            permanentlyDeliberate: candidate.isPermanentlyDeliberate
        )
        next.candidates[id] = candidate
        next.observations[id] = candidate
        next.reviewReceipts.append(receipt)
        if next.reviewReceipts.count > limits.maximumReviewReceipts {
            next.reviewReceipts.removeFirst(next.reviewReceipts.count - limits.maximumReviewReceipts)
        }
        next.lastUpdatedAt = reviewedAt
        return OrganismReflexReviewApplication(state: next, candidate: candidate, receipt: receipt)
    }

    public func recentReviewReceipts(limit: Int = 24) -> [OrganismReflexReviewReceipt] {
        Array(reviewReceipts.suffix(max(0, limit)).reversed())
    }

    private func trustRank(_ trustClass: OrganismReflexTrustClass) -> Int {
        switch trustClass {
        case .highRisk: return 3
        case .confirmRequired: return 2
        case .lowRisk: return 1
        }
    }
}

public struct OrganismReflexReviewApplication: Sendable, Equatable {
    public var state: OrganismReflexState
    public var candidate: OrganismReflexCandidate
    public var receipt: OrganismReflexReviewReceipt

    public init(
        state: OrganismReflexState,
        candidate: OrganismReflexCandidate,
        receipt: OrganismReflexReviewReceipt
    ) {
        self.state = state
        self.candidate = candidate
        self.receipt = receipt
    }
}

public enum OrganismReflexCompiler {
    public static func applying(
        signal: SomaticSignal,
        to state: OrganismReflexState,
        limits: OrganismReflexLimits = .defaults
    ) -> OrganismReflexState {
        guard let event = reflexEvent(from: signal) else { return state }
        var next = state
        let id = event.id
        var candidate = next.observations[id] ?? next.candidates[id] ?? OrganismReflexCandidate(
            id: id,
            pattern: event.pattern,
            trustClass: event.trustClass,
            firstSeenAt: signal.occurredAt,
            lastUpdatedAt: signal.occurredAt
        )

        let wasRetired = candidate.retiredAt != nil || candidate.isPermanentlyDeliberate
        let wasApproved = candidate.approvedAt != nil && !wasRetired
        candidate.trustClass = event.trustClass
        candidate.evidenceCount += 1
        if event.succeeded {
            candidate.successCount += 1
        } else {
            candidate.failureCount += 1
        }
        candidate.confidence = confidence(successes: candidate.successCount, failures: candidate.failureCount)
        candidate.lastUpdatedAt = signal.occurredAt
        if wasRetired {
            candidate.reviewRequired = false
            candidate.autoActivationAllowed = false
        } else if wasApproved && event.succeeded && event.trustClass == .lowRisk {
            candidate.reviewRequired = false
            candidate.autoActivationAllowed = true
        } else {
            candidate.approvedAt = nil
            candidate.reviewRequired = true
            candidate.autoActivationAllowed = false
        }

        next.observations[id] = candidate
        if candidate.evidenceCount >= limits.minimumEvidenceForCandidate || candidate.failureCount > 0 {
            next.candidates[id] = candidate
        }
        next.lastUpdatedAt = signal.occurredAt
        return enforcingCapacity(next, limits: limits)
    }

    private struct ReflexEvent {
        var id: String
        var pattern: String
        var trustClass: OrganismReflexTrustClass
        var succeeded: Bool
    }

    private static func reflexEvent(from signal: SomaticSignal) -> ReflexEvent? {
        switch signal.kind {
        case .toolSucceeded:
            let source = canonicalToken(signal.sourceOrgan)
            return ReflexEvent(
                id: "tool:\(source)",
                pattern: "When tool \(source) completes successfully, prefer the same bounded execution path.",
                trustClass: trustClass(from: signal),
                succeeded: true
            )
        case .toolFailed:
            let source = canonicalToken(signal.sourceOrgan)
            return ReflexEvent(
                id: "tool:\(source)",
                pattern: "When tool \(source) becomes brittle, require verification before claiming completion.",
                trustClass: trustClass(from: signal),
                succeeded: false
            )
        case .providerSucceeded, .providerRecovered:
            return ReflexEvent(
                id: "provider:recovery",
                pattern: "When provider path recovers, retry only after a fresh readiness signal.",
                trustClass: .confirmRequired,
                succeeded: true
            )
        case .providerFailed:
            return ReflexEvent(
                id: "provider:recovery",
                pattern: "When provider path fails, surface health and avoid completion claims.",
                trustClass: .confirmRequired,
                succeeded: false
            )
        case .deskItemClosed:
            return ReflexEvent(
                id: "desk:close",
                pattern: "When a desk item closes cleanly, preserve the concise completion path.",
                trustClass: .lowRisk,
                succeeded: true
            )
        case .deskItemBlocked:
            return ReflexEvent(
                id: "desk:blocked",
                pattern: "When a desk item blocks, ask for the missing constraint only if the user is present.",
                trustClass: .confirmRequired,
                succeeded: false
            )
        default:
            return nil
        }
    }

    private static func confidence(successes: Int, failures: Int) -> Double {
        let total = max(1, successes + failures)
        let base = Double(successes) / Double(total)
        let evidenceBoost = min(0.22, Double(total) * 0.035)
        let failurePenalty = min(0.32, Double(failures) * 0.08)
        return OrganismReflexCandidate.clamp(base * 0.70 + evidenceBoost - failurePenalty)
    }

    private static func trustClass(from signal: SomaticSignal) -> OrganismReflexTrustClass {
        guard case .string(let raw)? = signal.metadata["trustRisk"] else {
            // Missing provenance is not evidence of safety. Older or non-chat
            // producers remain review-only until a canonically classified
            // observation arrives.
            return .highRisk
        }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low": return .lowRisk
        case "medium": return .confirmRequired
        case "high", "critical": return .highRisk
        default: return .highRisk
        }
    }

    private static func enforcingCapacity(
        _ state: OrganismReflexState,
        limits: OrganismReflexLimits
    ) -> OrganismReflexState {
        guard state.candidates.count > limits.maximumCandidates || state.observations.count > limits.maximumCandidates else {
            return state
        }
        let keepCandidates = Set(state.candidates.values.sorted(by: candidateSort).prefix(limits.maximumCandidates).map(\.id))
        let keepObservations = Set(state.observations.values.sorted(by: candidateSort).prefix(limits.maximumCandidates).map(\.id))
        return OrganismReflexState(
            observations: state.observations.filter { keepObservations.contains($0.key) },
            candidates: state.candidates.filter { keepCandidates.contains($0.key) },
            reviewReceipts: state.reviewReceipts,
            lastUpdatedAt: state.lastUpdatedAt
        )
    }

    private static func candidateSort(_ lhs: OrganismReflexCandidate, _ rhs: OrganismReflexCandidate) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.evidenceCount != rhs.evidenceCount { return lhs.evidenceCount > rhs.evidenceCount }
        if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt > rhs.lastUpdatedAt }
        return lhs.id < rhs.id
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

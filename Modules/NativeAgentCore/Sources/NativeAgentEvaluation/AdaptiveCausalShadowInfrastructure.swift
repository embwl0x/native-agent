import CryptoKit
import Foundation
import PersistenceCore

// MARK: - Outcome classification

/// A terminal result supplied by the domain owner when the generic transition
/// projection cannot prove verification on its own. It contains no payload,
/// title, path, or raw identifier.
public struct AuthoritativeTerminalOutcomeEvidence: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case verifiedSuccess = "verified_success"
        case verifiedFailure = "verified_failure"
        case cancelled
    }

    public let domain: String
    public let itemIdentity: String
    public let occurredAt: String
    public let kind: Kind

    public init(domain: String, itemIdentity: String, occurredAt: String, kind: Kind) {
        self.domain = domain
        self.itemIdentity = itemIdentity
        self.occurredAt = occurredAt
        self.kind = kind
    }
}

public struct CausalOutcomeClassificationReport: Sendable, Equatable {
    public let transitionCount: Int
    /// Number of transition rows belonging to a trajectory that later reached
    /// a domain-proven terminal result. This is deliberately trajectory-return
    /// coverage, not a claim that every row was itself terminal and not a
    /// per-step next-evidence label. A future trainer must retain that
    /// distinction instead of treating the terminal kind as the immediate
    /// result of each intermediate transition.
    public let outcomeCompleteTransitionCount: Int
    public let terminalTrajectoryCount: Int
    public let incompleteTrajectoryCount: Int
    public let terminalKindCounts: [AuthoritativeTerminalOutcomeEvidence.Kind: Int]

    public var outcomeCoverage: Double {
        transitionCount > 0
            ? Double(outcomeCompleteTransitionCount) / Double(transitionCount)
            : 0
    }
}

/// Correlates reducer transitions by their opaque domain/item identity and
/// counts a transition complete only when the trajectory has a terminal result
/// the domain can actually prove. GitHub `resolved` is verified by its reducer;
/// Workshop failure/cancellation is terminal in the canonical timeline, while
/// Workshop success requires a domain-owned verification override.
public enum CausalTerminalOutcomeClassifier {
    public static func classify(
        transitions: [CausalTransitionEvidence],
        authoritative: [AuthoritativeTerminalOutcomeEvidence] = []
    ) -> CausalOutcomeClassificationReport {
        struct TrajectoryKey: Hashable {
            let domain: String
            let itemIdentity: String
        }

        let grouped = Dictionary(grouping: transitions) {
            TrajectoryKey(domain: $0.domain, itemIdentity: $0.itemIdentity)
        }
        let authoritativeByKey = Dictionary(
            authoritative.map {
                (TrajectoryKey(domain: $0.domain, itemIdentity: $0.itemIdentity), $0)
            },
            uniquingKeysWith: { lhs, rhs in
                (parseAdaptiveCausalDate(lhs.occurredAt) ?? .distantPast)
                    >= (parseAdaptiveCausalDate(rhs.occurredAt) ?? .distantPast) ? lhs : rhs
            }
        )

        var completeTransitions = 0
        var terminalTrajectories = 0
        var incompleteTrajectories = 0
        var kindCounts: [AuthoritativeTerminalOutcomeEvidence.Kind: Int] = [:]

        for (key, rows) in grouped {
            let ordered = rows.sorted(by: causalTransitionOrder)
            let inferred = inferTerminalOutcome(from: ordered)
            let lastTransitionAt = ordered.last.flatMap { parseAdaptiveCausalDate($0.occurredAt) }
            let authoritativeTerminal = authoritativeByKey[key].flatMap { candidate -> AuthoritativeTerminalOutcomeEvidence? in
                guard let terminalAt = parseAdaptiveCausalDate(candidate.occurredAt),
                      let lastTransitionAt,
                      terminalAt >= lastTransitionAt else { return nil }
                return candidate
            }
            let terminal = authoritativeTerminal ?? inferred
            if let terminal {
                completeTransitions += rows.count
                terminalTrajectories += 1
                kindCounts[terminal.kind, default: 0] += 1
            } else {
                incompleteTrajectories += 1
            }
        }

        return CausalOutcomeClassificationReport(
            transitionCount: transitions.count,
            outcomeCompleteTransitionCount: completeTransitions,
            terminalTrajectoryCount: terminalTrajectories,
            incompleteTrajectoryCount: incompleteTrajectories,
            terminalKindCounts: kindCounts
        )
    }

    private static func inferTerminalOutcome(
        from rows: [CausalTransitionEvidence]
    ) -> AuthoritativeTerminalOutcomeEvidence? {
        guard let last = rows.last else { return nil }
        let kind: AuthoritativeTerminalOutcomeEvidence.Kind?
        switch (last.domain, last.afterState?.lowercased()) {
        case ("github_command", "resolved"):
            kind = .verifiedSuccess
        case ("workshop_execution", "failed"):
            kind = .verifiedFailure
        case ("workshop_execution", "cancelled"), ("workshop_execution", "canceled"):
            kind = .cancelled
        default:
            // Workshop `completed` is intentionally absent. Completion without
            // the execution record's verification is not an observed outcome.
            kind = nil
        }
        return kind.map {
            AuthoritativeTerminalOutcomeEvidence(
                domain: last.domain,
                itemIdentity: last.itemIdentity,
                occurredAt: last.occurredAt,
                kind: $0
            )
        }
    }
}

// MARK: - Deterministic time holdout

public struct AdaptiveCausalTimeHoldout: Sendable, Equatable {
    public let requestedDays: Int
    public let cutoffAt: Date?
    public let latestEvidenceAt: Date?
    public let training: [CausalTransitionEvidence]
    public let holdout: [CausalTransitionEvidence]
    public let invalidTimestampCount: Int
    public let elapsedHoldoutDays: Int

    public var ready: Bool {
        elapsedHoldoutDays >= requestedDays && !training.isEmpty && !holdout.isEmpty
    }
}

public enum AdaptiveCausalTimeHoldoutPolicy {
    /// Uses the latest evidence timestamp as an immutable dataset anchor and
    /// reserves the latest N UTC calendar days. The split therefore does not
    /// move with wall-clock evaluation time and cannot randomly reshuffle rows.
    public static func split(
        _ transitions: [CausalTransitionEvidence],
        days requestedDays: Int = AdaptiveCausalLearningGate.minimumHoldoutDays
    ) -> AdaptiveCausalTimeHoldout {
        let days = max(1, requestedDays)
        let dated = transitions.compactMap { row -> (CausalTransitionEvidence, Date)? in
            parseAdaptiveCausalDate(row.occurredAt).map { (row, $0) }
        }
        guard let latest = dated.map(\.1).max() else {
            return AdaptiveCausalTimeHoldout(
                requestedDays: days,
                cutoffAt: nil,
                latestEvidenceAt: nil,
                training: [],
                holdout: [],
                invalidTimestampCount: transitions.count,
                elapsedHoldoutDays: 0
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let latestDay = calendar.startOfDay(for: latest)
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: latestDay)!
        let training = dated.filter { $0.1 < cutoff }.map(\.0).sorted(by: causalTransitionOrder)
        let holdout = dated.filter { $0.1 >= cutoff }.map(\.0).sorted(by: causalTransitionOrder)
        let elapsed = (!training.isEmpty && !holdout.isEmpty)
            ? (calendar.dateComponents([.day], from: cutoff, to: latestDay).day ?? -1) + 1
            : 0
        return AdaptiveCausalTimeHoldout(
            requestedDays: days,
            cutoffAt: cutoff,
            latestEvidenceAt: latest,
            training: training,
            holdout: holdout,
            invalidTimestampCount: transitions.count - dated.count,
            elapsedHoldoutDays: max(0, elapsed)
        )
    }
}

// MARK: - Distribution drift

public enum AdaptiveCausalDriftStatus: String, Sendable, Equatable {
    case insufficientSamples = "insufficient_samples"
    case withinLimit = "within_limit"
    case shifted
}

public struct AdaptiveCausalDriftEvaluation: Sendable, Equatable {
    public let schema: String
    public let trainingCount: Int
    public let holdoutCount: Int
    public let minimumSampleCount: Int
    public let jensenShannonDivergence: Double?
    public let maximumAllowedDivergence: Double
    public let status: AdaptiveCausalDriftStatus

    public var detectorReady: Bool { status != .insufficientSamples }
    public var withinLimit: Bool { status == .withinLimit }
}

public enum AdaptiveCausalDriftEvaluator {
    public static let schema = "adaptive-causal-drift.v1"

    /// Compares payload-free domain/kind/outcome frequencies. This is a
    /// deterministic readiness/drift monitor, not a learned model and not a
    /// claim that the distributions are causally explanatory.
    public static func evaluate(
        training: [CausalTransitionEvidence],
        holdout: [CausalTransitionEvidence],
        minimumSampleCount: Int = 30,
        maximumAllowedDivergence: Double = 0.20
    ) -> AdaptiveCausalDriftEvaluation {
        let minimum = max(1, minimumSampleCount)
        let maximum = min(1, max(0, maximumAllowedDivergence))
        guard training.count >= minimum, holdout.count >= minimum else {
            return AdaptiveCausalDriftEvaluation(
                schema: schema,
                trainingCount: training.count,
                holdoutCount: holdout.count,
                minimumSampleCount: minimum,
                jensenShannonDivergence: nil,
                maximumAllowedDivergence: maximum,
                status: .insufficientSamples
            )
        }

        let trainingCounts = categoryCounts(training)
        let holdoutCounts = categoryCounts(holdout)
        // Floating-point addition is order-sensitive. Set iteration order is
        // process-randomized, which made an otherwise identical report differ
        // in the final bit under the parallel canonical test shards. Sort the
        // category algebra so drift evidence is reproducible byte-for-byte.
        let keys = Set(trainingCounts.keys).union(holdoutCounts.keys).sorted()
        let pTotal = Double(training.count)
        let qTotal = Double(holdout.count)
        var divergence = 0.0
        for key in keys {
            let p = Double(trainingCounts[key, default: 0]) / pTotal
            let q = Double(holdoutCounts[key, default: 0]) / qTotal
            let midpoint = (p + q) / 2
            if p > 0 { divergence += 0.5 * p * log2(p / midpoint) }
            if q > 0 { divergence += 0.5 * q * log2(q / midpoint) }
        }
        let bounded = min(1, max(0, divergence))
        return AdaptiveCausalDriftEvaluation(
            schema: schema,
            trainingCount: training.count,
            holdoutCount: holdout.count,
            minimumSampleCount: minimum,
            jensenShannonDivergence: bounded,
            maximumAllowedDivergence: maximum,
            status: bounded <= maximum ? .withinLimit : .shifted
        )
    }

    private static func categoryCounts(
        _ transitions: [CausalTransitionEvidence]
    ) -> [String: Int] {
        Dictionary(grouping: transitions) {
            "\($0.domain)|\($0.kind)|\($0.outcome)"
        }.mapValues(\.count)
    }
}

// MARK: - Reviewed privacy artifact

public enum AdaptiveCausalPrivacyDecision: String, Codable, Sendable, Equatable {
    case approvedForShadowEvaluation = "approved_for_shadow_evaluation"
    case rejected
}

public struct AdaptiveCausalPrivacyReviewArtifact: Codable, Sendable, Equatable {
    public static let schemaVersion = "adaptive-causal-privacy-review.v1"
    public static let permittedFields = [
        "afterState", "beforeState", "domain", "expectedNextEvidence", "itemIdentity",
        "kind", "occurredAt", "operationId", "outcome",
    ]
    public static let requiredExclusions = [
        "credentials", "local_paths", "personal_identifiers", "raw_text", "secrets",
    ]

    public let schema: String
    public let classificationVersion: String
    public let transitionSchemaVersion: String
    public let decision: AdaptiveCausalPrivacyDecision
    public let reviewedAt: String
    public let reviewedDomains: [String]
    public let permittedFields: [String]
    public let excludedContentClasses: [String]
    public let identityEncoding: String
    public let controlAuthority: Bool
    public let artifactDigestSHA256: String

    public init(
        schema: String = Self.schemaVersion,
        classificationVersion: String,
        transitionSchemaVersion: String,
        decision: AdaptiveCausalPrivacyDecision,
        reviewedAt: String,
        reviewedDomains: [String],
        permittedFields: [String] = Self.permittedFields,
        excludedContentClasses: [String] = Self.requiredExclusions,
        identityEncoding: String = "sha256",
        controlAuthority: Bool = false,
        artifactDigestSHA256: String
    ) {
        self.schema = schema
        self.classificationVersion = classificationVersion
        self.transitionSchemaVersion = transitionSchemaVersion
        self.decision = decision
        self.reviewedAt = reviewedAt
        self.reviewedDomains = reviewedDomains
        self.permittedFields = permittedFields
        self.excludedContentClasses = excludedContentClasses
        self.identityEncoding = identityEncoding
        self.controlAuthority = controlAuthority
        self.artifactDigestSHA256 = artifactDigestSHA256
    }

    public func sealed() throws -> Self {
        try Self(
            schema: schema,
            classificationVersion: classificationVersion,
            transitionSchemaVersion: transitionSchemaVersion,
            decision: decision,
            reviewedAt: reviewedAt,
            reviewedDomains: reviewedDomains,
            permittedFields: permittedFields,
            excludedContentClasses: excludedContentClasses,
            identityEncoding: identityEncoding,
            controlAuthority: controlAuthority,
            artifactDigestSHA256: canonicalDigest()
        )
    }

    fileprivate func canonicalDigest() throws -> String {
        struct Payload: Encodable {
            let schema: String
            let classificationVersion: String
            let transitionSchemaVersion: String
            let decision: AdaptiveCausalPrivacyDecision
            let reviewedAt: String
            let reviewedDomains: [String]
            let permittedFields: [String]
            let excludedContentClasses: [String]
            let identityEncoding: String
            let controlAuthority: Bool
        }
        let payload = Payload(
            schema: schema,
            classificationVersion: classificationVersion,
            transitionSchemaVersion: transitionSchemaVersion,
            decision: decision,
            reviewedAt: reviewedAt,
            reviewedDomains: reviewedDomains.sorted(),
            permittedFields: permittedFields.sorted(),
            excludedContentClasses: excludedContentClasses.sorted(),
            identityEncoding: identityEncoding,
            controlAuthority: controlAuthority
        )
        return try adaptiveCanonicalSHA256(payload)
    }
}

public enum AdaptiveCausalArtifactError: String, Error, Sendable, Equatable {
    case missing
    case malformed
    case unsupportedSchema
    case unexpectedFields
    case invalidReview
    case digestMismatch
    case modelArtifactMissing
    case modelDigestMismatch
}

public enum AdaptiveCausalPrivacyReviewLoader {
    public static func load(
        from url: URL,
        requiredDomains: Set<String>,
        transitionSchemaVersion: String
    ) throws -> AdaptiveCausalPrivacyReviewArtifact {
        let data = try readAdaptiveArtifact(url)
        try requireExactTopLevelKeys(data, allowed: [
            "schema", "classificationVersion", "transitionSchemaVersion", "decision",
            "reviewedAt", "reviewedDomains", "permittedFields", "excludedContentClasses",
            "identityEncoding", "controlAuthority", "artifactDigestSHA256",
        ])
        guard let artifact = try? JSONDecoder().decode(AdaptiveCausalPrivacyReviewArtifact.self, from: data) else {
            throw AdaptiveCausalArtifactError.malformed
        }
        guard artifact.schema == AdaptiveCausalPrivacyReviewArtifact.schemaVersion else {
            throw AdaptiveCausalArtifactError.unsupportedSchema
        }
        guard artifact.decision == .approvedForShadowEvaluation,
              !artifact.classificationVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              artifact.transitionSchemaVersion == transitionSchemaVersion,
              parseAdaptiveCausalDate(artifact.reviewedAt) != nil,
              !artifact.reviewedDomains.isEmpty,
              requiredDomains.isSubset(of: Set(artifact.reviewedDomains)),
              artifact.permittedFields.sorted() == AdaptiveCausalPrivacyReviewArtifact.permittedFields.sorted(),
              Set(AdaptiveCausalPrivacyReviewArtifact.requiredExclusions)
                .isSubset(of: Set(artifact.excludedContentClasses)),
              artifact.identityEncoding == "sha256",
              artifact.controlAuthority == false else {
            throw AdaptiveCausalArtifactError.invalidReview
        }
        guard try artifact.canonicalDigest() == artifact.artifactDigestSHA256.lowercased() else {
            throw AdaptiveCausalArtifactError.digestMismatch
        }
        return artifact
    }
}

// MARK: - Immutable rollback manifest

public struct AdaptiveCausalRollbackManifest: Codable, Sendable, Equatable {
    public static let schemaVersion = "adaptive-causal-rollback-manifest.v1"

    public let schema: String
    public let modelVersion: String
    public let modelArtifactSHA256: String
    public let deterministicBaselineVersion: String
    public let createdAt: String
    public let activationScope: String
    public let rollbackAction: String
    public let controlAuthority: Bool
    public let manifestDigestSHA256: String

    public init(
        schema: String = Self.schemaVersion,
        modelVersion: String,
        modelArtifactSHA256: String,
        deterministicBaselineVersion: String,
        createdAt: String,
        activationScope: String = "shadow_only",
        rollbackAction: String = "disable_shadow_model",
        controlAuthority: Bool = false,
        manifestDigestSHA256: String
    ) {
        self.schema = schema
        self.modelVersion = modelVersion
        self.modelArtifactSHA256 = modelArtifactSHA256
        self.deterministicBaselineVersion = deterministicBaselineVersion
        self.createdAt = createdAt
        self.activationScope = activationScope
        self.rollbackAction = rollbackAction
        self.controlAuthority = controlAuthority
        self.manifestDigestSHA256 = manifestDigestSHA256
    }

    public func sealed() throws -> Self {
        try Self(
            schema: schema,
            modelVersion: modelVersion,
            modelArtifactSHA256: modelArtifactSHA256,
            deterministicBaselineVersion: deterministicBaselineVersion,
            createdAt: createdAt,
            activationScope: activationScope,
            rollbackAction: rollbackAction,
            controlAuthority: controlAuthority,
            manifestDigestSHA256: canonicalDigest()
        )
    }

    fileprivate func canonicalDigest() throws -> String {
        struct Payload: Encodable {
            let schema: String
            let modelVersion: String
            let modelArtifactSHA256: String
            let deterministicBaselineVersion: String
            let createdAt: String
            let activationScope: String
            let rollbackAction: String
            let controlAuthority: Bool
        }
        return try adaptiveCanonicalSHA256(Payload(
            schema: schema,
            modelVersion: modelVersion,
            modelArtifactSHA256: modelArtifactSHA256,
            deterministicBaselineVersion: deterministicBaselineVersion,
            createdAt: createdAt,
            activationScope: activationScope,
            rollbackAction: rollbackAction,
            controlAuthority: controlAuthority
        ))
    }
}

public enum AdaptiveCausalRollbackManifestLoader {
    /// Validates the manifest checksum and the exact immutable model bytes.
    /// The checksum detects accidental/stale mutation; it is not an approval
    /// signature and grants no authority.
    /// The model filename is derived only from a strict version token; the
    /// manifest cannot inject an absolute or parent-relative path.
    public static func load(
        from url: URL,
        modelArtifactDirectory: URL
    ) throws -> AdaptiveCausalRollbackManifest {
        let data = try readAdaptiveArtifact(url)
        try requireExactTopLevelKeys(data, allowed: [
            "schema", "modelVersion", "modelArtifactSHA256",
            "deterministicBaselineVersion", "createdAt", "activationScope",
            "rollbackAction", "controlAuthority", "manifestDigestSHA256",
        ])
        guard let manifest = try? JSONDecoder().decode(AdaptiveCausalRollbackManifest.self, from: data) else {
            throw AdaptiveCausalArtifactError.malformed
        }
        let token = try NSRegularExpression(
            pattern: "^[A-Za-z0-9][A-Za-z0-9_-]*(?:\\.[A-Za-z0-9_-]+)*$"
        )
        let fullRange = NSRange(manifest.modelVersion.startIndex..., in: manifest.modelVersion)
        guard manifest.schema == AdaptiveCausalRollbackManifest.schemaVersion else {
            throw AdaptiveCausalArtifactError.unsupportedSchema
        }
        guard manifest.modelVersion.count <= 96,
              token.firstMatch(in: manifest.modelVersion, range: fullRange) != nil,
              isAdaptiveSHA256(manifest.modelArtifactSHA256),
              !manifest.deterministicBaselineVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              parseAdaptiveCausalDate(manifest.createdAt) != nil,
              manifest.activationScope == "shadow_only",
              manifest.rollbackAction == "disable_shadow_model",
              manifest.controlAuthority == false else {
            throw AdaptiveCausalArtifactError.invalidReview
        }
        guard try manifest.canonicalDigest() == manifest.manifestDigestSHA256.lowercased() else {
            throw AdaptiveCausalArtifactError.digestMismatch
        }
        let artifactURL = modelArtifactDirectory
            .appendingPathComponent(manifest.modelVersion, isDirectory: false)
            .appendingPathExtension("bin")
        let artifactValues = try? artifactURL.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard artifactValues?.isRegularFile == true,
              artifactValues?.isSymbolicLink != true,
              let artifactSize = artifactValues?.fileSize,
              artifactSize <= 128 * 1_024 * 1_024,
              let artifactData = try? Data(contentsOf: artifactURL),
              artifactData.count == artifactSize else {
            throw AdaptiveCausalArtifactError.modelArtifactMissing
        }
        let digest = SHA256.hash(data: artifactData).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.modelArtifactSHA256.lowercased() else {
            throw AdaptiveCausalArtifactError.modelDigestMismatch
        }
        return manifest
    }
}

// MARK: - Shared helpers

private func parseAdaptiveCausalDate(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) { return date }
    let ordinary = ISO8601DateFormatter()
    ordinary.formatOptions = [.withInternetDateTime]
    return ordinary.date(from: raw)
}

private func causalTransitionOrder(
    _ lhs: CausalTransitionEvidence,
    _ rhs: CausalTransitionEvidence
) -> Bool {
    let left = parseAdaptiveCausalDate(lhs.occurredAt) ?? .distantPast
    let right = parseAdaptiveCausalDate(rhs.occurredAt) ?? .distantPast
    if left != right { return left < right }
    return lhs.operationId < rhs.operationId
}

private func adaptiveCanonicalSHA256<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(value)
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private func readAdaptiveArtifact(_ url: URL) throws -> Data {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw AdaptiveCausalArtifactError.missing
    }
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values?.isRegularFile == true,
          let size = values?.fileSize,
          size <= 256 * 1_024,
          let data = try? Data(contentsOf: url),
          data.count == size else {
        throw AdaptiveCausalArtifactError.malformed
    }
    return data
}

private func requireExactTopLevelKeys(_ data: Data, allowed: Set<String>) throws {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any],
          Set(dictionary.keys) == allowed else {
        throw AdaptiveCausalArtifactError.unexpectedFields
    }
}

private func isAdaptiveSHA256(_ raw: String) -> Bool {
    raw.count == 64 && raw.allSatisfy { $0.isHexDigit }
}

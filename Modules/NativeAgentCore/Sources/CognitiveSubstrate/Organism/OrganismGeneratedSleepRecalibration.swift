import Foundation
import CryptoKit

public struct OrganismSleepCalibrationSample: Sendable, Equatable {
    public var evidenceID: String
    public var evidenceClass: OrganismSleepEvidenceClass
    public var predictedProbability: Double
    public var observedSuccess: Bool

    public init(
        evidenceID: String,
        evidenceClass: OrganismSleepEvidenceClass,
        predictedProbability: Double,
        observedSuccess: Bool
    ) {
        self.evidenceID = SHA256.hash(data: Data(evidenceID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.evidenceClass = evidenceClass
        self.predictedProbability = (predictedProbability.isFinite ? predictedProbability : 0).clamped01()
        self.observedSuccess = observedSuccess
    }
}

/// No public initializer exists. Only package tests/frozen laboratories may
/// construct this authority; personal runtime traces require Wave 11's
/// ApprovalInbox-bound, versioned privacy artifact and are intentionally not
/// accepted here.
public struct OrganismGeneratedSleepRecalibrationAuthorization: Sendable, Equatable {
    private init() {}
    static let generatedAndFrozen = Self()
}

public enum OrganismGeneratedSleepRecalibrationError: String, Error, Sendable, Equatable {
    case personalEvidenceDenied = "personal_evidence_denied"
    case insufficientEvidence = "insufficient_evidence"
    case pressureLaneNotReady = "pressure_lane_not_ready"
}

public struct OrganismGeneratedSleepRecalibrationArtifact: Codable, Sendable, Equatable {
    public var schema: String
    public var generatedAt: Date
    public var evidenceGeneration: String
    public var sampleCount: Int
    public var scale: Double
    public var brierBefore: Double
    public var brierAfter: Double
    public var evidenceIDs: [String]
    public var generatedOrFrozenOnly: Bool
    public var personalModelUpdated: Bool
    public var productionInfluence: Bool
    public var rollbackRequired: Bool
}

public struct OrganismGeneratedSleepRecalibrationResult: Sendable, Equatable {
    public var artifact: OrganismGeneratedSleepRecalibrationArtifact
    public var controlState: OrganismSleepControlState
}

/// A small deterministic recalibration proof for generated/frozen evidence.
/// The artifact is immutable and advisory; it is never installed into the live
/// predictive body and has no provider, prompt, or action side effects.
public enum OrganismGeneratedSleepRecalibrator {
    public static func recalibrate(
        reading: OrganismResidualRepairOpportunity,
        samples: [OrganismSleepCalibrationSample],
        authorization: OrganismGeneratedSleepRecalibrationAuthorization,
        controlState: OrganismSleepControlState = .empty,
        at now: Date
    ) throws -> OrganismGeneratedSleepRecalibrationResult {
        _ = authorization
        guard reading.lanes.first(where: { $0.lane == .generatedFrozenRecalibration })?.disposition == .ready else {
            throw OrganismGeneratedSleepRecalibrationError.pressureLaneNotReady
        }
        let bounded = Array(samples.prefix(10_000))
        guard bounded.count >= 8 else {
            throw OrganismGeneratedSleepRecalibrationError.insufficientEvidence
        }
        guard bounded.allSatisfy({ $0.evidenceClass == .generated || $0.evidenceClass == .frozenControlled }) else {
            throw OrganismGeneratedSleepRecalibrationError.personalEvidenceDenied
        }
        let meanPrediction = bounded.reduce(0.0) { $0 + $1.predictedProbability } / Double(bounded.count)
        let posteriorObserved = Double(bounded.filter(\.observedSuccess).count + 1) / Double(bounded.count + 2)
        let scale = meanPrediction > 0.000_001
            ? min(1.5, max(0.5, posteriorObserved / meanPrediction))
            : 1
        func brier(scale: Double) -> Double {
            bounded.reduce(0.0) { total, sample in
                let p = (sample.predictedProbability * scale).clamped01()
                let y = sample.observedSuccess ? 1.0 : 0.0
                return total + pow(p - y, 2)
            } / Double(bounded.count)
        }
        let before = brier(scale: 1)
        let after = brier(scale: scale)
        let artifact = OrganismGeneratedSleepRecalibrationArtifact(
            schema: "organism-generated-sleep-recalibration.v1",
            generatedAt: now,
            evidenceGeneration: reading.evidenceGeneration,
            sampleCount: bounded.count,
            scale: scale,
            brierBefore: before,
            brierAfter: after,
            evidenceIDs: Array(Set(bounded.map(\.evidenceID)).sorted().prefix(10_000)),
            generatedOrFrozenOnly: true,
            personalModelUpdated: false,
            productionInfluence: false,
            rollbackRequired: false
        )
        var next = controlState
        next.lastGeneratedRecalibrationAt = now
        next.lastGeneratedEvidenceGeneration = reading.evidenceGeneration
        return OrganismGeneratedSleepRecalibrationResult(
            artifact: artifact,
            controlState: next
        )
    }
}

import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ProcedureArtifactContracts.swift` | Procedure artifact errors, canonical execution and invocation receipt contracts, and payload-free status snapshots |

public enum ProcedureArtifactStoreError: String, Error, Sendable, Equatable {
    case invalidArtifact = "invalid_artifact"
    case immutableConflict = "immutable_conflict"
    case artifactNotFound = "artifact_not_found"
    case corruptArtifact = "corrupt_artifact"
    case legacyArtifactRequiresRevalidation = "legacy_artifact_requires_revalidation"
    /// The discovery ceiling signals capacity exhaustion, not artifact corruption.
    case artifactCapacityExceeded = "artifact_capacity_exceeded"
    case corruptInvocationLedger = "corrupt_invocation_ledger"
    case invocationNotEligible = "invocation_not_eligible"
    case invalidInputReference = "invalid_input_reference"
    case invalidExecutionResult = "invalid_execution_result"
}

/// Closed, payload-free result vocabulary from a canonical domain executor.
/// Arbitrary executor prose must never be persisted into the invocation ledger.
public enum ProcedureCanonicalExecutionStatus: String, Codable, Sendable, Equatable {
    case verifiedSuccess = "verified_success"
    case verifiedFailure = "verified_failure"
    case cancelled
    case abstained
    case unverified
}

public struct ProcedureCanonicalExecutionResult: Sendable, Equatable {
    public let status: ProcedureCanonicalExecutionStatus
    public let authorityRechecked: Bool
    public let canonicalEvidenceMatched: Bool
    public let verified: Bool

    public init(
        status: ProcedureCanonicalExecutionStatus,
        authorityRechecked: Bool,
        canonicalEvidenceMatched: Bool,
        verified: Bool
    ) {
        self.status = status
        self.authorityRechecked = authorityRechecked
        self.canonicalEvidenceMatched = canonicalEvidenceMatched
        self.verified = verified
    }

    var isValid: Bool {
        switch status {
        case .verifiedSuccess, .verifiedFailure, .cancelled:
            return authorityRechecked && canonicalEvidenceMatched && verified
        case .abstained, .unverified:
            return !verified
        }
    }
}

/// Domain executors remain the only action owners. This seam never receives
/// parameter values: it passes an opaque canonical-store reference and one
/// already-admitted transition rule. The executor must refetch input, recheck
/// TrustCenter/approval, and return exact verification. Retries must reuse the
/// same canonical execution identity and inspect its existing effects before
/// performing unfinished work; an observation failure never creates a new copy.
public typealias ProcedureCanonicalExecution = @Sendable (
    _ artifact: DeclarativeProcedureArtifact,
    _ rule: ProcedureTransitionRule,
    _ opaqueInputReference: String,
    _ invocationID: String
) async throws -> ProcedureCanonicalExecutionResult

/// A terminal observation failure says nothing about whether domain effects
/// landed. Its canonical invocation identity remains available for inspection.
public enum ProcedureInvocationInterruption: String, Codable, Sendable {
    case stopped
    case executorFailed = "executor_failed"
    case invalidResult = "invalid_result"
}

public struct ProcedureInvocationReceipt: Codable, Sendable, Equatable {
    public static let schema = "declarative-procedure-invocation.v1"
    public let schema: String
    public let invocationID: String
    public let artifactID: String
    public let opaqueInputReference: String
    public let requestedAt: String
    public let dryRunStatus: ProcedureDryRunStatus
    public let dryRunReason: ProcedureDryRunReason
    public let executorStatus: ProcedureCanonicalExecutionStatus?
    public let authorityRechecked: Bool
    public let canonicalEvidenceMatched: Bool
    public let verified: Bool
    public let fallback: ProcedureFallbackRoute
    public let dispatched: Bool
    public let payloadFree: Bool
    public let permissionAuthority: Bool
    public let automaticSelection: Bool
    /// Present only when an exact typed activation admitted the invocation.
    /// Older/manual rows decode with nil and retain their original meaning.
    public let activationID: String?
    public let procedureID: String?
    public let selectionMode: String?
    public let interruption: ProcedureInvocationInterruption?

    public init(
        schema: String,
        invocationID: String,
        artifactID: String,
        opaqueInputReference: String,
        requestedAt: String,
        dryRunStatus: ProcedureDryRunStatus,
        dryRunReason: ProcedureDryRunReason,
        executorStatus: ProcedureCanonicalExecutionStatus?,
        authorityRechecked: Bool,
        canonicalEvidenceMatched: Bool,
        verified: Bool,
        fallback: ProcedureFallbackRoute,
        dispatched: Bool,
        payloadFree: Bool,
        permissionAuthority: Bool,
        automaticSelection: Bool,
        activationID: String? = nil,
        procedureID: String? = nil,
        selectionMode: String? = nil,
        interruption: ProcedureInvocationInterruption? = nil
    ) {
        self.schema = schema
        self.invocationID = invocationID
        self.artifactID = artifactID
        self.opaqueInputReference = opaqueInputReference
        self.requestedAt = requestedAt
        self.dryRunStatus = dryRunStatus
        self.dryRunReason = dryRunReason
        self.executorStatus = executorStatus
        self.authorityRechecked = authorityRechecked
        self.canonicalEvidenceMatched = canonicalEvidenceMatched
        self.verified = verified
        self.fallback = fallback
        self.dispatched = dispatched
        self.payloadFree = payloadFree
        self.permissionAuthority = permissionAuthority
        self.automaticSelection = automaticSelection
        self.activationID = activationID
        self.procedureID = procedureID
        self.selectionMode = selectionMode
        self.interruption = interruption
    }
}

/// Bounded, payload-free operator projection. It reports whether an approved
/// native procedure actually exists and whether it has ever been invoked;
/// candidate prose, input values, Workshop IDs, and outputs are excluded.
public struct ProcedureArtifactStatusSnapshot: Sendable, Equatable {
    public let artifactCount: Int
    public let corruptArtifactCount: Int
    public let corruptInvocationCount: Int
    public let invocationCount: Int
    public let manualInvocationCount: Int
    public let automaticInvocationCount: Int
    public let verifiedInvocationCount: Int
    public let lastInvocationStatus: ProcedureCanonicalExecutionStatus?
    public let activationArtifactCount: Int
    public let corruptActivationArtifactCount: Int
    public let activeAutomaticProcedureCount: Int
    public let automaticSelectionEnabled: Bool
    public let payloadFree: Bool
    /// Sources this snapshot could not read or resolve, each with its cause.
    /// Empty means every count above was observed, zeros included.
    public let unreadable: [String]
}

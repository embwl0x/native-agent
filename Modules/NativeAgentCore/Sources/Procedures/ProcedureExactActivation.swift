import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ProcedureExactActivation.swift` | Exact activation manifests and active pointers; artifact revalidation and pointer publication share retention's invocation-ledger lock, acquired before the pointer lock |

public enum ProcedureExactActivationError: String, Error, Sendable, Equatable {
    case invalidProposal = "invalid_proposal"
    case invalidDecision = "invalid_decision"
    case artifactMismatch = "artifact_mismatch"
    case immutableConflict = "immutable_conflict"
    case activationNotFound = "activation_not_found"
    case activationCorrupt = "activation_corrupt"
    case activationBindingMismatch = "activation_binding_mismatch"
}

/// Payload-free evidence package for activating one already-reviewed native
/// procedure implementation. This does not describe a learned policy. It binds
/// exact canonical invocation receipts, exact Workshop trajectories, the
/// immutable declarative artifact, and a versioned deterministic fault gate.
public struct ProcedureExactActivationProposal: Codable, Sendable, Equatable {
    public static let schema = "procedure-exact-activation-proposal.v1"
    public static let minimumVerifiedExecutions = 12
    public static let requiredQualificationProtocolIdentity =
        CausalTransitionEvidence.opaqueIdentity(
            "procedure-exact-activation-qualification|canonical-workshop-v1|"
                + "path-containment|source-bounds|utf8-exactness|destination-parent|"
                + "same-path-refusal|trust-denial|retry-idempotency|corruption-fail-closed"
        )

    /// Qualification contracts are procedure-specific. A new native routine
    /// must add its own deterministic protocol identity here; it cannot reuse
    /// local-file-copy evidence merely because the proposal shape is valid.
    public static func requiredQualificationProtocolIdentity(
        for procedureID: String
    ) -> String? {
        switch procedureID {
        case "local_file_copy_v1": requiredQualificationProtocolIdentity
        default: nil
        }
    }

    public let schema: String
    public let artifactID: String
    public let procedureShapeIdentity: String
    public let procedureID: String
    public let implementationIdentity: String
    public let qualifyingInvocationIDs: [String]
    public let qualifyingTrajectoryIDs: [String]
    public let verifiedExecutionCount: Int
    public let distinctInputCount: Int
    public let zeroProviderExecutionCount: Int
    public let sourceEvidenceTrajectoryCount: Int
    public let p95ExecutionLatencyMilliseconds: Int
    public let qualificationProtocolIdentity: String
    public let evaluatedAt: String
    public let exactTypedSelectionOnly: Bool
    public let externalSendsEligible: Bool
    public let permissionAuthority: Bool

    public init(
        artifactID: String,
        procedureShapeIdentity: String,
        procedureID: String,
        implementationIdentity: String,
        qualifyingInvocationIDs: [String],
        qualifyingTrajectoryIDs: [String],
        verifiedExecutionCount: Int,
        distinctInputCount: Int,
        zeroProviderExecutionCount: Int,
        sourceEvidenceTrajectoryCount: Int,
        p95ExecutionLatencyMilliseconds: Int,
        qualificationProtocolIdentity: String = Self.requiredQualificationProtocolIdentity,
        evaluatedAt: String,
        exactTypedSelectionOnly: Bool = true,
        externalSendsEligible: Bool = false,
        permissionAuthority: Bool = false
    ) {
        self.schema = Self.schema
        self.artifactID = artifactID
        self.procedureShapeIdentity = procedureShapeIdentity
        self.procedureID = procedureID
        self.implementationIdentity = implementationIdentity
        self.qualifyingInvocationIDs = qualifyingInvocationIDs.sorted()
        self.qualifyingTrajectoryIDs = qualifyingTrajectoryIDs.sorted()
        self.verifiedExecutionCount = verifiedExecutionCount
        self.distinctInputCount = distinctInputCount
        self.zeroProviderExecutionCount = zeroProviderExecutionCount
        self.sourceEvidenceTrajectoryCount = sourceEvidenceTrajectoryCount
        self.p95ExecutionLatencyMilliseconds = p95ExecutionLatencyMilliseconds
        self.qualificationProtocolIdentity = qualificationProtocolIdentity
        self.evaluatedAt = evaluatedAt
        self.exactTypedSelectionOnly = exactTypedSelectionOnly
        self.externalSendsEligible = externalSendsEligible
        self.permissionAuthority = permissionAuthority
    }

    public var bindingDigest: String {
        CausalTransitionEvidence.opaqueIdentity([
            schema,
            artifactID,
            procedureShapeIdentity,
            procedureID,
            implementationIdentity,
            qualifyingInvocationIDs.joined(separator: ","),
            qualifyingTrajectoryIDs.joined(separator: ","),
            String(verifiedExecutionCount),
            String(distinctInputCount),
            String(zeroProviderExecutionCount),
            String(sourceEvidenceTrajectoryCount),
            String(p95ExecutionLatencyMilliseconds),
            qualificationProtocolIdentity,
            evaluatedAt,
            String(exactTypedSelectionOnly),
            String(externalSendsEligible),
            String(permissionAuthority),
        ].joined(separator: "||"))
    }

    public var validates: Bool {
        schema == Self.schema
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(artifactID)
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(procedureShapeIdentity)
            && ProcedureArtifactStore.token(procedureID, maximum: 80)
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(implementationIdentity)
            && qualifyingInvocationIDs.count >= Self.minimumVerifiedExecutions
            && qualifyingInvocationIDs.count <= 64
            && qualifyingInvocationIDs.allSatisfy(ProcedureTrajectoryExtractor.isOpaqueIdentity)
            && Set(qualifyingInvocationIDs).count == qualifyingInvocationIDs.count
            && qualifyingInvocationIDs == qualifyingInvocationIDs.sorted()
            && qualifyingTrajectoryIDs.count == qualifyingInvocationIDs.count
            && qualifyingTrajectoryIDs.allSatisfy(ProcedureTrajectoryExtractor.isOpaqueIdentity)
            && Set(qualifyingTrajectoryIDs).count == qualifyingTrajectoryIDs.count
            && qualifyingTrajectoryIDs == qualifyingTrajectoryIDs.sorted()
            && verifiedExecutionCount == qualifyingInvocationIDs.count
            && distinctInputCount == qualifyingTrajectoryIDs.count
            && zeroProviderExecutionCount == verifiedExecutionCount
            && sourceEvidenceTrajectoryCount >= 2
            && sourceEvidenceTrajectoryCount <= 64
            && (0...60_000).contains(p95ExecutionLatencyMilliseconds)
            && qualificationProtocolIdentity
                == Self.requiredQualificationProtocolIdentity(for: procedureID)
            && procedureExactTimestamp(evaluatedAt)
            && exactTypedSelectionOnly
            && !externalSendsEligible
            && !permissionAuthority
    }

    public func toJSON() -> JSONValue {
        (try? JSONValue.fromEncodable(self)) ?? .null
    }

    public init?(json: JSONValue) {
        guard let data = try? json.serializedData(pretty: false),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.validates else { return nil }
        self = decoded
    }
}

public struct ProcedureExactActivationReviewerDecision: Codable, Sendable, Equatable {
    public static let schema = "procedure-exact-activation-review.v1"

    public let schema: String
    public let proposalDigest: String
    public let verdict: ProcedureReviewVerdict
    public let reviewerIdentity: String
    public let approvalReceiptIdentity: String
    public let decidedAt: String

    package init(
        proposalDigest: String,
        verdict: ProcedureReviewVerdict,
        reviewerIdentity: String,
        approvalReceiptIdentity: String,
        decidedAt: String
    ) {
        self.schema = Self.schema
        self.proposalDigest = proposalDigest
        self.verdict = verdict
        self.reviewerIdentity = reviewerIdentity
        self.approvalReceiptIdentity = approvalReceiptIdentity
        self.decidedAt = decidedAt
    }

    public var validates: Bool {
        schema == Self.schema
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(proposalDigest)
            && verdict == .approve
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(reviewerIdentity)
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(approvalReceiptIdentity)
            && procedureExactTimestamp(decidedAt)
    }
}

public struct ProcedureExactActivationManifest: Codable, Sendable, Equatable, Identifiable {
    public static let schema = "procedure-exact-activation-manifest.v1"

    public let schema: String
    public let id: String
    public let proposal: ProcedureExactActivationProposal
    public let reviewerDecision: ProcedureExactActivationReviewerDecision
    public let selectionMode: String
    public let activatedAt: String
    public let rollbackDeclaration: String
    public let controlAuthority: Bool

    package init(
        proposal: ProcedureExactActivationProposal,
        reviewerDecision: ProcedureExactActivationReviewerDecision,
        activatedAt: String
    ) {
        self.schema = Self.schema
        self.proposal = proposal
        self.reviewerDecision = reviewerDecision
        self.selectionMode = "exact_typed"
        self.activatedAt = activatedAt
        self.rollbackDeclaration = "delete_active_pointer_restore_ordinary_workshop_no_data_migration"
        self.controlAuthority = false
        self.id = CausalTransitionEvidence.opaqueIdentity([
            Self.schema,
            proposal.bindingDigest,
            reviewerDecision.reviewerIdentity,
            reviewerDecision.approvalReceiptIdentity,
            reviewerDecision.decidedAt,
        ].joined(separator: "||"))
    }

    public var validates: Bool {
        schema == Self.schema
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(id)
            && proposal.validates
            && reviewerDecision.validates
            && reviewerDecision.proposalDigest == proposal.bindingDigest
            && selectionMode == "exact_typed"
            && procedureExactTimestamp(activatedAt)
            && rollbackDeclaration
                == "delete_active_pointer_restore_ordinary_workshop_no_data_migration"
            && !controlAuthority
            && id == CausalTransitionEvidence.opaqueIdentity([
                Self.schema,
                proposal.bindingDigest,
                reviewerDecision.reviewerIdentity,
                reviewerDecision.approvalReceiptIdentity,
                reviewerDecision.decidedAt,
            ].joined(separator: "||"))
    }
}

public struct ProcedureExactActiveResolution: Sendable, Equatable {
    public let manifest: ProcedureExactActivationManifest
    public let artifact: DeclarativeProcedureArtifact
}

package struct ProcedureExactActivationPointer: Codable, Sendable, Equatable {
    static let schema = "procedure-exact-activation-pointer.v1"

    let schema: String
    let activationID: String
    let artifactID: String
    let procedureID: String
    let implementationIdentity: String
    let proposalDigest: String

    init(manifest: ProcedureExactActivationManifest) {
        schema = Self.schema
        activationID = manifest.id
        artifactID = manifest.proposal.artifactID
        procedureID = manifest.proposal.procedureID
        implementationIdentity = manifest.proposal.implementationIdentity
        proposalDigest = manifest.proposal.bindingDigest
    }

    var validates: Bool {
        schema == Self.schema
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(activationID)
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(artifactID)
            && ProcedureArtifactStore.token(procedureID, maximum: 80)
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(implementationIdentity)
            && ProcedureTrajectoryExtractor.isOpaqueIdentity(proposalDigest)
    }
}

package func procedureExactTimestamp(_ raw: String) -> Bool {
    NativeTimestampFormat.parseISO8601FractionalFirst(raw) != nil
}

package func procedureExactISO8601(_ date: Date) -> String {
    NativeTimestampFormat.fractionalZulu(date)
}

package struct ProcedureExactActivationStatus: Sendable, Equatable {
    let activationArtifactCount: Int
    let corruptActivationArtifactCount: Int
    let activeAutomaticProcedureCount: Int
    let unreadable: [String]
}

extension ProcedureArtifactStore {
    /// Install one immutable activation and atomically move only the active
    /// pointer. A crash before the pointer write leaves the new manifest inert;
    /// deleting that pointer is the complete rollback.
    @discardableResult
    public func installAndActivateExact(
        proposal: ProcedureExactActivationProposal,
        reviewerDecision: ProcedureExactActivationReviewerDecision
    ) async throws -> ProcedureExactActivationManifest {
        guard proposal.validates else { throw ProcedureExactActivationError.invalidProposal }
        guard reviewerDecision.validates,
              reviewerDecision.proposalDigest == proposal.bindingDigest else {
            throw ProcedureExactActivationError.invalidDecision
        }
        let artifact = try await loadForInvocation(proposal.artifactID)
        guard artifact.domain == "workshop_execution",
              artifact.procedureShapeIdentity == proposal.procedureShapeIdentity,
              artifact.authorityClass == "low_risk" else {
            throw ProcedureExactActivationError.artifactMismatch
        }

        let candidate = ProcedureExactActivationManifest(
            proposal: proposal,
            reviewerDecision: reviewerDecision,
            activatedAt: procedureExactISO8601(clock())
        )
        guard candidate.validates else { throw ProcedureExactActivationError.invalidDecision }
        let manifestPath = exactActivationManifestPath(candidate.id)
        let candidateValue = try JSONValue.parse(JSONEncoder().encode(candidate))
        let manifest: ProcedureExactActivationManifest = try await SwiftNativePersistenceCore.withFileLock(
            manifestPath
        ) {
            if FileManager.default.fileExists(atPath: manifestPath.path) {
                guard let existing = try? Self.checkedActivationManifest(manifestPath),
                      existing.proposal == proposal,
                      existing.reviewerDecision == reviewerDecision else {
                    throw ProcedureExactActivationError.immutableConflict
                }
                return existing
            }
            try await SwiftNativePersistenceCore.writeJSON(candidateValue, to: manifestPath)
            return candidate
        }

        let pointer = ProcedureExactActivationPointer(manifest: manifest)
        let pointerPath = exactActivationPointerPath(proposal.procedureID)
        let invocationPath = root.appendingPathComponent("invocations.jsonl")
        try await SwiftNativePersistenceCore.withFileLock(invocationPath) {
            // The earlier load may predate a retention pass. Revalidate while
            // excluding deletion, then publish before releasing that exclusion.
            guard try await loadForInvocation(proposal.artifactID) == artifact else {
                throw ProcedureExactActivationError.artifactMismatch
            }
            try await SwiftNativePersistenceCore.withFileLock(pointerPath) {
                try await SwiftNativePersistenceCore.writeJSON(
                    try JSONValue.parse(JSONEncoder().encode(pointer)),
                    to: pointerPath
                )
            }
        }
        return manifest
    }

    /// Checked exact lookup used by the native procedure implementation. The
    /// caller supplies its compiled implementation identity; stale pointers,
    /// changed code contracts, extra artifacts, and damaged files all fail
    /// closed before canonical queue admission.
    public func loadActiveExactProcedure(
        procedureID: String,
        implementationIdentity: String
    ) async throws -> ProcedureExactActiveResolution {
        guard Self.token(procedureID, maximum: 80),
              ProcedureTrajectoryExtractor.isOpaqueIdentity(implementationIdentity) else {
            throw ProcedureExactActivationError.activationNotFound
        }
        let pointer = try Self.checkedActivationPointer(exactActivationPointerPath(procedureID))
        guard pointer.procedureID == procedureID,
              pointer.implementationIdentity == implementationIdentity else {
            throw ProcedureExactActivationError.activationBindingMismatch
        }
        return try await loadActiveExactProcedure(pointer)
    }

    private func loadActiveExactProcedure(
        _ pointer: ProcedureExactActivationPointer
    ) async throws -> ProcedureExactActiveResolution {
        let manifestPath = exactActivationManifestPath(pointer.activationID)
        let manifest = try Self.checkedActivationManifest(manifestPath)
        guard manifest.proposal.artifactID == pointer.artifactID,
              manifest.proposal.procedureID == pointer.procedureID,
              manifest.proposal.implementationIdentity == pointer.implementationIdentity,
              manifest.proposal.bindingDigest == pointer.proposalDigest else {
            throw ProcedureExactActivationError.activationBindingMismatch
        }
        let artifact = try await loadForInvocation(pointer.artifactID)
        guard artifact.procedureShapeIdentity == manifest.proposal.procedureShapeIdentity,
              artifact.domain == "workshop_execution",
              artifact.authorityClass == "low_risk" else {
            throw ProcedureExactActivationError.artifactMismatch
        }
        return ProcedureExactActiveResolution(manifest: manifest, artifact: artifact)
    }

    package func exactActivationStatusSnapshot() async -> ProcedureExactActivationStatus {
        var unreadable: [String] = []
        let activationURLs = Self.statusListing(
            root.appendingPathComponent("activations", isDirectory: true), unreadable: &unreadable
        ).prefix(1_024)
        var validActivations = 0
        var corruptActivations = 0
        for url in activationURLs {
            guard (try? Self.checkedActivationManifest(url)) != nil else {
                corruptActivations += 1
                continue
            }
            validActivations += 1
        }

        let activeURLs = Self.statusListing(
            root.appendingPathComponent("active", isDirectory: true), unreadable: &unreadable
        ).prefix(128)
        var active = 0
        for url in activeURLs {
            guard let pointer = try? Self.checkedActivationPointer(url),
                  url.deletingPathExtension().lastPathComponent == pointer.procedureID else {
                unreadable.append("active/\(url.lastPathComponent): unreadable or invalid pointer")
                continue
            }
            do {
                _ = try await loadActiveExactProcedure(pointer)
                active += 1
            } catch {
                unreadable.append("active/\(url.lastPathComponent): \(error)")
            }
        }
        return ProcedureExactActivationStatus(
            activationArtifactCount: validActivations,
            corruptActivationArtifactCount: corruptActivations,
            activeAutomaticProcedureCount: active,
            unreadable: unreadable
        )
    }

    private func exactActivationManifestPath(_ id: String) -> URL {
        root.appendingPathComponent("activations", isDirectory: true)
            .appendingPathComponent("\(id).json")
    }

    nonisolated static func checkedActivationPointer(_ url: URL) throws -> ProcedureExactActivationPointer {
        guard let data = checkedRegularFile(url, maximumBytes: 64 * 1_024),
              let pointer = try? JSONDecoder().decode(ProcedureExactActivationPointer.self, from: data),
              pointer.validates else {
            throw FileManager.default.fileExists(atPath: url.path)
                ? ProcedureExactActivationError.activationCorrupt
                : ProcedureExactActivationError.activationNotFound
        }
        return pointer
    }

    private nonisolated static func checkedActivationManifest(
        _ url: URL
    ) throws -> ProcedureExactActivationManifest {
        guard let data = checkedRegularFile(url, maximumBytes: 2 * 1_024 * 1_024),
              let manifest = try? JSONDecoder().decode(ProcedureExactActivationManifest.self, from: data),
              manifest.validates else {
            throw ProcedureExactActivationError.activationCorrupt
        }
        guard manifest.id == url.deletingPathExtension().lastPathComponent else {
            throw ProcedureExactActivationError.activationBindingMismatch
        }
        return manifest
    }

    package func exactActivationPointerPath(_ procedureID: String) -> URL {
        root.appendingPathComponent("active", isDirectory: true)
            .appendingPathComponent("\(procedureID).json")
    }

    nonisolated static func checkedRegularFile(
        _ url: URL,
        maximumBytes: Int
    ) -> Data? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= maximumBytes,
              let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
        return data
    }
}

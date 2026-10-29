import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ProcedureCompilation.swift` | Declarative procedure artifacts, shared domain contracts and immutable transition-table compilation |

// MARK: - Immutable declarative artifact and replay

public enum ProcedureCanonicalOracle: String, Codable, Sendable, Equatable {
    case githubCommandReducer = "github_command_reducer"
    case workshopRecordAndTimeline = "workshop_record_and_timeline"
}

public enum ProcedureFallbackRoute: String, Codable, Sendable, Equatable {
    case githubCanonicalReducer = "github_canonical_reducer"
    case ordinaryWorkshopPlannerExecutor = "ordinary_workshop_planner_executor"
}

public enum ProcedureSafetyRecheckPoint: String, Codable, Sendable, Equatable {
    case beforeInvocation = "before_invocation"
    case beforeEveryAction = "before_every_action"
    case afterEveryCheckpoint = "after_every_checkpoint"
}

public struct ProcedureSafetyDeclaration: Codable, Sendable, Equatable {
    public let trustCenterCapability: String
    public let requiredPreconditions: [String]
    public let recheckPoints: [ProcedureSafetyRecheckPoint]
    public let canonicalApprovalOwner: String?
    public let externalSendsEligible: Bool
    public let permissionAuthority: Bool
    public let automaticActivationAllowed: Bool
}

public struct ProcedureInputContract: Codable, Sendable, Equatable {
    public let taskFamily: String
    public let inputClass: String
    public let parameterSchemaClass: String
    public let acceptedParameterSchemaIdentities: [String]
    public let allowedExternalEffectClasses: [String]
}

public struct ProcedureTransitionRule: Codable, Sendable, Equatable {
    public let sequence: Int
    public let beforeState: String?
    public let onTransitionKind: String
    public let actionKind: String?
    public let requiredEvidenceKind: String?
    public let expectedNextEvidence: String?
    public let checkpointClass: String?
    public let externalEffectClass: String
    public let afterState: String?
    public let verificationClass: String?
    public let terminalClass: ProcedureTerminalClass?
}

public struct DeclarativeProcedureArtifact: Codable, Sendable, Equatable, Identifiable {
    public static let schema = "declarative-procedure-transition-table.v2"
    static let legacySchema = "declarative-procedure-transition-table.v1"

    public private(set) var schema: String
    public private(set) var id: String
    public let interpretation: String
    public let sourceTrajectoryIdentities: [String]
    public let domain: String
    public let procedureShapeIdentity: String
    public let inputContract: ProcedureInputContract
    public let authorityClass: String
    public let canonicalOracle: ProcedureCanonicalOracle
    public let transitionTable: [ProcedureTransitionRule]
    public let safety: ProcedureSafetyDeclaration
    public let deterministicAbandonConditions: [String]
    public let deterministicFallback: ProcedureFallbackRoute
    public let rollbackDeclaration: String
    public let reviewerDecision: ProcedureReviewerDecision
    public let manualInvocationEligible: Bool
    public let canaryEligible: Bool
    public let automaticSelectionEligible: Bool
    public let generatedExecutableCode: Bool

    /// Bind all semantic and approval fields using the same encoding on both paths.
    func canonicalIdentity() throws -> String {
        var unsigned = self
        unsigned.id = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return CausalTransitionEvidence.opaqueIdentity(
            String(decoding: try encoder.encode(unsigned), as: UTF8.self)
        )
    }

    func withCanonicalIdentity() throws -> Self {
        var artifact = self
        artifact.id = try canonicalIdentity()
        return artifact
    }

    /// The v1 fingerprint omits semantic and approval fields; recognizing it never admits execution.
    func legacyIdentity() -> String {
        let fingerprint = [
            procedureShapeIdentity,
            domain,
            inputContract.taskFamily,
            inputContract.inputClass,
            authorityClass,
            inputContract.acceptedParameterSchemaIdentities.joined(separator: ","),
            transitionTable.map {
                "\($0.sequence)|\($0.beforeState ?? "nil")|\($0.onTransitionKind)|"
                    + "\($0.actionKind ?? "nil")|\($0.requiredEvidenceKind ?? "nil")|"
                    + "\($0.externalEffectClass)|\($0.afterState ?? "nil")|"
                    + "\($0.terminalClass?.rawValue ?? "nil")"
            }.joined(separator: ">"),
            reviewerDecision.reviewerIdentity,
            reviewerDecision.decidedAt,
        ].joined(separator: "||")
        return CausalTransitionEvidence.opaqueIdentity(fingerprint)
    }

    public var requiresLegacyRevalidation: Bool {
        schema == Self.legacySchema && id != (try? canonicalIdentity())
    }

    func withLegacyIdentity() -> Self {
        var artifact = self
        artifact.schema = Self.legacySchema
        artifact.id = artifact.legacyIdentity()
        return artifact
    }
}

public enum ProcedureCompilationError: Error, Equatable {
    case candidateNotEligible
    case missingReviewerApproval
    case unsupportedDomain
}

/// The one domain contract that compilation and stored-artifact validation
/// both read, so an artifact one boundary accepts the other accepts too.
struct ProcedureDomainContract {
    let oracle: ProcedureCanonicalOracle
    let fallback: ProcedureFallbackRoute
    let capability: String

    static func named(_ domain: String) -> ProcedureDomainContract? {
        switch domain {
        case "github_command":
            ProcedureDomainContract(oracle: .githubCommandReducer, fallback: .githubCanonicalReducer,
                                    capability: "github_connector")
        case "workshop_execution":
            ProcedureDomainContract(oracle: .workshopRecordAndTimeline, fallback: .ordinaryWorkshopPlannerExecutor,
                                    capability: "workshop_execution")
        default: nil
        }
    }
}

public enum DeclarativeProcedureCompiler {
    public static func compile(_ candidate: ProcedureCandidate) throws -> DeclarativeProcedureArtifact {
        guard candidate.manualInvocationEligible else { throw ProcedureCompilationError.candidateNotEligible }
        guard let review = candidate.reviewerDecision, review.verdict == .approve,
              review.candidateEvidenceDigest == candidate.reviewBindingDigest else {
            throw ProcedureCompilationError.missingReviewerApproval
        }
        guard let domain = ProcedureDomainContract.named(candidate.canonicalTrajectory.domain) else {
            throw ProcedureCompilationError.unsupportedDomain
        }
        let trajectory = candidate.canonicalTrajectory
        let table = trajectory.steps.enumerated().map { index, step in
            ProcedureTransitionRule(
                sequence: index,
                beforeState: step.beforeState,
                onTransitionKind: step.transitionKind,
                actionKind: step.actionKind,
                requiredEvidenceKind: step.evidenceKind,
                expectedNextEvidence: step.expectedNextEvidence,
                checkpointClass: step.checkpointClass,
                externalEffectClass: step.externalEffectClass,
                afterState: step.afterState,
                verificationClass: step.verificationClass,
                terminalClass: step.terminalClass
            )
        }
        let schemas = Array(Set(candidate.sourceTrajectories.map(\.parameterSchemaIdentity))).sorted()
        let effects = Array(Set(candidate.sourceTrajectories.flatMap(\.externalEffectClasses))).sorted()
        let approvalOwner = trajectory.authorityClass == "confirm_required" ? "approval_inbox" : nil
        let safety = ProcedureSafetyDeclaration(
            trustCenterCapability: domain.capability,
            requiredPreconditions: [
                "authority_class_matches",
                "canonical_executor_available",
                "domain_state_matches",
                "input_schema_matches",
            ],
            recheckPoints: [.beforeInvocation, .beforeEveryAction, .afterEveryCheckpoint],
            canonicalApprovalOwner: approvalOwner,
            externalSendsEligible: false,
            permissionAuthority: false,
            automaticActivationAllowed: false
        )
        return try DeclarativeProcedureArtifact(
            schema: DeclarativeProcedureArtifact.schema,
            id: "",
            interpretation: "trusted_declarative_transition_table_v1",
            sourceTrajectoryIdentities: Array(candidate.sourceTrajectories.map(\.id).sorted().prefix(64)),
            domain: trajectory.domain,
            procedureShapeIdentity: trajectory.procedureShapeIdentity,
            inputContract: ProcedureInputContract(
                taskFamily: trajectory.taskFamily,
                inputClass: trajectory.inputClass,
                parameterSchemaClass: trajectory.parameterSchemaClass,
                acceptedParameterSchemaIdentities: schemas,
                allowedExternalEffectClasses: effects
            ),
            authorityClass: trajectory.authorityClass,
            canonicalOracle: domain.oracle,
            transitionTable: table,
            safety: safety,
            deterministicAbandonConditions: candidate.deterministicAbandonConditions,
            deterministicFallback: domain.fallback,
            rollbackDeclaration: "delete_artifact_restore_fallback_no_data_migration",
            reviewerDecision: review,
            manualInvocationEligible: true,
            canaryEligible: candidate.canaryEligible,
            automaticSelectionEligible: false,
            generatedExecutableCode: false
        ).withCanonicalIdentity()
    }
}

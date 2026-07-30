import Foundation
import NativeAgentCore
import PersistenceCore

public enum WorkshopCompiledProcedurePlanError: Error, LocalizedError, Equatable {
    case artifactNotEligible
    case artifactShapeMismatch
    case invalidRelativePath(String)
    case pathOutsideWorkspace
    case sourceUnavailable
    case sourceTooLarge
    case sourceNotUTF8
    case destinationParentUnavailable
    case sourceEqualsDestination
    case sourceChangedAfterPreflight
    case destinationChangedAfterPreflight
    case toolResultMismatch

    public var errorDescription: String? {
        switch self {
        case .artifactNotEligible:
            return "The procedure artifact is not eligible for a provider-free Workshop invocation."
        case .artifactShapeMismatch:
            return "The procedure artifact does not describe the supported read-file/write-file routine."
        case .invalidRelativePath(let field):
            return "The \(field) path must be a non-empty workspace-relative path without traversal."
        case .pathOutsideWorkspace:
            return "The procedure path resolves outside the injected workspace root."
        case .sourceUnavailable:
            return "The procedure source must be a readable regular file."
        case .sourceTooLarge:
            return "The procedure source exceeds the exact 64 KiB read-file limit."
        case .sourceNotUTF8:
            return "The procedure source must be exact UTF-8 text for the existing read-file tool."
        case .destinationParentUnavailable:
            return "The procedure destination parent must already exist inside the workspace."
        case .sourceEqualsDestination:
            return "The procedure source and destination must be different files."
        case .sourceChangedAfterPreflight:
            return "The procedure source changed after exact preflight; ordinary Workshop fallback is required."
        case .destinationChangedAfterPreflight:
            return "The procedure destination boundary changed after exact preflight; ordinary Workshop fallback is required."
        case .toolResultMismatch:
            return "The canonical file tool result did not match the exact reviewed procedure binding."
        }
    }
}

/// The first deliberately narrow, provider-free Workshop plan target.
///
/// This is not a new executor, scheduler, store, or authority owner. It is a
/// value-only `WorkshopPlannerLLM` adapter that turns one locally reviewed,
/// immutable declarative artifact into the same canonical two-step Workshop
/// plan the ordinary planner previously produced. Submission, tool dispatch,
/// verification, receipts, cancellation, Desk state, and Trust Center gates
/// remain owned by their existing systems.
public struct WorkshopCompiledLocalFileCopyPlanner: WorkshopPlannerLLM, Sendable {
    public static let maximumSourceBytes = 64 * 1_024
    public static let procedureID = "local_file_copy_v1"
    /// Content identity of the exact native semantic contract. Changing path
    /// rules, byte limits, tool sequence, append behavior, or verification
    /// requires a new identity and therefore a new local activation.
    public static let implementationIdentity = CausalTransitionEvidence.opaqueIdentity(
        "local_file_copy_v1|read_file(max_bytes=65536,path=source)|"
            + "write_file(append=false,content=step-1,path=destination)|"
            + "workspace-contained|regular-readable-source|exact-utf8|"
            + "existing-contained-parent|source-not-destination|file-bytes-verification"
    )
    public static let qualificationProtocolIdentity =
        ProcedureExactActivationProposal.requiredQualificationProtocolIdentity

    public let directProviderCallCountPerInvocation: Int? = 0
    public let sourceToolPath: String
    public let destinationToolPath: String
    public let contract: WorkshopProcedureContractProjection
    /// Opaque binding over the artifact, relative input locations, and exact
    /// bounded source bytes. A caller combines this with its stable request key
    /// so crash/retry reuses one procedure invocation without persisting raw
    /// parameters in the procedure ledger.
    public let operationBindingIdentity: String

    private let workspaceRootURL: URL
    private let sourceURL: URL
    private let destinationURL: URL
    private let destinationParentURL: URL
    private let sourceContentIdentity: String

    private let encodedPlan: String

    public init(
        artifact: DeclarativeProcedureArtifact,
        workspaceRoot: URL,
        sourceRelativePath: String,
        destinationRelativePath: String,
        fileManager: FileManager = .default
    ) throws {
        guard Self.isEligibleArtifact(artifact) else {
            throw WorkshopCompiledProcedurePlanError.artifactNotEligible
        }

        let workspace = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let sourceRelative = try Self.validatedRelativePath(
            sourceRelativePath,
            field: "source"
        )
        let destinationRelative = try Self.validatedRelativePath(
            destinationRelativePath,
            field: "destination"
        )
        let source = workspace.appendingPathComponent(sourceRelative)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isContained(source, by: workspace) else {
            throw WorkshopCompiledProcedurePlanError.pathOutsideWorkspace
        }
        guard let sourceValues = try? source.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey]
        ), sourceValues.isRegularFile == true, sourceValues.isReadable != false else {
            throw WorkshopCompiledProcedurePlanError.sourceUnavailable
        }
        guard (sourceValues.fileSize ?? Int.max) <= Self.maximumSourceBytes else {
            throw WorkshopCompiledProcedurePlanError.sourceTooLarge
        }
        guard let sourceData = try? Data(contentsOf: source, options: [.mappedIfSafe]),
              sourceData.count <= Self.maximumSourceBytes,
              let sourceText = String(data: sourceData, encoding: .utf8),
              Data(sourceText.utf8) == sourceData else {
            throw WorkshopCompiledProcedurePlanError.sourceNotUTF8
        }

        let unresolvedDestination = workspace.appendingPathComponent(destinationRelative)
            .standardizedFileURL
        let destinationParent = unresolvedDestination.deletingLastPathComponent()
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard Self.isContained(destinationParent, by: workspace),
              fileManager.fileExists(atPath: destinationParent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkshopCompiledProcedurePlanError.destinationParentUnavailable
        }
        let destination = unresolvedDestination.resolvingSymlinksInPath()
        guard Self.isContained(destination, by: workspace) else {
            throw WorkshopCompiledProcedurePlanError.pathOutsideWorkspace
        }
        guard source.path != destination.path else {
            throw WorkshopCompiledProcedurePlanError.sourceEqualsDestination
        }

        let sourceToolPath = "workspace/\(sourceRelative)"
        let destinationToolPath = "workspace/\(destinationRelative)"
        let steps = [
            WorkshopExecutionStep(
                id: "step-1",
                description: "Read the reviewed workspace source file",
                toolOrAction: "read_file",
                args: .object([
                    "max_bytes": .string(String(Self.maximumSourceBytes)),
                    "path": .string(sourceToolPath),
                ]),
                autonomy: "needs_approval"
            ),
            WorkshopExecutionStep(
                id: "step-2",
                description: "Write the exact source bytes to the reviewed workspace destination",
                toolOrAction: "write_file",
                args: .object([
                    "append": .string("false"),
                    "content": .string("{{step:step-1}}"),
                    "path": .string(destinationToolPath),
                ]),
                autonomy: "needs_approval"
            ),
        ]
        let record = WorkshopExecutionRecord(
            id: "compiled-procedure-projection",
            title: "Compiled local file copy",
            objective: "Execute an approved deterministic local file copy",
            createdAt: "1970-01-01T00:00:00Z",
            status: "queued",
            plan: steps,
            stepsCompleted: [],
            receiptsDir: "",
            triggerSource: "manual",
            trustRequired: "none",
            expectedOutputs: [],
            currentStepId: "",
            updatedAt: "1970-01-01T00:00:00Z",
            result: .null,
            rerunCount: 0,
            planningProviderCallCount: 0,
            planningRemovableOrchestrationProviderCallCount: 0
        )
        let contract = SwiftNativeWorkshopRunner.procedureContractProjection(record: record)
        guard contract.taskFamily == artifact.inputContract.taskFamily,
              contract.inputClass == artifact.inputContract.inputClass,
              contract.procedureShapeIdentity == artifact.procedureShapeIdentity,
              artifact.inputContract.acceptedParameterSchemaIdentities.contains(
                contract.parameterSchemaIdentity
              ),
              contract.authorityClass == artifact.authorityClass,
              Set(contract.externalEffectClasses).isSubset(
                of: Set(artifact.inputContract.allowedExternalEffectClasses)
              ) else {
            throw WorkshopCompiledProcedurePlanError.artifactShapeMismatch
        }

        self.sourceToolPath = sourceToolPath
        self.destinationToolPath = destinationToolPath
        self.contract = contract
        self.workspaceRootURL = workspace
        self.sourceURL = source
        self.destinationURL = destination
        self.destinationParentURL = destinationParent
        self.sourceContentIdentity = CausalTransitionEvidence.opaqueIdentity(sourceText)
        self.operationBindingIdentity = CausalTransitionEvidence.opaqueIdentity([
            artifact.id,
            sourceRelative,
            destinationRelative,
            sourceContentIdentity,
        ].joined(separator: "|"))
        self.encodedPlan = try JSONValue.object([
            "steps": .array(steps.map { step in
                .object([
                    "id": .string(step.id),
                    "description": .string(step.description),
                    "tool_or_action": .string(step.toolOrAction),
                    "args": step.args,
                    "autonomy_hint": .string(step.autonomy),
                ])
            }),
        ]).serialize(pretty: false)
    }

    public func availableConnectorActions() async -> [JSONValue] {
        [
            .object([
                "id": .string("read_file"),
                "description": .string("Read a workspace file"),
            ]),
            .object([
                "id": .string("write_file"),
                "description": .string("Write a workspace file"),
            ]),
        ]
    }

    public func runCodex(
        prompt: String,
        surface: String,
        timeoutSeconds: Int
    ) async throws -> (model: String, output: String) {
        (model: "native-procedure", output: encodedPlan)
    }

    public static func isEligibleArtifact(_ artifact: DeclarativeProcedureArtifact) -> Bool {
        guard artifact.schema == DeclarativeProcedureArtifact.schema,
              artifact.domain == "workshop_execution",
              artifact.canonicalOracle == .workshopRecordAndTimeline,
              artifact.authorityClass == "low_risk",
              artifact.reviewerDecision.verdict == .approve,
              artifact.manualInvocationEligible,
              !artifact.automaticSelectionEligible,
              !artifact.generatedExecutableCode,
              !artifact.safety.externalSendsEligible,
              !artifact.safety.permissionAuthority,
              !artifact.safety.automaticActivationAllowed,
              artifact.safety.trustCenterCapability == "workshop_execution" else {
            return false
        }
        let expectedActions: [String?] = [
            "queue_admission", "execute_plan", "tool:read_file", "tool:write_file", nil,
        ]
        let expectedEffects = [
            "local_control", "local_control", "local_read", "local_write", "local_control",
        ]
        guard artifact.transitionTable.count == expectedActions.count else { return false }
        for (index, rule) in artifact.transitionTable.enumerated() {
            guard rule.sequence == index,
                  rule.actionKind == expectedActions[index],
                  rule.externalEffectClass == expectedEffects[index] else { return false }
        }
        let rules = artifact.transitionTable
        return rules[0].beforeState == nil
            && rules[0].onTransitionKind == "enqueued"
            && rules[0].afterState == "queued"
            && rules[1].beforeState == "queued"
            && rules[1].onTransitionKind == "started"
            && rules[1].afterState == "running"
            && rules[2].beforeState == "running"
            && rules[2].onTransitionKind == "step_completed"
            && rules[2].afterState == "running"
            && rules[3].beforeState == "running"
            && rules[3].onTransitionKind == "step_completed"
            && rules[3].afterState == "running"
            && rules[4].beforeState == "running"
            && rules[4].onTransitionKind == "completed"
            && rules[4].afterState == "completed"
            && rules[4].requiredEvidenceKind == "domain_verification"
            && rules[4].checkpointClass == "domain_outcome_verification"
            && rules[4].verificationClass == "verified"
            && rules[4].terminalClass == .verifiedSuccess
    }

    /// Rechecks the immutable invocation binding at the last shared point
    /// before each canonical tool dispatch. The tools keep file authority;
    /// this guard only refuses to run the compiled shortcut when its exact
    /// source bytes or resolved destination boundary drifted after preflight.
    public func validateBeforeDispatch(
        tool: String,
        arguments: [String: JSONValue],
        fileManager: FileManager = .default
    ) throws {
        switch tool {
        case "read_file":
            guard arguments["path"] == .string(sourceToolPath),
                  arguments["max_bytes"] == .string(String(Self.maximumSourceBytes)) else {
                throw WorkshopCompiledProcedurePlanError.artifactShapeMismatch
            }
            try validateCurrentSource(fileManager: fileManager)
        case "write_file":
            guard arguments["path"] == .string(destinationToolPath),
                  arguments["append"] == .string("false"),
                  case .string(let content)? = arguments["content"],
                  CausalTransitionEvidence.opaqueIdentity(content) == sourceContentIdentity else {
                throw WorkshopCompiledProcedurePlanError.toolResultMismatch
            }
            // Refuse a source mutation between the read receipt and the write,
            // even though the bound content itself is still exact.
            try validateCurrentSource(fileManager: fileManager)
            let currentParent = destinationURL.deletingLastPathComponent()
                .standardizedFileURL.resolvingSymlinksInPath()
            let currentDestination = destinationURL.standardizedFileURL
                .resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard currentParent == destinationParentURL,
                  Self.isContained(currentParent, by: workspaceRootURL),
                  fileManager.fileExists(atPath: currentParent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  currentDestination == destinationURL,
                  Self.isContained(currentDestination, by: workspaceRootURL),
                  currentDestination != sourceURL else {
                throw WorkshopCompiledProcedurePlanError.destinationChangedAfterPreflight
            }
        default:
            throw WorkshopCompiledProcedurePlanError.artifactShapeMismatch
        }
    }

    public func validateAfterDispatch(tool: String, result: JSONValue) throws {
        guard tool == "read_file" else { return }
        guard case .string(let text) = result,
              CausalTransitionEvidence.opaqueIdentity(text) == sourceContentIdentity else {
            throw WorkshopCompiledProcedurePlanError.toolResultMismatch
        }
    }

    private func validateCurrentSource(fileManager: FileManager) throws {
        let current = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard current == sourceURL, Self.isContained(current, by: workspaceRootURL),
              let values = try? current.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey]
              ),
              values.isRegularFile == true, values.isReadable != false,
              (values.fileSize ?? Int.max) <= Self.maximumSourceBytes,
              let data = try? Data(contentsOf: current, options: [.mappedIfSafe]),
              data.count <= Self.maximumSourceBytes,
              let text = String(data: data, encoding: .utf8),
              Data(text.utf8) == data,
              CausalTransitionEvidence.opaqueIdentity(text) == sourceContentIdentity else {
            throw WorkshopCompiledProcedurePlanError.sourceChangedAfterPreflight
        }
    }

    private static func validatedRelativePath(
        _ raw: String,
        field: String
    ) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorkshopCompiledProcedurePlanError.invalidRelativePath(field)
        }
        return trimmed
    }

    private static func isContained(_ candidate: URL, by root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

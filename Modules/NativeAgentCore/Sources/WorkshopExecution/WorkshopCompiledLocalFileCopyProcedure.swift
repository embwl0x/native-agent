import Foundation
import NativeAgentCore
import PersistenceCore
import Procedures
// Blueprint: | `WorkshopCompiledLocalFileCopyProcedure.swift` | `WorkshopCompiledProcedurePlanError` enum |

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

/// A reviewed immutable artifact supplies typed, provider-free copy steps.
/// The canonical Workshop queue, dispatch, verification and Trust gates execute them.
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

    public let sourceToolPath: String
    public let destinationToolPath: String
    public let contract: WorkshopProcedureContractReadout
    /// Opaque binding over the artifact, relative input locations, and exact
    /// bounded source bytes. A caller combines this with its stable request key
    /// so crash/retry reuses one procedure invocation without persisting raw
    /// parameters in the procedure ledger.
    public let operationBindingIdentity: String

    public let binding: WorkshopCompiledFileCopyBinding

    private let steps: [WorkshopExecutionStep]

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
                    "max_bytes": .int(Int64(Self.maximumSourceBytes)),
                    "path": .string(sourceToolPath),
                ]),
                autonomy: "needs_approval",
                optional: false
            ),
            WorkshopExecutionStep(
                id: "step-2",
                description: "Write the exact source bytes to the reviewed workspace destination",
                toolOrAction: "write_file",
                args: .object([
                    "append": .bool(false),
                    "content": .string("{{step:step-1}}"),
                    "path": .string(destinationToolPath),
                ]),
                autonomy: "needs_approval",
                optional: false
            ),
        ]
        let contract = SwiftNativeWorkshopRunner.procedureContractProjection(
            plan: steps, trustRequired: "none", triggerSource: "manual"
        )
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
        let sourceContentIdentity = CausalTransitionEvidence.opaqueIdentity(sourceText)
        self.binding = WorkshopCompiledFileCopyBinding(
            workspaceRootURL: workspace, sourceURL: source, destinationURL: destination,
            destinationParentURL: destinationParent, sourceContentIdentity: sourceContentIdentity,
            sourceToolPath: sourceToolPath, destinationToolPath: destinationToolPath)
        self.operationBindingIdentity = CausalTransitionEvidence.opaqueIdentity([
            artifact.id,
            sourceRelative,
            destinationRelative,
            sourceContentIdentity,
        ].joined(separator: "|"))
        self.steps = steps
    }

    public func plan(spec: WorkshopExecutionSpec, dataRoot: URL, now: Date) async throws
        -> (steps: [WorkshopExecutionStep], providerCallCount: Int?, binding: WorkshopCompiledFileCopyBinding?) {
        try Task.checkCancellation()
        return (steps, 0, binding)
    }

    public static func isEligibleArtifact(_ artifact: DeclarativeProcedureArtifact) -> Bool {
        guard ProcedureArtifactStore.valid(artifact), artifact.domain == "workshop_execution",
              artifact.authorityClass == "low_risk" else { return false }
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

    fileprivate static func isContained(_ candidate: URL, by root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return NativeAgentWorkspaceRoot.relativePath(candidatePath, under: rootPath) != nil
    }
}

public struct WorkshopCompiledFileCopyBinding: Codable, Sendable, Equatable {
    let workspaceRootURL: URL
    let sourceURL: URL
    let destinationURL: URL
    let destinationParentURL: URL
    let sourceContentIdentity: String
    let sourceToolPath: String
    let destinationToolPath: String

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
                  arguments["max_bytes"] == .int(Int64(WorkshopCompiledLocalFileCopyPlanner.maximumSourceBytes)) else {
                throw WorkshopCompiledProcedurePlanError.artifactShapeMismatch
            }
            guard workspaceRootURL.appendingPathComponent(String(sourceToolPath.dropFirst("workspace/".count)))
                .standardizedFileURL.resolvingSymlinksInPath() == sourceURL else {
                throw WorkshopCompiledProcedurePlanError.sourceChangedAfterPreflight
            }
            try validateCurrentSource(fileManager: fileManager)
        case "write_file":
            guard arguments["path"] == .string(destinationToolPath),
                  arguments["append"] == .bool(false),
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
                  workspaceRootURL.appendingPathComponent(String(destinationToolPath.dropFirst("workspace/".count)))
                    .standardizedFileURL.resolvingSymlinksInPath() == destinationURL,
                  WorkshopCompiledLocalFileCopyPlanner.isContained(currentParent, by: workspaceRootURL),
                  fileManager.fileExists(atPath: currentParent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  currentDestination == destinationURL,
                  WorkshopCompiledLocalFileCopyPlanner.isContained(currentDestination, by: workspaceRootURL),
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
        guard workspaceRootURL.appendingPathComponent(String(sourceToolPath.dropFirst("workspace/".count)))
                .standardizedFileURL.resolvingSymlinksInPath() == sourceURL,
              current == sourceURL, WorkshopCompiledLocalFileCopyPlanner.isContained(current, by: workspaceRootURL),
              let values = try? current.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey]
              ),
              values.isRegularFile == true, values.isReadable != false,
              (values.fileSize ?? Int.max) <= WorkshopCompiledLocalFileCopyPlanner.maximumSourceBytes,
              let data = try? Data(contentsOf: current, options: [.mappedIfSafe]),
              data.count <= WorkshopCompiledLocalFileCopyPlanner.maximumSourceBytes,
              let text = String(data: data, encoding: .utf8),
              Data(text.utf8) == data,
              CausalTransitionEvidence.opaqueIdentity(text) == sourceContentIdentity else {
            throw WorkshopCompiledProcedurePlanError.sourceChangedAfterPreflight
        }
    }

}

import Foundation
import NativeAgentCore
import NativeAgentEvaluation
import PersistenceCore
import WorkshopExecution

extension ChatDriveMain {
    /// Every Living Fabric projection carries the actual source-read result
    /// alongside its bounded count. A zero projection has meaning only after
    /// a source read; missing and unreadable sources must remain distinct.
    enum LivingFabricEvidenceSourceState: String {
        case read
        case sourceAbsent = "source absent"
        case sourceUnreadable = "source unreadable"
    }

    static func livingFabricDirectoryRead(
        _ url: URL
    ) -> (state: LivingFabricEvidenceSourceState, urls: [URL]) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
                return (.sourceUnreadable, [])
            }
            return (
                .read,
                try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            )
        } catch {
            // Foundation reports a missing path as NSFileReadNoSuchFileError
            // (260) from attributesOfItem/contentsOfDirectory; the legacy
            // NSFileNoSuchFileError (4) is kept for completeness. Anything
            // else (ENOTDIR, EACCES, ...) is a real read failure and must
            // stay "source unreadable" — absence and unreadability are
            // distinct receipt facts.
            let nsError = error as NSError
            let absent = nsError.domain == NSCocoaErrorDomain
                && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(nsError.code)
            return (absent ? .sourceAbsent : .sourceUnreadable, [])
        }
    }

    struct OperationalProcedureEvidence {
        let transitions: [CausalTransitionEvidence]
        let authoritativeOutcomes: [AuthoritativeTerminalOutcomeEvidence]
        let githubCommandSourceState: LivingFabricEvidenceSourceState
        let workshopExecutionSourceState: LivingFabricEvidenceSourceState
        let workshopExecutionDirectoriesRead: Int
        let workshopTimelineSourceState: LivingFabricEvidenceSourceState
        let workshopTimelineFilesRead: Int
    }

    /// One bounded evidence reader shared by the Living Fabric report and the
    /// local procedure operator. Review staging must evaluate the exact same
    /// canonical GitHub/Workshop rows as the read-only status report; a second
    /// looser collector would let an approval bind to evidence the report did
    /// not actually admit.
    static func collectOperationalProcedureEvidence(
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol,
        tolerateUnreadableSources: Bool = false
    ) async throws -> OperationalProcedureEvidence {
        let fileManager = FileManager.default
        let githubRoot = dataRoot.appendingPathComponent("workshop/github_command", isDirectory: true)
        let githubOps = githubRoot.appendingPathComponent("ops.jsonl")
        let githubBase = githubRoot.appendingPathComponent("ops_base.json")
        let githubDirectoryRead = livingFabricDirectoryRead(githubRoot)
        let githubSourceState: LivingFabricEvidenceSourceState
        var transitions: [CausalTransitionEvidence]
        if githubDirectoryRead.state != .read {
            githubSourceState = githubDirectoryRead.state
            transitions = []
        } else if !fileManager.fileExists(atPath: githubOps.path),
           !fileManager.fileExists(atPath: githubBase.path) {
            githubSourceState = .sourceAbsent
            transitions = []
        } else {
            do {
                transitions = try await GitHubCommandStore(dataRoot: dataRoot)
                    .causalTransitionEvidence(limit: 2_048)
                githubSourceState = .read
            } catch {
                guard tolerateUnreadableSources else { throw error }
                // This report is diagnostic. A bad canonical feed must not
                // crash it into silence or become an empty transition count.
                transitions = []
                githubSourceState = .sourceUnreadable
            }
        }
        var authoritativeOutcomes: [AuthoritativeTerminalOutcomeEvidence] = []
        let workshopRunner = SwiftNativeWorkshopRunner(
            executorAvailable: false,
            root: dataRoot,
            enableAutonomy: false
        )
        let executionsRoot = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
        let executionRead = livingFabricDirectoryRead(executionsRoot)
        let executionDirectories = executionRead.urls.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if lhs != rhs { return lhs < rhs }
            return $0.lastPathComponent < $1.lastPathComponent
        }
        var workshopTimelineFilesRead = 0
        var workshopTimelineReadFailed = false

        // Builder evidence remains bounded before the final suffix so a
        // malformed/custom root cannot turn review staging into an archival
        // scan or an authority denial into a memory-pressure failure.
        for directory in executionDirectories.suffix(128) {
            let executionRecord = await workshopRunner.getWorkshopExecution(
                directory.lastPathComponent
            )
            let timelineURL = directory.appendingPathComponent("timeline.jsonl")
            let timeline: [JSONValue]
            if !fileManager.fileExists(atPath: timelineURL.path) {
                timeline = []
            } else {
                do {
                    timeline = try await persistence.tailJSONL(
                        timelineURL,
                        limit: 256,
                        maxBytes: 512 * 1_024
                    )
                    workshopTimelineFilesRead += 1
                } catch {
                    guard tolerateUnreadableSources else { throw error }
                    timeline = []
                    workshopTimelineReadFailed = true
                }
            }
            transitions.append(contentsOf: SwiftNativeWorkshopRunner.causalTransitionEvidence(
                executionId: directory.lastPathComponent,
                timeline: timeline,
                record: executionRecord,
                limit: 256
            ))
            if transitions.count > 20_000 {
                transitions.sort {
                    let lhs = parseLivingFabricDate($0.occurredAt) ?? .distantPast
                    let rhs = parseLivingFabricDate($1.occurredAt) ?? .distantPast
                    if lhs != rhs { return lhs < rhs }
                    return $0.operationId < $1.operationId
                }
                transitions = Array(transitions.suffix(20_000))
            }
            let action: MotorActionReadModel?
            do {
                action = try await workshopRunner.motorActionReadModel(
                    actionId: directory.lastPathComponent
                )
            } catch {
                guard tolerateUnreadableSources else { throw error }
                workshopTimelineReadFailed = true
                action = nil
            }
            if let action, let occurredAt = action.updatedAt {
                let kind: AuthoritativeTerminalOutcomeEvidence.Kind?
                switch (action.phase, action.verification) {
                case (.succeeded, .satisfied): kind = .verifiedSuccess
                case (.failed, .failed): kind = .verifiedFailure
                case (.cancelled, .notRequired): kind = .cancelled
                default: kind = nil
                }
                if let kind {
                    authoritativeOutcomes.append(AuthoritativeTerminalOutcomeEvidence(
                        domain: action.domain,
                        itemIdentity: action.actionIdentity,
                        occurredAt: occurredAt,
                        kind: kind
                    ))
                }
            }
        }
        transitions.sort {
            let lhs = parseLivingFabricDate($0.occurredAt) ?? .distantPast
            let rhs = parseLivingFabricDate($1.occurredAt) ?? .distantPast
            if lhs != rhs { return lhs < rhs }
            return $0.operationId < $1.operationId
        }
        let workshopTimelineSourceState: LivingFabricEvidenceSourceState
        if workshopTimelineReadFailed {
            workshopTimelineSourceState = .sourceUnreadable
        } else if executionRead.state != .read {
            workshopTimelineSourceState = executionRead.state
        } else if !executionDirectories.isEmpty, workshopTimelineFilesRead == 0 {
            workshopTimelineSourceState = .sourceAbsent
        } else {
            workshopTimelineSourceState = .read
        }
        return OperationalProcedureEvidence(
            transitions: Array(transitions.suffix(20_000)),
            authoritativeOutcomes: authoritativeOutcomes,
            githubCommandSourceState: githubSourceState,
            workshopExecutionSourceState: executionRead.state,
            workshopExecutionDirectoriesRead: executionDirectories.count,
            workshopTimelineSourceState: workshopTimelineSourceState,
            workshopTimelineFilesRead: workshopTimelineFilesRead
        )
    }

    static func parseLivingFabricDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}

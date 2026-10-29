import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import Desk
import ApprovalInbox
import WorkshopExecution
import AgentWorkspace
import NotificationInbox
import Privacy
import Cognition
// Blueprint: | `HeartbeatBackgroundWork.swift` | Existing heartbeat work binding, event/deadline loop construction and age limits |
public struct HeartbeatBackgroundWork: Sendable {
    internal let port: any BackgroundWorkNotificationPort

    public init(port: any BackgroundWorkNotificationPort) { self.port = port }

    /// Health heartbeat driven by assessment-input changes and age crossings. Reads
    /// `HEARTBEAT.md` from the persona dir, gathers a compact live signal
    /// block (stuck executions / Full-Mac expiry / Doctor),
    /// and surfaces deterministic anomalies as stable inbox cards. Clean
    /// assessments make no notice; anomalies use their per-condition template. The checklist read,
    /// assessment gather, and notice surface share this owner.
    public func makeHeartbeatLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> HeartbeatLoop {
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        // Live-verify hook: a terminal-launched bundle can shrink the integrity interval
        // (NATIVE_AGENT_HEARTBEAT_INTERVAL_SECONDS=60) to watch a real tick.
        // The normal `open`-launched app never has this set → 12h integrity.
        // Floor at 1s: interval ≤ 0 reaches Task.sleep(0) in the scheduler —
        // a tight busy loop.
        let configured = ProcessInfo.processInfo.environment["NATIVE_AGENT_HEARTBEAT_INTERVAL_SECONDS"]
        let parsed = configured.flatMap(TimeInterval.init)
        let valid = parsed.map { $0.isFinite && $0 >= 1
            && $0 * 1_000_000_000 < Double(UInt64.max) } ?? false
        let configurationError = configured != nil && !valid
            ? "NATIVE_AGENT_HEARTBEAT_INTERVAL_SECONDS must be at least 1 second and representable in UInt64 nanoseconds."
            : nil
        // Invalid configuration is a failed tick, paced by the normal integrity cadence.
        let interval = valid ? (parsed ?? HeartbeatLoop.defaultInterval) : HeartbeatLoop.defaultInterval
        return HeartbeatLoop(
            interval: interval,
            configurationError: configurationError,
            events: {
                let ledger = SwiftNativeTaskLedger(dataRoot: dataRoot)
                let desk = SwiftNativeDeskStore(dataRoot: dataRoot)
                let executions = dataRoot.appendingPathComponent("workshop/executions", isDirectory: true)
                let workflows = dataRoot.appendingPathComponent("workflows/run_state", isDirectory: true)
                let executionFiles = ((try? FileManager.default.contentsOfDirectory(
                    at: executions, includingPropertiesForKeys: nil)) ?? [])
                    .map { ExecutionRecordFile.canonicalPath(in: $0) }
                let workflowFiles = (try? FileManager.default.contentsOfDirectory(
                    at: workflows, includingPropertiesForKeys: nil)) ?? []
                // Nested records created after subscription retain the 12h
                // missed-event backstop; the vnode watcher is not recursive.
                return EventDeadlinePhysiology.storeAndFileEvents(
                    paths: [personaRoot.appendingPathComponent("HEARTBEAT.md"),
                            dataRoot.appendingPathComponent("doctor/latest.json"),
                            ledger.eventsPath, ledger.basePath, desk.opsPath, desk.basePath,
                            executions, workflows,
                            dataRoot.deletingLastPathComponent().appendingPathComponent("docs/eval_acknowledgments.json")]
                        + executionFiles + workflowFiles
                        + ErrorFeeds.errorFeeds.map { $0.url(dataRoot: dataRoot) }
                        + DelegationStatusProjector(dataRoot: dataRoot).watchedPaths,
                    stores: [.desk],
                    notifications: [.NSSystemTimeZoneDidChange, .NSSystemClockDidChange,
                        DeskContinuationScheduler.ownerReceiptChanged],
                    loopId: "heartbeat"
                )
            },
            nextDeadline: { now in
                await nextHeartbeatAssessmentDeadline(dataRoot: dataRoot, after: now)
            },
            loadChecklist: {
                let path = personaRoot.appendingPathComponent("HEARTBEAT.md")
                return try? String(contentsOf: path, encoding: .utf8)
            },
            gatherAssessment: {
                await gatherHeartbeatAssessment(
                    dataRoot: dataRoot
                )
            },
            surfaceNotice: { notice in
                // A failed inbox write must fail the tick.
                try await upsertHeartbeatNoticeCard(dataRoot: dataRoot, notice: notice)
            }
        )
    }
    internal let heartbeatExecutionStuckAge: TimeInterval = 6 * 60 * 60
    internal let heartbeatWorkflowStaleAge: TimeInterval = 60 * 60
    internal let heartbeatClaimStaleAge: TimeInterval = 24 * 60 * 60
    internal let heartbeatDeskStaleAge: TimeInterval = 30 * 24 * 60 * 60

    /// Time alone can make a retained input stale or clear an error burst.
    /// Project those crossings; changed inputs rearm the same manager deadline.
}

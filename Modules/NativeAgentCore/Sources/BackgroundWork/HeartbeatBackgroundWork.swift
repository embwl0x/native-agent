import AgentConversations
import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import Desk
import ApprovalInbox
import AgentWorkspace
import NotificationInbox
import Privacy
import Cognition
// Blueprint: | `HeartbeatBackgroundWork.swift` | Existing heartbeat work binding, event/deadline loop construction and age limits |
public struct HeartbeatBackgroundWork: Sendable {
    internal let port: any BackgroundWorkNotificationPort

    public init(port: any BackgroundWorkNotificationPort) { self.port = port }

    /// Keep checklist, live assessment and notice settlement in one owner so condition cards reflect the same reading.
    public func makeHeartbeatLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> HeartbeatLoop {
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        // A nonpositive interval reaches Task.sleep(0), causing a busy loop; floor it at one second.
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
                let workflows = dataRoot.appendingPathComponent("workflows/run_state", isDirectory: true)
                func children(_ path: URL) -> [URL] {
                    do { return try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) }
                    catch CocoaError.fileReadNoSuchFile { return [] }
                    catch {
                        let cause = """
                            Heartbeat source watches are incompletely armed at \(path.path): \(error.localizedDescription). Repair directory access and \
                            reopen NativeAgent to rearm its child watches; the parent watch remains active.
                            """
                        Task { await BackgroundLoopLifetimes.shared.recordOutOfBandOutcome(loopId: "heartbeat", outcome: .failed(error: cause)) }
                        return []
                    }
                }
                let workflowFiles = children(workflows)
                // The watcher is not recursive; retain the integrity pass for later-created nested records.
                return EventDeadlinePhysiology.storeAndFileEvents(
                    paths: [personaRoot.appendingPathComponent("HEARTBEAT.md"),
                            dataRoot.appendingPathComponent("doctor/latest.json"),
                            ledger.eventsPath, ledger.basePath, desk.opsPath, desk.basePath,
                            AgentJobStore(dataRoot: dataRoot).fileURL, workflows]
                        + workflowFiles
                        + ErrorFeeds.errorFeeds.map { $0.url(dataRoot: dataRoot) },
                    stores: [.desk],
                    notifications: [.NSSystemTimeZoneDidChange, .NSSystemClockDidChange, LoopFailureReceipts.didWrite],
                    loopId: "heartbeat"
                )
            },
            nextDeadline: { now in
                await nextHeartbeatAssessmentDeadline(dataRoot: dataRoot, after: now)
            },
            loadChecklist: {
                let path = personaRoot.appendingPathComponent("HEARTBEAT.md")
                do { return try String(contentsOf: path, encoding: .utf8) }
                catch CocoaError.fileReadNoSuchFile { return nil }
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
    internal let heartbeatWorkflowStaleAge: TimeInterval = 60 * 60
    internal let heartbeatDeskStaleAge: TimeInterval = 30 * 24 * 60 * 60

    /// Time alone can make a retained input stale or clear an error burst.
    /// Project those crossings; changed inputs rearm the same manager deadline.
}

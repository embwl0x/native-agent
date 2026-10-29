import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import ChatSessionWork
import Context
import DoctorChecks
import PersistenceCore
import TurnTrace
import ApprovalInbox
import NotificationInbox
import MemoryV2
import DreamREMCycle
import AgentWorkspace
import Desk
import AttentionRouting
import Privacy
import ProviderRouting
import Experiences
import ToolRegistry
import Cognition
// Blueprint: | `TurnTraceRetentionRunner.swift` | `MaintenanceBackgroundWork.makeTurnTraceRetentionLoop`; bounded trace expiry, orphan lock sidecars and pre-compaction transcript backup retention with named outcomes |

extension MaintenanceBackgroundWork {
    /// The mounted six-hour retention wake handles date-named trace expiry,
    /// old orphan lock sidecars, and excess pre-compaction transcript backups.
    /// The generic sweep is bounded, so it drains large historical residue
    /// across wakes instead of turning a maintenance tick into a disk walk.
    public func makeTurnTraceRetentionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 6 * 60 * 60
    ) -> some LoopRunner {
        TurnTraceRetentionRunner(
            interval: intervalSeconds,
            dataRoot: dataRoot
        )
    }
}

/// Prunes traces to the newest ~14 days and reclaims orphaned locks.
private struct TurnTraceRetentionRunner: LoopRunner {
    let interval: TimeInterval
    let dataRoot: URL

    var loopId: String { "turn_trace_retention" }
    var tickTimeoutOverride: TimeInterval? { 60 }

    func tickOutcome() async -> LoopTickOutcome {
        do {
            let now = Date()
            let traceReport = try await TurnTraceRetention.enforce(dataRoot: dataRoot, now: now)
            let lockReport = try await FileLockSidecarLifecycle.reapOrphanedSidecars(
                dataRoot: dataRoot,
                now: now
            )
            let backupReport = await ChatCompactionBackupRetention.enforce(dataRoot: dataRoot)
            // Removed artifacts are reported through logs and the scheduler outcome.
            if traceReport.removedDays > 0 {
                nativeLog("turn_trace_retention: removed %d day file(s) and %d lock(s), kept %d day(s)",
                      traceReport.removedDays, 0, traceReport.keptDays)
            }
            if lockReport.reaped > 0 || lockReport.deferred > 0 || lockReport.failures > 0 {
                nativeLog("file_lock_sidecar_lifecycle: reaped %d orphan lock(s), deferred %d, failures %d",
                      lockReport.reaped, lockReport.deferred, lockReport.failures)
            }
            if lockReport.failures > 0 {
                return .failed(error: "lock-sidecar sweep had \(lockReport.failures) failed candidate(s)")
            }
            if backupReport.removed > 0 || backupReport.failures > 0 || backupReport.truncated {
                nativeLog("chat_compaction_backup_retention: removed %d backup(s), scanned %d session(s), failures %d, truncated %@",
                      backupReport.removed, backupReport.sessionsScanned, backupReport.failures,
                      backupReport.truncated.description)
            }
            if backupReport.failures > 0 {
                return .failed(error: "compaction-backup sweep had \(backupReport.failures) failed session(s)")
            }
            let bounded = lockReport.deferred > 0
                ? "; \(lockReport.deferred) orphan lock(s) deferred"
                : ""
            let backupBounded = backupReport.truncated
                ? "; compaction-backup scan bounded at \(backupReport.sessionsScanned) sessions"
                : ""
            // A sweep that removed nothing is a skip, so it cannot refresh successful-work age.
            let swept = traceReport.removedDays
                + lockReport.reaped + backupReport.removed
            guard swept > 0 else {
                return .skipped(reason: "nothing past any retention cutoff\(bounded)")
            }
            return .completed(
                result: "maintenance retention removed \(swept) artifact(s)"
                    + "\(bounded)\(backupBounded)")
        } catch {
            nativeLog("turn_trace_retention: sweep failed: %@", String(describing: error))
            return .failed(error: String(describing: error))
        }
    }
}

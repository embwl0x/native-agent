import Foundation
import NativeAgentShared

extension iCloudSyncEngine {
    func applySchedulerSnapshot(_ snapshot: MobileSchedulerSnapshot) {
        guard snapshot.capturedAt >= (schedulerSnapshot?.capturedAt ?? 0) else { return }
        var merged = snapshot
        schedulerJobReceiptTimes = schedulerJobReceiptTimes.filter { $0.value > snapshot.capturedAt }
        // Preserve newer action readbacks without discarding other jobs in this full snapshot.
        for job in schedulerSnapshot?.jobs ?? [] where schedulerJobReceiptTimes[job.id] != nil {
            if let index = merged.jobs.firstIndex(where: { $0.id == job.id }) {
                merged.jobs[index] = job
            } else {
                merged.jobs.append(job)
            }
        }
        schedulerSnapshot = merged
    }

    @discardableResult
    func refreshSchedulerSnapshot() async -> Bool {
        await refreshSnapshotStaleness()
        guard snapshotDir != nil else {
            schedulerError = "Scheduler is unavailable until this iPhone receives a snapshot from the Mac."
            return false
        }
        let lifecycle = lifecycleGeneration
        let snapshot: MobileSchedulerSnapshot? = await loadSnapshotObjectAsync(named: "scheduler.json")
        guard lifecycle == lifecycleGeneration else { return false }
        guard let snapshot else {
            schedulerError = "Could not refresh Scheduler. Keep the Mac app open and try again."
            return false
        }
        applySchedulerSnapshot(snapshot)
        schedulerError = nil
        return true
    }
}

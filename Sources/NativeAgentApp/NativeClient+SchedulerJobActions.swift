import Foundation
import PersistenceCore
import TriggerScheduler

extension NativeClient {
    func createJob(name: String, kind: String, intervalSeconds: Int) async throws -> ScheduledJob {
        // WAVE 33 W18 (2026-06-01): the POST /v1/scheduler/jobs WRITE is ported
        // into SwiftNative TriggerScheduler (create_job → normalize +
        // flock'd jobs.json append + activity event).
        // Connector-action jobs validate against the Swift action registry when
        // callers provide that kind; ordinary notify/dream/improve jobs remain
        // fully native.
        let writer = makeSchedulerJobWriter(
            connectorActionIDs: Self.connectorActionIDSet(),
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        let body: JSONValue = .object([
            "name": .string(name),
            "kind": .string(kind),
            "interval_seconds": .int(Int64(intervalSeconds)),
        ])
        return try ScheduledJob(row: try await writer.createJob(body: body))
    }

    /// Pause / resume one scheduled job — the write behind the Scheduler
    /// screen's enabled/paused control (item 36). Routes into the same flocked
    /// `scheduler/jobs.json` writer the create/cancel paths use, and lands a
    /// scheduler activity receipt.
    func setSchedulerJobEnabled(id: String, enabled: Bool) async throws -> ScheduledJob {
        let writer = makeSchedulerJobWriter(
            connectorActionIDs: Self.connectorActionIDSet(),
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        let result = try await writer.setJobEnabled(jobId: id, enabled: enabled)
        guard case .object(let object) = result, let job = object["job"] else {
            throw SchedulerJobsFeedError.unavailable("scheduler pause/resume returned no job")
        }
        return try ScheduledJob(row: job)
    }

}

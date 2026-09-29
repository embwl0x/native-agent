import Foundation
import NativeAgentShared
import PersistenceCore
import TriggerScheduler

enum MobileSchedulerProjection {
    static func read(using writer: any SchedulerJobWriter, jobID: String? = nil) async throws -> MobileSchedulerSnapshot {
        let capturedAt = Date().timeIntervalSince1970
        let rows = try await writer.listJobs()
        // Action readback checks only its own job; full publication still checks every row.
        let selected = rows.filter { row in
            guard let jobID else { return true }
            guard case .object(let object) = row else { return false }
            return object["id"] == .string(jobID)
        }
        let jobs = try selected.map { row in
            let job = try ScheduledJob(row: row)
            guard case .object(let object) = row else { throw ScheduledJob.RowError.notAnObject }
            func optionalString(_ key: String) throws -> String? {
                switch object[key] {
                case nil, .null?: return nil
                case .string(let value)?: return value
                default: throw ScheduledJob.RowError.field(key)
                }
            }
            let schedule: String
            if case .object(let fields)? = object["schedule"] {
                // Only schedule metadata; never pass arbitrary payload fields through.
                let labels = [
                    "type": "Schedule", "kind": "Schedule", "seconds": "Seconds",
                    "interval_seconds": "Seconds", "intervalSeconds": "Seconds",
                    "minutes": "Minutes", "hours": "Hours", "days": "Days",
                    "at": "At", "time": "Time", "hour": "Hour", "minute": "Minute",
                    "timezone": "Time zone", "tz": "Time zone",
                    "weekdays": "Weekdays", "weekday": "Weekday",
                    "day": "Day", "monthday": "Day", "monthDay": "Day",
                    "expression": "Cron", "cron": "Cron", "firstRunAt": "First run",
                    "run_at": "Run at", "runAt": "Run at"
                ]
                schedule = try fields.keys.filter { labels[$0] != nil }.sorted().map { key in
                    let value = fields[key]!
                    if case .string(let text) = value { return "\(labels[key]!): \(text)" }
                    return "\(labels[key]!): \(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))"
                }.joined(separator: " · ")
            } else if let seconds = job.intervalSeconds {
                schedule = "Every \(seconds) seconds"
            } else {
                throw ScheduledJob.RowError.field("schedule")
            }
            return MobileSchedulerJob(
                id: job.id, name: job.name, kind: job.kind, enabled: job.enabled,
                schedule: schedule, nextRunAt: job.nextRunAt, lastRunAt: job.lastRunAt,
                lastRunStatus: try optionalString("lastRunStatus"),
                cancelledAt: try optionalString("cancelledAt")
            )
        }
        return MobileSchedulerSnapshot(capturedAt: capturedAt, jobs: jobs)
    }
}

extension MacSyncEngine {
    func schedulerSnapshotData() async -> SnapshotGroupBuild {
        do {
            var snapshot = try await MobileSchedulerProjection.read(using: makeSchedulerJobWriter())
            if let path = snapshotDir?.appendingPathComponent("scheduler.json") {
                let previous = await MobileSnapshotBuilder.shared.build {
                    try? JSONDecoder().decode(MobileSchedulerSnapshot.self, from: Data(contentsOf: path))
                }
                // Preserve digest stability when an unrelated owner requests a pass.
                if let previous, previous.jobs == snapshot.jobs {
                    snapshot.capturedAt = previous.capturedAt
                }
            }
            return .built(try await encodeSnapshot(snapshot))
        } catch {
            return .skipped(error.localizedDescription)
        }
    }

    func startSchedulerSnapshotObservation() {
        schedulerSnapshotWatcher?.cancel()
        schedulerSnapshotWatcher = FileChangeWatcher(paths: [
            PersistenceCore.defaultDataRoot().appendingPathComponent("scheduler/jobs.json")
        ]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                await self.writeSnapshots()
            }
        }
    }
}

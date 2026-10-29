import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TriggerScheduler
// Blueprint: | `MacSyncEngine+Scheduler.swift` | `MacSyncEngine`: `schedulerSnapshotData`, `startSchedulerSnapshotObservation` |

enum MobileSchedules {
    static func read(using writer: SwiftNativeTriggerScheduler, jobID: String? = nil) async throws -> MobileSchedulerSnapshot {
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
            let object = try JSONRow(row)
            let schedule: String
            if let once = job.onceScheduleDescription {
                schedule = once
            } else if case .object(let fields)? = object.fields["schedule"] {
                // Only schedule metadata; never pass arbitrary payload fields through.
                let labels = [
                    "type": "Schedule", "kind": "Schedule", "seconds": "Seconds",
                    "interval_seconds": "Seconds", "intervalSeconds": "Seconds",
                    "minutes": "Minutes", "hours": "Hours", "days": "Days",
                    "at": "At", "time": "Time", "hour": "Hour", "minute": "Minute",
                    "weekdays": "Weekdays", "weekday": "Weekday",
                    "day": "Day", "monthday": "Day", "monthDay": "Day",
                    "expression": "Cron", "cron": "Cron", "firstRunAt": "First run",
                    "run_at": "Run at", "runAt": "Run at"
                ]
                schedule = try fields.keys.sorted().compactMap { key -> String? in
                    guard let label = labels[key], let value = fields[key] else { return nil }
                    if case .string(let text) = value { return "\(label): \(text)" }
                    return "\(label): \(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))"
                }.joined(separator: " · ")
            } else if let seconds = job.intervalSeconds {
                schedule = "Every \(seconds) seconds"
            } else {
                throw ScheduledJob.RowError.field("schedule")
            }
            do {
                return MobileSchedulerJob(
                    id: job.id, name: job.name, kind: job.kind, enabled: job.enabled,
                    schedule: schedule, nextRunAt: job.nextRunAt, lastRunAt: job.lastRunAt,
                    lastRunStatus: try object.optionalString("lastRunStatus"),
                    cancelledAt: try object.optionalString("cancelledAt")
                )
            } catch JSONRow.Malformed.field(let key) {
                throw ScheduledJob.RowError.field(key)
            }
        }
        var snapshot = MobileSchedulerSnapshot(capturedAt: capturedAt, jobs: jobs)
        // The Mac's current zone rides with the facts; the phone shows them in it (Law 7).
        snapshot.mac_time_zone = TimeZone.autoupdatingCurrent.identifier
        return snapshot
    }
}

extension MacSyncEngine {
    func schedulerSnapshotData() async -> SnapshotGroupBuild {
        do {
            var snapshot = try await MobileSchedules.read(using: makeSchedulerJobWriter())
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

    func startSchedulerSnapshotObservation() async {
        schedulerSnapshotWatcher?.cancel()
        let generation = snapshotLifecycleGeneration
        let watcher = await FileChangeWatcher.armed(paths: [
            PersistenceCore.defaultDataRoot().appendingPathComponent("scheduler/jobs.json")
        ]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, generation == self.snapshotLifecycleGeneration else { return }
                await self.writeSnapshots()
            }
        }
        guard isActive, generation == snapshotLifecycleGeneration else { watcher.cancel(); return }
        schedulerSnapshotWatcher = watcher
    }
}

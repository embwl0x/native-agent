import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `SchedulerRestoreFences.swift` | SwiftNativeTriggerScheduler pre-owner restore merge: selected definitions, current occurrence/effect facts only; recurrence advances using the selected schedule and consumed time |

extension SwiftNativeTriggerScheduler {
    /// Called before constructing live owners. Current-only jobs belong solely
    /// to the safety backup; neither their definitions nor their schedules move.
    public nonisolated static func mergeRestoreFences(safetyRoot: URL, destinationRoot: URL) throws -> [String] {
        let relative = "scheduler/jobs.json"
        let safetyPath = safetyRoot.appendingPathComponent("scheduler", isDirectory: true).appendingPathComponent("jobs.json")
        let destinationPath = destinationRoot.appendingPathComponent("scheduler", isDirectory: true).appendingPathComponent("jobs.json")
        let current: [JSONValue]
        do { current = try readJobsChecked(at: safetyPath) }
        catch { return ["\(relative): \(error.localizedDescription); current occurrence and consumption facts were not kept."] }
        let selected = try readJobsChecked(at: destinationPath)
        var restored = selected
        for index in restored.indices {
            guard case .object(var job) = restored[index],
                  let id = SchedulerJobRuntime.string(job["id"]), !id.isEmpty,
                  let row = current.first(where: { SchedulerJobRuntime.string($0.objectValue?["id"]) == id }),
                  case .object(let facts) = row else { continue }

            // An admitted effect remains owned by its original life. The
            // occurrence owner will reconcile it as stopped/restored, never run it.
            if let active = facts["activeOccurrence"] { job["activeOccurrence"] = active }

            let consumedAt = SchedulerJobRuntime.string(facts["lastRunAt"])
                .flatMap(NativeTimestampFormat.parseISO8601FractionalFirst)?.timeIntervalSince1970
            let selectedAt = SchedulerJobRuntime.string(job["lastRunAt"])
                .flatMap(NativeTimestampFormat.parseISO8601FractionalFirst)?.timeIntervalSince1970
            if let consumedAt, selectedAt.map({ consumedAt >= $0 }) ?? true {
                // These fields describe execution, not authoring or retry intent.
                // Missing optional evidence clears an older description of the run.
                for key in ["lastRunAt", "lastRunStatus", "lastRunDetail", "lastRunError",
                            "lastOccurrenceKey", "lastUnknownOccurrenceKey", "lastInvalidOccurrenceClaim",
                            "lastSeen", "completedAt"] {
                    job[key] = facts[key]
                }
                if job["activeOccurrence"] == nil,
                   let due = SchedulerJobRuntime.scheduledEpoch(for: job), due <= consumedAt {
                    if SchedulerJobRuntime.bool(job["oneShot"], default: false) {
                        // A consumed one-shot must not become a fresh effect
                        // just because the selected definition was enabled.
                        guard let key = SchedulerJobRuntime.string(facts["lastOccurrenceKey"])
                            ?? SchedulerJobRuntime.string(facts["lastUnknownOccurrenceKey"]), !key.isEmpty else {
                            throw TriggerSchedulerError.persistenceFailure("Consumed one-shot \(id) has no retained occurrence key; preserve its source and reconcile the occurrence evidence before restore.")
                        }
                        let dueEpoch = try SchedulerJobNormalizer.checkedEpoch(due)
                        let occurrence: [String: JSONValue] = [
                            "key": .string(key), "state": .string("stopped"),
                            "reason": .string(DataRootLife.stoppedReason),
                            "dueEpoch": .int(dueEpoch),
                            "lifeID": .string(DataRootLife.first),
                        ]
                        job["activeOccurrence"] = .object(occurrence)
                    } else if let next = try SchedulerJobRuntime.nextRunEpoch(for: .object(job), afterEpoch: consumedAt) {
                        // Recompute from the selected schedule. Copying current
                        // nextRunAt would import a later edit of that schedule.
                        try stampNextRun(&job, epoch: next)
                    }
                }
            }
            restored[index] = .object(job)
        }
        guard restored != selected else { return [] }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(jobsDataForWrite(restored), to: destinationPath)
        return []
    }
}

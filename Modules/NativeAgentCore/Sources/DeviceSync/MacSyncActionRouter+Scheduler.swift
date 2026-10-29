import Foundation
import NativeAgentShared
import PersistenceCore
import TriggerScheduler
// Blueprint: | `MacSyncActionRouter+Scheduler.swift` | `MacSyncActionRouter`: `schedulerAction` |

extension MacSyncActionRouter {
    func schedulerAction(_ action: String, payload: [String: String]) async throws -> [String: String] {
        if action == "create_scheduler_job", payload["kind"] == "improve" {
            return ["status": "error", "message": "Code improvement jobs are no longer available."]
        }
        let writer = makeSchedulerJobWriter()
        let jobID: String
        if action == "create_scheduler_job" {
            let name = (payload["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 160,
                  let kind = payload["kind"], ["notify", "dream", "rem"].contains(kind),
                  let seconds = Int64(payload["interval_seconds"] ?? ""), seconds >= 60,
                  seconds <= 315_360_000 else {
                return ["status": "error", "message": "Enter a name, a supported job kind, and an interval from 60 to 315360000 seconds."]
            }
            var body: [String: JSONValue] = [
                "name": .string(name), "kind": .string(kind), "interval_seconds": .int(seconds)
            ]
            if kind == "notify" {
                let message = (payload["message"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty, message.count <= 1000 else {
                    return ["status": "error", "message": "Enter a notification message of 1 to 1000 characters."]
                }
                body["message"] = .string(message)
            }
            let result = try await sync.host.schedulerCreateJob(input: body)
            guard case .object(let receipt) = result, let created = receipt["job"] else {
                return ["status": "error", "message": "The Mac did not return a saved scheduler job."]
            }
            // The nightly reflection exists but is paused: nothing was armed, and the phone says why.
            if receipt["operation"] == .string("paused"), case .string(let detail)? = receipt["detail"] {
                return ["status": "error", "message": detail]
            }
            jobID = try ScheduledJob(row: created).id
        } else {
            guard let id = payload["id"], !id.isEmpty else {
                return ["status": "error", "message": "A scheduler job ID is required."]
            }
            let changed = action == "cancel_scheduler_job"
                ? try await writer.cancelJob(jobId: id)
                : try await writer.setJobEnabled(jobId: id, enabled: action == "resume_scheduler_job")
            // The job the change landed on: a unique start of an id resolves to the whole id.
            if case .object(let answer) = changed, case .object(let job)? = answer["job"], case .string(let whole)? = job["id"] {
                jobID = whole
            } else {
                jobID = id
            }
        }
        let recovered = try await MobileSchedules.read(using: writer, jobID: jobID)
        guard recovered.jobs.contains(where: { $0.id == jobID }) else {
            return ["status": "error", "message": "The Mac could not read back the scheduler job."]
        }
        return ["status": "ok", "ok": "true", "id": jobID,
                "scheduler_job": String(decoding: try JSONEncoder().encode(recovered), as: UTF8.self)]
    }
}

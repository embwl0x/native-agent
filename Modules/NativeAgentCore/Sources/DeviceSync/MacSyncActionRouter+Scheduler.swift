import Foundation
import NativeAgentShared
import PersistenceCore
import TriggerScheduler

extension MacSyncActionRouter {
    func schedulerAction(_ action: String, payload: [String: String]) async throws -> [String: String] {
        let writer = makeSchedulerJobWriter()
        let jobID: String
        if action == "create_scheduler_job" {
            let name = (payload["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 160,
                  let kind = payload["kind"], ["notify", "dream", "rem", "improve"].contains(kind),
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
            let created = try await writer.createJob(body: .object(body))
            jobID = try ScheduledJob(row: created).id
        } else {
            guard let id = payload["id"], !id.isEmpty else {
                return ["status": "error", "message": "A scheduler job ID is required."]
            }
            jobID = id
            if action == "cancel_scheduler_job" {
                _ = try await writer.cancelJob(jobId: id)
            } else {
                _ = try await writer.setJobEnabled(jobId: id, enabled: action == "resume_scheduler_job")
            }
        }
        let recovered = try await MobileSchedulerProjection.read(using: writer, jobID: jobID)
        guard recovered.jobs.contains(where: { $0.id == jobID }) else {
            return ["status": "error", "message": "The Mac could not read back the scheduler job."]
        }
        return ["status": "ok", "ok": "true", "id": jobID,
                "scheduler_job": String(decoding: try JSONEncoder().encode(recovered), as: UTF8.self)]
    }
}

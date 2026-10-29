import Foundation
import PersistenceCore
import TriggerScheduler
// Blueprint: | `SchedulerDueJobRunner+DreamCommands.swift` | canonical recurring-dream command selection and job receipts |

extension SchedulerDueJobRunner {
    public func createIntegrationJob(input: [String: JSONValue], writer: SwiftNativeTriggerScheduler, createJob: @Sendable ([String: JSONValue]) async throws -> JSONValue) async throws -> JSONValue {
        // A repeating dream is the nightly reflection, which has one canonical
        // job. Recreating it goes through Add Nightly Reflection's own path
        // (reactivating a cancelled job) instead of adding a second daily dream.
        // A one-time dream is still an ordinary job.
        if input["kind"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "dream",
           !SchedulerJobNormalizer.isOneShot(input) {
            return try await nightlyDreamJob(writer: writer)
        }
        return try await createJob(input)
    }

    private func nightlyDreamJob(writer: SwiftNativeTriggerScheduler) async throws -> JSONValue {
        let prior = try await writer.listJobs()
        let resolved = try await ensureDefaultCycleJobs(now: Date(), reactivateCancelled: true).nightlyDream
        guard case .object(let saved) = resolved, let id = saved["id"]?.stringValue,
              case .object(let after)? = try await writer.listJobs().first(where: {
                  guard case .object(let job) = $0 else { return false }
                  return job["id"] == .string(id)
              }) else {
            throw NSError(domain: "NativeAgentMacIntegrationBridge", code: -500, userInfo: [
                NSLocalizedDescriptionKey: "The nightly reflection job was not saved; nothing was added. app schedule.list shows what the scheduler holds.",
            ])
        }
        let before = prior.first { row in
            guard case .object(let job) = row else { return false }
            return job["id"] == .string(id)
        }
        let operation: String
        var detail: String
        if after["enabled"] == .bool(false) {
            operation = "paused"
            detail = "The nightly reflection job exists and is paused; nothing was added. Resume it with app schedule.resume, job_id \(id)."
        } else if before == nil {
            operation = "added"; detail = "Nightly reflection added."
        } else if before == .object(after) {
            operation = "already_present"; detail = "Nightly reflection is already scheduled; nothing was added."
        } else {
            operation = "reactivated"; detail = "Nightly reflection is scheduled again on its existing job; nothing was duplicated."
        }
        detail += " A repeating dream always uses this one job on its own nightly time. For one extra dream, use a once schedule."
        return .object(["status": .string("completed"), "operation": .string(operation),
                        "detail": .string(detail), "job": .object(after)])
    }
}

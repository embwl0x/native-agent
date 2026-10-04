import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Per-job timeouts
//
// Before this seam a single hung job body (a wedged NativeClient call inside
// execute(job:now:)) kept `running == true` and blocked every later due row for
// the lifetime of the process. Each job now races its body against a deadline;
// on timeout the body is cancelled cooperatively, the job is marked failed with
// an explicit timeout receipt, and the pass STOPS. The runner refuses a new
// pass until the timed-out body has actually exited.
//
// FAIL LOUD, no retry: a timed-out job records status "error" with
// failureKind == "job_timeout" and a stderr line — it is never silently retried
// or swallowed.

extension SchedulerDueJobRunner {
    /// SINGLE SOURCE of every due-job deadline. Default is 300s; the long-running
    /// consolidation / benchmark kinds (which legitimately call multi-minute
    /// LLM + I/O passes) get 1800s. Add a kind here to change its budget — no
    /// deadline lives anywhere else.
    static let defaultJobTimeoutSeconds: Double = 300
    static let longJobTimeoutSeconds: Double = 1800

    static func jobTimeoutSeconds(forKind kind: String) -> Double {
        switch kind {
        case "dream", "rem", "improve", "harness_benchmark":
            return longJobTimeoutSeconds
        default:
            return defaultJobTimeoutSeconds
        }
    }

    /// Run `execute(job:now:)` under the kind's deadline and always return a
    /// JobResult (never throws). A thrown job error maps to the SAME error
    /// receipt the pre-timeout call site produced; a blown deadline maps to a
    /// distinct loud timeout receipt.
    ///
    /// Cancellation of the timed-out body: on deadline the body Task is
    /// `cancel()`ed cooperatively and the caller-facing race resolves promptly.
    /// A body-exit hook separately owns its real lifecycle: until that hook
    /// fires, `inFlightJobBodies` keeps every later scheduler pass quarantined.
    /// This preserves the deadline without allowing a non-cooperative loser to
    /// overlap another scheduled effect.
    func executeWithTimeout(job: DueJob, now: Date) async -> JobResult {
        let seconds = Self.jobTimeoutSeconds(forKind: job.kind)
        inFlightJobBodies += 1
        let outcome = await raceAgainstTimeout(
            seconds: seconds,
            onBodyExit: { [weak self] in
                Task { await self?.scheduledJobBodyDidExit() }
            }
        ) { [self] in
            try await execute(job: job, now: now)
        }
        switch outcome {
        case .value(let result):
            return result
        case .failure(let message):
            var output: [String: JSONValue] = ["error": .string(message)]
            if job.kind == "dream", Self.dreamErrorsAreRetryable([message]) {
                output["retryAfterSeconds"] = .int(15 * 60)
            }
            return JobResult(
                status: "error",
                detail: message,
                output: .object(output)
            )
        case .timedOut:
            let detail = "job kind '\(job.kind)' exceeded \(Int(seconds))s timeout; "
                + "cancellation requested; later jobs wait for this job to exit"
            FileHandle.standardError.write(Data(
                "[SchedulerDueJobRunner] TIMEOUT \(job.id) (\(job.kind)): \(detail)\n".utf8
            ))
            return JobResult(
                status: "error",
                detail: detail,
                output: .object([
                    "error": .string(detail),
                    "failureKind": .string("job_timeout"),
                    "timeoutSeconds": .int(Int64(seconds)),
                ])
            )
        case .cancelled:
            let detail = "job kind '\(job.kind)' cancelled; "
                + "later jobs wait for this job to exit"
            FileHandle.standardError.write(Data(
                "[SchedulerDueJobRunner] CANCELLED \(job.id) (\(job.kind)): \(detail)\n".utf8
            ))
            return JobResult(
                status: "error",
                detail: detail,
                output: .object([
                    "error": .string(detail),
                    "failureKind": .string("job_cancelled"),
                ])
            )
        }
    }

    private func scheduledJobBodyDidExit() {
        inFlightJobBodies = max(0, inFlightJobBodies - 1)
        guard inFlightJobBodies == 0 else { return }
        let waiters = jobBodyExitWaiters
        jobBodyExitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

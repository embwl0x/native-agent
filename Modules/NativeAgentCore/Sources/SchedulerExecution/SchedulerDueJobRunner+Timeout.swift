import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SchedulerDueJobRunner+Timeout.swift` | `SchedulerDueJobRunner`, `jobTimeoutSeconds`, `executeWithTimeout` |

// MARK: - Per-job timeouts
// A deadline requests cancellation; settlement joins the body before recording returned output and channels. The enclosing loop bounds its own wait; a
// timed-out job stays an explicit job_timeout error and never reruns automatically.

extension SchedulerDueJobRunner {
    /// Per-job budget: 300s, or 1800s for long-running kinds. The enclosing trigger-loop tick independently has a 1800s ceiling.
    static let defaultJobTimeoutSeconds: Double = 300
    static let longJobTimeoutSeconds: Double = 1800

    static func jobTimeoutSeconds(forKind kind: String) -> Double {
        switch kind {
        case "dream", "rem", "harness_benchmark":
            return longJobTimeoutSeconds
        default:
            return defaultJobTimeoutSeconds
        }
    }

    /// Keep job failure distinct from expiry. After requesting cancellation, join the body and retain its output and receipts; exclusion lasts through
    /// settlement even if the manager stops waiting.
    func executeWithTimeout(job: DueJob) async -> JobResult {
        let seconds = Self.jobTimeoutSeconds(forKind: job.kind)
        // The race selects the terminal reason; this task owns the actual body and keeps a result returned after cancellation wins that race.
        let body = Task { [self] in
            try await execute(job: job)
        }
        let outcome = await raceAgainstTimeout(seconds: seconds) {
            try await withTaskCancellationHandler {
                try await body.value
            } onCancel: {
                body.cancel()
            }
        }
        let bodyResult = await settle { await body.result }
        switch outcome {
        case .value(let result):
            return result
        case .failure(let message):
            let output: [String: JSONValue] = ["error": .string(message)]
            return JobResult(
                status: "error",
                detail: message,
                output: .object(output)
            )
        case .timedOut:
            let result = stoppedResult(
                job: job, bodyResult: bodyResult,
                detail: "job_timeout: Scheduled Desk task '\(job.kind)' exceeded \(Int(seconds))s; cancellation requested.",
                fields: [
                    "failureKind": .string("job_timeout"),
                    "timeoutSeconds": .int(Int64(seconds)),
                ]
            )
            FileHandle.standardError.write(Data(
                "[SchedulerDueJobRunner] TIMEOUT \(job.id) (\(job.kind)): \(result.detail)\n".utf8
            ))
            return result
        case .cancelled:
            let result = stoppedResult(
                job: job, bodyResult: bodyResult,
                detail: "job_cancelled: Cancellation requested for scheduled Desk task '\(job.kind)'.",
                fields: ["failureKind": .string("job_cancelled")]
            )
            FileHandle.standardError.write(Data(
                "[SchedulerDueJobRunner] CANCELLED \(job.id) (\(job.kind)): \(result.detail)\n".utf8
            ))
            return result
        }
    }

    private func stoppedResult(
        job: DueJob, bodyResult: Result<JobResult, Error>, detail: String,
        fields: [String: JSONValue]
    ) -> JobResult {
        var output = fields
        let finalDetail: String
        let seen: [String]?
        switch bodyResult {
        case .success(let result):
            finalDetail = detail + " Body returned \(result.status): \(result.detail). Its output is retained; inspect it before resuming."
            output["bodyResult"] = .object([
                "status": .string(result.status),
                "detail": .string(result.detail),
                "output": result.output,
            ])
            seen = result.seen
        case .failure(let error):
            finalDetail = detail + " Body exited with error: \(error.localizedDescription). Effects remain unknown. Inspect its receipts before resuming."
            output["bodyError"] = .string(error.localizedDescription)
            output["effects"] = .string("unknown")
            seen = nil
        }
        output["error"] = .string(finalDetail)
        return JobResult(status: "error", detail: finalDetail, output: .object(output), seen: seen)
    }

}

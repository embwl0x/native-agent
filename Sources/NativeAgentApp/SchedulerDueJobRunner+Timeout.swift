import Foundation
import NativeAgentCore

// MARK: - Per-job timeouts
//
// Before this seam a single hung job body (a wedged NativeClient call inside
// execute(job:now:)) kept `running == true` and blocked every later due row for
// the lifetime of the process. Each job now races its body against a deadline;
// on timeout the body is cancelled cooperatively, the job is marked failed with
// an explicit timeout receipt, and the runner CONTINUES to the next due job.
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
    /// `cancel()`ed (cooperative) and ABANDONED — `raceAgainstTimeout` resolves
    /// on the FIRST of {body, deadline} via an unstructured task + latch and does
    /// NOT structurally await the loser, so the runner proceeds immediately even
    /// if the abandoned body ignores cancellation. Every current job kind routes
    /// through NativeClient's URLSession async calls, which DO honor cancellation,
    /// so an abandoned body typically unwinds promptly; a body stuck in genuinely
    /// non-cooperative work (a tight CPU loop / blocking syscall that never checks
    /// Task.isCancelled) may linger in the background but can no longer block the
    /// runner or hold `running` true.
    func executeWithTimeout(job: DueJob, now: Date) async -> JobResult {
        let seconds = Self.jobTimeoutSeconds(forKind: job.kind)
        let outcome = await raceAgainstTimeout(seconds: seconds) { [self] in
            try await execute(job: job, now: now)
        }
        switch outcome {
        case .value(let result):
            return result
        case .failure(let message):
            // Preserve the exact thrown-error mapping the direct call site used.
            return JobResult(
                status: "error",
                detail: message,
                output: .object(["error": .string(message)])
            )
        case .timedOut:
            let detail = "job kind '\(job.kind)' exceeded \(Int(seconds))s timeout; "
                + "body cancelled, runner continued"
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
            let detail = "job kind '\(job.kind)' cancelled (scheduler stopping); "
                + "body abandoned, runner returning"
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
}

/// Outcome of racing an async operation against a wall-clock deadline.
enum TimeoutRaceOutcome<T: Sendable>: Sendable {
    case value(T)
    /// The operation threw; carries `error.localizedDescription` (Sendable).
    case failure(String)
    case timedOut
    /// The PARENT task (the runDueJobs call) was cancelled while this job's body
    /// was still in flight — e.g. the scheduler loop was stopped. Both the body
    /// and deadline tasks are cancelled and abandoned; the caller surfaces a loud
    /// cancelled receipt and returns promptly instead of blocking on the loser.
    case cancelled
}

/// First-wins latch coordinating the body task and the deadline task. Whichever
/// resolves first is delivered to the single waiter; later resolves are ignored.
private actor TimeoutRaceLatch<T: Sendable> {
    private var resolved: TimeoutRaceOutcome<T>?
    private var waiter: CheckedContinuation<TimeoutRaceOutcome<T>, Never>?

    func resolve(_ outcome: TimeoutRaceOutcome<T>) {
        guard resolved == nil else { return }
        resolved = outcome
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: outcome)
        }
    }

    func wait() async -> TimeoutRaceOutcome<T> {
        if let resolved { return resolved }
        return await withCheckedContinuation { continuation in
            if let resolved {
                continuation.resume(returning: resolved)
            } else {
                waiter = continuation
            }
        }
    }
}

/// Race `operation` against `seconds`. Resolves on the FIRST of {operation
/// completes, deadline elapses} WITHOUT structurally awaiting the loser: on
/// timeout the operation's Task is cancelled and abandoned, so a non-cooperative
/// body lingers in the background but never blocks the caller. Exposed at file
/// scope (not actor-isolated) so it is directly unit-testable with a scripted
/// closure.
func raceAgainstTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async -> TimeoutRaceOutcome<T> {
    let latch = TimeoutRaceLatch<T>()
    let bodyTask = Task {
        do {
            let value = try await operation()
            await latch.resolve(.value(value))
        } catch is CancellationError {
            // The CANCELLER (deadline or parent-cancel handler) owns the outcome
            // label — a cancellation throw must never race its own `.failure` in.
            // Cancellers always resolve, so going silent here can't strand the latch.
        } catch {
            await latch.resolve(.failure(error.localizedDescription))
        }
    }
    let deadlineNanos = UInt64(max(0, seconds * 1_000_000_000).rounded())
    let timerTask = Task {
        do { try await Task.sleep(nanoseconds: deadlineNanos) } catch { return }
        // Cancel the body BEFORE resolving: Task.cancel() sets isCancelled
        // synchronously, so by the time the runner observes `.timedOut` every
        // cooperative guard in the abandoned body already sees cancellation —
        // there is no window where it can commit an artifact after the runner
        // moved on (review finding 2026-07-01).
        bodyTask.cancel()
        await latch.resolve(.timedOut)
    }

    // Propagate PARENT cancellation into the race: if the enclosing task (the
    // runDueJobs loop) is cancelled while we're suspended on the latch, the
    // handler cancels the body + deadline tasks FIRST (synchronous flag set —
    // closes the same commit window), then resolves `.cancelled`. The timer's
    // do/catch bails on cancellation, and the body's CancellationError is
    // silent, so neither can race a mislabeled outcome in. DOCUMENTED BIAS:
    // a body that completes in the same instant as a parent cancel may still
    // be labeled cancelled even though its work committed — acceptable for
    // scheduler-stopping semantics; the receipt errs loud, never silent.
    let outcome = await withTaskCancellationHandler {
        await latch.wait()
    } onCancel: {
        bodyTask.cancel()
        timerTask.cancel()
        Task { await latch.resolve(.cancelled) }
    }
    timerTask.cancel()
    return outcome
}

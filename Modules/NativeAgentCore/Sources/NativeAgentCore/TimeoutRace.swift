import Foundation
import NativeAgentShared

// Blueprint: | `TimeoutRace.swift` | `raceAgainstTimeout` through `ContinuationOnce`: first-wins operation/deadline coordination with explicit parent-cancellation outcome |

/// Outcome of racing an async operation against a wall-clock deadline.
public enum TimeoutRaceOutcome<T: Sendable>: Sendable {
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

/// Race `operation` against `seconds`. Resolves on the FIRST of {operation
/// completes, deadline elapses} WITHOUT structurally awaiting the loser: on
/// timeout the operation's Task is cancelled and abandoned, so a non-cooperative
/// body lingers in the background but never blocks the caller.
/// Timeout bounds only the response: execution exclusion/resources belong to
/// the body's actual exit (`onBodyExit`), never to the returned timeout receipt.
public func raceAgainstTimeout<T: Sendable>(
    seconds: Double,
    onBodyExit: @escaping @Sendable () -> Void = {},
    _ operation: @escaping @Sendable () async throws -> T
) async -> TimeoutRaceOutcome<T> {
    await raceAgainstTimeout(nanoseconds: UInt64(max(0, seconds * 1_000_000_000).rounded()),
                             onBodyExit: onBodyExit, operation)
}

/// The same hard race for callers that already own duration conversion.
public func raceAgainstTimeout<T: Sendable>(
    nanoseconds: UInt64,
    onBodyExit: @escaping @Sendable () -> Void = {},
    _ operation: @escaping @Sendable () async throws -> T
) async -> TimeoutRaceOutcome<T> {
    let latch = ContinuationOnce<TimeoutRaceOutcome<T>>()
    let bodyTask = Task {
        defer { onBodyExit() }
        do {
            let value = try await operation()
            latch.resume(.value(value))
        } catch is CancellationError {
            // The canceller (deadline or parent) owns `.cancelled`. A body that
            // threw CancellationError on its own is a failure of that job, not
            // a stop of the pass, and it must settle rather than wait for the
            // deadline.
            if !Task.isCancelled { latch.resume(.failure("job cancelled itself")) }
        } catch {
            latch.resume(.failure(error.localizedDescription))
        }
    }
    let timerTask = Task {
        do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
        // Claim the receipt before cancellation can trigger a body completion,
        // but set the body's cancellation flag before waking the caller.
        latch.resume(.timedOut) { bodyTask.cancel() }
    }

    // Propagate PARENT cancellation into the race: if the enclosing task (the
    // runDueJobs loop) is cancelled while we're suspended on the latch, the
    // handler claims cancellation, then cancels both tasks before waking the
    // caller. An independently completed body still retains its first-wins receipt.
    let outcome = await withTaskCancellationHandler {
        await latch.wait()
    } onCancel: {
        latch.resume(.cancelled) {
            bodyTask.cancel()
            timerTask.cancel()
        }
    }
    timerTask.cancel()
    return outcome
}

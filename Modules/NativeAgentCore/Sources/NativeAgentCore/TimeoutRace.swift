import Foundation

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
public func raceAgainstTimeout<T: Sendable>(
    seconds: Double,
    onBodyExit: @escaping @Sendable () -> Void = {},
    _ operation: @escaping @Sendable () async throws -> T
) async -> TimeoutRaceOutcome<T> {
    let latch = TimeoutRaceLatch<T>()
    let bodyTask = Task {
        defer { onBodyExit() }
        do {
            let value = try await operation()
            await latch.resolve(.value(value))
        } catch is CancellationError {
            // The canceller (deadline or parent) owns `.cancelled`. A body that
            // threw CancellationError on its own is a failure of that job, not
            // a stop of the pass, and it must settle rather than wait for the
            // deadline.
            if !Task.isCancelled { await latch.resolve(.failure("job cancelled itself")) }
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

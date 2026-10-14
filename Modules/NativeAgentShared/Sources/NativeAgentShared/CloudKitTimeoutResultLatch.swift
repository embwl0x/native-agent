import Foundation

enum CloudKitTimeoutOutcome<T: Sendable>: Sendable {
    case success(T)
    case failure(Error)
    case timedOut
    case cancelled
}

/// Per-operation result cell for a single timeout-race waiter.
public actor CloudKitTimeoutResultLatch<T: Sendable> {
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<Result<T, Error>?, Never>?
    // 2026-09-07: latched, because the timeout side can call cancelWaiter()
    // before the waiter child has registered; without the latch that waiter
    // then parks forever and the bounded wrapper waits on the hung work.
    private var cancelled = false

    public init() {}

    // Callers own task creation: diagnostics detach, transport inherits recovery budgets.
    nonisolated func race(
        workTask: Task<Void, Never>,
        timeoutNanoseconds: UInt64,
        timeoutOnCancellation: Bool = false
    ) async -> CloudKitTimeoutOutcome<T> {
        await withTaskGroup(of: CloudKitTimeoutOutcome<T>.self) { group in
            group.addTask {
                guard let result = await self.wait() else { return .cancelled }
                switch result {
                case .success(let value): return .success(value)
                case .failure(let error): return .failure(error)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return .timedOut
                } catch { return timeoutOnCancellation ? .timedOut : .cancelled }
            }

            let first = await group.next()
            group.cancelAll()
            workTask.cancel()
            await self.cancelWaiter()
            return first ?? .cancelled
        }
    }

    public func wait() async -> Result<T, Error>? {
        if let result {
            return result
        }
        if cancelled {
            return nil
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    public func finish(_ result: Result<T, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    public func cancelWaiter() {
        cancelled = true
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

import Foundation
// Blueprint: | `ContinuationOnce.swift` | `ContinuationOnce`: one retained first outcome for single-consumer waits; winning resolution runs cancellation before any continuation resumes; CloudKit races preserve typed failures and caller-owned task policies |

/// First outcome wins, including resolution before continuation installation.
public final class ContinuationOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private enum State {
        case waiting(CheckedContinuation<T, Never>?)
        case resolving(T, CheckedContinuation<T, Never>?)
        case resolved(T)
    }
    private var state: State = .waiting(nil)
    public init() {}

    /// Whether no outcome has been admitted yet; callers can retire unissued work.
    public var isPending: Bool {
        lock.withLock { if case .waiting = state { return true }; return false }
    }

    /// Returns whether installation admitted starting the work.
    @discardableResult
    public func install(_ continuation: CheckedContinuation<T, Never>) -> Bool {
        lock.lock()
        switch state {
        case .resolved(let value):
            lock.unlock()
            continuation.resume(returning: value)
            return false
        case .resolving(let value, _):
            state = .resolving(value, continuation)
            lock.unlock()
            return false
        case .waiting:
            state = .waiting(continuation)
            lock.unlock()
            return true
        }
    }

    /// Returns whether this resolution won. Cancellation runs outside the lock,
    /// while installation still waits for it to finish before resuming.
    @discardableResult
    public func resume(_ value: T, beforeResume: @Sendable () -> Void = {}) -> Bool {
        lock.lock()
        guard case .waiting(let continuation) = state else { lock.unlock(); return false }
        state = .resolving(value, continuation)
        lock.unlock()
        beforeResume()
        lock.lock()
        guard case .resolving(_, let waiter) = state else { preconditionFailure("Invalid continuation state") }
        state = .resolved(value)
        lock.unlock()
        waiter?.resume(returning: value)
        return true
    }

    public func wait() async -> T {
        await withCheckedContinuation { _ = install($0) }
    }
}

enum CloudKitTimeoutOutcome<T: Sendable>: Sendable {
    case success(T)
    case failure(Error)
    case timedOut
    case cancelled
}

extension ContinuationOnce {
    // Diagnostics detach; transport inherits its recovery budget.
    func cloudKitRace<Value: Sendable>(
        workTask: Task<Void, Never>,
        timeoutNanoseconds: UInt64,
        timeoutOnCancellation: Bool = false
    ) async -> CloudKitTimeoutOutcome<Value> where T == Result<Value, Error>? {
        await withTaskGroup(of: CloudKitTimeoutOutcome<Value>.self) { group in
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
            self.resume(nil)
            return first ?? .cancelled
        }
    }
}

import Foundation
// Blueprint: | `ContinuationOnce.swift` | `ContinuationOnce`: first outcome wins; typed Stop/deadline waits preserve writes |

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

    /// Returns whether this resolution won. Cancellation runs outside the lock, while installation still waits for it to finish before resuming.
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

    /// A generic result has no invented cancellation value. The owner supplies its existing typed cancellation path; both Stop and expiry use it.
    public func wait(
        budget: OperationWaitBudget = .init(),
        cancellingWith value: @autoclosure @escaping @Sendable () -> T,
        onCancel: @escaping @Sendable () -> Void = {}
    ) async -> T {
        let cancel: @Sendable () -> Void = { self.resume(value(), beforeResume: onCancel) }
        let deadline = budget.arm(cancel)
        defer { deadline?.cancel() }
        return await withTaskCancellationHandler {
            await wait()
        } onCancel: { cancel() }
    }
}

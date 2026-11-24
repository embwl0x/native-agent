import Foundation
import Synchronization
// Blueprint: | `ContinuationOnce.swift` | `ContinuationOnce`: first outcome wins; typed Stop/deadline waits preserve writes |

/// First outcome wins, including resolution before continuation installation.
public final class ContinuationOnce<T: Sendable>: Sendable {
    private enum State {
        case waiting(CheckedContinuation<T, Never>?)
        case resolving(T, CheckedContinuation<T, Never>?)
        case resolved(T)
    }
    private let state = Mutex<State>(.waiting(nil))
    public init() {}

    /// Whether no outcome has been admitted yet; callers can retire unissued work.
    public var isPending: Bool {
        state.withLock {
            if case .waiting = $0 { return true }
            return false
        }
    }

    @discardableResult
    public func install(_ continuation: CheckedContinuation<T, Never>) -> Bool {
        let prior = state.withLock { state in
            let prior = state
            switch prior {
            case .waiting: state = .waiting(continuation)
            case .resolving(let value, _): state = .resolving(value, continuation)
            case .resolved: break
            }
            return prior
        }
        if case .resolved(let value) = prior { continuation.resume(returning: value) }
        if case .waiting = prior { return true }
        return false
    }

    /// Returns whether this resolution won. Cancellation runs outside the lock, while installation still waits for it to finish before resuming.
    @discardableResult
    public func resume(_ value: T, beforeResume: @Sendable () -> Void = {}) -> Bool {
        let won = state.withLock { state in
            guard case .waiting(let continuation) = state else { return false }
            state = .resolving(value, continuation)
            return true
        }
        guard won else { return false }
        beforeResume()
        let waiter = state.withLock { state in
            guard case .resolving(_, let waiter) = state else { preconditionFailure("Invalid continuation state") }
            state = .resolved(value)
            return waiter
        }
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

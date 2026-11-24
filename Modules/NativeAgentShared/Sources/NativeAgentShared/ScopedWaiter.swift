import Foundation
import Synchronization

// Blueprint: | `ScopedWaiter.swift` | `ScopedWaiter`: one-shot parking; cancellation and deadlines release only their parker |

/// One parked `withCheckedContinuation` that resumes EXACTLY once. This is the one way a task parks; continuation bodies never touch isolated state. The
/// registration race is closed by construction: `resume()` before `park()` makes the park return immediately, so a caller may register the waiter in its
/// list BEFORE parking without leaking a never-resumed continuation. A cancelled task resumes through the same one-shot path, so a wedged producer can
/// never strand the waiter (or the Task awaiting it) forever.
public final class ScopedWaiter: Sendable {
    private struct State {
        var parked: [(id: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
        var resolved = false
        var nextParkID: UInt64 = 0
        var cancelledParks: Set<UInt64> = []
    }
    private let state = Mutex(State())

    public init() {}

    @discardableResult
    public func resume() -> Bool {
        let waiting = state.withLock { state -> [(id: UInt64, continuation: CheckedContinuation<Void, Never>)]? in
            guard !state.resolved else { return nil }
            state.resolved = true
            defer {
                state.parked.removeAll()
                state.cancelledParks.removeAll()
            }
            return state.parked
        }
        guard let waiting else { return false }
        waiting.forEach { $0.continuation.resume() }
        return true
    }

    /// Parks until someone calls `resume()`, or until THIS parker's task is cancelled or its explicit operation deadline passes. Returns immediately if
    /// the waiter already resolved. Waking is not producer evidence. Cancellation unparks only the cancelled waiter: the waiter itself stays unresolved, so
    /// a sibling parker and the producer are untouched.
    public func park(budget: OperationWaitBudget = .init()) async {
        let id = state.withLock { state in
            defer { state.nextParkID &+= 1 }
            return state.nextParkID
        }
        let deadline = budget.arm { self.unpark(id) }
        defer { deadline?.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked = state.withLock { state in
                    guard !state.resolved, state.cancelledParks.remove(id) == nil else { return false }
                    state.parked.append((id, continuation))
                    return true
                }
                if !parked { continuation.resume() }
            }
        } onCancel: {
            unpark(id)
        }
    }

    /// Resumes exactly one parker by identity, or records the cancellation when it beat registration.
    private func unpark(_ id: UInt64) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let index = state.parked.firstIndex(where: { $0.id == id }) else {
                if !state.resolved { state.cancelledParks.insert(id) }
                return nil
            }
            return state.parked.remove(at: index).continuation
        }
        continuation?.resume()
    }
}

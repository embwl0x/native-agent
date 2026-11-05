import Foundation

// Blueprint: | `ScopedWaiter.swift` | `ScopedWaiter`: one-shot parking; cancellation and deadlines release only their parker |

/// One parked `withCheckedContinuation` that resumes EXACTLY once. This is the one way a task parks; continuation bodies never touch isolated state. The
/// registration race is closed by construction: `resume()` before `park()` makes the park return immediately, so a caller may register the waiter in its
/// list BEFORE parking without leaking a never-resumed continuation. A cancelled task resumes through the same one-shot path, so a wedged producer can
/// never strand the waiter (or the Task awaiting it) forever.
public final class ScopedWaiter: @unchecked Sendable {
    private let lock = NSLock()
    /// A list, not a single slot: a second `park()` on the same waiter would otherwise overwrite the first parker's continuation and strand it — the very
    /// leak this type exists to prevent.
    private var parked: [(id: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
    private var resolved = false
    /// Identity per park, so a cancelled parker unparks ITSELF without resolving the shared waiter for everyone else.
    private var nextParkID: UInt64 = 0
    /// Parks cancelled before their continuation was registered. Consumed by the registering body, which then never parks.
    private var cancelledParks: Set<UInt64> = []

    public init() {}

    @discardableResult
    public func resume() -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let waiting = parked
        parked.removeAll()
        cancelledParks.removeAll()
        lock.unlock()
        waiting.forEach { $0.continuation.resume() }
        return true
    }

    /// Parks until someone calls `resume()`, or until THIS parker's task is cancelled or its explicit operation deadline passes. Returns immediately if
    /// the waiter already resolved. Waking is not producer evidence. Cancellation unparks only the cancelled waiter: the waiter itself stays unresolved, so
    /// a sibling parker and the producer are untouched.
    public func park(budget: OperationWaitBudget = .init()) async {
        let id = allocateParkID()
        let deadline = budget.arm { self.unpark(id) }
        defer { deadline?.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if resolved || cancelledParks.contains(id) {
                    cancelledParks.remove(id)
                    lock.unlock()
                    continuation.resume()
                    return
                }
                parked.append((id, continuation))
                lock.unlock()
            }
        } onCancel: {
            unpark(id)
        }
    }

    /// Synchronous so the lock is never held across a suspension point.
    private func allocateParkID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextParkID
        nextParkID &+= 1
        return id
    }

    /// Resumes exactly one parker by identity, or records the cancellation when it beat registration.
    private func unpark(_ id: UInt64) {
        lock.lock()
        guard let index = parked.firstIndex(where: { $0.id == id }) else {
            if !resolved { cancelledParks.insert(id) }
            lock.unlock()
            return
        }
        let continuation = parked.remove(at: index).continuation
        lock.unlock()
        continuation.resume()
    }
}

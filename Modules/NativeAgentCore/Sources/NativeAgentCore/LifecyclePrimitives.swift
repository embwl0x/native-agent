import Foundation
import os

// Lifecycle primitives — Track C of docs/build_plans/lifecycle-prevention-design.md.
//
// 99 of 272 logged NativeAgent bugs (36%) are ONE shape: something was
// acquired, registered, or parked, and the release path missed an exit — a
// throw, a cancel, a guard-return, or a `defer` scoped to an inner closure.
// Reviews catch those one at a time, forever. These types make the release
// un-skippable BY CONSTRUCTION instead:
//
//   * `ScopedSlot`        — a handle whose `deinit` is the ONLY release path.
//   * `ScopedSlotCounter` — bounded counter; the count is private to the type,
//                           so nothing can increment without taking a handle.
//   * `ScopedSlotSet`     — the same for membership registries.
//   * `ScopedWaiter`      — a parked continuation that resumes EXACTLY once,
//                           race-free against a resume that beats the park.
//   * `OnceByKey`         — run-at-most-once-per-key that does not retain the
//                           in-flight Task (or its captures) after completion.
//   * `BoundedWait`       — every await gets a deadline; expiry throws a TYPED,
//                           LOGGED timeout naming the reason. Never a silent
//                           hang, never a bare `catch {}` that erases the class.

/// Shared log target for invariant violations these primitives recover from
/// rather than crash on. A recovery that is not logged is a silent bug.
enum LifecycleLog {
    static let logger = Logger(subsystem: "com.nativeagent.core", category: "lifecycle-primitives")
}

// MARK: - ScopedSlot

/// An RAII-style handle for one acquired slot / registration.
///
/// The release closure runs exactly once, from `deinit`, no matter which path
/// leaves the scope holding it — normal return, `throw`, `guard` exit, or task
/// cancellation. There is deliberately NO public `release()`: a second release
/// path is exactly the drift this type exists to prevent.
///
/// Escaping use is explicit and safe: capture the handle in the escaping block
/// (`{ [slot] in ... }`) and that block now OWNS the release — the slot stays
/// held until the block's context is torn down.
public final class ScopedSlot: @unchecked Sendable {
    private let releaseAction: @Sendable () -> Void

    /// A standalone handle whose only duty is to run `release` when it dies.
    /// Prefer `ScopedSlotCounter`/`ScopedSlotSet`, which also own the state
    /// being guarded; this initializer is for adapting an existing pair.
    public init(release: @escaping @Sendable () -> Void) {
        self.releaseAction = release
    }

    deinit { releaseAction() }
}

// MARK: - ScopedSlotCounter

/// A bounded concurrency counter whose count is PRIVATE to the type: the only
/// way to increment is to receive a `ScopedSlot`, and the only way to decrement
/// is to let that handle die.
public final class ScopedSlotCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    public let limit: Int
    public let name: String

    public init(name: String, limit: Int) {
        self.name = name
        self.limit = max(0, limit)
    }

    /// Slots currently held. Read-only by design — diagnostics, never control.
    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Returns a handle, or nil when the limit is already reached. The caller
    /// must keep the handle alive for exactly as long as the work runs.
    public func acquire() -> ScopedSlot? {
        lock.lock()
        guard active < limit else {
            lock.unlock()
            return nil
        }
        active += 1
        lock.unlock()
        return ScopedSlot { [weak self] in self?.releaseOne() }
    }

    private func releaseOne() {
        lock.lock()
        guard active > 0 else {
            lock.unlock()
            // Unreachable by construction: the only increment hands out a
            // handle, and the only decrement is that handle's `deinit`. A
            // silent `max(0, active - 1)` would have hidden a real double
            // release; trap in debug, log and no-op in release.
            assertionFailure("ScopedSlotCounter(\(name)) released with no active slot")
            LifecycleLog.logger.error(
                "scoped slot over-release ignored: \(self.name, privacy: .public)"
            )
            return
        }
        active -= 1
        lock.unlock()
    }
}

// MARK: - ScopedSlotSet

/// A membership registry with the same discipline: `acquire(key)` returns a
/// handle (nil when the key is already registered) and the key is removed when
/// that handle dies. No caller can insert without taking on the removal.
public final class ScopedSlotSet<Key: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var members: Set<Key> = []
    public let name: String

    public init(name: String) { self.name = name }

    public func acquire(_ key: Key) -> ScopedSlot? {
        lock.lock()
        guard !members.contains(key) else {
            lock.unlock()
            return nil
        }
        members.insert(key)
        lock.unlock()
        return ScopedSlot { [weak self] in self?.remove(key) }
    }

    public func contains(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return members.contains(key)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return members.count
    }

    private func remove(_ key: Key) {
        lock.lock()
        members.remove(key)
        lock.unlock()
    }
}

// MARK: - ScopedWaiter

/// One parked `withCheckedContinuation` that resumes EXACTLY once.
///
/// The registration race is closed by construction: `resume()` before `park()`
/// makes the park return immediately, so a caller may register the waiter in
/// its list BEFORE parking without leaking a never-resumed continuation. A
/// cancelled task resumes through the same one-shot path, so a wedged producer
/// can never strand the waiter (or the Task awaiting it) forever.
public final class ScopedWaiter: @unchecked Sendable {
    private let lock = NSLock()
    /// A list, not a single slot: a second `park()` on the same waiter would
    /// otherwise overwrite the first parker's continuation and strand it —
    /// the very leak this type exists to prevent.
    private var parked: [(id: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
    private var resolved = false
    private var cancelledFlag = false
    /// Identity per park, so a cancelled parker unparks ITSELF without
    /// resolving the shared waiter for everyone else.
    private var nextParkID: UInt64 = 0
    /// Parks cancelled before their continuation was registered. Consumed by
    /// the registering body, which then never parks.
    private var cancelledParks: Set<UInt64> = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    public var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    /// Resolves the waiter. Returns true only for the call that won.
    @discardableResult
    public func resume() -> Bool { resolve(cancelled: false) }

    /// Resolves the waiter as cancelled. Returns true only for the winner.
    @discardableResult
    public func cancel() -> Bool { resolve(cancelled: true) }

    /// Parks until someone calls `resume()`/`cancel()`, or until THIS parker's
    /// task is cancelled. Returns immediately if the waiter already resolved.
    ///
    /// fix-park-cancellation (2026-08-02): a bare
    /// `withCheckedContinuation(Void, Never)` ignores cancellation entirely
    /// (empirically confirmed), so a parker whose task was cancelled with no
    /// later `resume`/`cancel` stayed in `parked` forever — the exact leak this
    /// type claims to prevent. The guarantee now lives INSIDE the primitive
    /// instead of in whichever caller remembered to add its own handler.
    ///
    /// Cancellation unparks only the cancelled waiter: the waiter itself stays
    /// unresolved, so a sibling parker and the producer are untouched.
    public func park() async {
        let id = allocateParkID()
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

    /// Resumes exactly one parker by identity, or records the cancellation when
    /// it beat registration.
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

    /// Parks with a deadline. Returns false when the deadline (or a cancel)
    /// resolved the waiter instead of a real `resume()`.
    ///
    /// Preferred over wrapping `park()` in `BoundedWait.run`: this deadline
    /// RESOLVES the waiter, so the parked continuation is actually released,
    /// whereas `BoundedWait.run` would return on time but leave the park
    /// abandoned in the background. Use this whenever the wait is a
    /// `ScopedWaiter`.
    ///
    /// `false` means "no real resume was observed" — a deadline, a `cancel()`,
    /// or this parker's own task being cancelled.
    @discardableResult
    public func park(timeoutSeconds: TimeInterval, reason: String) async -> Bool {
        let deadline = BoundedWait.clampedDeadline(timeoutSeconds, reason: reason)
        let expiry = Task { [weak self] in
            try await Task.sleep(nanoseconds: BoundedWait.nanoseconds(deadline))
            guard let self, self.cancel() else { return }
            BoundedWait.logger.error(
                "bounded wait expired after \(deadline, privacy: .public)s: \(reason, privacy: .public)"
            )
        }
        await park()
        expiry.cancel()
        // A cancelled parker did not observe a real resume, even though the
        // waiter itself is still unresolved.
        return !isCancelled && !Task.isCancelled
    }

    private func resolve(cancelled: Bool) -> Bool {
        lock.lock()
        // Set `cancelledFlag` ONLY when this call actually resolves the waiter.
        // A deadline that fires a hair after a real resume must not relabel a
        // genuine wake-up as a timeout.
        guard !resolved else {
            lock.unlock()
            return false
        }
        if cancelled { cancelledFlag = true }
        resolved = true
        let waiting = parked
        parked.removeAll()
        cancelledParks.removeAll()
        lock.unlock()
        waiting.forEach { $0.continuation.resume() }
        return true
    }
}

// MARK: - OnceByKey

/// Runs an async operation at most once per key per process, with every later
/// caller awaiting the SAME run to completion.
///
/// Unlike a bare `[Key: Task]` memo table, the in-flight `Task` (and everything
/// its closure captured — typically a whole store/executor instance) is dropped
/// once the run finishes; only a completion marker is kept. `reset()` exists so
/// tests do not accumulate one entry per temp root for the process lifetime.
public actor OnceByKey<Key: Hashable & Sendable> {
    private enum State {
        case running(Task<Void, Never>)
        case done
    }

    private var states: [Key: State] = [:]
    public let name: String

    public init(name: String) { self.name = name }

    /// Awaits the single run for `key`, starting it if this is the first call.
    ///
    /// fix-once-marker-ownership (2026-08-02): the `.done` transition used to
    /// happen in the AWAITING caller after `task.value` returned, which made
    /// the table's cleanup depend on caller behaviour — a class of retention
    /// this primitive exists to remove. The run now marks itself done from
    /// inside the spawned task, before that task completes, so the entry (and
    /// the operation's captures) is dropped whether or not anybody is still
    /// waiting on it.
    public func run(_ key: Key, _ operation: @escaping @Sendable () async -> Void) async {
        switch states[key] {
        case .done:
            return
        case .running(let task):
            await task.value
        case nil:
            let task = Task { [weak self] in
                await operation()
                await self?.markDone(key)
            }
            // Safe against a fast operation: `markDone` needs this actor, and
            // this call holds it until the `await` below, so the assignment
            // can never clobber the marker.
            states[key] = .running(task)
            await task.value
        }
    }

    /// Called by the run itself. Only advances a still-`running` entry, so a
    /// `reset()` mid-flight is not resurrected by a late completion.
    private func markDone(_ key: Key) {
        guard case .running = states[key] else { return }
        states[key] = .done
    }

    public func hasCompleted(_ key: Key) -> Bool {
        if case .done = states[key] { return true }
        return false
    }

    public var trackedKeys: Int { states.count }

    /// Test seam — drops completion markers so a temp-root-per-test suite does
    /// not grow the table for the process lifetime.
    public func reset() { states.removeAll() }
}

// MARK: - BoundedWait

/// Thrown when a `BoundedWait` deadline expires. Typed on purpose: a caller
/// that wants to tolerate a timeout must name it, and a `catch` that erases it
/// is visible in review.
public struct BoundedWaitTimeout: Error, LocalizedError, Sendable, Equatable {
    public let reason: String
    public let seconds: TimeInterval

    public init(reason: String, seconds: TimeInterval) {
        self.reason = reason
        self.seconds = seconds
    }

    public var errorDescription: String? {
        "Timed out after \(Int(seconds.rounded()))s waiting for \(reason)."
    }
}

/// Every unbounded await gets a deadline by construction.
///
/// Companion rule (design doc C-2): **no unbounded wait may be held under a
/// file lock.** A hang under a cross-process flock turns one wedged caller into
/// a system-wide wedge — every other process blocks on the same lock. There is
/// deliberately no "wait forever" option here.
public enum BoundedWait {
    public static let logger = Logger(subsystem: "com.nativeagent.core", category: "bounded-wait")

    /// Longest deadline this type will honor. A "deadline" of hours is not a
    /// deadline — under the companion no-unbounded-wait-under-a-file-lock rule
    /// it wedges every other process on the same flock for that long. It also
    /// keeps the `TimeInterval -> UInt64` nanosecond conversion far away from
    /// the overflow that would TRAP the process on a hostile env value.
    public static let maxDeadlineSeconds: TimeInterval = 900

    private enum Outcome<Value: Sendable>: @unchecked Sendable {
        case value(Value)
        case failure(Error)
    }

    /// One-shot race resolver. Whichever of {operation, deadline, caller
    /// cancellation} settles first wins; every later settle is dropped, and the
    /// losing side is never awaited.
    private final class RaceBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome<Value>, Never>?
        private var pending: Outcome<Value>?
        private var settled = false

        func attach(_ continuation: CheckedContinuation<Outcome<Value>, Never>) {
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(returning: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        @discardableResult
        func settle(_ outcome: Outcome<Value>) -> Bool {
            lock.lock()
            guard !settled else {
                lock.unlock()
                return false
            }
            settled = true
            if let waiting = continuation {
                continuation = nil
                lock.unlock()
                waiting.resume(returning: outcome)
            } else {
                pending = outcome
                lock.unlock()
            }
            return true
        }
    }

    /// Runs `operation` with a deadline that holds even when `operation` does
    /// NOT cooperate with cancellation. On expiry a LOGGED `BoundedWaitTimeout`
    /// naming `reason` is thrown and this call returns immediately.
    ///
    /// fix-bounded-wait-hard-deadline (2026-08-02): this used to be a
    /// `withThrowingTaskGroup`. A task group AWAITS its children at scope exit
    /// and `cancelAll()` is only a request, so any operation that ignores
    /// cancellation (a raw `withCheckedContinuation`, a blocking syscall on a
    /// detached queue, a semaphore) hung forever DESPITE the bound — the
    /// overclaim that makes a safety primitive dangerous, because callers reach
    /// for it precisely when they do not trust the wait.
    ///
    /// WHAT LEAKS ON EXPIRY: the operation runs in an unstructured `Task` that
    /// is CANCELLED and then ABANDONED. Cooperative work stops promptly.
    /// Non-cooperative work keeps running to completion in the background,
    /// holding its captures until then, and its result/error is discarded.
    /// That is the deliberate trade: a bounded caller plus a possibly-lingering
    /// background task, instead of an unbounded caller. Do not put work with
    /// externally visible side effects behind this deadline unless a late,
    /// unobserved completion is acceptable.
    ///
    /// Cancellation of the calling task propagates into `operation` unchanged —
    /// a `CancellationError` is never converted into a timeout.
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        reason: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds > 0, seconds.isFinite else {
            throw BoundedWaitTimeout(reason: reason, seconds: max(0, seconds))
        }
        let deadline = clampedDeadline(seconds, reason: reason)
        let box = RaceBox<T>()
        let work = Task {
            do {
                box.settle(.value(try await operation()))
            } catch {
                box.settle(.failure(error))
            }
        }
        let expiry = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds(deadline))
            } catch {
                return  // cancelled: the operation already settled the race
            }
            guard box.settle(.failure(BoundedWaitTimeout(reason: reason, seconds: deadline)))
            else { return }
            logger.error(
                "bounded wait expired after \(deadline, privacy: .public)s: \(reason, privacy: .public)"
            )
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
                box.attach(continuation)
            }
        } onCancel: {
            // Propagate, don't launder: a cooperative operation surfaces its
            // own CancellationError. A non-cooperative one is still bounded by
            // the deadline below rather than by this handler.
            work.cancel()
        }
        expiry.cancel()
        // Abandon the loser — requested to stop, never awaited.
        work.cancel()
        switch outcome {
        case .value(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    /// Clamps a requested deadline into `(0, maxDeadlineSeconds]`, logging the
    /// clamp. Called by every deadline path so nothing can smuggle an
    /// hours-long "bound" past the companion rule.
    static func clampedDeadline(_ seconds: TimeInterval, reason: String) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        guard seconds > maxDeadlineSeconds else { return seconds }
        logger.error(
            """
            bounded wait deadline \(seconds, privacy: .public)s exceeds the \
            \(maxDeadlineSeconds, privacy: .public)s maximum; clamped: \(reason, privacy: .public)
            """
        )
        return maxDeadlineSeconds
    }

    /// Overflow-safe nanosecond conversion. Inputs are already clamped, so this
    /// can never trap the process on a hostile value.
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        let bounded = min(max(0, seconds), maxDeadlineSeconds)
        return UInt64((bounded * 1_000_000_000).rounded())
    }

    /// Bounded variant that reports expiry instead of throwing — for seams
    /// whose caller cannot throw. Still logged; never silent.
    public static func runReportingTimeout<T: Sendable>(
        seconds: TimeInterval,
        reason: String,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        try? await run(seconds: seconds, reason: reason, operation: operation)
    }

    /// Reads a positive TimeInterval override from the environment, falling
    /// back to `fallback`. Keeps deadline constants testable without a global.
    ///
    /// An override above `maxDeadlineSeconds` is REJECTED (falls back) and
    /// logged, not honored: stretching a 300s guard to hours re-creates the
    /// system-wide flock wedge the guard exists to prevent, and honoring it
    /// silently would make the wedge look like normal slowness.
    public static func seconds(fromEnv key: String, fallback: TimeInterval) -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let parsed = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              parsed > 0, parsed.isFinite
        else { return fallback }
        guard parsed <= maxDeadlineSeconds else {
            logger.error(
                """
                \(key, privacy: .public)=\(parsed, privacy: .public)s exceeds the \
                \(maxDeadlineSeconds, privacy: .public)s maximum; rejected, using \
                \(fallback, privacy: .public)s
                """
            )
            return fallback
        }
        return parsed
    }
}

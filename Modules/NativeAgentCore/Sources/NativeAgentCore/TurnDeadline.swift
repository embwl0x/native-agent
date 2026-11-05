import Foundation
import NativeAgentShared
// Blueprint: | `TurnDeadline.swift` | `OperationDeadlines`, `TurnDeadline`, `TurnBodyLifetime`: work ceilings and owned settlement |

/// One operation's enclosing ceilings and person-wait observer, passed down its call stack.
public struct OperationDeadlines: Sendable {
    fileprivate var values: [TurnDeadline] = []
    public var onHumanWait: (@Sendable (Bool) -> Void)?
    public init(onHumanWait: (@Sendable (Bool) -> Void)? = nil) { self.onHumanWait = onHumanWait }

    public func progressed() { for deadline in values { deadline.renew() } }
    public var secondsLeft: TimeInterval? { values.filter { $0.boundsWork }.map { $0.left() }.min() }
    /// Human waits pause active-work clocks, never wall clocks; the same held ceilings resume on exit.
    public nonisolated(nonsending) func withHumanWait<T>(_ work: () async throws -> T) async rethrows -> T {
        let paused = values.map { ($0, $0.pause()) }
        onHumanWait?(true)
        defer { onHumanWait?(false); for (deadline, token) in paused { deadline.resume(token) } }
        return try await work()
    }
}

public final class TurnDeadline: @unchecked Sendable {
    public enum Clock: Sendable, Equatable { case activeWork, wallClock }
    private let lock = NSLock()
    private var remaining: Duration
    private var started: ContinuousClock.Instant?
    private var sleeper: Task<Void, Never>?
    private var expiry: (@Sendable () -> Void)?
    private var waits: Set<UUID> = []

    private let full: Duration
    private let clock: Clock
    /// A response-only ceiling participates in progress/person waits, but cannot become a transport/effect budget read by the work it observes.
    fileprivate let boundsWork: Bool

    private init(seconds: TimeInterval, clock: Clock, boundsWork: Bool) {
        remaining = .seconds(seconds); full = .seconds(seconds); self.clock = clock; self.boundsWork = boundsWork
    }

    fileprivate func left() -> TimeInterval {
        lock.withLock {
            guard expiry != nil else { return 0 }
            var rest = remaining
            if let started { rest -= started.duration(to: .now) }
            let seconds = Double(rest.components.seconds) + Double(rest.components.attoseconds) * 1e-18
            return max(0, seconds)
        }
    }

    fileprivate func renew() {
        guard clock == .activeWork else { return }
        lock.withLock {
            guard expiry != nil else { return }
            remaining = full
            sleeper?.cancel()
            sleeper = nil
            started = nil
            arm()
        }
    }

    fileprivate func pause() -> UUID? {
        guard clock == .activeWork else { return nil }
        return lock.withLock {
            let token = UUID()
            waits.insert(token)
            if let started { remaining -= started.duration(to: .now) }
            started = nil
            sleeper?.cancel()
            sleeper = nil
            return token
        }
    }

    fileprivate func resume(_ token: UUID?) {
        guard let token else { return }
        lock.withLock { waits.remove(token); arm() }
    }

    private func arm() {
        guard waits.isEmpty, let expiry else { return }
        let start = ContinuousClock.now
        started = start
        let remaining = remaining
        sleeper = Task { [weak self] in
            do { try await Task.sleep(for: remaining) } catch { return }
            let won = self?.lock.withLock {
                guard self?.started == start else { return false }
                self?.started = nil
                self?.expiry = nil
                return true
            } == true
            if won { expiry() }
        }
    }

    private func stop() {
        lock.withLock { expiry = nil; started = nil; sleeper?.cancel(); sleeper = nil }
    }

    public struct DeadlineExceeded: Error, LocalizedError, Sendable {
        public var errorDescription: String? { "The operation exceeded its deadline." }
    }

    public struct InvalidDeadline: Error, LocalizedError, Sendable {
        public var errorDescription: String? { "The deadline must be finite, nonnegative and representable in seconds." }
    }

    /// Preserve provider/storage errors separately from deadline expiry and Stop. `cancelWorkOnExpiry:false` ends only the response wait. The original work
    /// must own its terminal receipt; Stop still requests cancellation.
    public static func withThrowingDeadline<T: Sendable>(
        seconds: TimeInterval,
        clock: Clock = .activeWork,
        cancelWorkOnExpiry: Bool = true,
        deadlines: OperationDeadlines,
        _ work: @escaping @Sendable (OperationDeadlines) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) else {
            throw InvalidDeadline()
        }
        let deadline = TurnDeadline(seconds: seconds, clock: clock, boundsWork: cancelWorkOnExpiry)
        var nested = deadlines
        nested.values.append(deadline)
        let held = nested
        let child = Task { () -> Result<T, Error> in
            do { return .success(try await work(held)) }
            catch { return .failure(error) }
        }
        let once = ContinuationOnce<Result<T, Error>>()
        deadline.lock.withLock {
            deadline.expiry = {
                once.resume(.failure(DeadlineExceeded())) {
                    if cancelWorkOnExpiry { child.cancel() }
                }
            }
            deadline.arm()
        }
        defer { deadline.stop() }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>, Never>) in
                once.install(continuation)
                Task {
                    let value = await child.value
                    deadline.stop()
                    once.resume(value)
                }
            }
        } onCancel: {
            // Stop returns even when the provider ignores cancellation.
            once.resume(.failure(CancellationError())) {
                child.cancel()
                deadline.stop()
            }
        }
        return try result.get()
    }

}

/// A response ceiling can return before its body. Admission closes on Stop or finish; the actual body stays owned through settlement.
public final class TurnBodyLifetime<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<T, Error>?
    private var closed = false

    public init() {}

    /// Retained owners can still stop the body after its response wait ended. Closing admission also covers cancellation before the body starts.
    public func cancel() {
        let running = lock.withLock { closed = true; return task }
        running?.cancel()
    }

    public func run(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            let running: Task<T, Error> = try lock.withLock {
                try Task.checkCancellation()
                guard !closed, task == nil else { throw CancellationError() }
                let running = Task { try Task.checkCancellation(); return try await work() }
                task = running
                return running
            }
            return try await running.value
        } onCancel: {
            self.cancel()
        }
    }

    @discardableResult
    public func finish() async -> Result<T, Error>? {
        let running = lock.withLock { closed = true; return task }
        running?.cancel()
        return await settle { await running?.result }
    }
}

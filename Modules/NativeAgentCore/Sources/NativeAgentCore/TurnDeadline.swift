import Foundation
import NativeAgentShared
// Blueprint: | `TurnDeadline.swift` | `OperationDeadlines`, `TurnDeadline`, `CallLife`, `TurnBodyLifetime`: ceilings, call watches, owned settlement |

/// One operation's enclosing ceilings and person-wait observer, passed down its call stack.
public struct OperationDeadlines: Sendable {
    fileprivate var values: [TurnDeadline] = []
    public var onHumanWait: (@Sendable (Bool) -> Void)?
    public init(onHumanWait: (@Sendable (Bool) -> Void)? = nil) { self.onHumanWait = onHumanWait }

    /// Life renews every ceiling held here and every call watch in the same call's tree, so work holding an older copy of this chain
    /// (a body admitted after it was made, a deferred ability) still reaches the calls it runs inside.
    public func progressed() { for deadline in reach { deadline.renew() } }
    /// The innermost call watch this chain holds: the call the holder runs in.
    public var innermostCall: TurnDeadline? { values.last(where: { $0.isCall }) }
    /// Human waits pause active-work clocks, never wall clocks; the same held ceilings resume on exit. A person's wait is not silence.
    public nonisolated(nonsending) func withHumanWait<T>(_ work: () async throws -> T) async rethrows -> T {
        let paused = reach.map { ($0, $0.pause()) }
        onHumanWait?(true)
        defer { onHumanWait?(false); for (deadline, token) in paused { deadline.resume(token) } }
        return try await work()
    }
    private var reach: [TurnDeadline] {
        var seen = Set<ObjectIdentifier>()
        return (values + (innermostCall?.tree() ?? [])).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

private enum EnclosingCallPart: TurnPart { static let unset: TurnDeadline? = nil }

extension Turn {
    /// The watch of the call this turn's work runs inside. A turn derived from it (a helper, a part's thought) carries it, so that turn's
    /// output and completed calls are life of the call that started it, and an owner serving the turn can attach what the call waits on.
    public var enclosingCall: TurnDeadline? {
        get { self[EnclosingCallPart.self] }
        set { self[EnclosingCallPart.self] = newValue }
    }
}

/// What a call waits on, as its owner sees it: a child process, a request, an app under automation. The owner attaches it to the call's watch
/// (`TurnDeadline.watching`) for as long as the wait lasts, reports each sign of life with `moved()`, and answers "is it alive?" when the
/// call has been quiet. The answer, never the time that passed, decides whether the call ends.
public struct CallLife: Sendable {
    /// `waitingOnPerson` keeps the call waiting and shows the turn its words: the wait is the person's, not silence to judge.
    public enum Answer: Sendable { case alive, dead(String), unknown, waitingOnPerson(String) }
    /// What is waited on, in words the agent reads: "the process `swift build`", "Safari".
    public let what: String
    public let alive: @Sendable () async -> Answer
    public init(what: String, alive: @escaping @Sendable () async -> Answer) { self.what = what; self.alive = alive }
}

extension CallLife {
    /// What a call waits on when it waits on a request: alive while its task runs, however quiet, as a running process is; dead once the task
    /// has completed or is being cancelled. Bytes, as they move, are the call's life, reported by whoever receives them.
    public static func request(_ task: URLSessionTask, what: String) -> CallLife {
        CallLife(what: what) {
            switch task.state {
            case .running: .alive
            case .canceling, .completed: .dead("\(what) has ended without an answer")
            case .suspended: .unknown
            @unknown default: .unknown
            }
        }
    }
}

extension URLSession {
    /// `data(for:)` whose task is what `life`, the watch of the call waiting on it, waits on while it runs.
    public func data(for request: URLRequest, life: TurnDeadline?) async throws -> (Data, URLResponse) {
        guard let life else { return try await data(for: request) }
        let owner = RequestLife(watch: life, what: request.url?.host.map { "the request to \($0)" } ?? "the request")
        defer { owner.detach() }
        return try await data(for: request, delegate: owner)
    }
}

/// Attaches a request's task to the waiting call's watch once URLSession creates it, and reports sent bytes as life.
private final class RequestLife: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let watch: TurnDeadline
    private let what: String
    private let lock = NSLock()
    private var attached: UUID?
    private var ended = false

    init(watch: TurnDeadline, what: String) { self.watch = watch; self.what = what }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { if !ended { attached = watch.attach(.request(task, what: what)) } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) { watch.moved() }

    func detach() { lock.withLock { ended = true; if let attached { watch.detach(attached) } } }
}

/// A call's name and where its turn shows that the call is waiting on something nothing can answer for.
public struct CallMark: Sendable {
    public let name: String
    public let notice: (@Sendable (String) async -> Void)?
    public init(name: String, notice: (@Sendable (String) async -> Void)?) { self.name = name; self.notice = notice }
}

/// What a quiet call's watch decided after asking what it waits on.
public enum CallSilence: Sendable { case keepWaiting, end(any Error) }

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
    /// A call's watch, linked to the call watch it runs inside and the ones running inside it: one tree per outermost call.
    fileprivate let mark: CallMark?
    fileprivate var isCall: Bool { mark != nil }
    private let parent: TurnDeadline?
    private var children: [ObjectIdentifier: TurnDeadline] = [:]
    /// A watch's expiry asks; it stays armed until the call ends.
    private var watches = false
    private var lives: [UUID: CallLife] = [:]
    private var lastLife = ContinuousClock.now

    private init(seconds: TimeInterval, clock: Clock, mark: CallMark?, parent: TurnDeadline?) {
        remaining = .seconds(seconds); full = .seconds(seconds); self.clock = clock; self.mark = mark; self.parent = parent
    }

    /// The call's name, for its receipt and its notice.
    public var name: String? { mark?.name }

    /// Every call watch in this one's tree: from its outermost call down through every call running inside it.
    public func tree() -> [TurnDeadline] {
        var root = self
        while let up = root.parent { root = up }
        return root.below()
    }

    private func below() -> [TurnDeadline] {
        var found: [TurnDeadline] = []
        var next = [self]
        while let node = next.popLast() {
            found.append(node)
            next.append(contentsOf: node.lock.withLock { Array(node.children.values) })
        }
        return found
    }

    /// Life anywhere in a call's tree (a turn under it producing output, a call in it completing, an owner's sign of life) is life of the
    /// whole call.
    public func moved() { for deadline in tree() { deadline.renew() } }

    /// A call running inside this one holds this watch until it returns; only the innermost running call listens for silence.
    public nonisolated(nonsending) func holding<T>(_ work: () async throws -> T) async rethrows -> T {
        let token = pause()
        defer { resume(token) }
        return try await work()
    }

    /// Attach what this call waits on while `work` runs; its owner reports life through `moved()`.
    public nonisolated(nonsending) func watching<T>(_ life: CallLife, _ work: () async throws -> T) async rethrows -> T {
        let id = attach(life)
        defer { detach(id) }
        return try await work()
    }

    public func attach(_ life: CallLife) -> UUID {
        let id = UUID()
        lock.withLock { lives[id] = life }
        return id
    }

    public func detach(_ id: UUID) { _ = lock.withLock { lives.removeValue(forKey: id) } }

    /// What this call and every call running inside it wait on.
    public func livesBelow() -> [CallLife] { below().flatMap { node in node.lock.withLock { Array(node.lives.values) } } }

    /// How long since the last sign of life.
    public var quietFor: TimeInterval {
        let quiet = lock.withLock { lastLife.duration(to: .now) }.components
        return Double(quiet.seconds) + Double(quiet.attoseconds) * 1e-18
    }

    /// Show on the turn, through the nearest call that has a place to show it, that this call is waiting on something nothing can answer for.
    public func notice(_ text: String) async {
        var at: TurnDeadline? = self
        while let node = at {
            if let show = node.mark?.notice { await show(text); return }
            at = node.parent
        }
    }

    fileprivate func renew() {
        guard clock == .activeWork else { return }
        lock.withLock {
            lastLife = .now
            guard expiry != nil else { return }
            // A stream renews on every word; a window renewed within the last second is already whole.
            if remaining == full, let started, started.duration(to: .now) < .seconds(1) { return }
            remaining = full
            sleeper?.cancel()
            sleeper = nil
            started = nil
            arm()
        }
    }

    /// A watch that asked and kept waiting listens again for a whole window.
    fileprivate func rewind() {
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
        guard waits.isEmpty, expiry != nil else { return }
        let start = ContinuousClock.now
        started = start
        let remaining = remaining
        sleeper = Task { [weak self] in
            do { try await Task.sleep(for: remaining) } catch { return }
            let fire: (@Sendable () -> Void)? = self?.lock.withLock {
                guard let self, self.started == start else { return nil }
                self.started = nil
                let fire = self.expiry
                if !self.watches { self.expiry = nil }
                return fire
            }
            fire?()
        }
    }

    private func stop() {
        lock.withLock { expiry = nil; started = nil; sleeper?.cancel(); sleeper = nil; lives = [:] }
        parent?.lock.withLock { _ = parent?.children.removeValue(forKey: ObjectIdentifier(self)) }
    }

    public struct DeadlineExceeded: Error, LocalizedError, Sendable {
        public var errorDescription: String? { "The operation exceeded its deadline." }
    }

    public struct InvalidDeadline: Error, LocalizedError, Sendable {
        public var errorDescription: String? { "The deadline must be finite, nonnegative and representable in seconds." }
    }

    /// Preserve provider/storage errors separately from deadline expiry and Stop. Expiry cancels the work as Stop does and returns at once;
    /// the work owns its terminal receipt. A call's watch (`call`) joins the tree of the call watch it runs inside (`parent`); given
    /// `onSilence`, its expiry does not end the work but asks, and only an `.end` answer ends it.
    public static func withThrowingDeadline<T: Sendable>(
        seconds: TimeInterval,
        clock: Clock = .activeWork,
        deadlines: OperationDeadlines,
        call: CallMark? = nil,
        parent: TurnDeadline? = nil,
        onSilence: (@Sendable (TurnDeadline) async -> CallSilence)? = nil,
        _ work: @escaping @Sendable (OperationDeadlines) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) else {
            throw InvalidDeadline()
        }
        let deadline = TurnDeadline(seconds: seconds, clock: clock, mark: call, parent: call != nil ? parent : nil)
        deadline.parent?.lock.withLock { deadline.parent?.children[ObjectIdentifier(deadline)] = deadline }
        var nested = deadlines
        nested.values.append(deadline)
        let held = nested
        let child = Task { () -> Result<T, Error> in
            do { return .success(try await work(held)) }
            catch { return .failure(error) }
        }
        let once = ContinuationOnce<Result<T, Error>>()
        deadline.lock.withLock {
            deadline.watches = onSilence != nil
            deadline.expiry = {
                guard let onSilence else {
                    once.resume(.failure(DeadlineExceeded())) { child.cancel() }
                    return
                }
                Task {
                    switch await onSilence(deadline) {
                    case .keepWaiting: deadline.rewind()
                    case .end(let error): once.resume(.failure(error)) { child.cancel() }
                    }
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

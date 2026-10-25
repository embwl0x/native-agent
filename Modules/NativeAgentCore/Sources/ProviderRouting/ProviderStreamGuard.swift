import Foundation
import Network
import NativeAgentCore
// Blueprint: | `ProviderStreamGuard.swift` | Configured idle/wall cuts on wire activity for every provider stream; the request registers its progress wake before reading and waits only for progress or its next deadline; terminal state closes activity admission before canceling forwarding/deadline tasks, retaining their handles through actual exit without joining the producer; typed no-reply failure and uncapped model URLSession; the learned first-output deadline bounds only a wire with nothing on it; `ProviderWire` opens every provider HTTP stream and owns delivery: until any of the answer arrives, a lost wire, a sent request with no response head in 20 s (plus upload time), an answerless idle or first-output cut, or a provider's busy reply (overloaded, 5xx, a rate limit naming a wait up to 30 s) dials again, up to 10 dials with 0.5-8 s jittered backoff inside the call's wall, each redial first waiting for the Mac's network path (Stop and the wall end the wait); refusals, sign-in, context and long quota waits never redial, CLI wires never do, and the final failure says how many tries it took; wall-off streams forward without a deadline worker |

public struct ProviderStreamGuardConfig: Sendable, Equatable {
    public var idleTimeout: TimeInterval
    public var wallTimeout: TimeInterval
    /// Kept for configuration compatibility; activity now wakes deadline
    /// evaluation directly instead of sampling at this interval.
    public var checkInterval: TimeInterval
    /// The provider's first-output deadline for this call, asked as the stream
    /// starts. It bounds only a wire with nothing on it (a connection that never
    /// opened or hung before headers); unmeasured leaves the wall.
    public var firstOutput = FirstOutputDeadline(calls: 0, slowest: nil)

    /// The ceiling every configured timeout is clamped to. User, 2026-09-06:
    /// `TimeInterval("inf")` and `TimeInterval("1e400")` both parse, `max(0, …)`
    /// let them straight through, and `UInt64(wall * 1_000_000_000)` at the
    /// completion wall in `LLMClient+Real` TRAPS on a non-finite or
    /// out-of-range Double — a typo in one env var crashed the process on the
    /// next provider call. A day is far past any timeout that means anything
    /// and is comfortably representable in nanoseconds.
    public static let maximumTimeout: TimeInterval = 86_400

    /// Clamp at construction, so every path — env parse, direct init, test
    /// injection — carries a finite, representable number of seconds. NaN
    /// (which compares false against everything) takes the floor, matching what
    /// the old `max(0, …)` already did with it.
    private static func bounded(_ value: TimeInterval, floor: TimeInterval) -> TimeInterval {
        guard !value.isNaN else { return floor }
        return Swift.min(Swift.max(floor, value), maximumTimeout)
    }

    public init(
        idleTimeout: TimeInterval = 90,
        wallTimeout: TimeInterval = 600,
        checkInterval: TimeInterval = 0.5
    ) {
        self.idleTimeout = Self.bounded(idleTimeout, floor: 0)
        self.wallTimeout = Self.bounded(wallTimeout, floor: 0)
        self.checkInterval = Self.bounded(checkInterval, floor: 0.01)
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderStreamGuardConfig {
        let defaults = ProviderStreamGuardConfig()
        return ProviderStreamGuardConfig(
            idleTimeout: seconds(
                from: environment,
                keys: [
                    "NATIVE_AGENT_PROVIDER_STREAM_IDLE_TIMEOUT_SEC",
                    "NATIVE_AGENT_PROVIDER_STREAM_IDLE_TIMEOUT",
                ],
                fallback: defaults.idleTimeout
            ),
            wallTimeout: seconds(
                from: environment,
                keys: [
                    "NATIVE_AGENT_PROVIDER_STREAM_WALL_TIMEOUT_SEC",
                    "NATIVE_AGENT_PROVIDER_STREAM_WALL_TIMEOUT",
                ],
                fallback: defaults.wallTimeout
            ),
            checkInterval: seconds(
                from: environment,
                keys: [
                    "NATIVE_AGENT_PROVIDER_STREAM_CHECK_INTERVAL_SEC",
                    "NATIVE_AGENT_PROVIDER_STREAM_CHECK_INTERVAL",
                ],
                fallback: defaults.checkInterval
            )
        )
    }

    private static func seconds(
        from environment: [String: String],
        keys: [String],
        fallback: TimeInterval
    ) -> TimeInterval {
        for key in keys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let value = TimeInterval(raw)
            else { continue }
            return value
        }
        return fallback
    }
}

/// Every provider HTTP stream opens its wire here, and the guard dials again
/// by the rule here. Claude Code and Codex rode a flaky hotspot through the
/// night while she gave up on the first lost connection (10-23).
public enum ProviderWire {
    /// Dials per call, the first included.
    public static let maxAttempts = 10

    /// Send the request and wait for its response head. The guard counts the
    /// response bound from here; only HTTP wires report it, so a CLI child that
    /// is silent while it thinks is never judged dead.
    public static func open(_ session: URLSession, _ request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var request = request
        // The guard's idle and wall bound every stream; URLSession's own
        // timeout (60 s by default) would end a model still thinking first.
        request.timeoutInterval = .infinity
        ProviderStreamContext.sending?()
        let opened = try await session.bytes(for: request)
        if !ProviderStreamContext.stallOnly { ProviderStreamContext.activity?() }
        return opened
    }

    /// A sent request whose response head has not come back in this long is on
    /// a dead wire: 20 s, plus upload time at a slow 50 KB/s for a big request.
    static func responseBound(_ config: ProviderStreamGuardConfig) -> TimeInterval {
        20 + Double(config.firstOutput.requestBytes) / 50_000
    }

    /// The wait before dialing again after `attempt` ended with nothing of the
    /// answer, or nil when this failure is the answer. A dead or lost wire and
    /// a provider's "busy" (overloaded, 5xx, a rate limit that names a wait of
    /// 30 s or less) dial again: 0.5 s doubling to 8 s, with jitter. A refusal,
    /// a rejected sign-in, too much context, a long quota wait or a rate limit
    /// that names no wait never does.
    package static func redialDelay(_ cause: ProviderFailure?, attempt: Int) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        let backoff = min(0.5 * pow(2, Double(attempt - 1)), 8) * Double.random(in: 1...1.25)
        switch cause {
        case .network?, .overloaded?: return backoff
        case .rateLimited(let after?)?:
            return after <= 30 ? max(Double(after), backoff) : nil
        // A 429 with no named wait is transient load (Kimi: "engine overloaded"):
        // back off and dial again, like Claude Code. A spent quota names its wait.
        case .rateLimited(nil)?: return backoff
        default: return nil
        }
    }

    /// Returns once the Mac has a network path to dial on: at once when it has
    /// one; while it has none, when one comes back. Stop and the call's wall
    /// end the wait by cancelling it (Codex's "waiting for network").
    static func networkReturns() async {
        let wait = NetworkPathWait()
        await withTaskCancellationHandler { await wait.satisfied() } onCancel: { wait.finish() }
    }

    /// The call's final failure, saying how many dials it took.
    static func settled(_ error: any Error, tries: Int, seconds: TimeInterval) -> any Error {
        guard tries > 1, !(error is CancellationError) else { return error }
        let diagnostic = error as? ProviderFailure.Diagnostic
        return ProviderFailure.Diagnostic(
            cause: ProviderFailure.classify(error) ?? .network,
            detail: ProviderFailure.diagnosticDescription(error) + " (\(tries) tries over \(Int(seconds.rounded())) s)",
            deadlineExpired: diagnostic?.deadlineExpired ?? false,
            admitted: diagnostic?.admitted ?? false,
            repair: diagnostic?.repair,
            tries: tries)
    }
}

/// One wait for a usable network path, released by the path or by cancellation.
private final class NetworkPathWait: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func satisfied() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if done { lock.unlock(); continuation.resume(); return }
            self.continuation = continuation
            lock.unlock()
            monitor.pathUpdateHandler = { [weak self] path in
                if path.status == .satisfied { self?.finish() }
            }
            monitor.start(queue: DispatchQueue(label: "provider.wire.path"))
        }
        monitor.cancel()
    }

    func finish() {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

public enum ProviderStreamGuard {
    /// No URLSession request or resource cap: the guard's idle and wall bound
    /// the call, and with the wall configured off nothing but transport
    /// termination, provider completion or cancellation ends it.
    public static let stallOnlySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// `isOutput` says which yields are the provider's own output; an
    /// adapter's synthetic heartbeat is activity, never first output.
    public static func wrap<Element: Sendable>(
        makeUpstream: @escaping @Sendable () -> AsyncThrowingStream<Element, Error>,
        config: ProviderStreamGuardConfig,
        providerLabel: String,
        isOutput: @escaping @Sendable (Element) -> Bool
    ) -> AsyncThrowingStream<Element, Error> {
        let activity = ProviderStreamContext.activity
        return AsyncThrowingStream { continuation in
            let state = ProviderStreamGuardState(startedAt: monotonicNow())
            let producer = Task {
                defer { state.producerDidExit() }
                do {
                    try Task.checkCancellation()
                    try await ProviderStreamContext.$stallOnly.withValue(config.wallTimeout == 0) {
                    try await ProviderStreamContext.$activity.withValue({
                        if state.markProviderActivity(monotonicNow()) { activity?() }
                    }) {
                    try await ProviderStreamContext.$admitted.withValue({ state.markAdmitted() }) {
                    try await ProviderStreamContext.$sending.withValue({ state.markSent(monotonicNow()) }) {
                    // Idle time begins only when the producer has actually
                    // been admitted. Include upstream creation: even a stream
                    // that never opens or sends its first event can stall.
                    guard state.admitProducer(monotonicNow()) else { return }
                    // Until the answer begins, the request is not delivered:
                    // a dead wire or a provider's "busy, try again" dials it
                    // again, quickly and then spaced, inside this call's own
                    // limit (ProviderWire.redialDelay). Once any of the answer
                    // arrived, a cut ends the call with what it produced.
                    while true {
                        guard let attempt = state.beginAttempt(monotonicNow()) else { return }
                        let wire = Task {
                            var iterator = makeUpstream().makeAsyncIterator()
                            while let chunk = try await iterator.next() {
                                try Task.checkCancellation()
                                guard state.markActivity(monotonicNow(), output: isOutput(chunk)) else { return }
                                continuation.yield(chunk)
                            }
                            // A cancelled upstream may end as if complete.
                            try Task.checkCancellation()
                        }
                        state.own(attempt: wire)
                        var failure: (any Error)?
                        do {
                            try await withTaskCancellationHandler { try await wire.value } onCancel: { wire.cancel() }
                        } catch { failure = error }
                        let (letGo, sent) = state.endAttempt()
                        try Task.checkCancellation()
                        // A wire the watchdog let go never completed, however it ended.
                        guard let reason = letGo ?? failure else { break }
                        guard sent, !state.snapshot().yieldedAny,
                              let delay = ProviderWire.redialDelay(
                                  letGo == nil ? ProviderFailure.classify(reason) : .network, attempt: attempt) else {
                            throw ProviderWire.settled(reason, tries: attempt, seconds: monotonicNow() - state.snapshot().startedAt)
                        }
                        // No network on the Mac: wait for one, as long as the call's wall allows.
                        await ProviderWire.networkReturns()
                        try await Task.sleep(for: .seconds(delay))
                    }
                    try Task.checkCancellation()
                    state.finish(continuation)
                    }
                    }
                    }
                    }
                } catch {
                    state.finish(continuation, throwing: ProviderFailure.normalize(error, admitted: state.snapshot().admitted))
                }
            }

            let watchdog = config.wallTimeout > 0 ? Task {
                defer { state.deadlineDidExit() }
                while !Task.isCancelled {
                    // Register under the state lock before reading: an update
                    // between the read and park must still wake this wait.
                    let (snapshot, wake) = state.observe()
                    if snapshot.finished {
                        return
                    }

                    let now = monotonicNow()
                    if let timeout = timeout(snapshot: snapshot, now: now, config: config) {
                        let error = timeout.error(providerLabel: providerLabel, snapshot: snapshot,
                                                  waited: now - snapshot.startedAt, config: config)
                        // A sent request with nothing of the answer on its
                        // wire yet: the wire is dead, not slow. Let it go; the
                        // producer dials again (or, if activity won the race,
                        // this reads again).
                        if timeout != .wall, snapshot.sentAt != nil, !snapshot.yieldedAny,
                           snapshot.attempt < ProviderWire.maxAttempts {
                            _ = state.abandon(error, ifUnchanged: snapshot)
                            continue
                        }
                        let ended = state.finish(
                            continuation,
                            throwing: error,
                            ifUnchanged: snapshot
                        )
                        if ended {
                            producer.cancel()
                            return
                        }
                        continue // provider activity won the timeout race
                    }

                    let delay = nextDelay(snapshot: snapshot, now: now, config: config)
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await wake.park() }
                        group.addTask { try? await Task.sleep(for: .seconds(delay)) }
                        await group.next()
                        group.cancelAll()
                    }
                }
            } : nil

            state.own(producer: producer, deadline: watchdog)
            continuation.onTermination = { _ in state.retire() }
        }
    }

    private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private enum TimeoutKind {
        case idle, wall, firstOutput, noResponse

        func error(providerLabel p: String, snapshot: ProviderStreamGuardState.Snapshot,
                   waited: TimeInterval, config: ProviderStreamGuardConfig) -> Error {
            let waited = Int(waited.rounded()), idle = Int(config.idleTimeout.rounded())
            let deadline = config.firstOutput
            let arrived = !snapshot.admitted ? (!snapshot.hasWireActivity ? "nothing arrived" : "headers only")
                : snapshot.keepAlives == 0 ? "headers only" : "headers and \(snapshot.keepAlives) keep-alives"
            let evidence = deadline.seconds == nil
                ? "its first-output deadline is unmeasured (\(deadline.calls) of \(FirstOutputDeadline.callsNeeded) calls)."
                : "its slowest first output in the last \(deadline.calls) calls was \(Int((deadline.slowest ?? 0).rounded())) s; "
                    + "for this request's \(deadline.requestBytes / 1024) KB its deadline was \(Int((deadline.seconds ?? 0).rounded())) s."
            let account: String
            switch (self, snapshot.yieldedAny) {
            case (.noResponse, _): account = "No response from \(p) to the request it was sent (nothing arrived in \(Int(ProviderWire.responseBound(config).rounded())) s)."
            case (.firstOutput, _): account = "No first output from \(p) in \(waited) s (\(arrived)); \(evidence)"
            case (.wall, false): account = "No first output from \(p) by the call's \(waited) s limit (\(arrived)); \(evidence)"
            case (.idle, false): account = "No first output from \(p), and nothing on the line for \(idle) s (\(arrived) in \(waited) s)."
            case (.wall, true): account = "\(p) was still replying at the call's \(waited) s limit (\(snapshot.eventCount) events)."
            case (.idle, true): account = "\(p) went silent for \(idle) s mid-reply (\(snapshot.eventCount) events in \(waited) s)."
            }
            let cut = ProviderFailure.noReply(provider: p, seconds: waited, events: snapshot.eventCount, account: account)
            return ProviderFailure.Diagnostic(cause: cut, detail: account, deadlineExpired: true, admitted: snapshot.admitted,
                                              tries: max(1, snapshot.attempt))
        }
    }

    private static func timeout(
        snapshot: ProviderStreamGuardState.Snapshot,
        now: TimeInterval,
        config: ProviderStreamGuardConfig
    ) -> TimeoutKind? {
        if config.wallTimeout > 0,
           now - snapshot.startedAt >= config.wallTimeout {
            return .wall
        }
        // Between attempts only the wall runs.
        guard let attemptStartedAt = snapshot.attemptStartedAt else { return nil }
        if let sentAt = snapshot.sentAt, !snapshot.hasWireActivity,
           now - sentAt >= ProviderWire.responseBound(config) {
            return .noResponse
        }
        if config.idleTimeout > 0,
           let lastActivityAt = snapshot.lastActivityAt,
           now - lastActivityAt >= config.idleTimeout {
            return .idle
        }
        // A live wire is a provider thinking, however slower than last time;
        // its silence and the wall bound it.
        if !snapshot.hasWireActivity, !snapshot.yieldedAny, let deadline = config.firstOutput.seconds,
           now - attemptStartedAt >= deadline {
            return .firstOutput
        }
        return nil
    }

    private static func nextDelay(
        snapshot: ProviderStreamGuardState.Snapshot,
        now: TimeInterval,
        config: ProviderStreamGuardConfig
    ) -> TimeInterval {
        var candidates: [TimeInterval] = []
        if config.wallTimeout > 0 {
            candidates.append(config.wallTimeout - (now - snapshot.startedAt))
        }
        if let attemptStartedAt = snapshot.attemptStartedAt {
            if let sentAt = snapshot.sentAt, !snapshot.hasWireActivity {
                candidates.append(ProviderWire.responseBound(config) - (now - sentAt))
            }
            if config.idleTimeout > 0, let lastActivityAt = snapshot.lastActivityAt {
                candidates.append(config.idleTimeout - (now - lastActivityAt))
            }
            if !snapshot.hasWireActivity, !snapshot.yieldedAny, let deadline = config.firstOutput.seconds {
                candidates.append(deadline - (now - attemptStartedAt))
            }
        }
        return max(0.01, candidates.min() ?? config.wallTimeout)
    }
}

private final class ProviderStreamGuardState: @unchecked Sendable {
    struct Snapshot: Sendable {
        var finished: Bool
        var startedAt: TimeInterval
        /// Nil until the producer task has been admitted and is about to make
        /// its first upstream `next()` call.
        var lastActivityAt: TimeInterval?
        var eventCount: Int
        var hasWireActivity: Bool
        var admitted: Bool
        /// Wire events after admission (pings, comments, content-free events).
        var keepAlives: Int
        /// First output arrived: the adapter yielded the provider's own output
        /// (text, tool, reasoning). Wire keep-alives and synthetic heartbeats
        /// never set it.
        var yieldedAny: Bool
        /// The current dial (1-based), when it began (nil between dials), and
        /// when its HTTP request went out (nil for a wire that is not HTTP).
        var attempt: Int
        var attemptStartedAt: TimeInterval?
        var sentAt: TimeInterval?
    }

    private let lock = NSLock()
    private var finished = false
    private let startedAt: TimeInterval
    private var lastActivityAt: TimeInterval?
    private var providerEvents = 0
    private var yieldedEvents = 0
    private var admitted = false
    private var eventsAtAdmission = 0
    private var yieldedAny = false
    private var wake: ScopedWaiter?
    private var producer: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var producerExited = false
    private var deadlineExited = false
    private var attempt = 0
    private var attemptStartedAt: TimeInterval?
    private var sentAt: TimeInterval?
    private var attemptTask: Task<Void, Error>?
    /// Why the watchdog let the current wire go, read once by the producer.
    private var letGo: (any Error)?

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        self.lastActivityAt = nil
    }

    func admitProducer(_ now: TimeInterval) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        if lastActivityAt == nil {
            lastActivityAt = now
        }
        signalAndUnlock()
        return true
    }

    /// A new dial: its own wire clocks; the call's start and wall stay.
    func beginAttempt(_ now: TimeInterval) -> Int? {
        lock.lock()
        guard !finished else { lock.unlock(); return nil }
        attempt += 1
        attemptStartedAt = now
        sentAt = nil
        letGo = nil
        lastActivityAt = now
        providerEvents = 0
        yieldedEvents = 0
        admitted = false
        eventsAtAdmission = 0
        let number = attempt
        signalAndUnlock()
        return number
    }

    func own(attempt task: Task<Void, Error>) {
        lock.lock()
        let stop = finished || letGo != nil
        if !stop { attemptTask = task }
        lock.unlock()
        if stop { task.cancel() }
    }

    /// The dial ended: why the watchdog let it go, if it did, and whether its
    /// request went out on an HTTP wire (only those dial again).
    func endAttempt() -> (letGo: (any Error)?, sent: Bool) {
        lock.withLock {
            let ended = (letGo, sentAt != nil)
            letGo = nil
            attemptTask = nil
            attemptStartedAt = nil
            sentAt = nil
            return ended
        }
    }

    func markSent(_ now: TimeInterval) {
        lock.lock()
        guard !finished, attemptStartedAt != nil else { lock.unlock(); return }
        if sentAt == nil { sentAt = now }
        signalAndUnlock()
    }

    /// Let a dead wire go when nothing changed since `snapshot` was read.
    func abandon(_ reason: any Error, ifUnchanged snapshot: Snapshot) -> Bool {
        lock.lock()
        guard !finished, attempt == snapshot.attempt, attemptStartedAt != nil, letGo == nil,
              lastActivityAt == snapshot.lastActivityAt, yieldedAny == snapshot.yieldedAny else {
            lock.unlock()
            return false
        }
        letGo = reason
        attemptStartedAt = nil
        let task = attemptTask
        signalAndUnlock()
        task?.cancel()
        return true
    }

    func markActivity(_ now: TimeInterval, output: Bool) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        yieldedAny = yieldedAny || output
        // Wire progress comes from received response headers and SSE framing.
        // Adapter presentation yields or synthetic heartbeats cannot hide
        // wire silence once the transport has begun reporting activity.
        if providerEvents == 0 {
            yieldedEvents += 1
            lastActivityAt = now
        }
        signalAndUnlock()
        return true
    }

    func markAdmitted() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        admitted = true
        eventsAtAdmission = providerEvents
        signalAndUnlock()
    }

    func markProviderActivity(_ now: TimeInterval) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        providerEvents += 1
        lastActivityAt = now
        signalAndUnlock()
        return true
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    func observe() -> (Snapshot, ScopedWaiter) {
        lock.lock()
        defer { lock.unlock() }
        let waiter = wake ?? ScopedWaiter()
        wake = waiter
        return (snapshotLocked(), waiter)
    }

    private func snapshotLocked() -> Snapshot {
        return Snapshot(
            finished: finished,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            eventCount: providerEvents > 0 ? providerEvents : yieldedEvents,
            hasWireActivity: providerEvents > 0,
            admitted: admitted,
            keepAlives: admitted ? providerEvents - eventsAtAdmission : 0,
            yieldedAny: yieldedAny,
            attempt: attempt,
            attemptStartedAt: attemptStartedAt,
            sentAt: sentAt
        )
    }

    /// Called only with the state lock held; never resume a waiter under it.
    private func signalAndUnlock() {
        let waiter = wake
        wake = nil
        lock.unlock()
        waiter?.resume()
    }

    func retire() {
        lock.lock()
        finished = true
        let producer = self.producer
        let deadline = self.deadline
        let wire = attemptTask
        signalAndUnlock()
        wire?.cancel()
        producer?.cancel()
        deadline?.cancel()
    }

    func own(producer: Task<Void, Never>, deadline: Task<Void, Never>?) {
        lock.lock()
        if !producerExited { self.producer = producer }
        if !deadlineExited { self.deadline = deadline }
        let stop = finished
        lock.unlock()
        // Completion/cancellation can beat handle installation. The terminal
        // latch still cancels them, and each actual exit releases its handle.
        if stop { producer.cancel(); deadline?.cancel() }
    }

    func producerDidExit() {
        lock.withLock { producerExited = true; producer = nil }
    }

    func deadlineDidExit() {
        lock.withLock { deadlineExited = true; deadline = nil }
    }

    @discardableResult
    func finish<Element: Sendable>(
        _ continuation: AsyncThrowingStream<Element, Error>.Continuation,
        throwing error: (any Error)? = nil,
        ifUnchanged snapshot: Snapshot? = nil
    ) -> Bool {
        lock.lock()
        guard !finished, snapshot == nil
                || (snapshot?.lastActivityAt == lastActivityAt && snapshot?.yieldedAny == yieldedAny) else {
            lock.unlock()
            return false
        }
        finished = true
        signalAndUnlock()

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        return true
    }
}

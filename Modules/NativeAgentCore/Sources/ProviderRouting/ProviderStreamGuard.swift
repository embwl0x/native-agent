import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `ProviderStreamGuard.swift` | Configured idle/wall cuts on wire activity; progress and shared NetworkSense path edges wake deadlines without polling; terminal state closes admission and retires the network observation, retaining forwarding/deadline task handles through actual exit; whole-reply Stop cancels coordinator waits and redial admission while joining the independently stopped wire through exit/drain; typed no-reply/offline failures and uncapped model URLSession; learned first-output deadline bounds only a wire with nothing on it; `ProviderWire` opens every provider HTTP stream and owns up to 10 pre-answer dials for network/overload/short rate limits with 0.5-8 s jittered backoff inside the wall; every dial reads the shared path, waiting at most 30 s offline, and in-flight path loss has the same bound; offline, refusal, sign-in, context and long quota waits never redial, CLI wires never redial; wall-off streams park on events without an online deadline timer |

public struct ProviderStreamGuardConfig: Sendable, Equatable {
    public var idleTimeout: TimeInterval
    public var wallTimeout: TimeInterval
    /// The provider's first-output deadline for this call, asked as the stream
    /// starts. It bounds only a wire with nothing on it (a connection that never
    /// opened or hung before headers); unmeasured leaves the wall.
    public var firstOutput = FirstOutputDeadline(calls: 0, slowest: nil)

    /// Configured timeouts are finite and capped at one day for safe nanosecond conversion.
    public static let maximumTimeout: TimeInterval = 86_400

    public init(
        idleTimeout: TimeInterval = 90,
        wallTimeout: TimeInterval = 600
    ) {
        self.idleTimeout = idleTimeout
        self.wallTimeout = wallTimeout
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderStreamGuardConfig {
        let defaults = ProviderStreamGuardConfig()
        return ProviderStreamGuardConfig(
            idleTimeout: seconds(
                from: environment,
                key: "NATIVE_AGENT_PROVIDER_STREAM_IDLE_TIMEOUT_SEC",
                absent: defaults.idleTimeout
            ),
            wallTimeout: seconds(
                from: environment,
                key: "NATIVE_AGENT_PROVIDER_STREAM_WALL_TIMEOUT_SEC",
                absent: defaults.wallTimeout
            )
        )
    }

    private static func seconds(
        from environment: [String: String],
        key: String,
        absent: TimeInterval
    ) -> TimeInterval {
        guard let raw = environment[key] else { return absent }
        // Keep invalid configuration unavailable until validate(), rather than
        // substituting a different deadline in this nonthrowing constructor.
        return TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan
    }

    public func validate() throws {
        for (key, value) in [("NATIVE_AGENT_PROVIDER_STREAM_IDLE_TIMEOUT_SEC", idleTimeout),
                             ("NATIVE_AGENT_PROVIDER_STREAM_WALL_TIMEOUT_SEC", wallTimeout)] {
            guard value.isFinite, (0...Self.maximumTimeout).contains(value) else {
                throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                    detail: "Invalid \(key): supply finite seconds in 0...86400 (zero disables this deadline). Correct the environment setting and restart NativeAgent; no request was sent.")
            }
        }
    }
}

/// Every provider HTTP stream opens its wire here; the guard owns redial admission.
public enum ProviderWire {
    /// Dials per call, the first included.
    public static let maxAttempts = 10
    static let networkReturnWait: TimeInterval = 30

    /// Send the request and wait for its response head. Only HTTP wires mark
    /// this send for pre-answer redial admission; a silent CLI child does not.
    public static func open(_ session: URLSession, _ request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await networkReturns()
        var request = request
        // The guard's idle and wall bound every stream; URLSession's own
        // timeout (60 s by default) would end a model still thinking first.
        request.timeoutInterval = .infinity
        ProviderStreamContext.sending?()
        // Count-only evidence after body assembly and the offline wait, just
        // before URLSession. This is a send attempt, never provider receipt.
        TurnTraceBus.fireFromContext(kind: "provider.httpRequestStarted", surface: LLMCallContext.surface,
            payload: .object(["requestBodyBytes": .int(Int64(request.httpBody?.count ?? 0))]))
        OAuthProbeCredential.sending(request)
        let opened = try await session.bytes(for: request)
        if !ProviderStreamContext.stallOnly { ProviderStreamContext.activity?() }
        return opened
    }

    /// Reject a failed Chat Completions response after a bounded body drain.
    static func validateChatCompletions(
        _ bytes: URLSession.AsyncBytes, _ response: URLResponse,
        rejected: (Int) throws -> Void = { _ in }
    ) async throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200..<300).contains(status) else { return }
        let body = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096, timeout: 2.0)
        try rejected(status)
        try throwIfChatCompletionsError(status: status, data: body, response: response)
    }

    /// Before answer output, retry network loss, overload/5xx and rate limits
    /// with no wait or a wait up to 30 s. Backoff doubles from 0.5 to 8 s with
    /// jitter; named waits also set a minimum delay. The attempt ceiling and all
    /// other failures (refusal, sign-in, context, longer waits) end redial.
    package static func redialDelay(_ cause: ProviderFailure?, attempt: Int) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        let backoff = min(0.5 * pow(2, Double(attempt - 1)), 8) * Double.random(in: 1...1.25)
        switch cause {
        case .network?, .overloaded?: return backoff
        case .rateLimited(let after?)?:
            return after <= 30 ? max(Double(after), backoff) : nil
        case .rateLimited(nil)?: return backoff
        default: return nil
        }
    }

    /// A short Wi-Fi blip may heal; an absent path never consumes the wall.
    static func networkReturns() async throws {
        try Task.checkCancellation()
        guard !NetworkSense.isUp else { return }
        guard try await NetworkSense.returns(within: networkReturnWait) else { throw ProviderFailure.offline }
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

public enum ProviderStreamGuard {
    /// No URLSession request or resource cap: the guard's idle/wall and shared
    /// offline bound own the call. Wall-off leaves only the offline bound,
    /// transport termination, provider completion or cancellation.
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
            do { try config.validate() }
            catch { continuation.finish(throwing: error); return }
            let state = ProviderStreamGuardState(startedAt: monotonicNow())
            state.observeNetwork()
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
                    // `ProviderWire.redialDelay` admits redials within this call's
                    // wall until answer output begins; then a cut ends the call.
                    while true {
                        try await ProviderWire.networkReturns()
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
                            // Whole-reply Stop cancels this coordinator's waits,
                            // but the transport owns stopping its active work.
                            // Await the uncancelled forwarder through exit/drain.
                            // Iterator termination still cancels it via retire().
                            try await wire.value
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
                        // No path: allow a brief return, then end with the real cause.
                        try await ProviderWire.networkReturns()
                        try await Task.sleep(for: .seconds(delay))
                    }
                    try Task.checkCancellation()
                    state.finish(continuation)
                    }
                    }
                    }
                    }
                } catch {
                    let snapshot = state.snapshot()
                    let failure = ProviderFailure.classify(error) == .offline
                        ? ProviderWire.settled(error, tries: snapshot.attempt, seconds: monotonicNow() - snapshot.startedAt)
                        : error
                    state.finish(continuation, throwing: ProviderFailure.normalize(failure, admitted: snapshot.admitted))
                }
            }

            let watchdog = Task {
                defer { state.deadlineDidExit() }
                while !Task.isCancelled {
                    // Register under the state lock before reading: an update
                    // between the read and park must still wake this wait.
                    let (snapshot, wake) = state.observe()
                    if snapshot.finished {
                        return
                    }

                    let now = monotonicNow()
                    let enabled = deadlines(snapshot: snapshot, now: now, config: config)
                    if let timeout = enabled.first(where: { $0.remaining <= 0 })?.kind {
                        let error = timeout.error(providerLabel: providerLabel, snapshot: snapshot,
                                                  waited: now - snapshot.startedAt, config: config)
                        // A sent request with nothing of the answer on its
                        // wire yet: the wire is dead, not slow. Let it go; the
                        // producer dials again (or, if activity won the race,
                        // this reads again).
                        if timeout != .wall, timeout != .offline, snapshot.sentAt != nil, !snapshot.yieldedAny,
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

                    guard let remaining = enabled.map({ $0.remaining }).min() else {
                        await wake.park()
                        continue
                    }
                    let delay = max(0.01, remaining)
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await wake.park() }
                        group.addTask { try? await Task.sleep(for: .seconds(delay)) }
                        await group.next()
                        group.cancelAll()
                    }
                }
            }

            ProviderReplyWork.current?.own(producer)
            ProviderReplyWork.current?.own(watchdog)
            state.own(producer: producer, deadline: watchdog)
            continuation.onTermination = { _ in state.retire() }
        }
    }

    private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private enum TimeoutKind {
        case idle, wall, firstOutput, offline

        func error(providerLabel p: String, snapshot: ProviderStreamGuardState.Snapshot,
                   waited: TimeInterval, config: ProviderStreamGuardConfig) -> Error {
            let waited = Int(waited.rounded()), idle = Int(config.idleTimeout.rounded())
            let deadline = config.firstOutput
            let arrived = !snapshot.admitted ? (!snapshot.hasWireActivity ? "nothing arrived" : "headers only")
                : snapshot.keepAlives == 0 ? "headers only" : "headers and \(snapshot.keepAlives) keep-alives"
            let evidence = deadline.seconds == nil
                ? "its first-output deadline is unmeasured (\(deadline.calls) of \(FirstOutputDeadline.callsNeeded) calls)."
                : "its slowest first output in the last \(deadline.calls) calls was \(String(format: "%.0f", deadline.slowest ?? 0)) s; "
                    + "for this request's \(deadline.requestBytes / 1024) KB its deadline was \(String(format: "%.0f", deadline.seconds ?? 0)) s."
            let account: String
            switch (self, snapshot.yieldedAny) {
            case (.offline, _):
                let progress = "Current dial: \(snapshot.sentAt == nil ? "no HTTP send attempt observed" : "HTTP send attempted"); provider response \(snapshot.admitted ? "began" : "not observed"); \(snapshot.eventCount) events received."
                return ProviderFailure.Diagnostic(cause: .offline, detail: ProviderFailure.offline.localizedDescription + " " + progress,
                    admitted: snapshot.admitted, tries: max(1, snapshot.attempt))
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

    /// Precedence is wall, offline, idle, first output; the earliest remaining deadline determines the wake.
    private static func deadlines(
        snapshot: ProviderStreamGuardState.Snapshot,
        now: TimeInterval,
        config: ProviderStreamGuardConfig
    ) -> [(kind: TimeoutKind, remaining: TimeInterval)] {
        var enabled: [(kind: TimeoutKind, remaining: TimeInterval)] = []
        if config.wallTimeout > 0 {
            enabled.append((.wall, config.wallTimeout - (now - snapshot.startedAt)))
        }
        if let down = snapshot.networkDownAt {
            enabled.append((.offline, ProviderWire.networkReturnWait - (now - down)))
        }
        // Between attempts only wall/offline run. Wall-off keeps the existing
        // transport-driven behavior, apart from the body's offline deadline.
        guard config.wallTimeout > 0, let attemptStartedAt = snapshot.attemptStartedAt else { return enabled }
        if config.idleTimeout > 0, let lastActivityAt = snapshot.lastActivityAt {
            enabled.append((.idle, config.idleTimeout - (now - lastActivityAt)))
        }
        // A live wire is bounded by idle and wall, without a first-output cut.
        if !snapshot.hasWireActivity, !snapshot.yieldedAny, let deadline = config.firstOutput.seconds {
            enabled.append((.firstOutput, deadline - (now - attemptStartedAt)))
        }
        return enabled
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
        var networkDownAt: TimeInterval?
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
    private var networkObservation: NSObjectProtocol?
    private var networkDownAt: TimeInterval?

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        self.lastActivityAt = nil
    }

    /// Subscribe before reading; callbacks reread the one owner so even a
    /// concurrent return cannot publish an older path over the current one.
    func observeNetwork() {
        let observer = NotificationCenter.default.addObserver(forName: NetworkSense.pathChanged,
            object: nil, queue: nil) { [weak self] _ in self?.networkChanged() }
        lock.withLock { networkObservation = observer }
        networkChanged()
    }

    private func networkChanged() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if NetworkSense.isUp { networkDownAt = nil }
        else if networkDownAt == nil { networkDownAt = ProcessInfo.processInfo.systemUptime }
        signalAndUnlock()
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
            sentAt: sentAt,
            networkDownAt: networkDownAt
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
        let observer = networkObservation
        networkObservation = nil
        signalAndUnlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
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
                || (snapshot?.lastActivityAt == lastActivityAt && snapshot?.yieldedAny == yieldedAny
                    && snapshot?.networkDownAt == networkDownAt) else {
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

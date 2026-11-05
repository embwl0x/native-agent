import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `ProviderStreamGuard.swift` | `ProviderWire`: bounded pre-answer redelivery; wire-owned clocks |

public struct ProviderStreamGuardConfig: Sendable, Equatable {
    public var idleTimeout: TimeInterval
    public var wallTimeout: TimeInterval
    /// The provider's first-output deadline for this call, asked as the stream starts. It bounds only a wire with nothing on it (a connection that never
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
        // Keep invalid configuration unavailable until validate(), rather than substituting a different deadline in this nonthrowing constructor.
        return TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan
    }

    public func validate() throws {
        for (key, value) in [("NATIVE_AGENT_PROVIDER_STREAM_IDLE_TIMEOUT_SEC", idleTimeout),
                             ("NATIVE_AGENT_PROVIDER_STREAM_WALL_TIMEOUT_SEC", wallTimeout)] {
            guard value.isFinite, (0...Self.maximumTimeout).contains(value) else {
                throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                    detail: """
                        Invalid \(key): supply finite seconds in 0...86400 (zero disables this deadline). Correct the environment setting and restart \
                        NativeAgent; no request was sent.
                        """)
            }
        }
    }
}

/// Every provider HTTP stream opens its wire here; the guard owns redial admission.
public enum ProviderWire {
    /// The attempt ceiling includes the initial dial.
    public static let maxAttempts = 10
    static let networkReturnWait: TimeInterval = 30

    /// Only HTTP sends establish pre-answer redial admission; silent CLI children do not.
    public static func open(_ session: URLSession, _ request: URLRequest, call: LLMCall) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await networkReturns()
        var request = request
        // The guard's idle and wall bound every stream; URLSession's own timeout (60 s by default) would end a model still thinking first.
        request.timeoutInterval = .infinity
        call.lifetime.sending?()
        // Count-only evidence after body assembly and the offline wait, just before URLSession. This is a send attempt, never provider receipt.
        TurnTraceBus.fireFromContext(kind: "provider.httpRequestStarted", surface: call.surface,
            payload: .object(["requestBodyBytes": .int(Int64(request.httpBody?.count ?? 0))]), turn: call.turn)
        call.probeCredential?.sending(request)
        let opened = try await session.bytes(for: request)
        if !call.lifetime.stallOnly { call.lifetime.activity?() }
        return opened
    }

    /// Bound diagnostic drain before rejecting failed HTTP responses.
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

    /// Redial only before output for network loss, overload and rate waits up to 30 seconds. Backoff doubles from 0.5 to 8 seconds with jitter;
    /// attempt/wall limits bound every retry.
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

    /// Retain final dial count so another owner cannot duplicate redelivery.
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
    /// No URLSession request or resource cap: the guard's idle/wall and shared offline bound own the call. Wall-off leaves only the offline bound,
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

    /// Only provider output establishes first output; synthetic heartbeats cannot.
    public static func wrap<Element: Sendable>(
        makeUpstream: @escaping @Sendable (LLMCall) -> AsyncThrowingStream<Element, Error>,
        config: ProviderStreamGuardConfig,
        providerLabel: String,
        isOutput: @escaping @Sendable (Element) -> Bool, call: LLMCall
    ) -> AsyncThrowingStream<Element, Error> {
        let activity = call.lifetime.activity
        return AsyncThrowingStream { continuation in
            do { try config.validate() }
            catch { continuation.finish(throwing: error); return }
            let state = ProviderStreamGuardState(startedAt: monotonicNow())
            state.observeNetwork()
            let producer = Task {
                defer { state.producerDidExit() }
                do {
                    try Task.checkCancellation()
                    var wireCall = call
                    wireCall.lifetime.stallOnly = config.wallTimeout == 0
                    wireCall.lifetime.activity = {
                        if state.markProviderActivity(monotonicNow()) { activity?() }
                    }
                    wireCall.lifetime.admitted = { state.markAdmitted() }
                    wireCall.lifetime.sending = { state.markSent(monotonicNow()) }
                    let held = wireCall
                    // Idle time begins only when the producer has actually been admitted. Include upstream creation: even a stream that never opens or
                    // sends its first event can stall.
                    guard state.admitProducer(monotonicNow()) else { return }
                    // Redials stay inside the call's wall and end once answer output begins.
                    while true {
                        try await ProviderWire.networkReturns()
                        guard let attempt = state.beginAttempt(monotonicNow()) else { return }
                        let wire = Task {
                            var iterator = makeUpstream(held).makeAsyncIterator()
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
                            // Whole-reply Stop cancels this coordinator's waits, but the transport owns stopping its active work. Await the uncancelled
                            // forwarder through exit/drain. Iterator termination still cancels it via retire().
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
                        // Bound offline waiting before reporting path absence.
                        try await ProviderWire.networkReturns()
                        try await Task.sleep(for: .seconds(delay))
                    }
                    try Task.checkCancellation()
                    state.finish(continuation)
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
                    // Register under the state lock before reading: an update between the read and park must still wake this wait.
                    let (snapshot, wake) = state.observe()
                    if snapshot.finished {
                        return
                    }

                    let now = monotonicNow()
                    let enabled = deadlines(snapshot: snapshot, now: now, config: config)
                    if let timeout = enabled.first(where: { $0.remaining <= 0 })?.kind {
                        let error = timeout.error(providerLabel: providerLabel, snapshot: snapshot,
                                                  waited: now - snapshot.startedAt, config: config)
                        // A sent wire with no answer activity may redial; recheck progress before releasing it so concurrent activity wins.
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

            call.replyWork?.own(producer)
            call.replyWork?.own(watchdog)
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
                let progress = """
                    Current dial: \(snapshot.sentAt == nil ? "no HTTP send attempt observed" : "HTTP send attempted"); provider response \
                    \(snapshot.admitted ? "began" : "not observed"); \(snapshot.eventCount) events received.
                    """
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
        // Between dials only wall/offline deadlines apply; wall-off still honors the shared offline bound.
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
        /// The idle clock cannot start before producer admission.
        var lastActivityAt: TimeInterval?
        var eventCount: Int
        var hasWireActivity: Bool
        var admitted: Bool
        /// Wire activity includes content-free events but does not prove answer output.
        var keepAlives: Int
        /// Only actual text/tool/reasoning output sets first output; pings and synthetic heartbeats do not.
        var yieldedAny: Bool
        /// Dial-local clocks reset per attempt; HTTP send time stays nil for non-HTTP wires.
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
    /// Only the producer consumes the watchdog's release reason.
    private var letGo: (any Error)?
    private var networkObservation: NSObjectProtocol?
    private var networkDownAt: TimeInterval?

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        self.lastActivityAt = nil
    }

    /// Subscribe before reading; callbacks reread the one owner so even a concurrent return cannot publish an older path over the current one.
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

    /// A new dial resets wire clocks without resetting the call's wall.
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

    /// Only a released HTTP send can authorize another dial.
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

    /// Release a dead wire only if progress still matches the observed snapshot.
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
        // Wire progress comes from received response headers and SSE framing. Adapter presentation yields or synthetic heartbeats cannot hide wire silence
        // once the transport has begun reporting activity.
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
        // Completion/cancellation can beat handle installation. The terminal latch still cancels them, and each actual exit releases its handle.
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

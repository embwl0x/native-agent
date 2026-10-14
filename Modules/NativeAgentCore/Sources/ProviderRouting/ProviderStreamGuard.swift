import Foundation
import NativeAgentCore

public struct ProviderStreamGuardConfig: Sendable, Equatable {
    public var idleTimeout: TimeInterval
    public var wallTimeout: TimeInterval
    public var checkInterval: TimeInterval
    /// The provider's first-output deadline for this call, asked as the stream
    /// starts. Until its first output, a stream that only keeps the connection
    /// open (headers, comments, pings) is cut there; unmeasured leaves the wall.
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
        return AsyncThrowingStream { continuation in
            let state = ProviderStreamGuardState(startedAt: monotonicNow())
            let producer = Task {
                do {
                    try Task.checkCancellation()
                    try await ProviderStreamContext.$stallOnly.withValue(config.wallTimeout == 0) {
                    try await ProviderStreamContext.$activity.withValue({
                        _ = state.markProviderActivity(monotonicNow())
                    }) {
                    try await ProviderStreamContext.$admitted.withValue({ state.markAdmitted() }) {
                    // Idle time begins only when the producer has actually
                    // been admitted. Include upstream creation: even a stream
                    // that never opens or sends its first event can stall.
                    guard state.admitProducer(monotonicNow()) else { return }
                    var iterator = makeUpstream().makeAsyncIterator()
                    while let chunk = try await iterator.next() {
                        try Task.checkCancellation()
                        guard state.markActivity(monotonicNow(), output: isOutput(chunk)) else { break }
                        continuation.yield(chunk)
                    }
                    try Task.checkCancellation()
                    state.finish(continuation)
                    }
                    }
                    }
                } catch {
                    state.finish(continuation, throwing: ProviderFailure.normalize(error, admitted: state.snapshot().admitted))
                }
            }

            let watchdog = config.wallTimeout > 0 ? Task {
                while !Task.isCancelled {
                    let snapshot = state.snapshot()
                    if snapshot.finished {
                        return
                    }

                    let now = monotonicNow()
                    if let timeout = timeout(snapshot: snapshot, now: now, config: config) {
                        let ended = state.finish(
                            continuation,
                            throwing: timeout.error(providerLabel: providerLabel, snapshot: snapshot,
                                                    waited: now - snapshot.startedAt, config: config),
                            ifUnchanged: snapshot
                        )
                        if ended {
                            producer.cancel()
                            return
                        }
                        continue // provider activity won the timeout race
                    }

                    let delay = nextDelay(snapshot: snapshot, now: now, config: config)
                    let nanos = UInt64(max(0.01, delay) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                }
            } : nil

            continuation.onTermination = { _ in
                producer.cancel()
                watchdog?.cancel()
            }
        }
    }

    private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private enum TimeoutKind {
        case idle, wall, firstOutput

        /// The cut carries wire evidence so recovery can distinguish a live
        /// slow start from an unopened connection without reading its wording.
        func error(providerLabel p: String, snapshot: ProviderStreamGuardState.Snapshot,
                   waited: TimeInterval, config: ProviderStreamGuardConfig) -> Error {
            let waited = Int(waited.rounded()), idle = Int(config.idleTimeout.rounded())
            let deadline = config.firstOutput
            let arrived = !snapshot.admitted ? (!snapshot.hasWireActivity ? "nothing arrived" : "headers only")
                : snapshot.keepAlives == 0 ? "headers only" : "headers and \(snapshot.keepAlives) keep-alives"
            let evidence = deadline.seconds == nil
                ? "its first-output deadline is unmeasured (\(deadline.calls) of \(FirstOutputDeadline.callsNeeded) calls)."
                : "its slowest first output in the last \(deadline.calls) calls was \(Int((deadline.slowest ?? 0).rounded())) s."
            let account: String
            switch (self, snapshot.yieldedAny) {
            case (.firstOutput, _): account = "No first output from \(p) in \(waited) s (\(arrived)); \(evidence)"
            case (.wall, false):
                let evidence = ProviderStreamContext.retryingLiveFirstOutputCut
                    ? "the learned first-output deadline was skipped after a live-stream cut." : evidence
                account = "No first output from \(p) by the call's \(waited) s limit (\(arrived)); \(evidence)"
            case (.idle, false): account = "No first output from \(p), and nothing on the line for \(idle) s (\(arrived) in \(waited) s)."
            case (.wall, true): account = "\(p) was still replying at the call's \(waited) s limit (\(snapshot.eventCount) events)."
            case (.idle, true): account = "\(p) went silent for \(idle) s mid-reply (\(snapshot.eventCount) events in \(waited) s)."
            }
            let cut = ProviderFailure.noReply(provider: p, seconds: waited, events: snapshot.eventCount, account: account)
            return ProviderFailure.Diagnostic(cause: cut, detail: account, deadlineExpired: true,
                admitted: snapshot.admitted, liveFirstOutputCut: self == .firstOutput && snapshot.hasWireActivity)
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
        if !ProviderStreamContext.retryingLiveFirstOutputCut, config.idleTimeout > 0,
           let lastActivityAt = snapshot.lastActivityAt,
           now - lastActivityAt >= config.idleTimeout {
            return .idle
        }
        if !ProviderStreamContext.retryingLiveFirstOutputCut,
           !snapshot.yieldedAny, let deadline = config.firstOutput.seconds,
           now - snapshot.startedAt >= deadline {
            return .firstOutput
        }
        return nil
    }

    private static func nextDelay(
        snapshot: ProviderStreamGuardState.Snapshot,
        now: TimeInterval,
        config: ProviderStreamGuardConfig
    ) -> TimeInterval {
        var candidates = [config.checkInterval]
        if !ProviderStreamContext.retryingLiveFirstOutputCut, config.idleTimeout > 0,
           let lastActivityAt = snapshot.lastActivityAt {
            candidates.append(config.idleTimeout - (now - lastActivityAt))
        }
        if config.wallTimeout > 0 {
            candidates.append(config.wallTimeout - (now - snapshot.startedAt))
        }
        if !ProviderStreamContext.retryingLiveFirstOutputCut,
           !snapshot.yieldedAny, let deadline = config.firstOutput.seconds {
            candidates.append(deadline - (now - snapshot.startedAt))
        }
        return max(0.01, candidates.min() ?? config.checkInterval)
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

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        self.lastActivityAt = nil
    }

    func admitProducer(_ now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        if lastActivityAt == nil {
            lastActivityAt = now
        }
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
        lock.unlock()
        return true
    }

    func markAdmitted() {
        lock.lock()
        admitted = true
        eventsAtAdmission = providerEvents
        lock.unlock()
    }

    func markProviderActivity(_ now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        providerEvents += 1
        lastActivityAt = now
        return true
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            finished: finished,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            eventCount: providerEvents > 0 ? providerEvents : yieldedEvents,
            hasWireActivity: providerEvents > 0,
            admitted: admitted,
            keepAlives: admitted ? providerEvents - eventsAtAdmission : 0,
            yieldedAny: yieldedAny
        )
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
        lock.unlock()

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        return true
    }
}

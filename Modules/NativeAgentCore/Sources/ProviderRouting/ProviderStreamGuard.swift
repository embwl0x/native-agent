import Foundation

public struct ProviderStreamGuardConfig: Sendable, Equatable {
    public var idleTimeout: TimeInterval
    public var wallTimeout: TimeInterval
    public var checkInterval: TimeInterval

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

    public var isEnabled: Bool {
        idleTimeout > 0 || wallTimeout > 0
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
    public static func wrap<Element: Sendable>(
        _ upstream: AsyncThrowingStream<Element, Error>,
        config: ProviderStreamGuardConfig,
        providerLabel: String
    ) -> AsyncThrowingStream<Element, Error> {
        makeGuardedStream(
            upstream,
            config: config,
            providerLabel: providerLabel,
            beforeProducerAdmission: nil,
            watchdogStarted: nil
        )
    }

    /// Deterministic seam for proving watchdog/producer admission ordering.
    /// Production uses `wrap` and pays no hook awaits.
    static func _wrapForTesting<Element: Sendable>(
        _ upstream: AsyncThrowingStream<Element, Error>,
        config: ProviderStreamGuardConfig,
        providerLabel: String,
        beforeProducerAdmission: @escaping @Sendable () async -> Void,
        watchdogStarted: @escaping @Sendable () async -> Void
    ) -> AsyncThrowingStream<Element, Error> {
        makeGuardedStream(
            upstream,
            config: config,
            providerLabel: providerLabel,
            beforeProducerAdmission: beforeProducerAdmission,
            watchdogStarted: watchdogStarted
        )
    }

    private static func makeGuardedStream<Element: Sendable>(
        _ upstream: AsyncThrowingStream<Element, Error>,
        config: ProviderStreamGuardConfig,
        providerLabel: String,
        beforeProducerAdmission: (@Sendable () async -> Void)?,
        watchdogStarted: (@Sendable () async -> Void)?
    ) -> AsyncThrowingStream<Element, Error> {
        guard config.isEnabled else { return upstream }

        return AsyncThrowingStream { continuation in
            let state = ProviderStreamGuardState(startedAt: monotonicNow())

            let producer = Task {
                do {
                    if let beforeProducerAdmission {
                        await beforeProducerAdmission()
                    }
                    try Task.checkCancellation()
                    var iterator = upstream.makeAsyncIterator()
                    // Idle time begins only when the producer has actually
                    // been admitted and is about to ask upstream for its first
                    // element. Wall time still began at wrapper creation.
                    guard state.admitProducer(monotonicNow()) else { return }
                    while let chunk = try await iterator.next() {
                        try Task.checkCancellation()
                        guard state.markActivity(monotonicNow()) else { break }
                        continuation.yield(chunk)
                    }
                    state.finish(continuation)
                } catch {
                    state.finish(continuation, throwing: error)
                }
            }

            let watchdog = Task {
                if let watchdogStarted {
                    await watchdogStarted()
                }
                while !Task.isCancelled {
                    let snapshot = state.snapshot()
                    if snapshot.finished {
                        return
                    }

                    let now = monotonicNow()
                    if let timeout = timeout(snapshot: snapshot, now: now, config: config) {
                        state.finish(
                            continuation,
                            throwing: timeout.error(providerLabel: providerLabel)
                        )
                        producer.cancel()
                        return
                    }

                    let delay = nextDelay(snapshot: snapshot, now: now, config: config)
                    let nanos = UInt64(max(0.01, delay) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                }
            }

            continuation.onTermination = { _ in
                producer.cancel()
                watchdog.cancel()
            }
        }
    }

    private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private enum TimeoutKind {
        case idle(seconds: TimeInterval)
        case wall(seconds: TimeInterval)

        func error(providerLabel: String) -> LLMError {
            switch self {
            case .idle(let seconds):
                return .transient(
                    message: "\(providerLabel) stream idle timeout after \(format(seconds))s"
                )
            case .wall(let seconds):
                return .transient(
                    message: "\(providerLabel) stream wall timeout after \(format(seconds))s"
                )
            }
        }

        private func format(_ seconds: TimeInterval) -> String {
            if seconds.rounded() == seconds {
                return String(Int(seconds))
            }
            return String(format: "%.2f", seconds)
        }
    }

    private static func timeout(
        snapshot: ProviderStreamGuardState.Snapshot,
        now: TimeInterval,
        config: ProviderStreamGuardConfig
    ) -> TimeoutKind? {
        if config.wallTimeout > 0,
           now - snapshot.startedAt >= config.wallTimeout {
            return .wall(seconds: config.wallTimeout)
        }
        if config.idleTimeout > 0,
           let lastActivityAt = snapshot.lastActivityAt,
           now - lastActivityAt >= config.idleTimeout {
            return .idle(seconds: config.idleTimeout)
        }
        return nil
    }

    private static func nextDelay(
        snapshot: ProviderStreamGuardState.Snapshot,
        now: TimeInterval,
        config: ProviderStreamGuardConfig
    ) -> TimeInterval {
        var candidates = [config.checkInterval]
        if config.idleTimeout > 0,
           let lastActivityAt = snapshot.lastActivityAt {
            candidates.append(config.idleTimeout - (now - lastActivityAt))
        }
        if config.wallTimeout > 0 {
            candidates.append(config.wallTimeout - (now - snapshot.startedAt))
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
    }

    private let lock = NSLock()
    private var finished = false
    private let startedAt: TimeInterval
    private var lastActivityAt: TimeInterval?

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

    func markActivity(_ now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        lastActivityAt = now
        return true
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            finished: finished,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt
        )
    }

    func finish<Element: Sendable>(
        _ continuation: AsyncThrowingStream<Element, Error>.Continuation,
        throwing error: (any Error)? = nil
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

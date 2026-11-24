import AppKit
import Synchronization
import ApplicationServices
import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `ActivityWatcher.swift` | Ordered capture queue and span-store pump; the drained pump releases restart ownership |

// The capture queue owns AppKit observer tokens and the live capture sources.
public final class ActivityWatcher: @unchecked Sendable {
    // MARK: Capture boundaries

    /// Five minutes avoids treating ordinary pauses as app changes without overstating long inactive sessions.
    public static let defaultIdleThreshold: TimeInterval = 300
    static let tickInterval: TimeInterval = 60

    /// Frontmost loginwindow means lock even if AX supplies plausible titles.
    public static let loginWindowBundleID = "com.apple.loginwindow"

    public enum LifecycleState: String, Sendable, Equatable {
        case stopped
        case starting
        case running
        case stopping
        case degraded
    }

    // MARK: Stored state

    let store: ActivitySpanStore
    let clock = SystemActivityClock()
    let idleThreshold = ActivityWatcher.defaultIdleThreshold
    let lifecycleChanged: (@Sendable (LifecycleState) -> Void)?
    let observationIssue: (@Sendable (String) -> Void)?

    // Guard cross-thread scalars with lock.
    private let lock = Mutex(())
    let captureQueue = DispatchQueue(label: "com.nativeagent.activity-watch", qos: .utility)
    var _stopping = false
    var _stopRequested = false
    var _restartAfterStop = false
    var _lifecycleState: LifecycleState = .stopped
    var _captureEnabled: Bool
    var _policyAvailable = true
    /// Compare incoming changes with the last propagated policy so queued updates cannot restore stale consent.
    var _lastKnownPolicy: ActivityPolicy
    var _installed = false
    var _generation: UInt64 = 0

    var nerveToken: NSObjectProtocol?
    var presenceObserver: NSObjectProtocol?
    var engine: ActivitySpanEngine
    var observedPID: pid_t?
    var tickTimer: DispatchSourceTimer?
    var resumeAfterInputUptime: TimeInterval?
    var screensAsleep = false
    var sessionInactive = false
    var screenLockedByNotification = false
    /// Use a monotonic anchor so wall-clock steps cannot inflate observation time.
    private var spanStartWall: Double = 0
    private var spanStartMono: Double = 0

    enum StoreRequest: Sendable {
        case write(ActivityStoreCommand)
        case purge(bundleID: String, completion: CheckedContinuation<Int, Error>)
        case wipe(completion: CheckedContinuation<Int, Error>)
    }

    var continuation: AsyncStream<StoreRequest>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var drained: DispatchGroup?

    public init(
        store: ActivitySpanStore,
        policy: ActivityPolicy,
        lifecycleChanged: (@Sendable (LifecycleState) -> Void)? = nil,
        observationIssue: (@Sendable (String) -> Void)? = nil
    ) {
        self.store = store
        self.engine = ActivitySpanEngine(policy: policy)
        self._captureEnabled = policy.captureEnabled
        self._lastKnownPolicy = policy
        self.lifecycleChanged = lifecycleChanged
        self.observationIssue = observationIssue
    }

    // MARK: - Lifecycle

    /// Capture requires explicit Trust Center opt-in; policy changes install or remove its sources.
    public var isCaptureEnabled: Bool {
        withLock { _captureEnabled && _policyAvailable }
    }

    /// Derive the indicator from installed, running observers; enabled consent alone does not prove capture.
    public var isCapturing: Bool {
        withLock { _installed && !_stopping && !_stopRequested && _lifecycleState == .running }
    }

    public var lifecycleState: LifecycleState {
        withLock { _lifecycleState }
    }

    /// Suspend startup off the main actor; an unready partial installation remains owned through settlement.
    @discardableResult
    public func startBounded(timeout: TimeInterval = 5) async -> Bool {
        let enabled = withLock { () -> Bool in
            guard !Task.isCancelled, _captureEnabled, _policyAvailable else { return false }
            if _stopping || _stopRequested {
                _restartAfterStop = true
                return false
            }
            return true
        }
        guard enabled else { return withLock { _policyAvailable && !_captureEnabled } }
        guard let (generation, ready) = beginStartInstalled() else {
            return lifecycleState == .running || lifecycleState == .starting
        }
        guard await Self.wait(ready, timeout: timeout) else {
            guard !Task.isCancelled else {
                await stopInstalled(generation: generation)
                return false
            }
            let current = withLock { () -> Bool in
                guard _generation == generation, _installed else { return false }
                _lifecycleState = .degraded
                return true
            }
            guard current else { return false }
            lifecycleChanged?(.degraded)
            await stopInstalled(generation: generation)
            return false
        }
        guard !Task.isCancelled else {
            await stopInstalled(generation: generation)
            return false
        }
        let running = withLock { () -> Bool in
            guard _generation == generation, _installed, !_stopping, !_stopRequested,
                  _lifecycleState == .starting else { return false }
            _lifecycleState = .running
            return true
        }
        if running { lifecycleChanged?(.running) }
        return running
    }

    /// Keep installation private so every entry passes the capture-consent gate.
    @discardableResult
    private func beginStartInstalled() -> (UInt64, DispatchGroup)? {
        let started = withLock { startInstalled() }
        if started != nil { lifecycleChanged?(.starting) }
        return started
    }

    private func startInstalled() -> (UInt64, DispatchGroup)? {
        guard !Task.isCancelled, _captureEnabled, _policyAvailable else {
            return nil
        }
        if _installed || _stopping || _stopRequested {
            if _captureEnabled { _restartAfterStop = true }
            return nil
        }
        _installed = true
        _generation &+= 1
        let generation = _generation
        _lifecycleState = .starting
        let ready = DispatchGroup(), drained = DispatchGroup()
        ready.enter()
        drained.enter()
        self.drained = drained
        // Unbounded buffering preserves every span control command, including opens and closes.
        let (stream, continuation) = AsyncStream<StoreRequest>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation
        let store = self.store
        pumpTask = Task.detached(priority: .utility) { [weak self] in
            var writeFailure: Error?
            for await request in stream {
                switch request {
                case .write(let command):
                    guard writeFailure == nil else { continue }
                    do {
                        try await store.apply(command)
                    } catch {
                        writeFailure = error
                        FileHandle.standardError.write(
                            Data("activity-watch: store write failed: \(error)\n".utf8)
                        )
                        self?.handleStoreFailure()
                    }
                case .purge(let bundleID, let completion):
                    do {
                        if let writeFailure { throw writeFailure }
                        completion.resume(returning: try await store.purge(bundleID: bundleID))
                    } catch {
                        completion.resume(throwing: error)
                    }
                case .wipe(let completion):
                    do {
                        if let writeFailure { throw writeFailure }
                        completion.resume(returning: try await store.wipeAll())
                    } catch {
                        writeFailure = error
                        self?.handleStoreFailure()
                        completion.resume(throwing: error)
                    }
                }
            }
            self?.finishCapture()
            drained.leave()
        }

        captureQueue.async { [self] in
            startCapture()
            ready.leave()
        }
        return (generation, ready)
    }

    public struct StopRequest: Sendable {
        public enum Outcome: String, Sendable, Equatable { case settled, settlementPending }
        public let outcome: Outcome
        public let settlement: Task<Void, Never>?
    }

    /// Bound handoff and settlement waits at five seconds each; pending settlement retains capture ownership.
    public func requestStop() async -> StopRequest {
        let (generation, pump) = withLock {
            _stopRequested = _installed
            _restartAfterStop = false
            return (_generation, pumpTask)
        }
        await stopInstalled(generation: generation)
        let pending = withLock { _installed && _generation == generation }
        return StopRequest(outcome: pending ? .settlementPending : .settled, settlement: pump)
    }

    func stopForPolicyDisable(generation: UInt64) async {
        await stopInstalled(generation: generation)
    }

    private func stopInstalled(generation: UInt64) async {
        let closed = DispatchGroup()
        let retiring = withLock { () -> (DispatchGroup, Bool)? in
            guard _generation == generation, _installed, !_stopping, let drained else { return nil }
            _stopping = true
            let announce = _lifecycleState != .stopping
            _lifecycleState = .stopping
            closed.enter()
            captureQueue.async { [self] in
                feed(.terminate(at: safeNow()))
                stopListeningToBody()
                detachObserver()
                stopTickTimer()
                continuation?.finish()
                closed.leave()
            }
            return (drained, announce)
        }
        guard let (drained, announce) = retiring else { return }
        if announce { lifecycleChanged?(.stopping) }
        _ = await Self.wait(closed, timeout: 5)
        guard await Self.wait(drained, timeout: 5) else {
            let timedOut = withLock { () -> Bool in
                guard _generation == generation, _installed, _stopping else { return false }
                _lifecycleState = .degraded
                return true
            }
            if timedOut { lifecycleChanged?(.degraded) }
            return
        }
    }

    private func finishCapture() {
        let restart = withLock { () -> Bool in
            drained = nil
            continuation = nil
            pumpTask = nil
            _installed = false
            _stopping = false
            _stopRequested = false
            _lifecycleState = .stopped
            let shouldRestart = _restartAfterStop && _captureEnabled && _policyAvailable
            _restartAfterStop = false
            return shouldRestart
        }
        lifecycleChanged?(.stopped)
        if restart {
            Task { [weak self] in _ = await self?.startBounded() }
        }
    }

    private static func wait(_ group: DispatchGroup, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: group.wait(timeout: .now() + max(0, timeout)) == .success)
            }
        }
    }

    func withLock<T: Sendable>(_ body: () -> T) -> T {
        lock.withLock { _ in body() }
    }

    var isStopping: Bool {
        withLock { _stopping || _stopRequested }
    }

    /// Degraded observation retains timer/workspace sources for repair rather than pretending teardown completed.
    func observationUnavailable(_ detail: String) {
        feed(.observationUnavailable)
        detachObserver()
        let changed = withLock { () -> Bool? in
            guard !_stopping, !_stopRequested else { return nil }
            guard _lifecycleState != .degraded else { return false }
            _lifecycleState = .degraded
            return true
        }
        guard let changed else { return }
        if changed { lifecycleChanged?(.degraded) }
        observationIssue?(detail + " Capture will recheck at the next foreground change or 60-second observation tick; until then no new spans are recorded.")
    }

    func observationAvailable() {
        let recovered = withLock { () -> Bool in
            guard !_stopping, !_stopRequested, _lifecycleState == .degraded else { return false }
            _lifecycleState = .running
            return true
        }
        if recovered { lifecycleChanged?(.running) }
    }

    private func handleStoreFailure() {
        let generation = withLock { () -> UInt64? in
            guard _installed, !_stopping, !_stopRequested else { return nil }
            _stopRequested = true
            _restartAfterStop = false
            _lifecycleState = .degraded
            return _generation
        }
        guard let generation else { return }
        lifecycleChanged?(.degraded)
        Task { [weak self] in await self?.stopInstalled(generation: generation) }
    }

    private func startCapture() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        listenToBody()

        let policy = withLock { _lastKnownPolicy }
        emit(engine.updatePolicy(policy, at: safeNow()))
        // Settle abandoned rows at their own last observation before capturing new activity.
        emit(engine.startupReconcile())
        seedFromFrontmostApplication()
    }

    @discardableResult
    func enqueueCapture(_ work: @escaping @Sendable () -> Void) -> (accepted: Bool, drainingPump: Task<Void, Never>?) {
        withLock {
            guard _installed, !_stopping else { return (false, pumpTask) }
            captureQueue.async(execute: work)
            return (true, nil)
        }
    }

    /// Forward events through one state machine and pump so span writes and exclusion purges stay ordered.
    func feed(_ event: ActivityInputEvent) {
        emit(engine.process(event))
    }

    func emit(_ commands: [ActivityStoreCommand]) {
        for command in commands {
            if case .open(let span) = command {
                spanStartWall = span.startedAt
                spanStartMono = clock.monotonicNow()
            }
            continuation?.yield(.write(command))
        }
    }

    // MARK: - Monotonic-safe clock

    /// Monotonic elapsed time excludes sleep and wall-clock steps; the engine
    /// separately clamps out-of-order events.
    func safeNow() -> Double {
        guard let span = engine.openSpan else { return clock.wallNow() }
        let elapsed = max(0, clock.monotonicNow() - spanStartMono)
        return max(span.lastSeenAt, spanStartWall + elapsed)
    }
}

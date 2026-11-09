#if canImport(AppKit)
import AppKit
import ApplicationServices
import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `ActivityWatcher.swift` | `ActivityWatcher`: capture-thread lifecycle and ordered store pump; only the drained pump releases restart ownership |

/// Metadata-only capture drives `ActivitySpanEngine` and forwards its commands
/// verbatim. One dedicated thread owns AX; callbacks never await the store.
/// One serial pump preserves open/touch/close order through thread retirement.
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
    let lock = NSLock()
    var _runLoop: CFRunLoop?
    private var _captureCommandSource: CFRunLoopSource?
    /// Non-nil from installation reservation until capture-thread exit.
    private var _captureBlocks: [@Sendable () -> Void]?
    var _stopping = false
    var _stopRequested = false
    var _restartAfterStop = false
    var _lifecycleState: LifecycleState = .stopped
    /// Cache capture consent for startup because its authoritative engine thread does not exist yet.
    var _captureEnabled: Bool
    var _policyAvailable = true
    /// Compare incoming changes with the last propagated policy so queued updates cannot restore stale consent.
    var _lastKnownPolicy: ActivityPolicy
    var _installed = false
    var _generation: UInt64 = 0

    // Capture-thread-only. Never touched off the capture thread.
    var workspaceObserverTokens: [NSObjectProtocol] = []
    var presenceObserver: NSObjectProtocol?
    var engine: ActivitySpanEngine
    var observer: AXObserver?
    var observerContext: ActivityObserverContext?
    var observedPID: pid_t?
    var tickTimer: CFRunLoopTimer?
    /// Keep the idle-closed timer alive so interaction can reopen capture without an app switch.
    var idleResumeWatch = false
    var screensAsleep = false
    var sessionInactive = false
    var screenLockedByNotification = false
    var lockTokens: [NSObjectProtocol] = []
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
    // Retained until the thread's exit notification and the store drain settle.
    private var captureThread: Thread?
    private var threadExitToken: NSObjectProtocol?
    private let started = NSCondition()
    private var isThreadReady = false
    private var isThreadExited = true
    private var retiredGeneration: UInt64 = 0

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
        lock.lock()
        defer { lock.unlock() }
        return _captureEnabled && _policyAvailable
    }

    /// Derive the indicator from installed, running observers; enabled consent alone does not prove capture.
    public var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _installed && !_stopping && !_stopRequested
            && _lifecycleState == .running
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
        guard let generation = beginStartInstalled() else {
            return lifecycleState == .running || lifecycleState == .starting
        }
        guard await waitForThreadReady(timeout: timeout) else {
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
    private func beginStartInstalled() -> UInt64? {
        lock.lock()
        guard !Task.isCancelled, _captureEnabled, _policyAvailable else {
            lock.unlock()
            return nil
        }
        if _installed || _stopping || _stopRequested {
            if _captureEnabled { _restartAfterStop = true }
            lock.unlock()
            return nil
        }
        _installed = true
        _generation &+= 1
        let generation = _generation
        _lifecycleState = .starting
        _captureBlocks = []
        started.lock()
        isThreadReady = false
        isThreadExited = false
        started.unlock()
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
            self?.finishStoppedThread()
        }

        let thread = Thread { [weak self] in self?.captureThreadMain() }
        thread.name = "com.nativeagent.activity-watch"
        thread.stackSize = 512 * 1024
        captureThread = thread
        threadExitToken = NotificationCenter.default.addObserver(
            forName: .NSThreadWillExit, object: thread, queue: nil
        ) { [self] _ in
            // Close the stream only after capture exit so the pump drains every accepted write.
            withLock { continuation.finish() }
        }
        thread.start()
        lock.unlock()
        lifecycleChanged?(.starting)
        return generation
    }

    public struct StopRequest: Sendable {
        public enum Outcome: String, Sendable, Equatable { case settled, settlementPending }
        public let outcome: Outcome
        /// Retain the pump through physical thread exit; a wedged thread leaves this join pending without a deadline.
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
        let (proceed, announceStopping) = withLock { () -> (Bool, Bool) in
            // Without an installed run loop, a shutdown hop can never be serviced and must not be awaited.
            guard _generation == generation, _installed, !_stopping else { return (false, false) }
            _stopping = true
            let announce = _lifecycleState != .stopping
            _lifecycleState = .stopping
            return (true, announce)
        }
        guard proceed else { return }
        if announceStopping { lifecycleChanged?(.stopping) }

        // Bound a wedged run-loop handoff and resume its continuation exactly once.
        let gate = ContinuationOnce<Void>()
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
            gate.resume(())
        }
        onCaptureThread {
            if self.withLock({ self._generation == generation }) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            gate.resume(())
        }
        await gate.wait()
        watchdog.cancel()

        // Acknowledgement is not exit: return degraded on timeout while the retained pump owns settlement and restart.
        guard await waitForThreadExit(generation: generation, timeout: 5) else {
            let timedOut = withLock { () -> Bool in
                guard _generation == generation, _installed, _stopping else { return false }
                _lifecycleState = .degraded
                return true
            }
            if timedOut { lifecycleChanged?(.degraded) }
            return
        }
    }

    /// Only the pump after thread exit and final write may release installation ownership.
    private func finishStoppedThread() {
        let restart = withLock { () -> Bool in
            if let threadExitToken { NotificationCenter.default.removeObserver(threadExitToken) }
            threadExitToken = nil
            captureThread = nil
            continuation = nil
            pumpTask = nil
            _installed = false
            _runLoop = nil
            _stopping = false
            _stopRequested = false
            _lifecycleState = .stopped
            let shouldRestart = _restartAfterStop && _captureEnabled && _policyAvailable
            _restartAfterStop = false
            started.lock()
            isThreadReady = false
            isThreadExited = true
            retiredGeneration = _generation
            started.broadcast()
            started.unlock()
            return shouldRestart
        }
        lifecycleChanged?(.stopped)
        if restart {
            Task { [weak self] in _ = await self?.startBounded() }
        }
    }

    private func waitForThreadReady(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                self.started.lock()
                defer { self.started.unlock() }
                let deadline = Date().addingTimeInterval(max(0, timeout))
                while !self.isThreadReady, !self.isThreadExited {
                    if !self.started.wait(until: deadline) {
                        continuation.resume(returning: false)
                        return
                    }
                }
                continuation.resume(returning: self.isThreadReady)
            }
        }
    }

    private func waitForThreadExit(generation: UInt64, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: true)
                    return
                }
                self.started.lock()
                defer { self.started.unlock() }
                let deadline = Date().addingTimeInterval(timeout)
                while self.retiredGeneration < generation {
                    if !self.started.wait(until: deadline) {
                        continuation.resume(returning: false)
                        return
                    }
                }
                continuation.resume(returning: true)
            }
        }
    }

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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

    private func transitionLifecycle(to state: LifecycleState) {
        let changed = withLock { () -> Bool in
            guard _lifecycleState != state else { return false }
            _lifecycleState = state
            return true
        }
        if changed { lifecycleChanged?(state) }
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

    // MARK: - Capture thread

    private func captureThreadMain() {
        lock.lock()
        _runLoop = CFRunLoopGetCurrent()
        lock.unlock()

        // Set the system-wide AX timeout; element-local limits cannot bound reads that fetch the next element.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)

        // Keep a signalled command source: AX alone may leave lifecycle blocks queued forever when no source runs.
        var commandSourceContext = CFRunLoopSourceContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil,
            equal: nil,
            hash: nil,
            schedule: nil,
            cancel: nil,
            perform: { info in
                guard let info else { return }
                Unmanaged<ActivityWatcher>.fromOpaque(info)
                    .takeUnretainedValue()
                    .drainCaptureBlocks()
            }
        )
        let commandSource = CFRunLoopSourceCreate(nil, 0, &commandSourceContext)
        lock.lock()
        _captureCommandSource = commandSource
        lock.unlock()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), commandSource, .defaultMode)

        // Serialize source removal with installation so startup-stop cannot remove tokens while they are added.
        installWorkspaceObservers()
        installLockNotificationObservers()

        let policy = withLock { _lastKnownPolicy }
        emit(engine.updatePolicy(policy, at: safeNow()))
        // Settle abandoned rows at their own last observation before capturing new activity.
        emit(engine.startupReconcile())
        seedFromFrontmostApplication()
        drainCaptureBlocks()

        started.lock()
        isThreadReady = true
        started.signal()
        started.unlock()

        // An unowned run-loop exit loses the command spine; degrade and retire instead of spinning without sources.
        if !isStopping {
            CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false)
            if !isStopping { transitionLifecycle(to: .degraded) }
        }

        lock.lock()
        let blocks = _captureBlocks ?? []
        _captureBlocks = nil
        _captureCommandSource = nil
        _runLoop = nil
        lock.unlock()
        // Finish accepted policy/purge work even when Stop skipped the loop.
        for block in blocks { block() }
        // Close the span before acknowledging exit and draining the pump.
        feed(.terminate(at: safeNow()))
        removeWorkspaceObservers()
        detachObserver()
        stopTickTimer()
        // Let thread-exit notification close the pump only after this body returns.
    }

    @discardableResult
    func onCaptureThread(
        _ block: @escaping @Sendable () -> Void
    ) -> (accepted: Bool, drainingPump: Task<Void, Never>?) {
        lock.lock()
        guard _captureBlocks != nil else {
            // Capture rejection and the old pump together so a restart cannot make rejection join a new live pump.
            let pump = pumpTask
            lock.unlock()
            return (false, pump)
        }
        _captureBlocks?.append(block)
        let runLoop = _runLoop
        let source = _captureCommandSource
        lock.unlock()
        if let runLoop, let source {
            CFRunLoopSourceSignal(source)
            CFRunLoopWakeUp(runLoop)
        }
        return (true, nil)
    }

    private func drainCaptureBlocks() {
        lock.lock()
        let blocks = _captureBlocks ?? []
        _captureBlocks?.removeAll(keepingCapacity: true)
        lock.unlock()
        for block in blocks { block() }
    }

    // MARK: - Engine plumbing (capture thread only)

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

#endif

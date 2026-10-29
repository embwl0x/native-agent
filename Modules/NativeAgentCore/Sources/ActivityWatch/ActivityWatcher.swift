#if canImport(AppKit)
import AppKit
import ApplicationServices
import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `ActivityWatcher.swift` | `ActivityWatcher`: capture-thread lifetime, command handoff and ordered store pump; unexpected run-loop return degrades and retires capture; only the drained pump releases installation and pending restart ownership |

/// Metadata-only capture drives `ActivitySpanEngine` and forwards its commands
/// verbatim. One dedicated thread owns AX; callbacks never await the store.
/// One serial pump preserves open/touch/close order through thread retirement.
public final class ActivityWatcher: @unchecked Sendable {
    // MARK: Capture boundaries

    /// Five minutes is a capture boundary, not a UI preference: a smaller
    /// value makes ordinary pauses look like app changes and a larger one
    /// silently overstates every inactive session.
    public static let defaultIdleThreshold: TimeInterval = 300
    static let tickInterval: TimeInterval = 60

    /// Frontmost loginwindow signals lock; plausible AX data cannot open a span.
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
    let ownProcessID = ProcessInfo.processInfo.processIdentifier
    let lifecycleChanged: (@Sendable (LifecycleState) -> Void)?

    // Cross-thread scalars. Guarded by `lock`.
    let lock = NSLock()
    var _runLoop: CFRunLoop?
    private var _captureCommandSource: CFRunLoopSource?
    /// Non-nil from installation reservation until capture-thread exit.
    private var _captureBlocks: [@Sendable () -> Void]?
    var _stopping = false
    var _stopRequested = false
    var _restartAfterStop = false
    var _lifecycleState: LifecycleState = .stopped
    /// Mirror of `policy.captureEnabled`, readable off the capture thread. The
    /// engine owns the authoritative copy; `startBounded()` must decide whether
    /// to create the capture thread BEFORE there is one to ask.
    var _captureEnabled: Bool
    /// The last policy actually pushed through `updatePolicy`. Compared against
    /// incoming policy changes so queued updates use the latest authority.
    var _lastKnownPolicy: ActivityPolicy
    /// Whether the observers/thread/pump are currently installed.
    var _installed = false
    var _generation: UInt64 = 0

    // Capture-thread-only. Never touched off the capture thread.
    var workspaceObserverTokens: [NSObjectProtocol] = []
    var presenceObserver: NSObjectProtocol?
    /// The span state machine.
    var engine: ActivitySpanEngine
    var observer: AXObserver?
    var observerContext: ActivityObserverContext?
    var observedPID: pid_t?
    var tickTimer: CFRunLoopTimer?
    /// The span was closed by the IDLE deadline and the tick timer was kept
    /// running so ordinary interaction can reopen it. Cleared the moment a span
    /// opens again, or when the timer stops for any other reason.
    var idleResumeWatch = false
    var screensAsleep = false
    var sessionInactive = false
    /// Set by `com.apple.screenIsLocked` / cleared by `com.apple.screenIsUnlocked`.
    var screenLockedByNotification = false
    /// Distributed-centre observer tokens (screen lock/unlock).
    var lockTokens: [NSObjectProtocol] = []
    /// Monotonic anchor for `safeNow()`.
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
        lifecycleChanged: (@Sendable (LifecycleState) -> Void)? = nil
    ) {
        self.store = store
        self.engine = ActivitySpanEngine(policy: policy)
        self._captureEnabled = policy.captureEnabled
        self._lastKnownPolicy = policy
        self.lifecycleChanged = lifecycleChanged
    }

    // MARK: - Lifecycle

    /// Capture requires explicit Trust Center opt-in; policy changes install or remove its sources.
    public var isCaptureEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _captureEnabled
    }

    /// True only when the observers are actually installed and running — what
    /// the menu-bar indicator renders. Distinct from `isCaptureEnabled`: an
    /// enabled-but-stopped watcher shows no indicator.
    public var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _installed && !_stopping && !_stopRequested
            && _lifecycleState != .degraded
    }

    public var lifecycleState: LifecycleState {
        withLock { _lifecycleState }
    }

    /// App-facing startup that never parks the main actor on an AX/run-loop
    /// bootstrap. If the capture thread does not acknowledge readiness in time,
    /// the partially installed observers and pump are rolled back.
    @discardableResult
    public func startBounded(timeout: TimeInterval = 5) async -> Bool {
        let enabled = withLock { () -> Bool in
            guard !Task.isCancelled, _captureEnabled else { return false }
            if _stopping || _stopRequested {
                _restartAfterStop = true
                return false
            }
            return true
        }
        guard enabled else { return !isCaptureEnabled }
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

    /// The real installer. Private on purpose: every path into it goes through
    /// the `_captureEnabled` check above, so there is exactly one gate.
    @discardableResult
    private func beginStartInstalled() -> UInt64? {
        lock.lock()
        guard !Task.isCancelled, _captureEnabled else {
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
            // The capture body has returned: no source can enqueue another
            // write. Closing its stream lets the owned pump retire everything.
            withLock { continuation.finish() }
        }
        thread.start()
        lock.unlock()
        lifecycleChanged?(.starting)
        return generation
    }

    /// Closes the open span cleanly, tears the observer down, stops the run
    /// loop, and drains the pump. Never called from the capture thread.
    public func stop() async {
        let (generation, pump) = withLock {
            _stopRequested = true
            _restartAfterStop = false
            return (_generation, pumpTask)
        }
        await stopInstalled(generation: generation)
        // A stop already underway, or a degraded handoff, still owes actual exit.
        await settle { await pump?.value }
    }

    func stopForPolicyDisable(generation: UInt64) async {
        await stopInstalled(generation: generation)
    }

    private func stopInstalled(generation: UInt64) async {
        let (proceed, announceStopping) = withLock { () -> (Bool, Bool) in
            // Nothing installed → nothing to tear down. This is the ordinary
            // case when capture was never enabled, and it must not block on a
            // run-loop hop that will never be serviced (there is no run loop).
            guard _generation == generation, _installed, !_stopping else { return (false, false) }
            _stopping = true
            let announce = _lifecycleState != .stopping
            _lifecycleState = .stopping
            return (true, announce)
        }
        guard proceed else { return }
        if announceStopping { lifecycleChanged?(.stopping) }

        // Bounded handoff: a wedged run loop must not hang shutdown forever, and
        // the continuation must resume exactly once whichever path wins.
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

        // Acknowledgment is not exit. The exit notification closes the stream;
        // only the pump's actual drain releases installation/restart ownership.
        // A timeout returns degraded without creating an indefinite waiter.
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

    /// Called only by the pump after thread exit and its last accepted write.
    private func finishStoppedThread() {
        // Back to the uninstalled state, so a later off→on policy flip can
        // re-install cleanly instead of finding `_installed` stuck true.
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
            let shouldRestart = _restartAfterStop && _captureEnabled
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
        withLock { _stopping || _stopRequested || _lifecycleState == .degraded }
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
            guard _installed, !_stopping, _lifecycleState != .degraded else { return nil }
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

        // PROCESS-GLOBAL AX messaging timeout. Per AXUIElement.h, passing the
        // system-wide element sets it for the whole process; setting it on any
        // other element applies ONLY to that element. Without this the read
        // that *fetches* the next element is itself unbounded.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)

        // A signalled source is both the keepalive and the cross-thread command
        // channel. `CFRunLoopPerformBlock` can remain queued indefinitely when
        // the only other source is AX (or AX is unavailable), leaving lifecycle
        // state at `.running` while workspace/sleep events never reach the
        // engine.
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

        // Installation and removal share the capture thread. A stop requested
        // during startup cannot remove tokens while they are still being added.
        installWorkspaceObservers()
        installLockNotificationObservers()

        let policy = withLock { _lastKnownPolicy }
        emit(engine.updatePolicy(policy, at: safeNow()))
        // Startup reconciliation: spans a prior process left open are closed at
        // their own last_seen_at and marked abandoned.
        emit(engine.startupReconcile())
        seedFromFrontmostApplication()
        drainCaptureBlocks()

        started.lock()
        isThreadReady = true
        started.signal()
        started.unlock()

        // The command source keeps this loop alive even without AX. Returning
        // without an owned stop means that spine is lost: degrade and retire,
        // rather than re-entering a sourceless loop every 10 ms forever.
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
        // Close before exit is acknowledged and the pump drains.
        feed(.terminate(at: safeNow()))
        removeWorkspaceObservers()
        detachObserver()
        stopTickTimer()
        // NSThreadWillExit closes the pump after this body returns.
    }

    @discardableResult
    func onCaptureThread(
        _ block: @escaping @Sendable () -> Void
    ) -> (accepted: Bool, drainingPump: Task<Void, Never>?) {
        lock.lock()
        guard _captureBlocks != nil else {
            // Decide and capture the old pump together; a restart must not
            // make a rejected request join the new, still-running pump.
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

    /// Push one event into the shared state machine and forward what it wants
    /// written. Span writes and live exclusion purges share the same pump.
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

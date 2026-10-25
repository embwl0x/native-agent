#if canImport(AppKit)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacControl
import PersistenceCore
// Blueprint: | `ActivityWatcher.swift` | `ActivityWatcher`; capture-thread sources and ordered store pump; presence reads `MacPersonInput.presence`, capture idle-close remains separate and idle-resume reads `MacPersonInput.sessionIdleAfterAgentMotor` in every permission state without asserting presence; unexpected run-loop return degrades and retires capture; only the drained pump releases installation and pending restart ownership |

/// Platform notifications translated before they enter the capture thread.
public enum ActivityWorkspaceEvent: Sendable {
    case activate(bundleId: String?, appName: String?, pid: pid_t?)
    case terminate(pid: pid_t?)
    case sleep
    case wake
    case sessionResignedActive
    case sessionBecameActive
}

/// The live capture spine — metadata only, zero inference.
///
/// **It owns no span logic.** Every span decision lives in `ActivitySpanEngine`,
/// which this class drives with `ActivityInputEvent`s and whose
/// `ActivityStoreCommand`s it forwards verbatim to `ActivitySpanStore.apply`.
/// What DOES live here: threading, AX, and the platform signals.
///
///  1. A dedicated `Thread` with its own `CFRunLoop` owns every `AXUIElement`
///     and `AXObserver`. AX types never leave that thread.
///  2. The AX callback does its reads, builds immutable `Sendable` commands,
///     and hands them off **without ever awaiting** the store actor or GRDB. The
///     P0 spike measured a 21.9 ms AX read tail; a blocking wait in the callback
///     would stall the run loop by exactly that much.
///  3. A single serial pump task drains the command stream into
///     `ActivitySpanStore`. AsyncStream preserves ordering, so open→touch→close
///     can never be applied out of order (a bare `Task { }` per command could).
public final class ActivityWatcher: @unchecked Sendable {
    // MARK: Capture boundaries

    /// Five minutes is a capture boundary, not a UI preference: a smaller
    /// value makes ordinary pauses look like app changes and a larger one
    /// silently overstates every inactive session.
    public static let defaultIdleThreshold: TimeInterval = 300
    static let tickInterval: TimeInterval = 60

    /// A frontmost reading of loginwindow is a LOCK SIGNAL, never a span.
    /// While locked, AX still answers and returns the bare app name — data that
    /// looks completely real (P0 blocker finding).
    public static let loginWindowBundleID = "com.apple.loginwindow"

    public enum LifecycleState: String, Sendable, Equatable {
        case stopped
        case starting
        case running
        case stopping
        case degraded
    }

    // MARK: Stored state

    private let store: ActivitySpanStore
    private let clock = SystemActivityClock()
    private let idleThreshold = ActivityWatcher.defaultIdleThreshold
    private let ownProcessID = ProcessInfo.processInfo.processIdentifier
    private let lifecycleChanged: (@Sendable (LifecycleState) -> Void)?
    private let presenceTransitionURL: URL

    // Cross-thread scalars. Guarded by `lock`.
    private let lock = NSLock()
    private var _runLoop: CFRunLoop?
    private var _captureCommandSource: CFRunLoopSource?
    /// Non-nil from installation reservation until capture-thread exit.
    private var _captureBlocks: [@Sendable () -> Void]?
    private var _stopping = false
    private var _stopRequested = false
    private var _restartAfterStop = false
    private var _lifecycleState: LifecycleState = .stopped
    /// Mirror of `policy.captureEnabled`, readable off the capture thread. The
    /// engine owns the authoritative copy; `startBounded()` must decide whether
    /// to create the capture thread BEFORE there is one to ask.
    private var _captureEnabled: Bool
    /// The last policy actually pushed through `updatePolicy`. Compared against
    /// incoming policy changes so queued updates use the latest authority.
    private var _lastKnownPolicy: ActivityPolicy
    /// Whether the observers/thread/pump are currently installed.
    private var _installed = false
    private var _generation: UInt64 = 0

    // Capture-thread-only. Never touched off the capture thread.
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var presenceObserver: NSObjectProtocol?
    /// The span state machine.
    private var engine: ActivitySpanEngine
    private var observer: AXObserver?
    private var observerContext: ActivityObserverContext?
    private var observedPID: pid_t?
    private var tickTimer: CFRunLoopTimer?
    /// The span was closed by the IDLE deadline and the tick timer was kept
    /// running so ordinary interaction can reopen it. Cleared the moment a span
    /// opens again, or when the timer stops for any other reason.
    private var idleResumeWatch = false
    /// Last present/away conclusion actually published, or nil before the first
    /// one. Only a CHANGE touches the transition file the scheduler watches.
    private var lastPublishedPresence: Bool?
    /// The tick watches presence crossings without a span, AX observer, or
    /// title. Set when the frontmost app is privacy-excluded, this
    /// process, or unidentifiable — states where the person is still at the Mac
    /// but nothing may be recorded about what they are doing.
    private var presenceOnlyWatch = false
    private var screensAsleep = false
    private var sessionInactive = false
    /// Set by `com.apple.screenIsLocked` / cleared by `com.apple.screenIsUnlocked`.
    private var screenLockedByNotification = false
    /// Distributed-centre observer tokens (screen lock/unlock).
    private var lockTokens: [NSObjectProtocol] = []
    /// Monotonic anchor for `safeNow()`.
    private var spanStartWall: Double = 0
    private var spanStartMono: Double = 0

    private enum StoreRequest: Sendable {
        case write(ActivityStoreCommand)
        case purge(bundleID: String, completion: CheckedContinuation<Int, Error>)
    }

    private var continuation: AsyncStream<StoreRequest>.Continuation?
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
        presenceTransitionURL: URL
    ) {
        self.store = store
        self.engine = ActivitySpanEngine(policy: policy)
        self._captureEnabled = policy.captureEnabled
        self._lastKnownPolicy = policy
        self.lifecycleChanged = lifecycleChanged
        self.presenceTransitionURL = presenceTransitionURL
    }

    // MARK: - Lifecycle

    /// THE RUNTIME CAPTURE FENCE (W8, 2026-08-14).
    ///
    /// v0 was fenced at COMPILE time — the target did not exist unless an env
    /// var said so. That fence is gone now that the feature ships in-app, and
    /// this is what replaces it. The guarantee is: **capture cannot run unless
    /// the Trust Center toggle is explicitly enabled**, and it is structural
    /// rather than conventional in three specific ways.
    ///
    ///  1. `startBounded()` returns having installed NOTHING when the policy says
    ///     off — no `AXObserver`, no `NSWorkspace` observer, no distributed
    ///     lock observer, no capture thread, no run loop, no pump. There is no
    ///     later `if` to forget: the machinery does not exist to be triggered.
    ///  2. `updatePolicy(_:)` re-evaluates on every transition. Off→on installs
    ///     the whole apparatus; on→off tears it down and closes the open span,
    ///     which is what makes a Trust Center flip an INSTANT pause instead of
    ///     a restart-scoped one.
    ///  3. The controller keeps capture off when the policy is missing or
    ///     unavailable. A fresh
    ///     install captures nothing without a deliberate click.
    ///
    /// `ActivitySpanEngine` independently refuses to open a span while
    /// `captureEnabled` is false (`shouldCapture` → `policy.allowsCapture`), so
    /// even a hypothetical event injected into a running engine after a policy
    /// flip produces no row. Belt AND braces: this class controls whether the
    /// event sources exist, the engine controls whether an event can become a
    /// row, and the two are tested separately.
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
        // UNBOUNDED, deliberately (gpt-5.5 BLOCKING, 2026-08-14). These are
        // span *control* commands (open/touch/close), not a high-rate event
        // firehose: they arrive at human app-switch rate. `bufferingNewest`
        // silently DROPS, and dropping a `.close` leaks an open row while
        // dropping an `.open` turns every later touch/close into a no-op —
        // which breaks the every-open-has-a-close invariant AND corrupts the
        // one number the probe exists to produce.
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
        let generation = withLock {
            _stopRequested = true
            _restartAfterStop = false
            return _generation
        }
        await stopInstalled(generation: generation)
    }

    private func stopForPolicyDisable(generation: UInt64) async {
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
        let gate = OneShotGate()
        var watchdog: Task<Void, Never>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            watchdog = Task {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                if gate.claim() { continuation.resume() }
            }
            onCaptureThread {
                if self.withLock({ self._generation == generation }) {
                    CFRunLoopStop(CFRunLoopGetCurrent())
                }
                if gate.claim() { continuation.resume() }
            }
        }
        watchdog?.cancel()

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

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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

    /// Swap the privacy policy while running (the user edited exclusions, or
    /// flipped the master toggle in Trust Center).
    ///
    /// This is the SECOND half of the runtime fence, and the half that makes
    /// "instant pause" true rather than aspirational. The master switch is read
    /// on every call, so:
    ///   * **on → off** closes the open span and tears the observers down NOW.
    ///     Not on the next tick, not at the next launch. Nothing further can be
    ///     recorded because the event sources are gone.
    ///   * **off → on** installs the apparatus for the first time, so the user
    ///     does not have to restart the app after granting.
    ///   * **on → on** is the ordinary exclusion-list edit: handed to the engine
    ///     on the capture thread so it is never mutated under a concurrent
    ///     event, and the engine emits the retro-close commands itself.
    ///
    /// `stop()` is awaited on a detached task rather than inline because this
    /// is called from the UI: a Trust Center toggle must not block the main
    /// thread on a run-loop handoff.
    public func updatePolicy(_ policy: ActivityPolicy) {
        lock.lock()
        let wasEnabled = _captureEnabled
        _captureEnabled = policy.captureEnabled
        _lastKnownPolicy = policy
        let installed = _installed
        let generation = _generation
        var announceStopping = false
        if policy.captureEnabled {
            if _stopping || _stopRequested { _restartAfterStop = true }
        } else {
            _stopRequested = installed
            _restartAfterStop = false
            if installed, _lifecycleState != .stopping {
                _lifecycleState = .stopping
                announceStopping = true
            }
        }
        let stopPending = _stopping || _stopRequested
        lock.unlock()
        if announceStopping { lifecycleChanged?(.stopping) }

        switch (wasEnabled || installed, policy.captureEnabled) {
        case (_, false):
            // OFF. Push the policy into the engine first so the open span is
            // closed under a policy that forbids capture (the engine's
            // updatePolicy emits the close), then remove every event source.
            if installed {
                applyPolicyOnCaptureThread()
                Task { [weak self] in await self?.stopForPolicyDisable(generation: generation) }
            }
        case (false, true):
            // ON, from cold. Startup reads the latest policy on its own thread
            // before the first activation.
            if stopPending {
                applyPolicyOnCaptureThread()
            } else {
                Task { [weak self] in _ = await self?.startBounded() }
            }
        case (true, true):
            if installed {
                applyPolicyOnCaptureThread()
            } else {
                Task { [weak self] in _ = await self?.startBounded() }
            }
        }
    }

    /// External file changes may only tighten the current capture policy.
    static func safelyPolled(
        _ polled: ActivityPolicy, current: ActivityPolicy, currentlyEnabled: Bool
    ) -> ActivityPolicy? {
        // Disabling is always allowed, whatever else the file says.
        guard polled.captureEnabled else { return polled }
        // An out-of-band write may never ENABLE capture. Only the Trust Center
        // path (a direct `updatePolicy`) can do that.
        guard currentlyEnabled, current.captureEnabled else { return nil }

        var safe = polled
        safe.captureEnabled = true
        // Never drop below the exclusions already in force.
        safe.excludedBundleIDs = polled.excludedBundleIDs.union(current.excludedBundleIDs)
        // false → true is loosening, so it is refused; true → false is tightening.
        safe.captureTitles = polled.captureTitles && current.captureTitles
        safe.browserTitlesEnabled = polled.browserTitlesEnabled && current.browserTitlesEnabled
        // Model-provider access is a separate explicit consent. A file change
        // can turn it off, never on.
        safe.allowModelAccess = polled.allowModelAccess && current.allowModelAccess
        // The one flag whose TRUE is the private setting: it can only go on.
        safe.appNameOnlyMode = polled.appNameOnlyMode || current.appNameOnlyMode
        // Keeping data for longer is loosening; keeping it for less is not.
        safe.retentionDays = min(polled.retentionDays, current.retentionDays)
        return safe
    }

    private func applyPolicyOnCaptureThread() {
        let apply: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            // A queued UI update must not restore a superseded policy.
            let policy = self.withLock { self._lastKnownPolicy }
            self.emit(self.engine.updatePolicy(policy, at: self.safeNow()))
        }
        let runLoop = withLock { _runLoop }
        if let runLoop, CFRunLoopGetCurrent() === runLoop { apply() }
        else { onCaptureThread(apply) }
    }

    /// Apply the exclusion before placing its purge behind every older write.
    /// The controller holds its policy-mutation slot until this completes.
    public func purgeExcluded(bundleID: String) async throws -> Int {
        try await withCheckedThrowingContinuation { completion in
            let handoff = onCaptureThread {
                let policy = self.withLock { self._lastKnownPolicy }
                self.emit(self.engine.updatePolicy(policy, at: self.safeNow()))
                self.continuation?.yield(.purge(bundleID: bundleID, completion: completion))
            }
            if handoff.accepted { return }

            // No capture thread can enqueue more writes. Join any old pump
            // before purging directly, including during shutdown's drain.
            Task {
                await handoff.drainingPump?.value
                do { completion.resume(returning: try await store.purge(bundleID: bundleID)) }
                catch { completion.resume(throwing: error) }
            }
        }
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
    private func onCaptureThread(
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
    private func feed(_ event: ActivityInputEvent) {
        emit(engine.process(event))
    }

    private func emit(_ commands: [ActivityStoreCommand]) {
        for command in commands {
            if case .open(let span) = command {
                spanStartWall = span.startedAt
                spanStartMono = clock.monotonicNow()
            }
            continuation?.yield(.write(command))
        }
    }

    // MARK: - Workspace notifications

    private func installWorkspaceObservers() {
        presenceObserver = NotificationCenter.default.addObserver(
            forName: MacPersonInput.presenceChanged, object: nil, queue: nil
        ) { [weak self] _ in
            self?.onCaptureThread { [weak self] in self?.publishPresence() }
        }
        let handler: @Sendable (ActivityWorkspaceEvent) -> Void = { [weak self] event in
            self?.onCaptureThread { [weak self] in self?.handleWorkspaceEvent(event) }
        }
        let center = NSWorkspace.shared.notificationCenter
        var tokens: [NSObjectProtocol] = []
        tokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            handler(.activate(bundleId: app?.bundleIdentifier, appName: app?.localizedName,
                              pid: app?.processIdentifier))
        })
        tokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            handler(.terminate(pid: app?.processIdentifier))
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in handler(.sleep) })
        }
        tokens.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil
        ) { _ in handler(.wake) })
        tokens.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil
        ) { _ in handler(.sessionResignedActive) })
        tokens.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil
        ) { _ in handler(.sessionBecameActive) })
        workspaceObserverTokens = tokens
    }

    private func handleWorkspaceEvent(_ event: ActivityWorkspaceEvent) {
        switch event {
        case let .activate(bundleId, appName, pid):
            handleActivation(bundleId: bundleId, appName: appName, pid: pid)
        case let .terminate(pid):
            handleTermination(pid: pid)
        case .sleep:
            guard !screensAsleep else { return }
            screensAsleep = true
            feed(.sleep(at: safeNow()))
            standDownCapture()
        case .wake:
            guard screensAsleep else { return }
            screensAsleep = false
            feed(.wake(at: safeNow()))
            publishPresence()
            seedFromFrontmostApplication()
        case .sessionResignedActive:
            sessionInactive = true
            feed(.lock(at: safeNow()))
            standDownCapture()
        case .sessionBecameActive:
            sessionInactive = false
            feed(.unlock(at: safeNow()))
            publishPresence()
            seedFromFrontmostApplication()
        }
    }

    /// The screen-lock signal proper (gpt-5.5 BLOCKING, 2026-08-14).
    ///
    /// `NSWorkspace` session/sleep notifications do NOT fire for a plain
    /// screen lock, and the `loginwindow`-frontmost heuristic only flips once
    /// the window server has actually swapped the frontmost app — a window in
    /// which AX still answers with the placeholder data that motivated this
    /// gate. `com.apple.screenIsLocked` is the real edge and it arrives on the
    /// DISTRIBUTED centre, not the workspace centre. Still reconciled rather
    /// than trusted: this only ever *adds* a reason to believe we are locked.
    private func installLockNotificationObservers() {
        let center = DistributedNotificationCenter.default()
        lockTokens.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil
        ) { [weak self] _ in
            self?.onCaptureThread { [weak self] in
                guard let self else { return }
                self.screenLockedByNotification = true
                self.feed(.lock(at: self.safeNow()))
                self.standDownCapture()
            }
        })
        lockTokens.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
        ) { [weak self] _ in
            self?.onCaptureThread { [weak self] in
                guard let self else { return }
                self.screenLockedByNotification = false
                self.feed(.unlock(at: self.safeNow()))
                self.publishPresence()
                // Re-read; never assume unlocked just because a note said so.
                self.seedFromFrontmostApplication()
            }
        })
    }

    private func removeWorkspaceObservers() {
        if let presenceObserver { NotificationCenter.default.removeObserver(presenceObserver) }
        presenceObserver = nil
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObserverTokens { center.removeObserver(token) }
        workspaceObserverTokens = []
        let distributed = DistributedNotificationCenter.default()
        for token in lockTokens { distributed.removeObserver(token) }
        lockTokens = []
    }

    // MARK: - Lock reconciliation

    /// Lock state is RECONCILED, never trusted from a notification alone: read
    /// it on start, on wake, on every tick, and before every span open. A missed
    /// notification must degrade to "no span", never to "a confident wrong span".
    private func reconcileLocked() -> Bool {
        if screensAsleep || sessionInactive || screenLockedByNotification {
            return true
        }
        let front = NSWorkspace.shared.frontmostApplication
        return Self.isLockSignal(
            bundleId: front?.bundleIdentifier,
            localizedName: front?.localizedName
        )
    }

    /// Pure predicate so the lock gate is testable without a locked screen.
    public static func isLockSignal(bundleId: String?, localizedName: String?) -> Bool {
        if let bundleId, bundleId == loginWindowBundleID { return true }
        if let localizedName, localizedName.lowercased() == "loginwindow" { return true }
        // No frontmost app at all is not a licence to guess.
        return bundleId == nil && localizedName == nil
    }

    private var isStopping: Bool {
        withLock { _stopping || _stopRequested || _lifecycleState == .degraded }
    }

    // MARK: - Span handling (capture thread)

    private func seedFromFrontmostApplication() {
        if reconcileLocked() {
            feed(.lock(at: safeNow()))
            standDownCapture()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        handleActivation(
            bundleId: front?.bundleIdentifier,
            appName: front?.localizedName,
            pid: front?.processIdentifier
        )
    }

    private func handleActivation(bundleId: String?, appName: String?, pid: pid_t?) {
        // RUNTIME FENCE, RE-CHECKED AT THE EVENT (gpt-5.5 BLOCKING, 2026-08-14).
        //
        // `updatePolicy` flips `_captureEnabled` under the lock immediately, but
        // it only ENQUEUES the engine's policy swap onto this run loop. An
        // activation already sitting in the queue ahead of that swap would run
        // against the stale engine policy, pass `shouldCapture`, and open a span
        // AFTER the Trust Center toggle was already persisted off — which is
        // exactly the guarantee the toggle is supposed to make. Reading the
        // lock-guarded flag here closes the window regardless of queue order.
        //
        guard isCaptureEnabled else { return }
        guard !isStopping else { return }

        // An activation immediately following NativeAgent's own bounded motor
        // epoch is agent-driven provenance, not evidence that the person chose
        // this app. Close any human span and record nothing for this edge.
        guard !NativeAgentMotorEpoch.isAgentDriven() else {
            feed(.activate(
                bundleId: ActivityPolicy.selfProcessBundleID,
                appName: "agent-driven",
                at: safeNow()
            ))
            detachObserver()
            // Keep observing presence without attributing the agent's input
            // to the human or recording the excluded app.
            enterPresenceOnlyWatch()
            // Observe without opening a span. The first later AX event outside
            // the bounded motor epoch is evidence the human took over this app;
            // it will seed a fresh human span below. This avoids permanently
            // losing the app until the next app switch.
            if let pid, pid != ownProcessID { attachObserver(pid: pid) }
            return
        }

        // Lock gate FIRST — while locked AX answers with plausible garbage.
        let locked = Self.isLockSignal(bundleId: bundleId, localizedName: appName) || reconcileLocked()
        if locked {
            feed(.lock(at: safeNow()))
            standDownCapture()
            return
        }

        // An unknown frontmost is a GAP, not "the previous app is still there"
        // (gpt-5.5 IMPORTANT, 2026-08-14). Returning early used to leave the
        // prior span open, so a transient/bundle-less process silently
        // MISATTRIBUTED its dwell time to whatever the human was in before it.
        guard let bundleId, let pid else {
            feed(.activate(
                bundleId: ActivityPolicy.selfProcessBundleID, appName: "unknown", at: safeNow()
            ))
            detachObserver()
            enterPresenceOnlyWatch()
            return
        }

        // NON-OVERRIDABLE: never this probe's own process, whatever the policy
        // says. `ActivityPolicy` handles bundle ids; only we know our pid.
        guard pid != ownProcessID else {
            feed(.activate(
                bundleId: ActivityPolicy.selfProcessBundleID, appName: "self", at: safeNow()
            ))
            detachObserver()
            enterPresenceOnlyWatch()
            return
        }

        // CAPTURE-TIME EXCLUSION, BEFORE ANY AX READ. An excluded app's title is
        // never read — not read-and-discarded. `.activate` on an excluded bundle
        // closes whatever was open and opens nothing.
        guard engine.shouldCapture(bundleID: bundleId) else {
            feed(.activate(bundleId: bundleId, appName: appName ?? bundleId, at: safeNow()))
            detachObserver()
            enterPresenceOnlyWatch()
            return
        }

        if engine.openSpan?.bundleId == bundleId, observedPID == pid {
            feed(.focusEvent(at: safeNow()))
            return
        }

        detachObserver()

        // Span FIRST, observer second: a lagging or failed AX attach must not
        // become a capture blind spot (W1 condition on cutting the LRU).
        feed(.activate(bundleId: bundleId, appName: appName ?? bundleId, at: clock.wallNow()))

        // A span is open again: the timer is a heartbeat once more, not the
        // idle-resume or presence-only watch.
        idleResumeWatch = false
        presenceOnlyWatch = false
        startTickTimer()
        attachObserver(pid: pid)

        // Only NOW, with the span already open, is a title read attempted — and
        // only if policy allows it for this specific app.
        captureTitleIfAllowed(pid: pid, bundleID: bundleId)
    }

    private func handleTermination(pid: pid_t?) {
        guard let pid, pid == observedPID else { return }
        feed(.terminate(at: safeNow()))
        detachObserver()
        stopTickTimer()
    }

    /// One processed AX event. Runs on the capture thread (run-loop source);
    /// never awaits the actor.
    fileprivate func handleAXEvent(notification: String) {
        guard !isStopping else { return }
        // AX notifications caused by our own click/type/set-value must not be
        // counted as human focus events. A later physical app activation or AX
        // event outside the bounded motor epoch resumes ordinary attribution.
        guard !NativeAgentMotorEpoch.isAgentDriven() else { return }
        if engine.openSpan == nil {
            seedFromFrontmostApplication()
            return
        }
        // RUNTIME FENCE, RE-CHECKED AT THE EVENT (gpt-5.5 BLOCKING, 2026-08-14).
        //
        // `updatePolicy` flips `_captureEnabled` under the lock immediately, but
        // it only ENQUEUES the engine's policy swap onto this run loop. An
        // activation already sitting in the queue ahead of that swap would run
        // against the stale engine policy, pass `shouldCapture`, and open a span
        // AFTER the Trust Center toggle was already persisted off — which is
        // exactly the guarantee the toggle is supposed to make. Reading the
        // lock-guarded flag here closes the window regardless of queue order.
        guard isCaptureEnabled else { return }
        if reconcileLocked() {
            feed(.lock(at: safeNow()))
            detachObserver()
            stopTickTimer()
            return
        }
        guard let bundleID = engine.openSpan?.bundleId, let pid = observedPID else { return }

        // A title-bearing notification only turns into a title read when policy
        // allows it. Otherwise it is recorded as a bare focus event: the human
        // did something, and we say so without saying what.
        if notification == kAXTitleChangedNotification as String
            || notification == kAXFocusedWindowChangedNotification as String,
           engine.shouldReadTitle(bundleID: bundleID) {
            captureTitleIfAllowed(pid: pid, bundleID: bundleID)
            return
        }
        feed(.focusEvent(at: safeNow()))
    }

    /// The ONLY place a window title is read. Gated twice — policy first, then
    /// the redactor — and the raw string never leaves this function.
    private func captureTitleIfAllowed(pid: pid_t, bundleID: String) {
        guard engine.shouldReadTitle(bundleID: bundleID) else { return }
        // RE-CHECK THE LOCK IMMEDIATELY BEFORE THE AX READ (gpt-5.5 BLOCKING,
        // 2026-08-14). The caller's `reconcileLocked()` happened earlier in the
        // callback; a lock landing in between is a real TOCTOU, and the whole
        // point of the P0 finding is that AX keeps answering while locked with
        // placeholder text that looks completely real. Without this, a lock in
        // that gap writes a plausible windowChange span nobody can tell is junk.
        guard !reconcileLocked() else {
            feed(.lock(at: safeNow()))
            detachObserver()
            stopTickTimer()
            return
        }
        // RE-CHECK THE CAPTURE FENCE IMMEDIATELY BEFORE THE AX READ (gpt-5.5
        // IMPORTANT, 2026-08-14). The caller passed
        // `isCaptureEnabled` earlier in the callback; an out-of-band or Trust
        // Center disable landing in the gap between that check and this read is
        // a real TOCTOU, and this is the LAST instruction before the read. The
        // lock re-check above exists for exactly the same reason — a disable in
        // that window must cost a title read, not just a row.
        guard isCaptureEnabled else { return }
        let raw = Self.frontmostWindowTitle(pid: pid)
        // `raw` is handed straight to the engine, which redacts it before it can
        // reach a span. It is never logged, never stored, never returned.
        feed(.titleChange(raw: raw, at: safeNow()))
    }

    /// Reads `kAXTitle` off the focused window. NEVER `kAXValue`, for any role —
    /// that rule is categorical, not conditional on what the element is.
    private static func frontmostWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var windowRef: CFTypeRef?
        let windowErr = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef
        )
        guard windowErr == .success, let windowRef else { return nil }
        // The app may die mid-read; `.invalidUIElement` / `.cannotComplete`
        // return nil here rather than throwing the capture thread off course.
        guard CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(windowRef, to: AXUIElement.self)

        var titleRef: CFTypeRef?
        let titleErr = AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef
        )
        guard titleErr == .success, let title = titleRef as? String else { return nil }
        return title
    }

    // MARK: - The one timer, three jobs

    private func startTickTimer() {
        guard tickTimer == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            nil,
            CFAbsoluteTimeGetCurrent() + Self.tickInterval,
            Self.tickInterval,
            0,
            0
        ) { [weak self] _ in
            self?.onTick()
        }
        tickTimer = timer
        if let timer {
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
        }
    }

    private func stopTickTimer() {
        idleResumeWatch = false
        presenceOnlyWatch = false
        guard let timer = tickTimer else { return }
        CFRunLoopTimerInvalidate(timer)
        tickTimer = nil
    }

    private func onTick() {
        guard !isStopping else { return }

        guard isCaptureEnabled else { return }

        // (3) reconcile lock state — a missed notification self-heals in <= 60 s.
        if reconcileLocked() {
            feed(.lock(at: safeNow()))
            standDownCapture()
            return
        }
        // (2.5) publish presence crossings. Deliberately BEFORE the
        // open-span branch: while the person is away the span is closed, and
        // that is exactly the state the trigger scheduler most needs described.
        publishPresence()

        guard let span = engine.openSpan else {
            // 2026-09-06: the idle close used to take the AX observer AND this
            // timer with it, so nothing was left that could notice the human
            // coming back. Typing in the SAME app produced no activation
            // notification and no AX callback (the observer was gone), so the
            // watcher stayed dark until the next app switch. The timer is kept
            // as the low-rate resume observer instead: fresh input reopens the
            // span through the ordinary activation path, which re-attaches the
            // observer and re-applies every policy and lock gate.
            guard idleResumeWatch || presenceOnlyWatch else {
                stopTickTimer()
                return
            }
            // Presence-only: the crossing above is the whole job. Nothing here may
            // seed a span — the frontmost app is one this watcher is not
            // allowed to record, and re-seeding would only re-derive that.
            guard !presenceOnlyWatch else { return }
            // Capture starts without Input Monitoring and must resume without
            // it too. Session activity after our motor output reopens capture;
            // only publishPresence() carries the canonical presence fact.
            guard let idle = MacPersonInput.sessionIdleAfterAgentMotor(),
                  idle <= idleThreshold else { return }
            idleResumeWatch = false
            seedFromFrontmostApplication()
            return
        }

        // (2) idle deadline. This call is a READ, not an event source, which is
        // why a timer has to own the deadline.
        let idle = idleSecondsSinceLastInput()
        let now = safeNow()
        if let closeAt = Self.idleCloseTimestamp(
            spanStartedAt: span.startedAt,
            now: now,
            secondsSinceLastInput: idle,
            threshold: idleThreshold
        ) {
            feed(.idle(at: closeAt))
            detachObserver()
            // The timer stays: it is now the only thing that can see the human
            // return to an app that was never switched away from.
            idleResumeWatch = true
            return
        }

        // (1) advance last_seen_at. Heartbeat only — it must NOT bump
        // event_count, or the events/hour number is fiction.
        feed(.heartbeat(at: now))
    }

    /// Publish only changed conclusions to the scheduler's watched file.
    private func publish(present: Bool, at now: Double) {
        guard lastPublishedPresence != present else { return }
        // 2026-09-06: `lastPublishedPresence` used to advance BEFORE this write
        // and the write's result was discarded, so ONE failed transition write
        // lost the crossing permanently — every later tick saw "nothing
        // changed", the trigger scheduler's event loop was never woken, and it
        // waited up to six hours for the integrity tick. The marker now moves
        // only on a write that actually landed, so the next tick retries.
        guard HumanPresenceStamp.writeTransition(
            present: present,
            at: Date(timeIntervalSince1970: now),
            to: presenceTransitionURL
        ) else {
            FileHandle.standardError.write(Data((
                "ActivityWatcher: presence transition write failed (present=\(present)); "
                    + "holding the crossing so the next tick retries\n"
            ).utf8))
            return
        }
        lastPublishedPresence = present
    }

    /// Capture boundaries do not decide whether the person is here.
    private func standDownCapture() {
        publishPresence()
        detachObserver()
        stopTickTimer()
    }

    /// Publish the person fact; unknown leaves the last known transition alone.
    private func publishPresence() {
        let now = clock.wallNow()
        guard now.isFinite, let fact = MacPersonInput.presence() else { return }
        publish(present: fact.here, at: now)
    }

    /// Excluded apps still need present/away crossings, without app metadata.
    private func enterPresenceOnlyWatch() {
        idleResumeWatch = false
        presenceOnlyWatch = true
        startTickTimer()
    }

    private func idleSecondsSinceLastInput() -> Double {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null
        )
    }

    /// The timer's temporal decision, factored only so the exact same boundary
    /// can be driven without a window server. The watcher remains the sole
    /// caller in production; this function deliberately does no I/O or state
    /// mutation and cannot create an independent capture path.
    static func idleCloseTimestamp(
        spanStartedAt: Double,
        now: Double,
        secondsSinceLastInput: Double,
        threshold: TimeInterval
    ) -> Double? {
        guard now.isFinite, secondsSinceLastInput.isFinite,
              secondsSinceLastInput > threshold else { return nil }
        return min(max(spanStartedAt, now - secondsSinceLastInput), now)
    }

    // MARK: - AX observer (capture thread only)

    private func attachObserver(pid: pid_t) {
        var created: AXObserver?
        let createErr = AXObserverCreate(pid, activityAXObserverCallback, &created)
        guard createErr == .success, let created else { return }

        let appElement = AXUIElementCreateApplication(pid)
        // Belt-and-braces; the global timeout set at startup is the real gate.
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        let context = ActivityObserverContext(watcher: self, pid: pid)
        let refcon = Unmanaged.passUnretained(context).toOpaque()

        // NEVER kAXValueChangedNotification — that is per-keystroke.
        let notifications = [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXTitleChangedNotification,
        ]
        for notification in notifications {
            let err = AXObserverAddNotification(created, appElement, notification as CFString, refcon)
            switch err {
            case .success, .notificationAlreadyRegistered:
                continue
            case .invalidUIElement, .cannotComplete:
                // The target app may die mid-registration. Close and bail —
                // never leave a half-attached observer behind.
                feed(.terminate(at: safeNow()))
                stopTickTimer()
                return
            default:
                continue
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(created),
            .defaultMode
        )
        observer = created
        observerContext = context
        observedPID = pid
    }

    private func detachObserver() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observer = nil
        observerContext = nil
        observedPID = nil
    }

    // MARK: - Monotonic-safe clock

    /// Wall-clock "now" that a clock change or a sleep cannot inflate.
    ///
    /// Elapsed is measured monotonically (which does NOT advance across sleep),
    /// so an 8-hour sleep cannot turn into an 8-hour span, and a backwards NTP
    /// step cannot rewind an open span's timestamps. The engine clamps again on
    /// top of this — belt and braces, because these are two different failure
    /// modes (a lying clock here, out-of-order handoff there).
    private func safeNow() -> Double {
        guard let span = engine.openSpan else { return clock.wallNow() }
        let elapsed = max(0, clock.monotonicNow() - spanStartMono)
        return max(span.lastSeenAt, spanStartWall + elapsed)
    }
}

// MARK: - AX callback plumbing

/// Resume-exactly-once guard for a continuation with two possible resumers.
final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Refcon box for the C callback. Held strongly by the watcher for exactly as
/// long as the observer is attached.
final class ActivityObserverContext {
    weak var watcher: ActivityWatcher?
    let pid: pid_t

    init(watcher: ActivityWatcher, pid: pid_t) {
        self.watcher = watcher
        self.pid = pid
    }
}

/// Fires on the capture thread's run loop. No AX element escapes; no await.
private let activityAXObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let context = Unmanaged<ActivityObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    context.watcher?.handleAXEvent(notification: notification as String)
}
#endif

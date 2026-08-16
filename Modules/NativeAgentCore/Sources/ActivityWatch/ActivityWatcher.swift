#if canImport(AppKit)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacControl

/// The live capture spine — metadata only, zero inference.
///
/// **It owns no span logic.** Every span decision lives in `ActivitySpanEngine`,
/// which this class drives with `ActivityInputEvent`s and whose
/// `ActivityStoreCommand`s it forwards verbatim to `ActivitySpanStore.apply`.
/// That is deliberate and it is the whole verification story: the machine this
/// was built on has a locked screen, so the live path cannot be exercised —
/// but `activity-probe simulate` drives the SAME engine through the SAME store,
/// so what the simulation proves, the live path inherits. A parallel copy of the
/// state machine here would make every simulation test worthless.
///
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
    // MARK: Tunables

    /// Kept as a static for source compatibility; the authority is
    /// `ActivityPolicy.alwaysExcludedBundleIDs`, which cannot be overridden.
    public static var nativeAgentBundleIDs: Set<String> {
        ActivityPolicy.alwaysExcludedBundleIDs.subtracting([loginWindowBundleID])
    }

    /// A frontmost reading of loginwindow is a LOCK SIGNAL, never a span.
    /// While locked, AX still answers and returns the bare app name — data that
    /// looks completely real (P0 blocker finding).
    public static let loginWindowBundleID = "com.apple.loginwindow"

    public struct Status: Sendable {
        public var spansOpened: Int
        public var eventsRecorded: Int
        public var titlesCaptured: Int
        public var currentApp: String?
        public var isPaused: Bool
        public var isLocked: Bool
    }

    public enum LifecycleState: String, Sendable, Equatable {
        case stopped
        case starting
        case running
        case stopping
        case degraded
    }

    // MARK: Stored state

    private let store: ActivitySpanStore
    private let clock: ActivityClock
    private let idleThreshold: TimeInterval
    private let heartbeatInterval: TimeInterval
    private let ownProcessID: pid_t
    /// Out-of-band policy changes (W-live-fix, 2026-08-14). `nil` means this
    /// watcher watches no file — the default, which keeps every existing
    /// caller, test and simulation constructing exactly what it did before.
    private let policySource: (any ActivityPolicySource)?
    private let lifecycleChanged: (@Sendable (LifecycleState) -> Void)?
    private let policyChanged: (@Sendable (ActivityPolicy) -> Void)?

    // Cross-thread scalars. Guarded by `lock`.
    private let lock = NSLock()
    private var _runLoop: CFRunLoop?
    private var _paused = false
    private var _stopping = false
    private var _stopRequested = false
    private var _restartAfterStop = false
    private var _lifecycleState: LifecycleState = .stopped
    /// Mirror of `policy.captureEnabled`, readable off the capture thread. The
    /// engine owns the authoritative copy; this exists because `start()` has to
    /// decide whether to create the capture thread BEFORE there is one to ask.
    private var _captureEnabled: Bool
    /// The last policy actually pushed through `updatePolicy`. Compared against
    /// what the policy source hands back so an unchanged (or merely re-saved)
    /// policy file does not churn the engine once a minute.
    private var _lastKnownPolicy: ActivityPolicy
    /// Whether the observers/thread/pump are currently installed.
    private var _installed = false
    private var _spansOpened = 0
    private var _eventsRecorded = 0
    private var _titlesCaptured = 0
    private var _currentApp: String?
    private var _lockedFlag = false
    private var _observerTokens: [NSObjectProtocol] = []

    // Capture-thread-only. Never touched off the capture thread.
    /// THE state machine. Same type the simulator drives.
    private var engine: ActivitySpanEngine
    private var observer: AXObserver?
    private var observerContext: ActivityObserverContext?
    private var observedPID: pid_t?
    private var tickTimer: CFRunLoopTimer?
    private var screensAsleep = false
    private var sessionInactive = false
    /// Set by `com.apple.screenIsLocked` / cleared by `com.apple.screenIsUnlocked`.
    private var screenLockedByNotification = false
    /// Distributed-centre observer tokens (screen lock/unlock).
    private var lockTokens: [NSObjectProtocol] = []
    /// Monotonic anchor for `safeNow()`.
    private var spanStartWall: Double = 0
    private var spanStartMono: Double = 0

    private var continuation: AsyncStream<ActivityStoreCommand>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private let started = NSCondition()
    private var isThreadReady = false
    private var isThreadExited = true

    public init(
        store: ActivitySpanStore,
        policy: ActivityPolicy = ActivityPolicy(),
        clock: ActivityClock = SystemActivityClock(),
        idleThreshold: TimeInterval = 300,
        heartbeatInterval: TimeInterval = 60,
        policySource: (any ActivityPolicySource)? = nil,
        lifecycleChanged: (@Sendable (LifecycleState) -> Void)? = nil,
        policyChanged: (@Sendable (ActivityPolicy) -> Void)? = nil
    ) {
        self.store = store
        self.clock = clock
        self.engine = ActivitySpanEngine(policy: policy)
        self._captureEnabled = policy.captureEnabled
        self._lastKnownPolicy = policy
        self.idleThreshold = idleThreshold
        self.heartbeatInterval = heartbeatInterval
        self.ownProcessID = ProcessInfo.processInfo.processIdentifier
        self.policySource = policySource
        self.lifecycleChanged = lifecycleChanged
        self.policyChanged = policyChanged
        // The caller passed us the policy it just loaded off disk; priming here
        // stops the first poll from re-applying that identical policy.
        (policySource as? ActivityPolicyFileSource)?.prime()
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
    ///  1. `start()` returns having installed NOTHING when the policy says
    ///     off — no `AXObserver`, no `NSWorkspace` observer, no distributed
    ///     lock observer, no capture thread, no run loop, no pump. There is no
    ///     later `if` to forget: the machinery does not exist to be triggered.
    ///  2. `updatePolicy(_:)` re-evaluates on every transition. Off→on installs
    ///     the whole apparatus; on→off tears it down and closes the open span,
    ///     which is what makes a Trust Center flip an INSTANT pause instead of
    ///     a restart-scoped one.
    ///  3. The default is off, and `ActivityPolicyStore.load()` maps a missing
    ///     OR unreadable OR garbage policy file to the safe default. A fresh
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
    /// enabled-but-paused watcher shows no indicator, because it is recording
    /// nothing.
    public var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _installed && !_paused && !_stopping && !_stopRequested
            && _lifecycleState != .degraded
    }

    public var lifecycleState: LifecycleState {
        withLock { _lifecycleState }
    }

    /// Starts the pump, the capture thread, and the workspace observers —
    /// **unless the policy says capture is off**, in which case this installs
    /// nothing at all and returns immediately. See `isCaptureEnabled`.
    public func start() {
        let enabled = withLock { () -> Bool in
            guard _captureEnabled else { return false }
            if _stopping || _stopRequested {
                _restartAfterStop = true
                return false
            }
            return true
        }
        guard enabled else {
            // REFUSED. No observer, no thread, no span, no pump. The caller is
            // free to call `start()` unconditionally at launch; the policy is
            // what decides, and it decides here rather than in five callers.
            return
        }
        guard beginStartInstalled() else { return }
        started.lock()
        while !isThreadReady { started.wait() }
        started.unlock()
        transitionLifecycle(to: .running)
    }

    /// App-facing startup that never parks the main actor on an AX/run-loop
    /// bootstrap. If the capture thread does not acknowledge readiness in time,
    /// the partially installed observers and pump are rolled back.
    @discardableResult
    public func startBounded(timeout: TimeInterval = 5) async -> Bool {
        let enabled = withLock { () -> Bool in
            guard _captureEnabled else { return false }
            if _stopping || _stopRequested {
                _restartAfterStop = true
                return false
            }
            return true
        }
        guard enabled else { return !isCaptureEnabled }
        guard beginStartInstalled() else {
            return lifecycleState == .running || lifecycleState == .starting
        }
        guard await waitForThreadReady(timeout: timeout) else {
            transitionLifecycle(to: .degraded)
            await stop()
            return false
        }
        transitionLifecycle(to: .running)
        return true
    }

    /// The real installer. Private on purpose: every path into it goes through
    /// the `_captureEnabled` check above, so there is exactly one gate.
    @discardableResult
    private func beginStartInstalled() -> Bool {
        lock.lock()
        if _installed || _stopping || _stopRequested {
            if _captureEnabled { _restartAfterStop = true }
            lock.unlock()
            return false
        }
        _installed = true
        _lifecycleState = .starting
        lock.unlock()
        started.lock()
        isThreadReady = false
        isThreadExited = false
        started.unlock()
        lifecycleChanged?(.starting)
        // UNBOUNDED, deliberately (gpt-5.5 BLOCKING, 2026-08-14). These are
        // span *control* commands (open/touch/close), not a high-rate event
        // firehose: they arrive at human app-switch rate. `bufferingNewest`
        // silently DROPS, and dropping a `.close` leaks an open row while
        // dropping an `.open` turns every later touch/close into a no-op —
        // which breaks the every-open-has-a-close invariant AND corrupts the
        // one number the probe exists to produce.
        let (stream, continuation) = AsyncStream<ActivityStoreCommand>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation
        let store = self.store
        pumpTask = Task.detached(priority: .utility) { [weak self] in
            for await command in stream {
                do {
                    try await store.apply(command)
                } catch {
                    FileHandle.standardError.write(
                        Data("activity-watch: store write failed: \(error)\n".utf8)
                    )
                    self?.handleStoreFailure()
                    break
                }
            }
        }

        installWorkspaceObservers()
        installLockNotificationObservers()

        let thread = Thread { [weak self] in self?.captureThreadMain() }
        thread.name = "com.nativeagent.activity-watch"
        thread.stackSize = 512 * 1024
        thread.start()
        return true
    }

    /// Closes the open span cleanly, tears the observer down, stops the run
    /// loop, and drains the pump. Never called from the capture thread.
    public func stop() async {
        withLock {
            _stopRequested = true
            _restartAfterStop = false
        }
        await stopInstalled()
    }

    private func stopForPolicyDisable() async {
        await stopInstalled()
    }

    private func stopInstalled() async {
        let (proceed, announceStopping) = withLock { () -> (Bool, Bool) in
            // Nothing installed → nothing to tear down. This is the ordinary
            // case when capture was never enabled, and it must not block on a
            // run-loop hop that will never be serviced (there is no run loop).
            guard _installed, !_stopping else { return (false, false) }
            _stopping = true
            let announce = _lifecycleState != .stopping
            _lifecycleState = .stopping
            return (true, announce)
        }
        guard proceed else { return }
        if announceStopping { lifecycleChanged?(.stopping) }

        removeWorkspaceObservers()

        // Bounded handoff: a wedged run loop must not hang shutdown forever, and
        // the continuation must resume exactly once whichever path wins.
        let gate = OneShotGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            onCaptureThread { [weak self] in
                if let self {
                    self.feed(.terminate(at: self.safeNow()))
                    self.detachObserver()
                    self.stopTickTimer()
                }
                CFRunLoopStop(CFRunLoopGetCurrent())
                if gate.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if gate.claim() { continuation.resume() }
            }
        }

        // The run-loop block acknowledging CFRunLoopStop is not the same thing
        // as the capture thread having exited. Do not clear installed state or
        // permit a restart until the old thread confirms its actual exit.
        guard await waitForThreadExit(timeout: 5) else {
            transitionLifecycle(to: .degraded)
            Task { [weak self] in
                guard let self else { return }
                _ = await self.waitForThreadExit(timeout: nil)
                await self.finishStoppedThread()
            }
            return
        }
        await finishStoppedThread()
    }

    private func finishStoppedThread() async {
        self.continuation?.finish()
        self.continuation = nil
        await pumpTask?.value
        pumpTask = nil

        // Back to the uninstalled state, so a later off→on policy flip can
        // re-install cleanly instead of finding `_installed` stuck true.
        let restart = withLock { () -> Bool in
            _installed = false
            _runLoop = nil
            _stopping = false
            _stopRequested = false
            _currentApp = nil
            _lifecycleState = .stopped
            let shouldRestart = _restartAfterStop && _captureEnabled
            _restartAfterStop = false
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

    private func waitForThreadExit(timeout: TimeInterval?) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: true)
                    return
                }
                self.started.lock()
                defer { self.started.unlock() }
                if let timeout {
                    let deadline = Date().addingTimeInterval(timeout)
                    while !self.isThreadExited {
                        if !self.started.wait(until: deadline) {
                            continuation.resume(returning: false)
                            return
                        }
                    }
                } else {
                    while !self.isThreadExited { self.started.wait() }
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
        let shouldStop = withLock { () -> Bool in
            guard !_stopping, _lifecycleState != .degraded else { return false }
            _lifecycleState = .degraded
            return true
        }
        guard shouldStop else { return }
        lifecycleChanged?(.degraded)
        Task { [weak self] in await self?.stop() }
    }

    public func pause() {
        lock.lock()
        let wasPaused = _paused
        _paused = true
        lock.unlock()
        guard !wasPaused else { return }
        onCaptureThread { [weak self] in
            guard let self else { return }
            self.feed(.terminate(at: self.safeNow()))
            self.detachObserver()
            self.stopTickTimer()
        }
    }

    public func resume() {
        lock.lock()
        let wasPaused = _paused
        _paused = false
        lock.unlock()
        guard wasPaused else { return }
        onCaptureThread { [weak self] in
            self?.seedFromFrontmostApplication()
        }
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
        policyChanged?(policy)

        switch (wasEnabled || installed, policy.captureEnabled) {
        case (_, false):
            // OFF. Push the policy into the engine first so the open span is
            // closed under a policy that forbids capture (the engine's
            // updatePolicy emits the close), then remove every event source.
            if installed {
                onCaptureThread { [weak self] in
                    guard let self else { return }
                    let commands = self.engine.updatePolicy(policy, at: self.safeNow())
                    self.emit(commands)
                }
                Task { [weak self] in await self?.stopForPolicyDisable() }
            } else {
                applyPolicyToEngineDirectly(policy)
            }
        case (false, true):
            // ON, from cold. Seed the engine before the observers exist so the
            // first activation is evaluated against the new policy.
            if stopPending {
                onCaptureThread { [weak self] in
                    guard let self else { return }
                    let commands = self.engine.updatePolicy(policy, at: self.safeNow())
                    self.emit(commands)
                }
            } else {
                applyPolicyToEngineDirectly(policy)
                Task { [weak self] in _ = await self?.startBounded() }
            }
        case (true, true):
            if installed {
                onCaptureThread { [weak self] in
                    guard let self else { return }
                    let commands = self.engine.updatePolicy(policy, at: self.safeNow())
                    self.emit(commands)
                }
            } else {
                applyPolicyToEngineDirectly(policy)
                Task { [weak self] in _ = await self?.startBounded() }
            }
        }
    }

    /// Re-read the policy FILE and apply it if it changed out of band.
    ///
    /// THE THIRD HALF OF THE RUNTIME FENCE (live-run defect, 2026-08-14).
    /// `updatePolicy` makes the in-app Trust Center toggle an instant pause, but
    /// it is only reached when something in THIS process calls it. A running
    /// watcher was blind to every other writer of `activity_policy.json`: a live
    /// run disabled capture with `activity-probe policy --disable` and the
    /// watcher kept recording, adding 4 more rows over the next 40 seconds.
    ///
    /// **Worst-case bound: an out-of-band disable takes effect within one tick**
    /// (`heartbeatInterval`, 60 s by default), or at the next app activation,
    /// whichever lands first. It cannot be worse than that: the tick fires
    /// while a span is open, and the activation path is the only way a span can
    /// be opened when no tick timer is running.
    ///
    /// Cost per call is one `stat`. The JSON is decoded only when the file's
    /// modification date or size actually moved — see `ActivityPolicyFileSource`.
    ///
    /// THE POLL IS A SAFETY VALVE, NOT A CONTROL CHANNEL (gpt-5.5 BLOCKING,
    /// 2026-08-14). It can only ever make capture LESS permissive.
    ///
    /// `ActivityPolicy`'s decoder defaults every missing key, deliberately, so
    /// an older build's file still loads. The consequence is that a TORN or
    /// partial external write — `{"captureEnabled":true}` landing mid-rewrite,
    /// or a hand edit, or any process that is not the Trust Center — decodes as
    /// a perfectly valid ENABLED policy with default exclusions. Applying that
    /// verbatim would let a file nobody deliberately wrote turn capture on and
    /// simultaneously drop every exclusion the user had added. So the polled
    /// policy is passed through `safelyPolled` first, and:
    ///
    ///   * `captureEnabled == false` applies verbatim — disabling is always
    ///     allowed and always safe, and it is the direction the poll exists for;
    ///   * `captureEnabled == true` on a currently-DISABLED watcher is IGNORED
    ///     outright. Turning capture on is a deliberate, user-driven act and it
    ///     goes through the in-app Trust Center path (`updatePolicy` called
    ///     directly), which no file write can impersonate;
    ///   * on → on applies the rest, but never loosens privacy: exclusions are
    ///     UNIONED with the current set (the poll cannot un-exclude an app),
    ///     `captureTitles` / `browserTitlesEnabled` can only go true→false,
    ///     `appNameOnlyMode` can only go false→true, and `retentionDays` can
    ///     only shrink. Tightening in every direction; loosening in none.
    ///
    /// The cost of the asymmetry is stated plainly: an out-of-band ENABLE, or a
    /// legitimate out-of-band widening (the user re-enabling titles by editing
    /// the file), needs the in-app path or a restart. That is the correct trade
    /// — being late to loosen is an inconvenience, being early to loosen is a
    /// privacy defect.
    ///
    /// STATED LIMIT, in the same direction: an out-of-band disable is not picked
    /// up by a fully STOPPED watcher either, because both poll sites live on the
    /// capture thread and a stopped watcher has neither a tick timer nor an
    /// observer — but a stopped watcher is recording nothing anyway.
    ///
    /// `@discardableResult` and public so the out-of-band path is testable
    /// headlessly, with no window server and no wall-clock minute to wait for.
    @discardableResult
    public func pollPolicySource() -> Bool {
        guard let policySource else { return false }
        guard let polled = policySource.reloadIfChanged() else { return false }
        let (current, enabled) = withLock { (_lastKnownPolicy, _captureEnabled) }
        guard let safe = Self.safelyPolled(polled, current: current, currentlyEnabled: enabled)
        else { return false }
        guard safe != current else { return false }
        updatePolicy(safe)
        return true
    }

    /// The one-way clamp behind `pollPolicySource`. `nil` means "this polled
    /// policy may not be applied at all". Static and internal so the asymmetry
    /// is testable directly, without a running capture thread.
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
        // Model-provider access is a separate explicit consent. A file poll
        // can turn it off, never on.
        safe.allowModelAccess = polled.allowModelAccess && current.allowModelAccess
        // The one flag whose TRUE is the private setting: it can only go on.
        safe.appNameOnlyMode = polled.appNameOnlyMode || current.appNameOnlyMode
        // Keeping data for longer is loosening; keeping it for less is not.
        safe.retentionDays = min(polled.retentionDays, current.retentionDays)
        return safe
    }

    /// Policy swap with no capture thread to hop onto. Safe because in this
    /// state nothing else touches the engine: there are no observers, no timer
    /// and no run loop, which is precisely the condition for taking this path.
    private func applyPolicyToEngineDirectly(_ policy: ActivityPolicy) {
        let commands = engine.updatePolicy(policy, at: clock.wallNow())
        emit(commands)
    }

    public func status() -> Status {
        lock.lock()
        defer { lock.unlock() }
        return Status(
            spansOpened: _spansOpened,
            eventsRecorded: _eventsRecorded,
            titlesCaptured: _titlesCaptured,
            currentApp: _currentApp,
            isPaused: _paused,
            isLocked: _lockedFlag
        )
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

        // A port source that is never signalled keeps CFRunLoopRun from
        // returning immediately for want of any input source.
        let keepAlive = CFRunLoopSourceCreate(nil, 0, &Self.noopSourceContext)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .defaultMode)

        // Startup reconciliation: spans a prior process left open are closed at
        // their own last_seen_at and marked abandoned.
        emit(engine.startupReconcile())
        seedFromFrontmostApplication()

        started.lock()
        isThreadReady = true
        started.signal()
        started.unlock()

        CFRunLoopRun()

        detachObserver()
        stopTickTimer()
        started.lock()
        isThreadReady = false
        isThreadExited = true
        started.broadcast()
        started.unlock()
    }

    private func onCaptureThread(_ block: @escaping @Sendable () -> Void) {
        lock.lock()
        let runLoop = _runLoop
        lock.unlock()
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private nonisolated(unsafe) static var noopSourceContext = CFRunLoopSourceContext(
        version: 0, info: nil, retain: nil, release: nil, copyDescription: nil,
        equal: nil, hash: nil, schedule: nil, cancel: nil, perform: { _ in }
    )

    // MARK: - Engine plumbing (capture thread only)

    /// Push one event into the shared state machine and forward what it wants
    /// written. THE ONLY WAY this class writes anything.
    private func feed(_ event: ActivityInputEvent) {
        emit(engine.process(event))
    }

    private func emit(_ commands: [ActivityStoreCommand]) {
        guard !commands.isEmpty else { return }
        var opened = 0
        var events = 0
        var titles = 0
        var current: String??
        for command in commands {
            switch command {
            case .open(let span):
                opened += 1
                current = .some(span.appName)
                if span.titleRedacted != nil { titles += 1 }
                spanStartWall = span.startedAt
                spanStartMono = clock.monotonicNow()
            case .touch:
                events += 1
            case .retitle(_, let title, _):
                // The store counts a retitle as an event (a title arriving is
                // evidence the human did something), so the in-memory counter
                // has to agree or `status()` drifts from the database.
                events += 1
                if title != nil { titles += 1 }
            case .close:
                current = .some(nil)
            case .heartbeat, .reconcileAbandoned:
                break
            }
            continuation?.yield(command)
        }
        lock.lock()
        _spansOpened += opened
        _eventsRecorded += events
        _titlesCaptured += titles
        if let current { _currentApp = current }
        lock.unlock()
    }

    // MARK: - Workspace notifications

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        var tokens: [NSObjectProtocol] = []

        tokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            // Snapshot bundle id + name SYNCHRONOUSLY here, before anything can
            // lag: an activation must produce a span even if observer attach
            // later fails (W1 condition on cutting the observer cache).
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleId = app?.bundleIdentifier
            let name = app?.localizedName
            let pid = app?.processIdentifier
            self?.onCaptureThread { [weak self] in
                self?.handleActivation(bundleId: bundleId, appName: name, pid: pid)
            }
        })

        tokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            self?.onCaptureThread { [weak self] in
                self?.handleTermination(pid: pid)
            }
        })

        tokens.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.onCaptureThread { [weak self] in
                guard let self else { return }
                self.screensAsleep = true
                self.feed(.sleep(at: self.safeNow()))
                self.detachObserver()
                self.stopTickTimer()
                self.publishLocked(true)
            }
        })

        tokens.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.onCaptureThread { [weak self] in
                guard let self else { return }
                self.screensAsleep = false
                self.feed(.wake(at: self.safeNow()))
                // Wake is exactly where a notification-trusting design lies to
                // itself: re-read the state, never assume unlocked.
                self.seedFromFrontmostApplication()
            }
        })

        tokens.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.onCaptureThread { [weak self] in
                guard let self else { return }
                self.sessionInactive = true
                self.feed(.lock(at: self.safeNow()))
                self.detachObserver()
                self.stopTickTimer()
                self.publishLocked(true)
            }
        })

        tokens.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.onCaptureThread { [weak self] in
                guard let self else { return }
                self.sessionInactive = false
                self.feed(.unlock(at: self.safeNow()))
                self.seedFromFrontmostApplication()
            }
        })

        lock.lock()
        _observerTokens = tokens
        lock.unlock()
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
                self.detachObserver()
                self.stopTickTimer()
                self.publishLocked(true)
            }
        })
        lockTokens.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
        ) { [weak self] _ in
            self?.onCaptureThread { [weak self] in
                guard let self else { return }
                self.screenLockedByNotification = false
                self.feed(.unlock(at: self.safeNow()))
                // Re-read; never assume unlocked just because a note said so.
                self.seedFromFrontmostApplication()
            }
        })
    }

    private func removeWorkspaceObservers() {
        lock.lock()
        let tokens = _observerTokens
        _observerTokens = []
        lock.unlock()
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
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
            publishLocked(true)
            return true
        }
        let front = NSWorkspace.shared.frontmostApplication
        let locked = Self.isLockSignal(
            bundleId: front?.bundleIdentifier,
            localizedName: front?.localizedName
        )
        publishLocked(locked)
        return locked
    }

    /// Pure predicate so the lock gate is testable without a locked screen.
    public static func isLockSignal(bundleId: String?, localizedName: String?) -> Bool {
        if let bundleId, bundleId == loginWindowBundleID { return true }
        if let localizedName, localizedName.lowercased() == "loginwindow" { return true }
        // No frontmost app at all is not a licence to guess.
        return bundleId == nil && localizedName == nil
    }

    private func publishLocked(_ locked: Bool) {
        lock.lock()
        _lockedFlag = locked
        if locked { _currentApp = nil }
        lock.unlock()
    }

    private var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _paused
    }

    private var isStopping: Bool {
        withLock { _stopping || _stopRequested }
    }

    // MARK: - Span handling (capture thread)

    private func seedFromFrontmostApplication() {
        guard !isPaused else { return }
        if reconcileLocked() {
            feed(.lock(at: safeNow()))
            detachObserver()
            stopTickTimer()
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
        // Polled FIRST so an out-of-band disable cannot be beaten by an app
        // switch: without this, a watcher whose tick timer had stopped (idle,
        // lock, terminated app) would open a fresh span here — under a policy
        // that says off on disk — and only notice a whole tick later.
        pollPolicySource()
        guard isCaptureEnabled else { return }
        guard !isStopping else { return }
        guard !isPaused else { return }

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
            stopTickTimer()
            // Observe without opening a span. The first later AX event outside
            // the bounded motor epoch is evidence the human took over this app;
            // it will seed a fresh human span below. This avoids permanently
            // losing the app until the next app switch.
            if let pid, pid != ownProcessID { attachObserver(pid: pid) }
            return
        }

        // Lock gate FIRST — while locked AX answers with plausible garbage.
        if Self.isLockSignal(bundleId: bundleId, localizedName: appName) || reconcileLocked() {
            feed(.lock(at: safeNow()))
            detachObserver()
            stopTickTimer()
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
            stopTickTimer()
            return
        }

        // NON-OVERRIDABLE: never this probe's own process, whatever the policy
        // says. `ActivityPolicy` handles bundle ids; only we know our pid.
        guard pid != ownProcessID else {
            feed(.activate(
                bundleId: ActivityPolicy.selfProcessBundleID, appName: "self", at: safeNow()
            ))
            detachObserver()
            stopTickTimer()
            return
        }

        // CAPTURE-TIME EXCLUSION, BEFORE ANY AX READ. An excluded app's title is
        // never read — not read-and-discarded. `.activate` on an excluded bundle
        // closes whatever was open and opens nothing.
        guard engine.shouldCapture(bundleID: bundleId) else {
            feed(.activate(bundleId: bundleId, appName: appName ?? bundleId, at: safeNow()))
            detachObserver()
            stopTickTimer()
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
        guard !isPaused else { return }
        guard !isStopping else { return }
        // AX notifications caused by our own click/type/set-value must not be
        // counted as human focus events. A later physical app activation or AX
        // event outside the bounded motor epoch resumes ordinary attribution.
        guard !NativeAgentMotorEpoch.isAgentDriven() else { return }
        if engine.openSpan == nil {
            seedFromFrontmostApplication()
            return
        }
        // RECONCILE THE POLICY AT EVERY WRITE SITE (second pass, 2026-08-14).
        //
        // The poll already ran at span-OPEN (handleActivation) and on the tick,
        // so an out-of-band disable could never let a NEW span start. But the
        // touch path is also a write: without this, the span that was already
        // open kept accumulating events and last_seen_at for up to a full 60 s
        // tick after the user's disable landed on disk. Polling here makes the
        // rule uniform — every place the engine can write to the store
        // reconciles the policy first — and it is cheap: a stat is ~1 µs against
        // the 63 µs AX read this callback is about to do anyway, and the JSON is
        // only decoded when the file's stamp actually moves.
        pollPolicySource()
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
        // IMPORTANT, 2026-08-14). The caller polled the policy source and passed
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
        let interval = heartbeatInterval
        let timer = CFRunLoopTimerCreateWithHandler(
            nil,
            CFAbsoluteTimeGetCurrent() + interval,
            interval,
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
        guard let timer = tickTimer else { return }
        CFRunLoopTimerInvalidate(timer)
        tickTimer = nil
    }

    private func onTick() {
        guard !isPaused else { return }
        guard !isStopping else { return }

        // (4) re-read the policy file. An out-of-band disable (the probe CLI,
        // a second process, a hand edit, a restore) is otherwise invisible to a
        // watcher that is already running. One `stat`; decodes only on change.
        if pollPolicySource(), !isCaptureEnabled {
            // Capture just went off. `updatePolicy` has already enqueued the
            // engine close and the teardown; nothing further belongs on this
            // tick, least of all a heartbeat that would extend the row.
            return
        }

        // (3) reconcile lock state — a missed notification self-heals in <= 60 s.
        if reconcileLocked() {
            feed(.lock(at: safeNow()))
            detachObserver()
            stopTickTimer()
            return
        }
        guard let span = engine.openSpan else {
            stopTickTimer()
            return
        }

        // (2) idle deadline. This call is a READ, not an event source, which is
        // why a timer has to own the deadline.
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: Self.anyInputEventType
        )
        let now = safeNow()
        if idle > idleThreshold {
            let closeAt = min(max(span.startedAt, now - idle), now)
            feed(.idle(at: closeAt))
            detachObserver()
            stopTickTimer()
            return
        }

        // (1) advance last_seen_at. Heartbeat only — it must NOT bump
        // event_count, or the events/hour number is fiction.
        feed(.heartbeat(at: now))
    }

    private static let anyInputEventType = CGEventType(rawValue: ~0) ?? .null

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

#if canImport(AppKit)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacControl
import NativeAgentCore
// Blueprint: | `ActivityWatcher+Foreground.swift` | The same watcher's workspace/lock observation, foreground activation, AX attachment and title reads; policy/title exclusions and motor provenance; one heartbeat/idle timer; canonical person-here events and sampled session activity resume capture without asserting presence; AX callback context lives with its observer |

/// Platform notifications translated before they enter the capture thread.
public enum ActivityWorkspaceEvent: Sendable {
    case activate(bundleId: String?, appName: String?, pid: pid_t?)
    case terminate(pid: pid_t?)
    case sleep
    case wake
    case sessionResignedActive
    case sessionBecameActive
}

extension ActivityWatcher {
    // MARK: - Workspace notifications

    func installWorkspaceObservers() {
        presenceObserver = NotificationCenter.default.addObserver(
            forName: MacPersonInput.presenceChanged, object: nil, queue: nil
        ) { [weak self] _ in
            self?.onCaptureThread { [weak self] in
                guard let self else { return }
                if self.idleResumeWatch, MacPersonInput.presence()?.here == true {
                    self.idleResumeWatch = false
                    self.seedFromFrontmostApplication()
                }
            }
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
            seedFromFrontmostApplication()
        case .sessionResignedActive:
            sessionInactive = true
            feed(.lock(at: safeNow()))
            standDownCapture()
        case .sessionBecameActive:
            sessionInactive = false
            feed(.unlock(at: safeNow()))
            seedFromFrontmostApplication()
        }
    }

    /// Distributed lock notifications supplement workspace signals; unlocks require reconciliation.
    func installLockNotificationObservers() {
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
                // Re-read; never assume unlocked just because a note said so.
                self.seedFromFrontmostApplication()
            }
        })
    }

    func removeWorkspaceObservers() {
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

    /// A missing frontmost identity is treated as locked.
    public static func isLockSignal(bundleId: String?, localizedName: String?) -> Bool {
        if let bundleId, bundleId == loginWindowBundleID { return true }
        if let localizedName, localizedName.lowercased() == "loginwindow" { return true }
        // No frontmost app at all is not a licence to guess.
        return bundleId == nil && localizedName == nil
    }

    // MARK: - Span handling (capture thread)

    func seedFromFrontmostApplication() {
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
        // Check the current capture flag because the engine's policy update is queued.
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
            stopTickTimer()
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

        // Unknown, self and excluded identities close the prior span and leave
        // a gap. Refuse them before any AX read, regardless of policy overrides.
        guard let bundleId, let pid, pid != ownProcessID,
              engine.shouldCapture(bundleID: bundleId) else {
            feed(.activate(
                bundleId: ActivityPolicy.selfProcessBundleID, appName: "excluded", at: safeNow()
            ))
            standDownCapture()
            return
        }

        if engine.openSpan?.bundleId == bundleId, observedPID == pid {
            feed(.focusEvent(at: safeNow()))
            return
        }

        detachObserver()

        // Open the span before attaching its observer so attachment cannot delay capture.
        feed(.activate(bundleId: bundleId, appName: appName ?? bundleId, at: clock.wallNow()))

        // A span is open again: the timer is a heartbeat once more.
        idleResumeWatch = false
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
        // Check the current capture flag because the engine's policy update is queued.
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
        // Recheck lock state before reading AX; locked AX titles can look valid.
        guard !reconcileLocked() else {
            feed(.lock(at: safeNow()))
            detachObserver()
            stopTickTimer()
            return
        }
        // Recheck capture immediately before AX so disabling also prevents the title read.
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

    func stopTickTimer() {
        idleResumeWatch = false
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
        guard let span = engine.openSpan else {
            // Fresh input resumes the same app through normal activation and its policy gates.
            guard idleResumeWatch else {
                stopTickTimer()
                return
            }
            // Capture starts without Input Monitoring and must resume without
            // it too. Session activity after our motor output reopens capture;
            // MacPersonInput alone owns the canonical presence fact.
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

    /// Capture boundaries do not decide whether the person is here.
    private func standDownCapture() {
        detachObserver()
        stopTickTimer()
    }

    private func idleSecondsSinceLastInput() -> Double {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null
        )
    }

    /// Clamp the idle boundary to the open span without I/O or state mutation.
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

    func detachObserver() {
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

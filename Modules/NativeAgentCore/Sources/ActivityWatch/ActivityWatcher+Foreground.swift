#if canImport(AppKit)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacControl
import NativeAgentCore
// Blueprint: | `ActivityWatcher+Foreground.swift` | Workspace/lock events, AX titles, motor provenance and heartbeat/idle; capture-thread callback lifetime |

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
            _ = reconcileLocked()
            standDownCapture()
        case .sessionBecameActive:
            sessionInactive = false
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
                _ = self.reconcileLocked()
                self.standDownCapture()
            }
        })
        lockTokens.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
        ) { [weak self] _ in
            self?.onCaptureThread { [weak self] in
                guard let self else { return }
                self.screenLockedByNotification = false
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

    /// Reconcile lock state before opens and on ticks; missed notifications must leave gaps, not false spans.
    private func reconcileLocked() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        let locked = screensAsleep || sessionInactive || screenLockedByNotification || Self.isLockSignal(
            bundleId: front?.bundleIdentifier,
            localizedName: front?.localizedName
        )
        // One reconciled snapshot can clear the missing-front/loginwindow gate even if unlock notification never arrives.
        feed(locked ? .lock(at: safeNow()) : .unlock(at: safeNow()))
        return locked
    }

    /// Missing frontmost identity cannot justify opening a span.
    public static func isLockSignal(bundleId: String?, localizedName: String?) -> Bool {
        if let bundleId, bundleId == loginWindowBundleID { return true }
        if let localizedName, localizedName.lowercased() == "loginwindow" { return true }
        return bundleId == nil && localizedName == nil
    }

    // MARK: - Span handling (capture thread)

    func seedFromFrontmostApplication() {
        guard isCaptureEnabled, !isStopping else { return }
        startTickTimer()
        if reconcileLocked() {
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
        startTickTimer()

        // Reconcile before motor attribution or any opening path.
        if reconcileLocked() {
            standDownCapture()
            return
        }

        // Our bounded motor epoch is agent provenance, not evidence of the person’s app choice.
        guard !NativeAgentMotorEpoch.isAgentDriven() else {
            feed(.activate(
                bundleId: ActivityPolicy.selfProcessBundleID,
                appName: "agent-driven",
                at: safeNow()
            ))
            detachObserver()
            idleResumeWatch = true
            // Observe without opening; later AX input outside the motor epoch can resume capture without an app switch.
            if let bundleId, let pid, pid != ownProcessID,
               engine.shouldCapture(bundleID: bundleId) {
                _ = attachCheckedObserver(pid: pid)
            }
            return
        }

        // Refuse unknown, self and excluded identities before AX; close the prior span and preserve the gap.
        guard let bundleId, let pid, pid != ownProcessID,
              engine.shouldCapture(bundleID: bundleId) else {
            feed(.activate(
                bundleId: ActivityPolicy.selfProcessBundleID, appName: "excluded", at: safeNow()
            ))
            standDownCapture()
            observationAvailable()
            return
        }

        if engine.openSpan?.bundleId == bundleId, observedPID == pid {
            feed(.focusEvent(at: safeNow()))
            return
        }

        detachObserver()
        // Close the prior app before attachment waits; another app’s failure cannot become its quit or observation loss.
        if let span = engine.openSpan, span.bundleId != bundleId {
            feed(.activate(bundleId: ActivityPolicy.selfProcessBundleID,
                           appName: "app-change", at: safeNow()))
        }
        // Required observation must be available before claiming a new span.
        guard attachCheckedObserver(pid: pid) else { return }
        feed(.activate(bundleId: bundleId, appName: appName ?? bundleId, at: clock.wallNow()))

        idleResumeWatch = false
        startTickTimer()

        // Read a permitted title only after the span is open so its initial value settles in place.
        captureTitleIfAllowed(pid: pid, bundleID: bundleId)
    }

    private func handleTermination(pid: pid_t?) {
        guard let pid, pid == observedPID else { return }
        feed(.terminate(at: safeNow()))
        detachObserver()
    }

    /// AX callbacks run on the capture thread and must never await the store actor.
    fileprivate func handleAXEvent(notification: String) {
        guard !isStopping else { return }
        // Exclude AX effects inside our motor epoch from human attribution; later input resumes it.
        guard !NativeAgentMotorEpoch.isAgentDriven() else { return }
        if engine.openSpan == nil {
            seedFromFrontmostApplication()
            return
        }
        // Check the current capture flag because the engine's policy update is queued.
        guard isCaptureEnabled else { return }
        if reconcileLocked() {
            detachObserver()
            return
        }
        guard let bundleID = engine.openSpan?.bundleId, let pid = observedPID else { return }

        // A disallowed title still supplies a focus event without exposing its content.
        if notification == kAXTitleChangedNotification as String
            || notification == kAXFocusedWindowChangedNotification as String,
           engine.shouldReadTitle(bundleID: bundleID) {
            captureTitleIfAllowed(pid: pid, bundleID: bundleID)
            return
        }
        feed(.focusEvent(at: safeNow()))
    }

    /// Policy-gate and redact at the sole title-read boundary; no raw string escapes.
    private func captureTitleIfAllowed(pid: pid_t, bundleID: String) {
        guard engine.shouldReadTitle(bundleID: bundleID) else { return }
        // Recheck lock state before reading AX; locked AX titles can look valid.
        guard !reconcileLocked() else {
            detachObserver()
            return
        }
        // Recheck capture immediately before AX so disabling also prevents the title read.
        guard isCaptureEnabled else { return }
        switch Self.frontmostWindowTitle(pid: pid) {
        case .observed(let raw):
            // Raw text goes only to the source redactor, never to diagnostics.
            feed(.titleChange(raw: raw, at: safeNow()))
        case .unavailable(let detail):
            observationIssue?("Activity title observation unavailable for PID \(pid): \(detail). The previous title evidence is unchanged.")
        }
    }

    private enum TitleObservation {
        case observed(String?)
        case unavailable(String)
    }

    /// Read only kAXTitle, never kAXValue for any element role.
    private static func frontmostWindowTitle(pid: pid_t) -> TitleObservation {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var windowRef: CFTypeRef?
        let windowErr = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef
        )
        if windowErr == .noValue { return .observed(nil) }
        guard windowErr == .success else {
            return .unavailable("focused-window AX error \(windowErr.rawValue)")
        }
        guard let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return .unavailable("focused-window result has no AX element")
        }
        let window = unsafeDowncast(windowRef, to: AXUIElement.self)

        var titleRef: CFTypeRef?
        let titleErr = AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef
        )
        if titleErr == .noValue || titleErr == .attributeUnsupported { return .observed(nil) }
        guard titleErr == .success else {
            return .unavailable("title AX error \(titleErr.rawValue)")
        }
        guard let title = titleRef as? String else {
            return .unavailable("title result is not a string")
        }
        return .observed(title)
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

        // Reconcile every 60 seconds so a missed lock notification cannot persist indefinitely.
        if reconcileLocked() {
            standDownCapture()
            return
        }
        guard let span = engine.openSpan else {
            // Fresh input resumes the same app through normal activation and its policy gates.
            guard idleResumeWatch else {
                seedFromFrontmostApplication()
                return
            }
            // Capture must resume without Input Monitoring; only MacPersonInput decides canonical presence.
            guard let idle = MacPersonInput.sessionIdleAfterAgentMotor(),
                  idle <= idleThreshold else { return }
            idleResumeWatch = false
            seedFromFrontmostApplication()
            return
        }

        // The idle API is only a read, so the timer must own its deadline.
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
            // Keep the timer so input can resume capture without switching apps.
            idleResumeWatch = true
            return
        }

        // Heartbeat advances liveness without fabricating events/hour.
        feed(.heartbeat(at: now))
    }

    /// Capture boundaries do not decide whether the person is here.
    private func standDownCapture() {
        detachObserver()
        // Keep reconciliation alive so missed unlocks or unavailable AX attachments can recover without another event.
    }

    private func idleSecondsSinceLastInput() -> Double {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null
        )
    }

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

    private enum AttachmentOutcome {
        case attached
        case terminated
        case unavailable(String)
    }

    private func attachCheckedObserver(pid: pid_t) -> Bool {
        switch attachObserver(pid: pid) {
        case .attached:
            observationAvailable()
            return true
        case .terminated:
            feed(.terminate(at: safeNow()))
            detachObserver()
            return false
        case .unavailable(let detail):
            observationUnavailable("Activity AX observation unavailable for PID \(pid): \(detail).")
            return false
        }
    }

    private func attachObserver(pid: pid_t) -> AttachmentOutcome {
        func failed(_ detail: String) -> AttachmentOutcome {
            if let app = NSRunningApplication(processIdentifier: pid), app.isTerminated {
                return .terminated
            }
            return .unavailable(detail)
        }
        var created: AXObserver?
        let createErr = AXObserverCreate(pid, activityAXObserverCallback, &created)
        guard createErr == .success, let created else {
            return failed("observer creation AX error \(createErr.rawValue)")
        }

        let appElement = AXUIElementCreateApplication(pid)
        // The process-wide startup timeout also bounds reads that fetch another AX element.
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        let context = ActivityObserverContext(watcher: self, pid: pid)
        let refcon = Unmanaged.passUnretained(context).toOpaque()

        // Value-change notifications expose per-keystroke activity and must never be observed.
        let notifications = [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXTitleChangedNotification,
        ]
        var registered = 0
        var unsupported: [String] = []
        for notification in notifications {
            let err = AXObserverAddNotification(created, appElement, notification as CFString, refcon)
            switch err {
            case .success, .notificationAlreadyRegistered:
                registered += 1
            case .notificationUnsupported:
                unsupported.append(notification as String)
            default:
                return failed("\(notification) registration AX error \(err.rawValue)")
            }
        }
        guard registered > 0 else { return failed("no requested AX notification is supported") }
        if !unsupported.isEmpty {
            observationIssue?(
                """
                Activity AX observation for PID \(pid) does not support: \(unsupported.joined(separator: ", ")). \
                Other registered notifications remain active.
                """
            )
        }

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(created),
            .defaultMode
        )
        observer = created
        observerContext = context
        observedPID = pid
        return .attached
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

/// Retain the C callback context for exactly the observer’s attached lifetime.
final class ActivityObserverContext {
    weak var watcher: ActivityWatcher?
    let pid: pid_t

    init(watcher: ActivityWatcher, pid: pid_t) {
        self.watcher = watcher
        self.pid = pid
    }
}

/// The callback stays on the capture run loop; no AX element escapes and no await is allowed.
private let activityAXObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let context = Unmanaged<ActivityObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    context.watcher?.handleAXEvent(notification: notification as String)
}
#endif

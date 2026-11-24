import CoreFoundation
import Dispatch
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `ActivityWatcher+Foreground.swift` | Body nerve edges, policy-gated titles, motor provenance and the 60-second idle check |

extension ActivityWatcher {
    func listenToBody() {
        presenceObserver = NotificationCenter.default.observeSynchronously(for: MacPersonInput.PresenceChanged.self) { [weak self] in
            self?.enqueueCapture { [weak self] in
                guard let self else { return }
                if self.resumeAfterInputUptime != nil, MacPersonInput.presence()?.here == true {
                    self.seedFromFrontmostApplication()
                }
            }
        }
        nerveToken = MacBodyNerve.shared.listen { [weak self] edge in
            switch edge {
            case .changed, .sheet, .workspace, .launched: return
            default:
                let uptime = ProcessInfo.processInfo.systemUptime
                self?.enqueueCapture { [weak self] in self?.handle(edge, uptime: uptime) }
            }
        }
    }

    private func handle(_ edge: MacBodyNerve.Edge, uptime: TimeInterval) {
        switch edge {
        case let .activated(pid, bundle, name, motor):
            handleActivation(bundleId: bundle, appName: name, pid: pid, motor: motor, uptime: uptime)
        case let .raised(pid, raisedAt):
            let front = MacBodyNerve.shared.frontmostApplication
            handleActivation(bundleId: front?.processIdentifier == pid ? front?.bundleIdentifier : nil,
                             appName: nil, pid: pid, motor: true, uptime: raisedAt)
        case .personInterrupted:
            seedFromFrontmostApplication()
        case let .terminated(pid, _, _):
            handleTermination(pid: pid)
        case let .focus(pid, kind, motor):
            guard !motor, observedPID == pid else { return }
            handleAXEvent(pid: pid, notification: kind)
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
        case .sessionInactive:
            sessionInactive = true
            _ = reconcileLocked()
            standDownCapture()
        case .sessionActive:
            sessionInactive = false
            seedFromFrontmostApplication()
        case .locked:
            screenLockedByNotification = true
            _ = reconcileLocked()
            standDownCapture()
        case .unlocked:
            screenLockedByNotification = false
            seedFromFrontmostApplication()
        default: break
        }
    }

    func stopListeningToBody() {
        if let nerveToken { MacBodyNerve.shared.remove(nerveToken) }
        nerveToken = nil
        if let presenceObserver { NotificationCenter.default.removeObserver(presenceObserver) }
        presenceObserver = nil
    }

    // MARK: - Lock reconciliation

    /// Reconcile lock state before opens and on ticks; missed notifications must leave gaps, not false spans.
    private func reconcileLocked() -> Bool {
        let front = MacBodyNerve.shared.frontmostApplication
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


    func seedFromFrontmostApplication() {
        guard isCaptureEnabled, !isStopping else { return }
        startTickTimer()
        if reconcileLocked() {
            standDownCapture()
            return
        }
        let front = MacBodyNerve.shared.frontmostApplication
        handleActivation(
            bundleId: front?.bundleIdentifier,
            appName: front?.localizedName,
            pid: front?.processIdentifier
        )
    }

    private func handleActivation(bundleId: String?, appName: String?, pid: pid_t?, motor: Bool? = nil,
                                  uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Check the current capture flag because the engine's policy update is queued.
        guard isCaptureEnabled else { return }
        guard !isStopping else { return }
        startTickTimer()

        let locked = reconcileLocked()
        let agentDriven = motor ?? MacBodyNerve.shared.isActing(pid: pid, foregroundOnly: true)
        if agentDriven, motor == true || resumeAfterInputUptime == nil {
            resumeAfterInputUptime = max(resumeAfterInputUptime ?? uptime, uptime)
        }
        if locked {
            standDownCapture()
            return
        }

        guard !agentDriven else {
            feed(.appChange(at: safeNow()))
            detachObserver()
            if let bundleId, let pid, !PersonOnlyWindows.isOwnProcess(pid),
               engine.shouldCapture(bundleID: bundleId) {
                _ = attachCheckedObserver(pid: pid)
            }
            return
        }

        // Refuse unknown, self and excluded identities before AX; close the prior span and preserve the gap.
        guard let bundleId, let pid, !PersonOnlyWindows.isOwnProcess(pid),
              engine.shouldCapture(bundleID: bundleId) else {
            feed(.appChange(at: safeNow()))
            standDownCapture()
            observationAvailable()
            return
        }

        if let boundary = resumeAfterInputUptime,
           !MacPersonInput.hasRecentPersonInput(after: boundary, within: idleThreshold) { return }

        if engine.openSpan?.pid == pid, observedPID == pid {
            guard attachCheckedObserver(pid: pid) else { return }
            feed(.focusEvent(at: safeNow()))
            return
        }

        detachObserver()
        // Close the prior app before attachment waits; another app’s failure cannot become its quit or observation loss.
        if let span = engine.openSpan, span.pid != pid {
            feed(.appChange(at: safeNow()))
        }
        // Required observation must be available before claiming a new span.
        guard attachCheckedObserver(pid: pid) else { return }
        feed(.activate(pid: pid, bundleId: bundleId, appName: appName ?? bundleId, at: clock.wallNow()))

        resumeAfterInputUptime = nil
        startTickTimer()

        // Read a permitted title only after the span is open so its initial value settles in place.
        captureTitleIfAllowed(pid: pid, bundleID: bundleId)
    }

    private func handleTermination(pid: pid_t?) {
        guard let pid, pid == observedPID else { return }
        feed(.terminate(at: safeNow()))
        detachObserver()
    }

    private func handleAXEvent(pid: pid_t, notification: String) {
        guard !isStopping else { return }
        if engine.openSpan == nil {
            if let app = MacBodyNerve.shared.frontmostApplication, app.processIdentifier == pid {
                handleActivation(bundleId: app.bundleIdentifier, appName: app.localizedName, pid: pid)
            }
            return
        }
        // Check the current capture flag because the engine's policy update is queued.
        guard isCaptureEnabled else { return }
        if reconcileLocked() {
            detachObserver()
            return
        }
        guard let span = engine.openSpan, span.pid == pid else { return }
        let bundleID = span.bundleId

        // A disallowed title still supplies a focus event without exposing its content.
        if notification == kAXTitleChangedNotification as String
            || notification == kAXFocusedWindowChangedNotification as String,
           engine.shouldReadTitle(bundleID: bundleID), MacBodyNerve.shared.frontmostApplication?.processIdentifier == pid {
            captureTitleIfAllowed(pid: pid, bundleID: bundleID, focusEvent: true)
            return
        }
        feed(.focusEvent(at: safeNow()))
    }

    /// Policy-gate and redact at the sole title-read boundary; no raw string escapes.
    private func captureTitleIfAllowed(pid: pid_t, bundleID: String, focusEvent: Bool = false) {
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
            if focusEvent { feed(.focusEvent(at: safeNow())) }
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
        let windowErr = unsafe AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef
        )
        if windowErr == .noValue { return .observed(nil) }
        guard windowErr == .success else {
            return .unavailable("focused-window AX error \(windowErr.rawValue)")
        }
        guard let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return .unavailable("focused-window result has no AX element")
        }
        let window = unsafe unsafeDowncast(windowRef, to: AXUIElement.self)

        var titleRef: CFTypeRef?
        let titleErr = unsafe AXUIElementCopyAttributeValue(
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
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        timer.setEventHandler { [weak self] in self?.onTick() }
        tickTimer = timer
        timer.resume()
    }

    func stopTickTimer() {
        resumeAfterInputUptime = nil
        guard let timer = tickTimer else { return }
        timer.cancel()
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
            seedFromFrontmostApplication()
            return
        }

        // The idle API is only a read, so the timer must own its deadline.
        let sampledAt = ProcessInfo.processInfo.systemUptime
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
            resumeAfterInputUptime = sampledAt
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

    private func attachCheckedObserver(pid: pid_t) -> Bool {
        observedPID = pid
        // The capture queue is serial by design: an activation finishes attaching before the next edge is handled, so it waits here for the nerve's
        // focus answer, which the nerve's own observer thread settles (never this queue).
        let answer = Mutex<MacBodyNerve.Focus?>(nil), settled = DispatchSemaphore(value: 0)
        Task.detached { let focus = await MacBodyNerve.shared.captureFocus(pid); answer.withLock { $0 = focus }; settled.signal() }
        settled.wait()
        switch answer.withLock({ $0 }) ?? .ended {
        case .ready(let unsupported):
            if !unsupported.isEmpty {
                observationIssue?("Activity AX observation for PID \(pid) does not support: \(unsupported.joined(separator: ", ")). Other registered notifications remain active.")
            }
            observationAvailable()
            return true
        case .ended:
            if NSRunningApplication(processIdentifier: pid)?.isTerminated == true {
                handleTermination(pid: pid)
            } else { observationUnavailable("Activity no longer observes foreground PID \(pid).") }
        case .unavailable(let detail):
            observationUnavailable("Activity AX observation unavailable for PID \(pid): \(detail).")
        }
        return false
    }

    func detachObserver() {
        if let observedPID { MacBodyNerve.shared.releaseFocus(observedPID) }
        observedPID = nil
    }
}

// MacWaitSignals.swift — WAITING BECAUSE THE SIGNAL REACHED YOU (fable51 item 31).
//
// NORTHSTAR clause 4: "A polling loop made faster is still a polling loop. The
// clause-4 move is the loop DISSOLVING into a flow — a signal that propagates
// when something happens." `wait` was the loop. It called `sight()` every
// 500 ms for up to 60 s, and every sight is a full AX walk plus a
// ScreenCaptureKit capture plus (conditionally) OCR: up to 120 captures to
// answer "has the page finished loading yet".
//
// The machinery to do it properly was already in the building. `MacActClosedLoop`
// has subscribed to a real `AXObserver` since the closed loop landed, and ends
// its wait the MOMENT the notification arrives. This file lets `wait` subscribe
// to the same thing, plus the one signal an AX observer structurally cannot
// carry: an app SWITCH, which happens in a process the observer is not
// installed on.
//
// WHAT CHANGED, AND WHAT DID NOT:
//   • `wait` renders ONCE at the start (its baseline), and then once per change
//     EPISODE — not on a timer. A burst of twelve notifications is one wake.
//   • Silence is the settle. When the observer is installed and nothing fires
//     for `settleQuietSeconds`, the screen has stopped changing; the render
//     already in hand is the answer, so a settle now costs ONE capture instead
//     of two.
//   • The coarse fallback re-render is the SAFETY NET, and it is honest about
//     what it is for: when no observer could be installed at all, silence
//     proves nothing, so `wait` degrades to a slow poll (every
//     `fallbackPollSeconds`) rather than reporting a settle it cannot see.
//   • The vocabulary and the result shape are untouched: matched / settled /
//     timeout, `seconds`, and the final render.

import Foundation
import PersistenceCore

#if canImport(AppKit) && os(macOS)
import AppKit
#endif

/// The signal an AX observer cannot carry. An `AXObserver` is installed on ONE
/// process; when macOS brings a different app forward, nothing fires on the old
/// one, and a `wait until "Mail is in front"` would sit blind until the
/// deadline. NSWorkspace publishes exactly this, so it is the second
/// subscription rather than a reason to keep polling.
public protocol MacAppActivationObserverSource: Sendable {
    /// `nil` when no activation observer could be installed — which the caller
    /// REPORTS (it falls back to the coarse re-check), never hides.
    func install(
        onActivation: @escaping @Sendable () -> Void
    ) -> (any MacAXEffectObservation)?
}

#if canImport(AppKit) && os(macOS)
public struct SystemMacAppActivationObserverSource: MacAppActivationObserverSource {
    public init() {}

    public func install(
        onActivation: @escaping @Sendable () -> Void
    ) -> (any MacAXEffectObservation)? {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { _ in onActivation() }
        return MacWorkspaceActivationObservation(center: center, token: token)
    }
}

/// Removes the workspace observer exactly once, from wherever control leaves
/// the wait — the same contract `MacAXEffectObserverGuard` holds for the AX
/// side.
final class MacWorkspaceActivationObservation: MacAXEffectObservation, @unchecked Sendable {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?
    private let lock = NSLock()

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    func stop() {
        lock.lock()
        let live = token
        token = nil
        lock.unlock()
        guard let live else { return }
        center.removeObserver(live)
    }

    deinit { stop() }
}
#endif

public struct UnavailableMacAppActivationObserverSource: MacAppActivationObserverSource {
    public init() {}
    public func install(
        onActivation: @escaping @Sendable () -> Void
    ) -> (any MacAXEffectObservation)? { nil }
}

public func defaultMacAppActivationObserverSource() -> any MacAppActivationObserverSource {
    #if canImport(AppKit) && os(macOS)
    return SystemMacAppActivationObserverSource()
    #else
    return UnavailableMacAppActivationObserverSource()
    #endif
}

/// Both subscriptions, and the one question the wait asks of them: "has
/// anything happened since I last looked?"
///
/// `consume()` DRAINS. A real UI change fires a burst — Calculator emits
/// `AXValueChanged` then `AXTitleChanged` within milliseconds — and rendering
/// once per notification would put the poll straight back, with extra steps.
/// One episode, one render.
public final class MacWaitSignals: @unchecked Sendable {
    private let collector = MacAXEffectCollector()
    private let effectGuard: MacAXEffectObserverGuard
    private let activation: (any MacAXEffectObservation)?
    private let activationBox: MacWaitActivationBox
    private let lock = NSLock()
    private var consumedNotifications = 0
    private var stopped = false

    /// True when AT LEAST ONE of the two subscriptions is live. When it is
    /// false, silence proves nothing and the wait must fall back to the coarse
    /// re-render — reporting a settle from a subscription that was never
    /// installed is the exact "silent stub" shape clause 2 forbids.
    public let isObserving: Bool

    public init(
        effects: any MacAXEffectObserverSource,
        activation activationSource: any MacAppActivationObserverSource,
        pid: Int32?
    ) {
        let sink = collector
        let installedEffects: (any MacAXEffectObservation)? = pid.flatMap { pid in
            effects.install(
                pid: pid,
                kinds: MacActClosedLoop.notificationKinds,
                onNotification: { sink.record($0) }
            )
        }
        self.effectGuard = MacAXEffectObserverGuard(installedEffects)
        // The activation flag is set from the main run loop while the wait runs
        // off it, exactly like the AX collector.
        let box = MacWaitActivationBox()
        self.activation = activationSource.install(onActivation: { box.set() })
        self.activationBox = box
        self.isObserving = installedEffects != nil || self.activation != nil
    }

    /// Anything since the last call? Drains both channels.
    public func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var fired = false
        // DROPPED COUNTS. `MacAXEffectCollector` retains only the first 64
        // notifications and counts the rest, so a churning app saturates the
        // buffer within a second — and comparing `snapshot().count` alone would
        // then report "nothing since last time" forever, turning a busy screen
        // into a settle. The TOTAL is retained + dropped.
        let notifications = collector.snapshot().count + collector.droppedCount()
        if notifications > consumedNotifications {
            consumedNotifications = notifications
            fired = true
        }
        if activationBox.take() { fired = true }
        return fired
    }

    /// The notification kinds seen so far, for the wait's structured detail.
    /// Diagnostics only — never a claim about what the screen now says.
    public func kinds() -> [String] {
        var seen: [String] = []
        for notification in collector.snapshot() where !seen.contains(notification.kind) {
            seen.append(notification.kind)
            if seen.count >= MacActClosedLoop.maxReportedNotifications { break }
        }
        return seen
    }

    /// Removes BOTH observers, exactly once, from wherever control leaves the
    /// wait: the matched return, the settle, the timeout, a blind re-look, or a
    /// cancellation that unwinds past every `defer`.
    public func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        effectGuard.stop()
        activation?.stop()
    }

    deinit { stop() }
}

/// One bool, safely crossed between the main run loop and the waiting task.
final class MacWaitActivationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    func set() {
        lock.lock(); pending = true; lock.unlock()
    }

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = false
        return value
    }
}

import Foundation
import Synchronization
import PersistenceCore

import AppKit

// Blueprint: | `MacWaitSignals.swift` | `MacWaitSignals`: Cancellable AX/app signal waits with owned observer lifetimes |

/// AX observes one process and misses app switches; NSWorkspace activation supplies that missing signal without polling.
public protocol MacAppActivationObserverSource: Sendable {
    /// Missing activation subscription refuses the wait rather than choosing another mechanism.
    func install(
        onActivation: @escaping @Sendable () -> Void
    ) -> (any MacAXEffectObservation)?
}

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
        return MacWorkspaceObservation(center: center, token: token)
    }
}

/// Release the workspace subscription exactly once on every wait exit.
final class MacWorkspaceObservation: MacAXEffectObservation, Sendable {
    private let center: NotificationCenter
    private let token: Mutex<NSObjectProtocol?>

    init(center: NotificationCenter, token: sending NSObjectProtocol) {
        self.center = center
        self.token = Mutex(token)
    }

    func stop() {
        let live = token.withLock { token in
            defer { token = nil }
            return token
        }
        if let live { center.removeObserver(live) }
    }

    deinit { stop() }
}

public func defaultMacAppActivationObserverSource() -> any MacAppActivationObserverSource {
    return SystemMacAppActivationObserverSource()
}

/// Coalesce AX and activation signals until drained.
public final class MacWaitSignals: Sendable {
    let collector: MacAXEffectCollector
    let startedAt: Date
    private let effects: (any MacAXEffectObservation)?
    private let activation: (any MacAXEffectObservation)?
    private let stopped = Atomic(false)

    /// Whether this wait installed AX observation; activation alone cannot observe in-window changes.
    public let isObserving: Bool
    public let installationFailure: String?

    public init(
        effects: any MacAXEffectObserverSource,
        activation activationSource: any MacAppActivationObserverSource,
        pid: Int32?
    ) {
        startedAt = Date()
        let sink = MacAXEffectCollector()
        self.collector = sink
        let installedEffects: (any MacAXEffectObservation)? = pid.flatMap { pid in
            effects.install(
                pid: pid,
                kinds: MacActClosedLoop.notificationKinds,
                onNotification: { sink.record($0) }
            )
        }
        let installedActivation = activationSource.install(onActivation: { sink.signal() })
        self.effects = installedEffects
        self.activation = installedActivation
        self.isObserving = installedEffects != nil
        self.installationFailure = pid == nil ? "The screen read did not establish an app process to observe."
            : installedEffects == nil ? "Accessibility change observation could not be installed for this app."
            : installedActivation == nil ? "App activation observation could not be installed."
            : nil
    }

    /// Borrow a caller's signal sink without installing or owning its observers.
    init(collector: MacAXEffectCollector, startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.collector = collector
        effects = nil
        activation = nil
        isObserving = false
        installationFailure = nil
    }

    public func consume() -> Bool {
        collector.consumeSignal()
    }

    func waitForSignal(seconds: Double) async -> Bool {
        await collector.waitForSignal(seconds: seconds)
    }

    /// Release both observers and pending waits exactly once.
    public func stop() {
        guard !stopped.exchange(true, ordering: .acquiringAndReleasing) else { return }
        effects?.stop()
        activation?.stop()
        collector.finishWaiting()
    }

    deinit { stop() }
}

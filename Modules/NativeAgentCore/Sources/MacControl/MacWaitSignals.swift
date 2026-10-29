import Foundation
import PersistenceCore

#if canImport(AppKit) && os(macOS)
import AppKit
#endif

// Blueprint: | `MacWaitSignals.swift` | `MacWaitSignals` and activation observation ports: cancellable event-driven waits that consume existing app/AX signals |

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
/// the wait — the same contract each observation holds for the AX
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

/// Coalesces AX changes and app activation until the consumer drains them.
public final class MacWaitSignals: @unchecked Sendable {
    private let collector = MacAXEffectCollector()
    private let effects: (any MacAXEffectObservation)?
    private let activation: (any MacAXEffectObservation)?
    private let lock = NSLock()
    private var stopped = false

    /// Whether AX observation is installed; activation alone cannot observe in-window changes.
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
        self.effects = installedEffects
        self.activation = activationSource.install(onActivation: { sink.signal() })
        self.isObserving = installedEffects != nil
    }

    /// Anything since the last call? Drains both channels.
    public func consume() -> Bool {
        collector.consumeSignal()
    }

    func waitForSignal(seconds: Double) async -> Bool {
        await collector.waitForSignal(seconds: seconds)
    }

    /// Removes both observers and releases pending signal waits exactly once.
    public func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        effects?.stop()
        activation?.stop()
        collector.finishWaiting()
    }

    deinit { stop() }
}

import Foundation
import PersistenceCore

#if canImport(AppKit) && os(macOS)
import AppKit
#endif

// Blueprint: | `MacWaitSignals.swift` | `MacWaitSignals`: Cancellable AX/app signal waits with owned observer lifetimes |

/// AX observes one process and misses app switches; NSWorkspace activation supplies that missing signal without polling.
public protocol MacAppActivationObserverSource: Sendable {
    /// Missing activation subscription refuses the wait rather than choosing another mechanism.
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

/// Release the workspace subscription exactly once on every wait exit.
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

/// Coalesce AX and activation signals until drained.
public final class MacWaitSignals: @unchecked Sendable {
    let collector: MacAXEffectCollector
    let startedAt: Date
    private let effects: (any MacAXEffectObservation)?
    private let activation: (any MacAXEffectObservation)?
    private let lock = NSLock()
    private var stopped = false

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

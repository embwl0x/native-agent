import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(ApplicationServices)
import ApplicationServices
#endif

// Blueprint: | `MacAXEffectObservation.swift` | `MacAXEffectObserverSource`: Payload-free signals; bounded waits and lane-owned cleanup |

// MARK: - The effect-observer seam

/// Keep notifications payload-free: userInfo can contain passwords and the signal crosses traces, operation storage and device sync.
public struct MacAXEffectNotification: Sendable, Equatable {
    public let kind: String
    public let at: Date

    public init(kind: String, at: Date) {
        self.kind = kind
        self.at = at
    }
}

/// Registrations must stop idempotently and release on deinitialization.
public protocol MacAXEffectObservation: AnyObject, Sendable {
    func stop()
}

/// Live AX notifications use the dedicated AX run loop.
public protocol MacAXEffectObserverSource: Sendable {
    /// An unavailable observer returns nil so callers report unobserved with a reason, never infer no effect.
    func install(
        pid: Int32,
        kinds: [String],
        onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void
    ) -> (any MacAXEffectObservation)?
}

/// Notifications arrive on the AX thread while the act waits off it, so the sink must be thread-safe.
public final class MacAXEffectCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var firstNotification: MacAXEffectNotification?
    private var batch: [String: MacAXEffectNotification] = [:]
    private var total = 0
    private var seenKinds: Set<String> = []
    private var pending = false
    private var waiter: AsyncStream<Void>.Continuation?

    public init() {}

    public func record(_ notification: MacAXEffectNotification) {
        lock.lock()
        defer { lock.unlock() }
        if total < Int.max { total += 1 }
        seenKinds.insert(notification.kind)
        batch[notification.kind] = notification
        if firstNotification == nil { firstNotification = notification }
        pending = true
        waiter?.yield(())
    }

    /// Activation wakes the same consumer without fabricating an AX event.
    func signal() {
        lock.lock()
        defer { lock.unlock() }
        pending = true
        waiter?.yield(())
    }

    func consumeSignal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let fired = pending
        pending = false
        return fired
    }

    /// One consumer per collector. Register before checking the latch so a notification between the caller's read and its suspension is retained.
    func waitForSignal(seconds: Double) async -> Bool {
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            waiter = continuation
            if pending { continuation.yield(()) }
        }
        defer { finishWaiting() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in events { break }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(max(0, seconds))) }
                catch { return } // A signal or Stop cancels the patience task.
            }
            await group.next()
            group.cancelAll()
        }
        return consumeSignal()
    }

    func finishWaiting() {
        lock.lock()
        let live = waiter
        waiter = nil
        lock.unlock()
        live?.finish()
    }

    /// Drain wake evidence without losing the first notification or lifetime counts and kinds.
    func drain() -> [MacAXEffectNotification] {
        lock.withLock {
            let result = Array(batch.values).sorted { $0.at < $1.at }
            batch.removeAll(keepingCapacity: true)
            pending = false
            return result
        }
    }

    func count() -> Int { lock.withLock { total } }
    func kinds() -> [String] { lock.withLock { seenKinds.sorted() } }

    public func first() -> MacAXEffectNotification? {
        lock.lock()
        defer { lock.unlock() }
        return firstNotification
    }
}

// MARK: - The live observer

#if canImport(ApplicationServices) && os(macOS)

/// The registration retains the callback refcon until stop releases it exactly once.
private final class MacAXEffectObserverBox {
    let onNotification: @Sendable (MacAXEffectNotification) -> Void
    init(onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void) {
        self.onNotification = onNotification
    }
}

private final class SystemMacAXEffectObservation: MacAXEffectObservation, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let observer: AXObserver
    private let element: AXUIElement
    private let kinds: [String]
    private let refcon: UnsafeMutableRawPointer

    init(observer: AXObserver, element: AXUIElement, kinds: [String], refcon: UnsafeMutableRawPointer) {
        self.observer = observer
        self.element = element
        self.kinds = kinds
        self.refcon = refcon
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        // AX removal can enter the target's main-thread handlers, so teardown uses the shared AX execution lane.
        MacAXExecutionLane.sync {
            for kind in kinds {
                AXObserverRemoveNotification(observer, element, kind as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        Unmanaged<MacAXEffectObserverBox>.fromOpaque(refcon).release()
    }

    deinit { stop() }
}

/// AX creation, delivery and removal share MacAXExecutionLane's run loop.
public struct SystemMacAXEffectObserverSource: MacAXEffectObserverSource {
    public init() {}

    public func install(
        pid: Int32,
        kinds: [String],
        onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void
    ) -> (any MacAXEffectObservation)? {
        MacAXExecutionLane.sync {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, notification, refcon in
                guard let refcon else { return }
                let box = Unmanaged<MacAXEffectObserverBox>.fromOpaque(refcon).takeUnretainedValue()
                box.onNotification(MacAXEffectNotification(kind: notification as String, at: Date()))
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
                return nil
            }
            let box = MacAXEffectObserverBox(onNotification: onNotification)
            let refcon = Unmanaged.passRetained(box).toOpaque()
            let element = AXUIElementCreateApplication(pid)
            var subscribed: [String] = []
            for kind in kinds {
                if AXObserverAddNotification(observer, element, kind as CFString, refcon) == .success {
                    subscribed.append(kind)
                }
            }
            // No subscribed kind means no working channel; return nil instead of an inert registration.
            guard !subscribed.isEmpty else {
                Unmanaged<MacAXEffectObserverBox>.fromOpaque(refcon).release()
                return nil
            }
            CFRunLoopAddSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
            return SystemMacAXEffectObservation(
                observer: observer,
                element: element,
                kinds: subscribed,
                refcon: refcon
            )
        }
    }
}

#endif

/// Return nil so unsupported platforms report observer_unavailable rather than claim no effect.
public struct UnavailableMacAXEffectObserverSource: MacAXEffectObserverSource {
    public init() {}
    public func install(
        pid: Int32,
        kinds: [String],
        onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void
    ) -> (any MacAXEffectObservation)? { nil }
}

public func defaultMacAXEffectObserverSource() -> any MacAXEffectObserverSource {
    #if canImport(ApplicationServices) && os(macOS)
    return SystemMacAXEffectObserverSource()
    #else
    return UnavailableMacAXEffectObserverSource()
    #endif
}

import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(ApplicationServices)
import ApplicationServices
#endif

// Blueprint: | `MacAXEffectObservation.swift` | `MacAXEffectObserverSource`, registration and collector: payload-free AX notifications, bounded signal waits and idempotent removal on the shared AX execution lane |

// MARK: - The effect-observer seam

/// One AX notification, named only. NEVER any payload: a notification's
/// userInfo can carry the changed VALUE (a password field's new contents on
/// `AXValueChanged`), and this rides the turn trace, the operation store and
/// the iOS/Telegram sync. The kind and the timestamp are the whole signal.
public struct MacAXEffectNotification: Sendable, Equatable {
    public let kind: String
    public let at: Date

    public init(kind: String, at: Date) {
        self.kind = kind
        self.at = at
    }
}

/// AX, attention and workspace registrations own idempotent `stop()` and deinitialization cleanup.
public protocol MacAXEffectObservation: AnyObject, Sendable {
    func stop()
}

/// Observe the target process's named AX notifications; the live source registers on the main run loop.
public protocol MacAXEffectObserverSource: Sendable {
    /// Install an observer for `kinds` on `pid`. Returns nil when no observer
    /// could be installed — which the caller must REPORT (`observed: false`
    /// with a reason), never hide behind a silent "no effect".
    func install(
        pid: Int32,
        kinds: [String],
        onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void
    ) -> (any MacAXEffectObservation)?
}


/// Thread-safe sink for notifications arriving on the main run loop while the
/// act waits off it.
public final class MacAXEffectCollector: @unchecked Sendable {
    /// A pathological app can fire hundreds of notifications in 80 ms. Only the
    /// first `hardCap` are retained; the count of the rest is still reported.
    public static let hardCap = 64

    private let lock = NSLock()
    private var received: [MacAXEffectNotification] = []
    private var dropped = 0
    private var pending = false
    private var waiter: AsyncStream<Void>.Continuation?

    public init() {}

    public func record(_ notification: MacAXEffectNotification) {
        lock.lock()
        defer { lock.unlock() }
        if received.count < Self.hardCap {
            received.append(notification)
        } else {
            dropped += 1
        }
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

    /// One consumer per collector. Register before checking the latch so a
    /// notification between the caller's read and its suspension is retained.
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
                try? await Task.sleep(for: .seconds(max(0, seconds)))
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

    public func snapshot() -> [MacAXEffectNotification] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    public func first() -> MacAXEffectNotification? {
        lock.lock()
        defer { lock.unlock() }
        return received.first
    }

    public func droppedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }
}

// MARK: - The live observer

#if canImport(ApplicationServices) && os(macOS)

/// Box carried through the AX callback's `refcon`. Retained for the lifetime of
/// the registration and released exactly once by `stop()`.
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
        // Same execution lane every other AX transaction in this module uses:
        // AX calls can synchronously enter the TARGET app's main-thread-isolated
        // handlers, and removing a notification is an AX call like any other.
        MacAXExecutionLane.sync {
            for kind in kinds {
                AXObserverRemoveNotification(observer, element, kind as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        Unmanaged<MacAXEffectObserverBox>.fromOpaque(refcon).release()
    }

    deinit { stop() }
}

/// The real `AXObserver`, sourced on the MAIN run loop (which is where the AX
/// framework delivers) and created/removed on `MacAXExecutionLane`.
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
            // Not one kind subscribed: there is nothing to remove and nothing
            // to hear. Report the failure by returning nil rather than handing
            // back a registration that can never fire.
            guard !subscribed.isEmpty else {
                Unmanaged<MacAXEffectObserverBox>.fromOpaque(refcon).release()
                return nil
            }
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
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

/// Honest unavailability: installs nothing and says so by returning nil, so the
/// act reports `observed: false, reason: "observer_unavailable"` instead of
/// silently claiming the app produced no effect.
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

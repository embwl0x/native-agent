import CoreFoundation
import Foundation
import Synchronization
import NativeAgentCore
import PersistenceCore
import DeskCore
import ApplicationServices

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
public final class MacAXEffectCollector: Sendable {
    private struct State {
        var firstNotification: MacAXEffectNotification?
        var batch: [String: MacAXEffectNotification] = [:]
        var total = 0
        var seenKinds: Set<String> = []
        var pending = false
        var waiter: AsyncStream<Void>.Continuation?
    }
    private let state = Mutex(State())

    public init() {}

    public func record(_ notification: MacAXEffectNotification) {
        state.withLock { state in
            if state.total < Int.max { state.total += 1 }
            state.seenKinds.insert(notification.kind)
            state.batch[notification.kind] = notification
            if state.firstNotification == nil { state.firstNotification = notification }
            state.pending = true
            state.waiter?.yield(())
        }
    }

    /// Activation wakes the same consumer without fabricating an AX event.
    func signal() {
        state.withLock { state in
            state.pending = true
            state.waiter?.yield(())
        }
    }

    func consumeSignal() -> Bool {
        return state.withLock { state in
            let fired = state.pending
            state.pending = false
            return fired
        }
    }

    /// One consumer per collector. Register before checking the latch so a notification between the caller's read and its suspension is retained.
    func waitForSignal(seconds: Double) async -> Bool {
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { state in
            state.waiter = continuation
            if state.pending { continuation.yield(()) }
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
        let live = state.withLock { state in
            defer { state.waiter = nil }
            return state.waiter
        }
        live?.finish()
    }

    /// Drain wake evidence without losing the first notification or lifetime counts and kinds.
    func drain() -> [MacAXEffectNotification] {
        state.withLock { state in
            let result = Array(state.batch.values).sorted { $0.at < $1.at }
            state.batch.removeAll(keepingCapacity: true)
            state.pending = false
            return result
        }
    }

    func count() -> Int { state.withLock { $0.total } }
    func kinds() -> [String] { state.withLock { $0.seenKinds.sorted() } }

    public func first() -> MacAXEffectNotification? {
        state.withLock { $0.firstNotification }
    }
}

// MARK: - The live observer


/// The registration retains the callback refcon until stop releases it exactly once.
private final class MacAXEffectObserverBox {
    let onNotification: @Sendable (MacAXEffectNotification) -> Void
    init(onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void) {
        self.onNotification = onNotification
    }
}

// The AX observer and element are CF handles with a retained callback context.
@safe private final class SystemMacAXEffectObservation: MacAXEffectObservation, @unchecked Sendable {
    private let stopped = Atomic(false)
    private let observer: AXObserver
    private let element: AXUIElement
    private let kinds: [String]
    private let refcon: UnsafeMutableRawPointer

    init(observer: AXObserver, element: AXUIElement, kinds: [String], refcon: UnsafeMutableRawPointer) {
        self.observer = observer
        self.element = element
        self.kinds = kinds
        unsafe self.refcon = refcon
    }

    func stop() {
        guard !stopped.exchange(true, ordering: .acquiringAndReleasing) else { return }
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
        unsafe Unmanaged<MacAXEffectObserverBox>.fromOpaque(refcon).release()
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
            let callback: AXObserverCallback = { _, element, notification, refcon in
                guard let refcon else { return }
                let box = unsafe Unmanaged<MacAXEffectObserverBox>.fromOpaque(refcon).takeUnretainedValue()
                let kind = notification as String
                if kind == kAXSheetCreatedNotification { MacBodyNerve.shared.sheetCreated(element) }
                box.onNotification(MacAXEffectNotification(kind: kind, at: Date()))
            }
            guard unsafe AXObserverCreate(pid, callback, &observer) == .success, let observer else {
                return nil
            }
            let box = MacAXEffectObserverBox(onNotification: onNotification)
            let refcon = unsafe Unmanaged.passRetained(box).toOpaque()
            let element = AXUIElementCreateApplication(pid)
            var subscribed: [String] = []
            for kind in kinds {
                if unsafe AXObserverAddNotification(observer, element, kind as CFString, refcon) == .success {
                    subscribed.append(kind)
                }
            }
            // No subscribed kind means no working channel; return nil instead of an inert registration.
            guard !subscribed.isEmpty else {
                unsafe Unmanaged<MacAXEffectObserverBox>.fromOpaque(refcon).release()
                return nil
            }
            CFRunLoopAddSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
            return unsafe SystemMacAXEffectObservation(
                observer: observer,
                element: element,
                kinds: subscribed,
                refcon: refcon
            )
        }
    }
}


public func defaultMacAXEffectObserverSource() -> any MacAXEffectObserverSource {
    return SystemMacAXEffectObserverSource()
}

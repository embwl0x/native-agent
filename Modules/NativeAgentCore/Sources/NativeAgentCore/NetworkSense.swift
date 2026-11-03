import Foundation
import Network

// Blueprint: | `NetworkSense.swift` | `NetworkSense`: one process-wide NWPathMonitor; immediate `isUp` and replaying `changes`, cancellation-aware bounded `returns(within:)`; `changed` posts only after the path holds for five seconds, feeding body signals through EnginePartWake |

/// The Mac's network path is one body fact, shared by every network consumer.
/// A satisfied path is reachability, not proof that a provider is healthy.
public enum NetworkSense {
    private static let owner = Owner()
    public static let changed = Notification.Name("NativeAgent.network.changed")
    /// Immediate edge for deadline owners; body signals use `changed` instead.
    public static let pathChanged = Notification.Name("NativeAgent.network.pathChanged")
    public static let settlingInterval: TimeInterval = 5

    /// Immediate path state. Until Network delivers its first observation, hold.
    public static var isUp: Bool { owner.isUp }

    /// Registers before replaying the current state, so a return cannot be lost
    /// between a caller's offline read and its subscription. Cancel to retire.
    public static var changes: AsyncStream<Bool> { owner.changes() }

    /// Wait only this long for a path. Stop remains cancellation, never offline.
    public static func returns(within seconds: TimeInterval) async throws -> Bool {
        try Task.checkCancellation()
        if isUp { return true }
        let changes = Self.changes
        let delay = seconds.isFinite ? min(max(0, seconds), 86_400) : 0
        let returned = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await up in changes {
                    if Task.isCancelled { return false }
                    if up { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(delay))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        try Task.checkCancellation()
        return returned
    }

    private final class Owner: @unchecked Sendable {
        private let monitor = NWPathMonitor()
        private let queue = DispatchQueue(label: "NativeAgent.network")
        private let lock = NSLock()
        private var up = false
        private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]
        // Only the monitor's serial queue touches the debounced edge.
        private var observed: Bool?
        private var posted: Bool?
        private var settling: DispatchWorkItem?

        init() {
            monitor.pathUpdateHandler = { [weak self] path in
                self?.receive(path.status == .satisfied)
            }
            monitor.start(queue: queue)
        }

        var isUp: Bool { lock.withLock { up } }

        func changes() -> AsyncStream<Bool> {
            let pair = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let id = UUID()
            lock.withLock {
                observers[id] = pair.continuation
                pair.continuation.yield(up)
            }
            pair.continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.observers.removeValue(forKey: id) }
            }
            return pair.stream
        }

        private func receive(_ value: Bool) {
            guard observed != value else { return }
            let first = observed == nil
            observed = value
            lock.withLock {
                up = value
                for observer in observers.values { observer.yield(value) }
            }
            NotificationCenter.default.post(name: NetworkSense.pathChanged, object: nil)
            // Observation at launch establishes a baseline, not a new return.
            if first { posted = value; return }
            settling?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.observed == value, self.posted != value else { return }
                self.posted = value
                NotificationCenter.default.post(name: NetworkSense.changed, object: nil,
                    userInfo: ["is_up": value])
            }
            settling = work
            queue.asyncAfter(deadline: .now() + NetworkSense.settlingInterval, execute: work)
        }
    }
}

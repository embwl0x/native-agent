import Foundation
import Network
import Synchronization

// Blueprint: | `NetworkSense.swift` | One path monitor; network-return waits and body wakes follow path events |

/// A satisfied path establishes local reachability, never a provider verdict.
public enum NetworkSense {
    private static let owner = Owner()
    public static let changed = Notification.Name("NativeAgent.network.changed")

    /// False includes a path that has not yet been observed; callers waiting for reachability keep waiting.
    public static var isUp: Bool { owner.isUp }
    public static var changes: AsyncStream<Bool> { owner.changes() }

    /// Subscribe before replaying the path; an absent return stays waiting until cancellation.
    public static func returns() async throws {
        try Task.checkCancellation()
        for await up in changes {
            try Task.checkCancellation()
            if up { return }
        }
        throw CancellationError()
    }

    private final class Owner: Sendable {
        private let monitor = NWPathMonitor()
        private let queue = DispatchQueue(label: "NativeAgent.network")
        private struct State: Sendable {
            var up: Bool?
            var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]
        }
        private let state = Mutex(State())

        init() {
            monitor.pathUpdateHandler = { [weak self] path in
                self?.receive(path.status == .satisfied)
            }
            monitor.start(queue: queue)
        }

        var isUp: Bool { state.withLock { $0.up == true } }

        func changes() -> AsyncStream<Bool> {
            let pair = AsyncStream<Bool>.makeStream()
            let id = UUID()
            state.withLock {
                $0.observers[id] = pair.continuation
                if let up = $0.up { pair.continuation.yield(up) }
            }
            pair.continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
            }
            return pair.stream
        }

        private func receive(_ value: Bool) {
            let edge = state.withLock { state -> (changed: Bool, first: Bool) in
                guard state.up != value else { return (false, false) }
                let first = state.up == nil
                state.up = value
                for observer in state.observers.values { observer.yield(value) }
                return (true, first)
            }
            guard edge.changed else { return }
            if !edge.first {
                NotificationCenter.default.post(name: NetworkSense.changed, object: nil, userInfo: ["is_up": value])
            }
        }
    }
}

import Synchronization
import Foundation

// Blueprint: | `StoreChangeBus.swift` | `StoreChangeBus`: process-local multicast store invalidations; files remain authoritative |

public struct StoreChange: Sendable, Equatable {
    public enum Store: String, Sendable { case desk, replyDelivery, keyring }
    public let store: Store
    public let path: URL
    public init(store: Store, path: URL) { self.store = store; self.path = path }
}

/// Process-local multicast invalidation bus. Files remain the source of truth.
public final class StoreChangeBus: Sendable {
    public static let shared = StoreChangeBus()
    private let continuations = Mutex<[UUID: AsyncStream<StoreChange>.Continuation]>([:])
    public init() {}

    public func changes() -> AsyncStream<StoreChange> {
        let id = UUID()
        let pair = AsyncStream<StoreChange>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuations.withLock { $0[id] = pair.continuation }
        pair.continuation.onTermination = { [weak self] _ in self?.remove(id) }
        return pair.stream
    }

    public func emit(_ change: StoreChange) {
        let listeners = continuations.withLock { Array($0.values) }
        listeners.forEach { $0.yield(change) }
    }

    private func remove(_ id: UUID) {
        continuations.withLock { $0[id] = nil }
    }
}

import Foundation

public struct StoreChange: Sendable, Equatable {
    public enum Store: String, Sendable { case desk, githubCommand }
    public let store: Store
    public let path: URL
    public init(store: Store, path: URL) { self.store = store; self.path = path }
}

/// Process-local multicast invalidation bus. Files remain the source of truth.
public final class StoreChangeBus: @unchecked Sendable {
    public static let shared = StoreChangeBus()
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<StoreChange>.Continuation] = [:]
    public init() {}

    public func changes() -> AsyncStream<StoreChange> {
        let id = UUID()
        let pair = AsyncStream<StoreChange>.makeStream(bufferingPolicy: .bufferingNewest(32))
        lock.lock(); continuations[id] = pair.continuation; lock.unlock()
        pair.continuation.onTermination = { [weak self] _ in self?.remove(id) }
        return pair.stream
    }

    public func emit(_ change: StoreChange) {
        lock.lock(); let listeners = Array(continuations.values); lock.unlock()
        listeners.forEach { $0.yield(change) }
    }

    private func remove(_ id: UUID) {
        lock.lock(); continuations.removeValue(forKey: id); lock.unlock()
    }
}

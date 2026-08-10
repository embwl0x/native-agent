import Foundation

/// FIFO relay for fire-and-forget work that must leave a hot path immediately
/// but still reach its consumer in submission order.
final class SerialDetachedRelay: @unchecked Sendable {
    private let label: String
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    init(label: String) { self.label = label }

    @discardableResult
    func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock()
        let previous = tail
        let next = Task.detached(priority: .utility) {
            if let previous { _ = await previous.value }
            await work()
        }
        tail = next
        lock.unlock()
        return next
    }

    func drain() async {
        if let current = currentTail() { _ = await current.value }
    }

    private func currentTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }
}

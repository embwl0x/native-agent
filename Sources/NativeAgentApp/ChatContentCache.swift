import Foundation

/// Process-local FIFO storage; callers own parsing and admission outside the lock.
final class ChatContentCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Value] = [:]
    private var order: [String] = []
    private var totalChars = 0
    private let capacity = 300
    private let charBudget = 4_000_000

    func lookup(_ content: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return cache[content]
    }

    func insertIfAbsent(_ parsed: Value, for content: String) {
        lock.lock()
        defer { lock.unlock() }
        if cache[content] == nil {
            cache[content] = parsed
            order.append(content)
            totalChars += content.count
            while order.count > capacity || (totalChars > charBudget && order.count > 1) {
                let evicted = order.removeFirst()
                totalChars -= evicted.count
                cache.removeValue(forKey: evicted)
            }
        }
    }
}

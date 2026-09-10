import Foundation

/// One output allowance shared by every provider request in a turn. UTF-8 bytes
/// conservatively bound visible output tokens when an adapter has no tokenizer.
/// Providers with a wire cap also receive the remaining allowance.
public final class TurnTokenBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var text = ""
    private var stopped = false
    public init(tokens: Int) { remaining = max(0, tokens) }
    public var available: Int { lock.lock(); defer { lock.unlock() }; return remaining }
    public var exhausted: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public var partialReply: String { lock.lock(); defer { lock.unlock() }; return text }
    public func take(_ value: String, visible: Bool = true) -> String {
        lock.lock(); defer { lock.unlock() }
        var accepted = ""
        for character in value {
            let size = String(character).utf8.count
            guard size <= remaining else { stopped = true; break }
            remaining -= size
            accepted.append(character)
        }
        if visible { text += accepted }
        if remaining == 0 { stopped = true }
        return accepted
    }
    public func beginRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard remaining > 0, !stopped else { stopped = true; return false }
        if !text.isEmpty { text += "\n\n" }
        return true
    }
}

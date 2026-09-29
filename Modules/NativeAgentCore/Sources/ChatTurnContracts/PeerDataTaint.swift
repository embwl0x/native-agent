import Foundation

/// TASK-LOCAL PROVENANCE FOR A PEER'S WORDS.
///
/// `agent_message` / `agent_read` already label their result
/// `untrusted_remote_data: true` — but that label rode back into the ordinary
/// tool loop as prose, where the model is free to act on it. A remote agent's
/// reply is DATA, and the one thing data must never be is the authority for
/// the next tool call.
///
/// So the label is bound to the TURN instead of to a string. The moment a turn
/// consumes a peer result, this box latches; from then until the turn ends,
/// `PeerDataTaintDispatcher` refuses the effect classes a peer could otherwise
/// have talked the model into: local effects, durable memory/persona writes,
/// disclosure reads, and external sends. The refusal says why, so the model
/// relays the peer's request to the person instead of executing it.
///
/// The scope is exactly one turn: a task-local reference box, latched at most
/// once, discarded when the turn's task tree ends. That IS the "until the next
/// authenticated human turn" boundary — the next turn starts with a fresh box.
public final class PeerDataTaint: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String] = []

    public init() {}

    @TaskLocal public static var current: PeerDataTaint?

    /// Run `operation` under a fresh taint scope, unless one is already bound
    /// (a nested loop must not silently launder its parent's taint).
    public static func withScope<T>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        if current != nil { return try await operation() }
        return try await $current.withValue(PeerDataTaint(), operation: operation, isolation: isolation)
    }

    /// Latch: this turn has now read a remote peer's words.
    public static func markConsumed(peer: String) {
        current?.mark(peer: peer)
    }

    func mark(peer: String) {
        lock.lock(); defer { lock.unlock() }
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "a remote peer" : trimmed
        guard !sources.contains(name), sources.count < 8 else { return }
        sources.append(name)
    }

    public var isTainted: Bool {
        lock.lock(); defer { lock.unlock() }
        return !sources.isEmpty
    }

    public var sourceDescription: String {
        lock.lock(); defer { lock.unlock() }
        return sources.joined(separator: ", ")
    }
}

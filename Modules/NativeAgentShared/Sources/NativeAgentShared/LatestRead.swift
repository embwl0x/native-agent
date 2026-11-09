// Blueprint: | `LatestRead.swift` | `LatestRead`: owner-isolated reads return their result; publication advances only |

/// One owner's snapshot ordering: all readers use `read`, committed writers use `write`, and callers consume their own result rather than the current
/// publication. Publication advances by start order; a pending newer read never blocks an older completed read. No caller keeps publication counters.
public final class LatestRead {
    // Pending identities are ordered only while their reads are in flight. Publication retires its predecessors; no finite ticket can exhaust.
    private final class Ticket {}
    private var pending: [Ticket] = []

    private func begin() -> Ticket {
        let ticket = Ticket()
        pending.append(ticket)
        return ticket
    }

    private func retire(_ ticket: Ticket) {
        pending.removeAll { $0 === ticket }
    }

    private func advance(_ ticket: Ticket) -> Bool {
        guard let position = pending.firstIndex(where: { $0 === ticket }) else { return false }
        pending.removeSubrange(...position)
        return true
    }

    public nonisolated init() {}

    /// Returns this load's value; publishes unless a later-started operation already published. Cancellation returns the value without advancing
    /// publication.
    public func read<Value>(
        isolation: isolated (any Actor)? = #isolation,
        _ load: () async throws -> Value,
        publish: (Value) -> Void
    ) async rethrows -> Value {
        let ticket = begin()
        defer { retire(ticket) }
        let value = try await load()
        if !Task.isCancelled, advance(ticket) {
            publish(value)
        }
        return value
    }

    /// A committed write publishes what it committed, ahead of every read that started before it (those can no longer replace it).
    public func write(_ publish: () -> Void) {
        pending.removeAll()
        publish()
    }
}

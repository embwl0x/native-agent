import Foundation
// Blueprint: | `ProviderReplyWork.swift` | Whole-reply stop ownership: sticky transport stop, producer joins, and cancellation-independent collection through actual exit/drain |

/// One whole reply owns the work it stops. Collection itself stays alive so
/// the provider can close its wire, drain output and publish its actual end.
final class ProviderReplyWork: @unchecked Sendable {
    @TaskLocal static var current: ProviderReplyWork?

    private struct Producer: Sendable {
        let stop: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }
    private let lock = NSLock()
    private var stopped = false
    private var producers: [Producer] = []

    var isStopped: Bool { lock.withLock { stopped } }

    /// HTTP stops its producer task. Pipe-backed producers instead stop their
    /// process, keeping the forwarding task uncancelled until EOF and drain.
    func own(_ task: Task<Void, Never>, stop: (@Sendable () -> Void)? = nil) {
        let producer = Producer(stop: stop ?? { task.cancel() }, join: { await task.value })
        let stopNow = lock.withLock {
            producers.append(producer)
            return stopped
        }
        if stopNow { producer.stop() }
    }

    func stop() {
        let owned = lock.withLock {
            stopped = true
            return producers
        }
        for producer in owned { producer.stop() }
    }

    /// A joined producer can have installed another while it was ending.
    /// Walk every registration, including those made during an earlier join.
    func join() async {
        var joined = 0
        while true {
            let batch = lock.withLock { Array(producers.dropFirst(joined)) }
            guard !batch.isEmpty else { return }
            for producer in batch { await producer.join() }
            joined += batch.count
        }
    }
}

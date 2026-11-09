import Foundation
import Synchronization

// Blueprint: | `ContextHealthEvents.swift` | Root-owned context health invalidations; readers subscribe before reading and release on cancellation |

/// Payload-free edges make health readers measure the owner instead of retaining another health snapshot.
public final class ContextHealthEvents: Sendable {
    private let readers = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    public init() {}

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        readers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.readers.withLock { _ = $0.removeValue(forKey: id) }
        }
        continuation.yield(())
        return stream
    }

    public func signal() {
        let current = readers.withLock { Array($0.values) }
        for reader in current { reader.yield(()) }
    }
}

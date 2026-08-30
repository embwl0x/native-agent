import Foundation
import PersistenceCore

/// App-owned signal adapters for event/deadline background runners. The
/// events are invalidations only: every runner rereads its canonical store.
enum EventDeadlinePhysiology {
    /// `loopId` arms C6 self-write suppression: events observed while every
    /// watched path still carries the generation stamped at the end of that
    /// loop's own last tick are its own echo and are dropped. Omit it (nil) and
    /// every event is delivered, exactly as before.
    static func storeAndFileEvents(
        paths: [URL],
        stores: Set<StoreChange.Store> = [],
        loopId: String? = nil,
        selfWrites: PhysiologySelfWriteRegistry = .shared
    ) -> AsyncStream<Void> {
        let normalized = Set(paths.map(\.standardizedFileURL))
        for path in normalized {
            try? FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        if let loopId {
            selfWrites.register(loopId: loopId, paths: Array(normalized))
        }
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Suppression is evaluated at DELIVERY, not at emit: the generation
        // read has to reflect the file as the consumer would find it, and an
        // FSEvent can arrive long after the write that caused it.
        let deliver: @Sendable () -> Void = { [continuation = pair.continuation] in
            if let loopId, selfWrites.isSelfWriteEcho(loopId: loopId) { return }
            continuation.yield(())
        }
        let watcher = FileChangeWatcher(paths: Array(normalized)) { _ in
            deliver()
        }
        let changes = StoreChangeBus.shared.changes()
        let busTask = Task {
            for await change in changes {
                guard !Task.isCancelled else { return }
                if stores.contains(change.store)
                    || normalized.contains(change.path.standardizedFileURL) {
                    deliver()
                }
            }
        }
        pair.continuation.onTermination = { _ in
            watcher.cancel()
            busTask.cancel()
        }
        return pair.stream
    }
}

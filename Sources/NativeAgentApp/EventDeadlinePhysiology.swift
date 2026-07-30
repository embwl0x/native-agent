import Foundation
import PersistenceCore

/// App-owned signal adapters for event/deadline background runners. The
/// events are invalidations only: every runner rereads its canonical store.
enum EventDeadlinePhysiology {
    static func storeAndFileEvents(
        paths: [URL],
        stores: Set<StoreChange.Store> = []
    ) -> AsyncStream<Void> {
        let normalized = Set(paths.map(\.standardizedFileURL))
        for path in normalized {
            try? FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let watcher = FileChangeWatcher(paths: Array(normalized)) { _ in
            pair.continuation.yield(())
        }
        let changes = StoreChangeBus.shared.changes()
        let busTask = Task {
            for await change in changes {
                guard !Task.isCancelled else { return }
                if stores.contains(change.store)
                    || normalized.contains(change.path.standardizedFileURL) {
                    pair.continuation.yield(())
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

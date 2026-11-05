import BackgroundLoops
import Foundation
import NativeAgentShared
import PersistenceCore

// Blueprint: | `EventDeadlinePhysiology.swift` | `EventDeadlinePhysiology`. |

/// Events invalidate only; runners reread canonical stores.
public enum EventDeadlinePhysiology {
    /// Suppress self-write echoes only while every path matches the loop's completed generation.
    /// Without a loop ID deliver all events; system clock notifications always bypass suppression.
    public static func storeAndFileEvents(
        paths: [URL],
        stores: Set<StoreChange.Store> = [],
        notifications: [Notification.Name] = [],
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
        // Evaluate suppression at delivery because delayed filesystem events must be compared with the consumer's current read.
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
        let notificationTokens = ObservationNotifications(
            center: .default, names: notifications
        ) { [continuation = pair.continuation] in
            continuation.yield(())
        }
        pair.continuation.onTermination = { _ in
            watcher.cancel()
            busTask.cancel()
            notificationTokens.cancel()
        }
        return pair.stream
    }

    /// Arm invalidations before the initial read so racing writes remain buffered.
    @MainActor
    public static func refreshOnChanges(
        paths: [URL],
        stores: Set<StoreChange.Store> = [],
        notifications: [Notification.Name] = [],
        debounceDelay: Duration = .milliseconds(250),
        refresh: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let events = EventDeadlinePhysiology.storeAndFileEvents(
            paths: paths,
            stores: stores,
            notifications: notifications
        )
        let debouncer = StoreReloadDebouncer(delay: debounceDelay) {
            await refresh()
        }
        // Arm before reading so a racing write remains buffered for replay.
        await refresh()
        guard !Task.isCancelled else {
            await debouncer.cancel()
            return
        }
        await debouncer.setVisible(true)

        for await _ in events {
            guard !Task.isCancelled else { break }
            await debouncer.signal()
        }
        await debouncer.cancel()
    }
}

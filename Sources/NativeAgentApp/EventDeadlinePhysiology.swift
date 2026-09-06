import Foundation
import PersistenceCore

/// App-owned signal adapters for event/deadline background runners. The
/// events are invalidations only: every runner rereads its canonical store.
enum EventDeadlinePhysiology {
    /// `loopId` arms C6 self-write suppression: events observed while every
    /// watched path still carries the generation stamped at the end of that
    /// loop's own last tick are its own echo and are dropped. Omit it (nil) and
    /// every event is delivered, exactly as before.
    ///
    /// `notifications` are system notifications that invalidate a runner's
    /// conclusions without touching any watched file — the wall clock and the
    /// time zone (2026-09-06). They are delivered UNCONDITIONALLY: the
    /// self-write echo filter answers "did this loop write these paths", which
    /// has nothing to say about the system clock moving underneath it.
    static func storeAndFileEvents(
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
        let notificationTokens = NotificationObserverTokens(
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
}

/// NotificationCenter's observer tokens are opaque and not `Sendable`, and the
/// stream's termination handler is — so they are held here rather than captured
/// directly (2026-09-06).
private final class NotificationObserverTokens: @unchecked Sendable {
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]

    init(center: NotificationCenter, names: [Notification.Name], deliver: @escaping @Sendable () -> Void) {
        self.center = center
        self.tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in deliver() }
        }
    }

    func cancel() {
        for token in tokens { center.removeObserver(token) }
    }
}

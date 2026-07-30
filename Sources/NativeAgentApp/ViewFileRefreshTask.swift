import Foundation
import PersistenceCore

/// View-lifetime bridge from canonical file/store invalidations to one
/// trailing-edge refresh. This owns no state and publishes no new signal: the
/// files and `StoreChangeBus` remain authoritative, while SwiftUI owns this
/// task's visibility/cancellation lifecycle.
enum ViewFileRefreshTask {
    @MainActor
    static func run(
        paths: [URL],
        stores: Set<StoreChange.Store> = [],
        debounceDelay: Duration = .milliseconds(250),
        refresh: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let events = EventDeadlinePhysiology.storeAndFileEvents(
            paths: paths,
            stores: stores
        )
        let debouncer = StoreReloadDebouncer(delay: debounceDelay) {
            await refresh()
        }
        // Arm the source before the initial read. Any write racing that read
        // remains buffered by the source stream and is replayed below.
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

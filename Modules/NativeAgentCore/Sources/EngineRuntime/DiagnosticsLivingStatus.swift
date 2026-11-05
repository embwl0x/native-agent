import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `DiagnosticsLivingStatus.swift` | Runtime-owned living-status subscriptions; source changes refresh the owner and its face until quit |

extension NativeAgentEngine {
    @MainActor public func refreshDiagnosticsLivingStatus() async {
        await cognitionView.refreshLivingStatus(desk: desk, agentDisplayName: { self.persona.displayName }, dreamErrorDidChange: { _ in })
    }

    @MainActor func observeDiagnosticsLivingStatus() async {
        async let files: Void = LivingStatusFileWatch.observe(dataRoot: dataRoot, availabilityDidChange: { [self] in
            cognitionView.livingWatchAvailability = $0
            cognitionView.livingStatusDidChange?()
        }, refresh: { [self] in await refreshDiagnosticsLivingStatus() })
        let changes = await cognitionView.changes()
        // Subscribe before the first read; process-local changes remain buffered while the read suspends.
        await refreshDiagnosticsLivingStatus()
        await pages.refresh(page: "diagnostics")
        for await _ in changes {
            guard !Task.isCancelled else { return }
            await refreshDiagnosticsLivingStatus()
        }
        await files
    }
}

extension LivingStatusFileWatch {
    @MainActor static func observe(
        dataRoot: URL,
        availabilityDidChange: @escaping @MainActor (Availability) -> Void,
        refresh: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let paths = watchedPaths(dataRoot: dataRoot)
        let events = FileChangeEvents(paths: paths, emitInitial: false)
        defer { events.cancel() }
        let armed = await events.waitUntilArmed()
        guard !Task.isCancelled else { return }
        let unavailable = Availability.unavailable("status files could not be observed")
        availabilityDidChange(armed ? .watching(inputCount: paths.count) : unavailable)
        await refresh()
        guard armed, !Task.isCancelled else { return }
        let debouncer = StoreReloadDebouncer(delay: .milliseconds(250), reload: refresh)
        await debouncer.setVisible(true)
        for await _ in events.stream {
            guard !Task.isCancelled else { break }
            await debouncer.signal()
        }
        await debouncer.cancel()
        if !Task.isCancelled { availabilityDidChange(unavailable) }
    }
}

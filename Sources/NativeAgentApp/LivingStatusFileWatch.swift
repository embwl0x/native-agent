import Foundation
import PersistenceCore

/// The durable inputs read by `LivingStatusPanel` that can change outside this
/// process. This is deliberately a small, consumer-owned list: watching a
/// producer that the panel does not read creates a reassuring refresh signal
/// without changing the displayed state.
enum LivingStatusFileWatch {
    enum Availability: Equatable, Sendable {
        case watching(inputCount: Int)
        case unavailable(String)

        var unavailableMessage: String? {
            guard case let .unavailable(detail) = self else { return nil }
            return "Live status updates are unavailable: \(detail)"
        }
    }

    static func watchedPaths(dataRoot: URL) -> [URL] {
        let desk = SwiftNativeDeskStore(dataRoot: dataRoot)
        return [
            // The process-local cognition stream covers in-process changes;
            // this file covers another process replacing the persisted state.
            dataRoot.appendingPathComponent("cognition/organism_state.json"),
            // `liveState()` reconstructs from both the append-only feed and
            // its materialized snapshot. A Desk commit can update either.
            desk.opsPath,
            desk.statePath,
            dataRoot.appendingPathComponent("workflows/approvals/requests.json"),
            // Dream reads choose the newest dated entry, so the directory—not
            // a guessed filename—is the canonical invalidation boundary.
            dataRoot.appendingPathComponent("dream_diary", isDirectory: true),
        ]
    }

    /// FileChangeWatcher can follow missing targets through a parent vnode, but
    /// it cannot observe a parent that is a regular file or cannot be created.
    /// Make that arming boundary observable rather than leaving the card with
    /// a successful initial read and no future invalidations.
    static func availability(dataRoot: URL) -> Availability {
        let paths = watchedPaths(dataRoot: dataRoot)
        // Deterministic order: Set iteration follows the per-process hash seed,
        // so an unwatchable root could report a different (order-dependent)
        // unavailable reason from run to run. Sorted, the shallowest parent —
        // the data root itself — is always diagnosed first.
        let parents = Set(paths.map { $0.deletingLastPathComponent().standardizedFileURL })
            .sorted { $0.path < $1.path }
        for parent in parents {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    return .unavailable("a status storage folder is not a directory")
                }
            } else {
                do {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                } catch {
                    return .unavailable("a status storage folder could not be prepared")
                }
            }
        }
        return .watching(inputCount: paths.count)
    }

    @MainActor
    static func observe(
        dataRoot: URL,
        debounceDelay: Duration = .milliseconds(250),
        availabilityDidChange: @escaping @MainActor (Availability) -> Void = { _ in },
        refresh: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let availability = availability(dataRoot: dataRoot)
        availabilityDidChange(availability)
        guard case .watching = availability else {
            // Preserve the one canonical read even when live observation cannot
            // be armed; the card will report both the read result and the lost
            // live-update capability instead of quietly retaining stale data.
            await refresh()
            return
        }
        await ViewFileRefreshTask.run(
            paths: watchedPaths(dataRoot: dataRoot),
            debounceDelay: debounceDelay,
            refresh: refresh
        )
    }
}

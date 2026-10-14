import PersistenceCore
// MARK: - liveState replay memo

actor GitHubCommandLiveStateMemo {
    typealias FeedStamp = SnapshotTailOpLog.FeedStamp

    struct LoadResult: Sendable {
        let state: GitHubCommandState
        let stamp: FeedStamp?
    }

    static let maxEntries = 8

    private struct Entry: Sendable {
        let stamp: FeedStamp
        let state: GitHubCommandState
    }

    private struct Pending: Sendable {
        let stamp: FeedStamp
        let task: Task<LoadResult, any Error>
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var pending: [String: Pending] = [:]

    func value(
        key: String,
        stamp: FeedStamp?,
        loader: @escaping @Sendable () async throws -> LoadResult
    ) async throws -> GitHubCommandState {
        guard let stamp else { return try await loader().state }
        if let entry = entries[key], entry.stamp == stamp {
            return entry.state
        }
        if let existing = pending[key], existing.stamp == stamp {
            return try await existing.task.value.state
        }

        let task = Task { try await loader() }
        pending[key] = Pending(stamp: stamp, task: task)
        do {
            let result = try await task.value
            if result.stamp == stamp { store(key: key, stamp: stamp, state: result.state) }
            if pending[key]?.stamp == stamp { pending[key] = nil }
            return result.state
        } catch {
            if pending[key]?.stamp == stamp { pending[key] = nil }
            throw error
        }
    }

    private func store(key: String, stamp: FeedStamp, state: GitHubCommandState) {
        if entries[key] == nil {
            order.append(key)
            while order.count > Self.maxEntries, let oldest = order.first {
                order.removeFirst()
                entries[oldest] = nil
            }
        }
        entries[key] = Entry(stamp: stamp, state: state)
    }

    /// Seed a projection a writer just committed. The caller supplies the
    /// post-write stamp, so a concurrent/out-of-process mutation still misses
    /// this entry and falls back to the canonical feed.
    func prime(key: String, stamp: FeedStamp?, state: GitHubCommandState) {
        guard let stamp else { return }
        store(key: key, stamp: stamp, state: state)
    }
}

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
    private var counters: [String: (hits: Int, misses: Int, coalesced: Int)] = [:]

    func value(
        key: String,
        stamp: FeedStamp?,
        loader: @escaping @Sendable () async throws -> LoadResult
    ) async throws -> GitHubCommandState {
        guard let stamp else { return try await loader().state }
        if let entry = entries[key], entry.stamp == stamp {
            note(key, hit: 1)
            return entry.state
        }
        if let existing = pending[key], existing.stamp == stamp {
            note(key, coalesced: 1)
            return try await existing.task.value.state
        }

        note(key, miss: 1)
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

    private func note(_ key: String, hit: Int = 0, miss: Int = 0, coalesced: Int = 0) {
        if counters[key] == nil, counters.count >= Self.maxEntries * 4 {
            counters.removeAll()
        }
        var value = counters[key] ?? (0, 0, 0)
        value.hits += hit
        value.misses += miss
        value.coalesced += coalesced
        counters[key] = value
    }

    func forget(key: String) {
        entries[key] = nil
        order.removeAll { $0 == key }
        pending[key]?.task.cancel()
        pending[key] = nil
        counters[key] = nil
    }

    func _testStats(key: String) -> (hits: Int, misses: Int, coalesced: Int, entries: Int) {
        let value = counters[key] ?? (0, 0, 0)
        return (value.hits, value.misses, value.coalesced, entries.count)
    }
}

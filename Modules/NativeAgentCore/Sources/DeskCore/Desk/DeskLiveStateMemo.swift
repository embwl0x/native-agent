import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskLiveStateMemo.swift` | Replay memo keyed by the canonical feed stamp |
/// Key replay on the ops path and both files’ stat identities; serve hits only under the ops flock.
/// Memoization skips decoding, preserving lock ordering and compaction isolation.
actor DeskLiveStateMemo {
    typealias FeedStamp = SnapshotTailOpLog.FeedStamp
    /// Bound retained roots so a long-lived process visiting temporary roots cannot grow the map indefinitely.
    static let maxEntries = 8
    private struct Entry: Sendable {
        let stamp: FeedStamp
        let state: DeskState
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    func lookup(key: String, stamp: FeedStamp?) -> DeskState? {
        guard let stamp, let entry = entries[key], entry.stamp == stamp else {
            return nil
        }
        return entry.state
    }
    func store(key: String, stamp: FeedStamp, state: DeskState) {
        if entries[key] == nil {
            order.append(key)
            while order.count > Self.maxEntries, let oldest = order.first {
                order.removeFirst()
                entries[oldest] = nil
            }
        }
        entries[key] = Entry(stamp: stamp, state: state)
    }
}

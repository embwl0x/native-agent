import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskLiveStateMemo.swift` | Replay memo keyed by the canonical feed stamp |
/// Process-wide memo behind `SwiftNativeDeskStore.liveState()`.
///
/// Every entry is keyed on the ops path AND stamped with the stat identity of
/// the two files a replay reads. A hit is only ever served while the caller
/// holds the ops flock, so this is strictly a decode+reduce skip: the lock, the
/// blocking behaviour, and the compaction-straddle guarantee are untouched.
actor DeskLiveStateMemo {
    typealias FeedStamp = SnapshotTailOpLog.FeedStamp
    /// Bound on distinct data roots held at once. Roots are few (live + any
    /// test/secondary root); the cap exists so a long-lived process that walks
    /// many temp roots cannot grow this map without limit — every insert has a
    /// matching eviction.
    static let maxEntries = 8
    private struct Entry: Sendable {
        let stamp: FeedStamp
        let state: DeskState
    }
    private var entries: [String: Entry] = [:]
    /// Least-recently-stored first; the eviction order for `maxEntries`.
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

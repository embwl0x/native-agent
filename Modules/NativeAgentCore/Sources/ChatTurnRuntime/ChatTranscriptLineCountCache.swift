import Foundation
import PersistenceCore
import Darwin
// Blueprint: | `ChatTranscriptLineCountCache.swift` | `ChatTranscriptLineCountCache`: bounded stat-validated counts; writers establish deltas under the transcript flock |

/// Process-wide transcript counts, carried forward under the transcript flock.
/// A filesystem revision stamp validates each entry; changed files are recounted.
final class ChatTranscriptLineCountCache: @unchecked Sendable {
    private struct Entry {
        var stamp: SnapshotTailOpLog.FileStamp
        var count: Int
    }

    static let shared = ChatTranscriptLineCountCache()
    private static let capacity = 128

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Current line count for `path`, recomputing only when the file on disk is
    /// not the one this cache last measured.
    func count(at path: URL, recount: (URL) -> Int) -> Int {
        let key = path.path
        let before = SnapshotTailOpLog.fileStamp(path)
        if let before, before != .absent {
            lock.lock()
            let cached = entries[key]
            lock.unlock()
            if let cached, cached.stamp == before {
                return cached.count
            }
        }
        let counted = recount(path)
        lock.lock()
        // Only cache when the file did not move under the read. If it did, the
        // pairing of (count, stamp) would be a lie — drop it and let the next
        // caller recount.
        if let before, before != .absent, let after = SnapshotTailOpLog.fileStamp(path), before == after {
            makeRoom(for: key)
            entries[key] = Entry(stamp: after, count: counted)
        } else {
            entries[key] = nil
        }
        lock.unlock()
        return counted
    }

    /// Record a count the caller established authoritatively (it just wrote the
    /// file under the lock). Returns the same count for call-site chaining.
    @discardableResult
    func record(count: Int, at path: URL) -> Int {
        let key = path.path
        lock.lock()
        if let stamp = SnapshotTailOpLog.fileStamp(path), stamp != .absent {
            makeRoom(for: key)
            entries[key] = Entry(stamp: stamp, count: count)
        } else {
            entries[key] = nil
        }
        lock.unlock()
        return count
    }

    /// Called with the cache lock held. Eviction only costs a later recount.
    private func makeRoom(for key: String) {
        if entries[key] == nil, entries.count >= Self.capacity, let evicted = entries.keys.first {
            entries.removeValue(forKey: evicted)
        }
    }
}

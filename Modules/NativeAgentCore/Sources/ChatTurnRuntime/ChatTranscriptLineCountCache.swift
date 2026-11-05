import Foundation
import PersistenceCore
import Darwin
// Blueprint: | `ChatTranscriptLineCountCache.swift` | `ChatTranscriptLineCountCache`; Revision-validated counts under transcript lock |

/// Validate cached counts against filesystem revision under the transcript lock; recount changed files.
final class ChatTranscriptLineCountCache: @unchecked Sendable {
    private struct Entry {
        var stamp: SnapshotTailOpLog.FileStamp
        var count: Int
    }

    static let shared = ChatTranscriptLineCountCache()
    private static let capacity = 128

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func count(at path: URL, recount: (URL) throws -> Int) throws -> Int {
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
        let counted = try recount(path)
        lock.lock()
        // Publish only an unchanged file's count and stamp; a moving file must be recounted by the next caller.
        if let before, before != .absent, let after = SnapshotTailOpLog.fileStamp(path), before == after {
            makeRoom(for: key)
            entries[key] = Entry(stamp: after, count: counted)
        } else {
            entries[key] = nil
        }
        lock.unlock()
        return counted
    }

    /// A locked writer's authoritative count may publish directly without rereading the file.
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

    /// Eviction only costs a later recount; the cache lock must be held.
    private func makeRoom(for key: String) {
        if entries[key] == nil, entries.count >= Self.capacity, let evicted = entries.keys.first {
            entries.removeValue(forKey: evicted)
        }
    }
}

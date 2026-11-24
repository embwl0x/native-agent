import Synchronization
import Foundation
import PersistenceCore
import Darwin
// Blueprint: | `ChatTranscriptLineCountCache.swift` | `ChatTranscriptLineCountCache`; Revision-validated counts under transcript lock |

/// Validate cached counts against filesystem revision under the transcript lock; recount changed files.
final class ChatTranscriptLineCountCache: Sendable {
    private struct Entry {
        var stamp: SnapshotTailOpLog.FileStamp
        var count: Int
    }

    static let shared = ChatTranscriptLineCountCache()
    private static let capacity = 128

    private let entries = Mutex<[String: Entry]>([:])

    func count(at path: URL, recount: (URL) throws -> Int) throws -> Int {
        let key = path.path
        let before = SnapshotTailOpLog.fileStamp(path)
        if let before, before != .absent {
            let cached = entries.withLock { $0[key] }
            if let cached, cached.stamp == before {
                return cached.count
            }
        }
        let counted = try recount(path)
        entries.withLock { entries in
            // Publish only an unchanged file's count and stamp; a moving file must be recounted by the next caller.
            if let before, before != .absent, let after = SnapshotTailOpLog.fileStamp(path), before == after {
                makeRoom(&entries, for: key)
                entries[key] = Entry(stamp: after, count: counted)
            } else {
                entries[key] = nil
            }
        }
        return counted
    }

    /// A locked writer's authoritative count may publish directly without rereading the file.
    @discardableResult
    func record(count: Int, at path: URL) -> Int {
        let key = path.path
        entries.withLock { entries in
            if let stamp = SnapshotTailOpLog.fileStamp(path), stamp != .absent {
                makeRoom(&entries, for: key)
                entries[key] = Entry(stamp: stamp, count: count)
            } else {
                entries[key] = nil
            }
        }
        return count
    }

    /// Eviction only costs a later recount; the cache lock must be held.
    private func makeRoom(_ entries: inout [String: Entry], for key: String) {
        if entries[key] == nil, entries.count >= Self.capacity, let evicted = entries.keys.first {
            entries.removeValue(forKey: evicted)
        }
    }
}

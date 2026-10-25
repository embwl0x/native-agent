// The Knowledge Graph's handle on memory.sqlite.
//
// memory.sqlite has ONE owner: MemoryV2's MemoryStorage opens it, and its
// migrator alone shapes it (every kg_* table included). The graph never opens
// a connection or creates a table of its own — before 2026-09-26 this file
// held a second DatabasePool writing the same file beside MemoryStorage's and
// completed the kg_* schema itself. Now `pool(at:)` returns the owning
// MemoryStorage's pool, resolved directly within MemoryV2.
//
// Lifecycle (every add has a remove):
//   - ADD: the first `pool(at:)` for a path asks the owner for its pool and
//     remembers it. A missing file throws `.databaseMissing` without asking —
//     the graph never causes a store to be created.
//   - REMOVE on file deletion: a missing file drops the entry, so a later
//     recreate resolves the owner again.
//   - REMOVE on failure: an owner that throws leaves no entry; the next call
//     asks again.
//
// Concurrency: the first caller for a path parks a resolving Task in the
// dictionary before its suspension point, so concurrent callers await the
// same resolution instead of asking the owner twice.

import Foundation
import GRDB
// Blueprint: | `KnowledgeGraph+PoolCache.swift` | Direct canonical MemoryStorage resolution with missing-file refusal, per-path single-flight and failed-resolution eviction; no launch owner-registration port |

public actor KnowledgeGraphPoolCache {
    public static let shared = KnowledgeGraphPoolCache()

    public enum PoolError: Error, Sendable, Equatable {
        /// The database file does not exist at the given path.
        case databaseMissing(String)
    }

    private var entries: [String: Task<DatabasePool, Error>] = [:]

    public init() {}

    /// The owning MemoryStorage's pool for `url`. Throws `.databaseMissing`
    /// when the file does not exist; an owner failure propagates.
    public func pool(at url: URL) async throws -> DatabasePool {
        let key = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: key) else {
            entries.removeValue(forKey: key)
            throw PoolError.databaseMissing(key)
        }
        if let pending = entries[key] {
            return try await pending.value
        }
        let target = URL(fileURLWithPath: key)
        let resolving = Task {
            let memoryDir = target.deletingLastPathComponent()
            guard target.lastPathComponent == "memory.sqlite",
                  memoryDir.lastPathComponent == "memory" else {
                throw MemoryStorageError.databaseUnavailable(
                    "Not a NativeAgent memory store: \(target.path)"
                )
            }
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(
                dataRoot: memoryDir.deletingLastPathComponent()
            )
            return storage.dbPool
        }
        entries[key] = resolving
        do {
            return try await resolving.value
        } catch {
            if entries[key] == resolving { entries.removeValue(forKey: key) }
            throw error
        }
    }
}

// MemoryStorage alone opens and migrates memory.sqlite. Missing files throw without creating storage and drop cached pools; owner failures leave no entry.
// Cache each resolving task before suspension so concurrent callers share one owner resolution.

import Foundation
import GRDB
// Blueprint: | `KnowledgeGraph+PoolCache.swift` | MemoryStorage pool resolution, missing-file refusal and per-path single-flight |

public actor KnowledgeGraphPoolCache {
    public static let shared = KnowledgeGraphPoolCache()

    public enum PoolError: Error, Sendable, Equatable {
        case databaseMissing(String)
    }

    private var entries: [String: Task<DatabasePool, Error>] = [:]

    public init() {}

    /// Resolve the owner's pool without creating a missing file; propagate owner failures.
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

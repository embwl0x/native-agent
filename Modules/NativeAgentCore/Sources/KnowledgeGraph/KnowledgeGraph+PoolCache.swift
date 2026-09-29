// The Knowledge Graph's handle on memory.sqlite.
//
// memory.sqlite has ONE owner: MemoryV2's MemoryStorage opens it, and its
// migrator alone shapes it (every kg_* table included). The graph never opens
// a connection or creates a table of its own — before 2026-09-26 this file
// held a second DatabasePool writing the same file beside MemoryStorage's and
// completed the kg_* schema itself. Now `pool(at:)` returns the owning
// MemoryStorage's pool, reached through the owner the app installs at launch
// (`installOwner`; MemoryV2 imports this module, so the dependency cannot
// point the other way).
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

public actor KnowledgeGraphPoolCache {
    public static let shared = KnowledgeGraphPoolCache()

    public enum PoolError: Error, Sendable, Equatable {
        /// The database file does not exist at the given path.
        case databaseMissing(String)
        /// No memory.sqlite owner was installed in this process.
        case ownerNotInstalled(String)
    }

    /// Resolves memory.sqlite's path to its owning storage's pool.
    public typealias Owner = @Sendable (URL) async throws -> DatabasePool

    private static let ownerLock = NSLock()
    nonisolated(unsafe) private static var owner: Owner?

    /// Install memory.sqlite's owner. Called once at launch, before any graph
    /// read or write.
    public static func installOwner(_ newOwner: @escaping Owner) {
        ownerLock.lock()
        owner = newOwner
        ownerLock.unlock()
    }

    private static func installedOwner() -> Owner? {
        ownerLock.lock()
        defer { ownerLock.unlock() }
        return owner
    }

    private var entries: [String: Task<DatabasePool, Error>] = [:]

    public init() {}

    /// The owning MemoryStorage's pool for `url`. Throws `.databaseMissing`
    /// when the file does not exist and `.ownerNotInstalled` when no owner
    /// was installed; an owner failure propagates.
    public func pool(at url: URL) async throws -> DatabasePool {
        let key = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: key) else {
            entries.removeValue(forKey: key)
            throw PoolError.databaseMissing(key)
        }
        if let pending = entries[key] {
            return try await pending.value
        }
        guard let owner = Self.installedOwner() else {
            throw PoolError.ownerNotInstalled(key)
        }
        let target = URL(fileURLWithPath: key)
        let resolving = Task { try await owner(target) }
        entries[key] = resolving
        do {
            return try await resolving.value
        } catch {
            if entries[key] == resolving { entries.removeValue(forKey: key) }
            throw error
        }
    }
}

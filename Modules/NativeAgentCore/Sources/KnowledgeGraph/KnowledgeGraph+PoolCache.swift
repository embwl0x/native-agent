// U5 W-C (2026-06-11): process-wide cached DatabasePool for the KG SQLite store.
//
// Before this file, every KG read constructed a FRESH DatabasePool per query
// (KnowledgeGraph+SQLite.swift:41/:67) and the indexer held its own private
// pool — connection churn on every Graph-tab render and every chat search_kg
// call. One actor now owns at most `maxEntries` pools keyed on the canonical
// file path; the loader and the indexer resolve through it, so the whole
// module shares one pool per memory.sqlite.
//
// Lifecycle (every add has a remove):
//   - ADD: the first `pool(at:)` for a path opens the pool and ensures the
//     kg_* schema (idempotent CREATE TABLE IF NOT EXISTS).
//   - REMOVE on file replace: every `pool(at:)` call re-stats the file; if the
//     (device, inode) identity changed (atomic replace, restore-from-backup),
//     the stale pool entry is dropped and a fresh pool is opened.
//   - REMOVE on file deletion: a missing file drops the entry and throws
//     `.databaseMissing`, so a later recreate reopens cleanly.
//   - REMOVE on LRU overflow: at most `maxEntries` pools are retained
//     (production uses exactly one path; the headroom is for tests that churn
//     temp directories).
//   - REMOVE on demand: `invalidate(path:)` / `invalidateAll()` for tests and
//     restore flows.
//   Dropping an entry releases the cache's reference; GRDB closes the pool's
//   connections when the last reference goes away, and any in-flight caller
//   holding a local reference finishes safely on the old pool first.
//
// Concurrency: `pool(at:)` is fully SYNCHRONOUS inside the actor — there is no
// suspension point between the stat, the dictionary read, and the dictionary
// write — so two concurrent callers can never interleave mid-decision; the
// second caller always observes the first caller's completed entry.
// DatabasePool itself is Sendable and thread-safe; sharing one instance across
// tasks is GRDB's supported usage.

import Foundation
import GRDB

public actor KnowledgeGraphPoolCache {
    public static let shared = KnowledgeGraphPoolCache()

    public enum PoolError: Error, Sendable, Equatable {
        /// The database file does not exist at the given path.
        case databaseMissing(String)
    }

    private struct Entry {
        var pool: DatabasePool
        var device: UInt64
        var inode: UInt64
        var lastUsed: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var useClock: UInt64 = 0
    private let maxEntries: Int

    /// Production has exactly one memory.sqlite; the default headroom is for
    /// tests that exercise multiple temp stores in one process.
    public init(maxEntries: Int = 4) {
        self.maxEntries = max(1, maxEntries)
    }

    /// Return the cached pool for `url`, opening it (and ensuring the kg_*
    /// schema) on first use, and transparently replacing it when the on-disk
    /// file's identity changes (atomic replace / restore). Throws
    /// `.databaseMissing` when the file does not exist — this cache never
    /// CREATES a database file; the schema-ensure only runs against a file
    /// some writer (MemoryStorage, the indexer's first write) already created.
    public func pool(at url: URL) throws -> DatabasePool {
        let key = url.standardizedFileURL.path
        guard let identity = Self.fileIdentity(path: key) else {
            // File gone — drop any stale entry so a future recreate reopens.
            entries.removeValue(forKey: key)
            throw PoolError.databaseMissing(key)
        }
        useClock += 1
        if var entry = entries[key] {
            if entry.device == identity.device && entry.inode == identity.inode {
                entry.lastUsed = useClock
                entries[key] = entry
                return entry.pool
            }
            // Same path, different file (replaced underneath us) — retire.
            entries.removeValue(forKey: key)
        }
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(2)
        // Same WAL bound as MemoryStorage's pool (gpt-5.5 review 2026-07-02):
        // both pools write the same memory.sqlite; a cap on only one leaves
        // KG-only write bursts free to push the WAL high-water mark back up.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_size_limit = 4194304")
        }
        let pool = try DatabasePool(path: key, configuration: config)
        try SwiftNativeKnowledgeGraphIndexer.ensureSchema(pool)
        if entries.count >= maxEntries,
           let lru = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            entries.removeValue(forKey: lru)
        }
        entries[key] = Entry(
            pool: pool,
            device: identity.device,
            inode: identity.inode,
            lastUsed: useClock
        )
        return pool
    }

    /// Drop the cached pool for a path (restore flows, tests). The next
    /// `pool(at:)` reopens fresh.
    public func invalidate(path: URL) {
        entries.removeValue(forKey: path.standardizedFileURL.path)
    }

    /// Drop every cached pool (tests).
    public func invalidateAll() {
        entries.removeAll()
    }

    /// Test seam: number of live cached pools.
    public func entryCount() -> Int { entries.count }

    /// (device, inode) identity — changes on atomic replace (temp + rename) or
    /// delete + recreate; does NOT change on in-place writes (SQLite mutates
    /// the same inode; WAL checkpoints keep it). nil when the file is missing.
    private static func fileIdentity(path: String) -> (device: UInt64, inode: UInt64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return (device, inode)
    }
}

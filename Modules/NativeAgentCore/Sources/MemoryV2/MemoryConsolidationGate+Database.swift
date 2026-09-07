import CryptoKit
import Foundation
import GRDB
import NativeAgentCore
import OSLog

extension MemoryConsolidationGate {
    /// Thrown by transactionalTableSwap when the IN-TRANSACTION fingerprint
    /// check finds live drifted from the staged manifest. The transaction
    /// rolls back; the caller turns it into a stale_refused terminal.
    struct SwapStaleError: Error {}

    /// ONE immediate transaction: replace memories/proposals/tombstones
    /// with the candidate's rows. Derived tables stay in place here, then the
    /// post-commit projection reconciler regenerates USER.md, Spotlight, the
    /// MemoryV2-owned KG rows, and Fluid Context. use_count/last_used_at accrued
    /// on live after staging are
    /// preserved as MAX(live, candidate) per row. ATTACH must happen outside
    /// the transaction (SQLite forbids ATTACH inside one).
    ///
    /// TOCTOU FIX (review finding 2, 2026-06-10): the AUTHORITATIVE
    /// staleness check runs INSIDE the .immediate transaction, under the
    /// same write lock that performs the table replacement. A chat turn
    /// that writes a memory between the caller's pre-check and this
    /// transaction changes the in-transaction fingerprint → SwapStaleError
    /// → rollback. No window remains in which a fresh write can be deleted
    /// by the swap.
    static func transactionalTableSwap(
        livePath: URL,
        candidatePath: URL,
        expectedLiveFingerprint: String,
        memoryLimit: Int = memoryStoredRowCap,
        appliedRunId: String? = nil
    ) throws -> [StoredMemory] {
        var config = Configuration()
        config.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: livePath.path, configuration: config)
        defer { try? queue.close() }
        var boundEvictions: [StoredMemory] = []
        try queue.inDatabase { db in
            try db.execute(sql: "ATTACH DATABASE ? AS cand", arguments: [candidatePath.path])
            do {
                try db.inTransaction(.immediate) {
                    // .immediate acquired the write lock — no other writer
                    // can slip in past this point. Re-check NOW.
                    let liveFP = try fingerprint(in: db)
                    guard liveFP == expectedLiveFingerprint else {
                        throw SwapStaleError()
                    }
                    // User, 2026-09-06: USAGE VETOES EVICTION AT SWAP TIME.
                    // The candidate archives rows that were unused when it was
                    // staged (archiveIfStillUnused re-checks use_count == 0, but
                    // only inside the candidate db). The fingerprint deliberately
                    // excludes use_count, so recall bumps between stage and
                    // approve leave the candidate green — and this INSERT used to
                    // copy `c.status` verbatim, archiving a row the user reached
                    // for in the meantime while simultaneously carrying its grown
                    // use count over. `c.use_count` IS the staged snapshot, so
                    // `lu.use_count > c.use_count` means "used since staging";
                    // when that row is still live-active, keep it active. Any
                    // hygiene metadata the candidate wrote comes along, but the
                    // status is authoritative and the next weekly pass re-decides
                    // with the usage now visible.
                    try db.execute(sql: """
                        CREATE TEMP TABLE _live_usage AS
                          SELECT id, use_count, last_used_at, status FROM memories;
                        DELETE FROM memories;
                        INSERT INTO memories
                          (id, content, persona_id, source, confidence,
                           created_at, updated_at, embedding, status, metadata_json,
                           use_count, last_used_at, lifecycle, embedding_epoch,
                           valid_from, valid_to, observed_at, evidence_json)
                        SELECT c.id, c.content, c.persona_id, c.source, c.confidence,
                               c.created_at, c.updated_at, c.embedding,
                               CASE WHEN c.status = 'archived'
                                     AND lu.status = 'active'
                                     AND COALESCE(lu.use_count, 0) > COALESCE(c.use_count, 0)
                                    THEN lu.status ELSE c.status END,
                               c.metadata_json,
                               MAX(c.use_count, COALESCE(lu.use_count, 0)),
                               COALESCE(MAX(c.last_used_at, lu.last_used_at),
                                        c.last_used_at, lu.last_used_at),
                               c.lifecycle, c.embedding_epoch,
                               c.valid_from, c.valid_to, c.observed_at, c.evidence_json
                        FROM cand.memories c
                        LEFT JOIN _live_usage lu ON lu.id = c.id;
                        DELETE FROM proposals;
                        INSERT INTO proposals
                          (id, content, persona_id, source, staged_at, status,
                           resolved_at, rejection_reason, embedding, metadata_json, embedding_epoch)
                        SELECT id, content, persona_id, source, staged_at, status,
                               resolved_at, rejection_reason, embedding, metadata_json, embedding_epoch
                        FROM cand.proposals;
                        DELETE FROM tombstones;
                        INSERT INTO tombstones
                          (content_hash, content, rejected_at, reason, embedding, embedding_epoch)
                        SELECT content_hash, content, rejected_at, reason, embedding, embedding_epoch
                        FROM cand.tombstones;
                        DROP TABLE _live_usage;
                    """)
                    boundEvictions = try MemoryStorage.pruneMemoriesToBound(
                        in: db,
                        limit: memoryLimit
                    )
                    // User, 2026-09-06: the applied marker commits WITH the
                    // swap. See `appliedMarkerTable` — a marker written after
                    // the transaction returns leaves a window in which a
                    // committed swap reads as stale.
                    if let appliedRunId {
                        try db.execute(sql: """
                            CREATE TABLE IF NOT EXISTS \(appliedMarkerTable) (
                              run_id TEXT PRIMARY KEY,
                              applied_at TEXT NOT NULL
                            )
                        """)
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO \(appliedMarkerTable) "
                                + "(run_id, applied_at) VALUES (?, ?)",
                            arguments: [appliedRunId, iso8601(Date())]
                        )
                    }
                    return .commit
                }
            } catch {
                try? db.execute(sql: "DETACH DATABASE cand")
                throw error
            }
            try db.execute(sql: "DETACH DATABASE cand")
        }
        return boundEvictions
    }

    /// Transactionally-consistent pre-swap backup via the SQLite online
    /// backup API (robust against concurrent WAL writers — the fix wave-1's
    /// checkpoint+copy comment wished for).
    static func backupLiveStore(livePath: URL, dataRoot: URL) throws -> String {
        let suffix = UUID().uuidString.lowercased().prefix(8)
        let dir = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("pre-consolidation-\(Self.timestamp())-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("memory.sqlite")
        try onlineBackup(from: livePath, to: dest)
        return dir.path
    }

    /// Pre-swap backups accumulate one full store copy per applied swap and
    /// nothing ever removed them. RETENTION (union, not intersection): a
    /// backup survives if it is among the newest `keepNewest` OR younger than
    /// `maxAge`. Only the two together bound the directory — newest-N alone
    /// discards a recent burst's history, age alone keeps nothing after a
    /// long idle stretch.
    ///
    /// Dated from the directory NAME (`pre-consolidation-<ts>-<suffix>`, UTC
    /// and lexicographically sortable). A directory whose name does not parse
    /// is never counted and never deleted — an unknown age is not an old age.
    /// Best-effort: a failed removal is logged, never thrown.
    static let backupRetentionKeepNewest = 5
    static let backupRetentionMaxAge: TimeInterval = 30 * 24 * 60 * 60

    @discardableResult
    static func sweepBackups(
        dataRoot: URL,
        now: Date = Date(),
        keepNewest: Int = backupRetentionKeepNewest,
        maxAge: TimeInterval = backupRetentionMaxAge
    ) -> [String] {
        let root = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        // Newest first; ties broken by name so the order is total.
        let dated: [(name: String, date: Date)] = names
            .compactMap { name in
                guard let date = backupDirectoryDate(name) else { return nil }
                return (name, date)
            }
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.name > $1.name
            }
        var removed: [String] = []
        for (index, entry) in dated.enumerated() {
            guard index >= keepNewest else { continue }
            // Boundary: exactly `maxAge` old is still WITHIN the window.
            guard now.timeIntervalSince(entry.date) > maxAge else { continue }
            do {
                try fm.removeItem(at: root.appendingPathComponent(entry.name, isDirectory: true))
                removed.append(entry.name)
            } catch {
                logger.error("consolidation backup sweep: could not remove \(entry.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if !removed.isEmpty {
            logger.info("consolidation backup sweep: removed \(removed.count, privacy: .public) backup(s), kept \(dated.count - removed.count, privacy: .public)")
        }
        return removed
    }

    /// `pre-consolidation-<yyyyMMdd'T'HHmmss'Z'>-<suffix>` → its stamp.
    static func backupDirectoryDate(_ name: String) -> Date? {
        let prefix = "pre-consolidation-"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: String(rest[rest.startIndex..<dash]))
    }

    /// SQLite online backup source → dest (full copy, consistent snapshot).
    static func onlineBackup(from source: URL, to dest: URL) throws {
        var sourceConfig = Configuration()
        sourceConfig.busyMode = .timeout(5)
        sourceConfig.readonly = true
        let sourceQueue = try DatabaseQueue(path: source.path, configuration: sourceConfig)
        defer { try? sourceQueue.close() }
        var destConfig = Configuration()
        destConfig.busyMode = .timeout(5)
        let destQueue = try DatabaseQueue(path: dest.path, configuration: destConfig)
        defer { try? destQueue.close() }
        try sourceQueue.backup(to: destQueue)
    }

    // MARK: - Fingerprint
    //
    // SHA256 over the content-bearing columns of memories + proposals +
    // tombstones, sorted by id. DELIBERATELY EXCLUDES use_count and
    // last_used_at: recall access bumps must not invalidate a staged
    // candidate (the swap carries those signals over instead).
    // Proposal metadata IS canonical evidence: repeated observations update
    // supporting sessions, recurrence, and confidence without changing status
    // or resolved_at. Excluding it lets an approved stale candidate overwrite
    // newer corroboration. Existing pre-metadata fingerprints fail the normal
    // integrity check safely and require a newly staged candidate.
    // 2026-07-21 audit fix: INCLUDES embedding_epoch per row and the
    // memory_embedding_state row. An epoch ACTIVATION between stage and
    // approve rewrites embedding/embedding_epoch WITHOUT touching updated_at
    // and advances active_epoch — the old fingerprint stayed green, the swap
    // installed old-epoch vectors under the new active_epoch, and recall's
    // epoch filter matched zero rows (silent total recall blackout). With
    // these columns hashed, the in-transaction re-check throws SwapStaleError
    // instead of installing mismatched vectors (fail-closed).

    static func fingerprint(ofDatabaseAt path: URL) throws -> String {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.readonly = true
        let queue = try DatabaseQueue(path: path.path, configuration: config)
        defer { try? queue.close() }
        return try queue.read { db in try fingerprint(in: db) }
    }

    /// Fingerprint from an ALREADY-OPEN connection — the shape the swap
    /// transaction needs for its in-lock staleness re-check. Tables are
    /// `main.`-qualified so the result is unaffected by the attached
    /// candidate database during the swap.
    static func fingerprint(in db: Database) throws -> String {
        var hasher = SHA256()
        let memories = try Row.fetchAll(db, sql: """
            SELECT id, updated_at, status, content, COALESCE(metadata_json, '') AS meta,
                   COALESCE(embedding_epoch, '') AS epoch
            FROM main.memories ORDER BY id
        """)
        for row in memories {
            let line = "M|\(row["id"] as String? ?? "")|\(row["updated_at"] as String? ?? "")|"
                + "\(row["status"] as String? ?? "")|\(row["content"] as String? ?? "")|"
                + "\(row["meta"] as String? ?? "")|\(row["epoch"] as String? ?? "")\n"
            hasher.update(data: Data(line.utf8))
        }
        let epochState = try Row.fetchAll(db, sql: """
            SELECT id, COALESCE(active_epoch, '') AS active,
                   COALESCE(previous_epoch, '') AS previous,
                   COALESCE(activated_at, '') AS activated, rollback_available
            FROM main.memory_embedding_state ORDER BY id
        """)
        for row in epochState {
            let line = "E|\(row["id"] as Int? ?? 0)|\(row["active"] as String? ?? "")|"
                + "\(row["previous"] as String? ?? "")|\(row["activated"] as String? ?? "")|"
                + "\(row["rollback_available"] as Int? ?? 0)\n"
            hasher.update(data: Data(line.utf8))
        }
        let proposals = try Row.fetchAll(db, sql: """
            SELECT id, status, COALESCE(resolved_at, '') AS resolved, content,
                   COALESCE(metadata_json, '') AS meta
            FROM main.proposals ORDER BY id
        """)
        for row in proposals {
            let line = "P|\(row["id"] as String? ?? "")|\(row["status"] as String? ?? "")|"
                + "\(row["resolved"] as String? ?? "")|\(row["content"] as String? ?? "")|"
                + "\(row["meta"] as String? ?? "")\n"
            hasher.update(data: Data(line.utf8))
        }
        let tombstones = try Row.fetchAll(
            db, sql: "SELECT content_hash FROM main.tombstones ORDER BY content_hash")
        for row in tombstones {
            hasher.update(data: Data("T|\(row["content_hash"] as String? ?? "")\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Diff

    static func computeDiff(
        livePath: URL, candidatePath: URL, plan: ConsolidationReport
    ) throws -> MemoryConsolidationDiff {
        func counts(_ path: URL) throws -> (activeMemories: Int, pendingProposals: Int) {
            var config = Configuration()
            config.busyMode = .timeout(5)
            config.readonly = true
            let queue = try DatabaseQueue(path: path.path, configuration: config)
            defer { try? queue.close() }
            return try queue.read { db in
                let mem = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM memories WHERE status = 'active'") ?? 0
                let prop = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM proposals WHERE status = 'pending'") ?? 0
                return (mem, prop)
            }
        }
        let live = try counts(livePath)
        let cand = try counts(candidatePath)
        return MemoryConsolidationDiff(
            memoriesActiveBefore: live.activeMemories,
            memoriesActiveAfter: cand.activeMemories,
            proposalsPendingBefore: live.pendingProposals,
            proposalsPendingAfter: cand.pendingProposals,
            accepted: plan.autoAccepted,
            merged: plan.duplicatesMerged,
            archived: plan.staleArchived
        )
    }

}

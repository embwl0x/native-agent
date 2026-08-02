import Foundation

// MARK: - SnapshotTailOpLog — shared snapshot+tail op-log engine
//
// Three append-only op-log stores (DeskStore, GitHubCommandStore, and — as of
// B4/2026-07-17 — SwiftNativeTaskLedger) bound their feeds the same way: once
// the feed crosses a threshold, the reduced state through some `lastCompactedOpId`
// is snapshotted into a base file and the op-log is truncated to a kept tail.
// Replay is then `base + ops that FOLLOW lastCompactedOpId`.
//
// WHY A HELPER SET, NOT A SINGLE GENERIC `SnapshotTailOpLog<Op, State>`:
// the three base FILES are byte-incompatible on disk and must stay so (live
// data must keep loading, and both Desk's and GitHubCommand's decoders were
// review-hardened TODAY — "preserve exactly"):
//   • DeskCompactionBase carries two extra top-level ledgers folded from RAW op
//     history (`aliasHighWater`, `lastNonTerminal`) plus a strict round-trip
//     decode gate.
//   • GitHubCommandCompactionBase carries `tailFirstOpId` — the lock-free
//     reader's torn-read consistency proof — and keeps a NON-empty tail.
//   • TaskLedgerCompactionBase carries an ordered array of compacted per-task
//     states.
// A single generic envelope could not reproduce all three layouts without
// changing every existing base file's bytes and breaking those hardened
// decoders. So each store keeps its OWN base type and its own read-consistency
// wrapper, and they share only the two byte-neutral pieces of the engine that
// are provably identical across all three:
//   1. `dropCompactedPrefix` — the prefix-drop scan (return the ops that follow
//      `lastCompactedOpId`; a no-op when the id is absent — genesis / already-tail).
//   2. `commitCompaction` — the atomic snapshot-BEFORE-truncate write sequence
//      (write the base, THEN rewrite the op-log to the kept tail). Base-first is
//      the crash-safety invariant: a crash between the two leaves the full
//      op-log intact and the replay prefix-drop heals it (never lost, never
//      double-applied).
public enum SnapshotTailOpLog {

    // MARK: - The unknown-row policy (audit 2026-08-02, finding 1)
    //
    // COMPACTION IS THE ONLY IRREVERSIBLE STEP IN THIS ENGINE. Reading is
    // tolerant by design — an op token a build does not recognise is skipped,
    // and a torn trailing line is ignored — and that tolerance is correct for
    // READS: an older binary should still be able to show the desk rather than
    // refuse to start. But `commitCompaction` snapshots the state folded from
    // the rows this build COULD decode and then rewrites the op-log, so every
    // row it could not decode is deleted from the only place it existed.
    //
    // The realistic trigger is a version skew, not corruption: DeskSweepCLI and
    // task-ledger ship as separate SwiftPM products and nothing forces them to
    // match the running .app. A newer app writes `set_defer_until`; a stale CLI
    // reads the feed, skips those rows, appends one op, crosses the threshold —
    // and every defer on the desk is gone, silently and unrecoverably.
    //
    // POLICY: REFUSE TO COMPACT WHILE ANY ROW IS UNUSABLE. Not "carry the
    // unknown rows into the new tail" — that alternative loses on all three
    // counts: (a) Desk keeps an EMPTY tail and GitHubCommand's tail head is its
    // torn-read consistency proof (`tailFirstOpId`), so smuggling foreign rows
    // into either tail breaks a hardened invariant; (b) the carried rows sit
    // BEFORE `lastCompactedOpId` positionally, so the very next
    // `dropCompactedPrefix` would drop them anyway — preservation in name only;
    // (c) it would still be wrong on ORDER, since a preserved row would replay
    // after ops that originally preceded it.
    //
    // Refusing costs an unbounded op-log; it never costs data. The feed keeps
    // growing until a build that understands the rows compacts it — which is
    // exactly the self-healing behaviour we want, and it is loud (see
    // `noteIntegrity`) rather than quiet.

    /// What one read of an op-log FILE could not use.
    public struct OpLogIntegrity: Sendable, Equatable {
        /// Lines that are not parseable JSON at all — EXCLUDING a tolerated
        /// torn trailing line (see `trailingPartialLine`).
        public var malformedLineCount: Int
        /// Rows that parsed as JSON but carried an op token this build does not
        /// know. A NEWER writer's op seen through an OLDER binary.
        public var undecodableRowCount: Int
        /// The final line was torn (the file does not end in a newline) — an
        /// append that had not landed whole when we read. Tolerated by design;
        /// reported so "we dropped something" is never invisible.
        public var trailingPartialLine: Bool
        /// PHYSICAL rows in the feed file — decodable or not. THE COMPACTION
        /// THRESHOLD KEYS ON THIS (gpt-5.5 review 2026-08-02, finding 2), never
        /// on the decoded-op count: a stale binary looking at 100k rows it does
        /// not understand plus 10 it does would otherwise compute a feed size of
        /// 10, sit under every threshold, and never reach `mayCompact` — so the
        /// refusal warning that is the only signal of the wedge never fires
        /// while the file grows without bound.
        public var physicalRowCount: Int

        public init(
            malformedLineCount: Int = 0,
            undecodableRowCount: Int = 0,
            trailingPartialLine: Bool = false,
            physicalRowCount: Int = 0
        ) {
            self.malformedLineCount = malformedLineCount
            self.undecodableRowCount = undecodableRowCount
            self.trailingPartialLine = trailingPartialLine
            self.physicalRowCount = physicalRowCount
        }

        public static let clean = OpLogIntegrity()

        /// Rows this build could not use. A torn trailing line does NOT count:
        /// it is a write in flight, not a row we are about to destroy, and the
        /// writer re-appends it. Blocking compaction on it would let one
        /// unlucky read wedge compaction for good.
        public var unusableRowCount: Int { malformedLineCount + undecodableRowCount }

        /// True when nothing was skipped — the only state in which compaction
        /// may rewrite the feed.
        public var isClean: Bool { unusableRowCount == 0 }

        /// The row count a compaction threshold must be compared against: the
        /// PHYSICAL size of the feed, never the decoded-op count. `max` with a
        /// caller-supplied decoded count is deliberate belt-and-braces — a
        /// conformer that under-reports physical rows (0 from a stale
        /// `JSONLReadReport`) then still thresholds on what it could decode,
        /// i.e. the old behaviour, instead of never compacting at all.
        public func feedRowCount(decodedCount: Int) -> Int {
            max(decodedCount, physicalRowCount)
        }

        /// The same integrity after `count` rows were appended to the file this
        /// read described. Used by the in-lock append paths, which know the
        /// post-append file is the pre-append file plus their own rows.
        public func appendingRows(_ count: Int) -> OpLogIntegrity {
            var next = self
            next.physicalRowCount += count
            return next
        }

        public var summary: String {
            "malformedLines=\(malformedLineCount) undecodableRows=\(undecodableRowCount) trailingPartial=\(trailingPartialLine)"
        }
    }

    // MARK: - The health surface (gpt-5.5 review 2026-08-02, finding 3)
    //
    // Refusing to compact trades liveness for safety, and the trade was only
    // ever visible as a deduped stderr line — invisible in a GUI app. One
    // future-format row can wedge compaction for weeks while every append
    // replays an ever-longer feed, and the first symptom User would see is the
    // desk getting slow. `OpLogHealth` is the readable version of that state:
    // one value per feed, carrying BOTH the undecodable-row count and the
    // physical size, so Doctor can say "this feed is stuck AND it is now 40k
    // rows" before it hurts. The Doctor check that renders it lives in
    // DoctorChecks (`OpLogHealthCheck`) — this type is the shared vocabulary,
    // not a parallel reporting lane.

    /// One op-log feed's health: what it cannot decode plus how big it has got.
    public struct OpLogHealth: Sendable, Equatable {
        public enum Status: String, Sendable, Equatable {
            /// Nothing skipped and the feed is within its normal band.
            case ok
            /// The feed is bigger than a healthy compaction cycle should leave
            /// it, or a torn trailing line was seen. Not yet harmful.
            case warn
            /// Rows this build cannot use — compaction is REFUSING to run and
            /// the feed cannot shrink until a build that understands them runs.
            case blocked
        }

        public let feed: String
        public let path: URL
        /// Physical rows in the feed file right now.
        public let physicalRowCount: Int
        /// Bytes on disk. Zero when the feed file does not exist yet.
        public let byteCount: Int
        /// The row count at which this feed's store compacts.
        public let compactionThreshold: Int
        public let integrity: OpLogIntegrity

        public init(
            feed: String,
            path: URL,
            physicalRowCount: Int,
            byteCount: Int,
            compactionThreshold: Int,
            integrity: OpLogIntegrity
        ) {
            self.feed = feed
            self.path = path
            self.physicalRowCount = physicalRowCount
            self.byteCount = byteCount
            self.compactionThreshold = compactionThreshold
            self.integrity = integrity
        }

        /// A feed that has grown past this multiple of its own compaction
        /// threshold is not merely "due for compaction" — a healthy store
        /// compacts at 1× and lands back under it, so 4× means compaction has
        /// not run in a long time. Warn early enough that growth is caught
        /// before it is felt, without crying wolf on a feed that is simply
        /// between cycles.
        public static let growthWarnMultiple = 4

        public var status: Status {
            if !integrity.isClean { return .blocked }
            if physicalRowCount >= compactionThreshold * Self.growthWarnMultiple { return .warn }
            if integrity.trailingPartialLine { return .warn }
            return .ok
        }

        /// One human-readable line per feed, for the Doctor detail body.
        public var detailLine: String {
            let kib = (byteCount + 1023) / 1024
            switch status {
            case .ok:
                return "\(feed): ok — \(physicalRowCount) row(s), \(kib) KiB"
            case .warn:
                return "\(feed): \(physicalRowCount) row(s), \(kib) KiB — "
                    + "over \(Self.growthWarnMultiple)× the \(compactionThreshold)-row compaction threshold"
                    + (integrity.trailingPartialLine ? " (last line torn — an append may be in flight)" : "")
            case .blocked:
                return "\(feed): COMPACTION BLOCKED — \(integrity.unusableRowCount) unusable row(s) "
                    + "(\(integrity.summary)); feed is \(physicalRowCount) row(s), \(kib) KiB and cannot shrink"
            }
        }

        /// Bytes + physical rows of a feed file, for a store assembling its own
        /// health value. A missing file is a genesis feed, not an error.
        public static func fileSize(_ path: URL) -> Int {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else { return 0 }
            return (attrs[.size] as? NSNumber)?.intValue ?? 0
        }
    }

    /// Process-wide dedupe for the integrity log so a stale binary appending in
    /// a loop reports once per distinct signature instead of flooding stderr.
    /// Counts CHANGING re-arms it — new damage is new news.
    private static let integrityLogLock = NSLock()
    nonisolated(unsafe) private static var loggedIntegritySignatures: Set<String> = []
    /// The dedupe memo is keyed on counts, so a feed accruing damage one line at
    /// a time mints a new signature each time. Cap it and start over rather than
    /// letting a long-lived process grow the set without bound — re-logging a
    /// signature is the harmless direction.
    private static let integrityLogMemoCap = 256

    /// Insert `signature`, returning true when it is new. Caller must not hold
    /// the lock.
    private static func claimLogSlot(_ signature: String) -> Bool {
        integrityLogLock.lock()
        defer { integrityLogLock.unlock() }
        if loggedIntegritySignatures.count >= integrityLogMemoCap {
            loggedIntegritySignatures.removeAll(keepingCapacity: true)
        }
        return loggedIntegritySignatures.insert(signature).inserted
    }

    /// Report an unclean read on stderr, once per distinct (feed, path, counts).
    /// Silent when the read was clean.
    public static func noteIntegrity(_ integrity: OpLogIntegrity, feed: String, path: URL) {
        guard !integrity.isClean || integrity.trailingPartialLine else { return }
        guard claimLogSlot("\(feed)|\(path.path)|\(integrity.summary)") else { return }
        let severity = integrity.isClean ? "note" : "WARNING"
        FileHandle.standardError.write(Data(
            "\(feed): \(severity) op-log rows skipped at \(path.path) — \(integrity.summary)\n".utf8
        ))
    }

    /// The compaction gate. Returns `true` when it is safe to rewrite the feed;
    /// returns `false` AND logs when any row was unusable. Every op-log store
    /// calls this immediately after its threshold check, so the one policy lives
    /// in one place instead of wearing three filenames.
    public static func mayCompact(_ integrity: OpLogIntegrity, feed: String, path: URL) -> Bool {
        guard !integrity.isClean else { return true }
        if claimLogSlot("refuse|\(feed)|\(path.path)|\(integrity.summary)") {
            FileHandle.standardError.write(Data(
                """
                \(feed): REFUSING to compact \(path.path) — \(integrity.unusableRowCount) row(s) \
                this build cannot decode (\(integrity.summary)). Compacting would delete them \
                permanently. The feed will keep growing until a build that understands them runs.

                """.utf8
            ))
        }
        return false
    }

    /// TEST HOOK ONLY: clear the log-dedupe memo so a test can assert the
    /// refusal path fires. Never called by product code.
    static func resetIntegrityLogMemoForTesting() {
        integrityLogLock.lock()
        loggedIntegritySignatures.removeAll()
        integrityLogLock.unlock()
    }

    /// Return the ops that FOLLOW `lastCompactedOpId` (the compaction tail).
    /// Scans from the END so the LAST occurrence of the id wins — matching every
    /// store's `lastIndex(where:)`. If the id is not present (a genesis feed, or
    /// an already-truncated feed whose head is past the compacted op), `ops` is
    /// returned unchanged. This also HEALS a crash between base-write and
    /// truncate: a stale full op-log simply replays as its post-base suffix.
    public static func dropCompactedPrefix<Op>(
        _ ops: [Op],
        lastCompactedOpId: String,
        id: (Op) -> String
    ) -> [Op] {
        guard let idx = ops.lastIndex(where: { id($0) == lastCompactedOpId }) else { return ops }
        return Array(ops[(idx + 1)...])
    }

    /// Atomic snapshot-BEFORE-truncate. Writes the compaction base first (via
    /// `writeJSON`'s temp+rename, so readers never see a partial base), THEN
    /// rewrites the op-log to exactly `tailRows`. Desk passes an EMPTY tail;
    /// GitHubCommand and TaskLedger pass the kept newest-K. The caller must hold
    /// the ops flock.
    public static func commitCompaction(
        baseJSON: JSONValue,
        tailRows: [JSONValue],
        basePath: URL,
        opsPath: URL,
        persistence: any PersistenceCoreProtocol
    ) async throws {
        try await persistence.writeJSON(baseJSON, to: basePath)
        try await persistence.replaceJSONL(tailRows, to: opsPath)
    }
}

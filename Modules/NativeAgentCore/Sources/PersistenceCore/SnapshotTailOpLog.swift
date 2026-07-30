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

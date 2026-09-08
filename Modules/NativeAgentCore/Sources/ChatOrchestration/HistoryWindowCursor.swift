import Foundation
import NativeAgentCore
import PersistenceCore

// Per-session replayed-prefix window cursor (v2Prefix conversation shape).
//
// v2 replays prior turns as REAL messages so a provider cache can match them
// byte-for-byte across turns. That only pays if the prefix is STABLE: every
// time the oldest replayed row changes, the whole cached prefix is invalidated
// and the turn pays the write premium again. A per-turn recomputation of "the
// newest N rows that fit" changes the head constantly — the exact churn v2
// exists to stop.
//
// So the head is pinned by a persisted cursor and moves RARELY, MONOTONICALLY,
// and only at a turn boundary:
//
//   - ADVANCE ONLY on real pressure: the admitted rows must exceed
//     `budget.historyChars * advanceTriggerRatio` (1.15). Under that, the head
//     does not move at all, even as the tail grows.
//   - When it does advance, drop OLDEST-FIRST in complete user/assistant PAIRS
//     until the remainder is at or under `budget.historyChars *
//     advanceTargetRatio` (0.70). Overshooting on purpose is what buys the
//     next several turns of stability — trimming to exactly the ceiling would
//     re-trigger on the very next turn.
//   - NEVER mid-turn. A tool loop's iteration N+1 must read iteration N's
//     prefix; moving the head between them is a guaranteed cache kill.
//   - ANCHORS ARE EXEMPT. The first `anchorLimit` user/assistant rows of the
//     session are the opening that makes everything after it legible.
//   - NEVER in the same turn a compaction ran. `ChatSessionAutocompactor`
//     stays the rare rewrite owner; two rewrites of the same prefix in one
//     turn is one rewrite too many, and the compaction already reclaimed the
//     bytes this cursor would be reclaiming.
//
// The boundary is stored as a row IDENTITY (`ChatMessage.historyIdentity`),
// not an index: indices shift under the tail limit every turn, identities do
// not. A boundary that no longer appears in the admitted set drops nothing —
// fail-open is a bigger prompt, never a lost row.
//
// File shape, actor discipline, per-file lock, and the hourly orphan sweep all
// mirror `ChatSessionActiveTools` / `ActiveToolsStore` deliberately: same
// failure modes, same recovery, one pattern to reason about.

public struct HistoryWindowCursor: Codable, Sendable, Equatable {
    public var sessionId: String
    /// `historyIdentity` of the NEWEST row that is outside the window. Every
    /// admitted row at or before it is dropped (anchors and the compaction
    /// summary excepted). nil → nothing dropped; the full admitted set rides.
    public var dropBoundaryIdentity: String?
    /// How many times this session's window has ever advanced. Read by the
    /// turn trace (`windowCursorAdvanceCount`); not authority for anything.
    public var advanceCount: Int
    /// Turn id of the most recent advance, so a within-turn second call
    /// (a tool loop's later iteration) is a no-op by construction rather than
    /// by the caller remembering not to ask.
    public var lastAdvanceTurnId: String?
    public var updatedAt: String

    public init(
        sessionId: String,
        dropBoundaryIdentity: String? = nil,
        advanceCount: Int = 0,
        lastAdvanceTurnId: String? = nil,
        updatedAt: String = ""
    ) {
        self.sessionId = sessionId
        self.dropBoundaryIdentity = dropBoundaryIdentity
        self.advanceCount = advanceCount
        self.lastAdvanceTurnId = lastAdvanceTurnId
        self.updatedAt = updatedAt
    }
}

public actor HistoryWindowCursorStore {
    /// Pressure threshold. Below `historyChars * 1.15` the head does not move.
    static let advanceTriggerRatio = 1.15
    /// Post-advance target. Trimming well under the ceiling is what makes the
    /// next several turns cache-stable.
    static let advanceTargetRatio = 0.70
    /// Orphan-sweep horizon and cadence — identical contract to
    /// `ActiveToolsStore`: this reaps `<id>.json` / `<id>.json.lock` left by
    /// sessions that ended or crashed, and is NOT a decay rule for live state.
    private static let ttlSeconds: TimeInterval = 24 * 60 * 60
    private static let sweepIntervalSeconds: TimeInterval = 60 * 60

    private static func makeISO8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    nonisolated private static func iso8601Now() -> String {
        makeISO8601().string(from: Date())
    }

    private let persistence = SwiftNativePersistenceCore()
    private let dataRootOverride: URL?
    private var lastSweepAt: Date?

    public init(dataRoot: URL? = nil) {
        self.dataRootOverride = dataRoot
    }

    private func dataRoot() -> URL {
        if let dataRootOverride { return dataRootOverride }
        return PersistenceCore.defaultDataRoot()
    }

    private func pathFor(sessionId: String) -> URL {
        let safe = NativeAgentChatSessionID.normalizedPathComponent(sessionId) ?? "invalid"
        return dataRoot()
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("prefix_window", isDirectory: true)
            .appendingPathComponent("\(safe).json")
    }

    // MARK: - Reads

    public func load(sessionId: String) async -> HistoryWindowCursor {
        await sweepOrphansIfDue()
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentChatSessionID.isSafePathComponent(trimmed) else {
            return HistoryWindowCursor(sessionId: sessionId)
        }
        let path = pathFor(sessionId: trimmed)
        do {
            return try await persistence.withFileLock(path) {
                await self.loadLocked(path: path, sessionId: trimmed)
            }
        } catch {
            return HistoryWindowCursor(sessionId: trimmed)
        }
    }

    // MARK: - The one advance boundary

    /// Decide and persist this turn's window head. Call ONCE per turn, at turn
    /// start, before the prefix is projected — never per tool-loop iteration.
    ///
    /// `admitted` is the projection's `admittedIdentities` (oldest→newest),
    /// `rowLengths` the matching per-row rendered lengths, `roles` the matching
    /// per-row roles (so pairs can be cut whole). Returns the cursor to project
    /// with; `didAdvance` says whether the head actually moved.
    @discardableResult
    public func advanceIfNeeded(
        sessionId: String,
        admitted: [HistoryWindowRow],
        budgetChars: Int,
        rowCap: Int,
        turnId: String?,
        compactionRanThisTurn: Bool
    ) async -> (cursor: HistoryWindowCursor, didAdvance: Bool) {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentChatSessionID.isSafePathComponent(trimmed) else {
            return (HistoryWindowCursor(sessionId: sessionId), false)
        }
        let path = pathFor(sessionId: trimmed)
        do {
            return try await persistence.withFileLock(path) {
                let state = await self.loadLocked(path: path, sessionId: trimmed)
                // PERSIST ON EVERY PATH. The file used to be written ONLY on a
                // successful advance, so a session that never crossed the
                // pressure threshold left no file at all — live CD041E66 had
                // only the `.lock` sidecar (created by `withFileLock`
                // regardless) and no `.json`. That made the one piece of state
                // that pins the prefix head invisible: "no advance yet" and
                // "the write path is broken" looked identical from outside.
                // Writing the CURRENT boundary every turn costs one small
                // locked write, keeps the file's mtime fresh for the orphan
                // sweep, and makes the cursor observable.
                func persistingCurrentState() async -> (HistoryWindowCursor, Bool) {
                    var refreshed = state
                    refreshed.updatedAt = Self.iso8601Now()
                    try? await self.saveLocked(refreshed, path: path)
                    return (state, false)
                }
                // NEVER twice within one turn: a tool loop's later iterations
                // must read the same prefix iteration 1 wrote.
                if let turnId, !turnId.isEmpty, state.lastAdvanceTurnId == turnId {
                    return (state, false)
                }
                // Compaction already owns this turn's rewrite.
                guard !compactionRanThisTurn else { return await persistingCurrentState() }
                guard let boundary = Self.nextBoundary(
                    admitted: admitted,
                    currentBoundary: state.dropBoundaryIdentity,
                    budgetChars: budgetChars,
                    rowCap: rowCap
                ) else {
                    return await persistingCurrentState()
                }
                // THE WRITE IS THE DECISION. A swallowed save failure used to
                // return `didAdvance: true` against an in-memory cursor that
                // was never persisted — so this turn dropped the oldest rows,
                // the next turn reloaded the OLD boundary, and those rows
                // re-entered the prefix. That is the exact churn this cursor
                // exists to prevent, and it would have looked like a healthy
                // advance in every receipt. On failure keep the OLD cursor for
                // this request and report no advance.
                var advanced = state
                advanced.dropBoundaryIdentity = boundary
                advanced.advanceCount += 1
                advanced.lastAdvanceTurnId = turnId
                advanced.updatedAt = Self.iso8601Now()
                do {
                    try await self.saveLocked(advanced, path: path)
                } catch {
                    Self.recordAdvanceWriteFailure(sessionId: trimmed, error: error)
                    return (state, false)
                }
                return (advanced, true)
            }
        } catch {
            return (HistoryWindowCursor(sessionId: trimmed), false)
        }
    }

    /// Pure decision half, so the rule is testable without touching disk.
    ///
    /// Returns the NEW boundary identity, or nil when the window must not move
    /// (no pressure, nothing droppable, or the candidate is not strictly newer
    /// than the current boundary — the cursor is monotonic, oldest-first only).
    /// `rowCap` is the SECOND bound, and the one the live defect needed.
    ///
    /// Character pressure alone never fired: the transcript reader hands the
    /// projection a tail-limited slice, so the admitted set was pre-trimmed to
    /// well under `budgetChars` and `used > budgetChars * 1.15` was
    /// unreachable. The cursor therefore never advanced, never persisted, and
    /// the prefix head was whatever the reader's sliding tail happened to start
    /// at — moving a few rows EVERY turn (live CD041E66: historyMessageCount
    /// 62 → 60 → 64 → 67 on a transcript that only grew). Every turn re-created
    /// the whole message history.
    ///
    /// Bounding ROWS with the same hysteresis puts the head back under the
    /// cursor: it moves once, in a chunk, and then holds for many turns.
    nonisolated static func nextBoundary(
        admitted: [HistoryWindowRow],
        currentBoundary: String?,
        budgetChars: Int,
        rowCap: Int = 0
    ) -> String? {
        guard budgetChars > 0 || rowCap > 0, !admitted.isEmpty else { return nil }
        let currentIndex = currentBoundary.flatMap { boundary in
            admitted.firstIndex { $0.identity == boundary }
        }
        // Rows still inside the window: everything after the current boundary.
        let liveStart = currentIndex.map { $0 + 1 } ?? 0
        guard liveStart < admitted.count else { return nil }
        let live = Array(admitted[liveStart...])
        // Anchors and the recollection sit BEFORE the boundary and are replayed
        // anyway, so they are part of what the model actually reads and must be
        // counted. Leaving them out would under-report the prefix and let it run
        // over the ceiling by exactly the bytes that can never be reclaimed.
        // Only the compaction recollection survives ahead of the boundary now.
        // Anchors are no longer pinned at the head: pinning them put a moving
        // joint between them and the first live row (see the projection's
        // cursor-drop note), and the session's opening already rides the
        // volatile block's continuity state.
        let pinnedAhead = admitted[..<liveStart]
            .filter { $0.isCompactionSummary }
        let replayed = pinnedAhead + live
        let used = replayed.reduce(0) { $0 + $1.length + 1 }
        let rowCount = replayed.count
        // EITHER bound can trigger; the trim below satisfies BOTH.
        let charPressure = budgetChars > 0
            && Double(used) > Double(budgetChars) * advanceTriggerRatio
        let rowPressure = rowCap > 0
            && Double(rowCount) > Double(rowCap) * advanceTriggerRatio
        guard charPressure || rowPressure else { return nil }

        let target = budgetChars > 0
            ? Double(budgetChars) * advanceTargetRatio
            : Double.greatestFiniteMagnitude
        let rowTarget = rowCap > 0
            ? Double(rowCap) * advanceTargetRatio
            : Double.greatestFiniteMagnitude
        // `remaining` starts at the FULL replayed size (pinned rows included);
        // the loop below only ever subtracts rows it is allowed to drop, so a
        // session whose pinned floor alone exceeds the target simply cuts
        // everything droppable and stops — it never spins.
        var remaining = used
        var remainingRows = rowCount
        var cut = 0
        // Drop COMPLETE user/assistant pairs, oldest first. A half-dropped pair
        // leaves an answer with no question — worse context than either whole.
        while cut < live.count,
              Double(remaining) > target || Double(remainingRows) > rowTarget {
            let pairEnd = Self.pairEnd(in: live, from: cut)
            guard pairEnd > cut else { break }
            var candidateRemaining = remaining
            var candidateRows = remainingRows
            var candidateCut = cut
            var droppedAny = false
            while candidateCut < pairEnd {
                let row = live[candidateCut]
                candidateCut += 1
                // The compaction recollection never leaves.
                if row.isCompactionSummary { continue }
                candidateRemaining -= (row.length + 1)
                candidateRows -= 1
                droppedAny = true
            }
            cut = candidateCut
            remaining = candidateRemaining
            remainingRows = candidateRows
            if !droppedAny && cut >= live.count { break }
        }
        guard cut > 0 else { return nil }
        // The boundary is the newest row now OUTSIDE the window.
        let boundaryIndex = min(cut, live.count) - 1
        guard boundaryIndex >= 0 else { return nil }
        let candidate = live[boundaryIndex].identity
        // Monotonic: never move the head backwards.
        if let currentBoundary,
           let currentAt = admitted.firstIndex(where: { $0.identity == currentBoundary }),
           let candidateAt = admitted.firstIndex(where: { $0.identity == candidate }),
           candidateAt <= currentAt {
            return nil
        }
        return candidate
    }

    /// End index (exclusive) of the user/assistant pair beginning at `start`:
    /// the run of rows up to and including the first assistant-side row that
    /// follows at least one user-side row.
    private nonisolated static func pairEnd(in rows: [HistoryWindowRow], from start: Int) -> Int {
        var index = start
        var sawUser = false
        while index < rows.count {
            let row = rows[index]
            index += 1
            if row.role == "user" { sawUser = true; continue }
            if sawUser, row.role == "assistant" || row.role == "tool" { return index }
        }
        return rows.count
    }

    /// A cursor advance that could not be persisted is a real event, not a
    /// silent no-op: the prefix stayed put when pressure said it should move,
    /// so the next turn pays uncached input. Receipt it on stderr — payload
    /// free, session id only — the same way the trace recorder reports its own
    /// write failures.
    nonisolated private static func recordAdvanceWriteFailure(
        sessionId: String,
        error: Error
    ) {
        FileHandle.standardError.write(Data(
            "HistoryWindowCursorStore: advance not persisted for session \(sessionId) — \(error). Window head unchanged this turn.\n".utf8
        ))
    }

    // MARK: - Orphan sweep (identical contract to ActiveToolsStore)

    private func sweepOrphansIfDue() async {
        let now = Date()
        if let last = lastSweepAt, now.timeIntervalSince(last) < Self.sweepIntervalSeconds {
            return
        }
        lastSweepAt = now
        let dir = dataRoot()
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("prefix_window", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries where url.pathExtension == "json" {
            try? await persistence.withFileLock(url) {
                guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = vals.contentModificationDate,
                      now.timeIntervalSince(mtime) > Self.ttlSeconds else { return }
                try? FileManager.default.removeItem(at: url)
            }
        }
        // Lock sidecars, same three conditions as ActiveToolsStore: the
        // sibling .json is gone, the lock is older than the TTL, and the
        // unlink happens while holding that lock.
        await reapOrphanedChatSessionLockSidecars(
            entries: entries, now: now, ttlSeconds: Self.ttlSeconds, persistence: persistence
        )
    }

    // MARK: - Helpers (must be called while holding the file lock)

    private func loadLocked(path: URL, sessionId: String) async -> HistoryWindowCursor {
        let json = await persistence.readJSON(path, defaultValue: .null)
        guard case .object(let obj) = json else {
            return HistoryWindowCursor(sessionId: sessionId)
        }
        func string(_ key: String) -> String? {
            if case .string(let s) = obj[key] ?? .null, !s.isEmpty { return s }
            return nil
        }
        var advanceCount = 0
        if case .int(let n) = obj["advanceCount"] ?? .null { advanceCount = Int(n) }
        return HistoryWindowCursor(
            sessionId: sessionId,
            dropBoundaryIdentity: string("dropBoundaryIdentity"),
            advanceCount: advanceCount,
            lastAdvanceTurnId: string("lastAdvanceTurnId"),
            updatedAt: string("updatedAt") ?? ""
        )
    }

    private func saveLocked(_ state: HistoryWindowCursor, path: URL) async throws {
        var body: [String: JSONValue] = [
            "schema": .string("chat.prefix_window.v1"),
            "sessionId": .string(state.sessionId),
            "advanceCount": .int(Int64(state.advanceCount)),
            "updatedAt": .string(state.updatedAt),
        ]
        if let boundary = state.dropBoundaryIdentity {
            body["dropBoundaryIdentity"] = .string(boundary)
        }
        if let turnId = state.lastAdvanceTurnId {
            body["lastAdvanceTurnId"] = .string(turnId)
        }
        try await persistence.writeJSON(.object(body), to: path)
    }
}

/// What the window cursor did for ONE turn, carried on the turn's context so
/// every consumer reports the same numbers.
///
/// The alternative — each seeding site re-reading the cursor from disk, or
/// hard-coding zeros — was both a second locked read per turn and a receipt
/// that could disagree with the decision it claims to describe.
public struct HistoryWindowReceipt: Sendable, Equatable {
    /// Lifetime advances for this session (the persisted counter).
    public let advanceCount: Int
    /// Whether the head moved on THIS turn.
    public let slid: Bool

    public init(advanceCount: Int, slid: Bool) {
        self.advanceCount = advanceCount
        self.slid = slid
    }
}

/// One admitted history row, reduced to what the window rule needs. Keeping
/// this payload-free (identity + length + role + two flags, never content) is
/// what lets the cursor be persisted and traced without carrying transcript.
public struct HistoryWindowRow: Sendable, Equatable {
    public let identity: String
    public let role: String
    public let length: Int
    public let isAnchor: Bool
    public let isCompactionSummary: Bool

    public init(
        identity: String,
        role: String,
        length: Int,
        isAnchor: Bool,
        isCompactionSummary: Bool
    ) {
        self.identity = identity
        self.role = role
        self.length = length
        self.isAnchor = isAnchor
        self.isCompactionSummary = isCompactionSummary
    }
}

/// Per-data-root store registry.
///
/// The store carries the hourly orphan-sweep throttle as instance state, so a
/// fresh instance per turn would re-run the directory sweep on every turn.
/// One store per root, reused, keeps the sweep at its intended cadence while
/// leaving tests free to point at a tmp root.
public actor HistoryWindowCursorStoreRegistry {
    public static let shared = HistoryWindowCursorStoreRegistry()
    private var stores: [String: HistoryWindowCursorStore] = [:]

    public func store(dataRoot: URL?) -> HistoryWindowCursorStore {
        let key = dataRoot?.standardizedFileURL.path ?? ""
        if let existing = stores[key] { return existing }
        let created = HistoryWindowCursorStore(dataRoot: dataRoot)
        stores[key] = created
        return created
    }
}

/// Turn-scoped facts the window rule needs but cannot observe for itself.
///
/// `compactionRanThisTurn` is bound by the chat lanes from the autocompactor's
/// own outcome. `ChatSessionAutocompactor` stays the rare rewrite owner: when
/// it fired, the prefix was already rewritten and reclaimed this turn, and a
/// second rewrite from the window cursor in the same turn would pay the cache
/// write premium twice for one turn's worth of savings.
public enum HistoryWindowTurnFacts {
    @TaskLocal public static var compactionRanThisTurn: Bool = false
}

import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `HistoryWindowCursor.swift` | `HistoryWindowCursor`, `HistoryWindowCursorStore`; locked reads validate nonnegative representable counters; checked advances preserve stored bytes on failure; row/character hysteresis persists only changed boundaries |

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
//     either rendered-byte or row budget * advanceTriggerRatio (1.15). Under
//     both, the head does not move at all, even as the tail grows.
//   - When it does advance, drop OLDEST-FIRST in complete user/assistant PAIRS
//     until the remainder is at or under BOTH budgets * advanceTargetRatio
//     (0.70). Overshooting on purpose is what buys the
//     next several turns of stability — trimming to exactly the ceiling would
//     re-trigger on the very next turn.
//   - NEVER mid-turn. A tool loop's iteration N+1 must read iteration N's
//     prefix; moving the head between them is a guaranteed cache kill.
//   - Only compaction recollections survive ahead of the boundary.
//   - After compaction, only advance if the remaining history still exceeds
//     either budget. Compaction owns the rewrite; the cursor bounds its result.
//
// The boundary is stored as a row IDENTITY (`ChatMessage.historyIdentity`),
// not an index: indices shift under the tail limit every turn, identities do
// not. A boundary that no longer appears in the admitted set drops nothing —
// fail-open is a bigger prompt, never a lost row.

public struct HistoryWindowCursor: Codable, Sendable, Equatable {
    public var sessionId: String
    /// `historyIdentity` of the NEWEST row that is outside the window. Every
    /// admitted row at or before it is dropped (compaction summaries excepted).
    /// nil → nothing dropped; the full admitted set rides.
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

/// Storage: prefix cursors are local replay state, excluded from local backup,
/// data export and phone sync; included in off-disk backup and PrivacyMap/chat.
public actor HistoryWindowCursorStore {
    /// Pressure threshold. Below both budgets * 1.15 the head does not move.
    static let advanceTriggerRatio = 1.15
    /// Post-advance target. Trimming well under the ceiling is what makes the
    /// next several turns cache-stable.
    static let advanceTargetRatio = 0.70

    private let dataRootOverride: URL?

    public init(dataRoot: URL? = nil) {
        self.dataRootOverride = dataRoot
    }

    private var dataRoot: URL { dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    private func pathFor(sessionId: String) -> URL {
        let safe = NativeAgentChatSessionID.normalizedPathComponent(sessionId) ?? "invalid"
        return dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("prefix_window", isDirectory: true)
            .appendingPathComponent("\(safe).json")
    }

    // MARK: - The one advance boundary

    /// Read before selecting transcript rows. The reader retains this boundary
    /// even beyond its ordinary tail, so only this owner can move the head.
    public func current(sessionId: String) async throws -> HistoryWindowCursor {
        guard let safe = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return HistoryWindowCursor(sessionId: sessionId)
        }
        let path = pathFor(sessionId: safe)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            try await self.loadLocked(path: path, sessionId: safe)
        }
    }

    /// Decide and persist this turn's window head. Call ONCE per turn, at turn
    /// start, before the prefix is projected — never per tool-loop iteration.
    ///
    /// `admitted` is the projection's `admittedIdentities` (oldest→newest),
    /// `rowLengths` the matching per-row rendered byte lengths (including sent
    /// context), `roles` the matching
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
    ) async throws -> (cursor: HistoryWindowCursor, didAdvance: Bool) {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentChatSessionID.isSafePathComponent(trimmed) else {
            return (HistoryWindowCursor(sessionId: sessionId), false)
        }
        let path = pathFor(sessionId: trimmed)
        do {
            return try await SwiftNativePersistenceCore.withFileLock(path) {
                let state = try await self.loadLocked(path: path, sessionId: trimmed)
                // NEVER twice within one turn: a tool loop's later iterations
                // must read the same prefix iteration 1 wrote.
                if let turnId, !turnId.isEmpty, state.lastAdvanceTurnId == turnId {
                    return (state, false)
                }
                // Compaction already owns this turn's rewrite, while what it
                // leaves fits; past that, whole older turns still go first.
                let replay = Self.replayed(admitted, currentBoundary: state.dropBoundaryIdentity)
                let over = (budgetChars > 0 && replay.chars > budgetChars)
                    || (rowCap > 0 && replay.rows > rowCap)
                guard !compactionRanThisTurn || over else { return (state, false) }
                guard let boundary = Self.nextBoundary(
                    admitted: admitted,
                    currentBoundary: state.dropBoundaryIdentity,
                    budgetChars: budgetChars,
                    rowCap: rowCap,
                    pressed: compactionRanThisTurn
                ) else {
                    return (state, false)
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
                let (count, overflow) = state.advanceCount.addingReportingOverflow(1)
                guard !overflow else {
                    throw PersistenceCoreError.ioFailure("History window advance counter is exhausted for \(trimmed); cursor left unchanged.")
                }
                advanced.advanceCount = count
                advanced.lastAdvanceTurnId = turnId
                advanced.updatedAt = NativeTimestampFormat.fractionalZulu(Date())
                do {
                    try await self.saveLocked(advanced, path: path)
                } catch {
                    Self.recordAdvanceWriteFailure(sessionId: trimmed, error: error)
                    return (state, false)
                }
                return (advanced, true)
            }
        } catch {
            throw error
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
    /// `pressed`: the history is already known to be over its budget, so the
    /// trim runs without waiting for the trigger ratio.
    nonisolated static func nextBoundary(
        admitted: [HistoryWindowRow],
        currentBoundary: String?,
        budgetChars: Int,
        rowCap: Int = 0,
        pressed: Bool = false
    ) -> String? {
        guard budgetChars > 0 || rowCap > 0, !admitted.isEmpty else { return nil }
        let (used, rowCount, liveStart) = replayed(admitted, currentBoundary: currentBoundary)
        guard liveStart < admitted.count else { return nil }
        let live = Array(admitted[liveStart...])
        // EITHER bound can trigger; the trim below satisfies BOTH.
        let charPressure = budgetChars > 0
            && Double(used) > Double(budgetChars) * (pressed ? 1 : advanceTriggerRatio)
        let rowPressure = rowCap > 0
            && Double(rowCount) > Double(rowCap) * (pressed ? 1 : advanceTriggerRatio)
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
        // Drop COMPLETE turns, oldest first. A half-dropped turn
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

    /// What the window replays past `currentBoundary`: its UTF-8 bytes, its rows,
    /// and where the live rows start. Compaction recollections survive ahead
    /// of the boundary and count toward the bytes the model reads.
    nonisolated static func replayed(_ admitted: [HistoryWindowRow], currentBoundary: String?)
        -> (chars: Int, rows: Int, liveStart: Int) {
        let currentIndex = currentBoundary.flatMap { boundary in admitted.firstIndex { $0.identity == boundary } }
        // Rows still inside the window: everything after the current boundary.
        let liveStart = currentIndex.map { $0 + 1 } ?? 0
        let rows = admitted[..<min(liveStart, admitted.count)].filter(\.isCompactionSummary)
            + admitted[min(liveStart, admitted.count)...]
        return (rows.reduce(0) { $0 + $1.length + 1 }, rows.count, liveStart)
    }

    /// End index (exclusive) of the turn beginning at `start`, including every
    /// tool receipt and assistant response before the next user row.
    private nonisolated static func pairEnd(in rows: [HistoryWindowRow], from start: Int) -> Int {
        var index = start
        var sawUser = false
        while index < rows.count {
            let row = rows[index]
            if row.role == "user" {
                if sawUser { return index }
                sawUser = true
            }
            index += 1
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

    // MARK: - Helpers (must be called while holding the file lock)

    private func loadLocked(path: URL, sessionId: String) async throws -> HistoryWindowCursor {
        let json = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .null)
        guard case .object(let obj) = json else {
            return HistoryWindowCursor(sessionId: sessionId)
        }
        func string(_ key: String) -> String? {
            if case .string(let s) = obj[key] ?? .null, !s.isEmpty { return s }
            return nil
        }
        guard case .int(let n)? = obj["advanceCount"], n >= 0,
              let advanceCount = Int(exactly: n) else {
            throw PersistenceCoreError.ioFailure("History window advance counter is invalid for \(sessionId); cursor left unchanged.")
        }
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
        try await SwiftNativePersistenceCore.writeJSON(.object(body), to: path)
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
/// this payload-free (identity + length + role + summary flag, never content) is
/// what lets the cursor be persisted and traced without carrying transcript.
public struct HistoryWindowRow: Sendable, Equatable {
    public let identity: String
    public let role: String
    /// Rendered UTF-8 bytes, including exact user-leading delivery metadata.
    public let length: Int
    public let isCompactionSummary: Bool

    public init(
        identity: String,
        role: String,
        length: Int,
        isCompactionSummary: Bool
    ) {
        self.identity = identity
        self.role = role
        self.length = length
        self.isCompactionSummary = isCompactionSummary
    }
}

/// Turn-scoped facts the window rule needs but cannot observe for itself.
///
/// `compactionRanThisTurn` is bound by the chat lanes from the autocompactor's
/// own outcome. `ChatSessionAutocompactor` stays the rare rewrite owner: when
/// it fired and its result fits both budgets, the cursor leaves the head alone.
/// A result still over either budget drops whole older turns through the same
/// cursor decision.
public enum HistoryWindowTurnFacts {
    @TaskLocal public static var compactionRanThisTurn: Bool = false
}

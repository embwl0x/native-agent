import Foundation
import Testing
@testable import PersistenceCore

// MARK: - TaskLedger compaction hygiene (audit 2026-07-21)
//
// Regression pins for the two audit findings on the snapshot+tail trim:
//   1. keep-tail hysteresis — compaction used to fire on EVERY append past
//      the first one (threshold == keepTail), rewriting the base + a full
//      5000-line feed under the cross-process flock each time.
//   2. terminal-task eviction — the compaction base (and the derived state
//      file) kept every taskId ever written; terminal tasks past a retention
//      bound are now retired at fold time.
//
// Swift Testing (not XCTest) so these run under the
// `swift test --disable-xctest` shard gate.

@Suite("TaskLedger: compaction hysteresis + terminal eviction")
struct TaskLedgerCompactionHygieneTests {
    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskledger-hygiene-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func feedLineCount(_ ledger: SwiftNativeTaskLedger) throws -> Int {
        try String(contentsOf: ledger.eventsPath, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).count
    }

    @Test func compactionAmortizesInsteadOfFiringOnEveryAppend() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root, compactionThreshold: 8, keepTail: 2)

        // Cross the threshold: first compaction fires, feed trims to keepTail.
        for i in 0..<8 {
            _ = try await ledger.append(TaskLedgerEvent(taskId: "t\(i)", actor: .claude, kind: .created))
        }
        #expect(FileManager.default.fileExists(atPath: ledger.basePath.path))
        #expect(try feedLineCount(ledger) == 2)
        let baseAfterFirst = try Data(contentsOf: ledger.basePath)

        // Steady-state appends BELOW the re-cross point must NOT recompact:
        // the base stays byte-identical and the feed simply grows.
        for i in 8..<11 {
            _ = try await ledger.append(TaskLedgerEvent(taskId: "t\(i)", actor: .claude, kind: .created))
        }
        #expect(try feedLineCount(ledger) == 5)
        #expect(try Data(contentsOf: ledger.basePath) == baseAfterFirst,
                "append below the re-cross threshold rewrote the base — hysteresis missing")

        // Re-crossing the threshold fires the next compaction.
        for i in 11..<14 {
            _ = try await ledger.append(TaskLedgerEvent(taskId: "t\(i)", actor: .claude, kind: .created))
        }
        #expect(try feedLineCount(ledger) == 2)
        #expect(try Data(contentsOf: ledger.basePath) != baseAfterFirst)
        let tasks = try await ledger.listTasks()
        #expect(tasks.count == 14)
    }

    @Test func productionKnobsCarryQuarterThresholdSlack() {
        // The audit's steady-state bug was threshold == keepTail (zero slack).
        #expect(SwiftNativeTaskLedger.compactionKeepTail
                == SwiftNativeTaskLedger.opsCompactionThreshold / 4)
        #expect(SwiftNativeTaskLedger.compactionKeepTail >= 1)
    }

    @Test func terminalTasksPastRetentionAreEvictedFromTheBase() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root, compactionThreshold: 6, keepTail: 2)
        let old = TaskLedgerClock.nowISO(Date().addingTimeInterval(-60 * 24 * 3600))

        _ = try await ledger.append(TaskLedgerEvent(taskId: "old-done", ts: old, actor: .user, kind: .created, title: "old"))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "old-done", ts: old, actor: .codex, kind: .done))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "old-claimed", ts: old, actor: .user, kind: .created, title: "live"))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "old-claimed", ts: old, actor: .codex, kind: .claimed))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "recent", actor: .user, kind: .created, title: "now"))
        // 6th append crosses the threshold and folds the four old events.
        _ = try await ledger.append(TaskLedgerEvent(taskId: "filler", actor: .claude, kind: .created))

        let baseRaw = try String(contentsOf: ledger.basePath, encoding: .utf8)
        #expect(!baseRaw.contains("old-done"),
                "terminal task past retention must be evicted from the compaction base")
        #expect(baseRaw.contains("old-claimed"),
                "non-terminal task must be retained regardless of age")

        let tasks = try await ledger.listTasks()
        #expect(!tasks.contains { $0.taskId == "old-done" })
        #expect(tasks.contains { $0.taskId == "old-claimed" && $0.owner == .codex })
        #expect(tasks.contains { $0.taskId == "recent" })
    }

    @Test func retentionPredicateKeepsFreshAndUnreadableRows() {
        let now = Date()
        func task(_ status: TaskLedgerKind, ts: String) -> TaskLedgerTaskState {
            TaskLedgerTaskState(
                taskId: "t", title: nil, owner: nil, status: status,
                createdTs: ts, updatedTs: ts, lastNote: nil, refs: []
            )
        }
        let fresh = TaskLedgerClock.nowISO(now)
        let old = TaskLedgerClock.nowISO(now.addingTimeInterval(-60 * 24 * 3600))
        // Terminal + fresh → kept; terminal + old → evicted.
        #expect(SwiftNativeTaskLedger.retainInCompactionBase(task(.done, ts: fresh), now: now))
        #expect(!SwiftNativeTaskLedger.retainInCompactionBase(task(.done, ts: old), now: now))
        #expect(!SwiftNativeTaskLedger.retainInCompactionBase(task(.cancelled, ts: old), now: now))
        // Non-terminal is never evicted, and an unparseable stamp fails toward
        // KEEPING the row (eviction must never lose unreadable history).
        #expect(SwiftNativeTaskLedger.retainInCompactionBase(task(.claimed, ts: old), now: now))
        #expect(SwiftNativeTaskLedger.retainInCompactionBase(task(.done, ts: "not-a-date"), now: now))
    }
}

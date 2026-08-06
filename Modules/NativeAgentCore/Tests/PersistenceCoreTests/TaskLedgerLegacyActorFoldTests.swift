import Foundation
import Testing
@testable import PersistenceCore

// MARK: - Legacy actor spellings must not wedge compaction (op_log_health, 2026-08-06)
//
// One June-2026 row with actor "agent" (the pre-identity-neutral spelling of
// `.assistant`) made `fromJSON` return nil, which counted as an undecodable
// row, which made `OpLogIntegrity.isClean` false FOREVER — snapshot+tail
// compaction refuses to rewrite an unclean feed, so the ledger could never
// shrink and Doctor reported op_log_health BLOCKED. The fix is the decode-side
// `TaskLedgerActor(wire:)` fold. These tests are the teeth: mutate the fold
// away and both fail.

@Suite("TaskLedger: legacy actor spellings fold on decode")
struct TaskLedgerLegacyActorFoldTests {
    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskledger-legacyactor-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("wire init folds the legacy spelling and still rejects unknowns")
    func wireInitFoldsLegacySpelling() {
        #expect(TaskLedgerActor(wire: "agent") == .assistant)
        #expect(TaskLedgerActor(wire: "assistant") == .assistant)
        #expect(TaskLedgerActor(wire: "claude") == .claude)
        // Genuinely unknown tokens must STILL fail decode: that is the
        // future-format safety the compaction block exists for.
        #expect(TaskLedgerActor(wire: "some_future_actor") == nil)
    }

    @Test("a legacy-actor row decodes, reads clean, and compaction proceeds")
    func legacyActorRowDoesNotBlockCompaction() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(
            dataRoot: root, compactionThreshold: 3, keepTail: 1)

        // Seed the feed with a raw legacy row exactly as the live ledger holds
        // it — written bytes, not the Swift writer (which only emits canonical
        // spellings).
        try FileManager.default.createDirectory(
            at: ledger.eventsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let legacyRow = """
        {"actor": "agent", "id": "legacy-1", "kind": "update", "note": "pre-rename row", "taskId": "t-legacy", "ts": "2026-06-11T17:59:04.870000+00:00"}

        """
        try Data(legacyRow.utf8).write(to: ledger.eventsPath)

        // The row decodes (folded to .assistant) and the feed reads clean.
        let events = try await ledger.readEventsUnlocked()
        #expect(events.count == 1)
        #expect(events.first?.actor == .assistant)
        let integrity = try await ledger.feedIntegrity()
        #expect(integrity.isClean,
                "legacy actor spelling counted as undecodable — compaction is wedged again")

        // Cross the threshold; compaction must actually rewrite the feed
        // (before the fix this silently refused, leaving all rows in place).
        _ = try await ledger.append(TaskLedgerEvent(taskId: "t2", actor: .claude, kind: .created, title: "two"))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "t3", actor: .claude, kind: .created, title: "three"))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "t4", actor: .claude, kind: .created, title: "four"))
        let health = try await ledger.feedHealth()
        #expect(health.status != .blocked)
        #expect(health.physicalRowCount < 4,
                "feed never shrank — compaction did not run over the legacy row")

        // The folded task survives compaction into the base with its history.
        let tasks = try await ledger.listTasks()
        #expect(tasks.contains { $0.taskId == "t-legacy" })
    }
}

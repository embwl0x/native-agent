// U3 review blockers (gpt-5.5, 2026-06-10) — approval-gated memory hygiene
// + memory.repair crash-window reconciliation.
//
//   1. The weekly memory_consolidation tick must NOT consolidate (store
//      mutation, plan law: approval-gated). It stages exactly ONE
//      self_improvement.apply card with op run_memory_hygiene, idempotent
//      while one is pending. The direct-consolidate path is reachable only
//      behind the explicit approvedDirectRun parameter.
//   2. resolveApproval persists the approval terminal BEFORE the executor
//      runs; a crash in that window left an approved repair that never
//      applied and never re-staged. The on-launch reconciliation
//      (NativeClient.reconcileUnappliedMemoryRepairs) must find
//      resolved-without-annotation records and run the idempotent executor.
//
// All roots are tmp dirs — no production data is touched.
import Foundation
import Testing
import ApprovalInbox
import KnowledgeGraph
import MemoryV2
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

// MARK: - helpers

private func makeMemTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MemoryHygieneAndRepairTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Seed `<root>/memory/legacy_notes/notes.jsonl` with duplicate test residue.
private func seedLegacyNotes(root: URL, uniques: Int, dupsOfFirst: Int) throws {
    let dir = root
        .appendingPathComponent("memory", isDirectory: true)
        .appendingPathComponent("legacy_notes", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var lines: [String] = []
    for i in 0..<uniques {
        lines.append(#"{"text": "unique note \#(i)", "_test_fixture": true}"#)
    }
    for _ in 0..<dupsOfFirst {
        lines.append(#"{"text": "unique note 0", "_test_fixture": true}"#)
    }
    let body = lines.joined(separator: "\n") + "\n"
    try Data(body.utf8).write(to: dir.appendingPathComponent("notes.jsonl"))
}

private func legacyNoteLines(root: URL) throws -> [String] {
    let path = root
        .appendingPathComponent("memory", isDirectory: true)
        .appendingPathComponent("legacy_notes", isDirectory: true)
        .appendingPathComponent("notes.jsonl")
    let raw = try String(contentsOf: path, encoding: .utf8)
    return raw.components(separatedBy: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}

private func pendingHygieneCards(root: URL) async throws -> [ApprovalRecord] {
    let inbox = SwiftNativeApprovalInbox(root: root)
    let pending = try await inbox.list(
        filter: ApprovalFilter(status: "pending", action: "self_improvement.apply"))
    return pending.filter { rec in
        guard case .object(let obj) = rec.payload,
              case .object(let apply)? = obj["apply"],
              case .string(let op)? = apply["op"] else { return false }
        return op == "run_memory_hygiene"
    }
}

// MARK: - 1. weekly hygiene tick stages, never consolidates

@Test
func weeklyHygieneTick_stagesExactlyOneCard_andNeverConsolidates() async throws {
    let root = try makeMemTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = MemoryConsolidationHygieneRunner(dataRoot: root)

    // Many ticks while the card is pending → exactly ONE staged card.
    await runner.tick()
    await runner.tick()
    await runner.tick()
    let cards = try await pendingHygieneCards(root: root)
    #expect(cards.count == 1)
    let card = try #require(cards.first)
    #expect(card.action == "self_improvement.apply")
    #expect(card.title == "Weekly memory hygiene is due")
    // The inbox actor recomputes payloadPreview from the payload itself —
    // assert the executable op rides in the payload, where the
    // applyApprovedSelfImprovement executor reads it.
    #expect(card.payloadPreview.contains("run_memory_hygiene"))

    // The tick must not have consolidated: no hygiene_last_run.json, no
    // memory store minted as a side effect of the tick.
    let lastRun = MemoryConsolidationHygiene.lastRunPath(dataRoot: root)
    #expect(!FileManager.default.fileExists(atPath: lastRun.path))
}

@Test
func weeklyHygieneTick_restagesAfterCardLeavesPending() async throws {
    let root = try makeMemTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = MemoryConsolidationHygieneRunner(dataRoot: root)
    await runner.tick()
    let first = try #require(try await pendingHygieneCards(root: root).first)

    // Deny it (weekly skip) — the NEXT weekly tick may legitimately stage a
    // fresh card; the dedupe is strictly "while one is pending".
    let inbox = SwiftNativeApprovalInbox(root: root)
    _ = try await inbox.resolve(first.id, decision: .denied, decidedBy: "test")
    await runner.tick()
    let cards = try await pendingHygieneCards(root: root)
    #expect(cards.count == 1)
    #expect(cards.first?.id != first.id)
}

@Test
func directHygieneRun_requiresTheExplicitApprovalParameter() async throws {
    let root = try makeMemTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: MemoryConsolidationHygiene.DirectRunNotApprovedError.self) {
        try await MemoryConsolidationHygiene.runOnce(dataRoot: root, approvedDirectRun: false)
    }
    // The approval-gated callers (MemoryView button / approved op) assert
    // the parameter and the pass runs + persists its report.
    let report = try await MemoryConsolidationHygiene.runOnce(
        dataRoot: root, approvedDirectRun: true)
    #expect(report.status == "ok")
    #expect(FileManager.default.fileExists(
        atPath: MemoryConsolidationHygiene.lastRunPath(dataRoot: root).path))
}

// MARK: - 1b. KG orphan sweep rides the hygiene cadence (2026-07-21 audit)

@Test
func weeklyHygieneTick_cardCarriesKGOrphanPreviewCounts() async throws {
    let root = try makeMemTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Mint the store FIRST: the read-only preview must never create
    // memory/memory.sqlite as a tick side effect (the no-mint case is
    // covered by weeklyHygieneTick_stagesExactlyOneCard_andNeverConsolidates).
    let storage = try MemoryStorage(dataRoot: root)
    _ = try await storage.insertMemory(StoredMemory(content: "NativeAgent ships tonight."))

    let runner = MemoryConsolidationHygieneRunner(dataRoot: root)
    await runner.tick()
    let card = try #require(try await pendingHygieneCards(root: root).first)
    guard case .object(let payload) = card.payload,
          case .string(let proposed)? = payload["proposedChange"] else {
        Issue.record("staged hygiene card missing proposedChange")
        return
    }
    #expect(proposed.contains("KG sweep preview on approval: 0 orphan entities"),
            "dry-run orphan counts must ride the staged card: \(proposed)")
}

@Test
func approvedHygieneRun_sweepsKGOrphanEntities() async throws {
    let root = try makeMemTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try MemoryStorage(dataRoot: root)
    _ = try await storage.insertMemory(
        StoredMemory(id: "mem-a", content: "NativeAgent ships tonight."))
    _ = try await storage.insertMemory(
        StoredMemory(id: "mem-b", content: "TradingView dashboards inside NativeAgent."))
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
    let factA = KnowledgeGraphMemoryFact(
        id: "mem-a", content: "NativeAgent ships tonight.",
        createdAt: "2026-07-21T00:00:00Z", updatedAt: "2026-07-21T00:00:00Z")
    let factB = KnowledgeGraphMemoryFact(
        id: "mem-b", content: "TradingView dashboards inside NativeAgent.",
        createdAt: "2026-07-21T00:00:00Z", updatedAt: "2026-07-21T00:00:00Z")
    try await indexer.indexMemory(factA)
    try await indexer.indexMemory(factB)
    // B dies — TradingView's only source is gone; NativeAgent survives via A.
    _ = try await storage.deleteMemory(id: "mem-b")
    try await indexer.indexMemory(factB, deleted: true)
    // Pre-flight: the orphan is really there for the sweep to find.
    let pre = try await indexer.collectGarbage(liveFacts: [factA], apply: false)
    #expect(pre.candidates.map { $0.name } == ["TradingView"])

    let report = try await MemoryConsolidationHygiene.runOnce(
        dataRoot: root, approvedDirectRun: true)
    #expect(report.status == "ok")

    // The approval-gated hygiene run swept the orphan (and nothing live).
    let post = try await indexer.collectGarbage(liveFacts: [factA], apply: false)
    #expect(post.candidates.isEmpty,
            "orphan survived the approved hygiene run: \(post.candidates)")
}

// MARK: - 2. memory.repair staging idempotence + crash-window reconciliation

@Test
func legacyNoteRepairStaging_isIdempotentAcrossLaunches() async throws {
    let root = try makeMemTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedLegacyNotes(root: root, uniques: 3, dupsOfFirst: 4)

    let first = await MemoryRepairOneShot.stageLegacyNoteDupPurge(dataRoot: root)
    let second = await MemoryRepairOneShot.stageLegacyNoteDupPurge(dataRoot: root)
    #expect(first != nil)
    #expect(first == second)

    let inbox = SwiftNativeApprovalInbox(root: root)
    let pending = try await inbox.list(
        filter: ApprovalFilter(status: "pending", action: MemoryRepairOneShot.action))
    #expect(pending.count == 1)
    // Staging never touches the store.
    #expect(try legacyNoteLines(root: root).count == 7)
}

@Test
func resolveCrashWindow_reconciliationAppliesTheApprovedRepair() async throws {
    let root = try makeMemTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedLegacyNotes(root: root, uniques: 3, dupsOfFirst: 4)
    let approvalId = try #require(await MemoryRepairOneShot.stageLegacyNoteDupPurge(dataRoot: root))

    // Simulate the crash window: the resolve PERSISTS (terminal record) but
    // the process dies before the executor runs — no execution annotation,
    // store untouched, staging stamp still present.
    let inbox = SwiftNativeApprovalInbox(root: root)
    _ = try await inbox.resolve(approvalId, decision: .approved, decidedBy: "test")
    #expect(try legacyNoteLines(root: root).count == 7) // nothing applied yet
    let stalled = try await inbox.get(approvalId)
    #expect(stalled.status == "resolved")
    #expect(stalled.executedAction == nil)

    // Without reconciliation, the next launch dead-ends: the stamp makes
    // stageIfNeeded a no-op and the record is terminal forever.
    #expect(MemoryRepairOneShot.readStamp(
        kind: MemoryRepairOneShot.legacyNoteDupsKind, dataRoot: root) == approvalId)

    // Relaunch path: reconcile → the idempotent executor applies the purge
    // and annotates the record.
    await NativeClient.reconcileUnappliedMemoryRepairs(dataRoot: root)
    #expect(try legacyNoteLines(root: root).count == 3) // dups purged
    let healed = try await inbox.get(approvalId)
    #expect(healed.executedAction != nil)
    #expect(healed.detail?.contains("purge applied") == true)

    // Second reconciliation pass: annotation present → record skipped, the
    // store stays exactly as the first apply left it.
    await NativeClient.reconcileUnappliedMemoryRepairs(dataRoot: root)
    #expect(try legacyNoteLines(root: root).count == 3)
}

@Test
func reconciliation_skipsRecordsThatAlreadyExecuted() async throws {
    let root = try makeMemTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedLegacyNotes(root: root, uniques: 2, dupsOfFirst: 2)
    let approvalId = try #require(await MemoryRepairOneShot.stageLegacyNoteDupPurge(dataRoot: root))

    // Full healthy resolve (executor + annotation) via the real path.
    let inbox = SwiftNativeApprovalInbox(root: root)
    let rec = try await inbox.resolve(approvalId, decision: .approved, decidedBy: "test")
    await NativeClient.applyResolvedMemoryRepair(from: rec, dataRoot: root)
    #expect(try legacyNoteLines(root: root).count == 2)
    let backupsBefore = try backupCount(root: root)

    // Reconciliation finds nothing to do — no second backup, no rewrite.
    await NativeClient.reconcileUnappliedMemoryRepairs(dataRoot: root)
    #expect(try backupCount(root: root) == backupsBefore)
    #expect(try legacyNoteLines(root: root).count == 2)
}

private func backupCount(root: URL) throws -> Int {
    let dir = root
        .appendingPathComponent("memory", isDirectory: true)
        .appendingPathComponent("legacy_notes", isDirectory: true)
    return try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.contains(".bak") }.count
}

// MARK: - truncated-rows executor: applies once, stale-skips on re-run

@Test
func truncatedRowsExecutor_appliesThenStaleSkipsOnRerun() async throws {
    let root = try makeMemTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try MemoryStorage(dataRoot: root)
    let chopped = String(repeating: "x", count: 195) + " and t"
    let row = try await storage.insertMemory(StoredMemory(
        id: "row-1",
        content: chopped,
        createdAt: "2026-05-16T10:00:00+00:00"
    ))
    let completed = chopped + "he completed sentence finishes cleanly."
    let repairs = [MemoryRepairOneShot.TruncatedRowRepair(
        id: row.id, currentText: chopped, proposedText: completed)]

    let outcome = try await MemoryRepairOneShot.applyTruncatedRowsRepair(
        dataRoot: root, repairs: repairs, embedder: MockEmbeddingProvider())
    #expect(outcome.applied == [row.id])
    #expect(outcome.failed.isEmpty)
    #expect(!outcome.backupPath.isEmpty)
    let updated = try await storage.memory(id: row.id)
    #expect(updated?.content == completed)

    // Idempotence (the property the crash-window reconciliation relies on):
    // re-running the same approved payload stale-skips — no double write.
    let rerun = try await MemoryRepairOneShot.applyTruncatedRowsRepair(
        dataRoot: root, repairs: repairs, embedder: MockEmbeddingProvider())
    #expect(rerun.applied.isEmpty)
    #expect(rerun.skippedStale == [row.id])
    #expect(try await storage.memory(id: row.id)?.content == completed)
}

@Test
func truncatedRowsStaging_detectsDaemonEraSignatureAndStagesOnce() async throws {
    let root = try makeMemTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try MemoryStorage(dataRoot: root)
    let chopped = String(repeating: "y", count: 200) // daemon-era cap signature
    _ = try await storage.insertMemory(StoredMemory(
        id: "row-cap",
        content: chopped,
        createdAt: "2026-05-17T08:00:00+00:00"
    ))
    let suggestions = ["row-cap": chopped + " completed."]

    let first = await MemoryRepairOneShot.stageTruncatedRowsRepair(
        dataRoot: root, suggestions: suggestions)
    let second = await MemoryRepairOneShot.stageTruncatedRowsRepair(
        dataRoot: root, suggestions: suggestions)
    #expect(first != nil)
    #expect(first == second)
    let inbox = SwiftNativeApprovalInbox(root: root)
    let pending = try await inbox.list(
        filter: ApprovalFilter(status: "pending", action: MemoryRepairOneShot.action))
    #expect(pending.count == 1)
    // Store untouched until approval.
    #expect(try await storage.memory(id: "row-cap")?.content == chopped)
}

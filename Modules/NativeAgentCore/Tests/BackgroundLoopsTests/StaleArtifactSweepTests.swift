import Testing
import Foundation
import PersistenceCore
@testable import BackgroundLoops

// A5.5: the stale-artifact sweep. The tests that matter here are the ones that
// prove the sweep does NOT delete: a referenced receipt, an in-grace receipt, a
// live store, and — above all — anything at all when the reference join cannot
// be proven.

// MARK: - Fixtures

private func sweepTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("stale-sweep-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(_ url: URL, contents: String = "x", daysAgo: Double? = nil) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(contents.utf8).write(to: url)
    if let daysAgo {
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        try? FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path)
    }
}

/// Seed a chat store whose message rows reference `runIDs`.
private func seedChatStore(_ root: URL, referencing runIDs: [String], startup: [String] = []) {
    let lines = runIDs.map { "{\"id\":\"m-\($0)\",\"runId\":\"\($0)\"}" }.joined(separator: "\n")
    writeFile(root.appendingPathComponent("chat/messages/session-a.jsonl"), contents: lines + "\n")
    let sessions = startup.map { "{\"id\":\"s\",\"startupContextRunId\":\"\($0)\"}" }
        .joined(separator: ",")
    writeFile(root.appendingPathComponent("chat/sessions.json"), contents: "[\(sessions)]")
}

private let liveRunID = "AAAAAAAA-1111-2222-3333-444444444444"
private let orphanRunID = "bbbbbbbb-1111-2222-3333-444444444444"
private let youngOrphanRunID = "cccccccc-1111-2222-3333-444444444444"

// MARK: - Orphan join

@Test func orphanReceiptPastGraceIsPlannedForDeletion() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 40)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.receiptsBlockedReason == nil)
    #expect(plan.orphanReceipts.map(\.relativePath) == ["context/\(orphanRunID).json"])
    #expect(plan.orphanReceipts.first?.archivedTo == nil)  // deleted outright
}

@Test func referencedReceiptIsNeverPlannedEvenWhenAncient() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    // 500 days old and still referenced — age never overrides a live reference.
    writeFile(root.appendingPathComponent("context/\(liveRunID).json"), daysAgo: 500)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.receiptsBlockedReason == nil)
    #expect(plan.orphanReceipts.isEmpty)
    #expect(plan.referencedRunIDCount == 1)
}

@Test func referenceMatchIsCaseInsensitive() {
    // The live chat store writes UPPERCASE UUID runIds; the daemon-era receipt
    // filenames are lowercase, and APFS opens them case-insensitively. A
    // case-SENSITIVE join would call a reachable file an orphan.
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    writeFile(
        root.appendingPathComponent("context/\(liveRunID.lowercased()).json"), daysAgo: 400)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.isEmpty)
}

@Test func receiptReferencedOnlyByStartupContextRunIDIsSpared() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    // No message row mentions it — only the session index's startupContextRunId,
    // which is the reader's second lookup (Context.swift:412-421).
    seedChatStore(root, referencing: [liveRunID], startup: [orphanRunID])
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 400)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.isEmpty)
}

@Test func receiptReferencedOnlyByArchivedSessionIsSpared() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    writeFile(
        root.appendingPathComponent("chat/archive/messages/old.jsonl"),
        contents: "{\"runId\":\"\(orphanRunID)\"}\n")
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 400)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.isEmpty)
}

@Test func inGraceOrphanIsKept() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    // Unreferenced, but only 3 days old — inside the 14-day grace window.
    writeFile(root.appendingPathComponent("context/\(youngOrphanRunID).json"), daysAgo: 3)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.isEmpty)
}

@Test func graceBoundaryIsStrictlyOlderThanCutoff() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 13.9)
    writeFile(root.appendingPathComponent("context/\(youngOrphanRunID).json"), daysAgo: 14.1)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.map(\.relativePath) == ["context/\(youngOrphanRunID).json"])
}

@Test func nonReceiptFilesInContextDirAreNeverCandidates() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    // The live store, its sidecars, and a non-UUID file all share the directory.
    writeFile(root.appendingPathComponent("context/context.sqlite"), daysAgo: 400)
    writeFile(root.appendingPathComponent("context/context.sqlite-wal"), daysAgo: 400)
    writeFile(root.appendingPathComponent("context/context.sqlite-shm"), daysAgo: 400)
    writeFile(root.appendingPathComponent("context/notes.json"), daysAgo: 400)
    writeFile(root.appendingPathComponent("context/hints/learned.json"), daysAgo: 400)
    writeFile(root.appendingPathComponent("context/feedback/events.jsonl"), daysAgo: 400)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.isEmpty)
}

// MARK: - Fail-closed

@Test func missingChatStoreBlocksTheReceiptLeg() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    // Receipts exist; the chat store does not. Deleting here would nuke the lot.
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 400)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.isEmpty)
    #expect(plan.receiptsBlockedReason?.contains("chat store missing") == true)
}

@Test func unparseableSessionsIndexBlocksTheReceiptLeg() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    writeFile(root.appendingPathComponent("chat/sessions.json"), contents: "}{ torn")
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 400)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.isEmpty)
    #expect(plan.receiptsBlockedReason?.contains("sessions.json") == true)
}

@Test func emptyReferenceSetWithCandidatesBlocksTheReceiptLeg() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    // A chat store that exists but yields zero runIds is indistinguishable from
    // a blind scan — and "every receipt is an orphan" is the worst possible
    // conclusion to reach by accident.
    writeFile(root.appendingPathComponent("chat/messages/empty.jsonl"), contents: "")
    writeFile(root.appendingPathComponent("chat/sessions.json"), contents: "[]")
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 400)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.isEmpty)
    #expect(plan.receiptsBlockedReason?.contains("0 runIds") == true)
}

@Test func emptyReferenceSetWithNoCandidatesIsNotBlocked() {
    // A genuinely fresh install: no chat history AND no receipts. Nothing to
    // decide, so nothing to refuse.
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    writeFile(root.appendingPathComponent("chat/sessions.json"), contents: "[]")

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.receiptsBlockedReason == nil)
    #expect(plan.isEmpty)
}

@Test func blockedReceiptLegStillLetsTheBackupLegRun() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 400)
    writeFile(root.appendingPathComponent("memory/SOUL.md.pre-2026-01-01.bak"), daysAgo: 90)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.receiptsBlockedReason != nil)     // no chat store
    #expect(plan.orphanReceipts.isEmpty)
    #expect(plan.staleBackups.count == 1)           // independent leg
}

// MARK: - .bak matcher

@Test func backupMatcherCoversEveryInRepoNamingConvention() {
    // The three shapes that actually exist under data/ at HEAD.
    #expect(StaleArtifactSweep.isBackupFileName("sessions.json.bak"))
    #expect(StaleArtifactSweep.isBackupFileName("policy.json.bak.pre-fileops-20260610T081803Z"))
    #expect(StaleArtifactSweep.isBackupFileName("SOUL.md.pre-20260508T225503Z.bak"))
    #expect(StaleArtifactSweep.isBackupFileName("items.jsonl.bak.pre-sweep-2026-07-20"))
    #expect(StaleArtifactSweep.isBackupFileName("runs.json.corrupt-20260101.bak"))
}

@Test func backupMatcherRejectsLiveStoresAndSidecars() {
    // No live store has ".bak" in its name — that is what makes the guarantee
    // structural rather than a maintained exclusion list.
    #expect(!StaleArtifactSweep.isBackupFileName("context.sqlite"))
    #expect(!StaleArtifactSweep.isBackupFileName("context.sqlite-wal"))
    #expect(!StaleArtifactSweep.isBackupFileName("context.sqlite-shm"))
    #expect(!StaleArtifactSweep.isBackupFileName("sessions.json"))
    #expect(!StaleArtifactSweep.isBackupFileName("inbox.jsonl"))
    // And a hypothetical name that pairs both conventions still loses.
    #expect(!StaleArtifactSweep.isBackupFileName("store.bak-wal"))
    #expect(!StaleArtifactSweep.isBackupFileName("store.bak.lock"))
    // memory.sqlite.pre-* snapshots carry no ".bak" — deliberately untouched.
    #expect(!StaleArtifactSweep.isBackupFileName("memory.sqlite.pre-curation-20260618"))
}

@Test func backupAgeBoundary() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    writeFile(root.appendingPathComponent("trust/policy.json.bak.young"), daysAgo: 29.9)
    writeFile(root.appendingPathComponent("trust/policy.json.bak.old"), daysAgo: 30.1)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.staleBackups.map(\.relativePath) == ["trust/policy.json.bak.old"])
}

@Test func backupSweepExcludesWorkshopAndTheArchiveItself() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    writeFile(root.appendingPathComponent("workshop/desk-1/draft.md.bak"), daysAgo: 400)
    writeFile(root.appendingPathComponent("archive/stale_backups/old.json.bak"), daysAgo: 400)
    writeFile(root.appendingPathComponent("providers/surfaces.json.bak.2026-06-05"), daysAgo: 400)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.staleBackups.map(\.relativePath) == ["providers/surfaces.json.bak.2026-06-05"])
}

@Test func plannedBackupIsArchivedNotDeleted() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    writeFile(root.appendingPathComponent("memory/SOUL.md.pre-x.bak"), daysAgo: 400)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.staleBackups.first?.archivedTo == "archive/stale_backups/memory/SOUL.md.pre-x.bak")
}

// MARK: - Cap

@Test func perTickCapTruncatesAndSaysSo() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    for i in 0..<5 {
        writeFile(
            root.appendingPathComponent("context/dddddddd-1111-2222-3333-00000000000\(i).json"),
            daysAgo: Double(100 + i))
    }

    let plan = StaleArtifactSweep.plan(dataRoot: root, maxPerTick: 2)
    #expect(plan.capped)
    #expect(plan.orphanReceipts.count == 2)
    // Oldest first, so a capped tick drains deterministically from the far end.
    #expect(plan.orphanReceipts.first?.relativePath
        == "context/dddddddd-1111-2222-3333-000000000004.json")
}

// MARK: - Apply

@Test func applyDeletesReceiptAndArchivesBackup() throws {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    let receipt = root.appendingPathComponent("context/\(orphanRunID).json")
    let backup = root.appendingPathComponent("memory/SOUL.md.pre-x.bak")
    writeFile(receipt, contents: "receipt-body", daysAgo: 400)
    writeFile(backup, contents: "backup-body", daysAgo: 400)

    let plan = StaleArtifactSweep.plan(dataRoot: root)
    for artifact in plan.orphanReceipts + plan.staleBackups {
        _ = try StaleArtifactSweep.apply(artifact, dataRoot: root)
    }

    #expect(!FileManager.default.fileExists(atPath: receipt.path))
    #expect(!FileManager.default.fileExists(atPath: backup.path))
    let archived = root.appendingPathComponent("archive/stale_backups/memory/SOUL.md.pre-x.bak")
    #expect(try String(contentsOf: archived, encoding: .utf8) == "backup-body")
}

@Test func archiveCollisionGetsASuffixInsteadOfClobbering() throws {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let backup = root.appendingPathComponent("memory/SOUL.md.pre-x.bak")
    writeFile(backup, contents: "new", daysAgo: 400)
    writeFile(
        root.appendingPathComponent("archive/stale_backups/memory/SOUL.md.pre-x.bak"),
        contents: "previously-archived")

    let values = try backup.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let artifact = SweptArtifact(
        relativePath: "memory/SOUL.md.pre-x.bak",
        sizeBytes: Int64(values.fileSize ?? 0),
        modifiedAt: values.contentModificationDate ?? Date(),
        reason: "t", archivedTo: "archive/stale_backups/memory/SOUL.md.pre-x.bak")
    let applied = try StaleArtifactSweep.apply(artifact, dataRoot: root)

    #expect(applied.archivedTo == "archive/stale_backups/memory/SOUL.md.pre-x.bak.1")
    let original = root.appendingPathComponent("archive/stale_backups/memory/SOUL.md.pre-x.bak")
    #expect(try String(contentsOf: original, encoding: .utf8) == "previously-archived")
}

// MARK: - Loop

private final class ReceiptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [JSONValue] = []
    var lines: [JSONValue] { lock.lock(); defer { lock.unlock() }; return _lines }
    func record(_ v: JSONValue) { lock.lock(); _lines.append(v); lock.unlock() }

    func events() -> [String] {
        lines.compactMap { line in
            guard case .object(let o) = line, case .string(let e)? = o["event"] else { return nil }
            return e
        }
    }
}

private func makeLoop(
    root: URL, enabled: Bool, recorder: ReceiptRecorder, ok: Bool = true
) -> StaleArtifactSweepLoop {
    StaleArtifactSweepLoop(
        dataRoot: root,
        isEnabled: { enabled },
        appendReceipt: { line in recorder.record(line); return ok }
    )
}

@Test func disabledLoopIsReportOnlyAndRemovesNothing() async {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    let receipt = root.appendingPathComponent("context/\(orphanRunID).json")
    writeFile(receipt, daysAgo: 400)
    let recorder = ReceiptRecorder()

    let outcome = await makeLoop(root: root, enabled: false, recorder: recorder).tickOutcome()

    guard case .completed(let detail) = outcome else {
        Issue.record("expected .completed, got \(outcome)"); return
    }
    #expect(detail?.contains("REPORT-ONLY") == true)
    #expect(FileManager.default.fileExists(atPath: receipt.path))  // untouched
    // Exactly one summary line — no 700-line "would remove" dump.
    #expect(recorder.events() == ["sweep_pass"])
}

@Test func enabledLoopRemovesAndWritesOneReceiptPerRemoval() async {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    let orphan = root.appendingPathComponent("context/\(orphanRunID).json")
    let live = root.appendingPathComponent("context/\(liveRunID.lowercased()).json")
    writeFile(orphan, daysAgo: 400)
    writeFile(live, daysAgo: 400)
    let recorder = ReceiptRecorder()

    let outcome = await makeLoop(root: root, enabled: true, recorder: recorder).tickOutcome()

    guard case .completed(let detail) = outcome else {
        Issue.record("expected .completed, got \(outcome)"); return
    }
    #expect(detail?.contains("removed 1 file(s)") == true)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(FileManager.default.fileExists(atPath: live.path))  // referenced — spared
    #expect(recorder.events() == ["sweep_pass_start", "removed", "sweep_pass"])

    // The removal receipt carries path, bytes, mtime and reason.
    guard case .object(let row)? = recorder.lines.dropFirst().first else {
        Issue.record("no removal receipt"); return
    }
    #expect(row["path"] == .string("context/\(orphanRunID).json"))
    #expect(row["disposition"] == .string("deleted"))
    #expect(row["dryRun"] == .bool(false))
    if case .int(let bytes)? = row["bytes"] { #expect(bytes > 0) } else {
        Issue.record("bytes missing from receipt")
    }
    if case .string(let mtime)? = row["mtime"] { #expect(!mtime.isEmpty) } else {
        Issue.record("mtime missing from receipt")
    }
    if case .string(let reason)? = row["reason"] {
        #expect(reason.contains("orphan_context_receipt"))
    } else {
        Issue.record("reason missing from receipt")
    }
}

@Test func secondTickTheSameDayIsSkipped() async {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 400)
    let recorder = ReceiptRecorder()
    let loop = makeLoop(root: root, enabled: false, recorder: recorder)

    _ = await loop.tickOutcome()
    let second = await loop.tickOutcome()

    guard case .skipped(let reason) = second else {
        Issue.record("expected .skipped, got \(second)"); return
    }
    #expect(reason.contains("already ran today"))
}

@Test func deadReceiptLedgerRemovesNothingAndRollsTheDayBack() async {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 400)
    writeFile(
        root.appendingPathComponent("context/eeeeeeee-1111-2222-3333-444444444444.json"),
        daysAgo: 401)
    let recorder = ReceiptRecorder()
    let loop = makeLoop(root: root, enabled: true, recorder: recorder, ok: false)

    let outcome = await loop.tickOutcome()
    guard case .failed(let error) = outcome else {
        Issue.record("expected .failed, got \(outcome)"); return
    }
    #expect(error.contains("receipt ledger unwritable"))

    // The pre-flight probe caught it: NOTHING was removed, so no file is gone
    // without an audit line.
    let remaining = (try? FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("context").path))?.count ?? 0
    #expect(remaining == 2)

    // Day rolled back ⇒ the next tick retries rather than silently skipping.
    let retry = await loop.tickOutcome()
    if case .skipped = retry { Issue.record("day was not rolled back") }
}

// MARK: - Review-round pins (gpt-5.5, 2026-07-24)

@Test func malformedMidFileMessageRowBlocksTheReceiptLeg() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    // Row 1 references the live receipt, row 2 is corrupt, row 3 is fine —
    // the reference set MAY be partial, so the leg must refuse.
    writeFile(root.appendingPathComponent("chat/messages/session-a.jsonl"),
              contents: "{\"runId\":\"\(liveRunID)\"}\nNOT-JSON\n{\"runId\":\"x\"}\n")
    writeFile(root.appendingPathComponent("chat/sessions.json"), contents: "[]")
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 30)
    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.isEmpty)
    #expect(plan.receiptsBlockedReason?.contains("malformed row") == true)
}

@Test func malformedFinalLineIsToleratedAsTornAppend() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    writeFile(root.appendingPathComponent("chat/messages/session-a.jsonl"),
              contents: "{\"runId\":\"\(liveRunID)\"}\n{\"runId\":\"y\"}\n{\"trunc")
    writeFile(root.appendingPathComponent("chat/sessions.json"), contents: "[]")
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 30)
    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.receiptsBlockedReason == nil)
    #expect(plan.orphanReceipts.count == 1)
}

@Test func missingMessagesDirWithCandidatesBlocksTheReceiptLeg() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    // chat/ exists (sessions.json contributes a runId) but messages/ is absent
    // — a partial store must refuse, not read as empty.
    writeFile(root.appendingPathComponent("chat/sessions.json"),
              contents: "[{\"startupContextRunId\":\"\(liveRunID)\"}]")
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 30)
    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.isEmpty)
    #expect(plan.receiptsBlockedReason?.contains("missing") == true)
}

@Test func archiveRootWithoutMessagesDirBlocksTheReceiptLeg() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    // A chat/archive tree EXISTS but its messages/ subdir is gone — the
    // half-migrated shape. Refuse.
    try? FileManager.default.createDirectory(
        at: root.appendingPathComponent("chat/archive/other", isDirectory: true),
        withIntermediateDirectories: true)
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 30)
    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.orphanReceipts.isEmpty)
    #expect(plan.receiptsBlockedReason?.contains("missing") == true)
}

@Test func absentArchiveTreeDoesNotBlock() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])  // no chat/archive at all
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 30)
    let plan = StaleArtifactSweep.plan(dataRoot: root)
    #expect(plan.receiptsBlockedReason == nil)
    #expect(plan.orphanReceipts.count == 1)
}

@Test func bakedStyleNamesAreNotBackupMatches() {
    #expect(!StaleArtifactSweep.isBackupFileName("profile.baked.json"))
    #expect(!StaleArtifactSweep.isBackupFileName("bakery-orders.json"))
    #expect(StaleArtifactSweep.isBackupFileName("profile.json.bak"))
    #expect(StaleArtifactSweep.isBackupFileName("inbox.jsonl.bak.pre-dream-20260617"))
}

@Test func applySkipsAFileThatDriftedSincePlanning() throws {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    let path = root.appendingPathComponent("context/\(orphanRunID).json")
    writeFile(path, contents: "old", daysAgo: 30)
    let plan = StaleArtifactSweep.plan(dataRoot: root)
    let planned = try #require(plan.orphanReceipts.first)
    // The file is REPLACED after planning (new size + fresh mtime): the
    // planned verdict no longer describes what is on disk.
    writeFile(path, contents: "replaced-with-new-live-content")
    #expect(throws: StaleArtifactSweep.SweepApplyOutcome.driftedSincePlan) {
        _ = try StaleArtifactSweep.apply(planned, dataRoot: root)
    }
    #expect(FileManager.default.fileExists(atPath: path.path))
}

@Test func ledgerDeathAfterFirstRemovalCountsTheMutationAndDoesNotRollBack() async {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    seedChatStore(root, referencing: [liveRunID])
    writeFile(root.appendingPathComponent("context/\(orphanRunID).json"), daysAgo: 30)
    writeFile(root.appendingPathComponent("context/\(youngOrphanRunID.replacingOccurrences(of: "cccccccc", with: "dddddddd")).json"), daysAgo: 40)
    // Ledger accepts the pass-start probe + first removal receipt, then dies.
    let recorder = ReceiptRecorder()
    let allowed = 1
    let loop = StaleArtifactSweepLoop(
        dataRoot: root,
        isEnabled: { true },
        appendReceipt: { line in
            recorder.record(line)
            return recorder.lines.count <= allowed
        }
    )
    let outcome = await loop.tickOutcome()
    // One mutation landed before the ledger died; the outcome must say so —
    // never "removed 0", and never a rolled-back day over a missing file.
    guard case .failed(let error) = outcome else {
        Issue.record("expected failed outcome, got \(outcome)"); return
    }
    #expect(error.contains("removed 1"))
    #expect(error.contains("UNRECEIPTED") || error.contains("receipt append failed"))
    // The reservation marker still stands (no rollback into a retry that
    // would re-delete): the day is burned, the failure is on the record.
    let marker = root.appendingPathComponent("logs/stale_artifact_sweep_last_run")
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func partialBackupScanIsSurfacedOnThePlan() {
    let root = sweepTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<40 {
        writeFile(root.appendingPathComponent("pile/file-\(i).txt"))
    }
    let plan = StaleArtifactSweep.plan(
        dataRoot: root, maxScannedEntries: 10)
    #expect(plan.backupScanPartial)
}

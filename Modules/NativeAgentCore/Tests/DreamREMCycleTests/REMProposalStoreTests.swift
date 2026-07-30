import Testing
import Foundation
@testable import DreamREMCycle
import NativeAgentCore

// MARK: - Helpers

private func tempStoreRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rem-proposal-store-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeProposal(
    id: String,
    targetDoc: String = "GROWTH.md",
    text: String = "A reflex worth keeping.",
    dates: [String] = ["2026-06-01", "2026-06-03"],
    createdAt: String = "2026-06-08T00:00:00Z"
) -> REMProposal {
    REMProposal(
        id: id,
        targetDoc: targetDoc,
        proposalText: text,
        evidenceDates: dates,
        confidence: 0.8,
        createdAt: createdAt
    )
}

private func readRows(_ dataRoot: URL) throws -> [[String: Any]] {
    let url = dataRoot.appendingPathComponent("rem_proposals.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let body = try String(contentsOf: url, encoding: .utf8)
    return try body.split(separator: "\n").filter { !$0.isEmpty }.map { line in
        let any = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return (any as? [String: Any]) ?? [:]
    }
}

/// Thread-safe recorder for staged proposal ids (the stager closure is
/// @Sendable; an actor would force awkward hops inside the closure).
private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    var ids: [String] {
        lock.lock(); defer { lock.unlock() }
        return _ids
    }
    func record(_ id: String) -> String {
        lock.lock(); defer { lock.unlock() }
        _ids.append(id)
        return "approval-\(id)"
    }
}

// MARK: - Append

@Test
func REMProposalStore_appendPending_writes_pending_rows_and_dedupes_by_id() async throws {
    let root = tempStoreRoot()
    let store = REMProposalStore(dataRoot: root)
    let appended = try await store.appendPending([
        makeProposal(id: "p1"),
        makeProposal(id: "p2", targetDoc: "SOUL"),
    ])
    #expect(appended == 1)

    // Re-appending the same ids is a no-op.
    let again = try await store.appendPending([
        makeProposal(id: "p1"),
        makeProposal(id: "p2", targetDoc: "SOUL"),
    ])
    #expect(again == 0)

    let rows = try readRows(root)
    #expect(rows.count == 1)
    #expect(rows.allSatisfy { ($0["status"] as? String) == "pending" })
    // Bare target names are normalized to the doc FILENAME.
    #expect(rows.allSatisfy { ($0["targetDoc"] as? String) == "GROWTH.md" })
}

// MARK: - Legacy import (requirement d)

@Test
func REMProposalStore_legacy_import_maps_snake_case_once_and_is_idempotent() async throws {
    let root = tempStoreRoot()
    let store = REMProposalStore(dataRoot: root)

    // Canonical store already holds one row whose id collides with a legacy row.
    try await store.appendPending([makeProposal(id: "dupe-1")])

    let harness = root.appendingPathComponent("harness", isDirectory: true)
    try FileManager.default.createDirectory(at: harness, withIntermediateDirectories: true)
    let legacy = harness.appendingPathComponent("rem_proposals.jsonl")
    // Live-file ground truth (2026-06-10): the legacy file is an append-only
    // EVENT LOG — one id can repeat as pending → applying → applied, plus an
    // extra updatedAt key the decoder must tolerate. The LAST row per id is
    // the truth: a final "applied" was daemon-actioned and must NOT import;
    // a final "applying" never completed and imports as pending.
    let legacyBody = """
    {"change_type":"append","createdAt":"2026-05-31T04:30:00Z","evidence_dates":["2026-05-28","2026-05-30"],"id":"legacy-1","proposed_text":"legacy reflex one","rationale":"","status":"pending","target_doc":"GROWTH.md"}
    {"change_type":"append","createdAt":"2026-05-31T04:30:01Z","evidence_dates":["2026-05-29"],"id":"dupe-1","proposed_text":"already imported","rationale":"","status":"pending","target_doc":"SOUL.md"}
    {"change_type":"append","createdAt":"2026-05-27T23:15:42.196589+00:00","evidence_dates":["2026-05-26"],"id":"legacy-lifecycle","proposed_text":"went all the way","rationale":"","status":"pending","target_doc":"GROWTH.md"}
    {"change_type":"append","createdAt":"2026-05-27T23:15:42.196589+00:00","evidence_dates":["2026-05-26"],"id":"legacy-lifecycle","proposed_text":"went all the way","rationale":"","status":"applying","target_doc":"GROWTH.md","updatedAt":"2026-05-27T23:15:59+00:00"}
    {"change_type":"append","createdAt":"2026-05-27T23:15:42.196589+00:00","evidence_dates":["2026-05-26"],"id":"legacy-lifecycle","proposed_text":"went all the way","rationale":"","status":"applied","target_doc":"GROWTH.md","updatedAt":"2026-05-27T23:16:00+00:00"}
    {"change_type":"append","createdAt":"2026-05-27T23:15:43+00:00","evidence_dates":["2026-05-26"],"id":"legacy-applying","proposed_text":"apply never finished","rationale":"","status":"applying","target_doc":"VOICE.md","updatedAt":"2026-05-27T23:16:01+00:00"}
    """
    try Data((legacyBody + "\n").utf8).write(to: legacy)

    let imported = try await store.importLegacyHarnessFileIfNeeded()
    #expect(imported == 1, "only final-pending GROWTH imports; dupe/final-applied/non-GROWTH are skipped")

    let rows = try readRows(root)
    #expect(rows.count == 2)
    #expect(!rows.contains { ($0["id"] as? String) == "legacy-lifecycle" },
            "event-log id whose FINAL status is applied was resurrected as pending")
    #expect(!rows.contains { ($0["id"] as? String) == "legacy-applying" },
            "non-GROWTH legacy proposals must not be resurrected into the approval flow")
    let legacyRow = try #require(rows.first { ($0["id"] as? String) == "legacy-1" })
    // snake_case → camelCase canonical schema, status forced to pending.
    #expect(legacyRow["targetDoc"] as? String == "GROWTH.md")
    #expect(legacyRow["proposalText"] as? String == "legacy reflex one")
    #expect((legacyRow["evidenceDates"] as? [String]) == ["2026-05-28", "2026-05-30"])
    #expect(legacyRow["status"] as? String == "pending")
    #expect(legacyRow["target_doc"] == nil)
    #expect(legacyRow["proposed_text"] == nil)

    // Source renamed to .migrated; original gone.
    let migrated = harness.appendingPathComponent("rem_proposals.jsonl.migrated")
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(FileManager.default.fileExists(atPath: migrated.path))

    // Idempotent: second call is a silent no-op.
    let second = try await store.importLegacyHarnessFileIfNeeded()
    #expect(second == 0)
    #expect(try readRows(root).count == 2)
}

@Test
func REMProposalStore_legacy_import_skips_silently_when_file_absent() async throws {
    let root = tempStoreRoot()
    let store = REMProposalStore(dataRoot: root)
    let imported = try await store.importLegacyHarnessFileIfNeeded()
    #expect(imported == 0)
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("rem_proposals.jsonl").path))
}

// MARK: - Staging (requirement a, store-level)

@Test
func REMProposalStore_stagePendingApprovals_stamps_rows_and_never_double_stages() async throws {
    let root = tempStoreRoot()
    let store = REMProposalStore(dataRoot: root)
    try await store.appendPending([makeProposal(id: "s1"), makeProposal(id: "s2")])

    let recorder = StageRecorder()
    let staged = try await store.stagePendingApprovals { row in recorder.record(row.id) }
    #expect(staged == 2)
    #expect(Set(recorder.ids) == ["s1", "s2"])

    let rows = try readRows(root)
    #expect(rows.allSatisfy { ($0["approvalId"] as? String)?.isEmpty == false })

    // Re-run: stamped rows are skipped — the stager fires zero times.
    let rerun = try await store.stagePendingApprovals { row in recorder.record(row.id) }
    #expect(rerun == 0)
    #expect(recorder.ids.count == 2)
}

@Test
func REMProposalStore_staging_failure_leaves_row_unstamped_for_retry() async throws {
    let root = tempStoreRoot()
    let store = REMProposalStore(dataRoot: root)
    try await store.appendPending([makeProposal(id: "f1")])

    // Stager failure (nil) → no stamp, no count.
    let staged = try await store.stagePendingApprovals { _ in nil }
    #expect(staged == 0)
    let rows = try readRows(root)
    #expect(rows.first?["approvalId"] == nil)

    // Retry succeeds and stamps.
    let recorder = StageRecorder()
    let retried = try await store.stagePendingApprovals { row in recorder.record(row.id) }
    #expect(retried == 1)
}

@Test
func REMProposalStore_nonGrowthLegacyRows_do_not_stage_or_approve_but_can_deny() async throws {
    let root = tempStoreRoot()
    let store = REMProposalStore(dataRoot: root)
    let row = REMProposalRow(
        id: "legacy-soul",
        targetDoc: "SOUL.md",
        proposalText: "old soul proposal",
        evidenceDates: ["2026-06-01", "2026-06-03"],
        confidence: 0.7,
        createdAt: "2026-06-08T00:00:00Z",
        status: "pending"
    )
    let url = root.appendingPathComponent("rem_proposals.jsonl")
    var data = try JSONEncoder().encode(row)
    data.append(0x0A)
    try data.write(to: url)

    let recorder = StageRecorder()
    let staged = try await store.stagePendingApprovals { row in recorder.record(row.id) }
    #expect(staged == 0)
    #expect(recorder.ids.isEmpty)

    await #expect(throws: REMProposalStoreError.unsupportedTarget("SOUL.md")) {
        try await store.applyApproval(proposalId: "legacy-soul")
    }

    let denied = try await store.applyDenial(proposalId: "legacy-soul", reason: "legacy cleanup")
    #expect(denied.status == "denied")
    let tombstones = REMTombstoneStore(dataRoot: root)
    #expect(try await tombstones.isTombstoned(row.asREMProposal) == true)
}

// MARK: - Approve (requirement b)

@Test
func REMProposalStore_applyApproval_flips_status_and_pin_appears() async throws {
    let root = tempStoreRoot()
    let store = REMProposalStore(dataRoot: root)
    try await store.appendPending([
        makeProposal(id: "a1", targetDoc: "GROWTH.md", text: "steady cadence"),
    ])

    let row = try await store.applyApproval(proposalId: "a1")
    #expect(row.status == "approved")

    let rows = try readRows(root)
    #expect(rows.first?["status"] as? String == "approved")

    // rem_pins.json rebuilt with the approved row only.
    let pins = REMPinsReader.read(dataRoot: root)
    #expect(pins["GROWTH.md"]?.first?.id == "a1")
    #expect(pins["GROWTH.md"]?.first?.text == "steady cadence")

    // Idempotent re-fire returns the approved row unchanged.
    let again = try await store.applyApproval(proposalId: "a1")
    #expect(again.status == "approved")
}

// MARK: - Deny (requirement c)

@Test
func REMProposalStore_applyDenial_tombstones_flips_status_and_pin_absent() async throws {
    let root = tempStoreRoot()
    let store = REMProposalStore(dataRoot: root)
    let proposal = makeProposal(id: "d1", targetDoc: "GROWTH.md", text: "a denied reflex")
    try await store.appendPending([proposal])

    let row = try await store.applyDenial(proposalId: "d1", reason: "test deny")
    #expect(row.status == "denied")

    // Tombstoned — the same text can never be re-proposed.
    let tombstones = REMTombstoneStore(dataRoot: root)
    #expect(try await tombstones.isTombstoned(proposal) == true)

    // Pin absent: denied rows must never reach the chat injector.
    let pins = REMPinsReader.read(dataRoot: root)
    #expect(pins["GROWTH.md"] == nil || pins["GROWTH.md"]?.isEmpty == true)

    let rows = try readRows(root)
    #expect(rows.first?["status"] as? String == "denied")
}

@Test
func REMProposalStore_decision_on_unknown_or_conflicting_row_throws() async throws {
    let root = tempStoreRoot()
    let store = REMProposalStore(dataRoot: root)
    try await store.appendPending([makeProposal(id: "c1")])
    _ = try await store.applyApproval(proposalId: "c1")

    // Deny-after-approve refuses (distinct terminal states).
    await #expect(throws: REMProposalStoreError.conflict(id: "c1", status: "approved")) {
        try await store.applyDenial(proposalId: "c1", reason: "late deny")
    }
    // Unknown id refuses.
    await #expect(throws: REMProposalStoreError.notFound("ghost")) {
        try await store.applyApproval(proposalId: "ghost")
    }
}

// MARK: - Cancel stamp-clear

@Test
func REMProposalStore_clearApprovalStamp_makes_row_stageable_again() async throws {
    let root = tempStoreRoot()
    let store = REMProposalStore(dataRoot: root)
    try await store.appendPending([makeProposal(id: "x1")])
    _ = try await store.stagePendingApprovals { _ in "approval-x1" }

    try await store.clearApprovalStamp(proposalId: "x1")

    let recorder = StageRecorder()
    let restaged = try await store.stagePendingApprovals { row in recorder.record(row.id) }
    #expect(restaged == 1)
    #expect(recorder.ids == ["x1"])
}

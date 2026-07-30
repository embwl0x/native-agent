import Testing
import Foundation
@testable import DreamREMCycle
import NativeAgentCore
import PersistenceCore

// Tightness round 2 P-L3: REMProposalStore adopts SnapshotTailOpLog snapshot+tail
// compaction. HARD INVARIANT: terminal (approved/denied) rows must survive
// compaction into the base — the approval-resolve executor and the pins emitter
// read them. These pin terminal preservation, torn-read safety, and idempotent
// re-decisions on folded rows.

private func compactionTempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rem-compaction-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func prop(_ i: Int) -> REMProposal {
    REMProposal(
        id: "p\(i)",
        targetDoc: "GROWTH.md",
        proposalText: "reflex \(i)",
        evidenceDates: ["2026-06-01", "2026-06-03"],
        confidence: 0.8,
        createdAt: String(format: "2026-06-%02dT00:00:00Z", i + 1)
    )
}

private func feedLineCount(_ root: URL) -> Int {
    let url = root.appendingPathComponent("rem_proposals.jsonl")
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
    return s.split(separator: "\n").filter { !$0.isEmpty }.count
}

@Test func compactionFoldsTerminalRowsIntoBaseAndPreservesThem() async throws {
    let root = compactionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = REMProposalStore(dataRoot: root, compactionThreshold: 6, keepTail: 2)

    _ = try await store.appendPending((0..<8).map(prop))
    // Approve two and deny one — creating terminal rows that must survive.
    _ = try await store.applyApproval(proposalId: "p0")
    _ = try await store.applyApproval(proposalId: "p1")
    _ = try await store.applyDenial(proposalId: "p2", reason: "not worth keeping")

    // The base now exists and the feed is bounded below the total row count.
    #expect(FileManager.default.fileExists(atPath: store.basePath.path))
    #expect(feedLineCount(root) < 8)

    // The full folded view still returns every row with the right status.
    let all = store.loadAll()
    #expect(all.count == 8)
    #expect(all.first { $0.id == "p0" }?.status == "approved")
    #expect(all.first { $0.id == "p1" }?.status == "approved")
    #expect(all.first { $0.id == "p2" }?.status == "denied")
    #expect(all.first { $0.id == "p7" }?.status == "pending")

    // Terminal rows genuinely left the feed (into the base), proving a naive
    // newest-N line cap WOULD have dropped them.
    let baseRows = store.loadBaseRows()
    #expect(baseRows.contains { $0.id == "p0" && $0.status == "approved" })

    // The pins emitter (raw file reader before P-L3) must still see the approved
    // rows now living in the base.
    try REMConsolidator.emitREMPinsIndex(dataRoot: root)
    let pins = try String(
        contentsOf: root.appendingPathComponent("rem_pins.json"), encoding: .utf8)
    #expect(pins.contains("\"p0\""))
    #expect(pins.contains("\"p1\""))
    #expect(!pins.contains("\"p2\""))   // denied never leaks into pins
}

@Test func idempotentReDecisionOnFoldedRow() async throws {
    let root = compactionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = REMProposalStore(dataRoot: root, compactionThreshold: 6, keepTail: 2)
    _ = try await store.appendPending((0..<8).map(prop))
    _ = try await store.applyApproval(proposalId: "p0")
    _ = try await store.applyApproval(proposalId: "p1")
    _ = try await store.applyDenial(proposalId: "p2", reason: "no")

    // p0 is now in the base (terminal). Re-approving it is an idempotent no-op,
    // NOT a notFound throw.
    let reApproved = try await store.applyApproval(proposalId: "p0")
    #expect(reApproved.status == "approved")
    // Re-denying an approved base row is a genuine conflict.
    await #expect(throws: (any Error).self) {
        _ = try await store.applyDenial(proposalId: "p0", reason: "conflict")
    }
}

@Test func tornReadWindowLosesNoTerminalRow() async throws {
    // Simulate the crash window between base-write and feed-truncate: the base
    // holds the folded terminal rows AND the feed still holds them (un-truncated).
    // loadAll must dedup by id (feed wins) and lose nothing.
    let root = compactionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = REMProposalStore(dataRoot: root, compactionThreshold: 6, keepTail: 2)
    _ = try await store.appendPending((0..<8).map(prop))
    _ = try await store.applyApproval(proposalId: "p0")
    _ = try await store.applyApproval(proposalId: "p1")

    // Reconstruct the pre-truncate feed: every row (base + tail) present at once.
    let folded = store.loadAll()
    let feedURL = root.appendingPathComponent("rem_proposals.jsonl")
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let lines = try folded.map { String(data: try enc.encode($0), encoding: .utf8)! }
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: feedURL)

    // The base still exists; loadAll sees each id exactly once with its terminal
    // status intact — no loss, no duplication.
    let all = store.loadAll()
    #expect(all.count == 8)
    #expect(Set(all.map(\.id)).count == 8)
    #expect(all.first { $0.id == "p0" }?.status == "approved")
    #expect(all.first { $0.id == "p1" }?.status == "approved")
}

@Test func genesisFeedWithNoBaseStillLoads() async throws {
    let root = compactionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = REMProposalStore(dataRoot: root)   // production thresholds — no compaction
    _ = try await store.appendPending((0..<3).map(prop))
    #expect(!FileManager.default.fileExists(atPath: store.basePath.path))
    #expect(store.loadAll().count == 3)
}

// gpt-5.5 fix round (HIGH): a deterministic emitter can re-emit an id whose
// approved copy already folded to base. The re-append must be REFUSED (base-
// aware dedupe) and even a directly-injected pending feed row must not shadow
// the terminal base row in loadAll's folded view.
@Test func reEmittedIdCannotShadowFoldedTerminalRow() async throws {
    let root = compactionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = REMProposalStore(dataRoot: root, compactionThreshold: 6, keepTail: 2)

    _ = try await store.appendPending((0..<8).map(prop))
    _ = try await store.applyApproval(proposalId: "p0")
    _ = try await store.applyApproval(proposalId: "p1")
    _ = try await store.applyDenial(proposalId: "p2", reason: "no")
    #expect(FileManager.default.fileExists(atPath: store.basePath.path))

    // Re-emit p0 (approved, folded to base): base-aware dedupe refuses it.
    let appended = try await store.appendPending([prop(0)])
    #expect(appended == 0)
    #expect(store.loadAll().first { $0.id == "p0" }?.status == "approved")

    // Belt over suspenders: even a raw pending line for p0 written straight
    // into the feed (simulating a pre-fix writer or partial crash) must not
    // shadow the approved base row in the folded read.
    let rogue = "{\"id\":\"p0\",\"targetDoc\":\"GROWTH.md\",\"proposalText\":\"rogue\","
        + "\"evidenceDates\":[],\"confidence\":0.5,\"createdAt\":\"2026-06-30T00:00:00Z\","
        + "\"status\":\"pending\"}\n"
    let feed = root.appendingPathComponent("rem_proposals.jsonl")
    let handle = try FileHandle(forWritingTo: feed)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(rogue.utf8))
    try handle.close()
    #expect(store.loadAll().first { $0.id == "p0" }?.status == "approved")
}

// gpt-5.5 fix round (MED): a base that exists but does not decode must FAIL
// CLOSED — compaction skips rather than overwriting the base with a merge
// built from an "empty" read, which would permanently discard folded rows.
@Test func corruptBaseSkipsCompactionInsteadOfOverwriting() async throws {
    let root = compactionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = REMProposalStore(dataRoot: root, compactionThreshold: 4, keepTail: 1)

    _ = try await store.appendPending((0..<6).map(prop))
    _ = try await store.applyApproval(proposalId: "p0")
    #expect(FileManager.default.fileExists(atPath: store.basePath.path))
    let goodBase = try Data(contentsOf: store.basePath)

    // Corrupt the base, then force enough terminal churn to trigger compaction.
    try Data("not json{{".utf8).write(to: store.basePath)
    _ = try await store.applyApproval(proposalId: "p3")
    _ = try await store.applyApproval(proposalId: "p4")

    // The corrupt base bytes are untouched — compaction refused to rewrite it.
    #expect(try Data(contentsOf: store.basePath) == Data("not json{{".utf8))

    // Restore the original base: the previously folded row is intact.
    try goodBase.write(to: store.basePath)
    #expect(store.loadAll().first { $0.id == "p0" }?.status == "approved")
}

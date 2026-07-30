import Testing
import Foundation
@testable import SelfImprovement

// MARK: - Fixtures

private func tempDataRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("evostore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeStore(
    dataRoot: URL,
    now: @escaping @Sendable () -> Date = Date.init
) -> EvolutionProposalStore {
    EvolutionProposalStore(dataRoot: dataRoot, now: now)
}

private let sampleDiff = """
--- a/seed.txt
+++ b/seed.txt
@@ -1 +1,2 @@
 hello
+world
"""

// MARK: - Propose / attach

@Test func propose_with_diff_lands_proposed_with_sha() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    let p = try await store.propose(
        source: .chat, title: "t", evidence: "e", diffText: sampleDiff)
    #expect(p.status == .proposed)
    #expect(p.diffSHA256 == EvolutionSupport.sha256Hex(sampleDiff))
    #expect(p.risk == "critical")
    #expect(p.autoApprove == false)
    #expect(p.receipts.count == 1)
    #expect(p.id.hasPrefix("evo_"))
}

@Test func propose_without_diff_lands_needs_diff() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    let p = try await store.propose(source: .weekly, title: "t", evidence: "e")
    #expect(p.status == .needsDiff)
    #expect(p.diffSHA256 == nil)
}

@Test func attachDiff_moves_needs_diff_to_proposed() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    let p = try await store.propose(source: .selfHeal, title: "t", evidence: "e")
    let updated = try await store.attachDiff(id: p.id, diffText: sampleDiff, expectedHead: "abc1234def56")
    #expect(updated.status == .proposed)
    #expect(updated.diffSHA256 == EvolutionSupport.sha256Hex(sampleDiff))
    #expect(updated.expectedHead == "abc1234def56")
}

@Test func attachDiff_on_proposed_is_illegal() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    let p = try await store.propose(source: .chat, title: "t", evidence: "e", diffText: sampleDiff)
    do {
        _ = try await store.attachDiff(id: p.id, diffText: sampleDiff)
        Issue.record("expected illegalTransition")
    } catch let e as EvolutionEngineError {
        if case .illegalTransition = e {} else { Issue.record("wrong error: \(e)") }
    }
}

@Test func attachDiff_empty_diff_refused() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    let p = try await store.propose(source: .weekly, title: "t", evidence: "e")
    await #expect(throws: EvolutionEngineError.self) {
        try await store.attachDiff(id: p.id, diffText: "   \n ")
    }
}

// MARK: - Transitions

@Test func legal_transition_applies_and_receipts() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    let p = try await store.propose(source: .chat, title: "t", evidence: "e", diffText: sampleDiff)
    let (after, applied) = try await store.transition(
        id: p.id, to: .building, candidateRunId: "run-1")
    #expect(applied == true)
    #expect(after.status == .building)
    #expect(after.candidateRunId == "run-1")
    #expect(after.receipts.count == 2)
}

@Test func illegal_transition_refused_record_unchanged() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    let p = try await store.propose(source: .chat, title: "t", evidence: "e", diffText: sampleDiff)
    let (after, applied) = try await store.transition(id: p.id, to: .verified)
    #expect(applied == false)
    #expect(after.status == .proposed)
    #expect(after.receipts.count == 1)
}

@Test func require_precondition_mismatch_refused() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    let p = try await store.propose(source: .chat, title: "t", evidence: "e", diffText: sampleDiff)
    let (_, applied) = try await store.transition(
        id: p.id, to: .denied, require: [.staged])
    #expect(applied == false)
}

@Test func transition_unknown_id_throws_not_found() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    await #expect(throws: EvolutionEngineError.self) {
        _ = try await store.transition(id: "evo_nope", to: .building)
    }
}

@Test func full_lifecycle_walk_every_edge() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    let p = try await store.propose(source: .weekly, title: "t", evidence: "e")
    _ = try await store.attachDiff(id: p.id, diffText: sampleDiff)
    for step: EvolutionProposalStatus in [.building, .candidateGreen, .staged, .approved, .installed, .verified] {
        let (_, applied) = try await store.transition(id: p.id, to: step)
        #expect(applied == true, "edge to \(step.rawValue) should apply")
    }
    let final = try await store.get(id: p.id)
    #expect(final?.status == .verified)
}

@Test func candidate_failed_can_return_to_proposed() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    let p = try await store.propose(source: .chat, title: "t", evidence: "e", diffText: sampleDiff)
    _ = try await store.transition(id: p.id, to: .building)
    _ = try await store.transition(id: p.id, to: .candidateFailed)
    let (after, applied) = try await store.transition(id: p.id, to: .proposed)
    #expect(applied == true)
    #expect(after.status == .proposed)
}

// MARK: - Safety pins

@Test func tampered_risk_and_autoApprove_are_force_pinned_on_decode() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    let p = try await store.propose(source: .chat, title: "t", evidence: "e", diffText: sampleDiff)
    // Tamper the on-disk record: drop risk to "low", flip autoApprove.
    let path = store.storePath
    var text = try String(contentsOf: path, encoding: .utf8)
    text = text.replacingOccurrences(of: "\"critical\"", with: "\"low\"")
    text = text.replacingOccurrences(of: "\"autoApprove\" : false", with: "\"autoApprove\" : true")
    text = text.replacingOccurrences(of: "\"autoApprove\": false", with: "\"autoApprove\": true")
    try text.write(to: path, atomically: true, encoding: .utf8)

    let loaded = try await store.get(id: p.id)
    #expect(loaded?.risk == "critical")
    #expect(loaded?.autoApprove == false)
}

// MARK: - Fail-closed corruption

@Test func corrupt_store_refuses_and_preserves_file() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(dataRoot: root)
    _ = try await store.propose(source: .chat, title: "t", evidence: "e", diffText: sampleDiff)
    let path = store.storePath
    let garbage = "{{{ not json"
    try garbage.write(to: path, atomically: true, encoding: .utf8)

    do {
        _ = try await store.list()
        Issue.record("expected storeCorrupt")
    } catch let e as EvolutionEngineError {
        if case .storeCorrupt = e {} else { Issue.record("wrong error: \(e)") }
    }
    do {
        _ = try await store.propose(source: .chat, title: "x", evidence: "y", diffText: sampleDiff)
        Issue.record("expected storeCorrupt on write path too")
    } catch let e as EvolutionEngineError {
        if case .storeCorrupt = e {} else { Issue.record("wrong error: \(e)") }
    }
    // The corrupt file was NOT silently replaced.
    let after = try String(contentsOf: path, encoding: .utf8)
    #expect(after == garbage)
}

// MARK: - Sweep (remove path)

@Test func sweep_removes_only_aged_terminal_records() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let clock = ClockBox(t0)
    let store = makeStore(dataRoot: root, now: { clock.get() })

    let oldTerminal = try await store.propose(source: .chat, title: "old-done", evidence: "e", diffText: sampleDiff)
    _ = try await store.transition(id: oldTerminal.id, to: .denied, denyReason: "no")
    let oldActive = try await store.propose(source: .chat, title: "old-active", evidence: "e", diffText: sampleDiff)

    // Jump 31 days; add a fresh terminal record.
    clock.set(t0.addingTimeInterval(31 * 24 * 3600))
    let freshTerminal = try await store.propose(source: .chat, title: "fresh-done", evidence: "e", diffText: sampleDiff)
    _ = try await store.transition(id: freshTerminal.id, to: .denied, denyReason: "no")

    let removed = try await store.sweep(olderThanDays: 30)
    #expect(removed == 1)
    let remaining = try await store.list()
    let ids = Set(remaining.map(\.id))
    #expect(!ids.contains(oldTerminal.id))
    #expect(ids.contains(oldActive.id))
    #expect(ids.contains(freshTerminal.id))
}

// MARK: - Persistence across instances

@Test func records_survive_store_reinstantiation() async throws {
    let root = try tempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let p = try await makeStore(dataRoot: root).propose(
        source: .external, title: "t", evidence: "e", diffText: sampleDiff)
    let second = makeStore(dataRoot: root)
    let loaded = try await second.get(id: p.id)
    #expect(loaded?.id == p.id)
    #expect(loaded?.diffSHA256 == p.diffSHA256)
}

// MARK: - Helpers

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ d: Date) { date = d }
    func get() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ d: Date) { lock.lock(); date = d; lock.unlock() }
}

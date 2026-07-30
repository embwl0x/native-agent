import Testing
import Foundation
@testable import BackgroundLoops

// MARK: - Mock recaller

private actor MockRecaller: MemoryConsolidationRecaller {
    var records: [ConsolidationCandidate]
    var removed: [String] = []
    var shouldThrowOnList: Bool = false
    var shouldThrowOnRemove: Bool = false

    init(_ records: [ConsolidationCandidate]) {
        self.records = records
    }

    func setThrowOnList(_ v: Bool) { shouldThrowOnList = v }
    func setThrowOnRemove(_ v: Bool) { shouldThrowOnRemove = v }
    func currentIds() -> [String] { records.map(\.id).sorted() }
    func removedIds() -> [String] { removed }

    struct MockError: Error {}

    func listAllForConsolidation() async throws -> [ConsolidationCandidate] {
        if shouldThrowOnList { throw MockError() }
        return records
    }

    func remove(id: String) async throws {
        if shouldThrowOnRemove { throw MockError() }
        removed.append(id)
        records.removeAll { $0.id == id }
    }
}

// MARK: - hermetic root (U5 W-F test hermeticity)
//
// `MemoryConsolidationLoop`'s `dataRoot:` defaults to `defaultDataRoot()` —
// the LIVE app data root under `swift test`. These tests are safe-by-accident
// today because `MockRecaller` intercepts the list/remove I/O, but the loop
// still captures the live root and the stderr log line reports it. Pinning
// every construction to a fresh temp dir makes the suite hermetic BY
// CONSTRUCTION rather than by accident.
private func hermeticLoopRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MemConsolidationTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - vector helpers

/// L2-normalized vector with `value` in slot 0, padded with zeros so cosine
/// across two such vectors is trivially computable.
private func vec(_ values: [Float]) -> [Float] {
    var sumsq: Float = 0
    for v in values { sumsq += v * v }
    let norm = sumsq > 0 ? sqrtf(sumsq) : 1
    return values.map { $0 / norm }
}

private func cand(_ id: String, _ embedding: [Float], _ text: String = "t", _ ts: Date) -> ConsolidationCandidate {
    ConsolidationCandidate(id: id, embedding: vec(embedding), text: text, updatedAt: ts)
}

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
private func date(_ offset: TimeInterval) -> Date { baseDate.addingTimeInterval(offset) }

// MARK: - Tests

@Test
func tick_with_no_duplicates_keeps_all() async throws {
    // Orthogonal-ish vectors → cosine far below 0.95.
    let mock = MockRecaller([
        cand("a", [1, 0, 0, 0], ts: date(0)),
        cand("b", [0, 1, 0, 0], ts: date(1)),
        cand("c", [0, 0, 1, 0], ts: date(2)),
    ])
    let loop = MemoryConsolidationLoop(recaller: mock, dataRoot: hermeticLoopRoot())
    await loop.tick()
    let removed = await mock.removedIds()
    #expect(removed.isEmpty)
    let ids = await mock.currentIds()
    #expect(ids == ["a", "b", "c"])
}

@Test
func tick_with_duplicate_pair_keeps_newer_removes_older() async throws {
    let mock = MockRecaller([
        cand("old", [1, 0, 0, 0], ts: date(0)),
        cand("new", [1, 0, 0, 0], ts: date(100)),
        cand("other", [0, 1, 0, 0], ts: date(50)),
    ])
    let loop = MemoryConsolidationLoop(recaller: mock, dataRoot: hermeticLoopRoot())
    await loop.tick()
    let removed = await mock.removedIds()
    #expect(removed == ["old"])
    let ids = await mock.currentIds()
    #expect(ids == ["new", "other"])
}

@Test
func tick_with_cluster_of_3_keeps_newest_removes_2() async throws {
    let mock = MockRecaller([
        cand("oldest", [1, 0, 0, 0], ts: date(0)),
        cand("middle", [1, 0, 0, 0], ts: date(10)),
        cand("newest", [1, 0, 0, 0], ts: date(20)),
    ])
    let loop = MemoryConsolidationLoop(recaller: mock, dataRoot: hermeticLoopRoot())
    await loop.tick()
    let removed = Set(await mock.removedIds())
    #expect(removed == Set(["oldest", "middle"]))
    let ids = await mock.currentIds()
    #expect(ids == ["newest"])
}

@Test
func tick_threshold_0_95_used() async throws {
    // Construct a pair just BELOW 0.95 — should not be merged.
    // cos(θ) = 0.9 between unit vectors u=[1,0], v=[0.9, sqrt(1-0.81)].
    let below: [Float] = [0.9, sqrtf(0.19), 0, 0]  // cosine with [1,0,0,0] ≈ 0.9
    let mockBelow = MockRecaller([
        cand("a", [1, 0, 0, 0], ts: date(0)),
        cand("b", below, ts: date(1)),
    ])
    let loopBelow = MemoryConsolidationLoop(recaller: mockBelow, dataRoot: hermeticLoopRoot())
    await loopBelow.tick()
    #expect(await mockBelow.removedIds() == [])

    // Construct a pair just ABOVE 0.95 — should merge.
    // cos(θ) ≈ 0.99 between [1,0] and [0.99, sqrt(1-0.9801)].
    let above: [Float] = [0.99, sqrtf(0.0199), 0, 0]
    let mockAbove = MockRecaller([
        cand("a", [1, 0, 0, 0], ts: date(0)),
        cand("b", above, ts: date(1)),
    ])
    let loopAbove = MemoryConsolidationLoop(recaller: mockAbove, dataRoot: hermeticLoopRoot())
    await loopAbove.tick()
    #expect(await mockAbove.removedIds() == ["a"])
}

@Test
func tick_non_throwing_on_recall_error() async throws {
    let mock = MockRecaller([])
    await mock.setThrowOnList(true)
    let loop = MemoryConsolidationLoop(recaller: mock, dataRoot: hermeticLoopRoot())
    // Must not throw, but cannot become a successful scheduler tick.
    guard case .failed(let error) = await loop.tickOutcome() else {
        Issue.record("expected typed consolidation failure")
        return
    }
    #expect(error.contains("list"))
    #expect(await mock.removedIds().isEmpty)
}

@Test
func default_interval_is_3600() {
    let mock = MockRecaller([])
    let loop = MemoryConsolidationLoop(recaller: mock, dataRoot: hermeticLoopRoot())
    #expect(loop.interval == 3600)
}

@Test
func loopId_is_memory_consolidation() {
    let mock = MockRecaller([])
    let loop = MemoryConsolidationLoop(recaller: mock, dataRoot: hermeticLoopRoot())
    #expect(loop.loopId == "memory_consolidation")
}

@Test
func tick_uses_recaller_remove() async throws {
    let mock = MockRecaller([
        cand("a", [1, 0, 0, 0], ts: date(0)),
        cand("b", [1, 0, 0, 0], ts: date(5)),
    ])
    let loop = MemoryConsolidationLoop(recaller: mock, dataRoot: hermeticLoopRoot())
    await loop.tick()
    let removed = await mock.removedIds()
    #expect(removed.count == 1)
    #expect(removed == ["a"])
}

// Shim so `cand("id", vector, ts: date(N))` reads cleanly.
private func cand(_ id: String, _ embedding: [Float], ts: Date) -> ConsolidationCandidate {
    cand(id, embedding, "t", ts)
}

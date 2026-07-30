import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// G-M2 (tightness round 2, 2026-07-18): the substrate's artifact dicts are
// disk-capped and restart-capped, but the IN-PROCESS dicts grew without bound
// over a days-long run (`.values` scans went O(N)). Each record tail now enforces
// an in-memory cap mirroring `enforceThoughtSeedCap`, evicting the oldest by
// timestamp, retained-N matched to the family's restore limit. These prove the
// highest-cadence family (reflectionReceipts) and the episodes/replayEvidenceIds
// pairing hold their bound and evict the oldest, not the newest.
@Suite("ArtifactInMemoryCap")
struct ArtifactInMemoryCapTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func makeSubstrate(_ clock: Clock) async throws -> CognitiveSubstrate {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-artifactcap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let s = CognitiveSubstrate(
            configuration: .allPhasesEnabled,
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: store)
        try await s.restorePersistentState()
        return s
    }

    // reflectionReceipts is the highest-cadence family (~10×/day). Cap =
    // max(40, dailyReflectionCallBudget * 4); allPhasesEnabled budget is 2 → 40.
    @Test func reflectionReceiptsCapEvictsOldestByTimestamp() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_760_000_000))
        let s = try await makeSubstrate(clock)
        let cap = 40

        // Record 15 more than the cap; each on a distinct (advancing) timestamp so
        // eviction order is unambiguous.
        for i in 0..<(cap + 15) {
            clock.advance(60)
            let request = CognitiveReflectionRequest(
                reason: "cap-\(i)",
                prompt: "prompt-\(i)",
                requestedAt: clock.now())
            _ = await s.recordUnreservedReflectionResultForTesting(
                request: request,
                resultSummary: "result-\(i)",
                provider: "test",
                cancelled: true)
        }

        let receipts = await s.reflectionReceiptSnapshot()
        #expect(receipts.count == cap)
        // Snapshot is newest-first. The newest recorded survives; the oldest 15
        // (cap-0…cap-14) were evicted, so the oldest survivor is cap-15.
        #expect(receipts.first?.request.reason == "cap-54")
        #expect(receipts.last?.request.reason == "cap-15")
        #expect(!receipts.contains { $0.request.reason == "cap-0" })
        #expect(!receipts.contains { $0.request.reason == "cap-14" })
    }

    // episodes cap = 120 (restore limit). replayEvidenceIds is the dedup guard for
    // dream replay and has no timestamp/disk restore; it is bounded in lockstep —
    // when an episode is evicted, its evidence id is pruned, so a re-dream of an
    // evicted episode is re-created (not silently deduped), while a surviving
    // episode's dream is still deduped.
    @Test func episodeCapEvictsOldestAndReplayEvidencePrunesInLockstep() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_760_000_000))
        let s = try await makeSubstrate(clock)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = DateComponents(
            calendar: utc, timeZone: TimeZone(secondsFromGMT: 0),
            year: 2025, month: 1, day: 1).date!
        let formatter = DateFormatter()
        formatter.calendar = utc
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        func dreamDate(_ i: Int) -> String {
            formatter.string(from: utc.date(byAdding: .day, value: i, to: base)!)
        }
        func dream(_ i: Int) -> CognitiveDreamReplayReference {
            CognitiveDreamReplayReference(
                id: "dream-\(i)",
                date: dreamDate(i),               // distinct ascending occurredAt
                filename: "\(i).md",
                content: "dream replay content number \(i)")
        }

        // Replay integrates at most 8 dreams per call. 17 batches → 136 episodes;
        // the cap of 120 evicts the 16 oldest (dreams 0…15).
        let total = 136
        for start in stride(from: 0, to: total, by: 8) {
            let batch = (start..<min(start + 8, total)).map(dream)
            _ = await s.integrateReplay(CognitiveReplayIntegrationInput(
                reason: "cap-batch-\(start)", dreamEntries: batch))
        }

        let episodes = await s.episodeSnapshot()
        #expect(episodes.count == 120)

        // A dream whose episode was evicted (dream-0) must be re-created, proving
        // its evidence id was pruned from the dedup set in lockstep.
        let evicted = await s.integrateReplay(CognitiveReplayIntegrationInput(
            reason: "re-evicted", dreamEntries: [dream(0)]))
        #expect(!evicted.episodeIds.isEmpty)
        #expect(evicted.skippedEvidenceIds.isEmpty)

        // A dream whose episode survives (dream-135, newest) must still be deduped,
        // proving referenced evidence ids are retained.
        let surviving = await s.integrateReplay(CognitiveReplayIntegrationInput(
            reason: "re-surviving", dreamEntries: [dream(135)]))
        #expect(surviving.episodeIds.isEmpty)
        #expect(!surviving.skippedEvidenceIds.isEmpty)

        // Cap still holds after the perturbations.
        #expect(await s.episodeSnapshot().count <= 120)
    }
}

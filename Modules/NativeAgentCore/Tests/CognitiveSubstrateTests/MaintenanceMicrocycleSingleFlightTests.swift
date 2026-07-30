import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

/// R-F2: the microcycle and maintenance must not interleave their SQLite
/// commits. Before the fix, a maintenance decay that landed while the microcycle
/// was suspended in its store commit was reverted on disk by the microcycle's
/// pre-decay seed rows (memory stayed correct; the next maintenance healed).
/// The fix makes the flight exclusion symmetric: the microcycle raises
/// `maintenanceCommitInFlight` across its commit window and `runMaintenanceChecked`
/// refuses to start while it is set.
@Suite("Maintenance/microcycle single-flight", .serialized)
struct MaintenanceMicrocycleSingleFlightTests {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ current: Date) { self.current = current }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    }

    private final class BoolBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        var read: Bool? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeStore(_ label: String) throws -> (CognitiveSQLiteStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-rf2-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try CognitiveSQLiteStore(dataRoot: root), root)
    }

    private func makeSubstrate(clock: TestClock, store: CognitiveSQLiteStore) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: true,
                affectEnabled: true,
                thoughtSeedsEnabled: true,
                backgroundMicrocyclesEnabled: true,
                maximumActiveNodes: 256,
                defaultDecayHalfLife: 3_600
            ),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }),
            store: store
        )
    }

    private func diskSeedPriority(_ store: CognitiveSQLiteStore) async throws -> Double? {
        let rows = try await store.loadArtifacts(kindPrefix: "thought_seed", limit: 10)
        guard case .object(let object)? = rows.first,
              case .double(let priority)? = object["priority"] else { return nil }
        return priority
    }

    @Test("a maintenance decay interleaved into the microcycle commit window is excluded, so disk never diverges from memory")
    func interleavedMaintenanceIsExcludedAndDecaySurvivesOnDisk() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 30_000_000))
        let (store, root) = try makeStore("interleave")
        defer { try? FileManager.default.removeItem(at: root) }
        let substrate = makeSubstrate(clock: clock, store: store)

        // A durable seed at priority 0.8, anchored at T0. This also marks the
        // substrate dirty so the microcycle has work to settle.
        _ = await substrate.addThoughtSeed(kind: .followUp, text: "carry this", priority: 0.8)
        #expect(try await diskSeedPriority(store) == 0.8)

        // Twelve hours later a maintenance decay would take the seed to ~0.566
        // (24h half-life). Above the 0.05 retention floor, so it survives, not
        // deleted — a clean, observable priority change.
        clock.advance(12 * 60 * 60)

        // Drive an interleaving maintenance run from INSIDE the microcycle's
        // commit window. With the fix it must be refused (returns false); the
        // seed is never decayed underneath the in-flight microcycle commit.
        let maintenanceRan = BoolBox()
        await substrate.setMicrocycleCommitInterleaveProbeForTesting { [weak substrate] in
            guard let substrate else { return }
            let ran = (try? await substrate.runMaintenanceChecked(reason: "interleaved probe")) ?? false
            maintenanceRan.set(ran)
        }

        _ = try await substrate.runMicrocycleChecked(reason: "settle")

        // The interleaving maintenance was excluded by the symmetric flight guard.
        #expect(maintenanceRan.read == false)

        // The microcycle committed the seed it snapshotted (0.8). Because the
        // decay was excluded, memory still holds 0.8 — so disk and memory agree.
        // (Before the fix, maintenance would have decayed memory to ~0.566 and
        // committed it, and the microcycle would then have reverted disk to 0.8,
        // leaving disk != memory.)
        let memoryAfterCycle = await substrate.thoughtSeeds.values.first?.priority
        let diskAfterCycle = try await diskSeedPriority(store)
        #expect(memoryAfterCycle == 0.8)
        #expect(diskAfterCycle == memoryAfterCycle)

        // Clear the probe and let maintenance run on its own now that no
        // microcycle commit is in flight: the decay lands and SURVIVES on disk.
        await substrate.setMicrocycleCommitInterleaveProbeForTesting(nil)
        let ranNow = try await substrate.runMaintenanceChecked(reason: "post-cycle maintenance")
        #expect(ranNow == true)

        let memoryDecayed = await substrate.thoughtSeeds.values.first?.priority
        let diskDecayed = try await diskSeedPriority(store)
        let decayed = try #require(memoryDecayed)
        #expect(decayed < 0.8)                         // the decay actually happened
        #expect(abs(decayed - 0.8 * pow(0.5, 0.5)) < 1e-6) // 12h at 24h half-life
        #expect(diskDecayed == memoryDecayed)          // and it survives on disk
    }
}

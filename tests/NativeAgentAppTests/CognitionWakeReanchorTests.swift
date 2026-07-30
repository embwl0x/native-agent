import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// R-F4: after a system wake the exact-deadline cognition timers must be
/// re-anchored to the post-wake clock. `Task.sleep` does not advance across
/// system sleep, so a deadline armed before sleep fires late until the next
/// sensory event re-arms it. `reanchorDeadlinesAfterWake()` forces a re-arm —
/// even when the projected deadline Date is unchanged (only the remaining
/// Task.sleep delay changed) — following the ContextFlow re-anchor pattern.
@Suite("Cognition wake re-anchor", .serialized)
struct CognitionWakeReanchorTests {
    private final class WakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-wake-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRuntime(root: URL, clock: WakeClock) -> NativeCognitionRuntime {
        NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: true,
                workspaceEnabled: true,
                affectEnabled: true,
                thoughtSeedsEnabled: true,
                backgroundMicrocyclesEnabled: true,
                observatoryEnabled: true,
                defaultDecayHalfLife: 24 * 60 * 60,
                maximumThoughtSeeds: 64
            ),
            now: { clock.now() },
            microcycleSchedulingMode: .manuallyFlushed
        )
    }

    @Test("wake re-anchor forces a re-arm even when the deadline Date is unchanged, and moves it once past the deadline")
    func wakeReanchorReAnchorsCognitionMaintenanceDeadline() async throws {
        let root = try temporaryRoot("reanchor")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = WakeClock(Date(timeIntervalSince1970: 10_000_000))
        let runtime = makeRuntime(root: root, clock: clock)

        await runtime.bootstrap()
        await runtime.flushPendingMicrocycleForProof()
        // The first maintenance is due immediately (consolidation never ran).
        #expect(await runtime.cognitionMaintenanceDeadlineForProof() == clock.now())
        await runtime.flushCognitionMaintenanceDeadlineForProof()

        // After firing once, the next deadline is the 20h consolidation boundary.
        let futureDeadline = try #require(await runtime.cognitionMaintenanceDeadlineForProof())
        #expect(futureDeadline == clock.now().addingTimeInterval(20 * 60 * 60))

        // --- Case 1: wake with the deadline STILL in the future ---
        // The absolute Date does not change, but Task.sleep's remaining delay is
        // now stale. The re-anchor must FORCE a re-arm (generation bumps) past
        // the unchanged-deadline idempotency short-circuit.
        clock.advance(5 * 60 * 60) // slept 5h; deadline (20h) not yet reached
        let genBeforeWake = await runtime.cognitionMaintenanceGenerationForProof()
        await runtime.reanchorDeadlinesAfterWake()
        let deadlineAfterWake = try #require(await runtime.cognitionMaintenanceDeadlineForProof())
        let genAfterWake = await runtime.cognitionMaintenanceGenerationForProof()
        #expect(deadlineAfterWake == futureDeadline)         // same absolute Date
        #expect(genAfterWake == genBeforeWake + 1)           // but forcibly re-armed

        // Idempotent: a second wake re-anchor re-arms exactly once more and never
        // leaves two competing arms (the pending deadline stays single/stable).
        await runtime.reanchorDeadlinesAfterWake()
        #expect(await runtime.cognitionMaintenanceGenerationForProof() == genAfterWake + 1)
        #expect(await runtime.cognitionMaintenanceDeadlineForProof() == futureDeadline)

        // --- Case 2: wake AFTER sleeping past the deadline ---
        // The projected deadline collapses to `now` so maintenance fires promptly
        // instead of staying pinned to the stale pre-sleep Date.
        clock.advance(20 * 60 * 60) // now well past the 20h boundary
        await runtime.reanchorDeadlinesAfterWake()
        #expect(await runtime.cognitionMaintenanceDeadlineForProof() == clock.now())
    }

    @Test("wake re-anchor before bootstrap is a safe no-op")
    func wakeReanchorBeforeBootstrapIsNoOp() async throws {
        let root = try temporaryRoot("reanchor-pre-bootstrap")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = WakeClock(Date(timeIntervalSince1970: 11_000_000))
        let runtime = makeRuntime(root: root, clock: clock)

        // No bootstrap → no armed timers to re-anchor. Must not arm anything or crash.
        await runtime.reanchorDeadlinesAfterWake()
        #expect(await runtime.cognitionMaintenanceDeadlineForProof() == nil)
        #expect(await runtime.cognitionMaintenanceGenerationForProof() == 0)
    }
}

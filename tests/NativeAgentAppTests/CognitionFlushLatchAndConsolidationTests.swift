import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// G-H2 / G-H1 (tightness round 2, 2026-07-18).
///
/// G-H2: `flushForTermination` must quiesce the dirty-microcycle and replay-retry
/// tasks AND every deadline re-arm site must honor the `isFlushedForTermination`
/// latch — not just the wake re-anchor. A queued microcycle that runs after the
/// terminal snapshot re-arms the cognition-maintenance deadline at its tail
/// (`runScheduledMicrocycle` → `rescheduleCognitionMaintenanceDeadline`); with the
/// latch moved into the reschedule bodies, that re-arm must no-op.
///
/// G-H1: commit d0bcd775 severed the operational-consolidation lane from the
/// residual-deadline fire path and hardcoded `operationalConsolidationPerformed:
/// false`. The regression guard for a *deleted call site* is a wiring assertion:
/// the fire body must call `runOperationalConsolidationIfDue()` and pass its real
/// disposition to telemetry, while the not-due branch keeps `false`.
@Suite("Cognition flush latch and operational consolidation", .serialized)
struct CognitionFlushLatchAndConsolidationTests {
    private final class LatchClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-flushlatch-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRuntime(root: URL, clock: LatchClock) -> NativeCognitionRuntime {
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

    @Test("after flushForTermination a queued dirty-microcycle cannot re-arm a deadline")
    func flushLatchBlocksQueuedMicrocycleReArm() async throws {
        let root = try temporaryRoot("queued-microcycle")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LatchClock(Date(timeIntervalSince1970: 12_500_000))
        let runtime = makeRuntime(root: root, clock: clock)

        await runtime.bootstrap()
        await runtime.flushPendingMicrocycleForProof()
        // The normal path arms a cognition-maintenance deadline — the contrast that
        // makes "nil after flush" a real proof, not a vacuous one.
        #expect(await runtime.cognitionMaintenanceDeadlineForProof() != nil)

        // Queue a dirty microcycle: an ordinary sensory event marks the resident
        // field dirty and sets a pending generation, but nothing settles inline
        // under manuallyFlushed scheduling.
        await runtime.observe(CognitiveEvent(
            id: "flush-latch-dirty",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "flush-latch", label: "flush-latch"),
            sourceClass: .userStated,
            occurredAt: clock.now(),
            summary: "a dirty settle is now queued",
            importance: 0.8,
            metadata: ["sessionId": .string("flush-latch")]))

        // Terminal flush: invalidates both deadlines and latches shutdown.
        await runtime.flushForTermination()
        #expect(await runtime.cognitionMaintenanceDeadlineForProof() == nil)
        #expect(await runtime.residualRepairDeadlineForProof() == nil)

        // Drain the queued microcycle. gpt-5.5 fix round STRENGTHENED this:
        // flush now clears the pending generation and runScheduledMicrocycle
        // honors the latch, so the queued microcycle must NOT run at all —
        // no commit may land after the terminal snapshot (the original pin
        // only rejected the tail re-arm and let the commit through).
        let executedBefore = await runtime.microcycleTelemetrySnapshot().executedCount
        await runtime.flushPendingMicrocycleForProof()
        let executedAfter = await runtime.microcycleTelemetrySnapshot().executedCount
        #expect(executedAfter == executedBefore)
        #expect(await runtime.cognitionMaintenanceDeadlineForProof() == nil)
        #expect(await runtime.residualRepairDeadlineForProof() == nil)

        // A wake re-anchor landing during teardown is likewise inert.
        await runtime.reanchorDeadlinesAfterWake()
        #expect(await runtime.cognitionMaintenanceDeadlineForProof() == nil)
        #expect(await runtime.residualRepairDeadlineForProof() == nil)
    }

    @Test("residual-deadline fire path is wired to the operational-consolidation lane")
    func residualFirePathWiresOperationalConsolidation() throws {
        let source = try Self.appSource("NativeCognitionRuntime+Deadlines.swift")

        // The severed call site is restored…
        #expect(source.contains("await organismKernel.runOperationalConsolidationIfDue()"))
        // …and its real disposition reaches telemetry (not a hardcoded false).
        #expect(source.contains("operationalConsolidationPerformed: operational != nil"))
        // …while the not-due branch still reports false.
        #expect(source.contains("operationalConsolidationPerformed: false"))
    }

    private static func appSource(_ name: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("Sources/NativeAgentApp", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw WiringLookupError("Could not locate Sources/NativeAgentApp/\(name) from \(#filePath)")
    }
}

private struct WiringLookupError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

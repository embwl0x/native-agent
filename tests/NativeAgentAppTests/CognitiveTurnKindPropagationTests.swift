import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Cognitive turn-kind propagation", .serialized)
struct CognitiveTurnKindPropagationTests {
    /// These tests run the runtime's REAL debounced microcycle scheduler, so
    /// settlement has no fixed upper bound under full-suite parallelism.
    /// Positive steps (a settlement SHOULD land) poll with a generous deadline;
    /// the baseline read instead waits for quiescence (the receipt count
    /// unchanged across a bounded window) because bootstrap may or may not own
    /// a reconciliation microcycle. The old fixed 600ms sleeps were roving
    /// flakes on a loaded machine.
    private func microcycleReceiptCount(_ substrate: CognitiveSubstrate) async -> Int {
        await substrate.receiptSnapshot().filter { $0.kind == "microcycle" }.count
    }

    private func waitForMicrocycleCount(
        _ substrate: CognitiveSubstrate,
        toReach expected: Int,
        deadline: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: deadline)
        while await microcycleReceiptCount(substrate) < expected, clock.now < limit {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func quiescentMicrocycleBaseline(
        _ substrate: CognitiveSubstrate,
        quietWindow: Duration = .milliseconds(500),
        deadline: Duration = .seconds(10)
    ) async throws -> Int {
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: deadline)
        var count = await microcycleReceiptCount(substrate)
        var quietSince = clock.now
        while clock.now < limit {
            try await Task.sleep(for: .milliseconds(50))
            let next = await microcycleReceiptCount(substrate)
            if next != count {
                count = next
                quietSince = clock.now
            } else if clock.now - quietSince >= quietWindow {
                return count
            }
        }
        return count
    }

    @Test("production manifest excludes orphan harness-learning scaffold")
    func productionManifestHasNoHarnessLearningLoop() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-harness-learning-\(UUID().uuidString)", isDirectory: true)
        let production = Set(BackgroundLoopsAssembly.assembleAllLoops(dataRoot: root).map(\.loopId))
        #expect(!production.contains("harness_learning"))
    }

    @Test("sensory events settle cognition without a periodic microcycle owner")
    func eventDrivenMicrocycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognitive-event-cycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: testCognitionConfiguration(),
            organismConfigurationOverride: .disabled
        )
        await runtime.bootstrap()
        let substrate = await runtime.substrateForIntegration()
        let baseline = try await quiescentMicrocycleBaseline(substrate)

        await runtime.observe(event(
            id: "sensory-change",
            kind: .userMessageReceived,
            summary: "A meaningful event reached the resident mind",
            sessionId: "event-driven",
            runId: "event-driven-run"
        ))
        try await waitForMicrocycleCount(substrate, toReach: baseline + 1)

        let after = await substrate.receiptSnapshot().filter { $0.kind == "microcycle" }.count
        #expect(after == baseline + 1)
        let productionIds = Set(BackgroundLoopsAssembly.assembleAllLoops(dataRoot: root).map(\.loopId))
        #expect(!productionIds.contains("cognition_microcycle"))
    }

    @Test("a burst of sensory events coalesces into one cognition settlement")
    func eventBurstCoalesces() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognitive-event-burst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: testCognitionConfiguration(),
            organismConfigurationOverride: .disabled
        )
        await runtime.bootstrap()
        let substrate = await runtime.substrateForIntegration()
        let baseline = try await quiescentMicrocycleBaseline(substrate)
        let telemetryBefore = await runtime.microcycleTelemetrySnapshot()

        for index in 0..<12 {
            await runtime.observe(event(
                id: "burst-\(index)",
                kind: .toolSucceeded,
                summary: "Bounded burst event \(index)",
                sessionId: "event-burst",
                runId: "event-burst-run"
            ))
        }
        try await waitForMicrocycleCount(substrate, toReach: baseline + 1)

        let receipts = await substrate.receiptSnapshot().filter { $0.kind == "microcycle" }
        #expect(receipts.count == baseline + 1)
        let nodes = await substrate.snapshot().nodes.filter {
            $0.subjectReference.id.hasPrefix("burst-")
        }
        #expect(nodes.count == 12)
        let telemetryAfter = await runtime.microcycleTelemetrySnapshot()
        #expect(telemetryAfter.scheduledSignalCount == telemetryBefore.scheduledSignalCount + 12)
        #expect(telemetryAfter.coalescedReplacementCount >= telemetryBefore.coalescedReplacementCount + 11)
        #expect(telemetryAfter.executedCount == telemetryBefore.executedCount + 1)
        #expect(telemetryAfter.completedCount == telemetryBefore.completedCount + 1)
        #expect(telemetryAfter.failedCount == telemetryBefore.failedCount)
        #expect(telemetryAfter.lastOutcome == "completed")
        #expect(telemetryAfter.lastDurationMilliseconds != nil)
    }

    @Test("app wake performs one reconciliation after relaunch")
    func wakeReconciliationAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognitive-event-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: testCognitionConfiguration(),
            organismConfigurationOverride: .disabled
        )
        await first.bootstrap()
        let firstSubstrate = await first.substrateForIntegration()
        let firstBaseline = try await quiescentMicrocycleBaseline(firstSubstrate)
        await first.observe(event(
            id: "persist-across-relaunch",
            kind: .userMessageReceived,
            summary: "Keep this state through a clean relaunch",
            sessionId: "relaunch",
            runId: "relaunch-run"
        ))
        try await waitForMicrocycleCount(firstSubstrate, toReach: firstBaseline + 1)
        // The app's real shutdown path makes persistence deterministic before
        // relaunch — the old fixed 600ms sleep raced the durable write.
        await first.flushForTermination()
        // Receipts are DURABLE (receiptSnapshot reads the persistent store),
        // so the relaunch assertion must wait for one MORE receipt than the
        // count persisted here — waiting for "any microcycle receipt" would be
        // satisfied by this first runtime's history and prove nothing about
        // the wake reconciliation (gpt-5.5 review SHOULD-FIX).
        let persistedCount = await firstSubstrate.receiptSnapshot()
            .filter { $0.kind == "microcycle" }.count

        let relaunched = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: testCognitionConfiguration(),
            organismConfigurationOverride: .disabled
        )
        await relaunched.bootstrap()
        let substrate = await relaunched.substrateForIntegration()
        // Positive steps: the restored node and a FRESH wake-reconciliation
        // microcycle (beyond the persisted history) SHOULD land — poll with a
        // generous deadline.
        try await waitForMicrocycleCount(substrate, toReach: persistedCount + 1)
        let nodes = await substrate.snapshot().nodes
        #expect(nodes.contains { $0.subjectReference.id == "persist-across-relaunch" })
        #expect(await substrate.receiptSnapshot()
            .filter { $0.kind == "microcycle" }.count >= persistedCount + 1,
            "relaunch bootstrap must run its own wake-reconciliation microcycle")
    }

    @Test("debug bridge classification reaches tools and reply without poisoning the next live turn")
    func debugClassificationIsRunScoped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognitive-turn-kind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: testCognitionConfiguration(),
            organismConfigurationOverride: .enabled
        )
        await runtime.bootstrap()
        let baselineSignals = await runtime.organismSnapshot().signalCount
        let sessionId = "shared-session"
        let debugRunId = "debug-run"

        await runtime.observe(event(
            id: "debug-user",
            kind: .userMessageReceived,
            summary: "[from: codex, via bridge] check the live runtime",
            sessionId: sessionId,
            runId: debugRunId
        ))
        await runtime.observe(event(
            id: "debug-tool",
            kind: .toolSucceeded,
            summary: "read_file completed",
            sessionId: sessionId,
            runId: debugRunId
        ))
        await runtime.observe(event(
            id: "debug-assistant",
            kind: .assistantTurnCompleted,
            summary: "The runtime is healthy.",
            sessionId: sessionId,
            runId: debugRunId
        ))

        let substrate = await runtime.substrateForIntegration()
        let debugNodes = await substrate.snapshot().nodes.filter {
            ["debug-user", "debug-tool", "debug-assistant"].contains($0.subjectReference.id)
        }
        #expect(debugNodes.count == 3)
        #expect(debugNodes.allSatisfy { $0.turnKind == .debug })
        #expect(await runtime.organismSnapshot().signalCount == baselineSignals)
        #expect(await runtime.nonLiveTurnKindByRunId[debugRunId] == nil)

        let verificationRunId = "verification-run"
        await runtime.observe(event(
            id: "verification-user",
            kind: .userMessageReceived,
            summary: "CTX-SNAPSHOT-VERIFY bridge-passthrough ping",
            sessionId: sessionId,
            runId: verificationRunId
        ))
        await runtime.observe(event(
            id: "verification-assistant",
            kind: .assistantTurnCompleted,
            summary: "The snapshot path is healthy.",
            sessionId: sessionId,
            runId: verificationRunId
        ))
        let verificationNodes = await substrate.snapshot().nodes.filter {
            ["verification-user", "verification-assistant"].contains($0.subjectReference.id)
        }
        #expect(verificationNodes.count == 2)
        #expect(verificationNodes.allSatisfy { $0.turnKind == .verification })
        #expect(await runtime.organismSnapshot().signalCount == baselineSignals)

        let liveRunId = "live-run"
        await runtime.observe(event(
            id: "live-user",
            kind: .userMessageReceived,
            summary: "How are you feeling right now?",
            sessionId: sessionId,
            runId: liveRunId
        ))
        await runtime.observe(event(
            id: "live-assistant",
            kind: .assistantTurnCompleted,
            summary: "Steady, warm, and focused.",
            sessionId: sessionId,
            runId: liveRunId
        ))

        let liveNodes = await substrate.snapshot().nodes.filter {
            ["live-user", "live-assistant"].contains($0.subjectReference.id)
        }
        #expect(liveNodes.count == 2)
        #expect(liveNodes.allSatisfy { $0.turnKind == .live })
        #expect(await runtime.organismSnapshot().signalCount > baselineSignals)
    }

    @Test("non-live run inheritance is bounded")
    func runInheritanceIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognitive-turn-kind-bound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = NativeCognitionRuntime(dataRoot: root)
        let overflow = 20
        for index in 0..<(NativeCognitionRuntime.maximumNonLiveTurnKindRuns + overflow) {
            await runtime.rememberNonLiveTurnKind(.debug, runId: "run-\(index)")
        }

        let retained = await runtime.nonLiveTurnKindByRunId
        #expect(retained.count == NativeCognitionRuntime.maximumNonLiveTurnKindRuns)
        #expect(retained["run-0"] == nil)
        #expect(retained["run-\(overflow - 1)"] == nil)
        #expect(retained["run-\(overflow)"] == .debug)
    }

    @Test("trusted bridge can read the current capsule without replacing the last live injection")
    func trustedBridgeProjectionIsReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognitive-bridge-projection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: testCognitionConfiguration(),
            organismConfigurationOverride: .disabled
        )
        let bridgeCapsule = try #require(await runtime.prepareCapsule(CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "[from: codex, via bridge] work with Agent",
            mode: .inject,
            allowNonLiveProjection: true
        )))
        #expect(!bridgeCapsule.dynamicContext.isEmpty)
        #expect(await runtime.lastInjectedCapsuleBridgeSummary().source == "none")

        _ = try #require(await runtime.prepareCapsule(CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "How are you feeling right now?",
            mode: .inject
        )))
        #expect(await runtime.lastInjectedCapsuleBridgeSummary().source == "live_injected")
    }

    private func event(
        id: String,
        kind: CognitiveEventKind,
        summary: String,
        sessionId: String,
        runId: String
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: id,
            kind: kind,
            subject: CognitiveSubjectReference(type: "test", id: id, label: id),
            sourceClass: .observed,
            occurredAt: Date(),
            summary: summary,
            importance: 0.7,
            metadata: [
                "sessionId": .string(sessionId),
                "runId": .string(runId),
            ]
        )
    }

    private func testCognitionConfiguration() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true,
            replayEnabled: true,
            backgroundMicrocyclesEnabled: true,
            observatoryEnabled: true,
            maximumCapsuleCharacters: 4_000,
            maximumThoughtSeeds: 64
        )
    }
}

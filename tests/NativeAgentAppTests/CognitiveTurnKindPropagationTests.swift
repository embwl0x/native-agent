import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Cognitive turn-kind propagation", .serialized)
struct CognitiveTurnKindPropagationTests {
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
        try await Task.sleep(nanoseconds: 600_000_000)
        let substrate = await runtime.substrateForIntegration()
        let baseline = await substrate.receiptSnapshot().filter { $0.kind == "microcycle" }.count

        await runtime.observe(event(
            id: "sensory-change",
            kind: .userMessageReceived,
            summary: "A meaningful event reached the resident mind",
            sessionId: "event-driven",
            runId: "event-driven-run"
        ))
        try await Task.sleep(nanoseconds: 600_000_000)

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
        try await Task.sleep(nanoseconds: 600_000_000)
        let substrate = await runtime.substrateForIntegration()
        let baseline = await substrate.receiptSnapshot().filter { $0.kind == "microcycle" }.count
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
        try await Task.sleep(nanoseconds: 600_000_000)

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
        try await Task.sleep(nanoseconds: 600_000_000)
        await first.observe(event(
            id: "persist-across-relaunch",
            kind: .userMessageReceived,
            summary: "Keep this state through a clean relaunch",
            sessionId: "relaunch",
            runId: "relaunch-run"
        ))
        try await Task.sleep(nanoseconds: 600_000_000)

        let relaunched = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: testCognitionConfiguration(),
            organismConfigurationOverride: .disabled
        )
        await relaunched.bootstrap()
        try await Task.sleep(nanoseconds: 600_000_000)
        let substrate = await relaunched.substrateForIntegration()
        let nodes = await substrate.snapshot().nodes
        #expect(nodes.contains { $0.subjectReference.id == "persist-across-relaunch" })
        #expect(await substrate.receiptSnapshot().contains { $0.kind == "microcycle" })
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

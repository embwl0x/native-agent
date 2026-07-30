import Foundation
import Testing
import BackgroundLoops
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

private struct FailingCognitionLLM: LLMClient {
    enum Failure: Error, LocalizedError {
        case providerUnavailable
        var errorDescription: String? { "provider unavailable" }
    }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        throw Failure.providerUnavailable
    }
}

private struct SuccessfulViewCognitionLLM: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        "I keep returning to verification as a source of trust.\nview: Verified outcomes matter more than confident completion claims."
    }
}

@Suite("Cognition background outcomes", .serialized)
struct CognitionBackgroundOutcomeTests {
    @Test("provider routing corruption closes reflection without poisoning cognition bootstrap")
    func providerRoutingFailureIsLaneScopedAndClearsAfterRepair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CognitionBackground-provider-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"cognition_reflection":{"model":"claude-opus-4-8","reasoningEffort":"high"}}"#.utf8)
            .write(to: providers.appendingPathComponent("surfaces.json"))
        try Data("not-json".utf8)
            .write(to: providers.appendingPathComponent("active.json"))

        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled
        )
        await runtime.bootstrap()
        let substrate = await runtime.substrateForIntegration()
        #expect(await substrate.configurationSnapshot().reflectiveCallsEnabled == false)

        let maintenance = await runtime.runMaintenance(reason: "provider corruption isolation")
        if case .failed(let detail) = maintenance,
           detail.contains("provider state unavailable") {
            Issue.record("provider routing failure leaked into cognition maintenance: \(detail)")
        }

        try Data("{}".utf8)
            .write(to: providers.appendingPathComponent("active.json"), options: .atomic)
        await runtime.refreshConfiguration()
        #expect(await substrate.configurationSnapshot().reflectiveCallsEnabled == true)

        let reflection = await runtime.runReflectionIfDue(
            llm: FailingCognitionLLM(),
            reason: "no evidence after provider repair"
        )
        if case .failed(let detail) = reflection,
           detail.contains("provider state unavailable") {
            Issue.record("successful provider refresh did not clear lane failure: \(detail)")
        }
    }

    @Test("unavailable persistence reaches the maintenance scheduler as failure")
    func maintenancePersistenceFailureIsTyped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CognitionBackground-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled
        )
        let loop: any LoopRunner = BackgroundLoopsAssembly.makeCognitionMaintenanceLoop(
            intervalSeconds: 1,
            runtime: runtime
        )

        let outcome = await loop.tickOutcome()

        guard case .failed(let detail) = outcome else {
            Issue.record("expected maintenance failure, got \(outcome)")
            return
        }
        #expect(detail.contains("restore") || detail.contains("maintenance"))
    }

    @Test("reflection failure cannot ignite a Workshop pursuit")
    func failedReflectionDoesNotProposePursuit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CognitionBackground-reflection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
        try "# Test identity\n\nStay grounded in verified outcomes."
            .write(to: personaRoot.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled
        )
        await runtime.observe(CognitiveEvent(
            id: "reflection-evidence",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "conversation", id: "living-fabric"),
            sourceClass: .userStated,
            occurredAt: Date(),
            summary: "Think carefully about the next architecture step",
            importance: 0.9
        ))
        let first = await runtime.runReflectionIfDue(
            llm: SuccessfulViewCognitionLLM(),
            reason: "form one reviewable standing view"
        )
        guard case .completed = first else {
            Issue.record("could not seed standing view: \(first)")
            return
        }
        let substrate = await runtime.substrateForIntegration()
        let proposed = try #require(await substrate.standingViewSnapshot().first)
        await runtime.resolveStandingView(id: proposed.id, approved: true)
        #expect(await substrate.standingViewSnapshot().contains { $0.status == .active })
        let deskStore = SwiftNativeDeskStore(dataRoot: root)
        let pursuitCountBeforeFailure = try await deskStore.liveState().items.filter {
            $0.origin == .agent && $0.kind == .project && !$0.status.isTerminal
        }.count
        await runtime.observe(CognitiveEvent(
            id: "reflection-evidence-2",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "conversation", id: "living-fabric-2"),
            sourceClass: .userStated,
            occurredAt: Date(),
            summary: "A second reflection now has approved pursuit evidence",
            importance: 0.9
        ))

        let loop: any LoopRunner = BackgroundLoopsAssembly.makeCognitionReflectionLoop(
            llm: FailingCognitionLLM(),
            intervalSeconds: 1,
            runtime: runtime
        )
        let outcome = await loop.tickOutcome()

        guard case .failed = outcome else {
            Issue.record("expected provider/persona reflection failure, got \(outcome)")
            return
        }
        let pursuitCountAfterFailure = try await deskStore.liveState().items.filter {
            $0.origin == .agent && $0.kind == .project && !$0.status.isTerminal
        }.count
        #expect(pursuitCountAfterFailure == pursuitCountBeforeFailure)
    }

    @Test("replay reads the runtime's injected root")
    func replayUsesInjectedRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CognitionBackground-replay-\(UUID().uuidString)", isDirectory: true)
        let diary = root.appendingPathComponent("dream_diary", isDirectory: true)
        try FileManager.default.createDirectory(at: diary, withIntermediateDirectories: true)
        try "A bounded dream from this exact runtime root."
            .write(to: diary.appendingPathComponent("2026-07-12.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled
        )

        let input = await runtime.makeReplayIntegrationInput(reason: "test")

        #expect(input.dreamEntries.count == 1)
        #expect(input.dreamEntries.first?.date == "2026-07-12")
    }
}

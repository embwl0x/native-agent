import Foundation
import Testing
import CognitiveSubstrate
import NativeAgentCore
@testable import NativeAgentApp

private func enabledNativeCognitionConfiguration() -> CognitiveConfiguration {
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

private func makeNativeCognitionRuntimeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "NativeCognitionRuntimeProjection-" + UUID().uuidString,
            isDirectory: true
        )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeNativeCognitionRuntimeFileRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeCognitionRuntimeProjection-" + UUID().uuidString)
    try Data("not a directory".utf8).write(to: root)
    return root
}

private func liveCapsuleRequest(maximumCharacters: Int? = nil) -> CognitiveCapsuleRequest {
    CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "please keep going",
        mode: .inject,
        maximumCharacters: maximumCharacters
    )
}

private func projection(
    from snapshot: OrganismSnapshot,
    bodyLine: String?
) -> OrganismProjection {
    OrganismProjection(
        generatedAt: snapshot.generatedAt,
        bodyLine: bodyLine,
        chemicalState: snapshot.chemicalState,
        bodySchema: snapshot.bodySchema
    )
}

@Suite("NativeCognitionRuntime projection and persistence", .serialized)
struct NativeCognitionRuntimeProjectionPersistenceTests {
    @Test func turnProjectionIsFixedTimeAndPresentationCommitIsDeferred() async throws {
        let root = try makeNativeCognitionRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedAt = Date(timeIntervalSince1970: 9_000)
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: enabledNativeCognitionConfiguration(),
            organismConfigurationOverride: .enabled,
            now: { fixedAt }
        )
        _ = try await runtime.setOrganismDebugBodyOverride(scenario: "provider_brittle")
        let request = liveCapsuleRequest(maximumCharacters: 1_200)

        let projection = await runtime.prepareTurnProjection(request)
        let capsule = try #require(projection.capsule)
        let posture = try #require(projection.posture)

        #expect(projection.fixedAt == fixedAt)
        #expect(capsule.generatedAt == fixedAt)
        #expect(posture.generatedAt == fixedAt)
        #expect(await runtime.lastInjectedCapsuleBridgeSummary().source == "none")

        await runtime.commitTurnProjection(projection, request: request)
        let committed = await runtime.lastInjectedCapsuleBridgeSummary()
        #expect(committed.source == "live_injected")
        #expect(committed.generatedAt == fixedAt)
    }

    @Test func providerLifecycleExpiryAndCancellationRemainUnknownEvidence() async throws {
        let root = try makeNativeCognitionRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: enabledNativeCognitionConfiguration(),
            organismConfigurationOverride: .enabled
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let started = LLMCallLifecycleEvent(
            id: "provider-expiry",
            phase: .started,
            providerId: "fixture",
            model: "fixture-1",
            surface: "chat",
            sessionId: "session",
            turnId: "turn",
            streaming: false,
            occurredAt: startedAt
        )
        await runtime.recordProviderLifecycleEvidence(started)
        await runtime.recordProviderLifecycleEvidence(LLMCallLifecycleEvent(
            id: "provider-cancelled",
            phase: .cancelled,
            providerId: "fixture",
            model: "fixture-1",
            surface: "chat",
            sessionId: "session",
            turnId: "turn",
            streaming: false,
            occurredAt: startedAt.addingTimeInterval(1)
        ))

        let evidence = await runtime.providerPathEvidence(
            at: startedAt.addingTimeInterval(NativeCognitionRuntime.providerLifecycleExpiry + 1)
        )
        #expect(evidence.contains { $0.outcome == .expired })
        #expect(evidence.contains { $0.outcome == .cancelled })
        let belief = ProviderPathBeliefProjector.project(
            evidence: evidence,
            now: startedAt.addingTimeInterval(NativeCognitionRuntime.providerLifecycleExpiry + 1)
        )
        #expect(belief.estimate == 0.5)
        #expect(belief.bodySchemaProvidersHealthy == nil)
    }

    @Test func runtimeFrozenMindReadDoesNotAdvanceOwnerRevisions() async throws {
        let root = try makeNativeCognitionRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: enabledNativeCognitionConfiguration(),
            organismConfigurationOverride: .enabled,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        await runtime.bootstrap()
        let before = await runtime.frozenMindOwnerRevisions()
        _ = try await runtime.frozenMindRead(
            at: Date(timeIntervalSince1970: 2_000 + 24 * 60 * 60),
            surface: "provider_transplant_eval",
            userMessage: "Evaluate without mutating the live mind.",
            sessionId: "frozen-session"
        )
        let after = await runtime.frozenMindOwnerRevisions()

        #expect(after == before)
    }

    @Test func providerLifecycleEvidenceCreatesAndSettlesOneCorrelatedPrediction() async throws {
        let root = try makeNativeCognitionRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: enabledNativeCognitionConfiguration(),
            organismConfigurationOverride: .enabled
        )
        let started = LLMCallLifecycleEvent(
            id: "provider-call-runtime-1",
            phase: .started,
            providerId: "openai_oauth_direct",
            model: "gpt-5.6-sol",
            surface: "chat",
            sessionId: "session-1",
            turnId: "turn-1",
            streaming: true,
            occurredAt: Date(timeIntervalSince1970: 2_000)
        )

        await runtime.observeProviderCall(started)
        let pending = await runtime.organismSnapshot()
        await runtime.observeProviderCall(started.terminal(
            .succeeded,
            at: Date(timeIntervalSince1970: 2_002)
        ))
        let settled = await runtime.organismSnapshot()

        #expect(pending.predictionSummary.pendingCount == 1)
        #expect(settled.predictionSummary.pendingCount == 0)
        #expect(settled.predictionSummary.satisfiedCount == 1)
    }

    @Test func debugBridgeProviderLifecycleUpdatesHealthEvidenceWithoutChangingChemistry() async throws {
        let root = try makeNativeCognitionRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: enabledNativeCognitionConfiguration(),
            organismConfigurationOverride: .enabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        let session = "debug-provider-session"
        await runtime.observeUserMessage(
            surface: "codex_bridge",
            text: "[from: codex, via bridge] Run a diagnostic provider check.",
            sessionId: session,
            messageId: "debug-user"
        )
        #expect(await runtime.debugSessionIds.contains(session))
        let before = await runtime.organismSnapshot()
        let started = LLMCallLifecycleEvent(
            id: "debug-provider-call",
            phase: .started,
            providerId: "openai_oauth_direct",
            model: "gpt-5.6-sol",
            surface: "chat",
            sessionId: session,
            turnId: "debug-turn",
            streaming: true
        )

        await runtime.observeProviderCall(started)
        await runtime.observeProviderCall(started.terminal(.succeeded))
        let after = await runtime.organismSnapshot()

        #expect(after.chemicalState == before.chemicalState)
        #expect(after.predictionSummary == before.predictionSummary)
        let evidence = await runtime.providerPathEvidence(at: Date())
        let expectedEvidenceID = ProviderPathEvidence(
            evidenceID: "provider-call:debug-provider-call",
            observedAt: Date(),
            outcome: .succeeded
        ).evidenceID
        #expect(evidence.contains {
            $0.evidenceID == expectedEvidenceID
                && $0.outcome == .succeeded
        })
    }

    @Test func consecutiveIdenticalBodyLinesSuppressOnlyBodyText() async throws {
        let root = try makeNativeCognitionRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: enabledNativeCognitionConfiguration(),
            organismConfigurationOverride: .enabled
        )
        _ = try await runtime.setOrganismDebugBodyOverride(scenario: "provider_brittle")
        for _ in 0..<4 {
            await runtime.ingestOrganismSignal(
                kind: .providerFailed,
                sourceOrgan: "regression",
                intensity: 1
            )
        }

        let request = liveCapsuleRequest(maximumCharacters: 1_200)
        let first = try #require(await runtime.prepareCapsule(request))
        _ = try #require(NativeCognitionRuntime.bodyLine(inCapsuleDynamicContext: first.dynamicContext))

        let snapshot = await runtime.organismSnapshot()
        #expect(snapshot.chemicalState.vigilance > 0.2)
        let bodylessProjection = projection(from: snapshot, bodyLine: nil)
        let substrate = await runtime.substrateForIntegration()
        let expected = await substrate.compileCapsule(CognitiveCapsuleRequest(
            surface: request.surface,
            userMessage: request.userMessage,
            sessionId: request.sessionId,
            mode: request.mode,
            maximumCharacters: request.maximumCharacters,
            organismProjection: bodylessProjection
        ))
        let withoutProjection = await substrate.compileCapsule(request)
        #expect(expected.dynamicContext != withoutProjection.dynamicContext)

        let second = try #require(await runtime.prepareCapsule(request))

        #expect(NativeCognitionRuntime.bodyLine(inCapsuleDynamicContext: second.dynamicContext) == nil)
        #expect(second.dynamicContext == expected.dynamicContext)
    }

    @Test func budgetOmittedBodyLineDoesNotConsumeDedupWindow() async throws {
        let root = try makeNativeCognitionRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: enabledNativeCognitionConfiguration(),
            organismConfigurationOverride: .enabled
        )
        _ = try await runtime.setOrganismDebugBodyOverride(scenario: "provider_brittle")
        let snapshot = await runtime.organismSnapshot()
        let bodyLine = try #require(snapshot.projectedBodyLine)
        let substrate = await runtime.substrateForIntegration()
        let fullRequest = liveCapsuleRequest(maximumCharacters: 1_200)
        let full = await substrate.compileCapsule(CognitiveCapsuleRequest(
            surface: fullRequest.surface,
            userMessage: fullRequest.userMessage,
            sessionId: fullRequest.sessionId,
            mode: fullRequest.mode,
            maximumCharacters: fullRequest.maximumCharacters,
            organismProjection: projection(from: snapshot, bodyLine: bodyLine)
        ))
        let fittedBodyLine = try #require(
            NativeCognitionRuntime.bodyLine(inCapsuleDynamicContext: full.dynamicContext)
        )
        let tightBudget = full.combined.count - fittedBodyLine.count - 1

        let omitted = try #require(await runtime.prepareCapsule(
            liveCapsuleRequest(maximumCharacters: tightBudget)
        ))
        #expect(NativeCognitionRuntime.bodyLine(inCapsuleDynamicContext: omitted.dynamicContext) == nil)

        let surfaced = try #require(await runtime.prepareCapsule(fullRequest))
        #expect(NativeCognitionRuntime.bodyLine(inCapsuleDynamicContext: surfaced.dynamicContext) == fittedBodyLine)
    }

    @Test func clearRemovesPersistedCognitionBeforeRelaunch() async throws {
        let root = try makeNativeCognitionRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = enabledNativeCognitionConfiguration()
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration,
            organismConfigurationOverride: .disabled
        )
        let substrate = await runtime.substrateForIntegration()
        let seed = try #require(await substrate.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "Keep the durable clear boundary honest.",
            priority: 0.9
        ))
        let populated = await runtime.observatoryDetail()
        #expect(populated.thoughtSeeds.contains(where: { $0.id == seed.id }))

        let outcome = await runtime.clearTransientState()
        #expect(outcome == .cleared)
        let cleared = await runtime.observatoryDetail()
        #expect(cleared.thoughtSeeds.isEmpty)

        let relaunched = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration,
            organismConfigurationOverride: .disabled
        )
        let afterRelaunch = await relaunched.observatoryDetail()
        #expect(afterRelaunch.thoughtSeeds.isEmpty)
    }

    @Test func clearReportsPersistenceFailureWithoutDiscardingLiveState() async throws {
        let root = try makeNativeCognitionRuntimeFileRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: enabledNativeCognitionConfiguration(),
            organismConfigurationOverride: .disabled
        )
        let substrate = await runtime.substrateForIntegration()
        let eventID = "unavailable-store-live-state"
        await substrate.ingest(CognitiveEvent(
            id: eventID,
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "test", id: eventID, label: eventID),
            sourceClass: .userStated,
            occurredAt: Date(),
            summary: "Do not claim a durable clear when storage is unavailable.",
            importance: 0.9
        ))
        #expect(await substrate.snapshot().nodes.contains(where: { $0.subjectReference.id == eventID }))

        let outcome = await runtime.clearTransientState()
        if case .persistenceFailed(let detail) = outcome {
            #expect(!detail.isEmpty)
        } else {
            Issue.record("clear should not report success without a durable cognitive store")
        }
        let retained = await substrate.snapshot()
        #expect(retained.nodes.contains(where: { $0.subjectReference.id == eventID }))
    }
}

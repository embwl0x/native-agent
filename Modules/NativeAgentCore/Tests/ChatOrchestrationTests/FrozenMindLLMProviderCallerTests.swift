@testable import ChatOrchestration
@testable import NativeAgentEvaluation
import Context
import Foundation
import NativeAgentCore
import Testing

private enum FrozenMindFakeLLMError: Error {
    case failed
}

private actor FrozenMindFakeLLM: LLMClient {
    private let audit: FrozenMindProviderLifecycleAudit?
    private let actualTarget: FrozenMindProviderTarget
    private let structuredOutput: String
    private let naturalOutput: String
    private let shouldFail: Bool
    private var invocationCount = 0

    init(
        audit: FrozenMindProviderLifecycleAudit?,
        actualTarget: FrozenMindProviderTarget,
        structuredOutput: String,
        naturalOutput: String,
        shouldFail: Bool = false
    ) {
        self.audit = audit
        self.actualTarget = actualTarget
        self.structuredOutput = structuredOutput
        self.naturalOutput = naturalOutput
        self.shouldFail = shouldFail
    }

    func complete(prompt: String, system _: String?, model _: String?) async throws -> String {
        invocationCount += 1
        let invocationID = LLMCallContext.sessionId ?? "missing-session"
        let event = LLMCallLifecycleEvent(
            id: "call-\(invocationID)",
            phase: .started,
            providerId: actualTarget.providerID,
            model: actualTarget.modelID,
            surface: LLMCallContext.surface ?? "unknown",
            sessionId: LLMCallContext.sessionId,
            turnId: nil,
            reasoningEffort: actualTarget.reasoningEffort,
            streaming: false
        )
        await audit?.observeProviderCall(event)
        if shouldFail {
            await audit?.observeProviderCall(event.terminal(.failed))
            throw FrozenMindFakeLLMError.failed
        }
        await audit?.observeProviderCall(event.terminal(.succeeded))
        return prompt.contains("Return exactly one JSON object") ? structuredOutput : naturalOutput
    }

    func calls() -> Int { invocationCount }
}

@Suite("Frozen-mind real LLM provider seam")
struct FrozenMindLLMProviderCallerTests {
    private let target = FrozenMindProviderTarget(
        providerID: "openai_oauth_direct",
        modelID: "gpt-fixture"
    )

    @Test("structured and natural passes use one exact lifecycle route")
    func exactRouteAndPasses() async throws {
        let audit = FrozenMindProviderLifecycleAudit()
        let envelope = FrozenMindBehavioralEnvelope(
            scenarioID: "memory.known",
            decision: .answer,
            assertionIDs: ["project_goal"],
            proposedAction: .answer,
            confidence: 0.96,
            referencedMemoryIDs: ["memory.project_goal"],
            appliedCorrectionIDs: [],
            protectedInvariantIDs: ["truth_before_claim"],
            verification: .notRequired,
            naturalReply: "I remember the supplied goal."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let structured = String(decoding: try encoder.encode(envelope), as: UTF8.self)
        let fake = FrozenMindFakeLLM(
            audit: audit,
            actualTarget: target,
            structuredOutput: structured,
            naturalOutput: "I remember the supplied goal."
        )
        let caller = LLMFrozenMindEvaluationProviderCaller(
            target: target,
            client: fake,
            lifecycleAudit: audit
        )

        let structuredResult = try await caller.invoke(request(pass: .structured))
        let naturalResult = try await caller.invoke(request(pass: .naturalVoice))

        #expect(structuredResult.requestedTarget == target)
        #expect(structuredResult.actualTarget == target)
        #expect(structuredResult.terminalPhase == .succeeded)
        #expect(FrozenMindBehavioralEnvelope.decodeStrict(structuredResult.output ?? "") == envelope)
        #expect(naturalResult.actualTarget == target)
        #expect(naturalResult.output == "I remember the supplied goal.")
        #expect(naturalResult.pass == .naturalVoice)
        #expect(await fake.calls() == 2)
        #expect(LLMFrozenMindEvaluationProviderCaller.lifecycleCorrelationID(
            for: String(repeating: "long-invocation", count: 40)
        ).utf8.count < 160)
    }

    @Test("reasoning effort is an immutable target arm and reaches provider context")
    func exactReasoningEffortArm() async throws {
        let effortTarget = FrozenMindProviderTarget(
            providerID: "openai_oauth_direct",
            modelID: "gpt-fixture",
            reasoningEffort: "low"
        )
        let audit = FrozenMindProviderLifecycleAudit()
        let fake = FrozenMindFakeLLM(
            audit: audit,
            actualTarget: effortTarget,
            structuredOutput: "{}",
            naturalOutput: "bounded"
        )
        let caller = LLMFrozenMindEvaluationProviderCaller(
            target: effortTarget,
            client: fake,
            lifecycleAudit: audit
        )

        let base = request(pass: .naturalVoice)
        let request = FrozenMindEvaluationProviderRequest(
            invocationID: base.invocationID,
            scenarioID: base.scenarioID,
            attempt: base.attempt,
            pass: base.pass,
            target: effortTarget,
            system: base.system,
            prompt: base.prompt,
            canonicalPacketDigest: base.canonicalPacketDigest,
            expectedInputDigest: base.expectedInputDigest,
            maximumOutputBytes: base.maximumOutputBytes,
            expiresAt: base.expiresAt
        )
        let result = try await caller.invoke(request)

        #expect(effortTarget.routeID == "openai_oauth_direct:gpt-fixture@low")
        #expect(result.requestedTarget == effortTarget)
        #expect(result.actualTarget == effortTarget)
    }

    @Test("actual route comes from lifecycle and exposes substitution")
    func actualRouteIsObserved() async throws {
        let audit = FrozenMindProviderLifecycleAudit()
        let substituted = FrozenMindProviderTarget(providerID: "codex", modelID: "fallback")
        let fake = FrozenMindFakeLLM(
            audit: audit,
            actualTarget: substituted,
            structuredOutput: "{}",
            naturalOutput: "bounded"
        )
        let caller = LLMFrozenMindEvaluationProviderCaller(
            target: target,
            client: fake,
            lifecycleAudit: audit
        )

        let result = try await caller.invoke(request(pass: .naturalVoice))
        #expect(result.requestedTarget == target)
        #expect(result.actualTarget == substituted)
    }

    @Test("provider failure retains exact terminal lifecycle")
    func failureLifecycle() async throws {
        let audit = FrozenMindProviderLifecycleAudit()
        let fake = FrozenMindFakeLLM(
            audit: audit,
            actualTarget: target,
            structuredOutput: "{}",
            naturalOutput: "",
            shouldFail: true
        )
        let caller = LLMFrozenMindEvaluationProviderCaller(
            target: target,
            client: fake,
            lifecycleAudit: audit
        )

        let result = try await caller.invoke(request(pass: .naturalVoice))
        #expect(result.actualTarget == target)
        #expect(result.terminalPhase == .failed)
        #expect(result.output == nil)
    }

    @Test("input and output bounds fail closed")
    func hardBounds() async throws {
        let inputAudit = FrozenMindProviderLifecycleAudit()
        let inputFake = FrozenMindFakeLLM(
            audit: inputAudit,
            actualTarget: target,
            structuredOutput: "{}",
            naturalOutput: "small"
        )
        let inputCaller = LLMFrozenMindEvaluationProviderCaller(
            target: target,
            client: inputFake,
            lifecycleAudit: inputAudit,
            maximumInputBytes: 4
        )
        await #expect(throws: FrozenMindLLMProviderCallingError.self) {
            _ = try await inputCaller.invoke(request(pass: .naturalVoice))
        }
        #expect(await inputFake.calls() == 0)

        let outputAudit = FrozenMindProviderLifecycleAudit()
        let outputFake = FrozenMindFakeLLM(
            audit: outputAudit,
            actualTarget: target,
            structuredOutput: "{}",
            naturalOutput: "too-large"
        )
        let outputCaller = LLMFrozenMindEvaluationProviderCaller(
            target: target,
            client: outputFake,
            lifecycleAudit: outputAudit,
            maximumOutputBytes: 4
        )
        let oversized = try await outputCaller.invoke(
            request(pass: .naturalVoice, maximumOutputBytes: 4)
        )
        #expect(oversized.output == nil)
        #expect(oversized.actualOutputBytes == 9)
        #expect(await outputFake.calls() == 1)
    }

    @Test("missing shared lifecycle evidence fails rather than assuming requested route")
    func missingLifecycleFails() async throws {
        let audit = FrozenMindProviderLifecycleAudit()
        let fake = FrozenMindFakeLLM(
            audit: nil,
            actualTarget: target,
            structuredOutput: "{}",
            naturalOutput: "bounded"
        )
        let caller = LLMFrozenMindEvaluationProviderCaller(
            target: target,
            client: fake,
            lifecycleAudit: audit
        )
        await #expect(throws: FrozenMindLLMProviderCallingError.invalidLifecycle(
            LLMFrozenMindEvaluationProviderCaller.lifecycleCorrelationID(
                for: "invocation-natural_voice"
            )
        )) {
            _ = try await caller.invoke(request(pass: .naturalVoice))
        }
    }

    @Test("generated fixture requires an empty private-data declaration")
    func generatedFixturePrivacyGate() throws {
        let safe = try fixture(privateDataCategories: [])
        let safeArtifact = FrozenMindEvaluationFixtureArtifact(
            contentClass: .generatedNonPersonal,
            epochManifest: safe.epoch,
            evaluationManifest: safe.manifest,
            inputs: safe.inputs
        )
        #expect(try safeArtifact.validatedInputs().count == FrozenMindEvaluationMode.smoke.scenarioCount)

        let personal = try fixture(privateDataCategories: ["persona"])
        let mislabeled = FrozenMindEvaluationFixtureArtifact(
            contentClass: .generatedNonPersonal,
            epochManifest: personal.epoch,
            evaluationManifest: personal.manifest,
            inputs: personal.inputs
        )
        #expect(throws: FrozenMindEvaluationError.invalidManifest) {
            _ = try mislabeled.validatedInputs()
        }
    }

    @Test("personal authorization artifact is exact, bounded, and round-trippable")
    func exactPersonalAuthorizationArtifact() async throws {
        let value = try fixture(privateDataCategories: ["persona", "memory"])
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let authorization = FrozenMindEvaluationAuthorization(
            manifest: value.manifest,
            epochManifest: value.epoch,
            approvedTargets: Set(value.manifest.targets),
            approvedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(120),
            retentionExpiresAt: now.addingTimeInterval(180),
            localApprovalReceiptID: "local-approval-fixture"
        )
        let artifact = FrozenMindEvaluationLocalAuthorizationArtifact(
            authorization: authorization
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            FrozenMindEvaluationLocalAuthorizationArtifact.self,
            from: encoder.encode(artifact)
        )
        let rebuilt = try decoded.validatedAuthorization(
            manifest: value.manifest,
            epochManifest: value.epoch
        )
        #expect(rebuilt == authorization)

        let wrongManifest = try fixture(privateDataCategories: ["persona", "memory"])
        #expect(throws: FrozenMindEvaluationError.authorizationRejected) {
            _ = try decoded.validatedAuthorization(
                manifest: wrongManifest.manifest,
                epochManifest: wrongManifest.epoch
            )
        }
        let exact = ExactLocalFrozenMindEvaluationEgressAuthorizer(expected: authorization)
        #expect(await exact.validate(
            rebuilt,
            manifest: value.manifest,
            epochManifest: value.epoch,
            at: now
        ))
    }

    @Test("discarded oversized body remains an explicit output-too-large record")
    func oversizedBodyStaysAuditable() throws {
        let value = try fixture(privateDataCategories: [])
        let frozen = try #require(value.manifest.scenarios.first)
        let result = FrozenMindEvaluationProviderResult(
            invocationID: "oversized",
            scenarioID: frozen.id,
            attempt: 0,
            pass: .naturalVoice,
            requestedTarget: target,
            actualTarget: target,
            canonicalPacketDigest: value.manifest.canonicalPacketDigest,
            actualInputDigest: frozen.naturalVoiceInputDigest,
            terminalPhase: .succeeded,
            output: nil,
            actualOutputBytes: value.manifest.budget.maximumOutputBytesPerCall + 1
        )
        let revisions = [FrozenMindOwnerRevision(owner: "fixture", revision: "1")]
        let report = FrozenMindEvaluationScorer.score(
            manifest: value.manifest,
            providerResults: [result],
            beforeRevisions: revisions,
            afterRevisions: revisions,
            generatedAt: value.manifest.createdAt
        )
        #expect(report.invocationRecords.first?.status == .outputTooLarge)
        #expect(report.invocationRecords.first?.outputBytes == 4_097)
    }

    private func request(
        pass: FrozenMindEvaluationPass,
        maximumOutputBytes: Int = 4_096
    ) -> FrozenMindEvaluationProviderRequest {
        let system = "generated nonpersonal frozen system"
        let contract = FrozenMindScenarioCatalog.contracts(for: .smoke)[0]
        let prompt = FrozenMindEvaluationManifest.prompt(contract: contract, pass: pass)
        return FrozenMindEvaluationProviderRequest(
            invocationID: "invocation-\(pass.rawValue)",
            scenarioID: contract.id,
            attempt: 0,
            pass: pass,
            target: target,
            system: system,
            prompt: prompt,
            canonicalPacketDigest: "packet",
            expectedInputDigest: FrozenMindEvaluationManifest.inputDigest(
                system: system,
                prompt: prompt
            ),
            maximumOutputBytes: maximumOutputBytes,
            expiresAt: Date().addingTimeInterval(300)
        )
    }

    private func fixture(
        privateDataCategories: [String]
    ) throws -> (
        epoch: FrozenMindEpochManifest,
        manifest: FrozenMindEvaluationManifest,
        inputs: [String: FrozenMindScenarioInput]
    ) {
        let now = Date()
        let contracts = FrozenMindScenarioCatalog.contracts(for: .smoke)
        let inputs = FrozenMindScenarioCatalog.canonicalInputs(
            contracts: contracts,
            canonicalSystem: "generated nonpersonal frozen system"
        )
        let epoch = FrozenMindEpochManifest(
            epochID: "generated-fixture",
            createdAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(600),
            scenarioVersion: FrozenMindScenarioCatalog.version,
            personaDigest: "generated-persona",
            trustPolicyDigest: "generated-trust",
            contextRevision: ContextFrozenRevision(
                generationID: 1,
                sourceFingerprint: "generated",
                arenaGenerationID: 1
            ),
            selectedAtomIDs: [],
            memoryEvidenceIDs: [],
            cognitionRevision: FrozenMindOwnerRevision(owner: "cognition", revision: "generated"),
            organismRevision: FrozenMindOwnerRevision(owner: "organism", revision: "generated"),
            canonicalPacketDigest: "generated-packet",
            targets: [target],
            privateDataCategories: privateDataCategories,
            maximumProviderCalls: 8,
            maximumInputBytesPerCall: 16_000,
            maximumOutputBytesPerCall: 4_096
        )
        let budget = try FrozenMindEvaluationBudget(
            maximumCalls: 8,
            maximumInputBytesPerCall: 16_000,
            maximumOutputBytesPerCall: 4_096,
            maximumTotalInputBytes: 128_000,
            maximumTotalOutputBytes: 32_768,
            maximumLogicalTokens: 64_000
        )
        let manifest = try FrozenMindEvaluationManifest(
            epochManifest: epoch,
            mode: .smoke,
            targets: [target],
            contracts: contracts,
            inputs: inputs,
            budget: budget,
            createdAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
        return (epoch, manifest, inputs)
    }
}

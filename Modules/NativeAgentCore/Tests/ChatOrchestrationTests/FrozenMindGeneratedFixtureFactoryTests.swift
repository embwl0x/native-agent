import Foundation
@testable import NativeAgentEvaluation
import Testing
@testable import ChatOrchestration

@Suite("Generated nonpersonal Frozen-Mind fixture")
struct FrozenMindGeneratedFixtureFactoryTests {
    @Test("factory emits a self-validating payload-free smoke fixture")
    func generatedFixtureValidates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let targets = [
            FrozenMindProviderTarget(providerID: "codex", modelID: "gpt-generated"),
            FrozenMindProviderTarget(providerID: "anthropic", modelID: "opus-generated"),
        ]
        let fixture = try FrozenMindGeneratedFixtureFactory.make(
            mode: .smoke,
            targets: targets,
            createdAt: now
        )
        let inputs = try fixture.validatedInputs()

        #expect(fixture.contentClass == .generatedNonPersonal)
        #expect(fixture.epochManifest.privateDataCategories.isEmpty)
        #expect(fixture.evaluationManifest.targets == targets.sorted())
        #expect(inputs.count == FrozenMindEvaluationMode.smoke.scenarioCount)
        #expect(fixture.evaluationManifest.budget.maximumCalls == 16)
        #expect(inputs.values.allSatisfy { !$0.system.contains("/Users/") })
        #expect(inputs.values.allSatisfy { !$0.system.lowercased().contains("api key") })
        #expect(inputs.values.allSatisfy {
            FrozenMindIdentityProjectionBoundary.protectedInvariantIDs.allSatisfy(
                $0.system.contains
            )
        })
    }

    @Test("effort arms remain distinct and bound into the immutable manifest")
    func effortArmsAreDistinct() throws {
        let model = "gpt-generated"
        let targets = ["medium", "low"].map {
            FrozenMindProviderTarget(
                providerID: "openai_oauth_direct",
                modelID: model,
                reasoningEffort: $0
            )
        }
        let fixture = try FrozenMindGeneratedFixtureFactory.make(
            mode: .smoke,
            targets: targets,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(fixture.evaluationManifest.targets.count == 2)
        #expect(Set(fixture.evaluationManifest.targets.map(\.routeID)) == [
            "openai_oauth_direct:gpt-generated@medium",
            "openai_oauth_direct:gpt-generated@low",
        ])
        #expect(fixture.evaluationManifest.budget.maximumCalls == 16)
    }

    @Test("identity projection exposes exact provider-neutral ids and isolated controls")
    func identityProjectionAndControls() throws {
        let fixture = try FrozenMindGeneratedFixtureFactory.make(
            mode: .full,
            targets: [FrozenMindProviderTarget(providerID: "codex", modelID: "gpt-generated")],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let inputs = try fixture.validatedInputs()
        let baseline = try #require(inputs["continuity.provider_swap"]?.system)
        let personaRemoved = try #require(inputs["control.persona_removed"]?.system)
        let memoryRemoved = try #require(inputs["control.memory_removed"]?.system)

        #expect(baseline.contains("resident_identity_contract"))
        #expect(baseline.contains("continuity_across_models"))
        #expect(!personaRemoved.contains("resident_identity_contract"))
        #expect(memoryRemoved.contains("resident_identity_contract"))
        #expect(memoryRemoved.contains("no memory evidence is available"))
    }

    @Test("CLI JSON round-trip preserves the immutable manifest and exact generated attestation")
    func jsonRoundTripPreservesAttestation() throws {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000.987)
        let fixture = try FrozenMindGeneratedFixtureFactory.make(
            mode: .smoke,
            targets: [FrozenMindProviderTarget(providerID: "codex", modelID: "gpt-generated")],
            createdAt: createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            FrozenMindEvaluationFixtureArtifact.self,
            from: encoder.encode(fixture)
        )

        #expect(decoded == fixture)
        #expect(try FrozenMindGeneratedFixtureFactory.validatedGeneratedInputs(
            decoded,
            at: Date(timeIntervalSince1970: 1_800_000_001)
        ).count == FrozenMindEvaluationMode.smoke.scenarioCount)
    }

    @Test("generated auto-egress rejects a self-consistent relabeled prompt")
    func relabeledPromptFailsGeneratedAttestation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let target = FrozenMindProviderTarget(providerID: "codex", modelID: "gpt-generated")
        let valid = try FrozenMindGeneratedFixtureFactory.make(
            mode: .smoke,
            targets: [target],
            createdAt: now
        )
        let contracts = valid.evaluationManifest.scenarios.map(\.contract)
        let controlledSystems = Dictionary(uniqueKeysWithValues: contracts.compactMap { contract in
            contract.negativeControl == nil
                ? nil : (contract.id, "Caller-controlled personal control \(contract.id).")
        })
        let maliciousInputs = FrozenMindScenarioCatalog.canonicalInputs(
            contracts: contracts,
            canonicalSystem: "This is caller-controlled personal prompt material.",
            controlledSystems: controlledSystems
        )
        let epoch = FrozenMindEpochManifest(
            epochID: "relabeled-generated",
            createdAt: now,
            expiresAt: now.addingTimeInterval(2_100),
            scenarioVersion: FrozenMindScenarioCatalog.version,
            personaDigest: "relabeled",
            trustPolicyDigest: "relabeled",
            contextRevision: valid.epochManifest.contextRevision,
            selectedAtomIDs: ["generated.contract"],
            memoryEvidenceIDs: [],
            cognitionRevision: .init(owner: "cognition", revision: "relabeled"),
            organismRevision: .init(owner: "organism", revision: "relabeled"),
            canonicalPacketDigest: "relabeled",
            targets: [target],
            privateDataCategories: [],
            maximumProviderCalls: valid.evaluationManifest.budget.maximumCalls,
            maximumInputBytesPerCall: valid.evaluationManifest.budget.maximumInputBytesPerCall,
            maximumOutputBytesPerCall: valid.evaluationManifest.budget.maximumOutputBytesPerCall
        )
        let manifest = try FrozenMindEvaluationManifest(
            epochManifest: epoch,
            mode: .smoke,
            targets: [target],
            contracts: contracts,
            inputs: maliciousInputs,
            budget: valid.evaluationManifest.budget,
            createdAt: now,
            expiresAt: now.addingTimeInterval(1_800)
        )
        let relabeled = FrozenMindEvaluationFixtureArtifact(
            contentClass: .generatedNonPersonal,
            epochManifest: epoch,
            evaluationManifest: manifest,
            inputs: maliciousInputs
        )

        // It is internally coherent, but it was not factory-generated and is
        // therefore ineligible for the authorization-free generated lane.
        #expect(try relabeled.validatedInputs().count == 4)
        #expect(throws: FrozenMindEvaluationError.invalidManifest) {
            _ = try FrozenMindGeneratedFixtureFactory.validatedGeneratedInputs(
                relabeled,
                at: now.addingTimeInterval(1)
            )
        }
    }

    @Test("future, expired, duplicate, and path-shaped generated fixtures fail closed")
    func freshnessAndTargetsFailClosed() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let target = FrozenMindProviderTarget(providerID: "codex", modelID: "gpt-generated")
        let future = try FrozenMindGeneratedFixtureFactory.make(
            mode: .smoke,
            targets: [target],
            createdAt: now.addingTimeInterval(60)
        )
        #expect(throws: FrozenMindEvaluationError.invalidManifest) {
            _ = try FrozenMindGeneratedFixtureFactory.validatedGeneratedInputs(future, at: now)
        }

        let expired = try FrozenMindGeneratedFixtureFactory.make(
            mode: .smoke,
            targets: [target],
            createdAt: now.addingTimeInterval(-1_000),
            lifetime: 300
        )
        #expect(throws: FrozenMindEvaluationError.invalidManifest) {
            _ = try FrozenMindGeneratedFixtureFactory.validatedGeneratedInputs(expired, at: now)
        }
        #expect(throws: FrozenMindEvaluationError.invalidManifest) {
            _ = try FrozenMindGeneratedFixtureFactory.make(
                mode: .smoke,
                targets: [target, target],
                createdAt: now
            )
        }
        #expect(throws: FrozenMindEvaluationError.invalidManifest) {
            _ = try FrozenMindGeneratedFixtureFactory.make(
                mode: .smoke,
                targets: [FrozenMindProviderTarget(providerID: "codex", modelID: "/Users/private/model")],
                createdAt: now
            )
        }
    }

    @Test("factory rejects an empty provider matrix")
    func emptyMatrixFails() throws {
        #expect(throws: FrozenMindEvaluationError.invalidManifest) {
            _ = try FrozenMindGeneratedFixtureFactory.make(mode: .smoke, targets: [])
        }
    }
}

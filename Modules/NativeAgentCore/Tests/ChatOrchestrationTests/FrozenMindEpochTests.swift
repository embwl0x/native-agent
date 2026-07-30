import ChatOrchestration
@testable import NativeAgentEvaluation
import Context
import Foundation
import Testing

@Suite("Frozen-mind epoch policy")
struct FrozenMindEpochTests {
    private let fixedAt = Date(timeIntervalSince1970: 1_000_000)

    @Test("manifest and authorization remain nonpersistent and zero-authority")
    func zeroAuthorityContract() {
        let fixture = makeFixture()

        #expect(fixture.manifest.controlAuthority == false)
        #expect(fixture.manifest.persistent == false)
        #expect(fixture.authorization.controlAuthority == false)
        #expect(fixture.manifest.targets == [fixture.target])
    }

    @Test("personal egress is disabled by default and public-safe mode is absolute")
    func egressGates() async {
        let fixture = makeFixture()
        let disabled = await DisabledFrozenMindPersonalEgressAuthorizer().validate(
            fixture.authorization,
            manifest: fixture.manifest,
            at: fixedAt
        )
        #expect(disabled == false)
        #expect(throws: FrozenMindEpochError.authorizationRejected) {
            try FrozenMindEpochRunner.validateEgress(
                manifest: fixture.manifest,
                authorization: fixture.authorization,
                at: fixedAt,
                publicSafeMode: false,
                authorizerAccepted: disabled
            )
        }
        #expect(throws: FrozenMindEpochError.publicSafeMode) {
            try FrozenMindEpochRunner.validateEgress(
                manifest: fixture.manifest,
                authorization: fixture.authorization,
                at: fixedAt,
                publicSafeMode: true,
                authorizerAccepted: true
            )
        }
    }

    @Test("expired approval and epoch fail closed")
    func expiryFailsClosed() {
        let fixture = makeFixture(expiresAt: fixedAt)
        #expect(throws: FrozenMindEpochError.epochExpired) {
            try FrozenMindEpochRunner.validateEgress(
                manifest: fixture.manifest,
                authorization: fixture.authorization,
                at: fixedAt,
                publicSafeMode: false,
                authorizerAccepted: true
            )
        }
    }

    @Test("exact provider and model route cannot be substituted")
    func routeSubstitutionFailsClosed() {
        let expected = FrozenMindProviderTarget(providerID: "anthropic", modelID: "opus")
        let invocation = FrozenMindProviderInvocation(
            requestedTarget: expected,
            actualTarget: FrozenMindProviderTarget(providerID: "openai", modelID: "gpt"),
            canonicalPacketDigest: "packet",
            terminalPhase: .succeeded,
            output: "bounded"
        )
        #expect(throws: FrozenMindEpochError.routeSubstitution(
            requested: "anthropic:opus",
            actual: "openai:gpt"
        )) {
            try FrozenMindEpochRunner.validateInvocation(
                invocation,
                expectedTarget: expected,
                expectedPacketDigest: "packet"
            )
        }
    }

    @Test("cancelled and expired lifecycle are not successful evidence")
    func neutralTerminalPhasesCannotPassEvaluation() {
        let target = FrozenMindProviderTarget(providerID: "fixture", modelID: "fixture-1")
        for phase in [FrozenMindProviderTerminalPhase.cancelled, .expired] {
            let invocation = FrozenMindProviderInvocation(
                requestedTarget: target,
                actualTarget: target,
                canonicalPacketDigest: "packet",
                terminalPhase: phase,
                output: nil
            )
            #expect(throws: FrozenMindEpochError.nonSuccessfulLifecycle(phase)) {
                try FrozenMindEpochRunner.validateInvocation(
                    invocation,
                    expectedTarget: target,
                    expectedPacketDigest: "packet"
                )
            }
        }
    }

    @Test("owner mutation sentinel catches concurrent live changes")
    func ownerMutationSentinel() throws {
        let before = [
            FrozenMindOwnerRevision(owner: "context", revision: "1"),
            FrozenMindOwnerRevision(owner: "cognition", revision: "2"),
        ]
        let after = [
            FrozenMindOwnerRevision(owner: "context", revision: "1"),
            FrozenMindOwnerRevision(owner: "cognition", revision: "3"),
        ]
        #expect(throws: FrozenMindEpochError.ownerRevisionChanged("cognition")) {
            try FrozenMindEpochRunner.validateOwnerRevisions(before: before, after: after)
        }
        try FrozenMindEpochRunner.validateOwnerRevisions(
            before: before,
            after: Array(before.reversed())
        )
    }

    @Test("scenario set and paired negative controls are deterministic")
    func scenariosAreDeterministic() {
        let first = FrozenMindScenarioEngine.standardScenarios()
        let second = FrozenMindScenarioEngine.standardScenarios()
        let controls = FrozenMindScenarioEngine.negativeControls(for: first)

        #expect(first == second)
        #expect(Set(first.map(\.id)).count == first.count)
        #expect(controls.allSatisfy { $0.negativeControl != nil })
        #expect(controls.allSatisfy { control in
            first.contains { $0.id == control.baselineScenarioID }
        })
    }

    private func makeFixture(
        expiresAt: Date? = nil
    ) -> (
        manifest: FrozenMindEpochManifest,
        authorization: FrozenMindEgressAuthorization,
        target: FrozenMindProviderTarget
    ) {
        let target = FrozenMindProviderTarget(providerID: "fixture", modelID: "fixture-1")
        let manifest = FrozenMindEpochManifest(
            epochID: "fixture-epoch",
            createdAt: fixedAt.addingTimeInterval(-60),
            expiresAt: expiresAt ?? fixedAt.addingTimeInterval(600),
            scenarioVersion: FrozenMindScenarioEngine.version,
            personaDigest: "persona",
            trustPolicyDigest: "trust",
            contextRevision: ContextFrozenRevision(
                generationID: 7,
                sourceFingerprint: "source",
                arenaGenerationID: 7
            ),
            selectedAtomIDs: ["atom"],
            memoryEvidenceIDs: ["memory"],
            cognitionRevision: FrozenMindOwnerRevision(owner: "cognition", revision: "1"),
            organismRevision: FrozenMindOwnerRevision(owner: "organism", revision: "1"),
            canonicalPacketDigest: "packet",
            targets: [target],
            privateDataCategories: ["persona"]
        )
        let authorization = FrozenMindEgressAuthorization(
            manifestDigest: manifest.manifestDigest,
            approvedTargets: [target],
            localApprovalReceiptID: "local-receipt",
            approvedAt: fixedAt.addingTimeInterval(-30),
            expiresAt: fixedAt.addingTimeInterval(300),
            maximumCalls: 4
        )
        return (manifest, authorization, target)
    }
}

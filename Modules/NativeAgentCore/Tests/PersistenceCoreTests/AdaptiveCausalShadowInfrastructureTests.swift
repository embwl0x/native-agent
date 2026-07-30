import CryptoKit
@testable import NativeAgentEvaluation
import Foundation
import Testing
@testable import PersistenceCore

@Suite("Adaptive causal shadow infrastructure")
struct AdaptiveCausalShadowInfrastructureTests {
    private func transition(
        domain: String,
        item: String,
        day: Int,
        kind: String = "observed",
        after: String,
        outcome: String = "state_changed",
        index: Int = 0
    ) -> CausalTransitionEvidence {
        CausalTransitionEvidence(
            domain: domain,
            operationId: CausalTransitionEvidence.opaqueIdentity("\(item)-\(day)-\(index)"),
            occurredAt: String(format: "2026-06-%02dT12:00:00Z", day),
            itemIdentity: CausalTransitionEvidence.opaqueIdentity(item),
            kind: kind,
            beforeState: nil,
            afterState: after,
            expectedNextEvidence: nil,
            outcome: outcome
        )
    }

    @Test("terminal classifier labels whole trajectories only from proven outcomes")
    func terminalClassification() {
        let github = [
            transition(domain: "github_command", item: "gh", day: 1, after: "needs_codex", index: 1),
            transition(domain: "github_command", item: "gh", day: 2, after: "resolved", index: 2),
        ]
        let unverifiedWorkshop = [
            transition(domain: "workshop_execution", item: "wu", day: 2, after: "running", index: 1),
            transition(domain: "workshop_execution", item: "wu", day: 3, after: "completed", index: 2),
        ]
        let failedWorkshop = [
            transition(domain: "workshop_execution", item: "wf", day: 3, after: "running", index: 1),
            transition(domain: "workshop_execution", item: "wf", day: 4, after: "failed", index: 2),
        ]
        let rows = github + unverifiedWorkshop + failedWorkshop
        let report = CausalTerminalOutcomeClassifier.classify(transitions: rows)
        #expect(report.transitionCount == 6)
        #expect(report.outcomeCompleteTransitionCount == 4)
        #expect(report.terminalTrajectoryCount == 2)
        #expect(report.incompleteTrajectoryCount == 1)
        #expect(report.terminalKindCounts[.verifiedSuccess] == 1)
        #expect(report.terminalKindCounts[.verifiedFailure] == 1)

        let verified = AuthoritativeTerminalOutcomeEvidence(
            domain: "workshop_execution",
            itemIdentity: CausalTransitionEvidence.opaqueIdentity("wu"),
            occurredAt: "2026-06-03T12:00:00Z",
            kind: .verifiedSuccess
        )
        let withOverride = CausalTerminalOutcomeClassifier.classify(
            transitions: rows,
            authoritative: [verified]
        )
        #expect(withOverride.outcomeCompleteTransitionCount == 6)
        #expect(withOverride.incompleteTrajectoryCount == 0)

        let staleOverride = AuthoritativeTerminalOutcomeEvidence(
            domain: "workshop_execution",
            itemIdentity: CausalTransitionEvidence.opaqueIdentity("wu"),
            occurredAt: "2026-06-01T12:00:00Z",
            kind: .verifiedSuccess
        )
        let stale = CausalTerminalOutcomeClassifier.classify(
            transitions: rows,
            authoritative: [staleOverride]
        )
        #expect(stale.outcomeCompleteTransitionCount == 4)

        let malformedOverride = AuthoritativeTerminalOutcomeEvidence(
            domain: "workshop_execution",
            itemIdentity: CausalTransitionEvidence.opaqueIdentity("wu"),
            occurredAt: "not-a-timestamp",
            kind: .verifiedSuccess
        )
        let malformed = CausalTerminalOutcomeClassifier.classify(
            transitions: rows,
            authoritative: [malformedOverride]
        )
        #expect(malformed.outcomeCompleteTransitionCount == 4)
    }

    @Test("time holdout is deterministic and independent of wall clock")
    func deterministicHoldout() {
        let rows = (1...28).map {
            transition(domain: "github_command", item: "i\($0)", day: $0, after: "resolved")
        }
        let first = AdaptiveCausalTimeHoldoutPolicy.split(rows, days: 7)
        let second = AdaptiveCausalTimeHoldoutPolicy.split(rows.reversed(), days: 7)
        #expect(first.ready)
        #expect(first.elapsedHoldoutDays == 7)
        #expect(first.training.count == 21)
        #expect(first.holdout.count == 7)
        #expect(first.cutoffAt == second.cutoffAt)
        #expect(first.training.map(\.operationId) == second.training.map(\.operationId))
        #expect(first.holdout.map(\.operationId) == second.holdout.map(\.operationId))
    }

    @Test("drift evaluator detects categorical shifts and sample insufficiency")
    func driftEvaluation() {
        let stableTrain = (0..<40).map {
            transition(domain: "github_command", item: "t\($0)", day: 1, kind: "observed", after: "resolved", index: $0)
        }
        let stableHoldout = (0..<40).map {
            transition(domain: "github_command", item: "h\($0)", day: 2, kind: "observed", after: "resolved", index: $0)
        }
        let stable = AdaptiveCausalDriftEvaluator.evaluate(training: stableTrain, holdout: stableHoldout)
        #expect(stable.status == .withinLimit)
        #expect(stable.jensenShannonDivergence == 0)

        let shiftedHoldout = (0..<40).map {
            transition(domain: "workshop_execution", item: "s\($0)", day: 2, kind: "failed", after: "failed", index: $0)
        }
        let shifted = AdaptiveCausalDriftEvaluator.evaluate(training: stableTrain, holdout: shiftedHoldout)
        #expect(shifted.status == .shifted)
        #expect(shifted.jensenShannonDivergence == 1)

        let insufficient = AdaptiveCausalDriftEvaluator.evaluate(training: [], holdout: stableHoldout)
        #expect(insufficient.status == .insufficientSamples)
        #expect(insufficient.jensenShannonDivergence == nil)
    }

    @Test("privacy review loader rejects mutation and never grants control")
    func privacyArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("privacy-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("privacy.json")
        let draft = AdaptiveCausalPrivacyReviewArtifact(
            classificationVersion: "privacy.v1",
            transitionSchemaVersion: "causal-transition-evidence.v1",
            decision: .approvedForShadowEvaluation,
            reviewedAt: "2026-07-12T12:00:00Z",
            reviewedDomains: ["github_command", "workshop_execution"],
            artifactDigestSHA256: ""
        )
        let sealed = try draft.sealed()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sealed).write(to: url)

        let loaded = try AdaptiveCausalPrivacyReviewLoader.load(
            from: url,
            requiredDomains: ["github_command"],
            transitionSchemaVersion: "causal-transition-evidence.v1"
        )
        #expect(loaded.classificationVersion == "privacy.v1")
        #expect(!loaded.controlAuthority)

        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["controlAuthority"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: AdaptiveCausalArtifactError.self) {
            _ = try AdaptiveCausalPrivacyReviewLoader.load(
                from: url,
                requiredDomains: ["github_command"],
                transitionSchemaVersion: "causal-transition-evidence.v1"
            )
        }
    }

    @Test("rollback manifest binds exact model bytes and shadow-only action")
    func rollbackManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollback-review-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let modelBytes = Data("shadow model fixture".utf8)
        let modelHash = SHA256.hash(data: modelBytes).map { String(format: "%02x", $0) }.joined()
        try modelBytes.write(to: models.appendingPathComponent("model-v1.bin"))
        let manifest = try AdaptiveCausalRollbackManifest(
            modelVersion: "model-v1",
            modelArtifactSHA256: modelHash,
            deterministicBaselineVersion: "swift-baseline.v1",
            createdAt: "2026-07-12T12:00:00Z",
            manifestDigestSHA256: ""
        ).sealed()
        let url = root.appendingPathComponent("rollback-manifest.json")
        try JSONEncoder().encode(manifest).write(to: url)

        let loaded = try AdaptiveCausalRollbackManifestLoader.load(
            from: url,
            modelArtifactDirectory: models
        )
        #expect(loaded.activationScope == "shadow_only")
        #expect(!loaded.controlAuthority)

        try Data("mutated model".utf8).write(to: models.appendingPathComponent("model-v1.bin"))
        #expect(throws: AdaptiveCausalArtifactError.self) {
            _ = try AdaptiveCausalRollbackManifestLoader.load(
                from: url,
                modelArtifactDirectory: models
            )
        }

        let external = root.appendingPathComponent("external-model.bin")
        try modelBytes.write(to: external)
        try FileManager.default.removeItem(at: models.appendingPathComponent("model-v1.bin"))
        try FileManager.default.createSymbolicLink(
            at: models.appendingPathComponent("model-v1.bin"),
            withDestinationURL: external
        )
        #expect(throws: AdaptiveCausalArtifactError.self) {
            _ = try AdaptiveCausalRollbackManifestLoader.load(
                from: url,
                modelArtifactDirectory: models
            )
        }

        let traversal = try AdaptiveCausalRollbackManifest(
            modelVersion: "../escape",
            modelArtifactSHA256: modelHash,
            deterministicBaselineVersion: "swift-baseline.v1",
            createdAt: "2026-07-12T12:00:00Z",
            manifestDigestSHA256: ""
        ).sealed()
        try JSONEncoder().encode(traversal).write(to: url)
        #expect(throws: AdaptiveCausalArtifactError.self) {
            _ = try AdaptiveCausalRollbackManifestLoader.load(
                from: url,
                modelArtifactDirectory: models
            )
        }
    }
}

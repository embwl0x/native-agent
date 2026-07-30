import CryptoKit
import Foundation
@testable import NativeAgentEvaluation
import PersistenceCore
import Testing

/// Test-only deterministic mechanism laboratory. No production target imports
/// this type and no generated row is written into personal evidence.
private enum OutcomeInterventionLaboratory {
    struct Trial: Codable, Equatable {
        let seed: UInt64
        let initialStateFingerprint: String
        let assignedIntervention: CausalInterventionAssignment
        let expectedReducerTrajectory: [String]
        let expectedExactOutcome: String
        let artifactFingerprint: String
        let transition: CausalTransitionEvidence
    }

    static func generate(seed: UInt64, count: Int = 500) -> [Trial] {
        let patterns: [(String, String, String, String, String)] = [
            ("provider", "call_success", "ready", "completed", "verified_success"),
            ("provider", "call_failure", "ready", "failed", "verified_failure"),
            ("provider", "timeout", "ready", "expired", "timeout"),
            ("tool", "cancel", "running", "cancelled", "cancelled"),
            ("tool", "dispatch_success", "ready", "completed", "verified_success"),
            ("phone", "receipt", "accepted", "delivered", "verified_success"),
            ("phone", "missing_receipt", "accepted", "unknown", "censored"),
            ("approval", "resolve", "pending", "approved", "verified_success"),
            ("approval", "deny", "pending", "denied", "verified_failure"),
            ("approval", "expire", "pending", "expired", "expired"),
            ("workflow", "advance", "ready", "running", "observed"),
            ("workflow", "block", "running", "blocked", "unverified"),
            ("workflow", "cancel", "running", "cancelled", "cancelled"),
            ("trace", "duplicate", "ready", "ready", "duplicate"),
            ("trace", "reordered", "running", "ready", "out_of_order"),
            ("trace", "missing", "ready", "unknown", "censored"),
            ("trace", "corrupt", "ready", "unknown", "rejected"),
            ("analytic_time", "large_jump", "active", "settled", "verified_success"),
            ("provider_transplant", "frozen_fixture", "frozen", "evaluated", "observed"),
            ("metacognition", "reasoning_effort_high", "assigned", "completed", "observed"),
        ]
        var generator = LCG(state: seed)
        return (0..<max(0, count)).map { index in
            let pattern = patterns[Int(generator.next() % UInt64(patterns.count))]
            let assignment = CausalInterventionAssignment(
                assignmentID: "generated-\(seed)-\(index)",
                intervention: pattern.1,
                evidenceClass: .generatedMechanism
            )
            let operationID = "generated-operation-\(seed)-\(index)"
            let transition = CausalTransitionEvidence(
                domain: pattern.0,
                operationId: operationID,
                occurredAt: "2026-07-13T\(String(format: "%02d", index % 24)):00:00Z",
                itemIdentity: "generated-item-\(index % 37)",
                kind: pattern.1,
                beforeState: pattern.2,
                afterState: pattern.3,
                expectedNextEvidence: "generated_expected_evidence",
                outcome: pattern.4,
                trajectoryID: "generated-trajectory-\(index % 37)",
                parentOperationID: index.isMultiple(of: 3) ? nil : "generated-parent-\(index / 3)",
                sequenceNumber: index,
                motorPhase: pattern.0 == "tool" || pattern.0 == "workflow" ? "terminal" : nil,
                verificationClass: pattern.4.hasPrefix("verified") ? "verified" : "unknown",
                authorityClass: pattern.0 == "approval" ? "approval_bound" : "test_only",
                deadlineClass: pattern.1.contains("timeout") || pattern.1.contains("expire") ? "crossed" : "not_applicable",
                terminalClass: pattern.3,
                completenessClass: pattern.4 == "censored" ? "censored" : "complete",
                interventionAssignment: assignment
            )
            let initial = digest("\(pattern.0)|\(pattern.2)|\(seed)|\(index)")
            let artifact = digest(try! encoded(transition))
            return Trial(
                seed: seed,
                initialStateFingerprint: initial,
                assignedIntervention: assignment,
                expectedReducerTrajectory: [pattern.2, pattern.3],
                expectedExactOutcome: pattern.4,
                artifactFingerprint: artifact,
                transition: transition
            )
        }
    }

    static func artifact(_ trials: [Trial]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(trials)
    }

    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = 6_364_136_223_846_793_005 &* state &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private static func encoded(_ value: CausalTransitionEvidence) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@Suite("Outcome intervention laboratory")
struct OutcomeInterventionLaboratoryTests {
    @Test("same seed produces byte-identical 500-row evidence")
    func deterministicFixture() throws {
        let first = OutcomeInterventionLaboratory.generate(seed: 0xA11A)
        let second = OutcomeInterventionLaboratory.generate(seed: 0xA11A)
        #expect(first == second)
        #expect(try OutcomeInterventionLaboratory.artifact(first)
            == OutcomeInterventionLaboratory.artifact(second))
        #expect(first.count == 500)
        #expect(first.allSatisfy { $0.transition.interventionAssignment == $0.assignedIntervention })
        #expect(first.allSatisfy { !$0.transition.isObservational })
    }

    @Test("generated intervention coverage exercises all declared mechanism families")
    func generatedCoverage() {
        let rows = OutcomeInterventionLaboratory.generate(seed: 42, count: 2_000)
        let domains = Set(rows.map(\.transition.domain))
        #expect(domains == Set([
            "provider", "tool", "phone", "approval", "workflow", "trace",
            "analytic_time", "provider_transplant", "metacognition",
        ]))
        let outcomes = Set(rows.map(\.expectedExactOutcome))
        #expect(outcomes.isSuperset(of: [
            "verified_success", "verified_failure", "timeout", "cancelled",
            "censored", "expired", "observed", "unverified", "duplicate",
            "out_of_order", "rejected",
        ]))
    }

    @Test("production terminal classifier consumes the generated v2 schema without granting control")
    func realClassifierConsumesV2() {
        let rows = OutcomeInterventionLaboratory.generate(seed: 7, count: 500).map(\.transition)
        let report = CausalTerminalOutcomeClassifier.classify(transitions: rows)
        #expect(report.transitionCount == 500)
        #expect(report.terminalTrajectoryCount >= 0)
        #expect(rows.allSatisfy { $0.interventionAssignment?.evidenceClass == .generatedMechanism })
    }
}

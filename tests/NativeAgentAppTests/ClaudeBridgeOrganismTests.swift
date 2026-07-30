import CognitiveSubstrate
import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Claude bridge organism projection")
struct ClaudeBridgeOrganismTests {
    @Test("bridge exposes process-local microcycle proof without control authority")
    func microcycleTelemetryProjection() throws {
        var telemetry = CognitiveMicrocycleTelemetry.fresh(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        telemetry.scheduledSignalCount = 12
        telemetry.coalescedReplacementCount = 11
        telemetry.executedCount = 1
        telemetry.completedCount = 1
        telemetry.lastOutcome = "completed"
        telemetry.lastDurationMilliseconds = 7

        let json = ClaudeBridge.microcycleTelemetryJSON(telemetry)
        #expect(json["schema"] as? String == "cognition.microcycle.telemetry.v1")
        #expect(json["runtimeInstanceId"] as? String == telemetry.runtimeInstanceId)
        #expect(json["processIdentifier"] as? Int == Int(telemetry.processIdentifier))
        #expect(json["scheduledSignals"] as? UInt64 == 12)
        #expect(json["coalescedReplacements"] as? UInt64 == 11)
        #expect(json["executed"] as? UInt64 == 1)
        #expect(json["completed"] as? UInt64 == 1)
        #expect(json["failed"] as? UInt64 == 0)
        #expect(json["controlAuthority"] as? Bool == false)
    }

    @Test("bridge exposes authoritative reflex totals beside bounded samples")
    func authoritativeReflexTotals() throws {
        let posture = OrganismBehaviorPosture(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            enabled: true,
            posture: "reviewing",
            approvedReflexBiases: ["Prefer the bounded read path."],
            reviewRequiredReflexCount: 9,
            approvedLowRiskReflexTotalCount: 5
        )

        let json = try #require(ClaudeBridge.organismBehaviorJSON(posture) as? [String: Any])
        #expect(json["reviewRequiredReflexCount"] as? Int == 9)
        #expect(json["approvedLowRiskReflexTotalCount"] as? Int == 5)
        #expect(json["approvedReflexBiasSampleCount"] as? Int == 1)
        #expect(json["approvedReflexBiasesAreSampled"] as? Bool == true)
    }
}

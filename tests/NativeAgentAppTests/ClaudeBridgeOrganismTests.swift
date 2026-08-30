import CognitiveSubstrate
import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Claude bridge organism projection")
struct ClaudeBridgeOrganismTests {
    @Test("bridge carries typed body beliefs instead of compatibility bits alone")
    func typedBodyBeliefProjection() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func evidence(_ id: String, _ evidenceClass: BodyEvidenceClass) -> BodyEvidenceReference {
            BodyEvidenceReference(
                id: id,
                evidenceClass: evidenceClass,
                observedAt: now,
                receivedAt: now
            )
        }
        let body = BodySchema(
            providersHealthy: false,
            providersAvailable: true,
            peerPresenceBelief: PeerPresenceBelief(
                generatedAt: now,
                evidence: [evidence("peer", .signedPeerContact)]
            ),
            notificationDeliveryBelief: NotificationDeliveryBelief(
                generatedAt: now,
                transportConfigured: true,
                transportAccepted: true,
                evidence: [evidence("apns", .apnsAcceptance)]
            ),
            memoryIntegrityReading: MemoryIntegrityReading(
                generatedAt: now,
                storeAvailable: true,
                maintenanceSucceeded: true,
                evidence: [evidence("memory", .maintenanceReceipt)]
            ),
            dreamIntegrityReading: DreamIntegrityReading(
                generatedAt: now,
                storeAvailable: true,
                completionEvidence: [evidence("dream", .dreamCompletion)]
            ),
            toolCapabilityReading: ToolCapabilityReading(
                generatedAt: now,
                configured: true,
                liveCapabilityObserved: true,
                evidence: [evidence("tool", .liveToolCapability)]
            ),
            approvalPathReading: ApprovalPathReading(
                generatedAt: now,
                writable: true,
                evidence: [evidence("approval", .approvalStore)]
            ),
            resourcePressureReading: ResourcePressureReading(
                generatedAt: now,
                thermalPressure: .elevated,
                lowPowerMode: false,
                evidence: [evidence("thermal", .processThermalState)]
            )
        )

        let json = ClaudeBridge.organismBodySchemaJSON(body)
        #expect(json["providersAvailable"] as? Bool == true)
        let peer = try #require(json["peerPresenceBelief"] as? [String: Any])
        #expect(peer["category"] as? String == "present")
        #expect(peer["evidenceCount"] as? Int == 1)
        #expect(peer["evidenceClasses"] as? [String] == ["signedPeerContact"])
        let notification = try #require(json["notificationDeliveryBelief"] as? [String: Any])
        #expect(notification["category"] as? String == "transportAccepted")
        #expect(notification["transportAccepted"] as? Bool == true)
        let memory = try #require(json["memoryIntegrityReading"] as? [String: Any])
        #expect(memory["category"] as? String == "healthy")
        let dream = try #require(json["dreamIntegrityReading"] as? [String: Any])
        #expect(dream["storeAvailable"] as? Bool == true)
        let tool = try #require(json["toolCapabilityReading"] as? [String: Any])
        #expect(tool["liveCapabilityObserved"] as? Bool == true)
        let approval = try #require(json["approvalPathReading"] as? [String: Any])
        #expect(approval["writable"] as? Bool == true)
        let resource = try #require(json["resourcePressureReading"] as? [String: Any])
        #expect(resource["thermalPressure"] as? String == "elevated")
        #expect(resource["lowPowerMode"] as? Bool == false)
    }

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

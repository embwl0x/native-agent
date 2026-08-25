import CognitiveSubstrate
import Foundation
import Testing
@testable import NativeAgentApp

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.substrate.organism
// Ledger row: telemetry.organism_debug/organism_reflex_review
//
// The debug route's event is the audit link between a durable organism reflex
// receipt and the bounded bridge event ring. These checks use the real event
// payload and BridgeEvent encoding, then pin the route that sends that payload
// to the actual publisher. They deliberately distinguish a receipt-backed
// review from disabled, unavailable, and durable-write failure outcomes.
// ─────────────────────────────────────────────────────────────────────────────

@Suite("Organism reflex review telemetry", .serialized)
struct OrganismReflexReviewTelemetryEvalTests {
    @Test("receipt-backed reviews publish an attributable bounded event")
    func receiptBackedReviewEvent() throws {
        let reviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let telemetry = ClaudeBridge.OrganismReflexReviewTelemetry(
            candidateID: "  candidate-17  ",
            decision: .approve,
            status: .applied,
            receiptID: "receipt-17",
            reviewedAt: reviewedAt
        )

        #expect(telemetry.mutationRecorded)
        #expect(telemetry.status == "applied")
        #expect(telemetry.candidateID == "candidate-17")
        #expect(telemetry.receiptID == "receipt-17")
        #expect(telemetry.failureDetail == nil)

        let payload = telemetry.payload
        #expect(Set(payload.keys) == [
            "candidateId", "decision", "status", "mutationRecorded",
            "receiptId", "reviewedAt", "failureDetail", "source",
        ])
        #expect(payload["candidateId"] as? String == "candidate-17")
        #expect(payload["decision"] as? String == "approve")
        #expect(payload["receiptId"] as? String == "receipt-17")
        #expect(payload["reviewedAt"] as? String == "2023-11-14T22:13:20Z")
        #expect(payload["source"] as? String == "organism_debug_bridge")
        #expect(payload["failureDetail"] is NSNull)

        let event = ClaudeBridge.BridgeEvent(
            seq: 17,
            timestamp: reviewedAt,
            kind: "organism_reflex_review",
            payload: payload
        )
        #expect(JSONSerialization.isValidJSONObject(event.asJSON))
        #expect(event.asJSON["kind"] as? String == "organism_reflex_review")
        #expect(event.asJSON["receiptId"] as? String == "receipt-17")
    }

    @Test("disabled unavailable and failed reviews remain non-mutations with bounded payloads")
    func adverseReviewOutcomes() {
        let tooLongID = "  " + String(repeating: "c", count: 500)
        let tooLongFailure = String(repeating: "x", count: 900)
        let outcomes: [(OrganismReflexReviewApplyStatus, Int)] = [
            (.organismDisabled, 503),
            (.candidateNotFound, 404),
            (.reviewInFlight, 409),
            (.notAwaitingReview, 409),
            (.approvalRequiresLowRisk, 422),
            (.persistenceFailed, 503),
        ]

        for (status, expectedHTTPStatus) in outcomes {
            let telemetry = ClaudeBridge.OrganismReflexReviewTelemetry(
                candidateID: tooLongID,
                decision: .retire,
                status: status,
                // A non-applied result must not accidentally look attributable
                // merely because a malformed caller supplied receipt fields.
                receiptID: "must-not-appear",
                reviewedAt: Date(timeIntervalSince1970: 1_700_000_000),
                failureDetail: tooLongFailure
            )
            let payload = telemetry.payload

            #expect(!telemetry.mutationRecorded, "\(status.rawValue) must not claim a state mutation")
            #expect(telemetry.candidateID.count == ClaudeBridge.OrganismReflexReviewTelemetry.maximumCandidateIDCharacters)
            #expect(telemetry.failureDetail?.count == ClaudeBridge.OrganismReflexReviewTelemetry.maximumFailureDetailCharacters)
            #expect(telemetry.receiptID == nil)
            #expect(telemetry.reviewedAt == nil)
            #expect(payload["receiptId"] is NSNull)
            #expect(payload["reviewedAt"] is NSNull)
            #expect(payload["status"] as? String == status.rawValue)
            #expect(JSONSerialization.isValidJSONObject(payload))
            #expect(ClaudeBridge.organismReflexReviewHTTPStatus(for: status) == expectedHTTPStatus)
        }
    }

    @Test("debug route publishes the typed outcome before reporting success")
    func routeUsesOutcomeCarryingPublisherPayload() throws {
        let source = try AppSourceScraping.appSource("ClaudeBridge.swift")
        let route = try AppSourceScraping.functionBody(named: "handleOrganismDebug", in: source)

        #expect(route.contains("runtime.applyOrganismReflexReview("))
        #expect(!route.contains("runtime.reviewOrganismReflexCandidate("))
        #expect(route.contains("self.publishEvent(kind: \"organism_reflex_review\", payload: telemetry.payload)"))
        #expect(route.contains("guard telemetry.mutationRecorded else"))
        #expect(route.contains("\"status\": \"not_reviewed\""))
    }
}

import CognitiveSubstrate
import Foundation
import Testing
@testable import NativeAgentApp

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.substrate.organism
// Ledger row: telemetry.organism_debug/organism_reflex_review
//
// The debug route's event is the audit link between a durable organism reflex
// receipt and the bounded bridge event ring. These checks execute the same two
// production emitters used by the endpoint and inspect the real ring without a
// listener or live runtime. They deliberately distinguish a receipt-backed
// review from disabled, unavailable, and durable-write failure outcomes.
// ─────────────────────────────────────────────────────────────────────────────

@Suite("Organism reflex review telemetry", .serialized)
struct OrganismReflexReviewTelemetryEvalTests {
    @Test("production emitters preserve exact kind payload and redaction contracts")
    func productionEmittersPreserveRoutingAndRedaction() throws {
        let bridge = ClaudeBridge()
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

        bridge.publishOrganismDebugEvent(
            status: "active",
            scenario: "provider_brittle",
            ttlSeconds: 37
        )
        bridge.publishOrganismReflexReviewEvent(telemetry)

        let events = bridge.recentEventPayloads()
        #expect(events.count == 2)
        #expect(events[0]["seq"] as? UInt64 == 1)
        #expect(events[0]["kind"] as? String == "organism_debug")
        #expect(Set(events[0].keys) == ["seq", "timestamp", "kind", "status", "scenario", "ttlSeconds"])
        #expect(events[0]["status"] as? String == "active")
        #expect(events[0]["scenario"] as? String == "provider_brittle")
        #expect(events[0]["ttlSeconds"] as? Int == 37)

        #expect(events[1]["seq"] as? UInt64 == 2)
        #expect(events[1]["kind"] as? String == "organism_reflex_review")
        #expect(Set(events[1].keys) == Set(payload.keys).union(["seq", "timestamp", "kind"]))
        #expect(events[1]["receiptId"] as? String == "receipt-17")
        #expect(events[1]["mutationRecorded"] as? Bool == true)
        #expect(events[1]["source"] as? String == "organism_debug_bridge")
        #expect(events[1]["pattern"] == nil)
        #expect(events[1]["note"] == nil)
        #expect(JSONSerialization.isValidJSONObject(events))
    }

    @Test("disabled unavailable and failed reviews remain non-mutations with bounded payloads")
    func adverseReviewOutcomes() {
        let bridge = ClaudeBridge()
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
            bridge.publishOrganismReflexReviewEvent(telemetry)
        }

        let events = bridge.recentEventPayloads()
        #expect(events.count == outcomes.count)
        #expect(events.map { $0["seq"] as? UInt64 } == [1, 2, 3, 4, 5, 6])
        #expect(events.allSatisfy { $0["kind"] as? String == "organism_reflex_review" })
        #expect(events.allSatisfy { $0["mutationRecorded"] as? Bool == false })
        #expect(events.allSatisfy { $0["receiptId"] is NSNull && $0["reviewedAt"] is NSNull })

        // A failed review is telemetry, not a publisher failure: the next
        // unrelated organism event must still enter the ring in sequence.
        bridge.publishOrganismDebugEvent(status: "cleared")
        let afterFailure = bridge.recentEventPayloads()
        #expect(afterFailure.last?["seq"] as? UInt64 == 7)
        #expect(afterFailure.last?["kind"] as? String == "organism_debug")
        #expect(Set(afterFailure.last?.keys.map { $0 } ?? []) == ["seq", "timestamp", "kind", "status"])
    }

    @Test("debug route publishes the typed outcome before reporting success")
    func routeUsesOutcomeCarryingPublisherPayload() throws {
        let source = try AppSourceScraping.appSource("ClaudeBridge.swift")
        let route = try AppSourceScraping.functionBody(named: "handleOrganismDebug", in: source)

        #expect(route.contains("runtime.applyOrganismReflexReview("))
        #expect(!route.contains("runtime.reviewOrganismReflexCandidate("))
        #expect(AppSourceScraping.occurrences(
            of: "self.publishOrganismDebugEvent(",
            in: route
        ) == 4)
        for status in ["reset", "settled", "cleared"] {
            #expect(AppSourceScraping.occurrences(
                of: "self.publishOrganismDebugEvent(status: \"\(status)\")",
                in: route
            ) == 1)
        }
        let reviewPublication = try #require(
            route.range(of: "self.publishOrganismReflexReviewEvent(telemetry)")
        )
        let mutationRecordedGuard = try #require(
            route.range(of: "guard telemetry.mutationRecorded else")
        )
        #expect(reviewPublication.lowerBound < mutationRecordedGuard.lowerBound)
        #expect(route.contains("\"status\": \"not_reviewed\""))
    }
}

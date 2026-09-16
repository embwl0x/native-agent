import Foundation
import Testing
@testable import NativeAgentApp

@Suite struct BridgePendingReplyEvidenceTests {
    @Test func pendingReplyCorrelatesExactRequestWithoutClaimingCompletion() throws {
        let home = URL(fileURLWithPath: "/tmp/bridge-receipt-fixture")
        let pending = ClaudeBridge.pendingMessageReply(requestID: "request-a", sessionID: nil, home: home)
        let data = try JSONSerialization.data(withJSONObject: pending)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["status"] as? String == "still_working")
        #expect(decoded["runId"] == nil)
        #expect(decoded["reply"] == nil)
        #expect(decoded["sessionId"] is NSNull)
        let locator = try #require(decoded["replyReceipt"] as? [String: Any])
        #expect(locator["path"] as? String == ClaudeBridge.messageReplyURL(home: home).path)
        let match = try #require(locator["match"] as? [String: String])
        let replies = [
            ClaudeBridge.messageReplyRecord(["status": "ok", "reply": "other"], requestID: "request-b"),
            ClaudeBridge.messageReplyRecord(["status": "chat_failed", "reply": "", "requestId": "stale"], requestID: "request-a"),
        ]
        let found = replies.filter { $0["requestId"] as? String == match["requestId"] }
        #expect(found.count == 1)
        #expect(found.first?["status"] as? String == "chat_failed")
        #expect(found.first?["reply"] as? String == "")
    }

    @Test func replyIdentityPreservesRunAndDeliveryEvidence() throws {
        let record = ClaudeBridge.messageReplyRecord([
            "status": "outcome_unknown", "sessionId": "session-one",
            "runId": "run-one", "deliveryId": "delivery-one", "reply": "retained reply",
        ], requestID: "request-one")
        #expect(record["requestId"] as? String == "request-one")
        #expect(record["runId"] as? String == "run-one")
        #expect(record["deliveryId"] as? String == "delivery-one")
        #expect(record["status"] as? String == "outcome_unknown")
        #expect(JSONSerialization.isValidJSONObject(record))
    }
}

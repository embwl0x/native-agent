import Foundation
import Testing
import NativeAgentShared
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / icloud.sendUnsignedResyncHint
@Suite("Unsigned iCloud resync hint", .serialized)
struct UnsignedResyncHintEvalTests {
    @Test("only the exact unsigned recovery envelope is eligible for the receiver exception")
    func unsignedHintIsActionFreeAndBounded() {
        let hint = iCloudBridge.unsignedResyncHintMessage(
            correlationID: "rejected-turn",
            targetSourceKey: "ios:device-1",
            publishedAt: "2026-08-24T00:00:00Z",
            secretVersion: 4
        )
        #expect(hint.signature == nil)
        #expect(hint.isUnsignedResyncHint)

        let actionLookalike = BridgeMessage.make(
            sender: "mac",
            text: "signature_invalid_resync",
            correlationID: "rejected-turn",
            metadata: [
                "kind": "signature_invalid_resync",
                "rejectedMessageId": "rejected-turn",
                "publishedAt": "2026-08-24T00:00:00Z",
                "pairing_secret_version": "4",
                "targetSourceKey": "ios:device-1",
                "action": "icloud_action",
            ]
        )
        #expect(!actionLookalike.isUnsignedResyncHint)

        let sessionLookalike = BridgeMessage.make(
            sender: "mac",
            text: "signature_invalid_resync",
            sessionID: "ios:session-1",
            correlationID: "rejected-turn",
            metadata: [
                "kind": "signature_invalid_resync",
                "rejectedMessageId": "rejected-turn",
                "publishedAt": "",
                "pairing_secret_version": "4",
                "targetSourceKey": "ios:device-1",
            ]
        )
        #expect(!sessionLookalike.isUnsignedResyncHint)

        var signedLookalike = hint
        signedLookalike.signature = "not-an-unsigned-hint"
        #expect(!signedLookalike.isUnsignedResyncHint)
    }
}

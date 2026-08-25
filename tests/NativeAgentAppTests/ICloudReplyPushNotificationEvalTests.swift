import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / icloud.replyPushNotification
//
// Drives the real reply-push owner with injected provider/prediction edges.
// The eval proves a canonical bounded request reaches APNS, while provider
// non-acceptance and malformed input settle honestly without claiming device
// delivery or leaving an optimistic prediction behind.

private actor ICloudReplyPushCapture {
    private(set) var requests: [ICloudReplyPushNotificationRequest] = []
    private(set) var startedEventIDs: [String] = []
    private(set) var failedEventIDs: [String] = []

    func send(_ request: ICloudReplyPushNotificationRequest, result: ICloudReplyPushNotificationProviderResult) -> ICloudReplyPushNotificationProviderResult {
        requests.append(request)
        return result
    }

    func started(_ eventID: String) { startedEventIDs.append(eventID) }
    func failed(_ eventID: String) { failedEventIDs.append(eventID) }
}

@Suite("iCloud reply push notification boundary")
struct ICloudReplyPushNotificationEvalTests {
    @Test("reply push sends one canonical provider request and reports provider acceptance only")
    func acceptedProviderRequestIsBoundedAndIdentifiable() async {
        let capture = ICloudReplyPushCapture()
        let accepted = await AppDelegate.sendICloudReplyPushNotification(
            text: "  Your reply is ready.  ",
            sessionID: " session-42 ",
            correlationID: "turn-42",
            kind: "reply",
            apnsSender: { request in
                await capture.send(request, result: .init(
                    attemptedTargets: 1,
                    acceptedTargets: 1,
                    errors: []
                ))
            },
            beginDeliveryPrediction: { eventID in await capture.started(eventID) },
            failDeliveryPrediction: { eventID in await capture.failed(eventID) }
        )

        #expect(accepted)
        let request = await capture.requests.first
        #expect(request?.body == "Your reply is ready.")
        #expect(request?.userInfo["sessionId"] == "session-42")
        #expect(request?.userInfo["dedupKey"] == "icloud_chat_reply:turn-42:reply")
        #expect(request?.userInfo["eventId"] == request?.eventID)
        #expect(request.map { NativeAgentDeviceEventIdentity.isCanonical($0.eventID) } == true)
        #expect(await capture.startedEventIDs == [request?.eventID].compactMap { $0 })
        #expect(await capture.failedEventIDs.isEmpty)

        guard case .ready(let bounded) = AppDelegate.iCloudReplyPushNotificationRequest(
            text: String(repeating: "x", count: 600),
            sessionID: nil,
            correlationID: "turn-42",
            kind: "reply"
        ), case .ready(let repeated) = AppDelegate.iCloudReplyPushNotificationRequest(
            text: "a revised reply",
            sessionID: nil,
            correlationID: "turn-42",
            kind: "reply"
        ) else {
            Issue.record("valid reply-push requests unexpectedly rejected")
            return
        }
        #expect(bounded.body.count == 500)
        #expect(repeated.eventID == bounded.eventID,
                "retries or revised prose must retain the same APNS collapse identity")
    }

    @Test("no provider acceptance fails the started prediction, including receiptless failure")
    func noProviderAcceptanceIsNotReportedAsDelivery() async {
        let capture = ICloudReplyPushCapture()
        let accepted = await AppDelegate.sendICloudReplyPushNotification(
            text: "Reply failed to notify.",
            sessionID: nil,
            correlationID: "turn-failed",
            kind: "error",
            apnsSender: { request in
                await capture.send(request, result: .init(
                    attemptedTargets: 0,
                    acceptedTargets: 0,
                    errors: []
                ))
            },
            beginDeliveryPrediction: { eventID in await capture.started(eventID) },
            failDeliveryPrediction: { eventID in await capture.failed(eventID) }
        )

        #expect(!accepted)
        let request = await capture.requests.first
        #expect(request?.urgency == "urgent")
        #expect(await capture.startedEventIDs == [request?.eventID].compactMap { $0 })
        #expect(await capture.failedEventIDs == [request?.eventID].compactMap { $0 })
        #expect(AppDelegate.iCloudReplyPushNotificationOutcome(providerResult: .init(
            attemptedTargets: 0, acceptedTargets: 0, errors: []
        )) == .providerNotAccepted(reason: "APNS returned no provider receipts."))
        #expect(AppDelegate.iCloudReplyPushNotificationOutcome(providerResult: .init(
            attemptedTargets: 0, acceptedTargets: 1, errors: []
        )) == .providerNotAccepted(reason: "APNS returned no provider receipts."))
    }

    @Test("blank or correlationless replies never invoke the provider or prediction")
    func invalidReplyInputIsRefusedBeforeSideEffects() async {
        let capture = ICloudReplyPushCapture()
        let blank = await AppDelegate.sendICloudReplyPushNotification(
            text: " \n ", sessionID: nil, correlationID: "turn-blank", kind: "reply",
            apnsSender: { request in
                await capture.send(request, result: .init(attemptedTargets: 1, acceptedTargets: 1, errors: []))
            },
            beginDeliveryPrediction: { eventID in await capture.started(eventID) },
            failDeliveryPrediction: { eventID in await capture.failed(eventID) }
        )
        let missingCorrelation = await AppDelegate.sendICloudReplyPushNotification(
            text: "reply", sessionID: nil, correlationID: " ", kind: "reply",
            apnsSender: { request in
                await capture.send(request, result: .init(attemptedTargets: 1, acceptedTargets: 1, errors: []))
            },
            beginDeliveryPrediction: { eventID in await capture.started(eventID) },
            failDeliveryPrediction: { eventID in await capture.failed(eventID) }
        )

        #expect(!blank)
        #expect(!missingCorrelation)
        #expect(await capture.requests.isEmpty)
        #expect(await capture.startedEventIDs.isEmpty)
        #expect(await capture.failedEventIDs.isEmpty)
    }
}

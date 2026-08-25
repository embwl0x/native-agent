import Foundation
import UIKit
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.app.didReceiveRemoteNotification`.
@MainActor
final class AppRemoteNotificationEvalTests: XCTestCase {
    private enum ExpectedFailure: Error { case refresh }

    func test_throwingPushLaneStillCompletesRemainingRefreshesAndRecordsOnce() async {
        var recordedEventIDs: [String?] = []
        var acknowledgements: [String] = []
        var steps: [String] = []
        let eventID = "event-remote-notification-eval"

        let outcome = await NativeAgentRemotePushProcessor.process(
            userInfo: ["eventId": eventID],
            recordReceipt: { info in
                steps.append("record")
                let recordedID = info["eventId"] as? String
                recordedEventIDs.append(recordedID)
                return PushReceiptEntry(
                    receivedAt: Date(),
                    source: "eval",
                    screen: "",
                    itemId: "",
                    eventId: recordedID
                )
            },
            sendReceipt: { id in
                steps.append("receipt")
                acknowledgements.append(id)
            },
            drainDeviceSyncPush: { _ in
                steps.append("drain")
                throw ExpectedFailure.refresh
            },
            refreshInbox: {
                steps.append("inbox")
                return true
            },
            refreshActivity: {
                steps.append("activity")
            }
        )

        XCTAssertEqual(recordedEventIDs, [eventID])
        XCTAssertEqual(acknowledgements, [eventID])
        XCTAssertEqual(steps, ["record", "receipt", "drain", "inbox", "activity"])
        XCTAssertEqual(outcome, .newData)
        XCTAssertEqual(outcome.backgroundFetchResult, .newData)
    }

    func test_completionGateInvokesUIKitCallbackExactlyOnce() {
        var completions: [UIBackgroundFetchResult] = []
        let gate = NativeAgentRemotePushCompletionGate { completions.append($0) }

        gate.complete(.newData)
        gate.complete(.noData)

        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first, .newData)
    }

    func test_appDelegateUsesTheSameOneShotGateForDeadlineAndNormalCompletion() throws {
        let source = try MobileEvalSources.mobileSource("NativeAgentMobileApp.swift")
        let delegate = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "NativeAgentMobilePushDelegate", keyword: "final class", in: source)
        )

        XCTAssertTrue(delegate.contains("backgroundPushDeadlineNanoseconds"))
        XCTAssertTrue(delegate.contains("let timeoutTask = Task"))
        XCTAssertTrue(delegate.contains("completionGate.complete(.noData)"))
        XCTAssertTrue(delegate.contains("timeoutTask.cancel()"))
        XCTAssertTrue(delegate.contains("completionGate.complete(outcome.backgroundFetchResult)"))
        XCTAssertFalse(delegate.contains("completionHandler(outcome.backgroundFetchResult)"))
    }
}

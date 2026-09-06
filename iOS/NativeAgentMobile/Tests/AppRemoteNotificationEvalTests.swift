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
        // 2026-09-06 (86b9825e): the receipt moved BEHIND the recovery lanes.
        // Its iCloud action write can wait the full 30 s while the background
        // push must report at 25 s, so acknowledging first meant a missed reply
        // was never recovered on the push that announced it. Drain/inbox/
        // activity run first; the receipt takes the remaining budget. The
        // throwing drain still must not suppress the lanes after it, and the
        // receipt must still be sent exactly once.
        XCTAssertEqual(steps, ["record", "drain", "inbox", "activity", "receipt"])
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

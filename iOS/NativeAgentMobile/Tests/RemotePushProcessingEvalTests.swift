import Foundation
import NativeAgentShared
import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.sync / ios.push.didReceiveRemoteNotification`.
@MainActor
final class RemotePushProcessingEvalTests: XCTestCase {
    func test_deviceSyncPlainAndUnrelatedPushesRecordRouteAndReportTruthfulResults() async {
        let deviceSyncEventID = NativeAgentDeviceEventIdentity.notification(
            userInfo: ["itemId": "device-sync"]
        )
        let deviceSync = await process(
            payload: ["eventId": deviceSyncEventID, "kind": "device-sync"],
            cloudKitDelivered: true,
            inboxLoaded: false
        )
        XCTAssertEqual(deviceSync.outcome, .newData)
        XCTAssertEqual(deviceSync.outcome.backgroundFetchResult, .newData)
        XCTAssertEqual(deviceSync.recordedEventIDs, [deviceSyncEventID])
        XCTAssertEqual(deviceSync.acknowledgedEventIDs, [deviceSyncEventID])
        XCTAssertEqual(deviceSync.drainedKinds, ["device-sync"])
        XCTAssertEqual(deviceSync.steps, ["record", "acknowledge", "drain", "inbox", "activity"])

        let plainEventID = NativeAgentDeviceEventIdentity.notification(
            userInfo: ["itemId": "plain-notification"]
        )
        let plainNotification = await process(
            payload: ["eventId": plainEventID, "kind": "plain-notification"],
            cloudKitDelivered: false,
            inboxLoaded: true
        )
        XCTAssertEqual(plainNotification.outcome, .newData)
        XCTAssertEqual(plainNotification.outcome.backgroundFetchResult, .newData)
        XCTAssertEqual(plainNotification.recordedEventIDs, [plainEventID])
        XCTAssertEqual(plainNotification.acknowledgedEventIDs, [plainEventID])
        XCTAssertEqual(plainNotification.drainedKinds, ["plain-notification"])

        let unrelated = await process(
            payload: ["kind": "unrelated"],
            cloudKitDelivered: false,
            inboxLoaded: false
        )
        XCTAssertEqual(unrelated.outcome, .noData)
        XCTAssertEqual(unrelated.outcome.backgroundFetchResult, .noData)
        XCTAssertEqual(unrelated.recordedEventIDs, [nil])
        XCTAssertTrue(unrelated.acknowledgedEventIDs.isEmpty)
        XCTAssertEqual(unrelated.drainedKinds, ["unrelated"])
        XCTAssertEqual(unrelated.steps, ["record", "drain", "inbox", "activity"])
    }

    func test_newDataIsReportedExactlyWhenInboxOrCloudKitDeliveredData() async {
        let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: ["itemId": "matrix"])
        for (cloudKitDelivered, inboxLoaded, expected) in [
            (false, false, NativeAgentRemotePushProcessor.FetchOutcome.noData),
            (false, true, .newData),
            (true, false, .newData),
            (true, true, .newData),
        ] {
            let result = await process(
                payload: ["eventId": eventID],
                cloudKitDelivered: cloudKitDelivered,
                inboxLoaded: inboxLoaded
            )
            XCTAssertEqual(result.outcome, expected)
            XCTAssertEqual(
                result.outcome.backgroundFetchResult,
                expected == .newData ? .newData : .noData
            )
        }
    }

    func test_visibleChatReplyPushDrainsReplyTransportAndReportsDeliveredData() async {
        let result = await process(
            payload: [
                "source": "icloud_chat_reply",
                "screen": "chat",
                "correlationId": "reply-1",
            ],
            cloudKitDelivered: false,
            chatReplyLoaded: true,
            inboxLoaded: false
        )

        XCTAssertEqual(result.outcome, .newData)
        XCTAssertEqual(result.steps, ["record", "drain", "chat", "inbox", "activity"])

        let unrelated = await process(
            payload: ["source": "other", "screen": "chat"],
            cloudKitDelivered: false,
            chatReplyLoaded: true,
            inboxLoaded: false
        )
        XCTAssertEqual(unrelated.outcome, .noData)
        XCTAssertFalse(unrelated.steps.contains("chat"))
    }

    private func process(
        payload: [String: String],
        cloudKitDelivered: Bool,
        chatReplyLoaded: Bool = false,
        inboxLoaded: Bool
    ) async -> ProcessResult {
        var steps: [String] = []
        var recordedEventIDs: [String?] = []
        var acknowledgedEventIDs: [String] = []
        var drainedKinds: [String] = []
        let userInfo = payload.reduce(into: [AnyHashable: Any]()) { values, entry in
            values[entry.key] = entry.value
        }

        let outcome = await NativeAgentRemotePushProcessor.process(
            userInfo: userInfo,
            recordReceipt: { info in
                steps.append("record")
                let eventID = NativeAgentNotificationEventGate.eventID(in: info)
                recordedEventIDs.append(eventID)
                return PushReceiptEntry(
                    receivedAt: Date(),
                    source: "eval",
                    screen: "",
                    itemId: "",
                    eventId: eventID
                )
            },
            sendReceipt: { eventID in
                steps.append("acknowledge")
                acknowledgedEventIDs.append(eventID)
            },
            drainDeviceSyncPush: { info in
                steps.append("drain")
                drainedKinds.append(info["kind"] as? String ?? "")
                return cloudKitDelivered
            },
            refreshChatReply: {
                steps.append("chat")
                return chatReplyLoaded
            },
            refreshInbox: {
                steps.append("inbox")
                return inboxLoaded
            },
            refreshActivity: {
                steps.append("activity")
            }
        )
        return ProcessResult(
            outcome: outcome,
            steps: steps,
            recordedEventIDs: recordedEventIDs,
            acknowledgedEventIDs: acknowledgedEventIDs,
            drainedKinds: drainedKinds
        )
    }

    private struct ProcessResult {
        let outcome: NativeAgentRemotePushProcessor.FetchOutcome
        let steps: [String]
        let recordedEventIDs: [String?]
        let acknowledgedEventIDs: [String]
        let drainedKinds: [String]
    }
}

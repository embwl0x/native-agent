import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.chat.scrollToBottom.scheduler
final class ChatScrollSchedulerEvalTests: XCTestCase {
    func testStreamingBurstSchedulesOneScrollAndUsesTheLatestMessageTarget() {
        var scheduler = ChatScrollScheduler()
        var scheduledSerials: [Int] = []

        for index in 0..<200 {
            if let serial = scheduler.schedule(
                targetID: "message-\(index)",
                animated: false,
                force: false
            ) {
                scheduledSerials.append(serial)
            }
        }

        XCTAssertEqual(scheduledSerials.count, 1,
                       "a streaming burst must invoke at most one scroll in its pending interval")
        XCTAssertEqual(
            scheduler.complete(serial: scheduledSerials[0], messagesAreAvailable: true),
            "message-199",
            "the coalesced invocation must follow the newest streamed message"
        )
        XCTAssertFalse(scheduler.isScheduled)
    }

    func testForcedScrollSupersedesAnOlderPendingCallbackWithoutClearingTheNewOne() throws {
        var scheduler = ChatScrollScheduler()
        let ordinary = try XCTUnwrap(scheduler.schedule(
            targetID: "older-message", animated: false, force: false
        ))
        let forced = try XCTUnwrap(scheduler.schedule(
            targetID: "recovery-message", animated: true, force: true
        ))

        XCTAssertNil(scheduler.complete(serial: ordinary, messagesAreAvailable: true))
        XCTAssertTrue(scheduler.isScheduled)
        XCTAssertEqual(scheduler.complete(serial: forced, messagesAreAvailable: true), "recovery-message")
        XCTAssertFalse(scheduler.isScheduled)
    }
}

import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.sync / ios.push.bridgeNotificationScheduler
final class BridgeNotificationSchedulerEvalTests: XCTestCase {
    func testSchedulerUsesTheDeduplicatedEventGateAndNeverSchedulesABlankBody() throws {
        let source = try MobileEvalSources.mobileSource("MobilePushNotifications.swift")
        let scheduler = try XCTUnwrap(MobileEvalSources.blockBody(named: "NativeAgentBridgeNotificationScheduler", keyword: "enum", in: source))

        XCTAssertTrue(scheduler.contains("?? nonEmpty(msg.text)"))
        XCTAssertTrue(scheduler.contains("?? \"New activity from Mac.\""))
        XCTAssertTrue(scheduler.contains("NativeAgentNotificationEventGate.add("))
        XCTAssertTrue(scheduler.contains("eventID: eventID"))
        XCTAssertTrue(scheduler.contains("sendNotificationReceipt("))
    }
}

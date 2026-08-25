import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.sync / ios.app.bridgeNotificationScheduler.schedule
final class BridgeNotificationSchedulerScheduleEvalTests: XCTestCase {
    func testScheduleDerivesIdentityDeduplicatesDeliveryAndReportsTheReceipt() throws {
        let source = try MobileEvalSources.mobileSource("NativeAgentMobileApp.swift")
        let scheduler = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "NativeAgentBridgeNotificationScheduler", keyword: "enum", in: source)
        )
        let schedule = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "schedule", keyword: "static func", in: scheduler)
        )

        XCTAssertTrue(schedule.contains("NativeAgentDeviceEventIdentity.notification("))
        XCTAssertTrue(schedule.contains("userInfo[\"eventId\"] = eventID"))
        XCTAssertTrue(schedule.contains("NativeAgentNotificationEventGate.add("))
        XCTAssertTrue(schedule.contains("eventID: eventID"))
        XCTAssertTrue(schedule.contains("sendNotificationReceipt("))
        XCTAssertTrue(schedule.contains("channel: \"icloud_bridge\""))
    }
}

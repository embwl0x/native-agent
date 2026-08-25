import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.sync / ios.app.configureNotifications
final class ConfigureNotificationsEvalTests: XCTestCase {
    func testPairingCompletionReplaysDeferredNotificationConfiguration() throws {
        let source = try MobileEvalSources.mobileSource("NativeAgentMobileApp.swift")
        XCTAssertTrue(source.contains("configureTransport()\n                        // Registration may have been deferred"))
        XCTAssertTrue(source.contains("configureNotifications()"))
        XCTAssertTrue(source.contains("guard pairingStore.usesICloudTransport else"))
        XCTAssertTrue(source.contains("UIApplication.shared.registerForRemoteNotifications()"))
    }
}

import Foundation
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.app.launchArgHooks`.
///
/// Test-only launch switches must parse safely and execute at most once even
/// when SwiftUI remounts the application root during a pairing transition.
final class LaunchArgumentHooksEvalTests: XCTestCase {
    func test_pairingSecretAcceptsOnlyAnExactThirtyTwoBytePayload() {
        let valid = Data(repeating: 0xA5, count: 32).base64EncodedString()
        XCTAssertEqual(
            NativeAgentLaunchArgumentPresentation.pairingSecret(
                from: ["NativeAgentMobile", "-pairingSecretBase64", valid]
            ),
            Data(repeating: 0xA5, count: 32)
        )
        XCTAssertNil(
            NativeAgentLaunchArgumentPresentation.pairingSecret(
                from: ["NativeAgentMobile", "-pairingSecretBase64", Data(repeating: 0, count: 31).base64EncodedString()]
            )
        )
        XCTAssertNil(NativeAgentLaunchArgumentPresentation.pairingSecret(from: ["NativeAgentMobile", "-pairingSecretBase64"]))
    }

    func test_notificationHookRequiresItsSwitchAndUsesTrimmedOverrides() {
        XCTAssertNil(NativeAgentLaunchArgumentPresentation.testNotification(from: ["NativeAgentMobile"]))
        XCTAssertEqual(
            NativeAgentLaunchArgumentPresentation.testNotification(
                from: [
                    "NativeAgentMobile", "-sendTestNotification",
                    "-notificationTitle", "  Test title  ",
                    "-notificationBody", "  Test body  ",
                ]
            ),
            NativeAgentLaunchArgumentPresentation.TestNotification(
                title: "Test title",
                body: "Test body"
            )
        )
        XCTAssertEqual(
            NativeAgentLaunchArgumentPresentation.testNotification(
                from: ["NativeAgentMobile", "-sendTestNotification", "-notificationTitle", "   "]
            )?.title,
            "NativeAgent test notification"
        )
    }

    func test_pairingAndNotificationHooksHaveIndependentOneShotGuards() throws {
        let source = try MobileEvalSources.mobileSource("NativeAgentMobileApp.swift")
        XCTAssertTrue(source.contains("@State private var didApplyPairingSecretLaunchArgument = false"))
        XCTAssertTrue(source.contains("@State private var didScheduleTestNotificationLaunchArgument = false"))

        let pairing = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "checkLaunchArgsForPairingSecret", keyword: "private func", in: source)
        )
        let notification = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "checkLaunchArgsForTestNotification", keyword: "private func", in: source)
        )
        XCTAssertTrue(pairing.contains("!didApplyPairingSecretLaunchArgument"))
        XCTAssertTrue(pairing.contains("didApplyPairingSecretLaunchArgument = true"))
        XCTAssertTrue(notification.contains("!didScheduleTestNotificationLaunchArgument"))
        XCTAssertTrue(notification.contains("didScheduleTestNotificationLaunchArgument = true"))
    }
}

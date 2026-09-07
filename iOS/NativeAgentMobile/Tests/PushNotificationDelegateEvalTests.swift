import UserNotifications
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.push.notificationDelegate`.
///
/// A foreground alert remains visible, but only an explicit notification tap
/// becomes a persisted navigation intent. Dismisses must leave app state alone.
final class PushNotificationDelegateEvalTests: XCTestCase {
    func test_foregroundPresentationRetainsVisibleAlertAndBadgeSignals() {
        let options = NativeAgentNotificationDelegatePresentation.foregroundPresentationOptions
        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.list))
        XCTAssertTrue(options.contains(.sound))
        XCTAssertTrue(options.contains(.badge))
    }

    func test_onlyTheDefaultTapIsRoutedAsNavigationIntent() {
        XCTAssertTrue(
            NativeAgentNotificationDelegatePresentation.shouldRouteUserResponse(
                actionIdentifier: UNNotificationDefaultActionIdentifier
            )
        )
        XCTAssertFalse(
            NativeAgentNotificationDelegatePresentation.shouldRouteUserResponse(
                actionIdentifier: UNNotificationDismissActionIdentifier
            )
        )
        XCTAssertFalse(
            NativeAgentNotificationDelegatePresentation.shouldRouteUserResponse(
                actionIdentifier: "nativeagent.custom-action"
            )
        )
    }

    func test_delegateGuardsRoutingBeforePersistingLaunchIntent() throws {
        let source = try MobileEvalSources.mobileSource("MobilePushNotifications.swift")
        let delegate = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "NativeAgentNotificationDelegate", keyword: "final class", in: source)
        )
        let guardRange = try XCTUnwrap(delegate.range(of: "shouldRouteUserResponse"))
        let intentRange = try XCTUnwrap(delegate.range(of: "markOpenActivityPending"))
        XCTAssertLessThan(guardRange.lowerBound, intentRange.lowerBound)
    }
}

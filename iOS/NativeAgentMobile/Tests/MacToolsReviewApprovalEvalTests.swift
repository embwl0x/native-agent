import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.mactools.reviewApprovalButton`.
///
/// A remote action waiting for approval must land on the Approvals queue, not
/// merely the Activity overview that still requires another manual drill-in.
final class MacToolsReviewApprovalEvalTests: XCTestCase {
    func test_reviewApprovalRouteTargetsTheResolvableQueue() {
        XCTAssertEqual(
            ActivityScreenPresentation.activityDestination(for: " approvals "),
            .approvals
        )
        XCTAssertNil(ActivityScreenPresentation.activityDestination(for: "activity"))
    }

    func test_reviewButtonCarriesApprovalTargetThroughTheActivityNavigator() throws {
        let tools = try MobileEvalSources.mobileSource("MacToolsView.swift")
        let card = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "RemoteActionCardView", keyword: "struct", in: tools)
        )
        XCTAssertTrue(card.contains("userInfo: [\"screen\": \"approvals\"]"))

        let content = try MobileEvalSources.mobileSource("ContentView.swift")
        XCTAssertTrue(content.contains("activityNavigationTarget = target == .activity"))
        XCTAssertTrue(content.contains("ActivityScreenPresentation.activityDestination(for: screen)"))

        let activity = try MobileEvalSources.mobileSource("ActivityView.swift")
        XCTAssertTrue(activity.contains(".onChange(of: navigationTarget)"))
        XCTAssertTrue(activity.contains("path.append(section)"))
    }
}

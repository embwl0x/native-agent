import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.chrome.macSyncErrorBanner
final class MacSyncErrorBannerEvalTests: XCTestCase {
    func testOnlyMeaningfulUndismissedSyncErrorsProduceABanner() {
        XCTAssertNil(MacSyncErrorBannerPresentation.visibleMessage(syncError: nil, dismissedMessage: nil))
        XCTAssertNil(MacSyncErrorBannerPresentation.visibleMessage(syncError: " \n ", dismissedMessage: nil))
        XCTAssertEqual(
            MacSyncErrorBannerPresentation.visibleMessage(
                syncError: "  iCloud snapshots are still downloading.  ",
                dismissedMessage: nil
            ),
            "iCloud snapshots are still downloading."
        )
        XCTAssertNil(
            MacSyncErrorBannerPresentation.visibleMessage(
                syncError: "iCloud snapshots are still downloading.",
                dismissedMessage: "iCloud snapshots are still downloading."
            )
        )
    }

    func testNewErrorReplacesOnlyTheDismissedWarning() {
        XCTAssertEqual(
            MacSyncErrorBannerPresentation.visibleMessage(
                syncError: "CloudKit health snapshot failed.",
                dismissedMessage: "iCloud snapshots are still downloading."
            ),
            "CloudKit health snapshot failed."
        )
    }

    func testBannerUsesSharedPresentationAndResetsAfterTheConditionClears() throws {
        let source = try MobileEvalSources.mobileSource("SystemToastBar.swift")
        let banner = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "MacSyncErrorBanner", keyword: "struct", in: source)
        )

        XCTAssertTrue(banner.contains("MacSyncErrorBannerPresentation.visibleMessage("))
        XCTAssertTrue(banner.contains("dismissedMessage = message"))
        XCTAssertTrue(banner.contains("MacSyncErrorBannerPresentation.normalizedMessage(newValue) == nil"))
        XCTAssertTrue(banner.contains("isExpanded = false"))
    }

    func testSharedChromePinsTheBannerInTheTopSafeArea() throws {
        let source = try MobileEvalSources.mobileSource("SystemToastBar.swift")
        let modifier = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "View", keyword: "extension", in: source)
        )

        XCTAssertTrue(modifier.contains("safeAreaInset(edge: .top, spacing: 0)"))
        XCTAssertTrue(modifier.contains("MacSyncErrorBanner()"))
    }
}

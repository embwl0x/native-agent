import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.chat.errorBanner.dismiss
@MainActor
final class ChatErrorBannerDismissEvalTests: XCTestCase {
    func testDismissingCurrentErrorDoesNotSuppressALaterError() {
        let suiteName = "ChatErrorBannerDismissEvalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)

        store.errorBanner = "First failure"
        store.dismissErrorBanner()
        XCTAssertNil(store.errorBanner)

        store.errorBanner = "Later failure"
        XCTAssertEqual(store.errorBanner, "Later failure")
    }

    func testChatBannerUsesTheStoreDismissalBoundaryAndAccessibleControl() throws {
        let source = try MobileEvalSources.mobileSource("ChatView.swift")
        let chat = try XCTUnwrap(MobileEvalSources.blockBody(named: "ChatView", keyword: "struct", in: source))
        let chatError = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "let error = store.errorBanner", keyword: "if", in: chat)
        )
        let banner = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "MobileChatIssueBanner", keyword: "struct", in: source)
        )

        // The screen supplies the outcome-specific name and store boundary;
        // the shared banner owns the actual accessible dismiss control.
        XCTAssertTrue(chatError.contains("MobileChatIssueBanner("))
        XCTAssertTrue(chatError.contains("message: error"))
        XCTAssertTrue(chatError.contains("dismissLabel: \"Dismiss chat error\""))
        XCTAssertTrue(chatError.contains("onDismiss: { store.dismissErrorBanner() }"))
        XCTAssertTrue(banner.contains("Button(action: onDismiss)"))
        XCTAssertTrue(banner.contains(".accessibilityLabel(dismissLabel)"))
        XCTAssertTrue(banner.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(banner.contains(".accessibilityElement(children: .contain)"))
    }
}

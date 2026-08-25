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

        XCTAssertTrue(chat.contains("store.dismissErrorBanner()"))
        XCTAssertTrue(chat.contains("accessibilityLabel(\"Dismiss chat error\")"))
    }
}

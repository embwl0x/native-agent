import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.mactools.retryButton`.
///
/// Retry always replays the captured card payload. Because the composer fields
/// may have changed in the meantime, the receipt names that original request.
final class MacToolsRetryButtonEvalTests: XCTestCase {
    func test_everyRetryNamesItsCapturedOriginalPayloadNotAChangedComposerValue() {
        // The current notification title/message, volume slider, Spotlight
        // field, and shortcut field are deliberately different from these
        // captured action payloads. A retry must describe the latter.
        XCTAssertEqual(
            RemoteActionRetryPresentation.dispatchDetail(
                for: .notify(title: "Original title", message: "Original message"),
                isRetry: true
            ),
            "Retrying original notification \"Original title\": \"Original message\" — not the current composer draft."
        )
        XCTAssertEqual(
            RemoteActionRetryPresentation.dispatchDetail(for: .system("lock_screen"), isRetry: true),
            "Retrying original system action: lock screen."
        )
        XCTAssertEqual(
            RemoteActionRetryPresentation.dispatchDetail(for: .volume(37), isRetry: true),
            "Retrying original volume target: 37% — not the current slider value."
        )
        XCTAssertEqual(
            RemoteActionRetryPresentation.dispatchDetail(for: .spotlight("old receipts"), isRetry: true),
            "Retrying original Spotlight search \"old receipts\" — not the current search field."
        )
        XCTAssertEqual(
            RemoteActionRetryPresentation.dispatchDetail(for: .shortcut("Old routine"), isRetry: true),
            "Retrying original shortcut \"Old routine\" — not the current shortcut field."
        )
    }

    func test_firstAttemptsKeepTheirNeutralProgressCopy() {
        XCTAssertEqual(
            RemoteActionRetryPresentation.dispatchDetail(for: .notify(title: "New", message: "Draft"), isRetry: false),
            "Sending to Mac"
        )
        XCTAssertEqual(
            RemoteActionRetryPresentation.dispatchDetail(for: .spotlight("new query"), isRetry: false),
            "Searching Mac"
        )
    }

    func test_allRetryDispatchesRouteCapturedValuesThroughTheOriginalPayloadReceipt() throws {
        let source = try MobileEvalSources.mobileSource("MacToolsView.swift")
        for payload in [
            ".notify(title: title, message: message)",
            ".system(action)",
            ".volume(percent)",
            ".spotlight(query)",
            ".shortcut(name)"
        ] {
            XCTAssertTrue(
                source.contains("for: \(payload),\n                isRetry: cardID != nil"),
                "the retry receipt no longer identifies the captured \(payload) payload"
            )
        }
    }
}

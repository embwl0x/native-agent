import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.providers.detail.testConnection`.
///
/// A missing or arbitrary action payload must never be shown as a passing
/// connection test: only Mac's explicit `ok` status carries that claim.
final class ProviderConnectionTestResultEvalTests: XCTestCase {
    func test_onlyExplicitOkProducesPassingConnectionFeedback() {
        XCTAssertEqual(
            ProviderConnectionTestPresentation.feedback(status: "ok"),
            "Test complete."
        )
        XCTAssertEqual(
            ProviderConnectionTestPresentation.feedback(status: "  OK \n"),
            "Test complete."
        )
    }

    func test_emptyFailureAndUnrecognizedResponsesAreNeverPassingFeedback() {
        let responses = ["", "error", "connection failed", "provider refused request", "latency=20ms"]
        for response in responses {
            let feedback = ProviderConnectionTestPresentation.feedback(status: response)
            XCTAssertTrue(feedback.hasPrefix("Error:"), "\(response.debugDescription) was reported as a passing test: \(feedback)")
            XCTAssertNotEqual(feedback, "Test complete.")
        }
        XCTAssertEqual(
            ProviderConnectionTestPresentation.feedback(status: ""),
            "Error: Mac did not return a test result."
        )
    }

    func test_providerSheetRoutesTestRepliesThroughTheStrictClassifier() throws {
        let source = try MobileEvalSources.mobileSource("ProviderSettingsView.swift")
        XCTAssertTrue(source.contains("ProviderConnectionTestPresentation.feedback("))
        XCTAssertFalse(source.contains("if trimmed.isEmpty || trimmed == \"ok\""))
    }
}

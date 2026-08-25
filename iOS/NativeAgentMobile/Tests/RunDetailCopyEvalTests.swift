import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.runs.detail.copy`.
///
/// Copying long run output must leave a visible, section-specific result rather
/// than silently changing the system clipboard.
final class RunDetailCopyEvalTests: XCTestCase {
    func test_copyFeedbackNamesTheCopiedSection() {
        XCTAssertEqual(
            RunDetailCopyPresentation.successMessage(for: "Prompt"),
            "Copied Prompt to clipboard."
        )
        XCTAssertEqual(
            RunDetailCopyPresentation.successMessage(for: " Output "),
            "Copied Output to clipboard."
        )
    }

    func test_detailCopyWritesBeforePresentingSuccessFeedback() throws {
        let source = try MobileEvalSources.mobileSource("AdvancedView.swift")
        let copyAction = try XCTUnwrap(
            MobileEvalSources.blockBody(
                named: "runTextSection(_ title: String, systemImage: String, text: String)",
                keyword: "private func",
                in: source
            )
        )
        let write = try XCTUnwrap(copyAction.range(of: "UIPasteboard.general.string = text"))
        let feedback = try XCTUnwrap(copyAction.range(of: "RunDetailCopyPresentation.successMessage(for: title)"))

        XCTAssertLessThan(write.lowerBound, feedback.lowerBound)
        XCTAssertTrue(copyAction.contains("iOSSystemToastCenter.shared.push("))
    }
}

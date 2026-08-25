import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.advanced.runDetail.copyPrompt
final class RunDetailCopyPromptEvalTests: XCTestCase {
    func testOnlyMeaningfulCapturedPromptsAreCopyableAndTheirTextIsPreserved() {
        let captured = "  Summarize this run.\n"

        XCTAssertEqual(RunDetailPromptPresentation.copyablePrompt(captured), captured)
        XCTAssertNil(RunDetailPromptPresentation.copyablePrompt(nil))
        XCTAssertNil(RunDetailPromptPresentation.copyablePrompt(""))
        XCTAssertNil(RunDetailPromptPresentation.copyablePrompt(" \n\t "))
    }

    func testUnavailablePromptHasAnExplicitNonCopyableExplanation() {
        XCTAssertEqual(
            RunDetailPromptPresentation.unavailableDescription,
            "The prompt was not captured for this run."
        )
    }

    func testRunDetailUsesThePromptGateBeforeExposingTheCopyAction() throws {
        let source = try MobileEvalSources.mobileSource("AdvancedView.swift")
        let detail = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "RunDetailView", keyword: "struct", in: source)
        )
        let textSection = try XCTUnwrap(
            MobileEvalSources.blockBody(
                named: "runTextSection(_ title: String, systemImage: String, text: String)",
                keyword: "private func",
                in: source
            )
        )

        XCTAssertTrue(detail.contains("RunDetailPromptPresentation.copyablePrompt(run.prompt)"))
        XCTAssertTrue(detail.contains("RunDetailPromptPresentation.unavailableDescription"))
        XCTAssertTrue(textSection.contains("Button(\"Copy \\(title)\""))
        XCTAssertTrue(textSection.contains("UIPasteboard.general.string = text"))
    }
}

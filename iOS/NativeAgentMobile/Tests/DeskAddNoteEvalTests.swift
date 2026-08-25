import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.desk.addNote
final class DeskAddNoteEvalTests: XCTestCase {
    func testTrimmedNoteAtMacLimitIsTheExactTextSentToTheAction() {
        let atLimit = String(repeating: "n", count: MobileDeskNotePresentation.maximumCharacterCount)

        XCTAssertEqual(
            MobileDeskNotePresentation.submissionText(for: " \n\(atLimit)\n "),
            atLimit
        )
        XCTAssertNil(MobileDeskNotePresentation.validationMessage(for: atLimit))
    }

    func testWhitespaceAndOversizedDraftsCannotBeSubmittedAndExplainWhy() {
        XCTAssertNil(MobileDeskNotePresentation.submissionText(for: " \n "))
        XCTAssertEqual(
            MobileDeskNotePresentation.validationMessage(for: " \n "),
            "Enter a note before adding it."
        )

        let tooLong = String(repeating: "n", count: MobileDeskNotePresentation.maximumCharacterCount + 1)
        XCTAssertNil(MobileDeskNotePresentation.submissionText(for: tooLong))
        XCTAssertEqual(
            MobileDeskNotePresentation.validationMessage(for: tooLong),
            "Desk notes can be at most 2,000 characters."
        )
    }

    func testMobileLimitMatchesTheMacAppendNoteBoundary() throws {
        let macRouter = try MobileEvalSources.repoFile("Sources/NativeAgentApp/MacSyncActionRouter.swift")

        XCTAssertEqual(MobileDeskNotePresentation.maximumCharacterCount, 2_000)
        XCTAssertTrue(
            macRouter.contains("!note.isEmpty, note.count <= 2_000"),
            "The iPhone form must keep its local validation aligned with the Mac action boundary."
        )
    }
}

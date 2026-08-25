import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.chat.composer.photosPicker
@MainActor
final class PhotosPickerComposerEvalTests: XCTestCase {
    func testAllRejectedPhotosNameTheEmptyComposerOutcomeAndRecovery() {
        XCTAssertEqual(
            PhotosPickerLoadPresentation.message(loadedCount: 0, skippedCount: 1),
            "No photo was added because it was too large or unsupported. Try a smaller image."
        )
        XCTAssertEqual(
            PhotosPickerLoadPresentation.message(loadedCount: 0, skippedCount: 3),
            "No photos were added because all 3 were too large or unsupported. Try smaller images."
        )
    }

    func testPartialAndSuccessfulSelectionsDescribeOnlyTheActualComposerState() {
        XCTAssertEqual(
            PhotosPickerLoadPresentation.message(loadedCount: 1, skippedCount: 1),
            "One photo was too large or unsupported; 1 photo is ready to send."
        )
        XCTAssertEqual(
            PhotosPickerLoadPresentation.message(loadedCount: 2, skippedCount: 2),
            "2 photos were too large or unsupported; 2 photos are ready to send."
        )
        XCTAssertNil(PhotosPickerLoadPresentation.message(loadedCount: 2, skippedCount: 0))
    }
}

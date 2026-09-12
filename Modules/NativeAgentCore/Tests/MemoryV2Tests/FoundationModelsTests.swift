import XCTest
@testable import MemoryV2

// What is left of this suite, 2026-09-11: `classify` and its reply matching.
// The on-device fact extraction it used to cover is deleted — the memory manager
// (MemoryV2+MemoryManager.swift, MemoryManagerLaneTests) replaced it.
final class FoundationModelsTests: XCTestCase {

    func testIsAvailableIsBoolean() {
        _ = AppleFoundationModelsAdapter.isAvailable
    }

    func testClassifyFallback() async {
        if !AppleFoundationModelsAdapter.isAvailable {
            do {
                _ = try await AppleFoundationModelsAdapter.classify(
                    content: "I like coffee",
                    into: ["preference", "identity"]
                )
                XCTFail("expected .unavailable")
            } catch let err as FoundationModelsError {
                XCTAssertEqual(err, .unavailable)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testClassifyEmptyCategoriesThrows() async {
        do {
            _ = try await AppleFoundationModelsAdapter.classify(content: "x", into: [])
            XCTFail("expected throw on empty categories")
        } catch {
            // expected
        }
    }

    // MARK: classify reply matching (fix-round finding 1)
    //
    // The model call itself needs Apple Intelligence, so the matching logic
    // is unit-tested directly via matchCategory — including the malformed
    // path, which used to coerce to categories.first instead of throwing.

    func testMatchCategoryExactCaseInsensitive() throws {
        let cats = ["identity", "preference", "project"]
        XCTAssertEqual(
            try AppleFoundationModelsAdapter.matchCategory(reply: "preference", categories: cats),
            "preference")
        XCTAssertEqual(
            try AppleFoundationModelsAdapter.matchCategory(reply: "  Preference \n", categories: cats),
            "preference")
    }

    func testMatchCategoryChattyReplyThrowsInsteadOfSubstringMatching() {
        // Substring matching was removed 2026-06-10 (gpt-5.5 delta review):
        // a NEGATED reply like "not a preference" substring-matched
        // "preference" — fabrication. Chatty replies now drop the row.
        let cats = ["identity", "preference", "project"]
        XCTAssertThrowsError(
            try AppleFoundationModelsAdapter.matchCategory(
                reply: "The category is: project.", categories: cats))
        XCTAssertThrowsError(
            try AppleFoundationModelsAdapter.matchCategory(
                reply: "not a preference", categories: cats))
        // Trailing punctuation alone is still tolerated (trimmed).
        XCTAssertEqual(
            try AppleFoundationModelsAdapter.matchCategory(
                reply: "project.", categories: cats),
            "project")
    }

    func testMatchCategoryMalformedReplyThrowsInsteadOfFabricatingFirst() {
        // The first category is "identity" — the old fall-back-to-first
        // behavior would have returned it for this unusable reply.
        let cats = ["identity", "preference", "project"]
        XCTAssertThrowsError(
            try AppleFoundationModelsAdapter.matchCategory(
                reply: "I cannot determine a label for this content", categories: cats)
        ) { error in
            guard case FoundationModelsError.classificationNoMatch(let reply) = error else {
                return XCTFail("expected .classificationNoMatch, got \(error)")
            }
            XCTAssertEqual(reply, "I cannot determine a label for this content")
        }
    }

    func testMatchCategoryEmptyReplyThrows() {
        XCTAssertThrowsError(
            try AppleFoundationModelsAdapter.matchCategory(
                reply: "   \n", categories: ["identity", "preference"])
        ) { error in
            guard case FoundationModelsError.classificationNoMatch = error else {
                return XCTFail("expected .classificationNoMatch, got \(error)")
            }
        }
    }

}

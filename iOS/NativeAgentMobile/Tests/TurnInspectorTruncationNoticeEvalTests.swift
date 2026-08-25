import Foundation
import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.turninspector.truncationNotice
final class TurnInspectorTruncationNoticeEvalTests: XCTestCase {
    func testCountMismatchShowsTruncationNoticeEvenWhenWriterFlagIsFalse() throws {
        let file = try summaryFile(truncated: false, totalTurnsSeen: 7)

        XCTAssertEqual(
            TurnInspectorPresentation.contentState(for: file),
            .content(truncated: true, visibleCount: 1, totalCount: 7)
        )
        XCTAssertEqual(
            TurnInspectorPresentation.truncationNotice(visibleCount: 1, totalCount: 7),
            "Showing 1 of 7 turns (oldest dropped for sync size)."
        )
    }

    func testCompleteEnvelopeDoesNotInventATruncationWarning() throws {
        let file = try summaryFile(truncated: false, totalTurnsSeen: 1)

        XCTAssertEqual(
            TurnInspectorPresentation.contentState(for: file),
            .content(truncated: false, visibleCount: 1, totalCount: 1)
        )
        XCTAssertFalse(
            TurnInspectorPresentation.isTruncated(
                writerMarkedTruncated: false,
                visibleCount: 1,
                totalCount: 1
            )
        )
    }

    func testWriterFlagStillSurfacesATruncationWarningWhenCountsMatch() {
        XCTAssertTrue(
            TurnInspectorPresentation.isTruncated(
                writerMarkedTruncated: true,
                visibleCount: 50,
                totalCount: 50
            )
        )
    }

    func testDroppedEveryVisibleRowStillDoesNotRenderAsAnEmptyHistory() throws {
        let file = try emptySummaryFile(truncated: false, totalTurnsSeen: 7)

        XCTAssertEqual(
            TurnInspectorPresentation.contentState(for: file),
            .content(truncated: true, visibleCount: 0, totalCount: 7)
        )
    }

    private func summaryFile(truncated: Bool, totalTurnsSeen: Int) throws -> TurnSummaryFile {
        let data = Data(
            """
            {"summaries":[{"id":"turn-1","startedAt":"2026-08-24T12:00:00Z","lastAt":"2026-08-24T12:00:01Z","eventCount":3,"wallMs":1000}],"truncated":\(truncated),"totalTurnsSeen":\(totalTurnsSeen)}
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TurnSummaryFile.self, from: data)
    }

    private func emptySummaryFile(truncated: Bool, totalTurnsSeen: Int) throws -> TurnSummaryFile {
        let data = Data("{\"summaries\":[],\"truncated\":\(truncated),\"totalTurnsSeen\":\(totalTurnsSeen)}".utf8)
        return try JSONDecoder().decode(TurnSummaryFile.self, from: data)
    }
}

import Foundation
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.turninspector.truncationBanner`.
final class TurnInspectorTruncationBannerEvalTests: XCTestCase {
    func testCountMismatchInAMobileSnapshotCacheCopyRendersTheTruncationBanner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-inspector-truncation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshots = root.appendingPathComponent("mobile_snapshot_cache/snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let snapshot = snapshots.appendingPathComponent("turn_summaries.json")
        try Data(
            """
            {"summaries":[
              {"id":"turn-a","startedAt":"2026-08-24T12:00:00Z","lastAt":"2026-08-24T12:00:01Z","eventCount":3,"wallMs":1000},
              {"id":"turn-b","startedAt":"2026-08-24T12:01:00Z","lastAt":"2026-08-24T12:01:01Z","eventCount":5,"wallMs":1300}
            ],"truncated":false,"totalTurnsSeen":5}
            """.utf8
        ).write(to: snapshot, options: .atomic)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(TurnSummaryFile.self, from: Data(contentsOf: snapshot))

        XCTAssertLessThan(file.summaries.count, file.totalTurnsSeen)
        XCTAssertEqual(
            TurnInspectorPresentation.contentState(for: file),
            .content(truncated: true, visibleCount: 2, totalCount: 5)
        )
        XCTAssertEqual(
            TurnInspectorPresentation.truncationNotice(visibleCount: 2, totalCount: 5),
            "Showing 2 of 5 turns (oldest dropped for sync size)."
        )
    }

    func testInspectorRoutesTheCountDerivedTruncationStateToTheVisibleBanner() throws {
        let source = try MobileEvalSources.mobileSource("TurnInspectorView.swift")
        let view = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "TurnInspectorView", keyword: "struct", in: source)
        )

        XCTAssertTrue(view.contains("if truncated"))
        XCTAssertTrue(view.contains("TurnInspectorPresentation.truncationNotice("))
        XCTAssertTrue(view.contains("visibleCount: visibleCount"))
        XCTAssertTrue(view.contains("totalCount: totalCount"))
    }
}

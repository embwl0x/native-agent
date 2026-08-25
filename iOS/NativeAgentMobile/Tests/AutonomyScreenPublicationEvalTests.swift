import Foundation
import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.autonomy.screen
final class AutonomyScreenPublicationEvalTests: XCTestCase {
    func testUnpublishedEmptyArraysNeverRenderAsTheGreenClearState() {
        XCTAssertEqual(
            AutonomyScreenPresentation.state(actionableCount: 0, publishedAt: nil),
            .awaitingPublication
        )
    }

    func testPairedPublicationSeparatesMeasuredClearFromActionableReview() {
        let publishedAt = Date(timeIntervalSince1970: 1_725_000_000)

        XCTAssertEqual(
            AutonomyScreenPresentation.state(actionableCount: 0, publishedAt: publishedAt),
            .clear
        )
        XCTAssertEqual(
            AutonomyScreenPresentation.state(actionableCount: 3, publishedAt: publishedAt),
            .awaitingReview(3)
        )
    }

    func testBothSnapshotRefreshPathsStampOnlyAPairedSelfImprovementPublication() throws {
        let snapshotSource = try MobileEvalSources.mobileSource("iCloudSyncEngine+Snapshots.swift")
        let pairedPublication = "if bundle.trainingProposals != nil, bundle.promotionCandidates != nil"
        let pairedPublicationPattern = "(\(NSRegularExpression.escapedPattern(for: pairedPublication)))"

        XCTAssertEqual(
            MobileEvalSources.matches(pairedPublicationPattern, in: snapshotSource).count,
            2,
            "Full and targeted refreshes must each distinguish paired publication from default empty arrays."
        )
        XCTAssertEqual(
            MobileEvalSources.matches("(selfImprovementSnapshotPublishedAt = Date\\(\\))", in: snapshotSource).count,
            2
        )
    }
}

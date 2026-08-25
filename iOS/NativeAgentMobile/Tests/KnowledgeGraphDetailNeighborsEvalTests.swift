import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.kg.detailSheet.neighbors`.
///
/// A selected entity can vanish between the list snapshot and the detail
/// snapshot. That is not evidence that iCloud has failed to download data.
final class KnowledgeGraphDetailNeighborsEvalTests: XCTestCase {
    func test_missingSnapshotAndMissingEntityHaveDifferentExplanations() {
        let snapshotUnavailable = KnowledgeGraphDetailNeighborsPresentation.message(for: .snapshotStillDownloading)
        let entityUnavailable = KnowledgeGraphDetailNeighborsPresentation.message(for: .entityNoLongerPublished)

        XCTAssertEqual(snapshotUnavailable, "Knowledge graph snapshot is still downloading from iCloud.")
        XCTAssertEqual(entityUnavailable, "This entity is no longer in the published Knowledge Graph.")
        XCTAssertNotEqual(snapshotUnavailable, entityUnavailable)
    }

    func test_detailLoaderDistinguishesSnapshotAbsenceFromEntityAbsence() throws {
        let source = try MobileEvalSources.mobileSource("KnowledgeGraphView.swift")
        let loader = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "loadNeighbors() async", keyword: "private func", in: source)
        )

        XCTAssertTrue(loader.contains("guard let snapshot else"))
        XCTAssertTrue(loader.contains(".snapshotStillDownloading"))
        XCTAssertTrue(loader.contains("guard let match = snapshot.entities.first(where: { $0.id == entity.id }) else"))
        XCTAssertTrue(loader.contains(".entityNoLongerPublished"))
    }
}

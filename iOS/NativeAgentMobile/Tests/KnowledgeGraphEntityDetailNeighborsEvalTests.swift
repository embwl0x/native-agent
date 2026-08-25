import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.knowledgegraph.entityDetail.neighbors`.
final class KnowledgeGraphEntityDetailNeighborsEvalTests: XCTestCase {
    func test_entitySnapshotMismatchIsExplainedAsInconsistentDataNotDownloadDelay() {
        let reason = KnowledgeGraphDetailNeighborsPresentation.UnavailableReason.entityNoLongerPublished

        XCTAssertFalse(
            KnowledgeGraphDetailNeighborsPresentation.message(for: reason)
                .localizedCaseInsensitiveContains("downloading")
        )
        XCTAssertEqual(
            KnowledgeGraphDetailNeighborsPresentation.recoveryDetail(for: reason),
            "The list and detail snapshots disagree. Refresh the Knowledge Graph on the Mac to publish a consistent view."
        )
        XCTAssertNil(
            KnowledgeGraphDetailNeighborsPresentation.recoveryDetail(for: .snapshotStillDownloading),
            "a genuine download delay must not be mislabeled as an entity-data mismatch"
        )
    }

    func test_danglingEdgeEndpointGetsAnExplicitUnknownEntityLabel() {
        XCTAssertEqual(
            KnowledgeGraphDetailNeighborsPresentation.neighborName(
                id: "person-missing",
                publishedName: nil
            ),
            "Unknown entity (person-missing) — graph data is incomplete."
        )
        XCTAssertEqual(
            KnowledgeGraphDetailNeighborsPresentation.neighborName(
                id: "person-blank",
                publishedName: " \n"
            ),
            "Unknown entity (person-blank) — graph data is incomplete."
        )
        XCTAssertEqual(
            KnowledgeGraphDetailNeighborsPresentation.neighborName(
                id: "person-1",
                publishedName: " Agent "
            ),
            "Agent"
        )
    }

    func test_detailLoaderAndEdgeRowUseTheTypedMismatchAndNeighborPresentations() throws {
        let source = try MobileEvalSources.mobileSource("KnowledgeGraphView.swift")
        let loader = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "loadNeighbors() async", keyword: "private func", in: source)
        )

        XCTAssertTrue(loader.contains("loadUnavailableReason = reason"))
        XCTAssertTrue(loader.contains(".snapshotStillDownloading"))
        XCTAssertTrue(loader.contains(".entityNoLongerPublished"))
        XCTAssertTrue(source.contains("KnowledgeGraphDetailNeighborsPresentation.recoveryDetail(for: reason)"))
        XCTAssertTrue(source.contains("KnowledgeGraphDetailNeighborsPresentation.neighborName("))
        XCTAssertFalse(source.contains("neighbors[otherId]?.name ?? otherId"))
    }
}

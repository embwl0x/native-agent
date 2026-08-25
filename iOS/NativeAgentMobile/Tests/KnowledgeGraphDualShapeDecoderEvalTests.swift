import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.knowledgegraph.dualShapeDecoder`.
///
/// iCloud can hold either the checked SQLite projection or the complete
/// pre-SQLite dictionary snapshot while the paired Mac migrates. Both must
/// produce the same usable list model on iPhone.
final class KnowledgeGraphDualShapeDecoderEvalTests: XCTestCase {
    func test_checkedArrayProjectionKeepsPublisherPagingAndTotals() throws {
        let response = try decode(#"""
        {
          "entities": [
            {"id": "person-agent", "name": "Agent", "type": "person"}
          ],
          "edges": [
            {"from": "person-agent", "to": "project-nativeagent", "kind": "works_on", "weight": 0.9}
          ],
          "total_entities": 23,
          "total_edges": 41,
          "page": 2
        }
        """#)

        XCTAssertEqual(response.entities.map(\.id), ["person-agent"])
        XCTAssertEqual(response.total, 23)
        XCTAssertEqual(response.totalEdges, 41)
        XCTAssertEqual(response.page, 2)
        XCTAssertEqual(response.edges.first?.kind, "works_on")
    }

    func test_legacyDictionaryProjectionBackfillsBlankIDsAndNormalizesMetadata() throws {
        let response = try decode(#"""
        {
          "_commit_seq": 7,
          "version": 1,
          "entities": {
            "concept-memory": {"name": "Memory", "type": "concept"},
            "person-agent": {"id": "   ", "name": "Agent", "type": "person"}
          },
          "edges": [
            {"from": "person-agent", "to": "concept-memory", "type": "remembers"}
          ]
        }
        """#)

        XCTAssertEqual(response.entities.map(\.name), ["Agent", "Memory"])
        XCTAssertEqual(response.entities.map(\.id), ["person-agent", "concept-memory"])
        XCTAssertEqual(response.total, 2)
        XCTAssertEqual(response.totalEdges, 1)
        XCTAssertEqual(response.page, 0)
        XCTAssertEqual(response.edges.first?.kind, "remembers")
    }

    private func decode(_ snapshot: String) throws -> KGEntityResponse {
        try JSONDecoder().decode(KGEntityResponse.self, from: Data(snapshot.utf8))
    }
}

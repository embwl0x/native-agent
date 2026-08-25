import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.kg.entityDetail

@MainActor
@Suite("Knowledge Graph entity detail")
struct KnowledgeGraphEntityDetailEvalTests {
    @Test("detail renders only root-connected relationships and discloses unrelated records")
    func unrelatedEdgesAreOmittedInsteadOfBeingMisrepresentedAsEntityRelationships() throws {
        let response = try relationshipResponse(
            edges: [
                "{\"from\":\"root\",\"to\":\"neighbor\",\"type\":\"mentions\"}",
                "{\"from\":\"stale-a\",\"to\":\"stale-b\",\"type\":\"related\"}",
            ]
        )

        let visible = KnowledgeGraphPresentation.visibleRelationshipEdges(
            rootID: "root",
            response: response
        )
        let state = KnowledgeGraphPresentation.entityDetailRelationships(
            isLoading: false,
            error: nil,
            rootID: "root",
            response: response
        )

        #expect(visible.map(\.id) == ["root-neighbor-mentions"])
        #expect(state == .partial(visibleCount: 1, omittedUnrelatedCount: 1))
    }

    @Test("missing, unavailable, and malformed relationship evidence remain distinct from no relationships")
    func adverseRelationshipStatesDoNotCollapseToAnEmptyRelationshipClaim() throws {
        let empty = try relationshipResponse(edges: [])
        let unrelatedOnly = try relationshipResponse(
            edges: ["{\"from\":\"other-a\",\"to\":\"other-b\",\"type\":\"related\"}"]
        )

        #expect(KnowledgeGraphPresentation.entityDetailRelationships(
            isLoading: false,
            error: nil,
            rootID: "root",
            response: nil
        ) == .notLoaded)
        #expect(KnowledgeGraphPresentation.entityDetailRelationships(
            isLoading: false,
            error: "  ",
            rootID: "root",
            response: empty
        ) == .failed("Relationship details could not be loaded."))
        #expect(KnowledgeGraphPresentation.entityDetailRelationships(
            isLoading: false,
            error: nil,
            rootID: "root",
            response: empty
        ) == .none)
        #expect(KnowledgeGraphPresentation.entityDetailRelationships(
            isLoading: false,
            error: nil,
            rootID: "root",
            response: unrelatedOnly
        ) == .partial(visibleCount: 0, omittedUnrelatedCount: 1))
    }

    private func relationshipResponse(edges: [String]) throws -> KGNeighborsResponse {
        let body = """
        {
          "entity":{"id":"root","name":"Root","type":"concept"},
          "edges":[\(edges.joined(separator: ","))],
          "neighbors":{"neighbor":{"id":"neighbor","name":"Neighbor","type":"concept"}}
        }
        """
        return try JSONDecoder().decode(KGNeighborsResponse.self, from: Data(body.utf8))
    }
}

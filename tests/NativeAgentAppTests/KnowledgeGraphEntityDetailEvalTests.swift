import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.kg.entityDetail

@MainActor
@Suite("Knowledge Graph entity detail")
struct KnowledgeGraphEntityDetailEvalTests {
    @Test("incoming and outgoing relationship links use the existing filtered selection boundary")
    func relationshipsNavigateOnlyToVisibleConnectedNeighbors() throws {
        let response = try relationshipResponse(edges: [
            #"{"from":"root","to":"neighbor","type":"mentions"}"#,
            #"{"from":"neighbor","to":"root","type":"mentions"}"#,
            #"{"from":"other","to":"neighbor","type":"mentions"}"#,
            #"{"from":"root","to":"root","type":"mentions"}"#,
            #"{"from":"root","to":"","type":"mentions"}"#,
        ])
        let destinations = response.edges.map {
            KnowledgeGraphPresentation.relationshipNavigationDestination(
                edge: $0, rootID: "root", visibleIDs: ["root", "neighbor", "other", ""]
            )
        }
        #expect(destinations == ["neighbor", "neighbor", nil, nil, nil])

        let filteredOut = KnowledgeGraphPresentation.relationshipNavigationDestination(
            edge: response.edges[0], rootID: "root", visibleIDs: ["root"]
        )
        #expect(filteredOut == nil, "A relationship must not silently clear filters to reveal its target.")
    }

    @Test("both list and graph details expose real relationship actions and recheck current visibility")
    func relationshipActionsShareTheCanonicalSelectionOwner() throws {
        let rows = try AppSourceScraping.appSource("KnowledgeGraphRows.swift")
        let view = try AppSourceScraping.appSource("KnowledgeGraphView.swift")
        #expect(rows.contains("Button { onSelectEntity(destination) }"))
        #expect(rows.contains(".accessibilityLabel(\"Show entity \\(otherName)\")"))
        #expect(rows.contains("relationshipContent(isLink: false)"))
        #expect(view.components(separatedBy: "onSelectEntity: selectRelatedEntity").count - 1 == 2)
        #expect(view.contains("private func selectRelatedEntity(_ id: String)"))
        #expect(view.contains("id, visibleIDs: displayedEntityIDs"))
        #expect(view.contains("selectedId = destination"))
    }

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

import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.kg.searchAndTypeFilter

@MainActor
@Suite("Knowledge Graph search and type filter")
struct KnowledgeGraphSearchTypeFilterEvalTests {
    private func entity(_ id: String, _ name: String, _ type: String) throws -> KGEntity {
        let data = Data("""
        {"id":"\(id)","name":"\(name)","type":"\(type)","summary":"\(name) summary"}
        """.utf8)
        return try JSONDecoder().decode(KGEntity.self, from: data)
    }

    @Test("incompatible single-type and multi-kind filters are disclosed rather than rendered as an empty graph")
    func incompatibleFiltersHaveAnExplicitRecoveryState() throws {
        let entities = [
            try entity("person", "Agent", "person"),
            try entity("project", "NativeAgent", "project"),
        ]
        let kinds: Set<String> = ["project"]
        let visible = KnowledgeGraphPresentation.filteredEntities(
            entities,
            filterType: "person",
            selectedKinds: kinds,
            cutoff: nil,
            query: ""
        )
        let conflict = KnowledgeGraphFilterConflict.resolve(
            filterType: "person",
            selectedKinds: kinds
        )

        #expect(visible.isEmpty)
        #expect(conflict == .incompatible(type: "person", kinds: ["project"]))
        #expect(conflict.message == "Type Person conflicts with kind filter Project.")

        let recovered = KnowledgeGraphPresentation.filteredEntities(
            entities,
            filterType: "person",
            selectedKinds: [],
            cutoff: nil,
            query: "agent"
        )
        #expect(recovered.map(\.id) == ["person"])
        #expect(KnowledgeGraphFilterConflict.resolve(filterType: "person", selectedKinds: []) == .none)
    }

    @Test("the shared filter catalog includes every selectable organization and fact kind")
    func organizationAndFactAreSearchableSelectableAndRenderable() throws {
        let entities = [
            try entity("organization", "OpenAI", "organization"),
            try entity("fact", "Agent uses Swift", "fact"),
        ]

        #expect(KnowledgeGraphFilterCatalog.entityTypes.contains("organization"))
        #expect(KnowledgeGraphFilterCatalog.selectableKinds.contains("organization"))
        #expect(KnowledgeGraphFilterCatalog.entityTypes.contains("fact"))
        #expect(KnowledgeGraphFilterCatalog.selectableKinds.contains("fact"))
        #expect(KGEntityRow.typeIcon("organization") != "circle")
        #expect(KGEntityRow.typeIcon("fact") != "circle")

        let fact = KnowledgeGraphPresentation.filteredEntities(
            entities,
            filterType: "fact",
            selectedKinds: ["fact"],
            cutoff: nil,
            query: "swift"
        )
        #expect(fact.map(\.id) == ["fact"])
    }
}

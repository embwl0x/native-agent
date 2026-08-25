import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / logic.kg.selectionSync

@MainActor
@Suite("Knowledge Graph selection synchronization")
struct KnowledgeGraphSelectionSyncEvalTests {
    private func entity(_ id: String, _ name: String, _ type: String) throws -> KGEntity {
        let data = Data("""
        {"id":"\(id)","name":"\(name)","type":"\(type)"}
        """.utf8)
        return try JSONDecoder().decode(KGEntity.self, from: data)
    }

    @Test("a filter removal clears selection once and the detail selection follows it")
    func filteredOutSelectionClearsOnceWithoutAStaleDetail() throws {
        let entities = [
            try entity("agent", "Agent", "person"),
            try entity("nativeagent", "NativeAgent", "project"),
        ]
        let initiallyVisibleIDs = visibleIDs(in: entities, filterType: "all")
        let selectedID = "agent"

        #expect(KnowledgeGraphPresentation.reconcileSelection(
            selectedID, visibleIDs: initiallyVisibleIDs
        ) == .retained("agent"))

        let projectIDs = visibleIDs(in: entities, filterType: "project")
        let reconciliation = KnowledgeGraphPresentation.reconcileSelection(
            selectedID, visibleIDs: projectIDs
        )
        #expect(reconciliation == .cleared("agent"))
        #expect(reconciliation.selectedID == nil)

        // This is the value the view's on-change handler assigns. A second
        // reconciliation sees the already-cleared selection rather than
        // reporting another removal.
        #expect(KnowledgeGraphPresentation.reconcileSelection(
            reconciliation.selectedID, visibleIDs: projectIDs
        ) == .alreadyEmpty)
    }

    @Test("a visible selection is retained across an unrelated filter update")
    func visibleSelectionRemainsStable() throws {
        let entities = [
            try entity("agent", "Agent", "person"),
            try entity("nativeagent", "NativeAgent", "project"),
        ]
        let matchingIDs = visibleIDs(
            in: entities,
            filterType: "all",
            query: "native"
        )
        let reconciliation = KnowledgeGraphPresentation.reconcileSelection(
            "nativeagent", visibleIDs: matchingIDs
        )

        #expect(reconciliation == .retained("nativeagent"))
        #expect(reconciliation.selectedID == "nativeagent")
        #expect(matchingIDs.contains(reconciliation.selectedID ?? ""))
    }

    private func visibleIDs(
        in entities: [KGEntity],
        filterType: String,
        query: String = ""
    ) -> Set<String> {
        Set(KnowledgeGraphPresentation.filteredEntities(
            entities,
            filterType: filterType,
            selectedKinds: [],
            cutoff: nil,
            query: query
        ).map(\.id))
    }
}

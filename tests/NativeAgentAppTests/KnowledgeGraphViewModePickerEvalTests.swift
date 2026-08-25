import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.kg.viewModePicker

@MainActor
@Suite("Knowledge Graph view-mode picker")
struct KnowledgeGraphViewModePickerEvalTests {
    @Test("Every picker mode round-trips through the canonical persisted preference")
    func allPickerModesPersistAndReload() {
        let suiteName = "KnowledgeGraphViewModePickerEvalTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(KGViewModePickerPreference.load(from: defaults) == .list)
        for mode in KGViewMode.allCases {
            let selected = KGViewModePickerState(persistedValue: mode.rawValue)
            #expect(selected.selectedMode == mode)
            KGViewModePickerPreference.save(selected.selectedMode, in: defaults)
            #expect(KGViewModePickerPreference.load(from: defaults) == mode)
            #expect(selected.selecting(mode).persistedValue == mode.rawValue)
        }

        defaults.set("not-a-mode", forKey: KGViewModePickerPreference.key)
        #expect(KGViewModePickerPreference.load(from: defaults) == .list,
                "an invalid saved picker value must recover to List, not create an untagged selection")
    }

    @Test("Graph selection routes to the graph when its displayed result is within the safe renderer bound")
    func graphSelectionWithinBoundProducesGraphWithoutFallbackNotice() throws {
        let mode = KGViewModePickerState(persistedValue: KGViewMode.graph.rawValue).selectedMode
        let displayed = try entities(count: KGViewModePickerPresentation.maximumGraphEntities)
        let renderedCount = KGGraphCanvasLayout.canonicalEntities(displayed).count

        #expect(KGViewModePickerPresentation.pickerNotice(
            requested: mode,
            displayedEntityCount: renderedCount
        ) == nil)
        #expect(KGViewModePickerPresentation.route(
            requested: mode,
            displayedEntityCount: renderedCount
        ) == .graph)
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: nil,
            entityCount: displayed.count,
            displayedEntityCount: displayed.count,
            renderableGraphEntityCount: renderedCount,
            isEnabled: true,
            viewMode: mode
        ) == .graph)
    }

    @Test("An oversized Graph request is disclosed and actually routes to the list safety fallback")
    func oversizedGraphSelectionCannotClaimAGraphWasRendered() throws {
        var picker = KGViewModePickerState(persistedValue: KGViewMode.graph.rawValue)
        let displayed = try entities(count: KGViewModePickerPresentation.maximumGraphEntities + 1)
        let renderedCount = KGGraphCanvasLayout.canonicalEntities(displayed).count

        let notice = try #require(KGViewModePickerPresentation.pickerNotice(
            requested: picker.selectedMode,
            displayedEntityCount: renderedCount
        ))
        #expect(notice.contains("list is displayed instead"))
        #expect(KGViewModePickerPresentation.route(
            requested: picker.selectedMode,
            displayedEntityCount: renderedCount
        ) == .graphSafetyFallback(entityCount: 201))
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: nil,
            entityCount: displayed.count,
            displayedEntityCount: displayed.count,
            renderableGraphEntityCount: renderedCount,
            isEnabled: true,
            viewMode: picker.selectedMode
        ) == .graphSafetyNet(count: 201))

        picker = picker.selecting(.list)
        #expect(KGViewModePickerPresentation.pickerNotice(
            requested: picker.selectedMode,
            displayedEntityCount: renderedCount
        ) == nil)
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: nil,
            entityCount: displayed.count,
            displayedEntityCount: displayed.count,
            renderableGraphEntityCount: renderedCount,
            isEnabled: true,
            viewMode: picker.selectedMode
        ) == .list)
    }

    // EVAL FENCE: app.mind / ui.kg.graphSafetyNet
    @Test("the mounted graph route uses the canvas's canonical participant count and recovers when filters narrow it")
    func graphSafetyNetTracksCanonicalParticipantsAndFilterRecovery() throws {
        let mode = KGViewModePickerState(persistedValue: KGViewMode.graph.rawValue).selectedMode
        let duplicateParticipantRows = try entities(count: KGViewModePickerPresentation.maximumGraphEntities)
            + [try JSONDecoder().decode(
                KGEntity.self,
                from: Data("{\"id\":\"entity-0\",\"name\":\"Duplicate\",\"type\":\"concept\"}".utf8)
            )]
        let duplicateRenderableCount = KGGraphCanvasLayout.canonicalEntities(duplicateParticipantRows).count

        #expect(duplicateParticipantRows.count == KGViewModePickerPresentation.maximumGraphEntities + 1)
        #expect(duplicateRenderableCount == KGViewModePickerPresentation.maximumGraphEntities)
        #expect(KGViewModePickerPresentation.pickerNotice(
            requested: mode,
            displayedEntityCount: duplicateRenderableCount
        ) == nil)
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: nil,
            entityCount: duplicateParticipantRows.count,
            displayedEntityCount: duplicateParticipantRows.count,
            renderableGraphEntityCount: duplicateRenderableCount,
            isEnabled: true,
            viewMode: mode
        ) == .graph)

        let oversizedRows = try entities(count: KGViewModePickerPresentation.maximumGraphEntities + 1)
        let oversizedRenderableCount = KGGraphCanvasLayout.canonicalEntities(oversizedRows).count
        #expect(KGViewModePickerPresentation.pickerNotice(
            requested: mode,
            displayedEntityCount: oversizedRenderableCount
        ) != nil)
        let narrowedRows = KnowledgeGraphPresentation.filteredEntities(
            oversizedRows,
            filterType: "all",
            selectedKinds: [],
            cutoff: nil,
            query: "Entity 0"
        )
        let narrowedRenderableCount = KGGraphCanvasLayout.canonicalEntities(narrowedRows).count
        #expect(narrowedRenderableCount == 1)
        #expect(KGViewModePickerPresentation.pickerNotice(
            requested: mode,
            displayedEntityCount: narrowedRenderableCount
        ) == nil)
    }

    private func entities(count: Int) throws -> [KGEntity] {
        try (0..<count).map { index in
            try JSONDecoder().decode(
                KGEntity.self,
                from: Data("{\"id\":\"entity-\(index)\",\"name\":\"Entity \(index)\",\"type\":\"concept\"}".utf8)
            )
        }
    }
}

import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.kg.staleDataBanner

@MainActor
@Suite("Knowledge Graph stale-data banner")
struct KnowledgeGraphStaleDataBannerEvalTests {
    @Test("every error state is visible, while stale is reserved for retained graph-load data")
    func errorsRemainVisibleAcrossEmptyRetainedAndLoadingStates() {
        let error = "Knowledge graph store could not be read"

        for loading in [false, true] {
            #expect(KnowledgeGraphPresentation.errorPlacement(
                isLoading: loading,
                error: error,
                entityCount: 0,
                errorOrigin: .graphLoad
            ) == .emptyState(error))
            #expect(KnowledgeGraphPresentation.content(
                isLoading: loading,
                error: error,
                entityCount: 0,
                displayedEntityCount: 0,
                isEnabled: true,
                viewMode: .list
            ) == .unavailable(error),
            "a set error must not be replaced by a healthy empty state or a spinner")

            #expect(KnowledgeGraphPresentation.errorPlacement(
                isLoading: loading,
                error: error,
                entityCount: 2,
                errorOrigin: .graphLoad
            ) == .retainedDataBanner(message: error, isStale: true))
            #expect(KnowledgeGraphPresentation.content(
                isLoading: loading,
                error: error,
                entityCount: 2,
                displayedEntityCount: 2,
                isEnabled: true,
                viewMode: .list
            ) == .list,
            "retained rows remain visible under their stale banner during a retry")

            #expect(KnowledgeGraphPresentation.errorPlacement(
                isLoading: loading,
                error: error,
                entityCount: 2,
                errorOrigin: .maintenance
            ) == .retainedDataBanner(message: error, isStale: false))
        }
    }

    @Test("a fresh empty load without an error remains a loading state")
    func emptyLoadingDoesNotInventAnError() {
        #expect(KnowledgeGraphPresentation.errorPlacement(
            isLoading: true,
            error: nil,
            entityCount: 0,
            errorOrigin: nil
        ) == .none)
        #expect(KnowledgeGraphPresentation.content(
            isLoading: true,
            error: nil,
            entityCount: 0,
            displayedEntityCount: 0,
            isEnabled: true,
            viewMode: .list
        ) == .loading)
    }
}

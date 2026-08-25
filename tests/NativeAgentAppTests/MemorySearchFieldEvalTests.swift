import Foundation
import MemoryV2
import Testing
@testable import NativeAgentApp

private func memorySearchTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("memory-search-field-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Memory search field — canonical reader and visible states")
struct MemorySearchFieldEvalTests {
    private struct SearchFixture: Equatable {
        let id: String
        let text: String
        let layer: String
    }

    @Test("an isolated app search reads the same injected canonical memory store as its visible list")
    @MainActor
    func searchUsesTheInjectedMemoryRoot() async throws {
        let root = try memorySearchTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        _ = try await storage.insertMemory(StoredMemory(
            id: "isolated-memory",
            content: "The isolated workspace keeps the amber lighthouse preference."
        ))

        let client = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        let visible = try await client.getMemories()
        #expect(visible.map(\.id) == ["isolated-memory"])

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        app.memories = visible
        await app.runMemorySemanticSearch(query: "amber lighthouse")
        #expect(app.memorySearchResults?.map(\.id) == ["isolated-memory"],
                "the search result must come from the same injected root as the rendered memory list")
    }

    @Test("search presentation does not turn pending, stale, or unavailable work into no matches")
    func searchStatesRemainHonest() {
        #expect(!MemorySearchPresentation.matchesCurrentQuery(
            "new query", resultQuery: "old query"))
        #expect(MemorySearchPresentation.resolve(
            query: "new query", resultCount: 0, isLoading: true, error: nil
        ) == .searching)
        #expect(MemorySearchPresentation.resolve(
            query: "new query", resultCount: 0, isLoading: false,
            error: "Semantic memory is unavailable; showing text matches only."
        ) == .unavailable("Semantic memory is unavailable; showing text matches only."))
        #expect(MemorySearchPresentation.resolve(
            query: "new query", resultCount: 0, isLoading: false, error: nil
        ) == .empty)
    }

    // app.mind / ui.memory.search.semanticRecall
    @Test("empty and stale semantic arrays cannot suppress the current query's lexical fallback")
    func semanticResultsAreUsedOnlyForTheirCurrentNonemptyQuery() {
        let records = [
            SearchFixture(id: "amber", text: "Keep the amber lighthouse preference.", layer: "semantic"),
            SearchFixture(id: "budget", text: "Review the project budget.", layer: "episodic"),
        ]
        let lexicalMatch: (SearchFixture, String) -> Bool = { record, lower in
            record.text.lowercased().contains(lower) || record.layer.lowercased().contains(lower)
        }

        let emptySemantic = MemorySearchPresentation.displayedRecords(
            records,
            query: "amber",
            semanticResults: [],
            resultQuery: "amber",
            lexicalMatch: lexicalMatch
        )
        #expect(emptySemantic.map(\.id) == ["amber"],
                "an empty semantic response must not turn an obvious text match into No Matches")

        let staleSemantic = MemorySearchPresentation.displayedRecords(
            records,
            query: "amber",
            semanticResults: [records[1]],
            resultQuery: "project budget",
            lexicalMatch: lexicalMatch
        )
        #expect(staleSemantic.map(\.id) == ["amber"],
                "a nonempty response for an older query must not render under newer keystrokes")

        let currentSemantic = MemorySearchPresentation.displayedRecords(
            records,
            query: " amber ",
            semanticResults: [records[1]],
            resultQuery: "amber",
            lexicalMatch: lexicalMatch
        )
        #expect(currentSemantic.map(\.id) == ["budget"],
                "a nonempty result is allowed only after query identity is established")
    }
}

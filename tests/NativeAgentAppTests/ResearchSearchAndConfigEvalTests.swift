import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.research.searchAndConfig

@MainActor
@Suite("Research search and configuration", .serialized)
struct ResearchSearchAndConfigEvalTests {
    private enum FixtureError: LocalizedError {
        case unavailable

        var errorDescription: String? { "Fixture research service is unavailable" }
    }

    @Test("the research owner persists normalized configuration on its root, refuses malformed replacement, and keeps search outcomes honest")
    func configurationAndSearchUseOneRootAndPreserveTheLastGoodResultOnFailure() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        try await client.configureSearXNG(baseURL: "  HTTPS://Search.EXAMPLE.test/searx/  ")
        let configURL = root.appendingPathComponent("research/config.json")
        let savedConfig = try String(contentsOf: configURL, encoding: .utf8)
        #expect(savedConfig.contains("https://search.example.test/searx"))

        do {
            try await client.configureSearXNG(baseURL: "ftp://search.example.test")
            Issue.record("A non-http SearXNG URL must not replace the saved configuration.")
        } catch {
            #expect(error.localizedDescription.contains("http:// or https://"))
        }
        #expect(try String(contentsOf: configURL, encoding: .utf8) == savedConfig)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let result = ResearchResult(
            title: "Grounded result",
            url: "https://result.example.test",
            snippet: "fixture receipt",
            source: "fixture"
        )
        let successfulSearch = await app.search("  durable query  ") { query in
            #expect(query == "durable query")
            return [result]
        }
        guard case .success(let rows) = successfulSearch else {
            Issue.record("The configured research action should expose its successful result.")
            return
        }
        #expect(rows == [result])

        let failedSearch = await app.search("second query") { _ in
            throw FixtureError.unavailable
        }
        guard case .failure(.requestFailed(let failure)) = failedSearch else {
            Issue.record("The unavailable search must return a typed failure.")
            return
        }
        #expect(failure == "Fixture research service is unavailable")
        #expect(app.researchResults == [result], "A failed request must not impersonate an empty successful search.")
    }

    @Test("configuration presentation reports absent and malformed service URLs without enabling a deceptive save")
    func configurationPresentationMakesUnavailableAndInvalidStatesDistinct() {
        let absent = ResearchSearchConfigurationPresentation.resolve(
            baseURL: "", status: .idle, isSaving: false)
        #expect(absent.statusText == "No search service configured.")
        #expect(absent.validationError == nil)
        #expect(!absent.canSave)

        let malformed = ResearchSearchConfigurationPresentation.resolve(
            baseURL: "ftp://bad.example.test", status: .idle, isSaving: false)
        #expect(malformed.validationError?.contains("http:// or https://") == true)
        #expect(!malformed.canSave)
        #expect(!ResearchSearchConfigurationPresentation.canSubmit(query: "  ", isSearching: false))
        #expect(ResearchSearchConfigurationPresentation.canSubmit(query: "actual query", isSearching: false))
        #expect(!ResearchSearchConfigurationPresentation.canSubmit(query: "actual query", isSearching: true))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-search-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

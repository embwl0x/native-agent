import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.research.autodetectAndStatusText

@MainActor
@Suite("Research autodetect status isolation", .serialized)
struct ResearchAutodetectAndStatusTextEvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-autodetect-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("root-scoped discovery maps usable and unusable responses into the Research-owned outcome")
    func autodetectOutcomesAreRootScopedAndRejectUnusableResponses() throws {
        let root = try root("outcomes")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        app.searxngBaseURL = ""

        let found = app.applySearXNGAutodetect(DetectSearXNGResponse(
            found: true,
            baseURL: " HTTPS://Search.EXAMPLE.test/searx/ ",
            source: "fixture",
            error: nil
        ))
        #expect(found == .found("https://search.example.test/searx"))
        #expect(app.searxngBaseURL == "https://search.example.test/searx")
        #expect(ResearchSearchServicePresentation.text(
            baseURL: app.searxngBaseURL,
            status: .autodetect(found)
        ) == "SearXNG found: https://search.example.test/searx")

        let unavailable = app.applySearXNGAutodetect(DetectSearXNGResponse(
            found: false,
            baseURL: nil,
            source: nil,
            error: "Docker is unavailable"
        ))
        #expect(unavailable == .notFound("Docker is unavailable"))
        #expect(app.searxngBaseURL == "https://search.example.test/searx")
        #expect(ResearchSearchServicePresentation.text(
            baseURL: app.searxngBaseURL,
            status: .autodetect(unavailable)
        ) == "SearXNG not found: Docker is unavailable")

        let malformed = app.applySearXNGAutodetect(DetectSearXNGResponse(
            found: true,
            baseURL: "ftp://not-a-search-service.example.test",
            source: "fixture",
            error: nil
        ))
        guard case .failed(let detail) = malformed else {
            Issue.record("A discovered non-http URL must be reported as a failure.")
            return
        }
        #expect(detail.contains("invalid URL"))
        #expect(app.searxngBaseURL == "https://search.example.test/searx")
        #expect(ResearchSearchServicePresentation.text(
            baseURL: app.searxngBaseURL,
            status: .autodetect(malformed)
        ).contains("SearXNG detection failed:"))
    }

    @Test("Research status presentation distinguishes unavailable, failure, and ready states")
    func statusPresentationDistinguishesUnavailableFailureAndReadyStates() {
        #expect(ResearchSearchServicePresentation.text(
            baseURL: "https://search.example.test",
            status: .idle
        ) == "Search service configured.")
        #expect(ResearchSearchServicePresentation.text(
            baseURL: "",
            status: .idle
        ) == "No search service configured.")
        #expect(ResearchSearchServicePresentation.text(
            baseURL: "https://search.example.test",
            status: .autodetect(.notFound("Docker is unavailable"))
        ) == "SearXNG not found: Docker is unavailable")
        #expect(ResearchSearchServicePresentation.text(
            baseURL: "https://search.example.test",
            status: .autodetect(.failed("response was malformed"))
        ) == "SearXNG detection failed: response was malformed")
    }
}

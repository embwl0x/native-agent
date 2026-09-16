import Foundation
import PersistenceCore
import Testing
import Research
import NativeAgentCore
import ProviderRouting
import MacIntegration
@testable import ChatOrchestration

private struct FixturePageHTTP: ResearchHTTPClient {
    func get(url: URL, timeout: TimeInterval) async throws -> (Int, Data, String?) {
        #expect(url.absoluteString == "https://example.org/fixture")
        return (200, Data("<html><body><h1>Fixture page</h1><p>Readable public text.</p></body></html>".utf8), "text/html")
    }
}

@Suite struct ReadPageToolTests {
    @Test func readerToolReturnsFixtureText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = SwiftNativeResearchClient(dataRoot: root, http: FixturePageHTTP())
        let dispatcher = SwiftToolDispatcher(dataRoot: root, pageReader: reader, enforceLazyToolLoading: false)
        let schemas = try await dispatcher.listAvailableToolSchemas()
        #expect(schemas.contains { $0.name == "read_page" })
        #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("read_page"))
        let result = try await dispatcher.dispatch(tool: "read_page",
            input: ["url": .string("https://example.org/fixture")], surface: "bot")
        guard case .object(let record) = result, case .string(let text)? = record["text"] else {
            Issue.record("Missing page text"); return
        }
        #expect(text.contains("Fixture page") && text.contains("Readable public text."))
        #expect(!text.contains("<html>"))
        #expect(record["url"] == .string("https://example.org/fixture"))
    }

    @Test func unattendedURLPreloadChoosesReader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for surface in ["bot", "background"] {
            let prediction = try #require(ToolPreloadHeuristics.predict(
                userMessage: "Read https://example.org/fixture", surface: surface))
            #expect(prediction.candidateTools.contains("read_page"))
            #expect(!prediction.candidateTools.contains { $0.hasPrefix("browser") })
            let outcome = await ToolPreloadHeuristics.preloadOutcome(prediction: prediction,
                sessionId: "fixture", activeTools: [], availableToolNames: ["read_page"],
                surface: surface, store: ActiveToolsStore(dataRoot: root),
                permissions: MacIntegrationPermissionStore(dataRoot: root), dataRoot: root)
            #expect(outcome.activeTools.contains("read_page"))
        }
        let chat = try #require(ToolPreloadHeuristics.predict(userMessage: "Read https://example.org/fixture"))
        #expect(chat.candidateTools.contains("browser.read_text"))
    }
    @Test(arguments: ["complete", "partial", "unsupported", "legacy"])
    func sourceReadOutcomeIsClassifiedWithoutInventingSuccess(kind: String) {
        let complete = kind == "complete"
        let unsupported = kind == "unsupported"
        let coverage: JSONValue? = kind == "legacy" ? nil : .object([
            "http_status": .int(200),
            "extraction_status": .string(unsupported ? "unsupported_content_type" : "html_text"),
            "complete": .bool(complete),
        ])
        let record = ResearchFetchRecord(id: "source", url: "https://page.example/", text: unsupported ? "" : "Readable text",
            createdAt: "date", coverage: coverage)
        let result = record.toJSON()
        let expected: ChatToolOutcome.ExactResultClass = complete ? .succeeded : (unsupported ? .failed : .unknown)
        #expect(ChatToolOutcome.exactResultClass(result) == expected)
        guard case .object(let object) = result else { Issue.record("Missing record"); return }
        if kind == "legacy" { #expect(object["status"] == nil) }
        if kind == "partial" { #expect(object["status"] == .string("partial")) }
        if unsupported {
            #expect(object["reason"] == .string("unsupported_content_type"))
            guard case .object(let details)? = object["coverage"] else { Issue.record("Missing coverage"); return }
            #expect(details["http_status"] == .int(200), "Transport success remains separate from extraction failure")
        }
    }

}

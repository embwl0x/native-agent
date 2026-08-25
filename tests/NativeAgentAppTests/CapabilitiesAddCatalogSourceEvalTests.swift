import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.settings · Capabilities add catalog source", .serialized)
struct CapabilitiesAddCatalogSourceEvalTests {
    @Test("the real add action writes and rereads only the injected catalog root")
    func addCatalogSourceUsesInjectedRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capability-catalog-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        let outcome = await app.addCatalogSource(
            name: "Isolated Local Source",
            url: "/tmp/nativeagent-catalog"
        )
        guard case let .saved(source) = outcome else {
            Issue.record("the real catalog write did not save and reread: \(outcome)")
            return
        }
        #expect(source.id == "isolated-local-source")
        #expect(app.capabilityCatalogSources.contains { $0.id == source.id })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog/sources/sources.json").path))

        let reloaded = try await NativeClient(baseURL: "", dataRootOverride: root).getCapabilityCatalogSources()
        #expect(reloaded.contains { $0.id == source.id && $0.url == "/tmp/nativeagent-catalog" })
    }

    @Test("catalog-source input is normalized into the saved source presentation contract")
    func addCatalogSourceNormalizesTheVisibleSavedSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capability-catalog-normalized-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        let outcome = await app.addCatalogSource(
            name: "  Normalized Source  ",
            url: "  /tmp/normalized-catalog  "
        )
        let source: CapabilityCatalogSource
        guard case .saved(let saved) = outcome else {
            Issue.record("the production catalog-source add route did not save: \(outcome)")
            return
        }
        source = saved

        // `id`, status, and detail are the presentation contract the view uses
        // after its Add Source action completes; assert them from the real
        // route instead of scraping an unrealized AppKit accessibility tree.
        #expect(source.id == "normalized-source")
        #expect(source.name == "Normalized Source")
        #expect(source.url == "/tmp/normalized-catalog")
        #expect(outcome.didSave)
        #expect(outcome.status == "ok")
        #expect(outcome.detail == "Saved Normalized Source.")
        #expect(app.capabilityCatalogSources.contains(source))
    }

    @Test("blank and concurrent saves remain explicit adverse outcomes")
    func addCatalogSourceNamesRefusalAndAvailability() async {
        let app = AppModel(dataRootOverride: FileManager.default.temporaryDirectory, startBackgroundTasks: false)
        let refused = await app.addCatalogSource(name: "  ", url: "\n")
        #expect(refused == .refused("Enter a source name or URL before adding it."))

        app.capabilityCatalogSourceSaveInFlight = true
        let unavailable = await app.addCatalogSource(name: "Source", url: "/tmp/source")
        #expect(unavailable == .unavailable("A catalog source is already being saved."))
    }
}

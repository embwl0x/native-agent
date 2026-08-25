import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / appmodel.settings.baseURLs
@MainActor
@Suite("AppModel base-URL settings", .serialized)
struct AppModelBaseURLSettingsEvalTests {
    @Test("native compatibility URL normalizes, persists, reloads, and preserves the prior value on malformed input")
    func nativeBaseURLCommitBoundary() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: NativeBaseURLDefaults.key)
        defer { restore(previous, key: NativeBaseURLDefaults.key, defaults: defaults) }
        defaults.removeObject(forKey: NativeBaseURLDefaults.key)

        let model = AppModel(startBackgroundTasks: false)
        let saved = try model.configureNativeBaseURL(" HTTP://LOCALHOST:8123/api/ ")
        #expect(saved == "http://localhost:8123/api")
        #expect(model.nativeBaseURL == saved)
        #expect(model.client.baseURL == saved)
        #expect(NativeBaseURLDefaults.read() == saved)

        #expect(throws: NativeBaseURLDefaults.ValidationError.invalidBaseURL) {
            try model.configureNativeBaseURL("https://user:password@example.invalid/?query=not-allowed")
        }
        #expect(model.nativeBaseURL == saved)
        #expect(NativeBaseURLDefaults.read() == saved)

        let reloaded = AppModel(startBackgroundTasks: false)
        #expect(reloaded.nativeBaseURL == saved)
        #expect(reloaded.client.baseURL == saved)
    }

    @Test("SearXNG saves through the mounted root and a rejected URL keeps the last committed configuration")
    func searxngCommitBoundary() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "searxngBaseURL")
        defer { restore(previous, key: "searxngBaseURL", defaults: defaults) }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        model.searxngBaseURL = "https://previous.example"

        let saved = try await model.saveSearXNGBaseURL(" https://SEARCH.EXAMPLE:8443/base/ ")
        #expect(saved == "https://search.example:8443/base")
        #expect(model.searxngBaseURL == saved)
        let path = root.appendingPathComponent("research/config.json")
        let committed = try Data(contentsOf: path)
        #expect(String(data: committed, encoding: .utf8)?.contains("https://search.example:8443/base") == true)

        await #expect(throws: (any Error).self) {
            try await model.saveSearXNGBaseURL("file:///private/tmp/not-a-search-service")
        }
        #expect(model.searxngBaseURL == saved)
        #expect(try Data(contentsOf: path) == committed)

        #expect(model.applyRefreshedSearXNGBaseURL(" HTTPS://REFRESH.EXAMPLE/next/ "))
        #expect(model.searxngBaseURL == "https://refresh.example/next")
        #expect(!model.applyRefreshedSearXNGBaseURL("not-a-url"))
        #expect(model.searxngBaseURL == "https://refresh.example/next")
        #expect(model.statusText.contains("SearXNG configuration unavailable"))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-base-url-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

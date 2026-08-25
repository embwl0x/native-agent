import Foundation
import Testing
@testable import PersistenceCore
@testable import ProviderRouting

@Suite("Feeds reports-only wave 2 provider", .serialized)
struct FeedsReportsOnlyWave2ProviderTests {
    @Test("feeds.providers.openrouter_models_cache refreshes a stale configured catalog on the TTL path")
    func openRouterCacheRefreshesStaleConfiguredCatalogOnTTLPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feeds-wave2-openrouter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("providers/openrouter-models-cache.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date()
        let staleStamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-48 * 60 * 60))
        try Data(#"{"api_key":"configured-test-key"}"#.utf8).write(to: root.appendingPathComponent("providers/openrouter.json"))
        try Data("{\"schema_version\":1,\"updated_at\":\"\(staleStamp)\",\"models\":[{\"id\":\"vendor/retired\",\"name\":\"Retired\",\"context_length\":32768},{\"id\":\"vendor/old\",\"name\":\"Old\",\"context_length\":32768}]}".utf8).write(to: cache)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-48 * 60 * 60)], ofItemAtPath: cache.path)
        #expect(LLMCredentialResolver.resolveAPIKey(envVar: "OPENROUTER_API_KEY", providerConfigFile: "openrouter.json", dataRoot: root, includeEnvironment: false) == "configured-test-key")
        let stale = try JSONValue.parse(Data(contentsOf: cache))
        guard case .object(let staleObject) = stale,
              case .array(let staleRows)? = staleObject["models"] else {
            Issue.record("configured OpenRouter cache fixture did not contain feed rows")
            return
        }
        #expect(staleRows.count == 2)
        #expect(OpenRouterModelCatalog.cachedAvailability(of: "vendor/retired", dataRoot: root, now: now) == .unknown)
        #expect(OpenRouterModelCatalog.cacheIsStale(dataRoot: root, now: now))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Wave2OpenRouterProtocol.self]
        let refreshed = await OpenRouterModelCatalog.models(
            dataRoot: root,
            session: URLSession(configuration: configuration),
            refresh: false
        )
        #expect(refreshed.map(\.id) == ["vendor/current"])
        #expect(OpenRouterModelCatalog.cachedAvailability(of: "vendor/current", dataRoot: root) == .available)
        #expect(OpenRouterModelCatalog.cachedAvailability(of: "vendor/retired", dataRoot: root) == .unavailable)

        let rewritten = try JSONValue.parse(Data(contentsOf: cache))
        let cacheMetadata = try cache.resourceValues(forKeys: [.contentModificationDateKey])
        guard case .object(let object) = rewritten,
              case .string(let updatedAt)? = object["updated_at"],
              (ISO8601DateFormatter().date(from: updatedAt) ?? .distantPast) > now.addingTimeInterval(-60 * 60),
              case .array(let rows)? = object["models"],
              rows.count == 1,
              case .object(let row)? = rows.first,
              row["id"] == .string("vendor/current"),
              (cacheMetadata.contentModificationDate ?? .distantPast) > now.addingTimeInterval(-60 * 60) else {
            Issue.record("the live OpenRouter refresh did not replace the stale cache feed")
            return
        }
    }
}

private final class Wave2OpenRouterProtocol: URLProtocol, @unchecked Sendable {
    private static let response = Data(#"{"data":[{"id":"vendor/current","name":"Current","context_length":65536,"architecture":{"output_modalities":["text"]}}]}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer configured-test-key"
        let response = HTTPURLResponse(url: request.url!, statusCode: authorized ? 200 : 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if authorized { client?.urlProtocol(self, didLoad: Self.response) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

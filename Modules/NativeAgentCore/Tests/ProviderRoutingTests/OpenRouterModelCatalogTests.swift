import Foundation
import Testing
@testable import ProviderRouting

@Test func OpenRouterModelCatalog_parseModelsResponse_filtersAndMapsLiveShape() throws {
    let data = Data("""
    {
      "data": [
        {
          "id": "google/gemini-test",
          "name": "Gemini Test",
          "context_length": 1048576,
          "architecture": {
            "input_modalities": ["text", "image"],
            "output_modalities": ["text"],
            "modality": "text+image->text"
          },
          "pricing": {
            "prompt": "0.00000125",
            "completion": "0.00001"
          },
          "supported_parameters": ["tools", "tool_choice", "response_format"]
        },
        {
          "id": "~hidden/internal",
          "name": "Hidden",
          "context_length": 8192,
          "architecture": {"output_modalities": ["text"]},
          "supported_parameters": []
        },
        {
          "id": "embedding/model",
          "name": "Embedding",
          "context_length": 8192,
          "architecture": {"output_modalities": ["embeddings"]},
          "supported_parameters": []
        }
      ]
    }
    """.utf8)

    let models = try OpenRouterModelCatalog.parseModelsResponse(data)

    #expect(models.map(\.id) == ["google/gemini-test"])
    let model = try #require(models.first)
    #expect(model.name == "Gemini Test")
    #expect(model.contextLength == 1_048_576)
    #expect(model.supportsStreaming)
    #expect(model.supportsVision)
    #expect(model.supportsTools)
    #expect(model.supportsJSONMode)
    #expect(model.costPer1KIn == 0.00125)
    #expect(model.costPer1KOut == 0.01)
}

@Test func OpenRouterModelCatalog_ordinaryReadUsesFallbackWithoutNetwork() async throws {
    final class NoNetworkURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requestCount = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requestCount += 1
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("openrouter-cache-first-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NoNetworkURLProtocol.self]
    let session = URLSession(configuration: configuration)

    let models = await OpenRouterModelCatalog.models(
        dataRoot: root,
        session: session,
        refresh: false
    )
    #expect(!models.isEmpty)
    #expect(NoNetworkURLProtocol.requestCount == 0)
}

@Test func OpenRouterModelCatalog_onlyFreshLiveCacheCanRejectAPin() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("openrouter-availability-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    let cache = providers.appendingPathComponent("openrouter-models-cache.json")

    func write(updatedAt: Date) throws {
        let payload: [String: Any] = [
            "schema_version": 1,
            "updated_at": ISO8601DateFormatter().string(from: updatedAt),
            "source": OpenRouterModelCatalog.endpoint.absoluteString,
            "models": [[
                "id": "anthropic/claude-sonnet-5",
                "name": "Claude Sonnet 5",
                "context_length": 1_000_000,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: cache)
    }

    #expect(OpenRouterModelCatalog.cachedAvailability(
        of: "retired/model", dataRoot: root
    ) == .unknown)
    try write(updatedAt: Date())
    #expect(OpenRouterModelCatalog.cachedAvailability(
        of: "anthropic/claude-sonnet-5", dataRoot: root
    ) == .available)
    #expect(OpenRouterModelCatalog.cachedAvailability(
        of: "retired/model", dataRoot: root
    ) == .unavailable)

    try write(updatedAt: Date().addingTimeInterval(-25 * 60 * 60))
    #expect(OpenRouterModelCatalog.cachedAvailability(
        of: "retired/model", dataRoot: root
    ) == .unknown)
}

@Test func OpenRouterModelCatalog_parseModelsResponse_sortsByProviderThenModel() throws {
    let data = Data("""
    {
      "data": [
        {
          "id": "zzz/vendor-model",
          "name": "Vendor Z",
          "context_length": 8192,
          "architecture": {"output_modalities": ["text"]},
          "supported_parameters": []
        },
        {
          "id": "anthropic/claude-sonnet-test",
          "name": "Claude Sonnet Test",
          "context_length": 200000,
          "architecture": {"output_modalities": ["text"]},
          "supported_parameters": ["tools"]
        },
        {
          "id": "openrouter/auto",
          "name": "Auto Router",
          "context_length": 200000,
          "architecture": {"output_modalities": ["text"]},
          "supported_parameters": []
        },
        {
          "id": "anthropic/claude-opus-test",
          "name": "Claude Opus Test",
          "context_length": 200000,
          "architecture": {"output_modalities": ["text"]},
          "supported_parameters": ["tools"]
        }
      ]
    }
    """.utf8)

    let ids = try OpenRouterModelCatalog.parseModelsResponse(data).map(\.id)

    #expect(ids == [
        "anthropic/claude-opus-test",
        "anthropic/claude-sonnet-test",
        "openrouter/auto",
        "zzz/vendor-model",
    ])
}

import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Subconscious reflection routing readiness", .serialized)
struct ReflectionRoutingReadinessTests {
    @Test func providerMustBeReadyAndFreshRetirementBlocksEnable() {
        #expect(!NativeReflectionRouteStatus(
            model: "model-a",
            providerID: "provider-a",
            providerReady: false,
            modelKnown: true,
            detail: "connect provider"
        ).isReady)
        #expect(!NativeReflectionRouteStatus(
            model: "retired-model",
            providerID: "provider-a",
            providerReady: true,
            modelKnown: false,
            detail: "choose replacement"
        ).isReady)
    }

    @Test func readyCredentialsMayProceedWhenCatalogFreshnessIsUnknown() {
        #expect(NativeReflectionRouteStatus(
            model: "model-a",
            providerID: "provider-a",
            providerReady: true,
            modelKnown: nil,
            detail: "catalog not freshly verified"
        ).isReady)
    }

    @Test func freshOpenRouterCatalogRetirementBlocksTheExactReflectionRoute() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflection-route-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"cognition_reflection":{"model":"vendor/retired","reasoningEffort":"high"}}"#.utf8)
            .write(to: providers.appendingPathComponent("surfaces.json"))
        try Data(#"{"cognition_reflection":"openrouter"}"#.utf8)
            .write(to: providers.appendingPathComponent("active.json"))
        try Data(#"{"api_key":"test-only"}"#.utf8)
            .write(to: providers.appendingPathComponent("openrouter.json"))
        let updatedAt = ISO8601DateFormatter().string(from: Date())
        let cache = """
        {"schema_version":1,"updated_at":"\(updatedAt)","source":"https://openrouter.ai/api/v1/models?output_modalities=text","models":[{"id":"vendor/current","name":"Current","context_length":128000}]}
        """
        try Data(cache.utf8)
            .write(to: providers.appendingPathComponent("openrouter-models-cache.json"))

        let runtime = NativeCognitionRuntime(dataRoot: root)
        let status = await runtime.reflectionRouteStatus()

        #expect(status.model == "vendor/retired")
        #expect(status.providerID == "openrouter")
        #expect(status.providerReady)
        #expect(status.modelKnown == false)
        #expect(!status.isReady)
    }
}

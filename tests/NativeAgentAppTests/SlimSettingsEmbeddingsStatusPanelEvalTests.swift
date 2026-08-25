import Foundation
import Testing
@testable import NativeAgentApp

private func embeddingsPanelRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("slim-settings-embeddings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Slim Settings embeddings status panel — root-resolved runtime")
struct SlimSettingsEmbeddingsStatusPanelEvalTests {
    @Test("the status panel reads the same isolated embedding mode its action persisted")
    func panelUsesTheAppModelEmbeddingRoot() async throws {
        let root = try embeddingsPanelRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        let result = try await client.setEmbeddingsMemoryMode(mode: "low_memory")
        #expect(result.status.memoryMode == "low_memory")
        let status = try await client.getEmbeddingsStatus()
        #expect(status.memoryMode == "low_memory")
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("embeddings/mode.json").path
        ))

        let presentation = EmbeddingsSettingsStatusPresentation(status: status)
        #expect(presentation.memoryMode == "low_memory")
        #expect(presentation.memoryModeLabel == "Low")
        #expect(presentation.memoryModeDescription == "The search model unloads after 45 seconds of no use, to keep memory free.")
    }
}

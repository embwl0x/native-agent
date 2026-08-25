import Foundation
import Testing
@testable import NativeAgentApp

private func privacyMapPanelRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("trust-privacy-map-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Trust Center privacy map panel — canonical root")
struct TrustCenterPrivacyMapPanelEvalTests {
    @Test("the privacy-map presentation displays inventory from its injected data root")
    func panelUsesTheClientPrivacyMapRoot() async throws {
        let root = try privacyMapPanelRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let memoryDirectory = root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        try Data("private memory".utf8).write(to: memoryDirectory.appendingPathComponent("record.json"))

        let privacyMap = try await NativeClient(
            baseURL: "",
            dataRootOverride: root
        ).getPrivacyMap()
        #expect(privacyMap.dataRoot == root.path)
        #expect(privacyMap.categories.first(where: { $0.id == "memory" })
            .map { $0.contains.contains("1 file") } == true)
        #expect(privacyMap.categories.first(where: { $0.id == "secrets" })
            .map { $0.contains.contains("not present") } == true)

        let presentation = PrivacyMapPanelPresentation.resolve(
            trustPolicyRoot: nil,
            privacyMap: privacyMap
        )
        guard case .loaded(let loaded) = presentation else {
            Issue.record("a received root-scoped privacy map must be presented as loaded")
            return
        }
        #expect(loaded.root == root.path)
        let memory = try #require(loaded.categories.first { $0.id == "memory" })
        #expect(memory.source.path == root.appendingPathComponent("memory").path)
        #expect(memory.source.contains.contains("1 file"))
        let secrets = try #require(loaded.categories.first { $0.id == "secrets" })
        #expect(secrets.protectionLabel == "Protected",
                "non-exportable categories must remain visibly protected")
    }

    @Test("the privacy-map presentation distinguishes data not yet loaded from an empty map")
    func panelShowsThePendingState() {
        #expect(PrivacyMapPanelPresentation.resolve(
            trustPolicyRoot: nil,
            privacyMap: nil
        ) == .pending)
    }
}

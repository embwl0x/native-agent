import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Skills.manifestErrorBanner

@MainActor
@Suite("Skills manifest error banner")
struct SkillsManifestErrorBannerEvalTests {
    @Test("a missing registry is a clean empty catalog, while corrupt existing bytes raise and recovery clears the banner")
    func bannerTracksTheAuthoritativeManifestReader() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-manifest-banner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("skills"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("skills/manifest_registry.json")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        await app.loadSkillManifests()
        #expect(app.skillManifests.isEmpty)
        #expect(app.skillLifecycleFeedback == nil)

        let corrupt = Data("{ broken".utf8)
        try corrupt.write(to: registry)
        await app.loadSkillManifests()
        #expect(app.skillLifecycleFeedback?.kind == .failure)
        #expect(app.skillManifestError?.contains("Skill catalog unavailable") == true)
        #expect(try Data(contentsOf: registry) == corrupt)

        try Data(#"{"skills":{}}"#.utf8).write(to: registry, options: .atomic)
        await app.loadSkillManifests()
        #expect(app.skillManifests.isEmpty)
        #expect(app.skillLifecycleFeedback == nil)
        #expect(app.skillManifestError == nil)
    }
}

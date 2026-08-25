import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SkillLifecycle.searchField

@MainActor
@Suite("Skill lifecycle search field")
struct SkillLifecycleSearchFieldEvalTests {
    @Test("the search state filters the real injected skill registry by every displayed identity field")
    func searchUsesTheLoadedSkillCatalogAndKeepsNoMatchVisible() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("skills/registry.json")
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(registryJSON.utf8).write(to: registryURL)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.loadSkillManifests()
        #expect(app.skillManifestError == nil)
        #expect(app.skillManifests.map(\.id) == ["vault-keeper", "route-planner"])

        let loaded = app.skillManifests
        #expect(SkillLifecycleSearchPresentation.filtered(loaded, query: "Journey")
            .map(\.id) == ["route-planner"])
        #expect(SkillLifecycleSearchPresentation.filtered(loaded, query: "CONNECTOR")
            .map(\.id) == ["route-planner"])
        #expect(SkillLifecycleSearchPresentation.filtered(loaded, query: "route planner")
            .map(\.id) == ["route-planner"])
        let tagged = skill(id: "tagged-skill", name: "Tagged Skill", tags: ["résumé"])
        #expect(SkillLifecycleSearchPresentation.filtered([tagged], query: "resume")
            .map(\.id) == ["tagged-skill"])
        #expect(SkillLifecycleSearchPresentation.filtered(loaded, query: "   \n")
            .map(\.id) == loaded.map(\.id))
        #expect(SkillLifecycleSearchPresentation.filtered(loaded, query: "absent capability").isEmpty)

        let matched = SkillLifecycleSearchPresentation.results(loaded, query: "journey")
        #expect(matched.displayed.map(\.id) == ["route-planner"])
        #expect(matched.isFiltering)
        #expect(matched.resultCountText == "1 match")

        let noMatch = SkillLifecycleSearchPresentation.results(loaded, query: "absent capability")
        #expect(noMatch.displayed.isEmpty)
        #expect(noMatch.emptyTitle == "No matches")
        #expect(noMatch.emptyDetail.contains("Nothing matches"))

        let whitespace = SkillLifecycleSearchPresentation.results(loaded, query: "   \n")
        #expect(!whitespace.isFiltering)
        #expect(whitespace.resultCountText == nil)
        #expect(whitespace.displayed.map(\.id) == loaded.map(\.id))
    }

    private var registryJSON: String {
        #"""
        [
          {
            "id": "route-planner",
            "name": "Journey Weaver",
            "description": "Plans calendar-aware routes.",
            "triggers": ["route", "calendar"],
            "kind": "connector",
            "status": "active",
            "autoCreated": false,
            "createdAt": "2026-08-24T12:00:00Z",
            "source": "runtime_registry"
          },
          {
            "id": "vault-keeper",
            "name": "Vault Keeper",
            "description": "Protects local credentials.",
            "triggers": ["credential"],
            "kind": "security",
            "status": "active",
            "autoCreated": false,
            "createdAt": "2026-08-24T12:01:00Z",
            "source": "runtime_registry"
          }
        ]
        """#
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-lifecycle-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func skill(id: String, name: String, tags: [String]) -> SkillInfo {
        SkillInfo(
            id: id,
            manifest: SkillManifest(
                schemaVersion: 1,
                name: name,
                version: "1.0.0",
                type: "composite",
                description: "Search fixture",
                author: nil,
                permissions: nil,
                tools: nil,
                oauth: nil,
                tags: tags,
                homepage: nil
            ),
            registry: SkillRegistryEntry(
                name: id,
                state: "active",
                version: "1.0.0",
                type: "composite",
                installedAt: nil,
                path: ""
            ),
            readme: nil
        )
    }

}

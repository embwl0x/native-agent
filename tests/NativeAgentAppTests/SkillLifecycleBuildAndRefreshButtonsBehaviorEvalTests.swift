import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SkillLifecycle.buildAndRefreshButtons
@MainActor
@Suite("Skill Lifecycle build and refresh buttons", .serialized)
struct SkillLifecycleBuildAndRefreshButtonsBehaviorEvalTests {
    @Test("Build in Chat writes the starter to the active composer and preserves an existing draft")
    func buildWritesOnlyWhenNoPersistedDraftExists() {
        let app = AppModel(dataRootOverride: FileManager.default.temporaryDirectory, startBackgroundTasks: false)
        app.activeChatSessionId = "skill-session"

        #expect(app.requestSkillBuild(starter: "Build me a skill that organizes receipts") == .draftPrepared)
        #expect(app.chatDraft(for: "skill-session") == "Build me a skill that organizes receipts")

        #expect(app.requestSkillBuild(starter: "This must not replace my draft") == .existingDraftPreserved)
        #expect(app.chatDraft(for: "skill-session") == "Build me a skill that organizes receipts")
    }

    @Test("Build treats a missing chat session as pending instead of claiming a prepared draft")
    func adverseBuildStateStaysTruthful() {
        #expect(SkillLifecycleActionPresentation.build(
            activeSessionID: "  ",
            existingDraft: ""
        ) == .awaitingChatSession)
    }

    @Test("Refresh distinguishes a clean empty catalog from a malformed authority at the mounted root")
    func refreshUsesTheMountedRootAndDoesNotCallAnUnreadCatalogEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-lifecycle-buttons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("skills", isDirectory: true),
            withIntermediateDirectories: true
        )

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.loadSkillManifests()
        #expect(app.skillManifestError == nil)
        #expect(app.skillManifests.isEmpty)

        try Data("{ malformed".utf8).write(
            to: root.appendingPathComponent("skills/manifest_registry.json")
        )
        await app.loadSkillManifests()
        #expect(app.skillManifests.isEmpty)
        #expect(app.skillLifecycleFeedback?.kind == .failure)
        #expect(app.skillManifestError?.contains("Skill catalog unavailable") == true)
    }
}

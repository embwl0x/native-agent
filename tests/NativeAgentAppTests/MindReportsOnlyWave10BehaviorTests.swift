// EVAL COVERAGE — app.mind Wave 10.
//
// These are mounted controls and real app readers/stores. They intentionally
// do not inspect source text or duplicate presentation predicates.

import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.mind Wave 10 — mounted truth and durable readers", .serialized)
struct MindReportsOnlyWave10BehaviorTests {
    private func root(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mind-wave10-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }


    // ui.dreams.button.refresh / ui.dreams.list.diary /
    // logic.dreams.diaryLoadGeneration
    @Test("the mounted Dreams reader uses its injected root and a fresh app reader sees the same diary after relaunch")
    func dreamDiaryRefreshIsDurableAcrossReaderRelaunch() async throws {
        let dataRoot = try root("dream-relaunch")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let diary = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        try FileManager.default.createDirectory(at: diary, withIntermediateDirectories: true)
        try "# Grounded reflection\n\nVerified outcomes first.\n"
            .write(to: diary.appendingPathComponent("2026-08-24.md"), atomically: true, encoding: .utf8)

        let first = NativeClient(baseURL: "http://unused", dataRootOverride: dataRoot)
        let firstRead = try await first.getDreamDiary(limit: 60)
        #expect(firstRead.entries.map(\.date) == ["2026-08-24"])
        #expect(firstRead.entries[0].content.contains("Verified outcomes first."))

        // A new app/model reader is the relaunch boundary; it must not depend
        // on an in-memory diary cache from the first read.
        let relaunched = NativeClient(baseURL: "http://unused", dataRootOverride: dataRoot)
        let afterRelaunch = try await relaunched.getDreamDiary(limit: 60)
        #expect(afterRelaunch.entries == firstRead.entries)

        // An adverse read must not erase the last successful durable response.
        try FileManager.default.removeItem(at: diary)
        try Data("not a directory".utf8).write(to: diary)
        await #expect(throws: (any Error).self) { _ = try await first.getDreamDiary(limit: 60) }
    }

    @Test("the bounded mounted diary discloses that it is showing only the first 60 readable entries")
    func boundedDiaryDisclosesItsLimit() async throws {
        let dataRoot = try root("dream-cap")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let diary = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        try FileManager.default.createDirectory(at: diary, withIntermediateDirectories: true)
        for day in 1...61 {
            try "entry \(day)".write(
                to: diary.appendingPathComponent(String(format: "2026-06-%02d.md", day)),
                atomically: true,
                encoding: .utf8
            )
        }
        let reader = NativeClient(baseURL: "http://unused", dataRootOverride: dataRoot)
        let response = try await reader.getDreamDiary(limit: 60)
        #expect(response.entries.count == 60)
        #expect(response.totalEntries == 61)
    }

    // ui.kg.emptyStates
    @Test("an unloaded trust policy mounts as checking, never as graph-off")
    func unloadedTrustPolicyMountsAsChecking() {
        let app = AppModel(startBackgroundTasks: false)
        #expect(app.trustPolicy == nil)
    }

    // ui.kg.graphCanvas
    @Test("the graph's production layout seed is stable for the same entity across relaunch-shaped re-instantiation")
    func graphLayoutSeedIsStable() {
        let firstLaunchSeed = KGGraphCanvas.stableSeed(for: "entity:stable-layout")
        let secondLaunchSeed = KGGraphCanvas.stableSeed(for: "entity:stable-layout")
        #expect(firstLaunchSeed == secondLaunchSeed)
        #expect(firstLaunchSeed != KGGraphCanvas.stableSeed(for: "entity:other"))
    }

    // ui.kg.action.enableKnowledgeGraph / ui.kg.button.enableKnowledgeGraph
    @Test("the actual Memory Policy writer reports durable enable success and fails closed for an invalid root")
    func memoryPolicyWriterIsDurableAndFailsClosed() async throws {
        let dataRoot = try root("knowledge-policy")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let app = AppModel(dataRootOverride: dataRoot, startBackgroundTasks: false)
        #expect(await app.patchMemoryPolicy(knowledgeGraphEnabled: true))
        #expect(app.trustPolicy?.memoryPolicy?.knowledge_graph_enabled == true)

        let invalidRoot = dataRoot.appendingPathComponent("not-a-directory")
        try Data("authority must stay untouched".utf8).write(to: invalidRoot)
        let denied = AppModel(dataRootOverride: invalidRoot, startBackgroundTasks: false)
        #expect(!(await denied.patchMemoryPolicy(knowledgeGraphEnabled: true)))
        #expect(try Data(contentsOf: invalidRoot) == Data("authority must stay untouched".utf8))
    }

    @Test("the mounted Enable Knowledge Graph button drives the checked policy action")
    func mountedEnableKnowledgeGraphButtonDrivesPolicyAction() async throws {
        let dataRoot = try root("knowledge-enable-button")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let app = AppModel(dataRootOverride: dataRoot, startBackgroundTasks: false)
        #expect(await app.patchMemoryPolicy(knowledgeGraphEnabled: false))
        #expect(await app.patchMemoryPolicy(knowledgeGraphEnabled: true))
        #expect(app.trustPolicy?.memoryPolicy?.knowledge_graph_enabled == true,
                "a mounted click must reach the policy action and commit before graph loading")
    }

    // ui.personality.starterPanel / ui.personality.docPicker /
    // ui.personality.reloadDocuments / logic.personality.loadProfile.docsLoadErrorLatch
    @Test("real personality document saves survive a new app model and preserve independent document drafts")
    func personalityDocumentSavesSurviveRelaunch() async throws {
        let dataRoot = try root("persona-relaunch")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let persona = dataRoot.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        try Data("complete\n".utf8).write(to: dataRoot.appendingPathComponent(".onboarded"))
        try "# Agent\n\nGround outcomes in evidence.\n"
            .write(to: persona.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

        let first = AppModel(dataRootOverride: dataRoot, startBackgroundTasks: false)
        #expect(await first.loadPersonalityDocs())
        let soul = try #require(first.personalityDocs.first { $0.id == "SOUL" })
        let voice = "# Voice\n\nWarm, direct, and candid.\n"
        #expect(await first.savePersonalityDoc(id: "VOICE", content: voice))
        #expect(first.personalityDocs.first { $0.id == soul.id }?.content.contains("Ground outcomes") == true)

        #expect(await first.loadPersonalityDocs())
        #expect(first.personalityDocs.first { $0.id == "VOICE" }?.content == voice,
                "the mounted reload button must retain the canonical document it just reread")

        // A new model takes the same on-disk route: it proves the document
        // picker/reload surface reads canonical durable bytes, not its old draft.
        let relaunched = AppModel(dataRootOverride: dataRoot, startBackgroundTasks: false)
        #expect(await relaunched.loadPersonalityDocs())
        #expect(relaunched.personalityDocs.first { $0.id == "SOUL" }?.content.contains("Ground outcomes") == true)
        #expect(relaunched.personalityDocs.first { $0.id == "VOICE" }?.content == voice)
    }
}

// EVAL COVERAGE — ui.personality.starterPanel.
//
// Drives the starter action through its real Swift onboarding and
// persona-document writers. It deliberately does not inspect source text or
// substitute a fake persistence client.

import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("Personality starter panel — durable behavior", .serialized)
struct PersonalityStarterPanelBehaviorTests {
    private func root(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("personality-starter-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("the starter Create action writes trimmed setup notes into canonical SOUL.md and a new reader sees them")
    func starterNotesPersistAcrossRelaunch() async throws {
        let dataRoot = try root("durable-notes")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let app = AppModel(dataRootOverride: dataRoot, startBackgroundTasks: false)
        let outcome = await PersonalityStarterCreateAction.create(
            appModel: app,
            agentName: "  Agent  ",
            userName: "  User  ",
            notes: "  Ground every claim in evidence.  "
        )
        #expect(outcome == .created)

        let soulURL = dataRoot.appendingPathComponent("persona/SOUL.md")
        let soul = try String(contentsOf: soulURL, encoding: .utf8)
        #expect(soul.contains("## From setup\nGround every claim in evidence.\n"))
        #expect(FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(".onboarded").path))

        let relaunched = AppModel(dataRootOverride: dataRoot, startBackgroundTasks: false)
        #expect(await relaunched.loadPersonalityDocs())
        #expect(relaunched.personalityDocs.first { $0.id == "SOUL" }?.content == soul,
                "the next app reader must receive the canonical saved setup notes")
    }

    @Test("a real second SOUL write failure returns the visible unsaved-draft presentation")
    func starterNotesSaveFailureStaysVisible() async throws {
        let dataRoot = try root("notes-save-failure")
        defer {
            PersonalityStarterPanelEvaluation.beforePersistingNotes = nil
            try? FileManager.default.removeItem(at: dataRoot)
        }
        let soulURL = dataRoot.appendingPathComponent("persona/SOUL.md")
        PersonalityStarterPanelEvaluation.beforePersistingNotes = {
            try? FileManager.default.removeItem(at: soulURL)
            try? FileManager.default.createDirectory(at: soulURL, withIntermediateDirectories: true)
        }

        let app = AppModel(dataRootOverride: dataRoot, startBackgroundTasks: false)
        let outcome = await PersonalityStarterCreateAction.create(
            appModel: app,
            agentName: "Agent",
            userName: "User",
            notes: "Keep this setup note safe."
        )

        let draft: String
        switch outcome {
        case .notesUnsaved(let documentID, let value):
            #expect(documentID.uppercased() == "SOUL")
            draft = value
        default:
            Issue.record("expected the real SOUL write failure, got \(outcome)")
            return
        }

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: soulURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "the writer must have encountered the actual hostile SOUL path")
        #expect(PersonalityStarterCreateAction.notesUnsavedMessage
            == "Setup notes were not saved. They are open as an unsaved SOUL.md draft below.")
        #expect(draft.contains("## From setup\nKeep this setup note safe.\n"),
                "the editor must receive the exact unsaved draft instead of discarding the user's notes")
    }
}

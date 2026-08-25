import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.personality.identity.saveName
@MainActor
@Suite("Personality identity name save", .serialized)
struct PersonalityIdentitySaveNameEvalTests {
    @Test("name-only identity save persists the returned profile across a fresh reader")
    func nameSaveUsesCanonicalProfileWriter() async throws {
        let root = try temporaryRoot("saved")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        // Fixture name is deliberately identity-neutral: the public-export
        // scrub rewrites private identity tokens, and a rewritten fixture can
        // land on a generic persona label the save path refuses.
        let outcome = await app.savePersonalityName("  Marisol  ")
        guard case .saved(let saved) = outcome else {
            throw PersonalityNameSaveEvalError.expectedSaved(outcome)
        }
        #expect(saved.name == "Marisol")
        #expect(app.personality?.name == "Marisol")
        #expect(app.agentDisplayName == "Marisol")

        let relaunched = NativeClient(baseURL: "", dataRootOverride: root)
        #expect(try await relaunched.getPersonality().name == "Marisol")
    }

    @Test("empty and generic names are refused before they can claim a live identity change")
    func invalidIdentityNamesFailClosed() async throws {
        let root = try temporaryRoot("refused")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        #expect(await app.savePersonalityName(" \n ") == .refused("Enter a name before saving."))
        #expect(await app.savePersonalityName("AI") == .refused(
            "Choose a specific name instead of a generic persona label."
        ))
        #expect(app.personality == nil)
    }

    @Test("an unavailable profile root returns failure without fabricating a saved identity")
    func unavailableWriterDoesNotClaimSuccess() async throws {
        let parent = try temporaryRoot("unavailable")
        defer { try? FileManager.default.removeItem(at: parent) }
        let invalidRoot = parent.appendingPathComponent("not-a-directory")
        try Data("preserve this file".utf8).write(to: invalidRoot)
        let app = AppModel(dataRootOverride: invalidRoot, startBackgroundTasks: false)

        let outcome = await app.savePersonalityName("Marisol")
        guard case .failed(let detail) = outcome else {
            throw PersonalityNameSaveEvalError.expectedFailure(outcome)
        }
        #expect(!detail.isEmpty)
        #expect(app.personality == nil)
        #expect(try Data(contentsOf: invalidRoot) == Data("preserve this file".utf8))
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("personality-name-save-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum PersonalityNameSaveEvalError: Error {
    case expectedSaved(PersonalityNameSaveOutcome)
    case expectedFailure(PersonalityNameSaveOutcome)
}

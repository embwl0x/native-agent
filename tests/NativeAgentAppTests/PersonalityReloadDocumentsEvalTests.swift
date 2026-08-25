import Darwin
import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.personality.reloadDocuments
@MainActor
@Suite("Personality document reload", .serialized)
struct PersonalityReloadDocumentsEvalTests {
    @Test("canonical document changes replace the mounted app model on reload")
    func reloadReadsFreshPersonaDocuments() async throws {
        let root = try temporaryRoot("fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let persona = try seedPersona(at: root)
        let voice = persona.appendingPathComponent("VOICE.md")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        #expect(await app.reloadPersonalityDocuments() == .loaded(documentCount: 5))
        try "# Voice\n\nChanged outside this view.\n"
            .write(to: voice, atomically: true, encoding: .utf8)

        #expect(await app.reloadPersonalityDocuments() == .loaded(documentCount: 5))
        #expect(app.personalityDocs.first { $0.id == "VOICE" }?.content
            == "# Voice\n\nChanged outside this view.\n")
    }

    @Test("a real failed reload retains prior documents and labels them stale")
    func failedReloadDoesNotMasqueradeAsEmptyPersona() async throws {
        let root = try temporaryRoot("retained")
        defer { try? FileManager.default.removeItem(at: root) }
        let persona = try seedPersona(at: root)
        let voice = persona.appendingPathComponent("VOICE.md")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        #expect(await app.reloadPersonalityDocuments() == .loaded(documentCount: 5))
        let retainedVoice = app.personalityDocs.first { $0.id == "VOICE" }?.content

        try FileManager.default.removeItem(at: voice)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: persona.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: persona.path) }

        let outcome = await app.reloadPersonalityDocuments()
        guard case .failed(let detail, let retainedCount) = outcome else {
            throw PersonalityReloadEvalError.expectedFailure(outcome)
        }
        #expect(!detail.isEmpty)
        #expect(retainedCount == 5)
        #expect(app.personalityDocs.first { $0.id == "VOICE" }?.content == retainedVoice)

        let presentation = PersonalityDocumentsReloadPresentation.resolve(
            documents: app.personalityDocs,
            errorDetail: detail
        )
        guard case .retainedStale(let count, _) = presentation else {
            throw PersonalityReloadEvalError.expectedRetainedPresentation(presentation)
        }
        #expect(count == 5)
        #expect(presentation.banner?.contains("previously loaded documents") == true)
    }

    // EVAL FENCE: app.mind / logic.personality.loadProfile.docsLoadErrorLatch
    @Test("the document-reader latch distinguishes a malformed root from first run, retains prior documents, and clears after repair")
    func documentLoadErrorLatchTracksTheRealReaderOutcome() async throws {
        let root = try temporaryRoot("load-error-latch")
        defer { try? FileManager.default.removeItem(at: root) }
        let persona = root.appendingPathComponent("persona", isDirectory: true)
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        var latch = PersonalityDocumentsLoadLatch()

        // A root file is corruption, not a missing first-run directory. The
        // real NativeClient -> PersonaEngine reader must report it so the
        // mounted loadProfile path cannot offer a false Create card.
        try Data("not a directory".utf8).write(to: persona)
        let unavailableOutcome = await app.reloadPersonalityDocuments()
        guard case .failed(_, let unavailableRetainedCount) = unavailableOutcome else {
            throw PersonalityReloadEvalError.expectedFailure(unavailableOutcome)
        }
        #expect(unavailableRetainedCount == 0)
        latch.record(unavailableOutcome)
        guard case .unavailable(let unavailableDetail) = latch.presentation else {
            throw PersonalityReloadEvalError.expectedUnavailablePresentation(latch.presentation)
        }
        #expect(unavailableDetail.contains("persona root is not a directory"))

        // Removing the malformed path entirely is the legitimate first-run
        // state, so it reads as current rather than unavailable. That
        // canonical success is the only event permitted to clear the latch.
        try FileManager.default.removeItem(at: persona)
        let firstRunOutcome = await app.reloadPersonalityDocuments()
        #expect(firstRunOutcome == .loaded(documentCount: 5))
        latch.record(firstRunOutcome)
        #expect(latch.presentation == .current)
        #expect(app.personalityDocs.first { $0.id == "SOUL" }?.updatedAt == nil)

        // Once documents are created, the same reader adopts their durable
        // content and remains current.
        try seedPersona(at: root)
        let repairedOutcome = await app.reloadPersonalityDocuments()
        #expect(repairedOutcome == .loaded(documentCount: 5))
        latch.record(repairedOutcome)
        #expect(latch.presentation == .current)
        let retainedSoul = app.personalityDocs.first { $0.id == "SOUL" }?.content

        // Once documents have been loaded, a later malformed root preserves
        // those bytes but marks them stale instead of declaring a new persona.
        try FileManager.default.removeItem(at: persona)
        try Data("corrupt again".utf8).write(to: persona)
        let staleOutcome = await app.reloadPersonalityDocuments()
        guard case .failed(_, let retainedCount) = staleOutcome else {
            throw PersonalityReloadEvalError.expectedFailure(staleOutcome)
        }
        #expect(retainedCount == 5)
        #expect(app.personalityDocs.first { $0.id == "SOUL" }?.content == retainedSoul)
        latch.record(staleOutcome)
        guard case .retainedStale(let count, _) = latch.presentation else {
            throw PersonalityReloadEvalError.expectedRetainedPresentation(latch.presentation)
        }
        #expect(count == 5)

        try FileManager.default.removeItem(at: persona)
        try seedPersona(at: root)
        let recoveredOutcome = await app.reloadPersonalityDocuments()
        #expect(recoveredOutcome == .loaded(documentCount: 5))
        latch.record(recoveredOutcome)
        #expect(latch.presentation == .current)
    }

    private func seedPersona(at root: URL) throws -> URL {
        let persona = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        try "# Soul\n".write(to: persona.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try "# Voice\n\nInitial voice.\n".write(to: persona.appendingPathComponent("VOICE.md"), atomically: true, encoding: .utf8)
        try "# Growth\n".write(to: persona.appendingPathComponent("GROWTH.md"), atomically: true, encoding: .utf8)
        try "# Manual\n".write(to: persona.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        return persona
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("personality-reload-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum PersonalityReloadEvalError: Error {
    case expectedFailure(PersonalityDocumentsReloadOutcome)
    case expectedRetainedPresentation(PersonalityDocumentsReloadPresentation)
    case expectedUnavailablePresentation(PersonalityDocumentsReloadPresentation)
}

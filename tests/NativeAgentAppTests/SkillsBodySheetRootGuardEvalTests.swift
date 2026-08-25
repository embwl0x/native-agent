import Foundation
import PersonaEngine
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.settings · Skills body-sheet root guard", .serialized)
struct SkillsBodySheetRootGuardEvalTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-body-root-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("only canonical runtime and isolated persona Markdown bodies are readable")
    func readsOnlyCanonicalBodyRoots() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = PersonaRootResolver.resolveIsolated(dataRoot: root)
        let runtime = root.appendingPathComponent("skills/bodies/runtime.md")
        let persona = personaRoot.appendingPathComponent("skills/bodies/persona.md")
        try FileManager.default.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: persona.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("runtime body".utf8).write(to: runtime)
        try Data("persona body".utf8).write(to: persona)

        #expect(SkillBodyPresentation.read(path: runtime.path, dataRoot: root, personaRoot: personaRoot)
            == .content("runtime body", truncated: false))
        #expect(SkillBodyPresentation.read(path: persona.path, dataRoot: root, personaRoot: personaRoot)
            == .content("persona body", truncated: false))

        let prefixLookalike = root.appendingPathComponent("skills/bodies-backup/escaped.md")
        try FileManager.default.createDirectory(at: prefixLookalike.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("do not render".utf8).write(to: prefixLookalike)
        #expect(SkillBodyPresentation.read(path: prefixLookalike.path, dataRoot: root, personaRoot: personaRoot)
            == .unavailable("The recorded body path is outside this skill store."))

        let nonMarkdown = root.appendingPathComponent("skills/bodies/notes.txt")
        try Data("not a skill body".utf8).write(to: nonMarkdown)
        #expect(SkillBodyPresentation.read(path: nonMarkdown.path, dataRoot: root, personaRoot: personaRoot)
            == .unavailable("The recorded body is not a Markdown skill file."))
    }

    @Test("a symlink escape is unavailable without reading or changing outside bytes")
    func bodyReaderRefusesSymlinkEscapeWithoutTouchingOutsideBody() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = PersonaRootResolver.resolveIsolated(dataRoot: root)
        let bodyRoot = root.appendingPathComponent("skills/bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: bodyRoot, withIntermediateDirectories: true)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-body-\(UUID().uuidString).md")
        let outsideBytes = Data("must not reach the body sheet".utf8)
        try outsideBytes.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escape = bodyRoot.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

        let state = SkillBodyPresentation.read(path: escape.path, dataRoot: root, personaRoot: personaRoot)
        #expect(state == .unavailable("The recorded body path is outside this skill store."))
        #expect(try Data(contentsOf: outside) == outsideBytes,
                "a refused body path must remain a read-only decision and never alter the escaped target")
        #expect(FileManager.default.fileExists(atPath: escape.path),
                "the body reader must not delete or repair an untrusted registry path")
    }
}

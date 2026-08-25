import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.settings · Skill Lifecycle body sheet", .serialized)
struct SkillLifecycleBodySheetEvalTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-body-sheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("the body reader selects the injected runtime body, not a process-default root")
    func bodySheetReadsTheCanonicalInjectedBody() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("skills/bodies/isolation.md")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expected = "# Isolated skill\n\nUse only the injected skill store."
        try Data(expected.utf8).write(to: path)

        // SkillBodySheet assigns this exact checked state. The direct reader
        // is the contract, not an offscreen AppKit text subtree.
        #expect(SkillBodyPresentation.read(
            path: path.path,
            dataRoot: root,
            personaRoot: root.appendingPathComponent("persona", isDirectory: true)
        ) == .content(expected, truncated: false))
    }

    @Test("empty, escaped, and oversized body paths remain distinct honest states")
    func bodySheetKeepsEmptyUnavailableAndTruncatedStatesVisible() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let bodies = root.appendingPathComponent("skills/bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)

        let empty = bodies.appendingPathComponent("empty.md")
        try Data().write(to: empty)
        #expect(SkillBodyPresentation.read(path: empty.path, dataRoot: root, personaRoot: personaRoot) == .empty)

        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-skill-body.md")
        try Data("must never render".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(SkillBodyPresentation.read(
            path: outside.path,
            dataRoot: root,
            personaRoot: personaRoot
        ) == .unavailable("The recorded body path is outside this skill store."))

        let oversized = bodies.appendingPathComponent("oversized.md")
        let source = String(repeating: "x", count: SkillBodyPresentation.maximumDisplayBytes + 1)
        try Data(source.utf8).write(to: oversized)
        guard case .content(let preview, let truncated) = SkillBodyPresentation.read(
            path: oversized.path, dataRoot: root, personaRoot: personaRoot
        ) else {
            Issue.record("a valid oversized body did not return a bounded preview")
            return
        }
        #expect(truncated)
        #expect(preview.utf8.count == SkillBodyPresentation.maximumDisplayBytes)
    }
}

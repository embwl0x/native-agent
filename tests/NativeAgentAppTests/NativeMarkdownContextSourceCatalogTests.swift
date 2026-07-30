import Context
import Foundation
import Testing
@testable import NativeAgentApp

private struct MarkdownCatalogFixture {
    let root: URL
    let bodiesRoot: URL

    init(label: String = UUID().uuidString) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMarkdownCatalogTests-\(label)", isDirectory: true)
            .standardizedFileURL
        bodiesRoot = root
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("bodies", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bodiesRoot,
            withIntermediateDirectories: true
        )
    }

    func write(_ name: String, contents: String = "# Skill\n\nProcedure.\n") throws {
        try Data(contents.utf8).write(to: bodiesRoot.appendingPathComponent(name))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Native Markdown Context source catalog")
struct NativeMarkdownContextSourceCatalogTests {
    @Test("registers direct skill Markdown with stable lazy policy")
    func registersDirectSkillMarkdown() throws {
        let fixture = try MarkdownCatalogFixture()
        defer { fixture.cleanUp() }
        try fixture.write("Zulu.md")
        try fixture.write("alpha.md")
        try fixture.write("notes.txt")
        try FileManager.default.createDirectory(
            at: fixture.bodiesRoot.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: false
        )
        try "# Nested".write(
            to: fixture.bodiesRoot.appendingPathComponent("nested/ignored.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: fixture.bodiesRoot.appendingPathComponent("directory.md", isDirectory: true),
            withIntermediateDirectories: false
        )

        let catalog = try NativeMarkdownContextSourceCatalog(personaRoot: fixture.root)

        #expect(catalog.allowedRoots == [fixture.root])
        #expect(catalog.registrations.map(\.fileURL.lastPathComponent) == ["alpha.md", "Zulu.md"])
        for registration in catalog.registrations {
            #expect(registration.allowedRoot == fixture.root)
            #expect(registration.maximumUTF8Bytes == NativeMarkdownContextSourceCatalog.maximumSourceUTF8Bytes)
            #expect(registration.descriptor.kind == .skill)
            #expect(registration.descriptor.authority == .approved)
            #expect(registration.descriptor.privacy == .localPrivate)
            #expect(registration.descriptor.injectionPolicy == .onDemand)
            #expect(registration.descriptor.permittedSurfaces == [
                .chat, .telegram, .ios, .slack, .workshop, .bridge,
            ])
        }
    }

    @Test("locators and IDs do not depend on the persona path")
    func stableAcrossPersonaPaths() throws {
        let first = try MarkdownCatalogFixture(label: "first-\(UUID().uuidString)")
        let second = try MarkdownCatalogFixture(label: "second-\(UUID().uuidString)")
        defer {
            first.cleanUp()
            second.cleanUp()
        }
        try first.write("Build-Release.md")
        try second.write("Build-Release.md")

        let firstRegistration = try #require(
            NativeMarkdownContextSourceCatalog.build(personaRoot: first.root).registrations.first
        )
        let secondRegistration = try #require(
            NativeMarkdownContextSourceCatalog.make(personaRoot: second.root).registrations.first
        )

        #expect(firstRegistration.descriptor.canonicalLocator == "skills/bodies/build-release.md")
        #expect(firstRegistration.descriptor.canonicalLocator == secondRegistration.descriptor.canonicalLocator)
        #expect(firstRegistration.descriptor.id == secondRegistration.descriptor.id)
    }

    @Test("hidden, credential-like, uppercase-extension, and oversized files are omitted")
    func omitsDisallowedFiles() throws {
        let fixture = try MarkdownCatalogFixture()
        defer { fixture.cleanUp() }
        try fixture.write("allowed.md")
        try fixture.write("oauth-flow.md")
        try fixture.write(".hidden.md")
        try fixture.write("credentials.md")
        try fixture.write("provider-token.md")
        try fixture.write("README.MD")
        let oversized = Data(
            repeating: 0x61,
            count: NativeMarkdownContextSourceCatalog.maximumSourceUTF8Bytes + 1
        )
        try oversized.write(to: fixture.bodiesRoot.appendingPathComponent("oversized.md"))

        let catalog = try NativeMarkdownContextSourceCatalog(personaRoot: fixture.root)

        #expect(catalog.registrations.map(\.fileURL.lastPathComponent) == [
            "allowed.md", "oauth-flow.md",
        ])
    }

    @Test("source count is capped after deterministic ordering")
    func capsSourceCount() throws {
        let fixture = try MarkdownCatalogFixture()
        defer { fixture.cleanUp() }
        for index in 0...NativeMarkdownContextSourceCatalog.maximumSourceCount {
            try fixture.write(String(format: "skill-%03d.md", index))
        }

        let catalog = try NativeMarkdownContextSourceCatalog(personaRoot: fixture.root)

        #expect(catalog.registrations.count == NativeMarkdownContextSourceCatalog.maximumSourceCount)
        #expect(catalog.registrations.first?.fileURL.lastPathComponent == "skill-000.md")
        #expect(catalog.registrations.last?.fileURL.lastPathComponent == "skill-127.md")
    }

    @Test("case and Unicode-normalization collisions are rejected")
    func rejectsCaseCollisions() throws {
        do {
            try NativeMarkdownContextSourceCatalog.validateUniqueNames([
                "Re\u{301}sume\u{301}.md",
                "R\u{00E9}SUM\u{00E9}.md",
            ])
            Issue.record("Expected normalized case collision")
        } catch let error as NativeMarkdownContextSourceCatalogError {
            #expect(error == .caseCollidingNames("Re\u{301}sume\u{301}.md", "R\u{00E9}SUM\u{00E9}.md"))
        }
    }

    @Test("symlink escapes are rejected and in-root symlinks are not registered")
    func rejectsSymlinkEscapes() throws {
        let fixture = try MarkdownCatalogFixture()
        defer { fixture.cleanUp() }
        try fixture.write("real.md")
        try FileManager.default.createSymbolicLink(
            at: fixture.bodiesRoot.appendingPathComponent("alias.md"),
            withDestinationURL: fixture.bodiesRoot.appendingPathComponent("real.md")
        )

        let safeCatalog = try NativeMarkdownContextSourceCatalog(personaRoot: fixture.root)
        #expect(safeCatalog.registrations.map(\.fileURL.lastPathComponent) == ["real.md"])

        let outside = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outside) }
        try "# Outside".write(to: outside, atomically: true, encoding: .utf8)
        let escape = fixture.bodiesRoot.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

        do {
            _ = try NativeMarkdownContextSourceCatalog(personaRoot: fixture.root)
            Issue.record("Expected symlink escape rejection")
        } catch let error as NativeMarkdownContextSourceCatalogError {
            guard case .symbolicLinkEscape(let path, let target) = error else {
                Issue.record("Unexpected catalog error: \(error)")
                return
            }
            #expect(URL(fileURLWithPath: path).lastPathComponent == escape.lastPathComponent)
            #expect(target == outside.resolvingSymlinksInPath().standardizedFileURL.path)
        }
    }
}

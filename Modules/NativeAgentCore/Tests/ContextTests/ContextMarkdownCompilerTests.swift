import Foundation
import Testing
@testable import Context

@Suite("Context Markdown compiler")
struct ContextMarkdownCompilerTests {
    @Test
    func segmentsStructuralBlocksWithUTF8RangesAndHeadingHierarchy() async throws {
        let provider = RecordingEmbeddingProvider()
        let compiler = ContextMarkdownCompiler(embeddingProvider: provider)
        let source = """
        # Root

        Intro café 😀.

        ## Work

        - first item
        - second item

        Follow-up paragraph.

        ```swift
        print("hello")
        ```
        """
        let data = Data(source.utf8)
        let compiled = try await compiler.compile(
            sourceData: data,
            descriptor: descriptor(name: "AGENTS.md", kind: .persona, authority: .canonical),
            updatedAt: fixedDate
        )

        #expect(compiled.atoms.count == 4)
        #expect(compiled.atoms.map(\.headingPath) == [
            ["Root"], ["Root", "Work"], ["Root", "Work"], ["Root", "Work"],
        ])
        #expect(compiled.atoms.map(\.kind) == [.instruction, .procedure, .instruction, .procedure])
        for atom in compiled.atoms {
            let range = atom.sourceRange.utf8Start..<atom.sourceRange.utf8End
            #expect(String(decoding: data[range], as: UTF8.self) == atom.body)
        }
        #expect(compiled.atoms[0].sourceRange.utf8End - compiled.atoms[0].sourceRange.utf8Start == compiled.atoms[0].body.utf8.count)
        #expect(await provider.batches() == [compiled.atoms.map { semantic($0.body) }])
    }

    @Test
    func classifiesDocumentsAndExternalProjectsWithoutElevatingAuthority() async throws {
        let provider = RecordingEmbeddingProvider()
        let compiler = ContextMarkdownCompiler(embeddingProvider: provider)
        let cases: [(String, ContextSourceKind, ContextAuthority, ContextAtomKind, ContextContentRole)] = [
            ("SOUL.md", .persona, .identity, .identity, .identity),
            ("VOICE.md", .persona, .identity, .identity, .identity),
            ("USER.md", .persona, .canonical, .relationship, .fact),
            ("MEMORY.md", .persona, .canonical, .memory, .memory),
            ("skill.md", .skill, .approved, .procedure, .procedure),
            ("map.md", .project, .canonical, .project, .untrustedExternalData),
        ]

        for item in cases {
            let result = try await compiler.compile(
                source: "A durable statement for classification.",
                descriptor: descriptor(name: item.0, kind: item.1, authority: item.2),
                updatedAt: fixedDate
            )
            #expect(result.atoms[0].kind == item.3)
            #expect(result.atoms[0].contentRole == item.4)
        }
    }

    @Test
    func summariesAndTriggersAreDeterministicAndBounded() async throws {
        let provider = RecordingEmbeddingProvider()
        let limits = ContextMarkdownCompilerLimits(
            maxSourceUTF8Bytes: 4_096,
            maxAtomUTF8Bytes: 4_096,
            maxSummaryUTF8Bytes: 36,
            maxTriggerUTF8Bytes: 10,
            maxTriggersPerAtom: 4
        )
        let compiler = ContextMarkdownCompiler(embeddingProvider: provider, limits: limits)
        let source = """
        # Deployment Operations

        - Validate the production database migration carefully
        - Restart the application after verification
        """
        let descriptor = descriptor(name: "release-skill.md", kind: .skill, authority: .approved)
        let first = try await compiler.compile(source: source, descriptor: descriptor, updatedAt: fixedDate)
        let second = try await compiler.compile(source: source, descriptor: descriptor, updatedAt: fixedDate)

        #expect(first.sourceHash == second.sourceHash)
        #expect(first.atoms[0].deterministicSummary == second.atoms[0].deterministicSummary)
        #expect(first.atoms[0].triggers == second.atoms[0].triggers)
        #expect(first.atoms[0].deterministicSummary!.utf8.count <= 36)
        #expect(first.atoms[0].triggers.count <= 4)
        #expect(first.atoms[0].triggers.allSatisfy { $0.utf8.count <= 10 })
    }

    @Test
    func reusesStableIDsForEditsAndMovesAndEmbedsOnlyChangedBodies() async throws {
        let provider = RecordingEmbeddingProvider()
        let compiler = ContextMarkdownCompiler(embeddingProvider: provider)
        let descriptor = descriptor(name: "skill.md", kind: .skill, authority: .approved)
        let original = """
        # Setup

        Install the package with the approved tool.

        Verify the checksum before continuing.

        # Recovery

        Keep this exact recovery procedure.
        """
        let first = try await compiler.compile(
            source: original,
            descriptor: descriptor,
            updatedAt: fixedDate
        )
        await provider.reset()

        let editedAndMoved = """
        # Recovery Moved

        Keep this exact recovery procedure.

        # Setup

        Install the package with the approved local tool.

        Verify the checksum before continuing.
        """
        let second = try await compiler.compile(
            source: editedAndMoved,
            descriptor: descriptor,
            previous: first,
            updatedAt: fixedDate.addingTimeInterval(60)
        )

        let firstByBody = Dictionary(uniqueKeysWithValues: first.atoms.map { (semantic($0.body), $0) })
        let secondByBody = Dictionary(uniqueKeysWithValues: second.atoms.map { (semantic($0.body), $0) })
        let movedBody = "Keep this exact recovery procedure."
        let unchangedBody = "Verify the checksum before continuing."
        #expect(secondByBody[movedBody]?.id == firstByBody[movedBody]?.id)
        #expect(secondByBody[unchangedBody]?.id == firstByBody[unchangedBody]?.id)

        let oldEdited = first.atoms.first { $0.body.hasPrefix("Install") }
        let newEdited = second.atoms.first { $0.body.hasPrefix("Install") }
        #expect(newEdited?.id == oldEdited?.id)
        #expect(newEdited?.embedding != oldEdited?.embedding)
        #expect(secondByBody[movedBody]?.embedding == firstByBody[movedBody]?.embedding)
        #expect(await provider.batches() == [["Install the package with the approved local tool."]])

        await provider.reset()
        let inserted = editedAndMoved.replacingOccurrences(
            of: "# Setup\n\n",
            with: "# Setup\n\nRead the release notes first.\n\n"
        )
        let third = try await compiler.compile(
            source: inserted,
            descriptor: descriptor,
            previous: second,
            updatedAt: fixedDate.addingTimeInterval(120)
        )
        #expect(Set(third.atoms.map(\.id)).count == third.atoms.count)
        #expect(third.atoms.first { $0.body.hasPrefix("Install") }?.id == newEdited?.id)
        #expect(await provider.batches() == [["Read the release notes first."]])
    }

    @Test
    func rejectsMalformedEmptyOversizedAndSecretBearingSourcesWithoutEchoingSecrets() async throws {
        let provider = RecordingEmbeddingProvider()
        let compiler = ContextMarkdownCompiler(
            embeddingProvider: provider,
            limits: ContextMarkdownCompilerLimits(
                maxSourceUTF8Bytes: 64,
                maxAtomUTF8Bytes: 16,
                maxSummaryUTF8Bytes: 16,
                maxTriggerUTF8Bytes: 8,
                maxTriggersPerAtom: 4
            )
        )
        let safeDescriptor = descriptor(name: "SOUL.md", kind: .persona, authority: .identity)

        await expectError(.malformedUTF8) {
            _ = try await compiler.compile(
                sourceData: Data([0xC3, 0x28]),
                descriptor: safeDescriptor,
                updatedAt: fixedDate
            )
        }
        await expectError(.emptySource) {
            _ = try await compiler.compile(source: " \n\t", descriptor: safeDescriptor, updatedAt: fixedDate)
        }
        await expectError(.sourceTooLarge(actualBytes: 65, maximumBytes: 64)) {
            _ = try await compiler.compile(source: String(repeating: "x", count: 65), descriptor: safeDescriptor, updatedAt: fixedDate)
        }
        await expectError(.atomTooLarge(index: 0, actualBytes: 17, maximumBytes: 16)) {
            _ = try await compiler.compile(source: String(repeating: "x", count: 17), descriptor: safeDescriptor, updatedAt: fixedDate)
        }

        let rawSecret = "sk-abcdefghijklmnopqrstuvwxyz123456"
        do {
            _ = try await compiler.compile(
                source: "API key: \(rawSecret)",
                descriptor: safeDescriptor,
                updatedAt: fixedDate
            )
            Issue.record("secret-bearing source unexpectedly compiled")
        } catch let error as ContextMarkdownCompilerError {
            #expect(error == .secretLikeContent)
            #expect(!error.description.contains(rawSecret))
        }
        #expect(await provider.batches().isEmpty)
    }

    /// INVERTED 2026-07-25: this used to pin sourceHash == plain
    /// sha256(content). That contract was the bug — the coordinator only
    /// accepts a recompile when sourceHash changes, so a compiler-output
    /// change (v2 per-fact USER.md atomization) could never reach the live
    /// store for unchanged bytes. The hash now folds in
    /// ContextMarkdownCompiler.compilerFormatVersion; this test pins that it
    /// is deterministic, version-sensitive, and deliberately NOT the bare
    /// content digest (so nobody "simplifies" the version back out).
    @Test
    func sourceHashIsVersionStampedNotBareContentDigest() async throws {
        let provider = RecordingEmbeddingProvider()
        let compiler = ContextMarkdownCompiler(embeddingProvider: provider)
        let compiled = try await compiler.compile(
            source: "abc",
            descriptor: descriptor(name: "note.md", kind: .other, authority: .canonical),
            updatedAt: fixedDate
        )
        let bareContentSHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(compiled.sourceHash != bareContentSHA,
                "a bare content digest can never carry a compiler-format bump")
        #expect(compiled.atoms[0].sourceHash == compiled.sourceHash)
        let again = try await compiler.compile(
            source: "abc",
            descriptor: descriptor(name: "note.md", kind: .other, authority: .canonical),
            updatedAt: fixedDate
        )
        #expect(again.sourceHash == compiled.sourceHash, "hash must stay deterministic")
    }

    private var fixedDate: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private func descriptor(
        name: String,
        kind: ContextSourceKind,
        authority: ContextAuthority
    ) -> ContextSourceDescriptor {
        ContextSourceDescriptor(
            id: ContextStableID.source(owner: kind.rawValue, locator: name),
            owner: kind.rawValue,
            kind: kind,
            canonicalLocator: name,
            authority: authority,
            privacy: .localPrivate,
            permittedSurfaces: [.chat, .bridge],
            injectionPolicy: kind == .persona ? .always : .adaptive
        )
    }

    private func semantic(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func expectError(
        _ expected: ContextMarkdownCompilerError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("expected compiler error \(expected)")
        } catch let error as ContextMarkdownCompilerError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

private actor RecordingEmbeddingProvider: ContextMarkdownEmbeddingProvider {
    nonisolated let modelFingerprint = "test-minilm-v1"
    private var recordedBatches: [[String]] = []

    func embed(_ texts: [String]) async throws -> [[Float]] {
        recordedBatches.append(texts)
        return texts.map { text in
            let total = text.utf8.reduce(0) { ($0 + Int($1)) % 10_000 }
            return [Float(total), Float(text.utf8.count)]
        }
    }

    func batches() -> [[String]] {
        recordedBatches
    }

    func reset() {
        recordedBatches.removeAll()
    }
}

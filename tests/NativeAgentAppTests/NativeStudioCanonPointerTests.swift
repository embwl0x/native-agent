import Context
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// Desk 903 phase 4, the reach half: a decided canon row becomes the SAME
/// recall-pointer shape a journal entry does — one extra source kind, nothing
/// more. These pin the two things that could go wrong: the canon becoming prompt
/// mass, and the canon becoming a score.
@Suite("Studio canon pointers")
struct NativeStudioCanonPointerTests {
    @Test("canon read failure retains last-good canon; confirmed empty retires it")
    func unavailableCanonIsNotEmptyCanon() async throws {
        enum Failure: Error { case unavailable }
        let old = try await projection(canon: [member()]).compiledProjection(previousSources: [:])
        let previous = Dictionary(uniqueKeysWithValues: old.changedSources.map { ($0.descriptor.id, $0) })
        let failed = try await NativeStudioContextProjection(loadEntries: { [] },
            loadCanon: { throw Failure.unavailable }, diagnostics: { _ in })
            .compiledProjection(previousSources: previous)
        #expect(failed.removedSourceIDs.isEmpty)
        #expect(failed.changedSources.isEmpty)
        let empty = try await projection().compiledProjection(previousSources: previous)
        #expect(empty.removedSourceIDs.contains(NativeStudioContextProjection.canonSourceID))
        do {
            _ = try await NativeStudioContextProjection(loadEntries: { [] },
                loadCanon: { throw CancellationError() }, diagnostics: { _ in })
                .compiledProjection(previousSources: previous)
            Issue.record("Cancelled canon read must not publish a replacement")
        } catch is CancellationError { }
    }

    private func projection(
        entries: [StudioJournalEntry] = [],
        canon: [StudioCanonMember] = []
    ) -> NativeStudioContextProjection {
        NativeStudioContextProjection(
            loadEntries: { entries },
            loadCanon: { canon },
            diagnostics: { _ in }
        )
    }

    private func member(
        title: String = "The Green Ray",
        creator: String? = "Éric Rohmer",
        standing: StudioCanonStanding = .canon
    ) -> StudioCanonMember {
        StudioCanonMember(
            workTitle: title,
            workCreator: creator,
            standing: standing,
            since: "2026-09-01T12:00:00.000000Z",
            evidenceEntryIDs: ["entry_b", "entry_c", "entry_d"]
        )
    }

    @Test("a canon row becomes one bounded, adaptive, private POINTER — never the judgment")
    func canonProjectsAsPointer() async throws {
        let result = try await projection(canon: [member()])
            .compiledProjection(previousSources: [:])
        let source = try #require(result.changedSources.first)
        #expect(source.descriptor.canonicalLocator == "studio/canon")
        #expect(source.descriptor.injectionPolicy == .adaptive)
        let atom = try #require(source.atoms.first)
        #expect(atom.kind == .evidence)
        #expect(atom.injectionPolicy == .adaptive)
        #expect(atom.privacy == .localPrivate)
        #expect(!atom.permittedSurfaces.contains(.slack))

        #expect(atom.body.contains("The Green Ray"))
        #expect(atom.body.contains("canon"))
        // The evidence is COUNTED and the pull is named; the argument itself
        // stays in the journal, one pull away.
        #expect(atom.body.contains("evidence 3 entries"))
        #expect(atom.body.contains("pull: studio_canon"))
        #expect(atom.body.utf8.count <= 512)
        // Selection keys are the work's own names, exactly like a journal
        // pointer — so a canon row cannot show up on an ops turn either.
        #expect(atom.entities.contains { $0.label == "The Green Ray" })
        #expect(atom.entities.allSatisfy { $0.kind == ContextCorrectionScope.studioEntityKind })
    }

    @Test("an anti-canon row says so, and carries no more weight than a canon one")
    func antiCanonIsNamedAndUnranked() async throws {
        let result = try await projection(canon: [
            member(title: "A Loud Building", creator: nil, standing: .antiCanon),
            member(),
        ]).compiledProjection(previousSources: [:])
        let source = try #require(result.changedSources.first)
        #expect(source.atoms.count == 2)
        #expect(source.atoms.contains { $0.body.contains("anti-canon") })
        // NO SCORES. Canon membership is a different fact, not a higher rank.
        let values = Set(source.atoms.map(\.confidence))
        #expect(values == [NativeStudioContextProjection.pointerConfidence])
    }

    /// NO PROMPT MASS. An empty museum publishes nothing at all — not an empty
    /// source, not a placeholder atom.
    @Test("an empty canon adds no source and no atoms")
    func emptyCanonIsSilent() async throws {
        let result = try await projection().compiledProjection(previousSources: [:])
        #expect(result.changedSources.isEmpty)
        #expect(NativeStudioContextProjection.prepareCanon([]) == nil)
    }

    /// The canon must not fail the whole studio projection: journal pointers
    /// still reach the turn when the canon cannot be read.
    @Test("an unreadable canon is an empty canon, and the journal still projects")
    func unreadableCanonDoesNotSinkTheJournal() async throws {
        enum ProbeError: Error { case unreadable }
        let projection = NativeStudioContextProjection(
            loadEntries: {
                [StudioJournalEntry(
                    id: "entry_a",
                    encounteredAt: "2026-09-01T12:00:00.000000Z",
                    recordedAt: "2026-09-01T12:00:00.000000Z",
                    work: StudioWork(title: "The Green Ray"),
                    origin: StudioOrigin(kind: .wandering),
                    response: "It holds.",
                    stance: StudioStanceValue(kind: .formed)
                )]
            },
            loadCanon: { throw ProbeError.unreadable },
            diagnostics: { _ in }
        )
        let result = try await projection.compiledProjection(previousSources: [:])
        #expect(result.changedSources.count == 1)
        #expect(result.changedSources.first?.atoms.first?.body.contains("studio_recall") == true)
    }
}

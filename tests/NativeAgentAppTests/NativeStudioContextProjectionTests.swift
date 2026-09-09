import Context
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// Desk 903 phase 5 — "taste by recall pointer", the piece the agent said
/// matters most: "never called in production means pull failed."
///
/// These pin the two halves of that. The pointer must be REACHABLE when a work,
/// creator or medium is named (or the turn is a taste judgment), and it must be
/// ABSENT — excluded with a receipt, not merely outranked — on everything else.
@Suite("Studio context projection")
struct NativeStudioContextProjectionTests {

    @Test func shelfAddsOnlyOneBoundedTitlesLineEvenWithoutJournalEntries() async throws {
        let line = "Working shelf: " + Array(repeating: String(repeating: "x", count: 120), count: 3)
            .joined(separator: "; ") + "; open with studio_shelf_read"
        for entries in [[], [journalEntry(id: "one", title: String(repeating: "A", count: 120))]] {
            let result = try await NativeStudioContextProjection(
                loadEntries: { entries }, loadCanon: { [] }, loadShelfPointer: { line }
            ).compiledProjection(previousSources: [:])
            let atoms = result.changedSources.flatMap(\.atoms)
            #expect(atoms.filter { $0.body == line }.count == 1)
            #expect(atoms.allSatisfy { $0.body.utf8.count <= 512 })
            #expect(atoms.allSatisfy { !$0.permittedSurfaces.contains(.slack) })
        }
        let empty = try await NativeStudioContextProjection(
            loadEntries: { [] }, loadCanon: { [] }, loadShelfPointer: { nil }
        ).compiledProjection(previousSources: [:])
        #expect(empty.changedSources.isEmpty)
        let populated = try await NativeStudioContextProjection(
            loadEntries: { throw ProbeError.unreadable }, loadCanon: { [] }, loadShelfPointer: { line },
            diagnostics: { _ in }
        ).compiledProjection(previousSources: [:])
        let source = try #require(populated.changedSources.first)
        #expect(source.atoms.first?.body == line)
        let cleared = try await NativeStudioContextProjection(
            loadEntries: { throw ProbeError.unreadable }, loadCanon: { [] }, loadShelfPointer: { nil },
            diagnostics: { _ in }
        ).compiledProjection(previousSources: [source.descriptor.id: source])
        #expect(cleared.removedSourceIDs == [source.descriptor.id])
    }

    @Test("a journal entry becomes a bounded, adaptive, private pointer atom")
    func entryProjectsAsSelectablePointerAtom() async throws {
        let result = try await projection(entries: [
            journalEntry(
                id: "entry_20260901T120000_aaaa",
                title: "The Green Ray",
                creator: "Éric Rohmer",
                medium: "film",
                response: "The colour holds because he refuses to explain it.",
                refs: ["/tmp/green-ray-still.png"]
            )
        ]).compiledProjection(previousSources: [:])

        let source = try #require(result.changedSources.first)
        let atom = try #require(source.atoms.first)
        #expect(atom.kind == .evidence)
        // Reach, never weight: nothing here is ever unconditionally injected.
        #expect(atom.injectionPolicy == .adaptive)
        #expect(source.descriptor.injectionPolicy == .adaptive)
        #expect(atom.privacy == .localPrivate)
        // Her aesthetic life is private. Slack is prompt-injectable and stays
        // outside the local-private tier.
        #expect(!atom.permittedSurfaces.contains(.slack))
        #expect(atom.permittedSurfaces.contains(.chat))

        // The atom is a POINTER: the work, the entry id, the stance, how to
        // pull it. The judgment itself is deliberately not here.
        #expect(atom.body.contains("The Green Ray"))
        #expect(atom.body.contains("Éric Rohmer"))
        #expect(atom.body.contains("entry_20260901T120000_aaaa"))
        #expect(atom.body.contains("studio_recall"))
        #expect(!atom.body.contains("refuses to explain"))
        #expect(atom.body.utf8.count <= 512)

        // An artifact ref renders as TEXT. Nothing dereferences it.
        #expect(atom.body.contains("/tmp/green-ray-still.png"))
    }

    /// Her veto, enforced structurally: there is no rating on an entry, and the
    /// projection must not invent one by ranking her judgments against each
    /// other. Every pointer carries the same neutral confidence.
    @Test("no pointer outranks another — there is no taste score anywhere")
    func pointersCarryNoScore() async throws {
        let result = try await projection(entries: [
            journalEntry(id: "entry_a", title: "A", response: "Yes, entirely.", stance: .formed),
            journalEntry(id: "entry_b", title: "B", response: nil, stance: .abstained),
            journalEntry(id: "entry_c", title: "C", response: "Not enough of it yet.", stance: .open),
        ]).compiledProjection(previousSources: [:])
        let atoms = result.changedSources.flatMap(\.atoms)
        #expect(atoms.count == 3)
        #expect(Set(atoms.map(\.confidence)).count == 1)
        // An abstention is a first-class entry, not a missing one.
        #expect(atoms.contains { $0.body.contains("stance abstained") })
    }

    /// The clause-6 line. Selection keys are the work title, the creator and the
    /// medium — never the response, never the stance, never a tag. An ops turn
    /// must get `outsideContextScope`, not a low rank: "if it shows up on ops
    /// turns I'll learn to ignore it, and ignored is worse than absent."
    @Test("judgment words select nothing; the work's name and a taste turn do")
    func onlyEndpointNamesAndTasteTurnsSelect() async throws {
        let result = try await projection(entries: [
            journalEntry(
                id: "entry_ray",
                title: "The Green Ray",
                creator: "Éric Rohmer",
                medium: "film",
                response: "The colour holds because he refuses to explain it.",
                tags: ["patience"]
            )
        ]).compiledProjection(previousSources: [:])

        for atom in result.changedSources.flatMap(\.atoms) {
            #expect(atom.entities.allSatisfy {
                $0.kind == ContextCorrectionScope.studioEntityKind
            })
            let keys = Set(atom.entities.map { $0.label.lowercased() })
                .union(atom.triggers.map { $0.lowercased() })
            #expect(!keys.contains("colour"))
            #expect(!keys.contains("patience"))
            #expect(!keys.contains("formed"))
            #expect(keys.contains("rohmer"))
            #expect(keys.contains("film"))
        }

        let fixture = generation(from: result.changedSources)
        let selector = ContextSelector()

        // An ordinary ops turn: excluded outright, with an honest receipt.
        let ops = try selector.select(
            signal("rerun the build and push the branch", generation: fixture), from: fixture
        )
        #expect(ops.selectedItems.isEmpty)
        for decision in ops.receipt.eligibility {
            #expect(decision.exclusionReason == .outsideContextScope)
        }

        // Naming the work is the ordinary way in.
        let named = try selector.select(
            signal("what did I make of The Green Ray?", generation: fixture), from: fixture
        )
        #expect(named.selectedItems.contains { $0.text.contains("entry_ray") })

        // A taste judgment is the other way in, with the work unnamed.
        let taste = try selector.select(
            signal("design review on this cover — which is better?", generation: fixture),
            from: fixture
        )
        // This is the scope gate, not a mandate to inject every eligible taste
        // pointer. Neutral pointers still compete on relevance and budget.
        #expect(!taste.receipt.eligibility.isEmpty)
        #expect(taste.receipt.eligibility.allSatisfy { $0.exclusionReason != .outsideContextScope })
    }

    /// A work she keeps returning to must not own the whole studio budget.
    @Test("entries group one source per work, newest first, capped")
    func entriesGroupPerWorkAndCap() async throws {
        let many = (0..<8).map { index in
            journalEntry(
                id: "entry_ray_\(index)",
                title: "The Green Ray",
                creator: "Éric Rohmer",
                recordedAt: "2026-08-0\(index + 1)T12:00:00.000000Z"
            )
        } + [journalEntry(id: "entry_other", title: "Kairos", creator: "Jenny Erpenbeck")]

        let result = try await projection(entries: many, perWorkCap: 3)
            .compiledProjection(previousSources: [:])
        #expect(result.changedSources.count == 2)
        let counts = result.changedSources.map(\.atoms.count).sorted()
        #expect(counts == [1, 3])
        let ray = try #require(result.changedSources.first { $0.atoms.count == 3 })
        // Newest first: the entry that revised her mind is reachable before the
        // one it revised.
        #expect(ray.atoms.map(\.body).allSatisfy { body in
            ["entry_ray_7", "entry_ray_6", "entry_ray_5"].contains { body.contains($0) }
        })
        for source in result.changedSources {
            #expect(source.atoms.allSatisfy { $0.sourceID == source.descriptor.id })
        }
    }

    @Test("an unreadable journal keeps the last good pointers instead of failing the generation")
    func unreadableJournalIsLastKnownGoodAndLoud() async throws {
        let logged = StudioDiagnosticsProbe()
        let previous = try await projection(entries: [journalEntry(id: "entry_a", title: "A")])
            .compiledProjection(previousSources: [:])
        let previousBySource = Dictionary(
            uniqueKeysWithValues: previous.changedSources.map { ($0.descriptor.id, $0) }
        )
        let result = try await NativeStudioContextProjection(
            loadEntries: { throw ProbeError.unreadable },
            diagnostics: { logged.record($0) }
        ).compiledProjection(previousSources: previousBySource)
        #expect(result.changedSources.isEmpty)
        #expect(result.removedSourceIDs.isEmpty)
        #expect(logged.count == 1)
    }

    // MARK: - Fixtures

    private enum ProbeError: Error { case unreadable }

    private func projection(
        entries: [StudioJournalEntry],
        perWorkCap: Int = NativeStudioContextProjection.maximumEntriesPerWork
    ) -> NativeStudioContextProjection {
        NativeStudioContextProjection(
            maximumEntriesPerWork: perWorkCap,
            loadEntries: { entries },
            loadCanon: { [] },
            diagnostics: { _ in }
        )
    }

    private func journalEntry(
        id: String,
        title: String,
        creator: String? = nil,
        medium: String? = nil,
        recordedAt: String = "2026-09-01T12:00:00.000000Z",
        response: String? = "A judgment, written out.",
        stance: StudioStance = .formed,
        refs: [String] = [],
        tags: [String] = []
    ) -> StudioJournalEntry {
        StudioJournalEntry(
            id: id,
            encounteredAt: recordedAt,
            recordedAt: recordedAt,
            work: StudioWork(title: title, creator: creator, medium: medium),
            reception: StudioReception(how: "reproduction", wholeOrPart: "whole"),
            artifactRefs: refs,
            origin: StudioOrigin(kind: .wandering),
            response: response,
            stance: StudioStanceValue(kind: stance),
            relations: [],
            tags: tags
        )
    }

    private func generation(from sources: [ContextCompiledSource]) -> ContextStoredGeneration {
        ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: Date(timeIntervalSince1970: 8_000),
                reason: "studio projection fixture",
                sourceFingerprint: "studio-fixture",
                atomCount: sources.reduce(0) { $0 + $1.atoms.count },
                sourceCount: sources.count
            ),
            sources: sources.map {
                ContextStoredSource(
                    descriptor: $0.descriptor,
                    sourceHash: $0.sourceHash,
                    health: .healthy,
                    lastError: nil,
                    validFromGeneration: 1,
                    validToGeneration: nil
                )
            },
            atoms: sources.flatMap(\.atoms).map {
                ContextStoredAtom(
                    versionKey: "\($0.id.rawValue)@1",
                    draft: $0,
                    validFromGeneration: 1,
                    validToGeneration: nil
                )
            },
            relationships: []
        )
    }

    private func signal(
        _ message: String, generation: ContextStoredGeneration
    ) -> NeedSignal {
        NeedSignal(
            message: message,
            surface: .chat,
            origin: .localAuthenticated,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: [.localAuthenticated],
                allowedPrivacy: [.localPrivate, .trustedRemote, .publicSafe],
                allowedSourceIDs: Set(generation.sources.map(\.descriptor.id))
            ),
            availableGenerationID: generation.generation.id,
            characterBudget: 5_000,
            now: Date(timeIntervalSince1970: 10_000),
            cacheState: .hit
        )
    }
}

/// `diagnostics` is a `@Sendable` closure, so the probe has to be too. The
/// knowledge-graph projection test keeps its own private one; this is ours.
private final class StudioDiagnosticsProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func record(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count
    }
}

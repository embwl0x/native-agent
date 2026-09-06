import Context
import Foundation
import KnowledgeGraph
import MemoryV2
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// Fluid Context sweep item 23 (2026-09-01): the knowledge graph was dark on
/// every live turn — its only prompt path was the legacy recall lane's
/// `related:` garnish, which an active ContextFlow turn bypasses. These pin the
/// replacement: relations are projected as bounded, SELECTABLE atoms.
@Suite("Knowledge graph context projection")
struct KnowledgeGraphContextProjectionTests {

    @Test("typed relations become bounded, adaptive relationship atoms")
    func relationsProjectAsSelectableRelationshipAtoms() async throws {
        let projection = NativeKnowledgeGraphContextProjection(
            loadRelations: { [relation(subject: "User", predicate: "works_on", object: "Hermes")] },
            diagnostics: { _ in }
        )
        let result = try await projection.compiledProjection(previousSources: [:])
        let source = try #require(result.changedSources.first)
        let atom = try #require(source.atoms.first)
        #expect(atom.kind == .relationship)
        #expect(atom.body == "User —works_on→ Hermes")
        // Reach, never weight: nothing here is ever unconditionally injected.
        #expect(atom.injectionPolicy == .adaptive)
        #expect(source.descriptor.injectionPolicy == .adaptive)
        #expect(atom.authority == .inferred)
        #expect(atom.privacy == .localPrivate)
        // Slack is prompt-injectable and stays outside the local-private tier,
        // exactly as the memory lane's default disclosure decides.
        #expect(!atom.permittedSurfaces.contains(.slack))
        #expect(atom.permittedSurfaces.contains(.chat))
        #expect(atom.permittedSurfaces.contains(.telegram))
        // Both endpoints are searchable identity for the selector.
        #expect(atom.entities.contains(ContextEntity(kind: "kg_entity", id: "e-user", label: "User")))
        #expect(atom.entities.contains(
            ContextEntity(kind: "kg_entity", id: "e-hermes", label: "Hermes")
        ))
    }

    /// The per-subject and total read caps live in the reader
    /// (`KnowledgeGraphContextRelationsTests`). What the projection owes is the
    /// grouping those caps assume: one source per subject entity, so the
    /// selector's existing `maximumAtomsPerSource` bounds a hub entity inside
    /// any one packet.
    @Test("edges group one source per subject entity")
    func edgesGroupOneSourcePerSubjectEntity() async throws {
        let edges = (0..<10).map { index in
            relation(subject: "User", predicate: "works_on", object: "Project \(index)")
        } + (0..<3).map { index in
            relation(subject: "Agent", predicate: "knows", object: "Person \(index)")
        }
        let projection = NativeKnowledgeGraphContextProjection(
            loadRelations: { edges }, diagnostics: { _ in }
        )
        let result = try await projection.compiledProjection(previousSources: [:])
        #expect(result.changedSources.count == 2)
        let bySubject = Dictionary(
            uniqueKeysWithValues: result.changedSources.map {
                ($0.descriptor.canonicalLocator, $0.atoms.count)
            }
        )
        #expect(bySubject.values.sorted() == [3, 10])
        // Every atom of one subject shares that subject's source, so the
        // selector's per-source cap is what bounds a single hub in a packet.
        for source in result.changedSources {
            #expect(source.atoms.allSatisfy { $0.sourceID == source.descriptor.id })
        }
    }

    /// Clause-6 leak caught in review: the predicate must never be a selection
    /// key. The selector folds `entities` and `triggers` into its lexical index
    /// and its sharedIdentifiers feature, and an atom can clear the relevance
    /// floor on message-token coverage alone — so a predicate admitted there
    /// would let a generic "who owns what, who knows whom" pull edges whose
    /// endpoints the message never named. Relations are reached BY ENTITY.
    @Test("predicate words alone select nothing; the subject entity still does")
    func onlyEndpointNamesAreSelectionKeys() async throws {
        let result = try await NativeKnowledgeGraphContextProjection(
            loadRelations: {
                [
                    relation(subject: "Hermes", predicate: "owns", object: "Ledger"),
                    relation(subject: "Agent", predicate: "knows", object: "Claude"),
                ]
            },
            diagnostics: { _ in }
        ).compiledProjection(previousSources: [:])

        // The predicate is body text and nothing else.
        for atom in result.changedSources.flatMap(\.atoms) {
            // The endpoint kind is what the eligibility gate scopes on.
            #expect(atom.entities.allSatisfy {
                $0.kind == ContextCorrectionScope.relationshipEntityKind
            })
            let keys = Set(atom.entities.flatMap { [$0.id.lowercased(), $0.label.lowercased()] })
                .union(atom.triggers.map { $0.lowercased() })
            #expect(!keys.contains("owns"))
            #expect(!keys.contains("knows"))
        }

        let fixture = generation(from: result.changedSources)
        let selector = ContextSelector()
        let predicateOnly = try selector.select(
            signal("who owns what and who knows whom", generation: fixture), from: fixture
        )
        #expect(predicateOnly.selectedItems.isEmpty)
        #expect(predicateOnly.receipt.selectedAtomIDs.isEmpty)

        // An untouched edge is EXCLUDED, with a receipt — not merely outranked.
        for decision in predicateOnly.receipt.eligibility {
            #expect(decision.exclusionReason == .outsideContextScope)
        }

        let byEntity = try selector.select(
            signal("what is Hermes connected to?", generation: fixture), from: fixture
        )
        let selectedBodies = byEntity.selectedItems.map(\.text)
        #expect(selectedBodies.contains("Hermes —owns→ Ledger"))
        #expect(!selectedBodies.contains("Agent —knows→ Claude"))
    }

    @Test("an unreadable graph keeps the last good relations instead of failing the generation")
    func unreadableGraphIsLastKnownGoodAndLoud() async throws {
        let logged = DiagnosticsProbe()
        let projection = NativeKnowledgeGraphContextProjection(
            loadRelations: { throw ProbeError.unreadable },
            diagnostics: { logged.record($0) }
        )
        let previous = try await NativeKnowledgeGraphContextProjection(
            loadRelations: { [relation(subject: "User", predicate: "owns", object: "Hermes")] },
            diagnostics: { _ in }
        ).compiledProjection(previousSources: [:])
        let previousBySource = Dictionary(
            uniqueKeysWithValues: previous.changedSources.map { ($0.descriptor.id, $0) }
        )
        let result = try await projection.compiledProjection(previousSources: previousBySource)
        #expect(result.changedSources.isEmpty)
        #expect(result.removedSourceIDs.isEmpty)
        #expect(logged.count == 1)
    }

    @Test("a retired edge retires its atom; an unchanged one republishes nothing")
    func retiredSubjectIsRemovedAndUnchangedSubjectIsQuiet() async throws {
        let first = try await NativeKnowledgeGraphContextProjection(
            loadRelations: {
                [
                    relation(subject: "User", predicate: "owns", object: "Hermes"),
                    relation(subject: "Agent", predicate: "knows", object: "Claude"),
                ]
            },
            diagnostics: { _ in }
        ).compiledProjection(previousSources: [:])
        let previous = Dictionary(
            uniqueKeysWithValues: first.changedSources.map { ($0.descriptor.id, $0) }
        )
        let second = try await NativeKnowledgeGraphContextProjection(
            loadRelations: { [relation(subject: "User", predicate: "owns", object: "Hermes")] },
            diagnostics: { _ in }
        ).compiledProjection(previousSources: previous)
        #expect(second.changedSources.isEmpty)
        #expect(second.removedSourceIDs.count == 1)
    }

    // MARK: - Fixtures

    private enum ProbeError: Error { case unreadable }

    /// A stored generation over exactly what the projection published, so the
    /// selector under test sees the production atom shape.
    private func generation(from sources: [ContextCompiledSource]) -> ContextStoredGeneration {
        ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: Date(timeIntervalSince1970: 8_000),
                reason: "kg projection fixture",
                sourceFingerprint: "kg-fixture",
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

    private func relation(
        subject: String,
        predicate: String,
        object: String
    ) -> KnowledgeGraphContextRelation {
        KnowledgeGraphContextRelation(
            subjectID: "e-\(subject.lowercased())",
            subject: subject,
            predicate: predicate,
            objectID: "e-\(object.lowercased().replacingOccurrences(of: " ", with: "-"))",
            object: object,
            weight: 0.7,
            mentionCount: 3,
            lastSeen: "2026-08-30T12:00:00Z"
        )
    }
}

/// Fluid Context sweep item 24: skill pointers arrive on the active lane as
/// ordinary `.memory` atoms. The PROCEDURAL content role is what the selector's
/// reservation keys on, so the stamp has to survive the projection.
@Suite("Skill pointers keep a procedural role on the ContextFlow lane")
struct SkillPointerProjectionRoleTests {

    @Test("a skill-pointer record projects with the procedure content role")
    func skillPointerCarriesProcedureRole() async throws {
        let memory = RoleProbeMemory(records: [
            record(
                id: "skill-pointer:git-rescue",
                text: "Skill available: git-rescue — recover from a bad reset or lost commits.",
                kind: "skill"
            ),
            record(
                id: "mem-1",
                text: "User prefers concise summaries over long narration.",
                kind: "preference"
            ),
        ])
        let result = try await NativeMemoryContextProjection(memory: memory)
            .compiledProjection(previousSources: [:])
        let atoms = result.changedSources.flatMap(\.atoms)
        let skill = try #require(atoms.first { $0.body.hasPrefix("Skill available:") })
        let plain = try #require(atoms.first { !$0.body.hasPrefix("Skill available:") })
        #expect(skill.kind == .memory)
        #expect(skill.contentRole == .procedure)
        #expect(plain.kind == .memory)
        #expect(plain.contentRole == .memory)
        #expect(skill.sourceHash != plain.sourceHash)
    }

    private func record(
        id: String, text: String, kind: String
    ) -> NativeMemoryProjectionRecord {
        NativeMemoryProjectionRecord(
            id: id,
            text: text,
            layer: "semantic",
            memoryKind: kind,
            createdAt: "2026-08-30T12:00:00Z",
            updatedAt: "2026-08-30T12:01:00Z",
            sourceRunId: "role-probe",
            status: "active",
            pinned: nil,
            confidence: 0.9,
            importance: 0.5,
            tags: nil,
            sourceQuality: nil,
            decay: nil,
            correction: nil,
            provenance: nil,
            extras: nil
        )
    }
}

/// `diagnostics` is a `@Sendable` closure, so the probe has to be too.
private final class DiagnosticsProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func record(_ line: String) { lock.withLock { lines.append(line) } }
    var count: Int { lock.withLock { lines.count } }
}

private actor RoleProbeMemory: NativeMemoryContextProjectionMemory {
    private let records: [NativeMemoryProjectionRecord]

    init(records: [NativeMemoryProjectionRecord]) {
        self.records = records
    }

    func listContextProjectionRecords() async throws -> [NativeMemoryProjectionRecord] {
        records
    }

    func contextProjectionEmbeddingModelFingerprint() async throws -> String {
        "role-probe:1"
    }

    func embedForDerivedContext(_ texts: [String]) async throws -> [[Float]] {
        texts.map { [Float($0.utf8.count), 1, 0] }
    }
}

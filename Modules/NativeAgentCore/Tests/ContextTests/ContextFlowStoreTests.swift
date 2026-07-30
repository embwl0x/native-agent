import Context
import Foundation
import Testing

@Suite(.serialized)
struct ContextFlowStoreTests {
    @Test
    func stableIDsAreDeterministicAndLengthDelimited() {
        let sourceA = ContextStableID.source(owner: "persona", locator: "SOUL.md")
        let sourceB = ContextStableID.source(owner: "persona", locator: "SOUL.md")
        #expect(sourceA == sourceB)

        let joinedA = ContextStableID.digest(parts: ["ab", "c"])
        let joinedB = ContextStableID.digest(parts: ["a", "bc"])
        #expect(joinedA != joinedB)

        let atomA = ContextStableID.atom(
            sourceID: sourceA,
            kind: .identity,
            headingPath: ["Core"],
            blockAnchor: "0"
        )
        let atomB = ContextStableID.atom(
            sourceID: sourceA,
            kind: .identity,
            headingPath: ["Core"],
            blockAnchor: "0"
        )
        #expect(atomA == atomB)
    }

    @Test
    func publishAndLoadRoundTripsSourceAtomsRelationshipsAndEmbedding() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let soul = makeSource(name: "SOUL.md", body: "Agent is one continuous mind.", ordinal: 1)
        let voice = makeSource(name: "VOICE.md", body: "Speak directly.", ordinal: 2)
        let relationship = ContextRelationshipDraft(
            id: ContextStableID.relationship(
                source: soul.atoms[0].id,
                target: voice.atoms[0].id,
                kind: "supports"
            ),
            sourceAtomID: soul.atoms[0].id,
            targetAtomID: voice.atoms[0].id,
            kind: "supports",
            weight: 0.8,
            provenance: "test"
        )
        let soulWithRelationship = ContextCompiledSource(
            descriptor: soul.descriptor,
            sourceHash: soul.sourceHash,
            atoms: soul.atoms,
            relationships: [relationship]
        )

        let published = try await fixture.store.publish(ContextGenerationDraft(
            reason: "initial",
            changedSources: [soulWithRelationship, voice],
            createdAt: Date(timeIntervalSince1970: 10)
        ))

        #expect(published.id == 1)
        #expect(published.parentID == nil)
        #expect(published.atomCount == 2)
        #expect(published.sourceCount == 2)

        let loaded = try await fixture.store.loadGeneration(id: 1)
        #expect(loaded.sources.count == 2)
        #expect(loaded.atoms.count == 2)
        #expect(loaded.relationships == [ContextStoredRelationship(
            versionKey: relationship.id.rawValue + "@1",
            draft: relationship,
            validFromGeneration: 1,
            validToGeneration: nil
        )])
        #expect(loaded.atoms.first(where: { $0.draft.sourceID == soul.descriptor.id })?.draft.embedding?.values == [0.1, 0.2, 0.3])
    }

    @Test
    func changingOneSourcePreservesOldGenerationAndUnchangedSource() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let soulV1 = makeSource(name: "SOUL.md", body: "Original identity.", ordinal: 1)
        let voice = makeSource(name: "VOICE.md", body: "Original voice.", ordinal: 2)
        let first = try await fixture.store.publish(ContextGenerationDraft(
            reason: "initial",
            changedSources: [soulV1, voice],
            createdAt: Date(timeIntervalSince1970: 10)
        ))

        let soulV2 = makeSource(
            name: "SOUL.md",
            body: "Updated identity.",
            ordinal: 1,
            stableAtomID: soulV1.atoms[0].id
        )
        let second = try await fixture.store.publish(ContextGenerationDraft(
            reason: "soul edit",
            changedSources: [soulV2],
            createdAt: Date(timeIntervalSince1970: 20)
        ))

        #expect(second.id == 2)
        #expect(second.parentID == first.id)
        #expect(second.sourceFingerprint != first.sourceFingerprint)

        let old = try await fixture.store.loadGeneration(id: 1)
        let current = try await fixture.store.loadGeneration(id: 2)
        #expect(old.atoms.first(where: { $0.draft.sourceID == soulV1.descriptor.id })?.draft.body == "Original identity.")
        #expect(current.atoms.first(where: { $0.draft.sourceID == soulV1.descriptor.id })?.draft.body == "Updated identity.")
        #expect(current.atoms.first(where: { $0.draft.sourceID == voice.descriptor.id })?.draft.body == "Original voice.")
        #expect(current.sources.count == 2)
    }

    @Test
    func invalidRelationshipRollsBackEntireGeneration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let soul = makeSource(name: "SOUL.md", body: "Last good.", ordinal: 1)
        _ = try await fixture.store.publish(ContextGenerationDraft(
            reason: "initial",
            changedSources: [soul]
        ))

        let changed = makeSource(
            name: "SOUL.md",
            body: "Must not publish.",
            ordinal: 1,
            stableAtomID: soul.atoms[0].id
        )
        let missingTarget = ContextAtomID(rawValue: "atom:missing")
        let brokenRelationship = ContextRelationshipDraft(
            id: ContextStableID.relationship(
                source: changed.atoms[0].id,
                target: missingTarget,
                kind: "broken"
            ),
            sourceAtomID: changed.atoms[0].id,
            targetAtomID: missingTarget,
            kind: "broken",
            weight: 1,
            provenance: "test"
        )
        let brokenSource = ContextCompiledSource(
            descriptor: changed.descriptor,
            sourceHash: changed.sourceHash,
            atoms: changed.atoms,
            relationships: [brokenRelationship]
        )

        do {
            _ = try await fixture.store.publish(ContextGenerationDraft(
                reason: "broken edit",
                changedSources: [brokenSource]
            ))
            Issue.record("broken relationship unexpectedly published")
        } catch let error as ContextFlowStoreError {
            #expect(error == .relationshipTargetMissing(missingTarget.rawValue))
        }

        let active = try #require(await fixture.store.loadActiveGeneration())
        #expect(active.generation.id == 1)
        #expect(active.atoms.map(\.draft.body) == ["Last good."])
    }

    @Test
    func removalDoesNotResurrectInLaterGeneration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let soul = makeSource(name: "SOUL.md", body: "Identity.", ordinal: 1)
        let project = makeSource(name: "project.md", body: "Old project.", ordinal: 2, kind: .project)
        _ = try await fixture.store.publish(ContextGenerationDraft(
            reason: "initial",
            changedSources: [soul, project]
        ))
        _ = try await fixture.store.publish(ContextGenerationDraft(
            reason: "remove project",
            changedSources: [],
            removedSourceIDs: [project.descriptor.id]
        ))

        let current = try #require(await fixture.store.loadActiveGeneration())
        #expect(current.sources.map(\.descriptor.id).contains(project.descriptor.id) == false)
        #expect(current.atoms.map(\.draft.sourceID).contains(project.descriptor.id) == false)

        let old = try await fixture.store.loadGeneration(id: 1)
        #expect(old.atoms.map(\.draft.sourceID).contains(project.descriptor.id))
    }

    @Test
    func degradedSourceKeepsLastGoodGeneration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let soul = makeSource(name: "SOUL.md", body: "Identity.", ordinal: 1)
        _ = try await fixture.store.publish(ContextGenerationDraft(
            reason: "initial",
            changedSources: [soul]
        ))
        try await fixture.store.markSourceDegraded(soul.descriptor.id, error: "partial write")

        let health = try await fixture.store.healthSnapshot()
        #expect(health.activeGenerationID == 1)
        #expect(health.degradedSources == 1)
        #expect(health.activeAtoms == 1)

        let active = try #require(await fixture.store.loadActiveGeneration())
        #expect(active.atoms.map(\.draft.body) == ["Identity."])
        let receipts = try await fixture.store.recentReceipts()
        #expect(receipts.contains(where: { $0.kind == .degraded }))
    }

    @Test
    func pruneRetainsLatestAndExplicitlyProtectedGenerations() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        var stableAtomID: ContextAtomID?
        for generation in 1...6 {
            let source = makeSource(
                name: "SOUL.md",
                body: "Identity \(generation).",
                ordinal: 1,
                stableAtomID: stableAtomID
            )
            stableAtomID = source.atoms[0].id
            _ = try await fixture.store.publish(ContextGenerationDraft(
                reason: "edit \(generation)",
                changedSources: [source],
                createdAt: Date(timeIntervalSince1970: Double(generation))
            ))
        }

        let result = try await fixture.store.prune(
            retainingLatest: 2,
            protectedGenerationIDs: [2],
            receiptLimit: 2
        )
        #expect(result.deletedGenerations == 3)
        #expect(result.deletedReceipts == 4)
        #expect(try await fixture.store.loadGeneration(id: 2).atoms.map(\.draft.body) == ["Identity 2."])
        #expect(try await fixture.store.loadGeneration(id: 5).atoms.map(\.draft.body) == ["Identity 5."])
        #expect(try await fixture.store.loadGeneration(id: 6).atoms.map(\.draft.body) == ["Identity 6."])

        do {
            _ = try await fixture.store.loadGeneration(id: 1)
            Issue.record("pruned generation still loaded")
        } catch let error as ContextFlowStoreError {
            #expect(error == .generationNotFound(1))
        }
    }

    @Test
    func vacuumReclaimsSpaceAfterPrune() async throws {
        // A5.5(b): prune() DELETEs rows but SQLite keeps the freed pages, so the
        // file never shrinks without VACUUM. Publish a fat history, prune most of
        // it, then VACUUM and confirm the on-disk file actually got smaller AND
        // the surviving generations still read.
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        var stableAtomID: ContextAtomID? = nil
        // Big-ish bodies so freed pages are measurable after the DELETEs.
        let filler = String(repeating: "context payload blob ", count: 400)
        for generation in 1...40 {
            let source = makeSource(
                name: "SOUL.md",
                body: "Identity \(generation). \(filler)",
                ordinal: 1,
                stableAtomID: stableAtomID
            )
            stableAtomID = source.atoms[0].id
            _ = try await fixture.store.publish(ContextGenerationDraft(
                reason: "edit \(generation)",
                changedSources: [source],
                createdAt: Date(timeIntervalSince1970: Double(generation))
            ))
        }

        let dbPath = fixture.root
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("context.sqlite").path
        func fileSize() -> Int64 {
            (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0
        }

        let result = try await fixture.store.prune(retainingLatest: 2, receiptLimit: 2)
        #expect(result.totalDeleted > 0)
        let sizeAfterPrune = fileSize()

        try await fixture.store.vacuum()
        let sizeAfterVacuum = fileSize()

        // VACUUM must have reclaimed at least some of the pages the prune freed.
        #expect(sizeAfterVacuum < sizeAfterPrune,
                "VACUUM did not shrink the file: \(sizeAfterVacuum) vs \(sizeAfterPrune)")
        // And the store is still fully readable afterwards.
        #expect(try await fixture.store.loadGeneration(id: 40).atoms.map(\.draft.body).first?.hasPrefix("Identity 40.") == true)
    }

    @Test
    func resetDeletesOnlyDerivedState() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let canonical = fixture.root.appendingPathComponent("SOUL.md")
        try "Canonical identity".write(to: canonical, atomically: true, encoding: .utf8)
        _ = try await fixture.store.publish(ContextGenerationDraft(
            reason: "initial",
            changedSources: [makeSource(name: "SOUL.md", body: "Canonical identity", ordinal: 1)]
        ))

        try await fixture.store.resetDerivedState()
        #expect(try await fixture.store.activeGeneration() == nil)
        #expect(try String(contentsOf: canonical, encoding: .utf8) == "Canonical identity")
    }

    private struct Fixture {
        let root: URL
        let store: ContextSQLiteStore

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextFlowStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root, store: try ContextSQLiteStore(dataRoot: root))
    }

    private func makeSource(
        name: String,
        body: String,
        ordinal: Int,
        stableAtomID: ContextAtomID? = nil,
        kind: ContextSourceKind = .persona
    ) -> ContextCompiledSource {
        let sourceID = ContextStableID.source(owner: kind.rawValue, locator: name)
        let sourceHash = ContextStableID.digest(parts: [body])
        let atomID = stableAtomID ?? ContextStableID.atom(
            sourceID: sourceID,
            kind: kind == .persona ? .identity : .project,
            headingPath: [name],
            blockAnchor: String(ordinal)
        )
        let descriptor = ContextSourceDescriptor(
            id: sourceID,
            owner: kind.rawValue,
            kind: kind,
            canonicalLocator: name,
            authority: kind == .persona ? .identity : .external,
            privacy: .localPrivate,
            permittedSurfaces: [.chat, .bridge],
            injectionPolicy: kind == .persona ? .always : .adaptive
        )
        let atom = ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: kind == .persona ? .identity : .project,
            headingPath: [name],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: sourceHash,
            body: body,
            deterministicSummary: body,
            authority: descriptor.authority,
            confidence: 1,
            freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: Double(ordinal))),
            privacy: descriptor.privacy,
            permittedSurfaces: descriptor.permittedSurfaces,
            injectionPolicy: descriptor.injectionPolicy,
            contentRole: kind == .persona ? .identity : .untrustedExternalData,
            entities: [ContextEntity(kind: "document", id: name, label: name)],
            triggers: [name],
            embedding: ContextEmbedding(modelFingerprint: "test-minilm", values: [0.1, 0.2, 0.3])
        )
        return ContextCompiledSource(
            descriptor: descriptor,
            sourceHash: sourceHash,
            atoms: [atom]
        )
    }
}

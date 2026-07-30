import Foundation
import Testing
@testable import Context

@Suite("Context expansion")
struct ContextExpansionTests {
    private let now = Date(timeIntervalSince1970: 20_000)

    @Test
    func expansionIsGenerationPinnedDeterministicAndBounded() throws {
        let body = "Alpha 😀 café expansion body"
        let atom = makeAtom(body: body, rangeStart: 31)
        let generation = makeGeneration(atom: atom)
        let pointer = ContextAtomPointer(atom: atom, generationID: generation.generation.id)
        let snapshot = try ContextGenerationSnapshot(
            generationID: generation.generation.id,
            sourceFingerprint: generation.generation.sourceFingerprint
        )
        let expander = ContextExpander(configuration: .init(maximumCharacters: 8))
        let need = makeNeed(generation: generation)

        let first = try expander.expand(
            pointer,
            for: need,
            from: generation,
            pinnedTo: snapshot,
            maximumCharacters: 20
        )
        let second = try expander.expand(
            pointer,
            for: need,
            from: generation,
            pinnedTo: snapshot,
            maximumCharacters: 20
        )

        #expect(first == second)
        #expect(first.text == String(body.prefix(8)))
        #expect(first.characterCount == 8)
        #expect(first.truncated)
        #expect(first.receipt.characterLimit == 8)
        #expect(first.receipt.returnedUTF8ByteCount == first.text.utf8.count)
        #expect(first.receipt.generationID == generation.generation.id)
        #expect(first.receipt.sourceFingerprint == generation.generation.sourceFingerprint)
        #expect(first.receipt.surface == .chat)
        #expect(first.receipt.origin == .localAuthenticated)
    }

    @Test
    func rejectsInvalidLimitAndEveryGenerationMismatch() throws {
        let atom = makeAtom()
        let generation = makeGeneration(atom: atom)
        let pointer = ContextAtomPointer(atom: atom, generationID: generation.generation.id)
        let expander = ContextExpander()

        #expect(expansionError(
            expander,
            pointer: pointer,
            need: makeNeed(generation: generation),
            generation: generation,
            maximumCharacters: 0
        ) == .invalidCharacterLimit)

        let wrongNeed = makeNeed(generation: generation, availableGenerationID: 91)
        #expect(expansionError(
            expander,
            pointer: pointer,
            need: wrongNeed,
            generation: generation
        ) == .requestedGenerationMismatch(requested: 91, actual: 7))

        let stalePointer = ContextAtomPointer(atom: atom, generationID: 6)
        #expect(expansionError(
            expander,
            pointer: stalePointer,
            need: makeNeed(generation: generation),
            generation: generation
        ) == .pointerGenerationMismatch(pointer: 6, generation: 7))

        let wrongGenerationSnapshot = try ContextGenerationSnapshot(
            generationID: 8,
            sourceFingerprint: generation.generation.sourceFingerprint
        )
        #expect(expansionError(
            expander,
            pointer: pointer,
            need: makeNeed(generation: generation),
            generation: generation,
            snapshot: wrongGenerationSnapshot
        ) == .snapshotGenerationMismatch(snapshot: 8, generation: 7))

        let wrongFingerprintSnapshot = try ContextGenerationSnapshot(
            generationID: 7,
            sourceFingerprint: "wrong-fingerprint"
        )
        #expect(expansionError(
            expander,
            pointer: pointer,
            need: makeNeed(generation: generation),
            generation: generation,
            snapshot: wrongFingerprintSnapshot
        ) == .snapshotFingerprintMismatch)
    }

    @Test
    func rejectsPointersThatDoNotExactlyMatchStoredAtomAndSource() {
        let atom = makeAtom()
        let source = makeSource(for: atom)
        let generation = makeGeneration(atom: atom, source: source)
        let need = makeNeed(generation: generation)
        let expander = ContextExpander()

        let unknown = makeAtom(atomID: "atom:unknown")
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: unknown, generationID: 7),
            need: need,
            generation: generation
        ) == .atomNotFound(unknown.draft.id))

        let wrongSource = makeAtom(sourceID: "source:other")
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: wrongSource, generationID: 7),
            need: need,
            generation: generation
        ) == .pointerSourceMismatch(
            pointer: wrongSource.draft.sourceID,
            atom: atom.draft.sourceID
        ))

        let wrongHash = makeAtom(sourceHash: "hash:other")
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: wrongHash, generationID: 7),
            need: need,
            generation: generation
        ) == .pointerSourceHashMismatch(pointer: "hash:other", atom: atom.draft.sourceHash))

        let noSource = makeGeneration(atom: atom, sources: [])
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: atom, generationID: 7),
            need: need,
            generation: noSource
        ) == .sourceNotFound(atom.draft.sourceID))

        let divergentSource = makeSource(for: atom, sourceHash: "hash:divergent")
        let divergentGeneration = makeGeneration(atom: atom, source: divergentSource)
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: atom, generationID: 7),
            need: makeNeed(generation: divergentGeneration),
            generation: divergentGeneration
        ) == .sourceHashMismatch(source: "hash:divergent", atom: atom.draft.sourceHash))
    }

    @Test
    func rejectsSourceRangeThatDoesNotDescribeStoredUTF8Body() {
        let body = "café 😀"
        let atom = makeAtom(
            body: body,
            sourceRange: ContextSourceRange(utf8Start: 10, utf8End: 10 + body.utf8.count - 1)
        )
        let generation = makeGeneration(atom: atom)

        #expect(expansionError(
            ContextExpander(),
            pointer: ContextAtomPointer(atom: atom, generationID: 7),
            need: makeNeed(generation: generation),
            generation: generation
        ) == .invalidSourceUTF8Range(
            atom: atom.draft.id,
            range: atom.draft.sourceRange,
            bodyUTF8ByteCount: body.utf8.count
        ))
    }

    @Test
    func enforcesOriginAndSourceAndAtomAuthorization() {
        let atom = makeAtom()
        let generation = makeGeneration(atom: atom)
        let pointer = ContextAtomPointer(atom: atom, generationID: 7)
        let expander = ContextExpander()

        let deniedOrigin = makeNeed(
            generation: generation,
            origin: .remoteAuthenticated,
            allowedOrigins: [.localAuthenticated]
        )
        #expect(expansionError(
            expander, pointer: pointer, need: deniedOrigin, generation: generation
        ) == .originDenied(.remoteAuthenticated))

        let deniedSource = makeNeed(generation: generation, allowedSourceIDs: [])
        #expect(expansionError(
            expander, pointer: pointer, need: deniedSource, generation: generation
        ) == .sourcePermissionDenied(atom.draft.sourceID))

        let deniedAtom = makeNeed(generation: generation, allowedAtomIDs: [])
        #expect(expansionError(
            expander, pointer: pointer, need: deniedAtom, generation: generation
        ) == .atomPermissionDenied(atom.draft.id))
    }

    @Test
    func enforcesSourceAndAtomSurfaceAndPrivacyIndependently() {
        let expander = ContextExpander()

        let sourceSurfaceAtom = makeAtom(surfaces: [.chat, .telegram])
        let sourceSurfaceSource = makeSource(for: sourceSurfaceAtom, surfaces: [.chat])
        let sourceSurfaceGeneration = makeGeneration(
            atom: sourceSurfaceAtom,
            source: sourceSurfaceSource
        )
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: sourceSurfaceAtom, generationID: 7),
            need: makeNeed(generation: sourceSurfaceGeneration, surface: .telegram),
            generation: sourceSurfaceGeneration
        ) == .sourceSurfaceDenied(source: sourceSurfaceAtom.draft.sourceID, surface: .telegram))

        let atomSurfaceAtom = makeAtom(surfaces: [.chat])
        let atomSurfaceSource = makeSource(for: atomSurfaceAtom, surfaces: [.chat, .telegram])
        let atomSurfaceGeneration = makeGeneration(atom: atomSurfaceAtom, source: atomSurfaceSource)
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: atomSurfaceAtom, generationID: 7),
            need: makeNeed(generation: atomSurfaceGeneration, surface: .telegram),
            generation: atomSurfaceGeneration
        ) == .atomSurfaceDenied(atom: atomSurfaceAtom.draft.id, surface: .telegram))

        let sourcePrivateAtom = makeAtom(privacy: .publicSafe)
        let sourcePrivateSource = makeSource(for: sourcePrivateAtom, privacy: .localPrivate)
        let sourcePrivateGeneration = makeGeneration(atom: sourcePrivateAtom, source: sourcePrivateSource)
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: sourcePrivateAtom, generationID: 7),
            need: makeNeed(generation: sourcePrivateGeneration, allowedPrivacy: [.publicSafe]),
            generation: sourcePrivateGeneration
        ) == .sourcePrivacyDenied(
            source: sourcePrivateAtom.draft.sourceID,
            privacy: .localPrivate
        ))

        let atomPrivateAtom = makeAtom(privacy: .localPrivate)
        let atomPrivateSource = makeSource(for: atomPrivateAtom, privacy: .publicSafe)
        let atomPrivateGeneration = makeGeneration(atom: atomPrivateAtom, source: atomPrivateSource)
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: atomPrivateAtom, generationID: 7),
            need: makeNeed(generation: atomPrivateGeneration, allowedPrivacy: [.publicSafe]),
            generation: atomPrivateGeneration
        ) == .atomPrivacyDenied(atom: atomPrivateAtom.draft.id, privacy: .localPrivate))
    }

    @Test
    func rejectsDeletedTombstonedStaleAndSecretAtoms() {
        let atom = makeAtom()
        let generation = makeGeneration(atom: atom)
        let pointer = ContextAtomPointer(atom: atom, generationID: 7)
        let expander = ContextExpander()

        #expect(expansionError(
            expander,
            pointer: pointer,
            need: makeNeed(generation: generation, deleted: [atom.draft.id]),
            generation: generation
        ) == .deleted(atom.draft.id))
        #expect(expansionError(
            expander,
            pointer: pointer,
            need: makeNeed(generation: generation, tombstoned: [atom.draft.id]),
            generation: generation
        ) == .tombstoned(atom.draft.id))
        #expect(expansionError(
            expander,
            pointer: pointer,
            need: makeNeed(generation: generation, stale: [atom.draft.id]),
            generation: generation
        ) == .staleRuntime(atom.draft.id))
        #expect(expansionError(
            expander,
            pointer: pointer,
            need: makeNeed(generation: generation, secret: [atom.draft.id]),
            generation: generation
        ) == .secretBearing(atom.draft.id))
    }

    @Test
    func rejectsInvalidStoredStateAndNonExpandableAtoms() {
        let expander = ContextExpander()

        let staleAtom = makeAtom(validFrom: 8)
        let staleGeneration = makeGeneration(atom: staleAtom)
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: staleAtom, generationID: 7),
            need: makeNeed(generation: staleGeneration),
            generation: staleGeneration
        ) == .atomGenerationMismatch(staleAtom.draft.id))

        let atom = makeAtom()
        let invalidSource = makeSource(for: atom, validTo: 6)
        let invalidSourceGeneration = makeGeneration(atom: atom, source: invalidSource)
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: atom, generationID: 7),
            need: makeNeed(generation: invalidSourceGeneration),
            generation: invalidSourceGeneration
        ) == .sourceGenerationMismatch(atom.draft.sourceID))

        let removedSource = makeSource(for: atom, health: .removed)
        let removedGeneration = makeGeneration(atom: atom, source: removedSource)
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: atom, generationID: 7),
            need: makeNeed(generation: removedGeneration),
            generation: removedGeneration
        ) == .sourceRemoved(atom.draft.sourceID))

        let adaptiveAtom = makeAtom(policy: .adaptive)
        let adaptiveGeneration = makeGeneration(atom: adaptiveAtom)
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: adaptiveAtom, generationID: 7),
            need: makeNeed(generation: adaptiveGeneration),
            generation: adaptiveGeneration
        ) == .atomNotExpandable(policy: .adaptive))

        let expiredAtom = makeAtom(expiresAt: Date(timeIntervalSince1970: 19_000))
        let expiredGeneration = makeGeneration(atom: expiredAtom)
        #expect(expansionError(
            expander,
            pointer: ContextAtomPointer(atom: expiredAtom, generationID: 7),
            need: makeNeed(generation: expiredGeneration),
            generation: expiredGeneration
        ) == .expired(expiredAtom.draft.id))
    }

    private func expansionError(
        _ expander: ContextExpander,
        pointer: ContextAtomPointer,
        need: NeedSignal,
        generation: ContextStoredGeneration,
        snapshot: ContextGenerationSnapshot? = nil,
        maximumCharacters: Int? = nil
    ) -> ContextExpansionError? {
        do {
            _ = try expander.expand(
                pointer,
                for: need,
                from: generation,
                pinnedTo: snapshot,
                maximumCharacters: maximumCharacters
            )
            return nil
        } catch let error as ContextExpansionError {
            return error
        } catch {
            Issue.record("Unexpected expansion error: \(error)")
            return nil
        }
    }

    private func makeNeed(
        generation: ContextStoredGeneration,
        surface: ContextSurface = .chat,
        origin: ContextOriginClass = .localAuthenticated,
        allowedOrigins: Set<ContextOriginClass> = [.localAuthenticated],
        allowedPrivacy: Set<ContextPrivacy> = [.localPrivate, .trustedRemote, .publicSafe],
        allowedSourceIDs: Set<ContextSourceID>? = nil,
        allowedAtomIDs: Set<ContextAtomID>? = nil,
        deleted: Set<ContextAtomID> = [],
        tombstoned: Set<ContextAtomID> = [],
        stale: Set<ContextAtomID> = [],
        secret: Set<ContextAtomID> = [],
        availableGenerationID: Int64? = nil
    ) -> NeedSignal {
        NeedSignal(
            message: "Expand the procedure",
            surface: surface,
            origin: origin,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: allowedOrigins,
                allowedPrivacy: allowedPrivacy,
                allowedSourceIDs: allowedSourceIDs ?? Set(generation.sources.map(\.descriptor.id)),
                allowedAtomIDs: allowedAtomIDs
            ),
            deletedAtomIDs: deleted,
            tombstonedAtomIDs: tombstoned,
            staleRuntimeAtomIDs: stale,
            secretBearingAtomIDs: secret,
            availableGenerationID: availableGenerationID ?? generation.generation.id,
            now: now,
            timeBucketSeconds: 60
        )
    }

    private func makeAtom(
        atomID: String = "atom:procedure",
        sourceID: String = "source:skill",
        sourceHash: String = "hash:skill-v1",
        body: String = "A complete on-demand procedure.",
        sourceRange: ContextSourceRange? = nil,
        rangeStart: Int = 0,
        kind: ContextAtomKind = .procedure,
        headingPath: [String] = ["Procedure"],
        privacy: ContextPrivacy = .localPrivate,
        surfaces: Set<ContextSurface> = [.chat],
        policy: ContextInjectionPolicy = .onDemand,
        expiresAt: Date? = nil,
        validFrom: Int64 = 1,
        validTo: Int64? = nil
    ) -> ContextStoredAtom {
        let atomID = ContextAtomID(rawValue: atomID)
        let sourceID = ContextSourceID(rawValue: sourceID)
        let range = sourceRange ?? ContextSourceRange(
            utf8Start: rangeStart,
            utf8End: rangeStart + body.utf8.count
        )
        let draft = ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: kind,
            headingPath: headingPath,
            sourceRange: range,
            sourceHash: sourceHash,
            body: body,
            deterministicSummary: "Procedure summary",
            authority: .approved,
            confidence: 0.9,
            freshness: ContextFreshness(
                updatedAt: Date(timeIntervalSince1970: 18_000),
                expiresAt: expiresAt
            ),
            privacy: privacy,
            permittedSurfaces: surfaces,
            injectionPolicy: policy,
            contentRole: .procedure
        )
        return ContextStoredAtom(
            versionKey: "\(atomID.rawValue)@7",
            draft: draft,
            validFromGeneration: validFrom,
            validToGeneration: validTo
        )
    }

    private func makeSource(
        for atom: ContextStoredAtom,
        sourceHash: String? = nil,
        privacy: ContextPrivacy? = nil,
        surfaces: Set<ContextSurface>? = nil,
        policy: ContextInjectionPolicy? = nil,
        health: ContextSourceHealth = .healthy,
        validFrom: Int64 = 1,
        validTo: Int64? = nil
    ) -> ContextStoredSource {
        ContextStoredSource(
            descriptor: ContextSourceDescriptor(
                id: atom.draft.sourceID,
                owner: "fixture",
                kind: .skill,
                canonicalLocator: "skill.md",
                authority: .approved,
                privacy: privacy ?? atom.draft.privacy,
                permittedSurfaces: surfaces ?? atom.draft.permittedSurfaces,
                injectionPolicy: policy ?? atom.draft.injectionPolicy
            ),
            sourceHash: sourceHash ?? atom.draft.sourceHash,
            health: health,
            lastError: nil,
            validFromGeneration: validFrom,
            validToGeneration: validTo
        )
    }

    private func makeGeneration(
        atom: ContextStoredAtom,
        source: ContextStoredSource? = nil,
        sources: [ContextStoredSource]? = nil
    ) -> ContextStoredGeneration {
        let storedSources = sources ?? [source ?? makeSource(for: atom)]
        return ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 7,
                parentID: 6,
                createdAt: Date(timeIntervalSince1970: 17_000),
                reason: "expansion fixture",
                sourceFingerprint: "fixture-generation-7",
                atomCount: 1,
                sourceCount: storedSources.count
            ),
            sources: storedSources,
            atoms: [atom],
            relationships: []
        )
    }
}

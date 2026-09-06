import Context
import Foundation
import Testing

/// The memory semantic floor and the short-message row cap (2026-09-02).
///
/// The measured problem, from a live chat turn: on the short warm message
/// "My days bright and fuckin shiny with you in it" the best memory hit scored
/// cosine 0.41 and the selector still filled the whole 12-row memory quota down
/// to 0.24 ("Desk notify plumbing") — 18 lead+pointer rows of noise on a turn
/// that asked for none of it. Targeted queries rank fine; this is a PRECISION
/// problem on small talk, so the fix is a rank threshold plus a narrower lane
/// for messages too short to evidence what they are about.
///
/// Every fixture here uses two-dimensional unit vectors against the query
/// [1, 0], so an atom's cosine is exactly its first component — the live 0.41
/// and 0.24 are reproduced, not approximated.
@Suite("Fluid Context — memory semantic floor")
struct ContextMemorySemanticFloorTests {
    private let now = Date(timeIntervalSince1970: 10_000)
    /// The live keeper: the best memory on that warm turn.
    private static let keeperCosine = 0.41
    /// The live worst offender that still rode the packet.
    private static let noiseCosine = 0.24

    /// Off-topic recall that still clears the global relevance floor on one
    /// incidental word — exactly how the live noise got in.
    private static func noiseBody(_ index: Int) -> String {
        "Desk notify plumbing landed behind a feature flag in the evenings \(index)."
    }

    // MARK: - (a) the reported regression

    @Test
    func lowCosineMemoriesAreRefusedWhileTheBestHitStays() throws {
        let keeper = memory("keeper", body: "User and Agent trade warmth most evenings.",
                            cosine: Self.keeperCosine)
        let noise = (0..<3).map { index in
            memory("noise-\(index)",
                   body: Self.noiseBody(index),
                   cosine: Self.noiseCosine)
        }
        let fixture = generation([keeper] + noise)
        let need = signal("You make the evenings brighter", generation: fixture,
                          queryEmbedding: [1, 0])

        let packet = try ContextSelector().select(need, from: fixture)

        #expect(packet.receipt.selectedAtomIDs == [keeper.draft.id])
        #expect(packet.receipt.memoryFloorDroppedCount == 3)
        // The floor refuses ADMISSION, not candidacy: the receipts still say
        // exactly why each row was left out.
        let noiseScore = try #require(
            packet.receipt.candidateScores.first { $0.atomID == noise[0].draft.id }
        )
        #expect(abs(noiseScore.features.semanticCosine - Self.noiseCosine) < 0.001)
        #expect(noiseScore.selectionOrdinal == nil)
    }

    // MARK: - (b) the exemptions

    @Test
    func aWholeMessageLexicalHitSurvivesTheFloor() throws {
        let lexical = memory(
            "lexical",
            body: "Note to self: the desk notify plumbing is still flagged off.",
            cosine: 0.05
        )
        let fixture = generation([lexical])
        let packet = try ContextSelector().select(
            signal("desk notify plumbing", generation: fixture, queryEmbedding: [1, 0]),
            from: fixture
        )

        #expect(packet.receipt.selectedAtomIDs == [lexical.draft.id])
        #expect(packet.receipt.memoryFloorDroppedCount == 0)
    }

    @Test
    func aSharedIdentifierSurvivesTheFloor() throws {
        let hermes = ContextEntity(kind: "project", id: "hermes", label: "Hermes")
        let identified = memory(
            "identified",
            body: "The bridge rewrite is parked until the vendor answers.",
            cosine: 0.05,
            entities: [hermes]
        )
        let fixture = generation([identified])
        let packet = try ContextSelector().select(
            signal("morning", generation: fixture, queryEmbedding: [1, 0], entities: [hermes]),
            from: fixture
        )

        #expect(packet.receipt.selectedAtomIDs == [identified.draft.id])
        #expect(packet.receipt.memoryFloorDroppedCount == 0)
    }

    @Test
    func coveringTheMessageSurvivesTheFloor() throws {
        // The atom the message is plainly about, with a cosine that would have
        // condemned it. Nine unrelated rows keep the token specificity honest
        // rather than letting a two-document fixture inflate coverage.
        let onMessage = memory(
            "on-message",
            body: "Tuesday: the orchard needs watering before the frost returns.",
            cosine: 0.05
        )
        let others = (0..<9).map { index in
            memory("other-\(index)", body: Self.noiseBody(index), cosine: Self.noiseCosine)
        }
        let fixture = generation([onMessage] + others)
        let packet = try ContextSelector().select(
            signal("orchard needs watering tuesday", generation: fixture,
                   budget: 5_000, queryEmbedding: [1, 0]),
            from: fixture
        )

        let coverage = try #require(
            packet.receipt.candidateScores.first { $0.atomID == onMessage.draft.id }
        ).features.messageCoverage
        #expect(coverage >= 0.5)
        #expect(packet.receipt.selectedAtomIDs.contains(onMessage.draft.id))
    }

    @Test
    func activationSurvivesTheFloorAndHalfHeartedActivationDoesNot() throws {
        // Attention and the working set are the turn saying "this is live".
        // 0.5 is the line: the same atom, twice, either side of it.
        let active = memory("active", body: Self.noiseBody(0), cosine: Self.noiseCosine,
                            activation: 0.6)
        let idle = memory("idle", body: Self.noiseBody(1), cosine: Self.noiseCosine,
                          activation: 0.4)
        let fixture = generation([active, idle])
        let packet = try ContextSelector().select(
            signal("You make the evenings brighter", generation: fixture,
                   queryEmbedding: [1, 0]),
            from: fixture
        )

        #expect(packet.receipt.selectedAtomIDs == [active.draft.id])
        #expect(packet.receipt.memoryFloorDroppedCount == 1)
    }

    @Test
    func anAtomWithNoComparableEmbeddingIsNeverFloored() throws {
        // A 0 that means "not measured" must not be read as "not relevant".
        // An atom still waiting to be embedded, and one embedded under a
        // retired model epoch, both keep their ordinary ranking.
        let unembedded = memory("unembedded", body: Self.noiseBody(0))
        let otherEpoch = memory("other-epoch", body: Self.noiseBody(1),
                                cosine: 0.99, embeddingFingerprint: "retired-epoch")
        let comparable = memory("comparable", body: Self.noiseBody(2),
                                cosine: Self.noiseCosine)
        let fixture = generation([unembedded, otherEpoch, comparable])
        let packet = try ContextSelector().select(
            signal("You make the evenings brighter", generation: fixture,
                   budget: 5_000, queryEmbedding: [1, 0]),
            from: fixture
        )

        #expect(packet.receipt.selectedAtomIDs.contains(unembedded.draft.id))
        #expect(packet.receipt.selectedAtomIDs.contains(otherEpoch.draft.id))
        #expect(!packet.receipt.selectedAtomIDs.contains(comparable.draft.id))
        #expect(packet.receipt.memoryFloorDroppedCount == 1)
    }

    @Test
    func aFlooredAtomCannotRideBackInsideAnUnresolvedConflict() throws {
        // An unresolved conflict unit is admitted whole, quotas and all — so
        // unit construction has to see the ADMITTED candidates, not every
        // ranked one, or the floor has a door in it.
        let keeper = memory("conflict-keeper", body: "User takes his coffee black in the evenings.",
                            cosine: Self.keeperCosine)
        let floored = memory("conflict-floored", body: "User takes his coffee with oat milk, evenings.",
                             cosine: Self.noiseCosine)
        let fixture = generation([keeper, floored])
        let conflict = ContextConflictDefinition(
            id: "coffee",
            memberAtomIDs: [keeper.draft.id, floored.draft.id],
            provenance: "fixture"
        )
        let packet = try ContextSelector().select(
            signal("You make the evenings brighter", generation: fixture,
                   budget: 5_000, queryEmbedding: [1, 0], conflicts: [conflict]),
            from: fixture
        )

        #expect(packet.receipt.selectedAtomIDs == [keeper.draft.id])
        #expect(packet.receipt.memoryFloorDroppedCount == 1)
        // Candidacy and the conflict receipt are untouched — the packet simply
        // does not spend a row on the sub-floor side.
        #expect(packet.receipt.candidateScores.contains { $0.atomID == floored.draft.id })
        #expect(packet.conflictSets.contains { $0.id == "coffee" })
    }

    // MARK: - (c) cold embedder

    @Test
    func theFloorIsInertWhenTheQueryHasNoEmbedding() throws {
        let noise = (0..<3).map { index in
            memory("noise-\(index)",
                   body: Self.noiseBody(index),
                   cosine: Self.noiseCosine)
        }
        let fixture = generation(noise)
        let selector = ContextSelector()

        // Same selector, same atoms, same message — only the QUERY embedding
        // differs. A cold embedder scores every atom 0, so a floor that read
        // the atom's zero would delete the memory lane instead of trimming it.
        let warm = try selector.select(
            signal("You make the evenings brighter", generation: fixture,
                   queryEmbedding: [1, 0]),
            from: fixture
        )
        let cold = try selector.select(
            signal("You make the evenings brighter", generation: fixture),
            from: fixture
        )

        #expect(warm.receipt.selectedAtomIDs.isEmpty)
        #expect(warm.receipt.memoryFloorDroppedCount == noise.count)
        #expect(cold.receipt.selectedAtomIDs.count == noise.count)
        #expect(cold.receipt.memoryFloorDroppedCount == 0)
    }

    // MARK: - (d) the kill switch

    @Test
    func floorZeroSelectsExactlyWhatTheSelectorSelectedBefore() throws {
        let keeper = memory("keeper", body: "User and Agent trade warmth most evenings.",
                            cosine: Self.keeperCosine)
        let noise = (0..<3).map { index in
            memory("noise-\(index)",
                   body: Self.noiseBody(index),
                   cosine: Self.noiseCosine)
        }
        let fixture = generation([keeper] + noise)
        let need = signal("You make the evenings brighter", generation: fixture,
                          queryEmbedding: [1, 0])

        let disabled = try ContextSelector(
            configuration: ContextSelectionConfiguration(memorySemanticFloor: 0)
        ).select(need, from: fixture)

        #expect(Set(disabled.receipt.selectedAtomIDs)
            == Set(([keeper] + noise).map(\.draft.id)))
        #expect(disabled.receipt.memoryFloorDroppedCount == 0)
    }

    @Test
    func floorZeroAlsoTurnsOffTheShortMessageCap() throws {
        // One switch, one claim: `memorySemanticFloor = 0` restores the
        // pre-floor selector, which never narrowed a lane for a short message.
        let memories = (0..<10).map { index in
            memory("orchard-\(index)", body: "Orchard watering note number \(index).",
                   source: "mem-\(index)")
        }
        let fixture = generation(memories)
        let need = signal("orchard watering notes", generation: fixture, budget: 5_000)

        let shipped = try ContextSelector().select(need, from: fixture)
        let floorOff = try ContextSelector(
            configuration: ContextSelectionConfiguration(memorySemanticFloor: 0)
        ).select(need, from: fixture)
        // The cap also has its own off value, for a turn that wants the floor
        // without the narrower lane.
        let capOff = try ContextSelector(
            configuration: ContextSelectionConfiguration(shortMessageMemoryRowCap: 0)
        ).select(need, from: fixture)

        #expect(count(shipped, .memory) == 6)
        #expect(count(floorOff, .memory)
            == ContextSelectionConfiguration().maximumAtoms(forKind: .memory))
        #expect(count(capOff, .memory) == count(floorOff, .memory))
    }

    @Test
    func aTurnWithNothingBelowTheFloorIsByteIdenticalWithAndWithoutIt() throws {
        // The other half of the kill switch: when no atom is below it, the
        // floor is not merely harmless — it changes nothing at all, receipts
        // and packet bytes included.
        let above = (0..<4).map { index in
            memory("above-\(index)",
                   body: "Orchard watering note number \(index).",
                   cosine: 0.9)
        }
        let fixture = generation(above)
        let need = signal("orchard watering notes", generation: fixture, queryEmbedding: [1, 0])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let shipped = try ContextSelector().select(need, from: fixture)
        let disabled = try ContextSelector(
            configuration: ContextSelectionConfiguration(memorySemanticFloor: 0)
        ).select(need, from: fixture)

        #expect(try encoder.encode(shipped) == encoder.encode(disabled))
        #expect(shipped.receipt.memoryFloorDroppedCount == 0)
    }

    // MARK: - (e) the short-message row cap

    @Test
    func aShortMessageGetsANarrowerMemoryLane() throws {
        // Ten on-topic memories, one per source so the per-source cap cannot be
        // what bounds them, and no embeddings at all so the floor is not what
        // bounds them either.
        let memories = (0..<10).map { index in
            memory("orchard-\(index)", body: "Orchard watering note number \(index).",
                   source: "mem-\(index)")
        }
        let fixture = generation(memories)

        // Three content tokens: below the coverage damp's own threshold.
        let short = try ContextSelector().select(
            signal("orchard watering notes", generation: fixture, budget: 5_000),
            from: fixture
        )
        // Five: the message can evidence what it is about, so the ordinary
        // memory kind cap applies.
        let long = try ContextSelector().select(
            signal("please summarise every orchard watering note today",
                   generation: fixture, budget: 5_000),
            from: fixture
        )

        #expect(count(short, .memory) == ContextSelectionConfiguration().shortMessageMemoryRowCap)
        #expect(count(short, .memory) == 6)
        #expect(count(long, .memory)
            == ContextSelectionConfiguration().maximumAtoms(forKind: .memory))
        #expect(count(long, .memory) == 8)
    }

    @Test
    func theShortMessageCapNarrowsTheCallersRowLimitAndNeverWidensIt() throws {
        let memories = (0..<10).map { index in
            memory("orchard-\(index)", body: "Orchard watering note number \(index).",
                   source: "mem-\(index)")
        }
        let fixture = generation(memories)

        let tightCaller = try ContextSelector().select(
            signal("orchard watering notes", generation: fixture, budget: 5_000,
                   memoryAtomRowLimit: 2),
            from: fixture
        )
        let wideCaller = try ContextSelector().select(
            signal("orchard watering notes", generation: fixture, budget: 5_000,
                   memoryAtomRowLimit: 12),
            from: fixture
        )

        #expect(count(tightCaller, .memory) == 2)
        #expect(count(wideCaller, .memory) == 6)
    }

    // MARK: - Fixtures

    private func count(_ packet: ContextPacket, _ kind: ContextAtomKind) -> Int {
        packet.selectedItems.filter { $0.pointer.kind == kind }.count
    }

    /// A unit vector whose cosine against the query [1, 0] is exactly `cosine`.
    private func unit(_ cosine: Double) -> [Float] {
        [Float(cosine), Float((1 - (cosine * cosine)).squareRoot())]
    }

    private func signal(
        _ message: String,
        generation: ContextStoredGeneration,
        budget: Int = 1_000,
        queryEmbedding: [Float]? = nil,
        entities: Set<ContextEntity> = [],
        memoryAtomRowLimit: Int? = nil,
        conflicts: [ContextConflictDefinition] = []
    ) -> NeedSignal {
        NeedSignal(
            message: message,
            extractedEntities: entities,
            surface: .chat,
            origin: .localAuthenticated,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: [.localAuthenticated],
                allowedPrivacy: [.localPrivate, .trustedRemote, .publicSafe],
                allowedSourceIDs: Set(generation.sources.map(\.descriptor.id))
            ),
            queryEmbedding: queryEmbedding,
            queryEmbeddingModelFingerprint: queryEmbedding == nil ? nil : "fixture",
            availableGenerationID: generation.generation.id,
            characterBudget: budget,
            memoryAtomRowLimit: memoryAtomRowLimit,
            now: now,
            explicitConflicts: conflicts,
            cacheState: .hit
        )
    }

    private func memory(
        _ id: String,
        body: String,
        cosine: Double? = nil,
        source: String? = nil,
        entities: [ContextEntity] = [],
        activation: Double = 0,
        embeddingFingerprint: String = "fixture"
    ) -> ContextStoredAtom {
        let sourceID = ContextSourceID(rawValue: "source:\(source ?? id)")
        let atomID = ContextAtomID(rawValue: "atom:\(id)")
        let draft = ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: .memory,
            headingPath: [],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: "hash:\(id)",
            body: body,
            authority: .inferred,
            confidence: 0.9,
            freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 9_000)),
            privacy: .localPrivate,
            permittedSurfaces: [.chat],
            injectionPolicy: .adaptive,
            contentRole: .memory,
            entities: entities,
            triggers: [],
            activation: activation,
            recentUsefulness: 0.5,
            decayState: 0.9,
            embedding: cosine.map {
                ContextEmbedding(modelFingerprint: embeddingFingerprint, values: unit($0))
            }
        )
        return ContextStoredAtom(
            versionKey: "\(atomID.rawValue)@1",
            draft: draft,
            validFromGeneration: 1,
            validToGeneration: nil
        )
    }

    private func generation(_ atoms: [ContextStoredAtom]) -> ContextStoredGeneration {
        var seen = Set<ContextSourceID>()
        let sources = atoms.compactMap { atom -> ContextStoredSource? in
            guard seen.insert(atom.draft.sourceID).inserted else { return nil }
            return ContextStoredSource(
                descriptor: ContextSourceDescriptor(
                    id: atom.draft.sourceID,
                    owner: "fixture",
                    kind: .other,
                    canonicalLocator: atom.draft.sourceID.rawValue,
                    authority: atom.draft.authority,
                    privacy: atom.draft.privacy,
                    permittedSurfaces: atom.draft.permittedSurfaces,
                    injectionPolicy: atom.draft.injectionPolicy
                ),
                sourceHash: atom.draft.sourceHash,
                health: .healthy,
                lastError: nil,
                validFromGeneration: 1,
                validToGeneration: nil
            )
        }
        return ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: Date(timeIntervalSince1970: 8_000),
                reason: "memory floor fixture",
                sourceFingerprint: "fixture-fingerprint",
                atomCount: atoms.count,
                sourceCount: sources.count
            ),
            sources: sources,
            atoms: atoms,
            relationships: []
        )
    }
}

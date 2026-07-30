import Context
import Foundation
import Testing

@Suite("Fluid Context FC3 shadow selection")
struct ContextSelectionTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test
    func mandatoryCoverageIsCompleteAndOrderedAheadOfDynamicContext() throws {
        let identity = atom(
            "identity",
            source: "persona",
            kind: .identity,
            body: "Agent is one continuous mind.",
            authority: .identity,
            policy: .always
        )
        let correction = atom(
            "correction",
            source: "memory",
            kind: .correction,
            body: "User prefers concise engineering updates.",
            authority: .explicitCorrection
        )
        let project = atom(
            "project",
            source: "project",
            kind: .project,
            body: "Fluid Context selection is in shadow mode."
        )
        let generation = generation([project, correction, identity])
        let need = signal(
            "What is the Fluid Context update style?",
            generation: generation,
            mandatory: [correction.draft.id],
            budget: 180
        )

        let packet = try ContextSelector().select(need, from: generation)

        #expect(packet.receipt.mandatoryCoverage == 1)
        #expect(Set(packet.receipt.mandatoryAtomIDs) == [identity.draft.id, correction.draft.id])
        #expect(packet.receipt.coveredMandatoryAtomIDs == packet.receipt.mandatoryAtomIDs)
        #expect(packet.selectedItems.prefix(2).allSatisfy { $0.mandatory })
        #expect(packet.selectedItems[0].pointer.atomID == identity.draft.id)
        #expect(packet.selectedItems[1].pointer.atomID == correction.draft.id)
    }

    @Test
    func privacyExclusionOccursBeforeCandidateScoring() throws {
        let privateAtom = atom(
            "private",
            source: "private-source",
            kind: .memory,
            body: "Atlas private launch details.",
            privacy: .localPrivate
        )
        let publicAtom = atom(
            "public",
            source: "public-source",
            kind: .memory,
            body: "Atlas public launch summary.",
            privacy: .publicSafe
        )
        let generation = generation([privateAtom, publicAtom])
        let need = signal(
            "Atlas launch",
            generation: generation,
            allowedPrivacy: [.publicSafe]
        )

        let packet = try ContextSelector().select(need, from: generation)
        let privateDecision = try #require(packet.receipt.eligibility.first {
            $0.atomID == privateAtom.draft.id
        })

        #expect(privateDecision.exclusionReason == .privacyDenied)
        #expect(!packet.receipt.candidateScores.map(\.atomID).contains(privateAtom.draft.id))
        #expect(!packet.receipt.selectedAtomIDs.contains(privateAtom.draft.id))
        #expect(packet.receipt.selectedAtomIDs.contains(publicAtom.draft.id))
    }

    @Test
    func expiredAndDeletedAtomsAreExcludedBeforeScoring() throws {
        let expired = atom(
            "expired",
            source: "runtime",
            kind: .runtimeTruth,
            body: "Provider is offline.",
            expiresAt: Date(timeIntervalSince1970: 9_000)
        )
        let deleted = atom(
            "deleted",
            source: "memory",
            kind: .memory,
            body: "Provider outage was unresolved."
        )
        let current = atom(
            "current",
            source: "health",
            kind: .runtimeTruth,
            body: "Provider is healthy."
        )
        let generation = generation([expired, deleted, current])
        let need = signal(
            "provider health outage",
            generation: generation,
            deleted: [deleted.draft.id]
        )

        let packet = try ContextSelector().select(need, from: generation)
        let decisions = Dictionary(uniqueKeysWithValues: packet.receipt.eligibility.map {
            ($0.atomID, $0.exclusionReason)
        })
        let scored = Set(packet.receipt.candidateScores.map(\.atomID))

        #expect(decisions[expired.draft.id] == .expired)
        #expect(decisions[deleted.draft.id] == .deleted)
        #expect(!scored.contains(expired.draft.id))
        #expect(!scored.contains(deleted.draft.id))
        #expect(packet.receipt.selectedAtomIDs == [current.draft.id])
    }

    @Test
    func permissionSurfaceAndNeverInjectGatesRunBeforeScoring() throws {
        let permissionDenied = atom(
            "permission-denied",
            source: "unauthorized",
            kind: .memory,
            body: "Atlas unauthorized memory."
        )
        let surfaceDenied = atom(
            "surface-denied",
            source: "bridge-only",
            kind: .memory,
            body: "Atlas bridge-only memory.",
            surfaces: [.bridge]
        )
        let neverInject = atom(
            "never-inject",
            source: "internal-index",
            kind: .memory,
            body: "Atlas internal index data.",
            policy: .neverInject
        )
        let eligible = atom(
            "eligible-gate-control",
            source: "eligible",
            kind: .memory,
            body: "Atlas eligible context."
        )
        let generation = generation([permissionDenied, surfaceDenied, neverInject, eligible])
        let allowedSources: Set<ContextSourceID> = [
            surfaceDenied.draft.sourceID,
            neverInject.draft.sourceID,
            eligible.draft.sourceID,
        ]
        let need = signal(
            "Atlas context",
            generation: generation,
            allowedSourceIDs: allowedSources
        )

        let packet = try ContextSelector().select(need, from: generation)
        let decisions = Dictionary(uniqueKeysWithValues: packet.receipt.eligibility.map {
            ($0.atomID, $0.exclusionReason)
        })
        let scored = Set(packet.receipt.candidateScores.map(\.atomID))

        #expect(decisions[permissionDenied.draft.id] == .permissionDenied)
        #expect(decisions[surfaceDenied.draft.id] == .surfaceDenied)
        #expect(decisions[neverInject.draft.id] == .neverInject)
        #expect(!scored.contains(permissionDenied.draft.id))
        #expect(!scored.contains(surfaceDenied.draft.id))
        #expect(!scored.contains(neverInject.draft.id))
        #expect(scored.contains(eligible.draft.id))
    }

    @Test
    func unresolvedExplicitConflictIsPackedAsAnAtomicUncertaintySet() throws {
        let monday = atom(
            "monday",
            source: "desk",
            kind: .fact,
            body: "Project Atlas launches Monday."
        )
        let tuesday = atom(
            "tuesday",
            source: "mission",
            kind: .fact,
            body: "Project Atlas launches Tuesday."
        )
        let generation = generation([tuesday, monday])
        let conflict = ContextConflictDefinition(
            id: "atlas-date",
            memberAtomIDs: [monday.draft.id, tuesday.draft.id],
            provenance: "fixture"
        )
        let need = signal(
            "When does Project Atlas launch?",
            generation: generation,
            conflicts: [conflict]
        )

        let packet = try ContextSelector().select(need, from: generation)
        let conflictSet = try #require(packet.conflictSets.first)

        #expect(conflictSet.id == "atlas-date")
        #expect(conflictSet.handling == .includedUncertainty)
        #expect(Set(conflictSet.claims.map(\.atomID)) == [monday.draft.id, tuesday.draft.id])
        #expect(Set(packet.receipt.selectedAtomIDs) == [monday.draft.id, tuesday.draft.id])
    }

    @Test
    func vectorsCannotOverrideAnExplicitAuthoritativeConflictResolution() throws {
        let correction = atom(
            "corrected",
            source: "corrections",
            kind: .correction,
            body: "Atlas launches Tuesday.",
            authority: .explicitCorrection,
            embedding: [0, 1]
        )
        let external = atom(
            "external",
            source: "external",
            kind: .evidence,
            body: "Atlas launches Monday.",
            authority: .external,
            embedding: [1, 0]
        )
        let generation = generation([external, correction])
        let conflict = ContextConflictDefinition(
            id: "resolved-atlas-date",
            memberAtomIDs: [correction.draft.id, external.draft.id],
            resolvedAtomID: correction.draft.id,
            provenance: "explicit correction"
        )
        let need = signal(
            "Atlas launch date",
            generation: generation,
            queryEmbedding: [1, 0],
            conflicts: [conflict]
        )

        let packet = try ContextSelector().select(need, from: generation)
        let externalDecision = try #require(packet.receipt.eligibility.first {
            $0.atomID == external.draft.id
        })

        #expect(externalDecision.exclusionReason == .supersededByConflictResolution)
        #expect(!packet.receipt.candidateScores.map(\.atomID).contains(external.draft.id))
        #expect(packet.receipt.selectedAtomIDs == [correction.draft.id])
        #expect(packet.conflictSets.first?.handling == .resolved)
    }

    @Test
    func semanticQueryRecoversAParaphraseThatLexicalSelectionMisses() throws {
        let target = atom(
            "jasmine-memory",
            source: "memory",
            kind: .memory,
            body: "User always chooses jasmine tea after lunch.",
            embedding: [1, 0]
        )
        let lexicalLure = atom(
            "beverage-note",
            source: "project",
            kind: .project,
            body: "Beverage deployment notes for the test fixture.",
            embedding: [0, 1]
        )
        let fixture = generation([lexicalLure, target])
        let selector = ContextSelector(configuration: ContextSelectionConfiguration(
            maximumDynamicAtoms: 1
        ))

        let lexical = try selector.select(
            signal("beverage preference", generation: fixture),
            from: fixture
        )
        let semantic = try selector.select(
            signal("beverage preference", generation: fixture, queryEmbedding: [1, 0]),
            from: fixture
        )

        #expect(!lexical.receipt.selectedAtomIDs.contains(target.draft.id))
        #expect(semantic.receipt.selectedAtomIDs == [target.draft.id])
    }

    @Test
    func semanticScoreFailsClosedWhenQueryAndAtomEmbeddingEpochsDiffer() throws {
        let target = atom(
            "epoch-target",
            source: "memory",
            kind: .memory,
            body: "An unrelated phrase with no lexical overlap.",
            embedding: [1, 0]
        )
        let fixture = generation([target])
        let matched = try ContextSelector().select(
            signal(
                "unrelated phrase",
                generation: fixture,
                queryEmbedding: [1, 0],
                queryEmbeddingModelFingerprint: "fixture"
            ),
            from: fixture
        )
        let mismatched = try ContextSelector().select(
            signal(
                "unrelated phrase",
                generation: fixture,
                queryEmbedding: [1, 0],
                queryEmbeddingModelFingerprint: "different-epoch"
            ),
            from: fixture
        )

        #expect(matched.receipt.candidateScores.first?.features.semanticCosine == 1)
        #expect(mismatched.receipt.candidateScores.first?.features.semanticCosine == 0)
    }

    @Test
    func restartOrderingAndReceiptAreDeterministicWithPinnedArenaSnapshot() throws {
        let first = atom("alpha", source: "a", kind: .project, body: "Atlas context alpha.")
        let second = atom("beta", source: "b", kind: .memory, body: "Atlas context beta.")
        let third = atom("gamma", source: "c", kind: .instruction, body: "Atlas context gamma.")
        let original = generation([third, first, second])
        let restarted = generation([second, third, first])
        let snapshot = try ContextGenerationSnapshot(
            generationID: original.generation.id,
            sourceFingerprint: original.generation.sourceFingerprint
        )
        let need = signal("Atlas context", generation: original, budget: 200)

        let firstPacket = try ContextSelector().select(need, from: original, pinnedTo: snapshot)
        let secondPacket = try ContextSelector().select(need, from: restarted, pinnedTo: snapshot)

        #expect(firstPacket == secondPacket)
        #expect(firstPacket.receipt.id == secondPacket.receipt.id)
    }

    @Test
    func diversityQuotaSelectsAcrossSourcesInsteadOfRepeatingOneSource() throws {
        let strongest = atom(
            "same-a",
            source: "same-source",
            kind: .memory,
            body: "Atlas migration detail one.",
            activation: 1
        )
        let duplicate = atom(
            "same-b",
            source: "same-source",
            kind: .memory,
            body: "Atlas migration detail two.",
            activation: 0.9
        )
        let diverse = atom(
            "other",
            source: "other-source",
            kind: .project,
            body: "Atlas migration project state.",
            activation: 0.2
        )
        let generation = generation([duplicate, diverse, strongest])
        let selector = ContextSelector(configuration: ContextSelectionConfiguration(
            maximumDynamicAtoms: 2,
            maximumAtomsPerSource: 1,
            maximumAtomsPerKind: 2
        ))

        let packet = try selector.select(
            signal("Atlas migration", generation: generation),
            from: generation
        )
        let selectedSources = Set(packet.selectedItems.map(\.pointer.sourceID))

        #expect(packet.selectedItems.count == 2)
        #expect(selectedSources.count == 2)
        #expect(packet.receipt.selectedAtomIDs.contains(strongest.draft.id))
        #expect(!packet.receipt.selectedAtomIDs.contains(duplicate.draft.id))
        #expect(packet.receipt.selectedAtomIDs.contains(diverse.draft.id))
    }

    @Test
    func hybridScoreExposesEveryPositiveFeatureAndSelectionPenalties() throws {
        let primary = atom(
            "hybrid-primary",
            source: "hybrid-a",
            kind: .project,
            body: "Atlas session-42 migration",
            authority: .canonical,
            activation: 0.6,
            embedding: [1, 0]
        )
        let redundant = atom(
            "hybrid-redundant",
            source: "hybrid-b",
            kind: .memory,
            body: "Atlas session-42 migration details",
            activation: 0.4,
            embedding: [0.8, 0.2]
        )
        let generation = generation([redundant, primary])
        let base = signal(
            "Atlas session-42 migration",
            generation: generation,
            queryEmbedding: [1, 0]
        )
        let need = NeedSignal(
            message: base.message,
            extractedEntities: [ContextEntity(kind: "project", id: "atlas", label: "Atlas")],
            surface: base.surface,
            origin: base.origin,
            authorization: base.authorization,
            sessionID: "session-42",
            currentProjectID: "atlas",
            cognitiveActivation: [primary.draft.id: 0.8],
            workingAtomIDs: [primary.draft.id],
            queryEmbedding: base.queryEmbedding,
            queryEmbeddingModelFingerprint: base.queryEmbeddingModelFingerprint,
            availableGenerationID: generation.generation.id,
            characterBudget: 500,
            now: now
        )

        let packet = try ContextSelector().select(need, from: generation)
        let primaryScore = try #require(packet.receipt.candidateScores.first {
            $0.atomID == primary.draft.id
        })
        let redundantScore = try #require(packet.receipt.candidateScores.first {
            $0.atomID == redundant.draft.id
        })

        #expect(primaryScore.features.lexicalExact > 0)
        #expect(primaryScore.features.tokenOverlap > 0)
        #expect(primaryScore.features.semanticCosine > 0)
        #expect(primaryScore.features.sharedIdentifiers > 0)
        #expect(primaryScore.features.activation > 0)
        #expect(primaryScore.features.authority > 0)
        #expect(primaryScore.features.confidence > 0)
        #expect(primaryScore.features.recency > 0)
        #expect(primaryScore.features.usefulness > 0)
        #expect(primaryScore.features.decay > 0)
        #expect(primaryScore.features.diversityBonus > 0)
        #expect(redundantScore.features.redundancyPenalty > 0)
    }

    @Test
    func onDemandCandidatesBecomePointersWithoutConsumingCharacterBudget() throws {
        let pointerAtom = atom(
            "procedure-pointer",
            source: "skill",
            kind: .procedure,
            body: String(repeating: "Atlas procedure ", count: 50),
            policy: .onDemand
        )
        let generation = generation([pointerAtom])

        let packet = try ContextSelector().select(
            signal("Atlas procedure", generation: generation, budget: 40),
            from: generation
        )

        #expect(packet.selectedItems.isEmpty)
        #expect(packet.expandablePointers.map(\.atomID) == [pointerAtom.draft.id])
        #expect(packet.characterCount == 0)
        #expect(packet.receipt.pointerAtomIDs == [pointerAtom.draft.id])
    }

    @Test
    func packetUsesDeterministicSummariesAndNeverExceedsCharacterBudget() throws {
        let identity = atom(
            "identity-budget",
            source: "persona",
            kind: .identity,
            body: String(repeating: "I", count: 20),
            authority: .identity,
            policy: .always
        )
        let dynamic = (1...4).map { index in
            atom(
                "long-\(index)",
                source: "source-\(index)",
                kind: .memory,
                body: "Atlas " + String(repeating: "x", count: 70),
                summary: "Atlas-\(index)"
            )
        }
        let generation = generation([identity] + dynamic)
        let selector = ContextSelector(configuration: ContextSelectionConfiguration(
            maximumDynamicAtoms: 8,
            maximumAtomsPerSource: 2,
            maximumAtomsPerKind: 8
        ))

        let packet = try selector.select(
            signal("Atlas", generation: generation, budget: 50),
            from: generation
        )

        #expect(packet.characterCount <= 50)
        #expect(packet.budget.usedCharacters == packet.selectedItems.map(\.characterCount).reduce(0, +))
        #expect(packet.selectedItems.dropFirst().allSatisfy {
            $0.representation == .deterministicSummary
        })
        #expect(packet.receipt.mandatoryCoverage == 1)
    }

    @Test
    func curatedRecallAt8AndWarmSelectionP95MeetAcceptanceGates() throws {
        let topics = (0..<24).map { "contexttopic\($0)" }
        let relevant = topics.enumerated().map { index, topic in
            atom(
                "curated-\(index)",
                source: "curated-\(index)",
                kind: .project,
                body: "\(topic) \(topic) is the required fact for fixture \(index)."
            )
        }
        let noise = (0..<160).map { index in
            atom(
                "noise-\(index)",
                source: "noise-\(index)",
                kind: .memory,
                body: "general unrelated continuity note number \(index)"
            )
        }
        let fixture = generation(relevant + noise)
        let selector = ContextSelector()

        for topic in topics.prefix(4) {
            _ = try selector.select(
                signal(topic, generation: fixture, budget: 2_000),
                from: fixture
            )
        }

        var recallHits = 0
        var elapsedMicroseconds: [Int] = []
        for iteration in 0..<120 {
            let topicIndex = iteration % topics.count
            let started = DispatchTime.now().uptimeNanoseconds
            let packet = try selector.select(
                signal(topics[topicIndex], generation: fixture, budget: 2_000),
                from: fixture
            )
            elapsedMicroseconds.append(
                Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000)
            )
            if packet.selectedItems.prefix(8).contains(where: {
                $0.pointer.atomID == relevant[topicIndex].draft.id
            }) {
                recallHits += 1
            }
        }

        let ordered = elapsedMicroseconds.sorted()
        let p95 = ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))]
        let recall = Double(recallHits) / Double(elapsedMicroseconds.count)

        // recall@8 is a functional-correctness property — always asserted.
        #expect(recall >= 0.95)
        print(
            "[fluid-context-metric] recall@8=\(recallHits)/\(elapsedMicroseconds.count) "
                + "warm-selection-p95=\(p95)us"
        )
        // The absolute p95 latency bound is a perf-regression tripwire — gated
        // behind NATIVE_AGENT_PERF_ASSERTS so CI load can't flake it, measurable
        // on demand. See nativeagent-hangproof-subprocess-tests.
        if ProcessInfo.processInfo.environment["NATIVE_AGENT_PERF_ASSERTS"] == "1" {
            #expect(p95 < 50_000)
        }
    }

    private func signal(
        _ message: String,
        generation: ContextStoredGeneration,
        mandatory: Set<ContextAtomID> = [],
        deleted: Set<ContextAtomID> = [],
        allowedPrivacy: Set<ContextPrivacy> = [.localPrivate, .trustedRemote, .publicSafe],
        allowedSourceIDs: Set<ContextSourceID>? = nil,
        queryEmbedding: [Float]? = nil,
        queryEmbeddingModelFingerprint: String? = nil,
        conflicts: [ContextConflictDefinition] = [],
        budget: Int = 500
    ) -> NeedSignal {
        NeedSignal(
            message: message,
            surface: .chat,
            origin: .localAuthenticated,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: [.localAuthenticated],
                allowedPrivacy: allowedPrivacy,
                allowedSourceIDs: allowedSourceIDs
                    ?? Set(generation.sources.map(\.descriptor.id))
            ),
            mandatoryAtomIDs: mandatory,
            deletedAtomIDs: deleted,
            queryEmbedding: queryEmbedding,
            queryEmbeddingModelFingerprint: queryEmbedding == nil
                ? nil
                : (queryEmbeddingModelFingerprint ?? "fixture"),
            availableGenerationID: generation.generation.id,
            characterBudget: budget,
            now: now,
            explicitConflicts: conflicts,
            cacheState: .hit
        )
    }

    private func atom(
        _ id: String,
        source: String,
        kind: ContextAtomKind,
        body: String,
        summary: String? = nil,
        authority: ContextAuthority = .approved,
        privacy: ContextPrivacy = .localPrivate,
        policy: ContextInjectionPolicy = .adaptive,
        surfaces: Set<ContextSurface> = [.chat],
        expiresAt: Date? = nil,
        activation: Double = 0,
        embedding: [Float]? = nil
    ) -> ContextStoredAtom {
        let sourceID = ContextSourceID(rawValue: "source:\(source)")
        let atomID = ContextAtomID(rawValue: "atom:\(id)")
        let draft = ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: kind,
            headingPath: [id],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: "hash:\(source)",
            body: body,
            deterministicSummary: summary,
            authority: authority,
            confidence: 0.9,
            freshness: ContextFreshness(
                updatedAt: Date(timeIntervalSince1970: 9_000),
                expiresAt: expiresAt
            ),
            privacy: privacy,
            permittedSurfaces: surfaces,
            injectionPolicy: policy,
            contentRole: role(for: kind),
            entities: [ContextEntity(kind: "project", id: "atlas", label: "Atlas")],
            triggers: ["Atlas"],
            activation: activation,
            recentUsefulness: 0.5,
            decayState: 0.9,
            embedding: embedding.map {
                ContextEmbedding(modelFingerprint: "fixture", values: $0)
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
            let descriptor = ContextSourceDescriptor(
                id: atom.draft.sourceID,
                owner: "fixture",
                kind: .other,
                canonicalLocator: atom.draft.sourceID.rawValue,
                authority: atom.draft.authority,
                privacy: atom.draft.privacy,
                permittedSurfaces: atom.draft.permittedSurfaces,
                injectionPolicy: atom.draft.injectionPolicy
            )
            return ContextStoredSource(
                descriptor: descriptor,
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
                reason: "selection fixture",
                sourceFingerprint: "fixture-fingerprint",
                atomCount: atoms.count,
                sourceCount: sources.count
            ),
            sources: sources,
            atoms: atoms,
            relationships: []
        )
    }

    private func role(for kind: ContextAtomKind) -> ContextContentRole {
        switch kind {
        case .identity: .identity
        case .instruction, .correction, .runtimeTruth: .instruction
        case .memory: .memory
        case .procedure: .procedure
        case .evidence: .evidence
        default: .fact
        }
    }
}

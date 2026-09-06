import Context
import Foundation
import Testing

/// Fluid Context sweep items 23 + 24 (2026-09-01).
///
/// 23 — knowledge-graph relations must be PULLED, never pushed: a message that
///      names an entity selects its relationship atoms; an unrelated message
///      selects none; the kind cap holds however many relations exist.
/// 24 — skill pointers must keep the share the legacy recall lane guarantees
///      them (`MemoryRecallScoring.selectRecallResults`, max(1, k/3)) now that
///      they arrive as ordinary `.memory` atoms on the active lane.
@Suite("Fluid Context — relationship reach and skill-pointer reserve")
struct ContextRelationshipAndSkillReserveTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    // MARK: - 23: relations are selectable, not injected

    @Test func messageNamingAnEntitySelectsItsRelationAtoms() throws {
        let relations = [
            relation("kg-1", subject: "User", predicate: "works_on", object: "Hermes"),
            relation("kg-2", subject: "User", predicate: "owns", object: "Hermes"),
        ]
        let unrelated = (0..<6).map { index in
            atom("mem-\(index)", source: "mem-\(index)", kind: .memory,
                 body: "Telescope collimation note number \(index).")
        }
        let fixture = generation(relations + unrelated)
        let packet = try ContextSelector().select(
            signal("What is User doing with Hermes?", generation: fixture), from: fixture
        )
        #expect(packet.receipt.selectedAtomIDs.contains(relations[0].draft.id))
        #expect(packet.selectedItems.allSatisfy { !$0.mandatory })
    }

    @Test func unrelatedMessageSelectsNoRelationAtoms() throws {
        let relations = [
            relation("kg-1", subject: "User", predicate: "works_on", object: "Hermes"),
            relation("kg-2", subject: "Agent", predicate: "knows", object: "Claude"),
        ]
        let answer = atom("answer", source: "answer", kind: .memory,
                          body: "Watering frequency is weekly.")
        let fixture = generation(relations + [answer])
        let packet = try ContextSelector().select(
            signal("What is the watering frequency?", generation: fixture), from: fixture
        )
        #expect(packet.receipt.selectedAtomIDs.contains(answer.draft.id))
        for stored in relations {
            #expect(!packet.receipt.selectedAtomIDs.contains(stored.draft.id))
        }
    }

    @Test func relationKindCapHoldsWhenEveryRelationIsRelevant() throws {
        // Twelve on-topic relations, one per source so the per-source cap
        // cannot be what bounds them.
        let relations = (0..<12).map { index in
            relation("kg-\(index)", subject: "Hermes", predicate: "involves",
                     object: "Hermes component \(index)", source: "kg-source-\(index)")
        }
        let fixture = generation(relations)
        let packet = try ContextSelector().select(
            signal("Tell me about Hermes involves components", generation: fixture, budget: 5_000),
            from: fixture
        )
        let selected = packet.selectedItems.filter { $0.pointer.kind == .relationship }
        #expect(selected.count == ContextSelectionConfiguration().maximumAtoms(forKind: .relationship))
        #expect(selected.count == 4)
    }

    // MARK: - 24: the skill-pointer reserve

    /// The regression this restores, in the shape the live arena showed it
    /// (generation 3046): eight memories win on embedding cosine and activation,
    /// saturate the 8-slot `.memory` quota, and the one skill pointer that
    /// actually speaks the message's vocabulary never lands.
    @Test func relevantSkillPointerSurvivesEightHigherScoringMemories() throws {
        let skill = skillPointer(
            "skill-pointer",
            body: "Skill available: ledger-sentinel-detach — detach the ledger "
                + "sentinel before a nightly rollup."
        )
        // Deliberately distinct from one another: near-identical bodies would
        // penalise each other for redundancy and let the skill in on a
        // technicality instead of on the reserve.
        let bodies = [
            "Quarterly orchard irrigation audit closed without findings.",
            "Telescope collimation drifts after cold nights.",
            "Espresso grinder burr replacement is overdue.",
            "Passport renewal appointment moved to Tuesday morning.",
            "Bicycle chain wear measured at half a millimetre.",
            "Greenhouse humidity sensor reads three points high.",
            "Attic insulation invoice was paid by bank transfer.",
            "Kayak hull repair epoxy needs a warmer garage.",
        ]
        let memories = bodies.enumerated().map { index, body in
            atom("mem-\(index)", source: "mem-\(index)", kind: .memory,
                 body: body, activation: 1, embedding: [1, 0])
        }
        let fixture = generation([skill] + memories)
        let need = signal(
            "detach the ledger sentinel now",
            generation: fixture, budget: 5_000, queryEmbedding: [1, 0]
        )

        // This pin is about the reserve's REALLOCATION inside a full memory
        // quota, so it opts out of the short-message row cap (2026-09-02),
        // which would otherwise bound this 4-token message to 6 memory rows
        // before the reserve ever mattered.
        let fullQuota = ContextSelectionConfiguration(shortMessageMemoryRowCap: 8)

        // Pre-fix behaviour: every memory outranks the skill pointer and the
        // quota is spent before selection ever reaches it.
        let withoutReserve = try ContextSelector(
            configuration: ContextSelectionConfiguration(
                reservedRoleSlotsPerKind: [:],
                shortMessageMemoryRowCap: 8
            )
        ).select(need, from: fixture)
        #expect(!withoutReserve.receipt.selectedAtomIDs.contains(skill.draft.id))

        let withReserve = try ContextSelector(configuration: fullQuota).select(need, from: fixture)
        #expect(withReserve.receipt.selectedAtomIDs.contains(skill.draft.id))
        // Reallocation, not growth: same dynamic count, one fewer plain memory.
        #expect(withReserve.selectedItems.count == withoutReserve.selectedItems.count)
        let plainMemories = withReserve.selectedItems.filter {
            $0.pointer.kind == .memory && $0.pointer.atomID != skill.draft.id
        }
        #expect(plainMemories.count == 7)
    }

    /// The merit gate: an off-topic pointer stays out. Without it the reserve
    /// would hand two packet slots to whichever skill happened to clear the
    /// global relevance floor — clause 6 in reverse.
    @Test func offTopicSkillPointerIsNotPromoted() throws {
        let skill = skillPointer(
            "skill-pointer",
            body: "Skill available: orchard-irrigation-audit — audit the orchard "
                + "irrigation schedule and its watering telemetry."
        )
        let memories = (0..<8).map { index in
            atom("mem-\(index)", source: "mem-\(index)", kind: .memory,
                 body: "Ledger sentinel nightly rollup note \(index).")
        }
        let fixture = generation([skill] + memories)
        let packet = try ContextSelector().select(
            signal("detach the ledger sentinel before the nightly rollup",
                   generation: fixture, budget: 5_000),
            from: fixture
        )
        #expect(!packet.receipt.selectedAtomIDs.contains(skill.draft.id))
    }

    /// The reserve REALLOCATES the memory quota, it never widens the packet.
    @Test func reserveDoesNotWidenTheMemoryQuotaOrThePacket() throws {
        let skills = (0..<3).map { index in
            skillPointer("skill-\(index)", body: "Skill available: repository recovery \(index).")
        }
        let memories = (0..<10).map { index in
            atom("mem-\(index)", source: "mem-\(index)", kind: .memory,
                 body: "Repository recovery memory \(index).")
        }
        let fixture = generation(skills + memories)
        let packet = try ContextSelector().select(
            signal("repository recovery", generation: fixture, budget: 5_000), from: fixture
        )
        let memoryAtoms = packet.selectedItems.filter { $0.pointer.kind == .memory }
        #expect(memoryAtoms.count <= 8)
        #expect(packet.selectedItems.count <= ContextSelectionConfiguration().maximumDynamicAtoms)
        // Two reserved slots, so no more than two skill pointers ride the
        // reserve; the rest compete on score like any other memory.
        let skillIDs = Set(skills.map(\.draft.id))
        let selectedSkills = packet.selectedItems.filter { skillIDs.contains($0.pointer.atomID) }
        #expect(selectedSkills.count >= 1)
    }

    /// A turn with no skill-pointer candidate must select exactly what it
    /// selected before the reserve existed.
    @Test func turnWithoutSkillPointersIsUnchanged() throws {
        let memories = (0..<12).map { index in
            atom("mem-\(index)", source: "mem-\(index)", kind: .memory,
                 body: "Repository recovery memory \(index).")
        }
        let fixture = generation(memories)
        let need = signal("repository recovery", generation: fixture, budget: 5_000)
        let withReserve = try ContextSelector().select(need, from: fixture)
        let withoutReserve = try ContextSelector(
            configuration: ContextSelectionConfiguration(reservedRoleSlotsPerKind: [:])
        ).select(need, from: fixture)
        #expect(withReserve.receipt.selectedAtomIDs == withoutReserve.receipt.selectedAtomIDs)
    }

    @Test func aReserveCanNeverClaimAKindsWholeQuota() {
        let configuration = ContextSelectionConfiguration(
            maximumAtomsPerKindOverrides: [.memory: 3],
            reservedRoleSlotsPerKind: [.memory: ContextRoleReservation(role: .procedure, slots: 9)]
        )
        #expect(configuration.reservedRoleSlotsPerKind[.memory]?.slots == 2)
    }

    // MARK: - Fixtures

    private func signal(
        _ message: String,
        generation: ContextStoredGeneration,
        budget: Int = 1_000,
        queryEmbedding: [Float]? = nil
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
            queryEmbedding: queryEmbedding,
            queryEmbeddingModelFingerprint: queryEmbedding == nil ? nil : "fixture",
            availableGenerationID: generation.generation.id,
            characterBudget: budget,
            now: now,
            cacheState: .hit
        )
    }

    private func relation(
        _ id: String,
        subject: String,
        predicate: String,
        object: String,
        source: String? = nil
    ) -> ContextStoredAtom {
        atom(
            id,
            source: source ?? "kg-\(subject.lowercased())",
            kind: .relationship,
            body: "\(subject) —\(predicate)→ \(object)",
            role: .fact,
            entities: [
                ContextEntity(kind: "kg_entity", id: subject.lowercased(), label: subject),
                ContextEntity(kind: "kg_entity", id: object.lowercased(), label: object),
            ],
            triggers: [subject.lowercased(), predicate, object.lowercased()]
        )
    }

    private func skillPointer(_ id: String, body: String) -> ContextStoredAtom {
        atom(id, source: id, kind: .memory, body: body, role: .procedure)
    }

    private func atom(
        _ id: String,
        source: String,
        kind: ContextAtomKind,
        body: String,
        role: ContextContentRole? = nil,
        entities: [ContextEntity] = [],
        triggers: [String] = [],
        activation: Double = 0,
        embedding: [Float]? = nil
    ) -> ContextStoredAtom {
        let sourceID = ContextSourceID(rawValue: "source:\(source)")
        let atomID = ContextAtomID(rawValue: "atom:\(id)")
        let draft = ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: kind,
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
            contentRole: role ?? (kind == .memory ? .memory : .fact),
            entities: entities,
            triggers: triggers,
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
                reason: "sweep-23-24 fixture",
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

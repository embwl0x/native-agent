import Foundation
import NativeAgentCore
import Testing
@testable import Context

extension ContextFlowCoordinatorTests {
    @Test
    func largeAdaptiveRelationshipDoesNotDisplaceProtectedCorrection() async throws {
        let relationship = compiledSource(
            id: "relationship",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: String(repeating: "relationship context ", count: 400),
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let correction = compiledSource(
            id: "correction",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/correction",
            kind: .correction,
            body: "User's explicit correction remains protected.",
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [relationship, correction]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Continue our unrelated task.",
            personaIDHint: "Agent",
            characterBudget: 6_000
        ))

        let correctionID = try #require(correction.atoms.first?.id)
        let relationshipID = try #require(relationship.atoms.first?.id)
        #expect(prepared.packet.receipt.mandatoryAtomIDs.contains(correctionID))
        #expect(prepared.packet.receipt.coveredMandatoryAtomIDs.contains(correctionID))
        #expect(!prepared.packet.receipt.mandatoryAtomIDs.contains(relationshipID))
        #expect(prepared.packet.receipt.mandatoryCoverage == 1)
        #expect(prepared.packet.receipt.budget.usedCharacters <= 6_000)
    }

    @Test
    func accumulatedCorrectionsUseBoundedRetryAndPreserveRankedContext() async throws {
        let corrections = (0..<4).map { index in
            compiledSource(
                id: "correction-\(index)",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/records/correction-\(index)",
                kind: .correction,
                body: String(repeating: "explicit correction \(index) remains authoritative. ", count: 55),
                authority: .explicitCorrection,
                policy: .adaptive
            )
        }
        let memory = compiledSource(
            id: "relevant-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/relevant-memory",
            kind: .memory,
            body: String(
                repeating: "The cobalt garden project uses a bounded resident context path. ",
                count: 20
            ),
            authority: .canonical,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: corrections + [memory]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Continue the cobalt garden project using resident context.",
            personaIDHint: "Agent",
            characterBudget: 6_000,
            maximumCharacterBudget: 24_000,
            postMandatoryCharacterReserve: 4_000
        ))

        let correctionIDs = try corrections.map {
            try #require($0.atoms.first?.id)
        }
        let memoryID = try #require(memory.atoms.first?.id)
        let expansion = try #require(prepared.budgetExpansion)
        #expect(prepared.need.characterBudget > 6_000)
        #expect(prepared.need.characterBudget <= 24_000)
        #expect(expansion.requestedCharacterBudget == 6_000)
        #expect(expansion.effectiveCharacterBudget == prepared.need.characterBudget)
        #expect(expansion.maximumCharacterBudget == 24_000)
        #expect(expansion.mandatoryCharacterBudget == prepared.packet.receipt.budget.mandatoryCharacters)
        #expect(expansion.grantedPostMandatoryReserve == max(0, expansion.effectiveCharacterBudget - expansion.mandatoryCharacterBudget))
        #expect(prepared.packet.receipt.budget.characterLimit == prepared.need.characterBudget)
        #expect(prepared.packet.receipt.budget.usedCharacters <= prepared.need.characterBudget)
        #expect(Set(prepared.packet.receipt.mandatoryAtomIDs).isSuperset(of: correctionIDs))
        #expect(Set(prepared.packet.receipt.coveredMandatoryAtomIDs).isSuperset(of: correctionIDs))
        #expect(prepared.packet.receipt.selectedAtomIDs.contains(memoryID))
        #expect(prepared.packet.receipt.mandatoryCoverage == 1)
    }

    @Test
    func accumulatedCorrectionsStillFailClosedAtConfiguredCeiling() async throws {
        let corrections = (0..<4).map { index in
            compiledSource(
                id: "oversized-correction-\(index)",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/records/oversized-correction-\(index)",
                kind: .correction,
                body: String(repeating: "authoritative correction \(index). ", count: 90),
                authority: .explicitCorrection,
                policy: .adaptive
            )
        }
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: corrections
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        do {
            _ = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
                surface: .chat,
                origin: .localAuthenticated,
                userMessage: "hello",
                personaIDHint: "Agent",
                characterBudget: 6_000,
                maximumCharacterBudget: 8_000,
                postMandatoryCharacterReserve: 4_000
            ))
            Issue.record("Expected the configured maximum budget to fail closed")
        } catch ContextSelectionError.mandatoryBudgetExceeded(let required, let limit) {
            #expect(required > limit)
            #expect(limit == 8_000)
        }
    }

    /// PRODUCT POLICY (User approved, 2026-07-24): a persona slot id is
    /// PRESENTATION-ONLY — a custom persona reads the SHARED memory store,
    /// exactly as the resident does. This test asserted the OPPOSITE earlier
    /// today; the old "isolation" was an id-vocabulary mismatch protecting an
    /// unmintable, permanently empty scope.
    ///
    /// The mismatched-vocabulary discipline is KEPT: the mirror carries a
    /// persona SLOT id ("CustomPersona" — a persona subdirectory name) while every
    /// projected memory scope is a digest of a RECORD persona id (agent names,
    /// the only vocabulary in the live store: "Agent", "NativeAgent"). Never
    /// the same literal on both sides — a same-string test can't see the live
    /// shape.
    @Test
    func customPersonaSlotAdmitsSharedAgentNameScopedMemory() async throws {
        // Keep the semantic roles distinct after the public exporter rewrites
        // the private resident name to the generic "agent" vocabulary.
        let residentNameScope = ContextStableID.digest(parts: ["agent"])
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        let residentNameMemory = compiledSource(
            id: "agent-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(residentNameScope)/records/one",
            kind: .memory,
            body: "Record persona id \"Agent\" — an agent name, not a slot id.",
            authority: .canonical,
            policy: .adaptive
        )
        let agentMemory = compiledSource(
            id: "agent-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScope)/records/two",
            kind: .memory,
            body: "Record persona id \"NativeAgent\" — the other live agent name.",
            authority: .canonical,
            policy: .adaptive
        )
        let sharedMemory = compiledSource(
            id: "shared-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/shared/records/three",
            kind: .memory,
            body: "Unscoped shared memory.",
            authority: .canonical,
            policy: .adaptive
        )
        // NEGATIVE CONTROL: the selection filter is still doing real work — a
        // persona DOC belonging to another slot stays out. Without this, a
        // blanket admit-everything regression would green this test.
        let otherPersonaDoc = compiledSource(
            id: "other-persona-doc",
            owner: "nativeagent.persona",
            locator: "persona/Marcus/SOUL.md",
            kind: .fact,
            body: "Another persona slot's identity document.",
            authority: .identity,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [residentNameMemory, agentMemory, sharedMemory, otherPersonaDoc],
            mirrorPersonaID: ContextPersonaID(rawValue: "CustomPersona")
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: "CustomPersona"
        ))
        let allowed = prepared.need.authorization.allowedSourceIDs

        // Slot "CustomPersona" reads the shared store: BOTH agent-name scopes land.
        #expect(allowed.contains(residentNameMemory.descriptor.id))
        #expect(allowed.contains(agentMemory.descriptor.id))
        #expect(allowed.contains(sharedMemory.descriptor.id))
        #expect(!allowed.contains(otherPersonaDoc.descriptor.id))
        // Shared reads are the healthy path — the drift alarm must stay quiet.
        #expect(fixture.diagnostics.memoryVocabularyDrift.isEmpty)
    }

    /// The surviving guard after the shared-store decision (2026-07-24). Memory
    /// is shared across persona slots, so no slot can starve and a starvation
    /// alarm would only ever fire on healthy behavior. The mismatch that is
    /// still REAL — and now the only one — is a live memory source scoped by
    /// digest(SLOT id): that means a writer began minting per-SLOT memory
    /// scopes, i.e. the two id vocabularies merged and the presentation-only
    /// decision has to be re-reviewed before a per-slot shard ships.
    ///
    /// This is the counterpart of the production-side guard in
    /// NativeMemoryContextProjectionTests.personaScopeUsesRecordPersonaVocabularyOnly.
    @Test
    func slotIDScopedMemorySourceTripsTheVocabularyDriftAlarm() async throws {
        let slotScope = ContextStableID.digest(parts: ["secondary"])
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        // Production never emits this shape — the fixture hand-mints it.
        let slotScopedMemory = compiledSource(
            id: "slot-scoped-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(slotScope)/records/one",
            kind: .memory,
            body: "Production-impossible slot-id-scoped memory.",
            authority: .canonical,
            policy: .adaptive
        )
        let liveShapedMemory = compiledSource(
            id: "live-shaped-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScope)/records/two",
            kind: .memory,
            body: "The shape production actually writes.",
            authority: .canonical,
            policy: .adaptive
        )

        // (a) Slot-id-scoped record present: still ADMITTED (memory is shared —
        //     the alarm never withholds context), but the turn says so loudly.
        let drifted = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [slotScopedMemory],
            mirrorPersonaID: ContextPersonaID(rawValue: "Secondary")
        )
        defer { drifted.cleanup() }
        await drifted.coordinator.start()
        let admitted = try await drifted.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: "Secondary"
        ))
        #expect(admitted.need.authorization.allowedSourceIDs.contains(slotScopedMemory.descriptor.id))
        #expect(drifted.diagnostics.memoryVocabularyDrift.count == 1)

        // (b) The live shape — agent-name scopes, mismatched against the slot
        //     id on purpose. Admitted AND silent: this is correct behavior.
        let live = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [liveShapedMemory],
            mirrorPersonaID: ContextPersonaID(rawValue: "Secondary")
        )
        defer { live.cleanup() }
        await live.coordinator.start()
        let healthy = try await live.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: "Secondary"
        ))
        #expect(healthy.need.authorization.allowedSourceIDs.contains(liveShapedMemory.descriptor.id))
        #expect(live.diagnostics.memoryVocabularyDrift.isEmpty)
    }

    /// Drift must be LOUD but BOUNDED: one error line per side-effecting turn
    /// naming the slot id, the computed prefix, and how many sources drifted —
    /// never one line per source or per atom.
    @Test
    func vocabularyDriftLogsOncePerTurnNamingSlotAndPrefix() async throws {
        let slotScope = ContextStableID.digest(parts: ["secondary"])
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        let sources = [
            compiledSource(
                id: "slot-scoped-one",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/personas/\(slotScope)/records/one",
                kind: .memory,
                body: "Slot-scoped memory one.",
                authority: .canonical,
                policy: .adaptive
            ),
            compiledSource(
                id: "slot-scoped-two",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/personas/\(slotScope)/records/two",
                kind: .memory,
                body: "Slot-scoped memory two.",
                authority: .canonical,
                policy: .adaptive
            ),
            // Mismatched-vocabulary companion: an agent-name scope alongside
            // the drifted ones must not be counted as drift.
            compiledSource(
                id: "agent-memory",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/personas/\(agentScope)/records/three",
                kind: .memory,
                body: "NativeAgent-scoped memory.",
                authority: .canonical,
                policy: .adaptive
            ),
        ]
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: sources,
            mirrorPersonaID: ContextPersonaID(rawValue: "Secondary")
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        _ = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: "Secondary"
        ))

        let logged = fixture.diagnostics.memoryVocabularyDrift
        #expect(logged.count == 1)
        let line = try #require(logged.first)
        #expect(line.contains("ERROR"))
        #expect(line.contains("\"Secondary\""))
        #expect(line.contains("memory-v2/personas/\(slotScope)/"))
        // 2 of the 3 memory sources drifted — the agent-name one is not drift.
        #expect(line.contains("2 live memory source(s)"))

        // Bounded: a second turn logs once more, never once per source/atom.
        _ = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory again",
            personaIDHint: "Secondary"
        ))
        #expect(fixture.diagnostics.memoryVocabularyDrift.count == 2)
    }

    /// Negative controls: the alarm must not cry wolf on the healthy paths.
    @Test
    func memoryScopeDriftAlarmStaysQuietForResidentAndForSharedScopes() async throws {
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        let agentMemory = compiledSource(
            id: "agent-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScope)/records/one",
            kind: .memory,
            body: "NativeAgent-scoped memory.",
            authority: .canonical,
            policy: .adaptive
        )
        let sharedMemory = compiledSource(
            id: "shared-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/shared/records/two",
            kind: .memory,
            body: "Shared memory.",
            authority: .canonical,
            policy: .adaptive
        )

        // Resident owns the whole store — never starved.
        let resident = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [agentMemory],
            mirrorPersonaID: .resident
        )
        defer { resident.cleanup() }
        await resident.coordinator.start()
        _ = try await resident.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: ContextPersonaID.resident.rawValue
        ))
        #expect(resident.diagnostics.memoryVocabularyDrift.isEmpty)

        // A custom persona reading the shared store is the healthy path too.
        let custom = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [agentMemory, sharedMemory],
            mirrorPersonaID: ContextPersonaID(rawValue: "Secondary")
        )
        defer { custom.cleanup() }
        await custom.coordinator.start()
        _ = try await custom.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: "Secondary"
        ))
        #expect(custom.diagnostics.memoryVocabularyDrift.isEmpty)
    }

    /// Regression (2026-07-24): memory persona scopes are digests of MemoryV2
    /// record persona ids (agent names, e.g. "NativeAgent"), while the mirror
    /// carries the persona SLOT id ("canonical"). The live app pairs these two
    /// vocabularies, so a prefix built from the slot id can never match — and
    /// every memory source was silently excluded from live turns (memoryRecords
    /// stuck at 0, use_count/activation loop starved). The resident default
    /// persona must admit every memory scope. (Custom slots now do too — see
    /// customPersonaSlotAdmitsSharedAgentNameScopedMemory; a slot id is
    /// presentation-only.) This test intentionally uses MISMATCHED vocabularies
    /// on the two sides — same-string tests could never catch the live shape.
    @Test
    func residentPersonaAdmitsAgentNameScopedMemorySources() async throws {
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        let customScope = ContextStableID.digest(parts: ["secondary"])
        let agentMemory = compiledSource(
            id: "agent-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScope)/records/one",
            kind: .memory,
            body: "Default-agent memory record.",
            authority: .canonical,
            policy: .adaptive
        )
        let customMemory = compiledSource(
            id: "custom-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(customScope)/records/two",
            kind: .memory,
            body: "Custom-persona memory record.",
            authority: .canonical,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [agentMemory, customMemory],
            mirrorPersonaID: .resident
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: ContextPersonaID.resident.rawValue
        ))
        let allowed = prepared.need.authorization.allowedSourceIDs

        // The resident owns the whole memory store — both scopes are hers.
        #expect(allowed.contains(agentMemory.descriptor.id))
        #expect(allowed.contains(customMemory.descriptor.id))
    }

    /// Admission is not delivery. This is the end of the pipe: a custom persona
    /// slot must get the shared store's memory as a real ATOM in the prepared
    /// packet, not merely an authorized source id. (Flipped 2026-07-24 from
    /// `customPersonaStillCannotSeeAgentNameScopedMemorySources`, which pinned
    /// the id-vocabulary mismatch as if it were intended isolation.)
    @Test
    func customPersonaSlotGetsSharedMemoryAtomsInThePreparedPacket() async throws {
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        let agentMemory = compiledSource(
            id: "agent-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScope)/records/one",
            kind: .correction,
            body: "User drinks jasmine tea after lunch, reliably.",
            authority: .explicitCorrection,
            policy: .always
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [agentMemory],
            mirrorPersonaID: ContextPersonaID(rawValue: "Secondary")
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "what does User drink after lunch?",
            personaIDHint: "Secondary"
        ))

        #expect(prepared.need.authorization.allowedSourceIDs.contains(agentMemory.descriptor.id))
        let memoryAtomID = try #require(agentMemory.atoms.first?.id, "fixture must mint an atom")
        #expect(prepared.packet.receipt.selectedAtomIDs.contains(memoryAtomID))
        #expect(prepared.packet.selectedItems.contains { $0.text.contains("jasmine tea") })
    }

}

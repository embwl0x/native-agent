import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration
@testable import Context
@testable import ProviderRouting

// MARK: - INVARIANTS (4) FLUID CONTEXT and (5) TOOLS, at the assembled turn
//
// Measured 2026-09-01: `persona.docChars = 22,278` vs `system.stableChars =
// 4,601` — only SOUL and VOICE reached the cached prefix, and USER / GROWTH /
// MEMORY / AGENTS were re-sent in the per-turn uncached mass on every single
// turn. Identity was being paid for as if it were relevance. In the same
// measurement corrections averaged 830 chars and reached 2 KB, uncapped, so the
// STORY shipped with the RULE whether or not the turn needed it.
//
// `FluidContextLeadAndStablePersonaTests` pins each of those producers. What it
// cannot see is the assembled turn: whether the persona bytes actually land in
// the cached region of the WIRE request, identically, on turn six as on turn
// one, and on telegram as on chat. That is what this file adds.

// MARK: - A compact real ContextPreparedTurn

private enum FluidFixture {
    static let personaID = ContextPersonaID(rawValue: "canonical")
    static let fingerprint = "persona-fingerprint"
    static let soulText = "I am the agent this installation configured."
    static let userText = "User has ADHD: answer first, detail after."
    static let growthText = "Approved drift is curated, never inferred."

    /// A 1,500-char correction — the exact shape that used to ship whole on
    /// every turn. Its first sentence IS the rule; the rest is the incident.
    static let longCorrection: String = {
        let rule = "Never run tests or evals on your own initiative. "
        return rule + String(repeating: "orchard ", count: 200)
    }()

    static let longMemory: String = {
        let lead = "The rollout gate is script/test.sh and it is required. "
        return lead + String(repeating: "detail ", count: 220)
    }()

    static func atom(
        _ id: String,
        kind: ContextAtomKind,
        body: String,
        summary: String? = nil
    ) -> ContextStoredAtom {
        ContextStoredAtom(
            versionKey: "atom:\(id)@1",
            draft: ContextAtomDraft(
                id: ContextAtomID(rawValue: "atom:\(id)"),
                sourceID: ContextSourceID(rawValue: "source:fixture"),
                kind: kind,
                headingPath: [id],
                sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
                sourceHash: "hash:fixture",
                body: body,
                deterministicSummary: summary,
                authority: kind == .correction ? .explicitCorrection : .approved,
                confidence: 0.9,
                freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 9_000)),
                privacy: .localPrivate,
                permittedSurfaces: [.chat, .telegram],
                injectionPolicy: .adaptive,
                contentRole: kind == .memory ? .memory : .instruction
            ),
            validFromGeneration: 1,
            validToGeneration: nil
        )
    }

    static func pointer(_ stored: ContextStoredAtom) -> ContextAtomPointer {
        ContextAtomPointer(atom: stored, generationID: 1)
    }

    static func item(_ stored: ContextStoredAtom, summary: String? = nil) -> ContextPacketItem {
        ContextPacketItem(
            pointer: pointer(stored),
            text: stored.draft.body,
            representation: .body,
            mandatory: false,
            summary: summary
        )
    }

    static func packet(
        items: [ContextPacketItem],
        pointers: [ContextAtomPointer]
    ) -> ContextPacket {
        let budget = ContextBudgetUsage(
            characterLimit: 6_000, usedCharacters: 0, mandatoryCharacters: 0
        )
        return ContextPacket(
            generationID: 1,
            sourceFingerprint: fingerprint,
            selectedItems: items,
            expandablePointers: pointers,
            conflictSets: [],
            degradedSources: [],
            budget: budget,
            receipt: ContextSelectionReceipt(
                id: "receipt",
                needFingerprint: "need",
                generationID: 1,
                sourceFingerprint: fingerprint,
                selectionTimeBucket: 1,
                eligibility: [],
                candidateScores: [],
                selectedAtomIDs: items.map(\.pointer.atomID),
                pointerAtomIDs: pointers.map(\.atomID),
                mandatoryAtomIDs: [],
                coveredMandatoryAtomIDs: [],
                mandatoryCoverage: 1,
                conflicts: [],
                budget: budget,
                degradedSources: [],
                cacheState: .hit,
                measuredSelectionMicroseconds: 1
            )
        )
    }

    /// A REAL prepared turn: real mirror, real arena lease, real packet, real
    /// need — the same object the production turn engine renders from.
    static func preparedTurn(
        surface: String = "chat",
        items: [ContextPacketItem] = [],
        pointers: [ContextAtomPointer] = [],
        thresholdChars: Int = ContextBudgetPolicy.packetAtomExpandThresholdChars,
        memoryAtomRowLimit: Int? = ContextBudgetPolicy.wideRecallRowLimit
    ) throws -> ContextPreparedTurn {
        let soul = try RequiredDocument(
            kind: .soul, sourceHash: "soul-hash", text: soulText, tokenCount: 8
        )
        let user = try RequiredDocument(
            kind: .user, sourceHash: "user-hash", text: userText, tokenCount: 9
        )
        let growth = try RequiredDocument(
            kind: .growth, sourceHash: "growth-hash", text: growthText, tokenCount: 7
        )
        let kernels = try ["chat", "telegram"].map { variant in
            try StablePromptKernel(
                key: StablePromptKernelKey(
                    personaID: personaID,
                    surfaceVariant: ContextSurfaceVariant(rawValue: variant),
                    sourceFingerprint: fingerprint
                ),
                renderedPrompt: "# SOUL\n\(soulText)",
                includedDocumentIDs: [soul.id],
                tokenCount: 10
            )
        }
        let mirror = try RequiredDocumentMirror(
            personaID: personaID,
            sourceFingerprint: fingerprint,
            documents: [soul, user, growth],
            kernels: kernels
        )
        let snapshot = try ContextGenerationSnapshot(
            generationID: 1,
            sourceFingerprint: "generation-fingerprint",
            requiredDocumentMirrors: [mirror]
        )
        let arena = try ContextArena(budget: .mib32)
        _ = arena.publish(snapshot)
        let lease = try arena.acquireSnapshot()
        let kernel = try #require(
            mirror.kernel(for: ContextSurfaceVariant(rawValue: surface))
        )
        let generation = ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: .distantPast,
                reason: "turn-regression",
                sourceFingerprint: snapshot.sourceFingerprint,
                atomCount: items.count,
                sourceCount: 0
            ),
            sources: [],
            atoms: [],
            relationships: []
        )
        let need = NeedSignal(
            message: "what did we decide about the rollout",
            surface: ContextSurface(rawValue: surface),
            origin: .localAuthenticated,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: [.localAuthenticated],
                allowedPrivacy: [.localPrivate],
                allowedSourceIDs: []
            ),
            availableGenerationID: 1,
            packetAtomExpandThresholdChars: thresholdChars,
            memoryAtomRowLimit: memoryAtomRowLimit,
            now: Date(timeIntervalSince1970: 10_000),
            cacheState: .hit
        )
        return ContextPreparedTurn(
            mode: .active,
            kernel: kernel,
            mirror: mirror,
            packet: packet(items: items, pointers: pointers),
            lease: lease,
            generation: generation,
            need: need
        )
    }
}

// MARK: - (4) Fluid context

@Suite("TurnRegression.FluidContext")
struct FluidContextTurnRegressionTests {

    /// Identity is CACHED PREFIX BYTES. Six turns, two surfaces, one string.
    /// Anything turn- or surface-derived leaking into it breaks the provider
    /// cache, which is the entire reason it moved there.
    @Test("the persona head is byte-identical across six turns and across surfaces")
    func personaHeadIsByteIdenticalAcrossTurnsAndSurfaces() throws {
        let chat = TurnRegression.sixTurns()
        let telegram = TurnRegression.sixTurns(surface: TurnRegression.telegramSurface)

        func stableRegion(_ turn: TurnRegression.Turn) -> String {
            // Everything except the trailing volatile message: on v2 the whole
            // system prompt IS the stable mass.
            TurnRegression.systemText(turn.body)
        }
        let head = try #require(chat.first.map(stableRegion))
        #expect(head.contains("# SOUL"))
        #expect(head.contains("# USER"))
        #expect(head.contains("# GROWTH"), "USER/GROWTH must reach the CACHED region")
        for turn in chat {
            #expect(stableRegion(turn) == head, "turn \(turn.index) rewrote the persona head")
        }
        for turn in telegram {
            #expect(
                stableRegion(turn) == head,
                "telegram turn \(turn.index) rendered a different persona head"
            )
        }
    }

    /// …and the churn is REAL, so the test above is not passing because nothing
    /// in the request ever changes. Every turn's volatile block differs.
    @Test("the per-turn volatile mass really does churn, outside the cached head")
    func theVolatileMassChurnsOutsideTheCachedHead() {
        let turns = TurnRegression.sixTurns()
        let blocks = turns.compactMap(\.seed.context.turnVolatileBlock)
        #expect(blocks.count == 6, "every v2 turn relocates its volatile mass")
        #expect(Set(blocks).count == 6, "six turns produced fewer than six volatile blocks")
        for block in blocks {
            #expect(
                !block.contains("# SOUL"),
                "persona bytes leaked back into the uncached per-turn block"
            )
        }
    }

    /// A 1,500-char correction ships as its RULE plus a pointer — not as the
    /// incident that produced it, on every turn, forever.
    @Test("a long correction renders as lead plus a context_expand pointer")
    func aLongCorrectionRendersAsLeadPlusPointer() throws {
        let correction = FluidFixture.atom(
            "correction-1", kind: .correction, body: FluidFixture.longCorrection
        )
        let prepared = try FluidFixture.preparedTurn(
            items: [FluidFixture.item(correction)],
            pointers: [FluidFixture.pointer(correction)]
        )
        let rendered = SwiftNativeTurnEngine.renderContextPacket(prepared)
        #expect(rendered.contains("Never run tests or evals on your own initiative."))
        #expect(
            rendered.contains("[context_expand atom:correction-1 —"),
            "a truncated atom must carry its own reach: \(rendered.prefix(400))"
        )
        #expect(
            !rendered.contains(FluidFixture.longCorrection),
            "the whole incident shipped anyway"
        )
        #expect(
            rendered.count < FluidFixture.longCorrection.count,
            "lead + pointer has to be cheaper than the body"
        )
    }

    /// A short atom is never turned into a pointer — reaching for a rule that
    /// already fits is worse than shipping it.
    @Test("a short atom ships whole and is never turned into a pointer")
    func aShortAtomShipsWhole() throws {
        let short = FluidFixture.atom(
            "note-1", kind: .memory, body: "The rollout gate is script/test.sh."
        )
        let prepared = try FluidFixture.preparedTurn(items: [FluidFixture.item(short)])
        let rendered = SwiftNativeTurnEngine.renderContextPacket(prepared)
        #expect(rendered.contains("The rollout gate is script/test.sh."))
        #expect(!rendered.contains("context_expand atom:note-1"))
    }

    /// The rendered packet is DETERMINISTIC — same atoms, same bytes, every
    /// turn. A renderer that varied would put churn inside the packet even when
    /// the selection did not move.
    @Test("the rendered packet is byte-identical for the same selection")
    func theRenderedPacketIsDeterministic() throws {
        let correction = FluidFixture.atom(
            "correction-1", kind: .correction, body: FluidFixture.longCorrection
        )
        let memory = FluidFixture.atom(
            "memory-1", kind: .memory, body: FluidFixture.longMemory
        )
        let items = [FluidFixture.item(correction), FluidFixture.item(memory)]
        let pointers = [FluidFixture.pointer(correction), FluidFixture.pointer(memory)]
        let first = SwiftNativeTurnEngine.renderContextPacket(
            try FluidFixture.preparedTurn(items: items, pointers: pointers)
        )
        let second = SwiftNativeTurnEngine.renderContextPacket(
            try FluidFixture.preparedTurn(items: items, pointers: pointers)
        )
        #expect(first == second)
    }

    /// `context_expand` retrieves only what THIS turn offered. An atom the
    /// packet never published is refused by name — not "not found", which reads
    /// as a store problem, but "not offered this turn", which is the truth.
    @Test("context_expand refuses an atom this turn never offered")
    func contextExpandRefusesAnAtomThisTurnNeverOffered() throws {
        let offered = FluidFixture.atom(
            "correction-1", kind: .correction, body: FluidFixture.longCorrection
        )
        let prepared = try FluidFixture.preparedTurn(
            items: [FluidFixture.item(offered)],
            pointers: [FluidFixture.pointer(offered)]
        )
        let dispatcher = SwiftToolDispatcher(
            dataRoot: TurnRegression.dataRoot("context-expand"),
            allowProcessGlobalTools: false
        )
        let refusal = try FluidContextToolScope.$current.withValue(prepared) {
            try dispatcher.impl_context_expand(
                input: ["atom_id": .string("atom:never-offered")],
                surface: TurnRegression.surface
            )
        }
        guard case .object(let payload) = refusal else {
            Issue.record("context_expand returned a non-object: \(refusal)")
            return
        }
        #expect(payload["status"] == .string("failed"))
        #expect(
            payload["reason"] == .string("pointer_not_offered_this_turn"),
            "an unoffered atom must be refused as UNOFFERED, not as missing"
        )
    }

    /// Without a generation in scope there is nothing to expand, and the tool
    /// says so instead of reaching into whatever generation happens to be live.
    @Test("context_expand is not a global search bypass when no turn is in scope")
    func contextExpandIsNotAGlobalSearchBypass() throws {
        let dispatcher = SwiftToolDispatcher(
            dataRoot: TurnRegression.dataRoot("context-expand-scopeless"),
            allowProcessGlobalTools: false
        )
        let refusal = try dispatcher.impl_context_expand(
            input: ["atom_id": .string("atom:correction-1")],
            surface: TurnRegression.surface
        )
        guard case .object(let payload) = refusal else {
            Issue.record("context_expand returned a non-object: \(refusal)")
            return
        }
        #expect(payload["reason"] == .string("context_generation_unavailable"))
    }

    /// The row limit and the truncation threshold are carried ON THE TURN, so
    /// the renderer and the selector cannot disagree about what was cut and
    /// what is reachable.
    @Test("a chat turn carries the memory row limit and expand threshold the policy sets")
    func theTurnCarriesTheRowLimitAndThresholdItWasSelectedUnder() throws {
        let prepared = try FluidFixture.preparedTurn()
        #expect(prepared.need.memoryAtomRowLimit == ContextBudgetPolicy.wideRecallRowLimit)
        #expect(prepared.need.memoryAtomRowLimit == 12)
        #expect(
            prepared.need.packetAtomExpandThresholdChars
                == ContextBudgetPolicy.packetAtomExpandThresholdChars
        )
        #expect(prepared.need.packetAtomExpandThresholdChars == 400)
    }

    /// The row limit bounds MEMORY rows. A correction is a rule the user
    /// dictated, not a recalled row, and counting it against the memory budget
    /// would let one correction evict the memories the turn needed.
    @Test("the memory row limit bounds memory atoms and does not count corrections")
    func theMemoryRowLimitDoesNotCountCorrections() throws {
        let limit = ContextBudgetPolicy.wideRecallRowLimit
        var items: [ContextPacketItem] = []
        for index in 0..<limit {
            items.append(FluidFixture.item(
                FluidFixture.atom("memory-\(index)", kind: .memory, body: "memory row \(index)")
            ))
        }
        items.append(FluidFixture.item(
            FluidFixture.atom("correction-1", kind: .correction, body: "never guess a receipt")
        ))
        let prepared = try FluidFixture.preparedTurn(items: items)
        let memoryRows = prepared.packet.selectedItems.filter { $0.pointer.kind == .memory }
        let corrections = prepared.packet.selectedItems.filter { $0.pointer.kind == .correction }
        #expect(memoryRows.count <= limit, "memory rows exceeded their own limit")
        #expect(corrections.count == 1, "the correction has to actually be in the packet")
        #expect(
            prepared.packet.selectedItems.count == limit + 1,
            "the correction was counted against the memory budget"
        )
    }
}

// MARK: - (5) Tools

@Suite("TurnRegression.Tools")
struct ToolContractTurnRegressionTests {

    /// The always-on floor is a FLOOR. No budget, no catalog size, no session
    /// state may cut it — an agent that cannot recall or load a tool cannot
    /// recover from anything.
    @Test("the always-on floor is never truncated, whatever the catalog size")
    func theFloorIsNeverTruncated() {
        let big = (0..<120).map { "lazy_tool_\($0)" }
        let ordering = SwiftToolDispatcher.canonicalToolOrder(
            TurnRegression.floorNames + big, loadOrder: []
        )
        for name in TurnRegression.floorNames {
            #expect(ordering.floor.contains(name), "\(name) fell out of the floor")
        }
        #expect(ordering.floor == ordering.floor.sorted(), "the floor is name-sorted")
    }

    /// A load APPENDS. It never reshuffles what the model was already shown,
    /// because a reshuffle rewrites the provider's cached prefix for a reason
    /// the model never asked about.
    @Test("appended tools ride in load order behind an unchanged floor")
    func appendedToolsRideInLoadOrderBehindAnUnchangedFloor() {
        // The contract advertises the floor plus what the session has
        // LOADED; an unloaded lazy tool rides the catalog, not the contract.
        // (Unranked rows in the contract are MCP membership, which is pinned
        // from turn one and deliberately sorts ahead of the load run.)
        let first = SwiftToolDispatcher.canonicalToolOrder(
            TurnRegression.floorNames + ["workshop_submit"],
            loadOrder: ["workshop_submit"]
        )
        let second = SwiftToolDispatcher.canonicalToolOrder(
            TurnRegression.floorNames + ["workshop_submit", "task_ledger_post"],
            loadOrder: ["workshop_submit", "task_ledger_post"]
        )
        #expect(first.floor == second.floor, "a load moved the floor")
        #expect(
            second.advertised.starts(with: first.advertised),
            "a load must APPEND: \(second.advertised) does not extend \(first.advertised)"
        )
    }

    /// Within one turn the tools array is pinned. A tool loop that grew or
    /// shrank its advertised set halfway through would invalidate the prefix it
    /// just paid to create — the 369,217-cache-creation-token turn.
    @Test("the advertised tools array is identical across the rounds of one turn")
    func theToolsArrayIsIdenticalAcrossTheRoundsOfOneTurn() throws {
        let rows = TurnRegression.session()
        let base = TurnRegression.context(
            turn: 0, session: rows, cursor: TurnRegression.cursor()
        )
        let roundOne = TurnRegression.wire(base, index: 0)

        // Round two: the tool loop appended an assistant tool_use and its
        // bounded result. Same context, same tools, one longer array.
        let appended = base.historyMessages + [
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "toolu_1", name: "recall_memory", inputJSON: Data("{}".utf8)),
            ]),
            LLMMessage(role: .user, content: [
                .toolResult(toolUseId: "toolu_1", content: "3 rows", isError: false),
            ]),
        ]
        let roundTwoContext = TurnContext(
            surface: base.surface, personaDocs: [:], recalled: [],
            modelId: base.modelId, reasoningEffort: base.reasoningEffort,
            providerId: base.providerId, toolsAvailable: base.toolsAvailable,
            systemPrompt: base.systemPrompt, userMessage: base.userMessage,
            toolSchemas: base.toolSchemas, systemSegments: base.systemSegments,
            historyMessages: appended,
            historyWindowReceipt: base.historyWindowReceipt
        )
        let roundTwo = TurnRegression.wire(roundTwoContext, index: 0)

        let firstNames = TurnRegression.wireTools(roundOne.body)
            .compactMap { $0["name"] as? String }
        let secondNames = TurnRegression.wireTools(roundTwo.body)
            .compactMap { $0["name"] as? String }
        #expect(!firstNames.isEmpty)
        #expect(firstNames == secondNames, "a later round rewrote the tools array")

        // …and the head is still the same head, so the appended rounds really
        // are append-only.
        #expect(roundOne.digests == roundTwo.digests)
    }

    /// Drops are batched at TURN START. A tool that vanished mid-turn is a tool
    /// the model may already have decided to call.
    @Test("an unload does not shrink the advertised run mid-turn")
    func anUnloadDoesNotShrinkTheAdvertisedRunMidTurn() throws {
        let names = TurnRegression.floorNames + ["workshop_submit", "task_ledger_post"]
        let context = TurnContext(
            surface: TurnRegression.surface, personaDocs: [:], recalled: [],
            modelId: TurnRegression.model, reasoningEffort: "medium",
            toolsAvailable: names, systemPrompt: "sys", userMessage: "hi",
            toolSchemas: names.map { TurnRegression.schema($0) }
        )
        let pinned = SessionToolContract(
            order: ["workshop_submit", "task_ledger_post"],
            loaded: ["workshop_submit", "task_ledger_post"],
            pinnedSchemas: Dictionary(
                uniqueKeysWithValues: ["workshop_submit", "task_ledger_post"].map {
                    ($0, PinnedToolSchema(TurnRegression.schema($0)))
                }
            )
        )
        // The store already dropped one; the PINNED contract for this turn has
        // not, and the pinned contract is what the model was shown.
        let advertised = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
            to: context,
            activeTools: ["workshop_submit"],
            contract: pinned
        )?.toolSchemas.map(\.name) ?? []
        #expect(advertised.contains("task_ledger_post"),
                "a mid-turn unload shrank the advertised run: \(advertised)")
        for name in TurnRegression.floorNames {
            #expect(advertised.contains(name), "\(name) left the floor")
        }
    }

    /// `context_expand` is in the floor, so it is advertised whether or not
    /// this turn's packet published a pointer. It used to be added per turn,
    /// which rewrote the array every time the packet's shape changed.
    @Test("context_expand is advertised even on a turn whose packet offers no pointer")
    func contextExpandIsAdvertisedWithoutAnyPointer() throws {
        let prepared = try FluidFixture.preparedTurn(items: [], pointers: [])
        #expect(prepared.packet.expandablePointers.isEmpty)
        let ordering = SwiftToolDispatcher.canonicalToolOrder(
            TurnRegression.floorNames, loadOrder: []
        )
        #expect(ordering.floor.contains("context_expand"))
    }
}

import Foundation
import NativeAgentCore
import Testing
@testable import ChatOrchestration
@testable import Context

// NORTHSTAR clause 6 — "everything at her fingertips but her mind clear".
//
// Two measurements on 2026-09-01 said the packet was doing the opposite:
//
//   persona.docChars = 22,278 vs system.stableChars = 4,601
//       — only SOUL/VOICE reached the CACHED prefix. USER/GROWTH/MEMORY/AGENTS
//         were mirrored into the per-turn (volatile, uncached) packet every
//         single turn: identity paid for as if it were relevance.
//   atoms rendered `- [kind] <full body>` uncapped
//       — corrections averaging 830 chars and reaching 2 KB, memories 470.
//         The story shipped with the rule, on every turn, whether or not the
//         turn needed the story.
//
// This suite pins the fix: identity in the stable prefix (byte-stable across
// turns AND surfaces), long atoms as lead + pointer, and — the part that makes
// truncation reach rather than loss — `context_expand` returning the full body
// for exactly the atoms the renderer cut.
@Suite("Fluid Context: persona in the stable prefix, lead + pointer in the packet")
struct FluidContextLeadAndStablePersonaTests {

    // MARK: - (1) Required persona documents live in the STABLE prefix

    @Test
    func requiredDocumentsRenderByteIdenticalAcrossTurnsAndSurfaces() throws {
        let chatTurnOne = try preparedTurn(surface: "chat")
        let chatTurnTwo = try preparedTurn(surface: "chat")
        let telegramTurn = try preparedTurn(surface: "telegram")

        let renders = [chatTurnOne, chatTurnTwo, telegramTurn].map { turn in
            SwiftNativeTurnEngine.renderSystemPromptSegments(
                compiledPersonaPrompt: turn.kernel.renderedPrompt,
                recalled: [],
                remPins: [],
                includeNaturalExpressionGuidance: false,
                requiredDocuments: SwiftNativeTurnEngine
                    .stablePrefixRequiredDocuments(turn)
            ).stable
        }

        // Byte-stable: two turns on one surface, and two different surfaces.
        // Anything turn- or surface-derived leaking into this string breaks the
        // provider prompt cache, which is the entire reason identity moved here.
        #expect(renders[0] == renders[1])
        #expect(renders[0] == renders[2])

        // And it actually carries the documents the kernel does NOT.
        for text in [Self.userDocumentText, Self.growthDocumentText] {
            #expect(renders[0].contains(text))
        }
        #expect(renders[0].contains(Self.soulDocumentText)) // via the kernel
    }

    @Test
    func kernelDocumentsAreNotRenderedTwiceIntoTheStableSegment() throws {
        let turn = try preparedTurn(surface: "chat")
        let extras = SwiftNativeTurnEngine.stablePrefixRequiredDocuments(turn)

        // SOUL is inside the compiled kernel already; re-appending it would
        // double the persona's most load-bearing document.
        #expect(!extras.contains { $0.id == RequiredPersonaDocumentKind.soul.id })
        #expect(extras.map(\.id) == [
            RequiredPersonaDocumentKind.user.id,
            RequiredPersonaDocumentKind.growth.id,
        ])
        // Canonical order, not dictionary order: USER precedes GROWTH.
        #expect(extras.map(\.canonicalOrder) == extras.map(\.canonicalOrder).sorted())
    }

    @Test
    func chatTurnRequestTellsTheSelectorTheStableSegmentCarriesThePersona() {
        // The flag is opt-in: a plain request keeps the pre-change behavior, so
        // harnesses, evals and direct context callers are untouched.
        let plain = ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "hello"
        )
        #expect(plain.stableSegmentCarriesRequiredDocuments == false)
        #expect(plain.packetAtomExpandThresholdChars == 0)
        #expect(plain.memoryAtomRowLimit == nil)

        let chatTurn = ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "hello",
            stableSegmentCarriesRequiredDocuments: true,
            packetAtomExpandThresholdChars:
                ContextBudgetPolicy.packetAtomExpandThresholdChars,
            memoryAtomRowLimit: ContextBudgetPolicy.wideRecallRowLimit
        )
        #expect(chatTurn.stableSegmentCarriesRequiredDocuments)
        #expect(chatTurn.packetAtomExpandThresholdChars == 400)
        #expect(chatTurn.memoryAtomRowLimit == 12)
    }

    @Test
    func surfaceRestrictedDocumentIsInChatStableAndAbsentFromTelegramStableAndPacket() throws {
        // Live data says every persona source currently permits all six
        // surfaces, so nothing leaks today. That is a fact about the DATA, not
        // a property of the code, and it is exactly the kind of fact that stops
        // being true the first time someone marks a document local-only. Moving
        // a document into the cached prefix must never be the thing that
        // carries it past a permission it would otherwise fail.
        let restricted = RequiredPersonaDocumentKind.growth.id

        let chatStable = try stableSegment(
            surface: "chat",
            chatOnlyDocumentIDs: [restricted]
        )
        let telegramStable = try stableSegment(
            surface: "telegram",
            chatOnlyDocumentIDs: [restricted]
        )

        // Chat permits it → present. Telegram does not → absent, while the
        // unrestricted documents still ship on BOTH surfaces (so this is a
        // permission gate, not the whole block collapsing).
        #expect(chatStable.contains(Self.growthDocumentText))
        #expect(!telegramStable.contains(Self.growthDocumentText))
        #expect(chatStable.contains(Self.userDocumentText))
        #expect(telegramStable.contains(Self.userDocumentText))

        // Byte-stability now holds PER SURFACE, and the surface-restricted
        // document is the only legitimate reason the two may differ.
        #expect(chatStable == (try stableSegment(
            surface: "chat",
            chatOnlyDocumentIDs: [restricted]
        )))
        #expect(chatStable != telegramStable)

        // The renderer's allow map, read directly. A source that ANSWERS "no"
        // is a policy outcome, not a fault: withheld, and NOT reported as
        // unproven.
        let telegramTurn = try preparedTurn(
            surface: "telegram",
            chatOnlyDocumentIDs: [restricted]
        )
        let telegramDocuments = SwiftNativeTurnEngine
            .stablePrefixPersonaDocuments(telegramTurn)
        #expect(!telegramDocuments.included.contains { $0.id == restricted })
        #expect(telegramDocuments.unprovenDocumentIDs.isEmpty)

        let chatTurn = try preparedTurn(surface: "chat", chatOnlyDocumentIDs: [restricted])
        let chatDocuments = SwiftNativeTurnEngine.stablePrefixPersonaDocuments(chatTurn)
        #expect(chatDocuments.included.contains { $0.id == restricted })
        #expect(chatDocuments.unprovenDocumentIDs.isEmpty)
    }

    @Test
    func documentWithoutProvenanceIsWithheldFromStableAndNamedInTheReceipt() throws {
        // The HIGH finding: a document whose provenance is missing — a mirror
        // built by an older path, a locator convention that drifted — used to
        // be read as "no denial observed" and shipped into the CACHED prefix.
        // A permission check must never fail open. Now it is withheld, and the
        // withholding is named so a wiring fault cannot be silent.
        let turn = try preparedTurn(surface: "chat", unprovenDocumentIDs: [
            RequiredPersonaDocumentKind.growth.id,
        ])
        let documents = SwiftNativeTurnEngine.stablePrefixPersonaDocuments(turn)

        #expect(documents.unprovenDocumentIDs == [RequiredPersonaDocumentKind.growth.id])
        #expect(!documents.included.contains { $0.id == RequiredPersonaDocumentKind.growth.id })
        // The proven document beside it is unaffected — this is a per-document
        // proof, not a whole-block collapse.
        #expect(documents.included.contains { $0.id == RequiredPersonaDocumentKind.user.id })

        let stable = SwiftNativeTurnEngine.renderSystemPromptSegments(
            compiledPersonaPrompt: turn.kernel.renderedPrompt,
            recalled: [],
            remPins: [],
            includeNaturalExpressionGuidance: false,
            requiredDocuments: documents.included
        ).stable
        #expect(!stable.contains(Self.growthDocumentText))
        #expect(stable.contains(Self.userDocumentText))
    }

    @Test
    func surfaceRestrictedDocumentStaysOutOfTheTelegramPacketToo() throws {
        // The other half of "absent from telegram": having been kept OUT of the
        // stable prefix, the document must not reappear in the packet either.
        // It stays under the packet's ordinary surface rules, which deny it.
        let atom = personaAtom(
            documentID: RequiredPersonaDocumentKind.growth.id,
            body: Self.growthDocumentText,
            permittedSurfaces: [.chat]
        )
        let generation = personaGeneration([atom])

        func packet(on surface: ContextSurface) throws -> ContextPacket {
            try ContextSelector().select(
                NeedSignal(
                    message: "how does approved drift work",
                    surface: surface,
                    origin: .localAuthenticated,
                    authorization: ContextSelectionAuthorization(
                        allowedOrigins: [.localAuthenticated],
                        allowedPrivacy: [.localPrivate],
                        allowedSourceIDs: Set(generation.sources.map(\.descriptor.id))
                    ),
                    availableGenerationID: 1,
                    characterBudget: 100_000,
                    now: Date(timeIntervalSince1970: 10_000),
                    cacheState: .hit
                ),
                from: generation
            )
        }

        #expect(try packet(on: .chat).selectedItems.contains {
            $0.pointer.atomID == atom.draft.id
        })
        let telegram = try packet(on: .telegram)
        #expect(!telegram.selectedItems.contains { $0.pointer.atomID == atom.draft.id })
        #expect(!telegram.expandablePointers.contains { $0.atomID == atom.draft.id })
        // Named by the receipt, so the reason is diagnosable from logs alone.
        let decision = try #require(telegram.receipt.eligibility.first {
            $0.atomID == atom.draft.id
        })
        #expect(!decision.eligible)
        #expect(decision.exclusionReason == .surfaceDenied)
    }

    // MARK: - (2) Lead + pointer for long atoms

    @Test
    func shortAtomRendersWhole() throws {
        let body = Self.filler(300)
        #expect(body.count == 300)
        let item = packetItem(id: "short", kind: .memory, text: body)

        let rendered = SwiftNativeTurnEngine.renderPacketAtom(
            item,
            thresholdChars: ContextBudgetPolicy.packetAtomExpandThresholdChars
        )

        #expect(rendered == "- [memory] \(body)")
        #expect(!rendered.contains("context_expand"))
    }

    @Test
    func longCorrectionRendersAsSummaryLeadPlusPointer() throws {
        let body = Self.longCorrectionBody
        #expect(body.count == 1_500)
        let item = packetItem(
            id: "correction",
            kind: .correction,
            text: body,
            summary: "Never run tests or evals unless User asks."
        )

        let rendered = SwiftNativeTurnEngine.renderPacketAtom(
            item,
            thresholdChars: ContextBudgetPolicy.packetAtomExpandThresholdChars
        )

        // The RULE, not the story: the compiler's own summary leads.
        #expect(rendered.hasPrefix("- [correction] Never run tests or evals unless User asks. …"))
        #expect(rendered.contains("[context_expand atom:correction — "))
        #expect(rendered.hasSuffix("more chars]"))
        #expect(rendered.count < body.count)
        // And the story is genuinely gone from the packet line.
        #expect(!rendered.contains(String(body.suffix(80))))
    }

    @Test
    func longAtomWithoutSummaryLeadsWithItsOwnFirstSentences() throws {
        let body = "Prefer deleting code to adding it. "
            + "The smallest change that fixes the named problem wins. "
            + Self.filler(1_400)
        let item = packetItem(id: "instruction", kind: .instruction, text: body)

        let lead = SwiftNativeTurnEngine.packetAtomLead(item)

        #expect(lead.count <= ContextBudgetPolicy.packetAtomLeadChars)
        // Cut at a sentence boundary, never mid-sentence: a half-sentence rule
        // reads as a whole one.
        #expect(lead.hasSuffix("."))
        #expect(lead.hasPrefix("Prefer deleting code to adding it."))
    }

    @Test
    func aThresholdOfZeroRendersEveryAtomExactlyAsBefore() throws {
        let item = packetItem(id: "long", kind: .memory, text: Self.filler(2_000))
        let rendered = SwiftNativeTurnEngine.renderPacketAtom(item, thresholdChars: 0)
        #expect(rendered == "- [memory] \(item.text)")
    }

    @Test
    func truncatedAtomIsPublishedAsAnExpandablePointerAndExpandsToTheFullBody() throws {
        let body = Self.longCorrectionBody
        let correction = atom(
            "correction",
            source: "memory",
            kind: .correction,
            body: body,
            summary: "Never run tests or evals unless User asks.",
            policy: .adaptive
        )
        let generation = generation([correction])
        let need = need(
            "What is the rule about running tests?",
            generation: generation,
            thresholdChars: ContextBudgetPolicy.packetAtomExpandThresholdChars
        )

        let packet = try ContextSelector().select(need, from: generation)
        let selected = try #require(packet.selectedItems.first {
            $0.pointer.atomID == correction.draft.id
        })

        // The summary column reached the packet item — no second store read is
        // needed to lead with the rule.
        #expect(selected.summary == "Never run tests or evals unless User asks.")

        // The selector published the pointer for the atom the renderer will cut.
        let pointer = try #require(packet.expandablePointers.first {
            $0.atomID == correction.draft.id
        })

        // ...and `context_expand` returns the FULL body, despite the atom being
        // `.adaptive` rather than `.onDemand`. Before this change the expander
        // refused it with `atomNotExpandable`, which would have made the lead a
        // silent loss instead of a pointer.
        let expansion = try ContextExpander().expand(
            pointer,
            for: need,
            from: generation,
            offeredTruncationAtomIDs: Set(packet.expandablePointers.map(\.atomID))
        )
        #expect(expansion.text == body)
        #expect(!expansion.truncated)

        // ...and ONLY because it was offered. The same pointer, same need, same
        // generation, without the offer is refused: "this atom is long" is not
        // authorization, "the model was shown a pointer to it" is.
        #expect(throws: ContextExpansionError.atomNotExpandable(policy: .adaptive)) {
            _ = try ContextExpander().expand(pointer, for: need, from: generation)
        }
    }

    @Test
    func aLongAtomNeverOfferedThisTurnIsRefusedEvenThoughItIsLongEnough() throws {
        // The MEDIUM finding. A hand-built pointer to an atom that was never
        // selected, never rendered and never offered must not expand just
        // because it happens to exceed the truncation threshold — otherwise the
        // packet's bound buys nothing and `context_expand` becomes a general
        // read of the generation.
        let offered = atom(
            "offered",
            source: "memory",
            kind: .correction,
            body: Self.longCorrectionBody,
            summary: "The offered rule.",
            policy: .adaptive
        )
        let neverSelected = atom(
            "never-selected",
            source: "elsewhere",
            kind: .memory,
            body: Self.filler(1_200),
            policy: .adaptive
        )
        let generation = generation([offered, neverSelected])
        let need = need(
            "What is the rule about running tests?",
            generation: generation,
            thresholdChars: ContextBudgetPolicy.packetAtomExpandThresholdChars
        )
        let packet = try ContextSelector().select(need, from: generation)
        let offeredIDs = Set(packet.expandablePointers.map(\.atomID))

        let smuggled = ContextAtomPointer(atom: neverSelected, generationID: 1)
        #expect(!offeredIDs.contains(neverSelected.draft.id))
        #expect(throws: ContextExpansionError.atomNotExpandable(policy: .adaptive)) {
            _ = try ContextExpander().expand(
                smuggled,
                for: need,
                from: generation,
                offeredTruncationAtomIDs: offeredIDs
            )
        }
    }

    @Test
    func aShortAtomIsNeverPublishedAsATruncationPointer() throws {
        let short = atom(
            "short",
            source: "memory",
            kind: .memory,
            body: Self.filler(300),
            policy: .adaptive
        )
        let generation = generation([short])
        let need = need(
            "\(Self.fillerWord) rule",
            generation: generation,
            thresholdChars: ContextBudgetPolicy.packetAtomExpandThresholdChars
        )

        let packet = try ContextSelector().select(need, from: generation)
        #expect(packet.selectedItems.contains { $0.pointer.atomID == short.draft.id })
        #expect(!packet.expandablePointers.contains { $0.atomID == short.draft.id })

        // An atom nobody truncated must stay unexpandable — truncation is the
        // ONLY thing that widens the expander's door.
        let pointer = ContextAtomPointer(atom: short, generationID: 1)
        #expect(throws: ContextExpansionError.atomNotExpandable(policy: .adaptive)) {
            _ = try ContextExpander().expand(pointer, for: need, from: generation)
        }
    }

    // MARK: - (3) One owner for the memory row count

    @Test
    func memoryRowLimitBoundsMemoryAtomsAndDoesNotCountCorrections() throws {
        let memories = (0..<20).map { index in
            atom(
                "memory-\(index)",
                source: "memory",
                kind: .memory,
                body: "User prefers concise orchard watering summaries number \(index)."
            )
        }
        let corrections = (0..<3).map { index in
            atom(
                "correction-\(index)",
                source: "correction",
                kind: .correction,
                body: "Orchard watering summaries stay concise, rule \(index).",
                policy: .always
            )
        }
        let generation = generation(memories + corrections)
        // The row LIMIT is what this pin measures, so the short-message row
        // cap (2026-09-02) is opted out of: a 3-token message would otherwise
        // cap the unbounded lane at 6 rows and hide the 20-row symptom.
        let configuration = ContextSelectionConfiguration(
            maximumDynamicAtoms: 40,
            maximumAtomsPerSource: 40,
            // The shipped per-kind cap (.memory: 8) would bound the unbounded
            // arm before the row limit could; widen it so this pin measures
            // the ONE owner it names.
            maximumAtomsPerKindOverrides: [.memory: 40, .relationship: 4],
            shortMessageMemoryRowCap: 40
        )

        let unbounded = try ContextSelector(configuration: configuration).select(
            need(
                "orchard watering summaries",
                generation: generation,
                budget: 100_000
            ),
            from: generation
        )
        let bounded = try ContextSelector(configuration: configuration).select(
            need(
                "orchard watering summaries",
                generation: generation,
                budget: 100_000,
                memoryAtomRowLimit: 12
            ),
            from: generation
        )

        func count(_ packet: ContextPacket, _ kind: ContextAtomKind) -> Int {
            packet.selectedItems.filter { $0.pointer.kind == kind }.count
        }

        // The measured symptom: 20 memory rows against a 12-row limit that
        // bounded only the (empty) legacy recall lane.
        #expect(count(unbounded, .memory) > 12)
        #expect(count(bounded, .memory) <= 12)
        // Corrections are authority, not recall breadth — the limit must not
        // spend their slots or take them away.
        #expect(count(bounded, .correction) == count(unbounded, .correction))
    }

    @Test
    func anOverlongSummaryIsBoundedByTheSameLeadCap() throws {
        // The MEDIUM finding: `deterministicSummary` has its own (byte-based)
        // compiler cap, so a summary can run past `packetAtomLeadChars`. A lead
        // that quietly ran long made `contextFlow.leadChars` under-report the
        // prompt it claims to measure.
        let summary = "Claude never runs tests or evals on her own initiative. "
            + Self.filler(600)
        #expect(summary.count > ContextBudgetPolicy.packetAtomLeadChars)
        let item = packetItem(
            id: "verbose",
            kind: .correction,
            text: Self.longCorrectionBody,
            summary: summary
        )

        let lead = SwiftNativeTurnEngine.packetAtomLead(item)
        #expect(lead.count <= ContextBudgetPolicy.packetAtomLeadChars)
        #expect(lead.hasPrefix("Claude never runs tests or evals on her own initiative."))

        let rendered = SwiftNativeTurnEngine.renderPacketAtom(
            item,
            thresholdChars: ContextBudgetPolicy.packetAtomExpandThresholdChars
        )
        // `leadChars` is the number the trace publishes; it must be the number
        // actually rendered.
        #expect(rendered.contains(lead))
        #expect(rendered.contains("more chars]"))
    }

    @Test
    func aSentenceBoundaryInsideAnInlineCodeSpanIsNotUsed() throws {
        // Cutting between backticks leaves the span unclosed and the remainder
        // of the packet reads as code.
        let text = "Run the migration. Use `swift build. --target Context` when checking. "
            + Self.filler(1_000)

        let lead = SwiftNativeTurnEngine.firstSentences(
            of: text,
            upTo: ContextBudgetPolicy.packetAtomLeadChars
        )

        // The `.` inside `swift build.` is rejected, so the cut lands on the
        // next boundary OUTSIDE the span — the span survives whole.
        #expect(lead == "Run the migration. Use `swift build. --target Context` when checking.")
        #expect(lead.filter { $0 == "`" }.count % 2 == 0)

        // And when the in-span terminator is the ONLY candidate, there is no
        // later boundary to fall to, so it drops to whole words rather than
        // cutting the span open.
        let spanOnly = "Use `swift build. --target Context` " + Self.filler(1_000)
        let spanOnlyLead = SwiftNativeTurnEngine.firstSentences(
            of: spanOnly,
            upTo: ContextBudgetPolicy.packetAtomLeadChars
        )
        // The cut we are preventing is one that ENDS inside the span. Carrying
        // the whole span through is correct; ending at `swift build.` is not.
        #expect(!spanOnlyLead.hasSuffix("`swift build."))
        #expect(spanOnlyLead.filter { $0 == "`" }.count % 2 == 0)
        #expect(spanOnlyLead.count <= ContextBudgetPolicy.packetAtomLeadChars)
    }

    @Test
    func aSentenceBoundaryInsideAUrlIsNotUsed() throws {
        // `https://ex.com/a. b` has a terminator followed by whitespace. Cutting
        // there hands the model a link that resolves somewhere else, or nowhere.
        let text = "See https://example.com/guide/v2. for the rule. " + Self.filler(1_000)

        let lead = SwiftNativeTurnEngine.firstSentences(
            of: text,
            upTo: ContextBudgetPolicy.packetAtomLeadChars
        )

        #expect(lead == "See https://example.com/guide/v2. for the rule.")
        #expect(!lead.hasSuffix("/v2."))
    }

    @Test
    func anUnbrokenTokenYieldsThePointerAloneRatherThanAMangledPrefix() throws {
        // No whitespace, no safe sentence end: there is nothing honest to lead
        // with, so the atom renders as its pointer. A truncated URL would be
        // worse than no lead — it looks like a link and is not one.
        let text = "https://example.com/" + String(repeating: "a", count: 1_200)
        let item = packetItem(id: "blob", kind: .evidence, text: text)

        #expect(SwiftNativeTurnEngine.packetAtomLead(item).isEmpty)

        let rendered = SwiftNativeTurnEngine.renderPacketAtom(
            item,
            thresholdChars: ContextBudgetPolicy.packetAtomExpandThresholdChars
        )
        #expect(rendered == "- [evidence] [context_expand atom:blob — \(text.count) chars]")
        #expect(!rendered.contains("…"))
        #expect(!rendered.contains("https://example.com/aaa"))
    }

    // MARK: - Trace receipts

    @Test
    func truncationCountsAreHonestAboutReachability() throws {
        let body = Self.longCorrectionBody
        let correction = atom(
            "correction",
            source: "memory",
            kind: .correction,
            body: body,
            summary: "Never run tests or evals unless User asks.",
            policy: .adaptive
        )
        let generation = generation([correction])
        let need = need(
            "What is the rule about running tests?",
            generation: generation,
            thresholdChars: ContextBudgetPolicy.packetAtomExpandThresholdChars
        )
        let packet = try ContextSelector().select(need, from: generation)
        let prepared = try preparedTurn(surface: "chat", packet: packet, need: need)

        let counts = SwiftNativeTurnEngine.packetTruncationCounts(prepared)
        #expect(counts.truncatedAtoms == 1)
        #expect(counts.leadChars == "Never run tests or evals unless User asks.".count)
        // The invariant that matters: every cut body is still reachable.
        #expect(counts.expandableAfterTruncation == counts.truncatedAtoms)
    }

    // MARK: - Fixtures

    private static let soulDocumentText = "I am Agent. I keep my own counsel."
    private static let userDocumentText = "User has ADHD: answer first, detail after."
    private static let growthDocumentText = "Approved drift is curated, never inferred."
    private static let fillerWord = "orchard"

    private static func filler(_ characters: Int) -> String {
        String(String(repeating: "\(fillerWord) ", count: characters).prefix(characters))
    }

    private static let longCorrectionBody: String = {
        let opening = "Claude never runs tests or evals on her own initiative. "
        return opening + filler(1_500 - opening.count)
    }()

    private func preparedTurn(
        surface: String,
        packet: ContextPacket? = nil,
        need needSignal: NeedSignal? = nil,
        chatOnlyDocumentIDs: Set<RequiredDocumentID> = [],
        unprovenDocumentIDs: Set<RequiredDocumentID> = []
    ) throws -> ContextPreparedTurn {
        let personaID = ContextPersonaID(rawValue: "canonical")
        // Provenance rides the document, the way NativeContextFlowRuntime
        // populates it. `unprovenDocumentIDs` reproduces a mirror built without
        // it — the fail-open case the allow map exists to close.
        func provenance(
            _ kind: RequiredPersonaDocumentKind
        ) -> (ContextSourceID?, Set<ContextSurface>?) {
            guard !unprovenDocumentIDs.contains(kind.id) else { return (nil, nil) }
            let source = personaSource(
                documentID: kind.id,
                permittedSurfaces: chatOnlyDocumentIDs.contains(kind.id)
                    ? [.chat]
                    : [.chat, .telegram]
            )
            return (source.descriptor.id, source.descriptor.permittedSurfaces)
        }
        let soulProvenance = provenance(.soul)
        let userProvenance = provenance(.user)
        let growthProvenance = provenance(.growth)
        let soul = try RequiredDocument(
            kind: .soul,
            sourceHash: "soul-hash",
            text: Self.soulDocumentText,
            tokenCount: 8,
            sourceID: soulProvenance.0,
            permittedSurfaces: soulProvenance.1
        )
        let user = try RequiredDocument(
            kind: .user,
            sourceHash: "user-hash",
            text: Self.userDocumentText,
            tokenCount: 9,
            sourceID: userProvenance.0,
            permittedSurfaces: userProvenance.1
        )
        let growth = try RequiredDocument(
            kind: .growth,
            sourceHash: "growth-hash",
            text: Self.growthDocumentText,
            tokenCount: 7,
            sourceID: growthProvenance.0,
            permittedSurfaces: growthProvenance.1
        )
        let fingerprint = "persona-fingerprint"
        // The live `.active` kernel: SOUL only (plus VOICE and surface guidance
        // in production). Everything else is what this change moves into the
        // stable prefix.
        let kernels = try ["chat", "telegram"].map { variant in
            try StablePromptKernel(
                key: StablePromptKernelKey(
                    personaID: personaID,
                    surfaceVariant: ContextSurfaceVariant(rawValue: variant),
                    sourceFingerprint: fingerprint
                ),
                renderedPrompt: "# SOUL\n\(Self.soulDocumentText)",
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
        let kernel = try #require(
            mirror.kernel(for: ContextSurfaceVariant(rawValue: surface))
        )
        let snapshot = try ContextGenerationSnapshot(
            generationID: 1,
            sourceFingerprint: "generation-fingerprint",
            requiredDocumentMirrors: [mirror]
        )
        let arena = try ContextArena(budget: .mib32)
        _ = arena.publish(snapshot)
        let lease = try arena.acquireSnapshot()
        // Register a real persona source per required document, the way
        // NativeContextFlowRuntime does — owner, `persona/<id>/<DOC>.md`
        // locator, and `permittedSurfaces`. The surface predicate is read from
        // HERE, so a fixture with no sources proves nothing about it.
        let personaSources = [soul, user, growth].map { document in
            personaSource(
                documentID: document.id,
                permittedSurfaces: chatOnlyDocumentIDs.contains(document.id)
                    ? [.chat]
                    : [.chat, .telegram]
            )
        }
        let emptyGeneration = ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: .distantPast,
                reason: "test",
                sourceFingerprint: snapshot.sourceFingerprint,
                atomCount: 0,
                sourceCount: personaSources.count
            ),
            sources: personaSources,
            atoms: [],
            relationships: []
        )
        let resolvedNeed = needSignal ?? NeedSignal(
            message: "hello",
            surface: ContextSurface(rawValue: surface),
            origin: .localAuthenticated,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: [.localAuthenticated],
                allowedPrivacy: [.localPrivate],
                allowedSourceIDs: []
            ),
            availableGenerationID: 1
        )
        return ContextPreparedTurn(
            mode: .active,
            kernel: kernel,
            mirror: mirror,
            packet: packet ?? Self.emptyPacket(fingerprint: snapshot.sourceFingerprint),
            lease: lease,
            generation: emptyGeneration,
            need: resolvedNeed
        )
    }

    private func personaSource(
        documentID: RequiredDocumentID,
        permittedSurfaces: Set<ContextSurface>
    ) -> ContextStoredSource {
        let locator = ContextPersonaSourceNaming
            .locatorPrefix(for: ContextPersonaID(rawValue: "canonical"))
            + documentID.rawValue
        return ContextStoredSource(
            descriptor: ContextSourceDescriptor(
                id: ContextStableID.source(
                    owner: ContextPersonaSourceNaming.owner,
                    locator: locator
                ),
                owner: ContextPersonaSourceNaming.owner,
                kind: .persona,
                canonicalLocator: locator,
                authority: .identity,
                privacy: .localPrivate,
                permittedSurfaces: permittedSurfaces,
                injectionPolicy: .always
            ),
            sourceHash: "hash:\(documentID.rawValue)",
            health: .healthy,
            lastError: nil,
            validFromGeneration: 1,
            validToGeneration: nil
        )
    }

    private static func emptyPacket(fingerprint: String) -> ContextPacket {
        let budget = ContextBudgetUsage(
            characterLimit: 6_000,
            usedCharacters: 0,
            mandatoryCharacters: 0
        )
        return ContextPacket(
            generationID: 1,
            sourceFingerprint: fingerprint,
            selectedItems: [],
            expandablePointers: [],
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
                selectedAtomIDs: [],
                pointerAtomIDs: [],
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

    private func packetItem(
        id: String,
        kind: ContextAtomKind,
        text: String,
        summary: String? = nil
    ) -> ContextPacketItem {
        ContextPacketItem(
            pointer: ContextAtomPointer(
                atom: atom(id, source: "fixture", kind: kind, body: text, summary: summary),
                generationID: 1
            ),
            text: text,
            representation: .body,
            mandatory: false,
            summary: summary
        )
    }

    private func need(
        _ message: String,
        generation: ContextStoredGeneration,
        budget: Int = 100_000,
        thresholdChars: Int = 0,
        memoryAtomRowLimit: Int? = nil
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
            characterBudget: budget,
            packetAtomExpandThresholdChars: thresholdChars,
            memoryAtomRowLimit: memoryAtomRowLimit,
            now: Date(timeIntervalSince1970: 10_000),
            cacheState: .hit
        )
    }

    private func atom(
        _ id: String,
        source: String,
        kind: ContextAtomKind,
        body: String,
        summary: String? = nil,
        policy: ContextInjectionPolicy = .adaptive
    ) -> ContextStoredAtom {
        let sourceID = ContextSourceID(rawValue: "source:\(source)")
        let atomID = ContextAtomID(rawValue: "atom:\(id)")
        return ContextStoredAtom(
            versionKey: "\(atomID.rawValue)@1",
            draft: ContextAtomDraft(
                id: atomID,
                sourceID: sourceID,
                kind: kind,
                headingPath: [id],
                sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
                sourceHash: "hash:\(source)",
                body: body,
                deterministicSummary: summary,
                authority: kind == .correction ? .explicitCorrection : .approved,
                confidence: 0.9,
                freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 9_000)),
                privacy: .localPrivate,
                permittedSurfaces: [.chat, .telegram],
                injectionPolicy: policy,
                contentRole: kind == .memory ? .memory : .instruction
            ),
            validFromGeneration: 1,
            validToGeneration: nil
        )
    }

    private func stableSegment(
        surface: String,
        chatOnlyDocumentIDs: Set<RequiredDocumentID> = [],
        unprovenDocumentIDs: Set<RequiredDocumentID> = []
    ) throws -> String {
        let turn = try preparedTurn(
            surface: surface,
            chatOnlyDocumentIDs: chatOnlyDocumentIDs,
            unprovenDocumentIDs: unprovenDocumentIDs
        )
        return SwiftNativeTurnEngine.renderSystemPromptSegments(
            compiledPersonaPrompt: turn.kernel.renderedPrompt,
            recalled: [],
            remPins: [],
            includeNaturalExpressionGuidance: false,
            requiredDocuments: SwiftNativeTurnEngine.stablePrefixRequiredDocuments(turn)
        ).stable
    }

    private func personaAtom(
        documentID: RequiredDocumentID,
        body: String,
        permittedSurfaces: Set<ContextSurface>
    ) -> ContextStoredAtom {
        let locator = ContextPersonaSourceNaming
            .locatorPrefix(for: ContextPersonaID(rawValue: "canonical"))
            + documentID.rawValue
        let sourceID = ContextStableID.source(
            owner: ContextPersonaSourceNaming.owner,
            locator: locator
        )
        return ContextStoredAtom(
            versionKey: "\(documentID.rawValue)@1",
            draft: ContextAtomDraft(
                id: ContextAtomID(rawValue: "atom:\(documentID.rawValue)"),
                sourceID: sourceID,
                kind: .identity,
                headingPath: [documentID.rawValue],
                sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
                sourceHash: "hash:\(documentID.rawValue)",
                body: body,
                authority: .identity,
                confidence: 1,
                freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 9_000)),
                privacy: .localPrivate,
                permittedSurfaces: permittedSurfaces,
                injectionPolicy: .always,
                contentRole: .identity
            ),
            validFromGeneration: 1,
            validToGeneration: nil
        )
    }

    private func personaGeneration(_ atoms: [ContextStoredAtom]) -> ContextStoredGeneration {
        var seen = Set<ContextSourceID>()
        let sources = atoms.compactMap { atom -> ContextStoredSource? in
            guard seen.insert(atom.draft.sourceID).inserted else { return nil }
            let documentID = RequiredDocumentID(
                rawValue: atom.draft.headingPath.first ?? "DOC.md"
            )
            return personaSource(
                documentID: documentID,
                permittedSurfaces: atom.draft.permittedSurfaces
            )
        }
        return ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: Date(timeIntervalSince1970: 8_000),
                reason: "surface-permission fixture",
                sourceFingerprint: "fixture-fingerprint",
                atomCount: atoms.count,
                sourceCount: sources.count
            ),
            sources: sources,
            atoms: atoms,
            relationships: []
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
                reason: "lead-and-pointer fixture",
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

// Atomization of the GENERATED USER.md body — one atom per bullet fact.
//
// Why this suite exists (2026-07-25). In `ContextFlowMode.active` the stable
// prompt kernel renders SOUL + VOICE + surface only, so USER.md reaches Agent
// through exactly one lane: context-packet atoms. The generated fact list is
// one contiguous Markdown list, so it compiled to ONE ~15 KB atom against a
// 6 KB dynamic packet budget — `plannedItems` could never admit its body and
// fell back to the 320-byte deterministic summary, i.e. roughly ONE of the
// forty-odd facts, chosen by where truncation landed rather than by relevance.
// Splitting per bullet lets individual facts compete for packet slots.
//
// Live-shaped values throughout: no assertion compares a literal against the
// same literal on both sides — expected text is written out independently of
// the fixture that produces it.

import Foundation
import NativeAgentCore
import Testing
@testable import Context

@Suite("Generated USER.md fact atomization")
struct GeneratedUserFactAtomizationTests {
    private let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)

    // A live-shaped generated USER.md: preamble-free, heading inside the
    // markers, forty-odd `- ` bullets of prose. Trimmed to five facts of
    // realistic length so the fixture stays readable; the real-document
    // inventory is exercised by `realPersonaUserDocumentSplitsPerFact`.
    private var generatedUserDocument: String {
        """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - User's sleep schedule (canonical): typically sleeps ~19:00-03:00 Central, an extreme early-bird pattern, NOT nocturnal.
        - User drives a 2019 Tacoma and does the brake work himself in the driveway.
        - 2026-07-19 User moved the espresso grinder to the shelf above the sink.
        - User's daughter Marisol plays clarinet in the middle-school wind ensemble.
        - User prefers dark roast and refuses anything with hazelnut in it.
        <!-- USER_MD_AUTOGEN_END -->
        """
    }

    // MARK: - Atomization

    @Test
    func generatedBodySplitsIntoOneAtomPerBulletWhileMarkersStayWhole() async throws {
        let compiler = ContextMarkdownCompiler(embeddingProvider: TokenHashEmbedder())
        let compiled = try await compiler.compile(
            source: generatedUserDocument,
            descriptor: userDescriptor(),
            updatedAt: updatedAt
        )

        let facts = compiled.atoms.filter { $0.body.hasPrefix("- ") }
        #expect(facts.count == 5)
        // Every fact is its own atom, and each one is small enough to enter a
        // packet as a BODY rather than as a truncated summary.
        #expect(facts.allSatisfy { $0.body.count < 200 })
        #expect(facts.contains { $0.body.contains("clarinet in the middle-school wind ensemble") })
        #expect(facts.contains { $0.body.contains("refuses anything with hazelnut") })
        // No atom carries two facts.
        #expect(facts.allSatisfy { !$0.body.contains("\n") })
        // The marker lines remain their own paragraph atoms — the autogen
        // region boundary is data, not a fact.
        #expect(compiled.atoms.count == facts.count + 2)
    }

    @Test
    func nonGeneratedUserProseKeepsWholeBlockAtoms() async throws {
        let compiler = ContextMarkdownCompiler(embeddingProvider: TokenHashEmbedder())
        // Same document kind, no autogen markers: a hand-written USER.md.
        let manual = """
        # About User

        - ships Swift on macOS
        - runs the release pipeline himself
        - reviews every provider diff before merge
        """
        let compiled = try await compiler.compile(
            source: manual,
            descriptor: userDescriptor(),
            updatedAt: updatedAt
        )

        #expect(compiled.atoms.count == 1)
        let body = try #require(compiled.atoms.first?.body)
        #expect(body.contains("ships Swift on macOS"))
        #expect(body.contains("reviews every provider diff before merge"))
    }

    @Test
    func indentedContinuationsStayWithTheirParentFact() async throws {
        let compiler = ContextMarkdownCompiler(embeddingProvider: TokenHashEmbedder())
        let document = """
        <!-- USER_MD_AUTOGEN_START -->
        - User keeps three guitars in the study.
          - the Telecaster is the one he actually plays
          continued on a wrapped line
        - User's wifi router lives on the top shelf of the hall closet.
        <!-- USER_MD_AUTOGEN_END -->
        """
        let compiled = try await compiler.compile(
            source: document,
            descriptor: userDescriptor(),
            updatedAt: updatedAt
        )

        let facts = compiled.atoms.filter { $0.body.hasPrefix("- ") }
        #expect(facts.count == 2)
        let guitars = try #require(facts.first { $0.body.contains("three guitars") })
        #expect(guitars.body.contains("the Telecaster is the one he actually plays"))
        #expect(guitars.body.contains("continued on a wrapped line"))
        #expect(!guitars.body.contains("hall closet"))
    }

    // MARK: - Changed-only embedding contract

    @Test
    func editingOneFactReembedsOnlyThatFactAndKeepsEveryOtherAtomID() async throws {
        let provider = CountingEmbedder()
        let compiler = ContextMarkdownCompiler(embeddingProvider: provider)
        let first = try await compiler.compile(
            source: generatedUserDocument,
            descriptor: userDescriptor(),
            updatedAt: updatedAt
        )
        #expect(await provider.embeddedTexts().count == first.atoms.count)
        await provider.reset()

        let edited = generatedUserDocument.replacingOccurrences(
            of: "refuses anything with hazelnut in it",
            with: "refuses anything with hazelnut or vanilla syrup in it"
        )
        let second = try await compiler.compile(
            source: edited,
            descriptor: userDescriptor(),
            previous: first,
            updatedAt: updatedAt.addingTimeInterval(3_600)
        )

        // Exactly one atom was re-embedded: the edited fact.
        let reembedded = await provider.embeddedTexts()
        #expect(reembedded.count == 1)
        #expect(reembedded.first?.contains("vanilla syrup") == true)

        // Every untouched fact kept its atom ID, so accumulated activation and
        // usefulness survive the regeneration.
        let unchangedBefore = first.atoms.filter { !$0.body.contains("hazelnut") }
        let unchangedAfter = second.atoms.filter { !$0.body.contains("hazelnut") }
        // Guard the guard: in a one-blob world there is nothing to preserve,
        // so "IDs are stable" would be vacuously true.
        #expect(unchangedBefore.count >= 4)
        #expect(unchangedBefore.count == unchangedAfter.count)
        #expect(Set(unchangedBefore.map(\.id)) == Set(unchangedAfter.map(\.id)))
    }

    @Test
    func restampingAFactKeepsItsAtomIDButStillRefreshesTheEmbedding() async throws {
        let provider = CountingEmbedder()
        let compiler = ContextMarkdownCompiler(embeddingProvider: provider)
        let first = try await compiler.compile(
            source: generatedUserDocument,
            descriptor: userDescriptor(),
            updatedAt: updatedAt
        )
        await provider.reset()

        // MemoryV2 re-emits the same fact under a newer leading stamp. The
        // fact did not change; only the machine chronology in front of it did.
        let restamped = generatedUserDocument.replacingOccurrences(
            of: "- 2026-07-19 User moved the espresso grinder",
            with: "- 2026-08-04 User moved the espresso grinder"
        )
        let second = try await compiler.compile(
            source: restamped,
            descriptor: userDescriptor(),
            previous: first,
            updatedAt: updatedAt.addingTimeInterval(7_200)
        )

        let before = try #require(first.atoms.first { $0.body.contains("espresso grinder") })
        let after = try #require(second.atoms.first { $0.body.contains("espresso grinder") })
        // Same fact, same atom. Identity anchors on the FULL
        // MemoryDisplayText.Key (core AND stamp) — a bare-core anchor merged
        // date-critical siblings into one ID (caught during development). A
        // restamped bullet keeps its atom ID via match()'s fuzzy path, which is
        // what this asserts — matching, not digest equality.
        #expect(before.id == after.id)
        #expect(before.body != after.body)
        // The body genuinely changed, so the vector is recomputed, not reused.
        let reembedded = await provider.embeddedTexts()
        #expect(reembedded.count == 1)
        #expect(reembedded.first?.contains("2026-08-04") == true)
    }

    @Test
    func siblingFactsThatDifferOnlyByDateNeverShareAnAtomID() async throws {
        let compiler = ContextMarkdownCompiler(embeddingProvider: TokenHashEmbedder())
        // Two date-critical rows with an identical core — the shape
        // `MemoryDisplayText.Key` exists to keep apart.
        // Newest first, which is how the generator orders a dated projection.
        let before = """
        <!-- USER_MD_AUTOGEN_START -->
        - 2026-08-01 09:00 Dentist appointment downtown.
        - 2026-07-01 09:00 Dentist appointment downtown.
        - User keeps the good chef's knife in the drawer left of the stove.
        <!-- USER_MD_AUTOGEN_END -->
        """
        let first = try await compiler.compile(
            source: before,
            descriptor: userDescriptor(),
            updatedAt: updatedAt
        )
        #expect(Set(first.atoms.map(\.id)).count == first.atoms.count)

        // A new visit is booked and sorts to the TOP. Both existing bullets
        // match their prior atoms and keep IDs minted at ordinals 0 and 1;
        // the new bullet is unmatched and mints at the position it now
        // occupies — ordinal 0, the ID the August atom already holds. The
        // ordinal is positional, so a reorder is all it takes.
        let after = """
        <!-- USER_MD_AUTOGEN_START -->
        - 2026-10-01 09:00 Dentist appointment downtown.
        - 2026-08-01 09:00 Dentist appointment downtown.
        - 2026-07-01 09:00 Dentist appointment downtown.
        - User keeps the good chef's knife in the drawer left of the stove.
        <!-- USER_MD_AUTOGEN_END -->
        """
        let second = try await compiler.compile(
            source: after,
            descriptor: userDescriptor(),
            previous: first,
            updatedAt: updatedAt.addingTimeInterval(2_592_000)
        )

        #expect(second.atoms.count == first.atoms.count + 1)
        // The decisive assertion: no two atoms in one generation share an ID.
        #expect(Set(second.atoms.map(\.id)).count == second.atoms.count)
        let august = try #require(second.atoms.first { $0.body.contains("2026-08-01") })
        let priorAugust = try #require(first.atoms.first { $0.body.contains("2026-08-01") })
        #expect(august.id == priorAugust.id)
    }

    // MARK: - Selection, end to end through the real selector

    @Test
    func aQueryAboutOneUserFactSelectsThatFactsAtom() async throws {
        let embedder = TokenHashEmbedder()
        let compiler = ContextMarkdownCompiler(embeddingProvider: embedder)
        let compiled = try await compiler.compile(
            source: generatedUserDocument,
            descriptor: userDescriptor(),
            updatedAt: updatedAt
        )
        let generation = storedGeneration(compiled)

        // A question that names none of the fact's own distinctive words
        // verbatim beyond the instrument itself.
        let question = "Which instrument does Marisol play at school?"
        let queryVector = try await embedder.embed([question])[0]
        let need = NeedSignal(
            message: question,
            surface: .chat,
            origin: .localAuthenticated,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: [.localAuthenticated],
                allowedPrivacy: [.localPrivate, .publicSafe],
                allowedSourceIDs: Set(generation.sources.map(\.descriptor.id))
            ),
            queryEmbedding: queryVector,
            queryEmbeddingModelFingerprint: embedder.modelFingerprint,
            availableGenerationID: generation.generation.id,
            characterBudget: 6_000,
            now: updatedAt
        )

        let packet = try ContextSelector().select(need, from: generation)
        let selected = packet.selectedItems.map(\.text)

        #expect(selected.contains { $0.contains("clarinet") })
        // It entered as a full body, not as a truncated summary.
        let clarinet = try #require(packet.selectedItems.first { $0.text.contains("clarinet") })
        #expect(clarinet.representation == .body)
        // And the packet is not flooded: the per-source quota keeps USER.md to
        // its two best facts, so forty-odd small atoms cannot crowd out the
        // rest of the packet.
        #expect(packet.selectedItems.count <= 2)
        #expect(!selected.contains { $0.contains("hazelnut") })
    }

    // MARK: - Real persona document inventory

    @Test
    func realPersonaUserDocumentSplitsPerFact() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ContextTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NativeAgentCore
            .deletingLastPathComponent() // Modules
            .appendingPathComponent("persona/USER.md")
        guard let data = try? Data(contentsOf: url) else { return }
        let text = try #require(String(data: data, encoding: .utf8))
        let bulletCount = text.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
        guard bulletCount > 1 else { return }

        let compiler = ContextMarkdownCompiler(embeddingProvider: TokenHashEmbedder())
        let compiled = try await compiler.compile(
            sourceData: data,
            descriptor: userDescriptor(),
            updatedAt: updatedAt
        )

        let facts = compiled.atoms.filter { $0.body.hasPrefix("- ") }
        #expect(facts.count == bulletCount)
        // The decisive property: no atom exceeds the dynamic packet budget any
        // more, so a fact can enter as a body instead of being represented by
        // a truncated whole-document summary.
        #expect(compiled.atoms.allSatisfy { $0.body.count < 6_000 })
        #expect(facts.allSatisfy { !$0.body.contains("\n- ") })
    }

    /// gpt-5.5 final review MED (2026-07-25): a PRIOR generation that already
    /// holds two atoms sharing one ContextAtomID (the residue the bare-core
    /// date-sibling defect could have written before it was caught) must not be
    /// perpetuated by matched-reuse. The recompile self-heals: the first match
    /// keeps the ID, the second mints fresh, and every emitted ID is unique.
    /// Contamination is forged via Codable round-trip — no production code
    /// path can mint it anymore, which is exactly why the guard needs a forged
    /// fixture rather than a same-literal reproduction.
    @Test
    func contaminatedPriorGenerationWithDuplicateIDsSelfHeals() async throws {
        let compiler = ContextMarkdownCompiler(embeddingProvider: TokenHashEmbedder())
        let clean = try await compiler.compile(
            source: generatedUserDocument,
            descriptor: userDescriptor(),
            updatedAt: updatedAt
        )
        let factAtoms = clean.atoms.filter { $0.kind == .relationship }
        try #require(factAtoms.count >= 2, "fixture must split into per-fact atoms")

        // Forge the contamination: give atom B atom A's ID via Codable rewrite.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var forgedAtoms = clean.atoms
        let victimIndex = try #require(forgedAtoms.firstIndex(where: { $0.id == factAtoms[1].id }))
        var atomJSON = try #require(
            try JSONSerialization.jsonObject(with: encoder.encode(forgedAtoms[victimIndex])) as? [String: Any]
        )
        atomJSON["id"] = factAtoms[0].id.rawValue
        forgedAtoms[victimIndex] = try decoder.decode(
            ContextAtomDraft.self,
            from: JSONSerialization.data(withJSONObject: atomJSON)
        )
        let contaminated = ContextCompiledSource(
            descriptor: clean.descriptor,
            sourceHash: clean.sourceHash,
            atoms: forgedAtoms,
            relationships: clean.relationships
        )
        try #require(
            Set(contaminated.atoms.map(\.id)).count == contaminated.atoms.count - 1,
            "the forged previous must actually carry a duplicate ID"
        )

        let healed = try await compiler.compile(
            source: generatedUserDocument,
            descriptor: userDescriptor(),
            previous: contaminated,
            updatedAt: updatedAt.addingTimeInterval(3_600)
        )
        let emitted = healed.atoms.map(\.id)
        #expect(Set(emitted).count == emitted.count,
                "recompiling against a contaminated previous must emit unique IDs")
        #expect(healed.atoms.count == clean.atoms.count)
    }

    /// gpt-5.5 final review MED (2026-07-25): a generator heading containing
    /// "preference"/"correction"/"boundary" used to promote every generated
    /// fact to .correction — and USER.md's .explicitCorrection authority makes
    /// corrections MANDATORY, so 43 mandatory atoms exceed the 6k budget and
    /// throw the whole turn. Generated facts must classify .relationship no
    /// matter what the generator titles its section; manual prose keeps the
    /// promotion.
    @Test
    func generatedFactsNeverPromoteToCorrectionViaHeadingTokens() async throws {
        let boobyTrapped = """
        # User Preferences (auto-generated from memory SQLite)

        \(UserMDAutogenMarkers.bodyStart)
        - User drinks his espresso as a double, never with hazelnut syrup.
        - 2026-08-01 09:00 Dentist appointment downtown.
        \(UserMDAutogenMarkers.bodyEnd)
        """
        let compiler = ContextMarkdownCompiler(embeddingProvider: TokenHashEmbedder())
        let compiled = try await compiler.compile(
            source: boobyTrapped,
            descriptor: userDescriptor(),
            updatedAt: updatedAt
        )
        let generated = compiled.atoms.filter { $0.body.contains("espresso") || $0.body.contains("Dentist") }
        try #require(generated.count == 2, "both bullets must atomize")
        #expect(generated.allSatisfy { $0.kind == .relationship },
                "generated facts under a 'Preferences' heading must stay .relationship, not .correction")
    }

    // MARK: - Fixtures

    private func userDescriptor() -> ContextSourceDescriptor {
        let locator = "persona/agent/USER.md"
        return ContextSourceDescriptor(
            id: ContextStableID.source(owner: "nativeagent.persona", locator: locator),
            owner: "nativeagent.persona",
            kind: .persona,
            canonicalLocator: locator,
            authority: .explicitCorrection,
            privacy: .localPrivate,
            permittedSurfaces: [.chat],
            injectionPolicy: .adaptive
        )
    }

    private func storedGeneration(_ compiled: ContextCompiledSource) -> ContextStoredGeneration {
        let source = ContextStoredSource(
            descriptor: compiled.descriptor,
            sourceHash: compiled.sourceHash,
            health: .healthy,
            lastError: nil,
            validFromGeneration: 1,
            validToGeneration: nil
        )
        let atoms = compiled.atoms.map {
            ContextStoredAtom(
                versionKey: "\($0.id.rawValue)@1",
                draft: $0,
                validFromGeneration: 1,
                validToGeneration: nil
            )
        }
        return ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: updatedAt,
                reason: "user fact atomization fixture",
                sourceFingerprint: compiled.sourceHash,
                atomCount: atoms.count,
                sourceCount: 1
            ),
            sources: [source],
            atoms: atoms,
            relationships: []
        )
    }
}

/// Deterministic bag-of-words embedder: hashes tokens into a fixed-width,
/// L2-normalized vector, so cosine between a query and an atom actually tracks
/// shared vocabulary instead of returning a constant.
private struct TokenHashEmbedder: ContextMarkdownEmbeddingProvider {
    let modelFingerprint = "token-hash-v1/256"

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var values = [Float](repeating: 0, count: 256)
            for token in text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
            where token.count >= 3 {
                var hash: UInt64 = 1_469_598_103_934_665_603
                for byte in token.utf8 {
                    hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
                }
                values[Int(hash % 256)] += 1
            }
            let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else {
                var fallback = values
                fallback[0] = 1
                return fallback
            }
            return values.map { $0 / norm }
        }
    }
}

private actor CountingEmbedder: ContextMarkdownEmbeddingProvider {
    nonisolated var modelFingerprint: String { "counting-v1/256" }
    private var seen: [String] = []

    func embed(_ texts: [String]) async throws -> [[Float]] {
        seen.append(contentsOf: texts)
        return try await TokenHashEmbedder().embed(texts)
    }

    func embeddedTexts() -> [String] { seen }
    func reset() { seen = [] }
}

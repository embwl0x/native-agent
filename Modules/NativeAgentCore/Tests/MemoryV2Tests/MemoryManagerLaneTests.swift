import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore
import PersistenceCore

// MARK: - The memory manager (2026-09-11)
//
// Two things are worth a test here and nothing else is: the JSON the model hands
// back, and the gate that decides whether a statement may stage. The model itself
// is mocked at the `MemoryManaging` seam.

private struct FixedMemoryManager: MemoryManaging {
    let decisions: [MemoryManagerDecision]?
    func review(_ request: MemoryManagerRequest) async -> [MemoryManagerDecision]? { decisions }
}

/// Answers with an `update` to whichever memory the manager was actually shown
/// first — the real shape of a correction, and the only way to test the
/// validated-target path without guessing ids.
private actor UpdatesFirstExistingManager: MemoryManaging {
    let statement: String
    private(set) var sawExisting: [MemoryManagerExistingMemory] = []

    init(statement: String) { self.statement = statement }

    func review(_ request: MemoryManagerRequest) async -> [MemoryManagerDecision]? {
        sawExisting = request.existing
        guard let target = request.existing.first else { return [] }
        return [.init(statement: statement, kind: "location",
                      whyItMatters: "where to reach him", confidence: 0.95,
                      action: .update, updatesId: target.id)]
    }

    func existingShown() -> [MemoryManagerExistingMemory] { sawExisting }
}

/// Says every text means the same thing. The hashing mock embedder cannot model
/// "this correction reads like the memory it corrects" — the production
/// condition behind the duplicate screen — so this stub states it outright.
private struct SameMeaningEmbeddingProvider: EmbeddingProvider {
    let dimensions = 8
    let modelId = "same-meaning"
    var embeddingEpoch: MemoryEmbeddingEpoch {
        MemoryEmbeddingEpoch(
            backend: "test-stub", modelID: modelId, modelArtifactDigest: "same-meaning-v1",
            tokenizerArtifactDigest: "none", preprocessing: "none",
            pooling: "constant", normalization: "l2", dimensions: dimensions,
            maximumSequenceLength: nil
        )
    }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in
            var v = [Float](repeating: 0, count: dimensions)
            v[0] = 1
            return v
        }
    }
}

@Suite("Memory manager lane")
struct MemoryManagerLaneTests {

    // MARK: parse

    @Test("An array of decisions parses, with defaults for what the model omits")
    func parsesDecisionArray() throws {
        let decisions = try MemoryManagerLane.parse("""
        Sure, here you go:
        ```json
        [{"statement": "User wants a second brain more powerful than the first",
          "kind": "goal", "why_it_matters": "it shapes what he builds next",
          "confidence": 0.91, "action": "add"},
         {"statement": "User now works from the studio, not the kitchen",
          "kind": "location", "confidence": "0.85", "action": "update",
          "updates_id": "mem-42"}]
        ```
        """)
        #expect(decisions.count == 2)
        #expect(decisions[0].action == .add)
        #expect(decisions[0].kind == "goal")
        #expect(decisions[0].confidence > 0.9)
        #expect(decisions[0].updatesId == nil)
        #expect(decisions[1].action == .update)
        #expect(decisions[1].updatesId == "mem-42")
        #expect(decisions[1].whyItMatters.isEmpty)
    }

    @Test("An empty array is an answer, a bare object is accepted, prose is not JSON")
    func parsesEdgeShapes() throws {
        #expect(try MemoryManagerLane.parse("[]").isEmpty)
        let single = try MemoryManagerLane.parse(
            #"{"statement": "User reads at night", "kind": "preference", "confidence": 0.9, "action": "add"}"#
        )
        #expect(single.count == 1)
        // An unknown kind falls back to "fact" rather than inventing a taxonomy.
        let odd = try MemoryManagerLane.parse(
            #"[{"statement": "User reads at night", "kind": "vibes", "confidence": 0.9, "action": "add"}]"#
        )
        #expect(odd.first?.kind == "fact")
        // An unknown action is a skip, never an add by default.
        let unknown = try MemoryManagerLane.parse(
            #"[{"statement": "User reads at night", "confidence": 0.9, "action": "maybe"}]"#
        )
        #expect(unknown.first?.action == .skip)
        #expect(throws: (any Error).self) { try MemoryManagerLane.parse("I could not find anything.") }
    }

    // MARK: the gate

    @Test("A plain third-person sentence about the person stages")
    func gateAllowsAMemory() {
        let user = "I want a second brain that is more powerful than the first one I built."
        let assistant = "Then the store has to outlive the app."
        #expect(MemoryManagerLane.statementRejectionReason(
            "User wants a second brain more powerful than the first one he built",
            userMessage: user, assistantMessage: assistant
        ) == nil)
    }

    @Test("The shapes User saw on the Memories page are all refused")
    func gateRefusesTheJunk() {
        let user = "I want a second brain that is more powerful than the first one I built."
        let assistant = "Then the store has to outlive the app."
        func reason(_ statement: String) -> String? {
            MemoryManagerLane.statementRejectionReason(
                statement, userMessage: user, assistantMessage: assistant
            )
        }
        // "user ..." — the phrasing of every junk proposal.
        #expect(reason("user wants a second brain more powerful than the first") != nil)
        // First person: the person's own words wearing a memory's clothes.
        #expect(reason("I want a second brain more powerful than the first one") != nil)
        // Addressed to the agent.
        #expect(reason("User wants you to build a more powerful second brain") != nil)
        // A quote used as a headline.
        #expect(reason("\"a second brain that is more powerful than the first\"") != nil)
        // A span copied out of the exchange rather than written about him.
        #expect(reason("a second brain that is more powerful than the first one I built") != nil)
        // An errand, which is the bot-brief shape.
        #expect(reason("Build a second brain more powerful than the first one") != nil)
        // Invented: nothing in the exchange grounds it.
        #expect(reason("User keeps tropical fish in a heated tank at home") != nil)
        // Bounded.
        #expect(reason("User naps") != nil)
        #expect(reason("User " + String(repeating: "wants more power ", count: 30)) != nil)
    }

    // MARK: staging

    @Test("Only add/update at or above the confidence floor reach the store")
    func stagesOnlyConfidentActions() async throws {
        let memory = try await makeMemory()
        let promoter = AdaptiveMemoryPromoter(
            memory: memory,
            memoryManager: FixedMemoryManager(decisions: [
                .init(statement: "User wants a second brain more powerful than the first",
                      kind: "goal", whyItMatters: "it shapes what he builds",
                      confidence: 0.93, action: .add),
                // Below the floor.
                .init(statement: "User prefers the studio to the kitchen for long builds",
                      kind: "preference", whyItMatters: "where he works",
                      confidence: 0.62, action: .add),
                // A skip, however confident.
                .init(statement: "User builds a second brain in the studio every morning",
                      kind: "fact", whyItMatters: "", confidence: 0.99, action: .skip),
                // Gate-refused phrasing.
                .init(statement: "user wants a second brain more powerful than the first",
                      kind: "goal", whyItMatters: "", confidence: 0.95, action: .add),
            ])
        )
        let observation = await promoter.observeTurnWithReport(
            userMessage: "I want a second brain that is more powerful than the first one I built.",
            assistantMessage: "Then the store has to outlive the app.",
            sessionId: "replay-test"
        )
        let facts = observation.proposals.filter { !MemoryMoments.isMoment($0.metadata) }
        #expect(facts.count == 1)
        #expect(facts.first?.content.hasPrefix("User wants a second brain") == true)
        #expect(facts.first?.source == "\(MemoryManagerLane.sourcePrefix):replay-test")
        #expect(observation.hygieneRejectedCount == 2)
    }

    @Test("An update names a memory it was shown, and carries that row's fingerprint")
    func updateCarriesValidatedTargetAndFingerprint() async throws {
        let storage = InMemoryMemoryStorage()
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32), storage: storage)
        let old = try await memory.store(
            content: "User works from the kitchen table",
            source: "test",
            metadata: .object(["kind": .string("location")])
        )
        let manager = UpdatesFirstExistingManager(
            statement: "User works from the studio now, not the kitchen table")
        let promoter = AdaptiveMemoryPromoter(memory: memory, memoryManager: manager)
        let observation = await promoter.observeTurnWithReport(
            userMessage: "I moved out of the kitchen, I work from the studio now.",
            assistantMessage: "Noted.",
            sessionId: "replay-test"
        )
        let shown = await manager.existingShown()
        #expect(shown.contains { $0.id == old.id }, "recall never showed the memory to correct")
        let staged = try #require(observation.proposals.first)
        guard case .object(let meta)? = staged.metadata,
              case .string(let superseded)? = meta[MemoryManagerLane.supersedesKey],
              case .string(let hash)? = meta[MemoryManagerLane.supersedesHashKey] else {
            Issue.record("staged row carried no validated supersession")
            return
        }
        #expect(superseded == old.id)
        #expect(hash == MemoryManagerLane.contentFingerprint("User works from the kitchen table"))
    }

    @Test("An update naming a memory it was never shown degrades to add, claiming no supersession")
    func updateWithUnknownIdDowngradesToAdd() async throws {
        let memory = try await makeMemory()
        let promoter = AdaptiveMemoryPromoter(
            memory: memory,
            memoryManager: FixedMemoryManager(decisions: [
                .init(statement: "User works from the studio now, not the kitchen table",
                      kind: "location", whyItMatters: "where to reach him",
                      confidence: 0.9, action: .update, updatesId: "mem-42"),
            ])
        )
        let observation = await promoter.observeTurnWithReport(
            userMessage: "I moved out of the kitchen, I work from the studio now.",
            assistantMessage: "Noted.",
            sessionId: "replay-test"
        )
        let staged = try #require(observation.proposals.first)
        guard case .object(let meta)? = staged.metadata else {
            Issue.record("staged row carried no metadata")
            return
        }
        // The statement was new, so it still stages — as an add that demotes
        // nothing, never as an update against an id nobody showed the model.
        #expect(meta[MemoryManagerLane.supersedesKey] == nil)
        #expect(meta[MemoryManagerLane.supersedesHashKey] == nil)
        #expect(meta["action"] == .string("add"))
    }

    @Test("The memory an update replaces is not screened as its own duplicate")
    func updateTargetIsExcludedFromDuplicateScreening() async throws {
        let storage = InMemoryMemoryStorage()
        let memory = SwiftNativeMemoryV2(
            embedder: SameMeaningEmbeddingProvider(), storage: storage)
        let old = try await memory.store(
            content: "User works from the kitchen table in the mornings",
            source: "test",
            metadata: .object(["kind": .string("location")])
        )
        // The correction is word-for-word the row it replaces except for the
        // one word that changed — the exact shape the duplicate screen used to
        // reject (2026-09-11 audit, finding 4).
        let manager = UpdatesFirstExistingManager(
            statement: "User works from the studio table in the mornings")
        let promoter = AdaptiveMemoryPromoter(memory: memory, memoryManager: manager)
        let observation = await promoter.observeTurnWithReport(
            userMessage: "I work from the studio table in the mornings now, not the kitchen.",
            assistantMessage: "Noted.",
            sessionId: "replay-test"
        )
        let shown = await manager.existingShown()
        #expect(shown.contains { $0.id == old.id }, "recall never showed the memory to correct")
        // The control: screened against the row it replaces, this statement IS a
        // near-duplicate — which is exactly why the target has to come out of the
        // comparison set for a validated update.
        #expect(await AdaptiveMemoryPromoter.isNearDuplicate(
            "User works from the studio table in the mornings",
            of: [old.text],
            memory: memory
        ))
        #expect(observation.proposals.count == 1)
        #expect(observation.hygieneRejectedCount == 0)
    }

    @Test("A store that cannot replace atomically refuses BEFORE any mutation")
    func acceptanceRefusesWithoutAtomicSupport() async throws {
        // InMemoryMemoryStorage cannot accept and demote in one transaction.
        // The old fallback accepted the proposal, inserted the new memory and
        // only then failed the demotion — a half-apply. Now it refuses first.
        let storage = InMemoryMemoryStorage()
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32), storage: storage)
        let old = try await memory.store(
            content: "User works from the kitchen table",
            source: "test",
            metadata: .object(["kind": .string("location")])
        )
        _ = try await memory.propose(
            content: "User works from the studio now, not the kitchen table",
            source: "\(MemoryManagerLane.sourcePrefix):replay-test",
            confidence: 0.95,
            kind: "location",
            extraMetadata: [
                MemoryManagerLane.supersedesKey: .string(old.id),
                MemoryManagerLane.supersedesHashKey:
                    .string(MemoryManagerLane.contentFingerprint(old.text)),
            ]
        )
        let pending = try #require(try await memory.listProposals(status: "pending").first)
        await #expect(throws: (any Error).self) {
            _ = try await memory.acceptProposal(id: pending.id)
        }
        // Nothing moved: no accepted status, no second memory row.
        let after = try #require(try await memory.listProposals(status: nil).first { $0.id == pending.id })
        #expect(after.status == "pending")
        #expect(try await memory.listProposals(status: "accepted").isEmpty)
        #expect(try await memory.listMemory(kind: nil).count == 1)
        #expect(try await memory.listMemory(kind: nil).first?.id == old.id)
    }

    @Test("An update whose target changed since staging is refused, not applied")
    func acceptanceRefusesAChangedTarget() async throws {
        // Through the PRODUCTION atomic bridge, so the fingerprint check is the
        // thing being exercised rather than the missing-capability refusal.
        let (memory, old) = try await makeAtomicMemoryWithOneFact()
        _ = try await memory.propose(
            content: "User works from the studio now, not the kitchen table",
            source: "\(MemoryManagerLane.sourcePrefix):replay-test",
            confidence: 0.95,
            kind: "location",
            extraMetadata: [
                MemoryManagerLane.supersedesKey: .string(old.id),
                // A fingerprint that does not match the row any more.
                MemoryManagerLane.supersedesHashKey:
                    .string(MemoryManagerLane.contentFingerprint("something else entirely")),
            ]
        )
        let pending = try #require(try await memory.listProposals(status: "pending").first)
        await #expect(throws: (any Error).self) {
            _ = try await memory.acceptProposal(id: pending.id)
        }
        // Refused BEFORE the acceptance: the proposal is still pending and no
        // second memory landed.
        #expect(try await memory.listProposals(status: "pending").count == 1)
        #expect(try await memory.listMemory(kind: nil).count == 1)
    }

    @Test("A verified update lands and demotes its target in one transaction")
    func acceptanceAppliesAVerifiedUpdate() async throws {
        // The happy path through the production atomic bridge — the guard rails
        // above are only honest if the real replacement still applies.
        let (memory, old) = try await makeAtomicMemoryWithOneFact()
        _ = try await memory.propose(
            content: "User works from the studio now, not the kitchen table",
            source: "\(MemoryManagerLane.sourcePrefix):replay-test",
            confidence: 0.95,
            kind: "location",
            extraMetadata: [
                MemoryManagerLane.supersedesKey: .string(old.id),
                MemoryManagerLane.supersedesHashKey:
                    .string(MemoryManagerLane.contentFingerprint(old.text)),
            ]
        )
        let pending = try #require(try await memory.listProposals(status: "pending").first)
        let accepted = try await memory.acceptProposal(id: pending.id)
        #expect(accepted.text.contains("studio"))
        // DEMOTION, not erasure: the old row is off the active list, the new
        // one is on it.
        let active = try await memory.listMemory(kind: nil)
        #expect(active.contains { $0.id == accepted.id })
        #expect(!active.contains { $0.id == old.id })
    }

    @Test("A legacy update with no target fingerprint never demotes anything")
    func acceptanceRefusesAFingerprintlessUpdate() async throws {
        // Proposals staged before the fingerprint existed carry only an id.
        // There is nothing to check the target against, so applying them would
        // demote whatever holds that id now. They stay pending for re-review.
        let (memory, old) = try await makeAtomicMemoryWithOneFact()
        _ = try await memory.propose(
            content: "User works from the studio now, not the kitchen table",
            source: "\(MemoryManagerLane.sourcePrefix):replay-test",
            confidence: 0.95,
            kind: "location",
            extraMetadata: [MemoryManagerLane.supersedesKey: .string(old.id)]
        )
        let pending = try #require(try await memory.listProposals(status: "pending").first)
        var message = ""
        do {
            _ = try await memory.acceptProposal(id: pending.id)
            Issue.record("a fingerprintless update was applied")
        } catch {
            message = "\(error)"
        }
        #expect(message.contains("needs re-review"))
        #expect(try await memory.listProposals(status: "pending").count == 1)
        #expect(try await memory.listMemory(kind: nil).count == 1)
        // And the memory it claimed to replace is untouched.
        let target = try #require(try await memory.listMemory(kind: nil).first)
        #expect(target.id == old.id)
    }

    /// SwiftNativeMemoryV2 over the production SQLite bridge (the storage that
    /// DOES implement atomic superseding acceptance), plus one stored fact.
    private func makeAtomicMemoryWithOneFact() async throws -> (SwiftNativeMemoryV2, MemoryRecord) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager-lane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32),
            storage: MemoryStorageBridge(storage: try MemoryStorage(dataRoot: root))
        )
        let old = try await memory.store(
            content: "User works from the kitchen table",
            source: "test",
            metadata: .object(["kind": .string("location")])
        )
        return (memory, old)
    }

    @Test("reconciled() keeps a shown target and drops an invented one")
    func reconciledValidatesTheTarget() {
        let existing = [MemoryManagerExistingMemory(id: "mem-1", content: "User works from the kitchen")]
        let update = MemoryManagerDecision(
            statement: "User works from the studio now", kind: "location",
            whyItMatters: "", confidence: 0.95, action: .update, updatesId: "mem-1")
        let kept = MemoryManagerLane.reconciled(update, existing: existing)
        #expect(kept.decision.action == .update)
        #expect(kept.target?.id == "mem-1")

        let invented = MemoryManagerDecision(
            statement: "User works from the studio now", kind: "location",
            whyItMatters: "", confidence: 0.95, action: .update, updatesId: "mem-99")
        let degraded = MemoryManagerLane.reconciled(invented, existing: existing)
        #expect(degraded.decision.action == .add)
        #expect(degraded.decision.updatesId == nil)
        #expect(degraded.target == nil)

        let idless = MemoryManagerDecision(
            statement: "User works from the studio now", kind: "location",
            whyItMatters: "", confidence: 0.95, action: .update, updatesId: nil)
        #expect(MemoryManagerLane.reconciled(idless, existing: existing).decision.action == .add)
    }

    @Test("No manager configured stages no facts, and says so")
    func noManagerStagesNothing() async throws {
        let memory = try await makeMemory()
        let promoter = AdaptiveMemoryPromoter(memory: memory, memoryManager: nil)
        let observation = await promoter.observeTurnWithReport(
            userMessage: "I want a second brain more powerful than the first.",
            assistantMessage: "Then the store has to outlive the app.",
            sessionId: "replay-test"
        )
        #expect(observation.proposals.isEmpty)
        #expect(observation.extraction.semanticStatus == .unavailable)
    }

    private func makeMemory() async throws -> SwiftNativeMemoryV2 {
        SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32),
            storage: InMemoryMemoryStorage()
        )
    }
}

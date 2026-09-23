import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore

private struct FixedManager: MemoryManaging {
    let decisions: [MemoryManagerDecision]
    func review(_ request: MemoryManagerRequest) async -> [MemoryManagerDecision]? { decisions }
}

@Suite("AdaptiveMemoryPromoter — staging, auto-accept and the sweep")
struct AdaptivePromoterTests {

    @Test func observeTurnWithoutMemoryIsNoOp() async {
        let promoter = AdaptiveMemoryPromoter(memory: nil)
        let staged = await promoter.observeTurn(
            userMessage: "my name is Example",
            assistantMessage: "hi Example",
            sessionId: "s-test"
        )
        #expect(staged.isEmpty)
    }

    @Test func highConfidenceIdentityAutoAcceptsIntoMemories() async throws {
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32),
            storage: InMemoryMemoryStorage()
        )
        // The narrow structured-fact allowlist (identity at >= 0.90) is the only
        // path that does not wait for review, and it is unchanged by the
        // memory-manager cutover.
        let promoter = AdaptiveMemoryPromoter(
            memory: memory,
            memoryManager: FixedManager(decisions: [
                .init(statement: "Example User is his full name",
                      kind: "identity", whyItMatters: "how to address him",
                      confidence: 0.95, action: .add),
            ])
        )

        let staged = await promoter.observeTurn(
            userMessage: "My name is Example User.",
            assistantMessage: "Got it, Example User.",
            sessionId: "s-auto-accept"
        )

        #expect(staged.count == 1)
        let memories = try await memory.listMemory(kind: nil)
        #expect(memories.count == 1)
        #expect(memories[0].text.lowercased().contains("example user"))

        let pending = try await memory.listProposals(status: "pending")
        let accepted = try await memory.listProposals(status: "accepted")
        #expect(pending.isEmpty)
        #expect(accepted.count == 1)
    }

    @Test func highConfidencePreferenceStaysPendingForHumanReview() async throws {
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32),
            storage: InMemoryMemoryStorage()
        )
        let promoter = AdaptiveMemoryPromoter(
            memory: memory,
            memoryManager: FixedManager(decisions: [
                .init(statement: "He prefers concise technical summaries",
                      kind: "preference", whyItMatters: "how to answer him",
                      confidence: 0.99, action: .add),
            ])
        )

        let staged = await promoter.observeTurn(
            userMessage: "I prefer concise technical summaries.",
            assistantMessage: "Got it.",
            sessionId: "preference-review-session"
        )

        #expect(staged.count == 1)
        #expect(try await memory.listMemory(kind: nil).isEmpty)
        let pending = try await memory.listProposals(status: "pending")
        #expect(pending.count == 1)
        guard case .object(let metadata)? = pending.first?.metadata else {
            Issue.record("expected proposal evidence metadata")
            return
        }
        #expect(metadata["recurrence_count"] == .int(1))
        #expect(metadata["supporting_session_ids"] == .array([
            .string("preference-review-session")
        ]))
    }

    @Test func acceptanceRechecksQualityForLegacyProposal() async throws {
        // The acceptance boundary still re-runs the durability gate. What that
        // gate covers after 2026-09-11 is transient session state, tool
        // transcript noise and a sentence that ends mid-thought — the rules that
        // protect EVERY writer, including commit_memory and the legacy rows the
        // consolidator sweeps. The old source-scoped "automatic extraction"
        // rules went with the regex extractor they were written for.
        let storage = InMemoryMemoryStorage()
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32),
            storage: storage
        )
        try await storage.insertProposal(ProposalRecord(
            id: "legacy-fragment",
            content: "user's design review is now",
            source: "adaptive-promoter:telegram-session",
            createdAt: "2026-07-10T01:02:11Z",
            metadata: .object([
                "kind": .string("goal"),
                "confidence": .double(0.7),
            ])
        ))

        do {
            _ = try await memory.acceptProposal(id: "legacy-fragment")
            Issue.record("quality-invalid proposal was accepted")
        } catch {
            // Expected: the acceptance boundary rejects and resolves the row.
        }

        #expect(try await memory.listMemory(kind: nil).isEmpty)
        let rejected = try #require(try await memory.listProposals(status: "rejected").first)
        #expect(rejected.id == "legacy-fragment")
        #expect(rejected.rejectionReason?.contains("quality gate at acceptance") == true)
    }

    @Test func proposeDedupesPendingProposalsByContentHash() async throws {
        // 2026-07-21 audit fix: propose() minted a fresh UUID per call, so
        // observeTurn staged the same extracted fact every turn. A pending
        // proposal with the same content hash is now updated in place.
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32),
            storage: InMemoryMemoryStorage()
        )
        let first = try await memory.propose(
            content: "user's favorite editor is Nova",
            source: "adaptive-promoter:sess-a",
            confidence: 0.8,
            kind: "preference",
            supportingSessionIDs: ["sess-a"],
            recurrenceCount: 1
        )
        // Same fact, next turn → SAME canonical row, merged evidence.
        let second = try await memory.propose(
            content: "user's favorite editor is Nova",
            source: "adaptive-promoter:sess-b",
            confidence: 0.85,
            kind: "preference",
            supportingSessionIDs: ["sess-b"],
            recurrenceCount: 1
        )
        #expect(second.id == first.id)
        let pending = try await memory.listProposals(status: "pending")
        #expect(pending.count == 1)
        guard case .object(let meta)? = pending[0].metadata else {
            Issue.record("expected object metadata on merged proposal")
            return
        }
        #expect(meta["recurrence_count"] == .int(2))
        #expect(meta["supporting_session_ids"] == .array([.string("sess-a"), .string("sess-b")]))
        #expect(meta["confidence"] == .double(0.85))
        #expect(meta["kind"] == .string("preference"))

        // A genuinely different fact still stages a fresh row.
        let third = try await memory.propose(
            content: "user lives in Berlin",
            source: "adaptive-promoter:sess-b",
            confidence: 0.9,
            kind: "location"
        )
        #expect(third.id != first.id)
        #expect(try await memory.listProposals(status: "pending").count == 2)
    }
}

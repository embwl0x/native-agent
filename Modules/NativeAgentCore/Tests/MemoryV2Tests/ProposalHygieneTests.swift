// ProposalHygieneTests.swift
//
// 2026-08-14 proposal-hygiene fix — three gates, each pinned by the REAL
// garbage the review queue accumulated (326 pending, screenshotted by User):
//   1. isIncompleteThought: kind-independent fragment gate (the old checks
//      were kind-guarded, so identity/location/employment bypassed them all).
//   2. isAgentSeatUserMessage: the bridge seat is DETECTED, so the memory
//      manager is told who is speaking (agent shop-talk used to mint "user is
//      a language model" about User). 2026-09-12: detection is all it does now —
//      the turn itself is no longer skipped, it stages under the sender's name.
//   3. Article-folded pending dedup ("user is a AI assistant" vs
//      "user is AI assistant" collapse to one row).

import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore

@Suite("Proposal hygiene — fragment gate")
struct FragmentGateTests {

    // Verbatim rows from the live pending queue, 2026-08-14. Every one must die.
    private static let liveGarbage: [String] = [
        // a private capsule line echoed into a memory proposal (2026-08-23 "- Settling:")
        "- Settling: still settling from a hard stretch; the kindness lands, but not all the way back yet",
        "user wants agent",
        "user likes how sometimes she",
        "user's design review is now",
        "user wants my own hands on it",
        "user wants out of it",
        "user's answer is no",
    ]

    @Test(arguments: Self.liveGarbage)
    func liveGarbageIsRejected(_ text: String) {
        #expect(!MemoryCandidateQuality.isDurableCandidate(
            text: text, source: "adaptive-promoter:test", kind: "preference"
        ), "should reject: \(text)")
    }

    // The kind-bypass hole: the same fragments tagged with kinds the OLD
    // gates skipped entirely must still die.
    @Test(arguments: ["identity", "location", "employment", "attribute"])
    func fragmentGateIsKindIndependent(_ kind: String) {
        #expect(!MemoryCandidateQuality.isDurableCandidate(
            text: "user likes how sometimes she",
            source: "adaptive-promoter:test",
            kind: kind
        ))
    }

    // Complete, legitimately-shaped facts must keep passing.
    private static let legitFacts: [String] = [
        "user's name is User",
        "user lives in San Francisco",
        "user works as a carpenter",
        "user works at Anthropic",
        "user's favorite color is blue",
        "user is a carpenter",
        "Goal: ship the public beta",
        "user prefers tabs, not spaces",
    ]

    @Test(arguments: Self.legitFacts)
    func completeFactsStillPass(_ text: String) {
        #expect(MemoryCandidateQuality.isDurableCandidate(
            text: text, source: "adaptive-promoter:test", kind: "fact"
        ), "should pass: \(text)")
    }

    // gpt-5.5 review finding (fce4c4114ffe BLOCKING, fixed): lexically
    // ambiguous tails — pronoun-record "her"/"his", proper-name "Who" —
    // must NOT reject DELIBERATE stores; they reject only for automatic
    // extraction sources.
    @Test func ambiguousTailsPassForDeliberateSources() {
        for text in ["user's pronouns are she/her",
                     "user's pronouns are he/him/his",
                     "user's favorite band is The Who"] {
            #expect(MemoryCandidateQuality.isDurableCandidate(
                text: text, source: "chat", kind: "identity"), "should pass: \(text)")
            #expect(MemoryCandidateQuality.isDurableCandidate(
                text: text, source: nil, kind: nil), "should pass (nil source): \(text)")
        }
    }

    @Test func ambiguousTailsStillRejectForAutomaticSources() {
        #expect(!MemoryCandidateQuality.isDurableCandidate(
            text: "user likes how sometimes her",
            source: "adaptive-promoter:t", kind: "preference"))
    }

    // Verb-form captures with a single bare-token object are clipped
    // sentences even when the token is a content word — while a multi-token
    // object is a complete thought and passes.
    @Test func singleTokenObjectAfterVerbLeadInIsRejected() {
        #expect(!MemoryCandidateQuality.isDurableCandidate(
            text: "user wants agent", source: "adaptive-promoter:t", kind: nil))
        #expect(!MemoryCandidateQuality.isDurableCandidate(
            text: "user wants coffee", source: "adaptive-promoter:t", kind: nil))
        #expect(MemoryCandidateQuality.isDurableCandidate(
            text: "user wants agent autonomy controls", source: "adaptive-promoter:t", kind: nil))
    }
}

@Suite("Proposal hygiene — agent-seat bridge gate")
struct AgentSeatGateTests {

    @Test func bridgePrefixedTurnsAreAgentSeat() {
        #expect(AdaptiveMemoryPromoter.isAgentSeatUserMessage(
            "[from: claude, via bridge] I want agent X to poll the runner"))
        #expect(AdaptiveMemoryPromoter.isAgentSeatUserMessage(
            "[from: codex, via bridge] my name is irrelevant here"))
        #expect(AdaptiveMemoryPromoter.isAgentSeatUserMessage(
            "  [FROM: agent-wake, via bridge] leading whitespace and caps"))
    }

    @Test func humanTurnsAreNotAgentSeat() {
        #expect(!AdaptiveMemoryPromoter.isAgentSeatUserMessage(
            "my name is User and I live in San Francisco"))
        // Mentioning the bridge mid-sentence is not a machine tag.
        #expect(!AdaptiveMemoryPromoter.isAgentSeatUserMessage(
            "I read a message [from: claude, via bridge] earlier today"))
        #expect(!AdaptiveMemoryPromoter.isAgentSeatUserMessage(""))
    }

    // 2026-09-12 (User, 2026-09-11: "her having her memory with you is kind of
    // important"). The blanket bridge skip was the regex era's fix. The memory
    // manager is a model that is TOLD who is speaking, so a bridge turn now runs
    // the fact lane with the sender named — it stages, under the manager source.
    @Test func agentSeatTurnStagesUnderTheMemoryManagerSource() async {
        let memory = SwiftNativeMemoryV2(embedder: MockEmbeddingProvider(), storage: InMemoryMemoryStorage())
        let promoter = AdaptiveMemoryPromoter(
            memory: memory, memoryManager: AlwaysProposingManager())
        let staged = await promoter.observeTurn(
            userMessage: "[from: claude, via bridge] my name is Claude and I live in Boston",
            assistantMessage: "noted",
            sessionId: "bridge-session"
        )
        #expect(!staged.isEmpty)
        // The manager lane owns it, keyed by the session it came from — not the
        // regex promoter, so an approval card can say where the fact came from.
        #expect(staged.contains {
            $0.source == "\(MemoryManagerLane.sourcePrefix):bridge-session"
        })

        // A human turn on the same promoter runs the same lane: the manager
        // proposes the same statement again and it folds into the one memory
        // the bridge turn already produced (0.95 auto-accepts) — one lane,
        // one row, whoever was in the seat.
        _ = await promoter.observeTurn(
            userMessage: "my name is Claude and I live in Boston",
            assistantMessage: "noted",
            sessionId: "human-session"
        )
        let memories = (try? await memory.listMemory(kind: nil)) ?? []
        #expect(memories.count == 1)
        #expect(((try? await memory.listProposals(status: "pending")) ?? []).isEmpty)
    }
}

@Suite("Proposal hygiene — article-folded dedup")
struct ArticleFoldDedupTests {

    @Test func articleVariantsCollapseToOnePendingRow() async throws {
        let memory = SwiftNativeMemoryV2(embedder: MockEmbeddingProvider(), storage: InMemoryMemoryStorage())
        let first = try await memory.propose(
            content: "user works as a senior carpenter",
            source: "adaptive-promoter:s1", confidence: 0.5, kind: "employment")
        let second = try await memory.propose(
            content: "user works as senior carpenter",
            source: "adaptive-promoter:s2", confidence: 0.5, kind: "employment")
        #expect(first.id == second.id, "article variant must merge into the canonical pending row")
        let pending = try await memory.listProposals(status: "pending")
        let matching = pending.filter { $0.content.lowercased().contains("senior carpenter") }
        #expect(matching.count == 1)
    }

    @Test func distinctFactsDoNotCollapse() async throws {
        let memory = SwiftNativeMemoryV2(embedder: MockEmbeddingProvider(), storage: InMemoryMemoryStorage())
        let first = try await memory.propose(
            content: "user works as a senior carpenter",
            source: "adaptive-promoter:s1", confidence: 0.5, kind: "employment")
        let second = try await memory.propose(
            content: "user works as a junior carpenter",
            source: "adaptive-promoter:s1", confidence: 0.5, kind: "employment")
        #expect(first.id != second.id)
    }
}

// 2026-08-16 live escape: "user's whole thing is I was just trying to think of
// some other" reached User's approval card. Two independent holes, both pinned.
@Suite("Proposal hygiene — parrot-clause and determiner-tail escape")
struct ParrotClauseEscapeTests {
    @Test func liveEscapeStringRejectsAtTheQualityGate() {
        let reason = MemoryCandidateQuality.rejectionReason(
            text: "user's whole thing is I was just trying to think of some other",
            source: "adaptive-promoter:session"
        )
        #expect(reason != nil, "determiner tail 'other' must reject for ANY source")
    }

    @Test func determinerTailsRejectForAutomaticSourcesOnly() {
        // Automatic extraction: a determiner tail is always a truncation.
        for tail in ["some other", "several", "more"] {
            let reason = MemoryCandidateQuality.rejectionReason(
                text: "user prefers \(tail)",
                source: "adaptive-promoter:session"
            )
            #expect(reason != nil, "automatic '\(tail)' tail must reject")
        }
        // Deliberate lane (chat.commit_memory — her GOOD lane, User 2026-08-17):
        // these are legit sentence endings and must survive.
        for content in [
            "User prefers Signal over any other",
            "User tracks upstream forks himself, among several",
            "User wants updates weekly, not more",
        ] {
            let reason = MemoryCandidateQuality.rejectionReason(
                text: content,
                source: "chat.commit_memory"
            )
            #expect(reason == nil, "deliberate save '\(content)' must pass, got \(reason ?? "nil")")
        }
    }

    // The two extractor-shape tests that lived here are gone with
    // `RuleBasedFactExtractor` (2026-09-11). The quality-gate rules above still
    // stand: they are what keeps the rows that extractor already wrote into the
    // live store out of recall, user.md and the context projection.
}

/// A manager that always returns one clean, gate-passing memory. Used to prove a
/// lane never RAN, rather than that its gate happened to refuse the answer.
private struct AlwaysProposingManager: MemoryManaging {
    func review(_ request: MemoryManagerRequest) async -> [MemoryManagerDecision]? {
        [.init(statement: "Claude drives the local bridge from Boston",
               kind: "location", whyItMatters: "where the peer runs",
               confidence: 0.95, action: .add)]
    }
}

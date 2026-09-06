import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore

/// Sweep item 35 — what she DID in a turn reaches memory.
///
/// The chat layer projects the turn's tool evidence into bounded lines; this
/// suite pins the MemoryV2 half: the lines become approval-gated candidates,
/// the caps hold at the boundary, the agent-seat guard covers the new lane,
/// and a turn with no evidence behaves exactly as it did before.
@Suite("AdaptiveToolEvidence — tool evidence reaches the promoter")
struct AdaptiveToolEvidenceTests {
    /// Evidence proposals are off by default since 2026-09-02 (a tool receipt
    /// is not a lasting fact); this suite exercises the opt-in path.
    init() { AdaptiveToolEvidence.proposalsEnabled = true }


    private func makeMemory() -> SwiftNativeMemoryV2 {
        SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32),
            storage: InMemoryMemoryStorage()
        )
    }

    // MARK: - Candidate shaping

    @Test func evidenceLineBecomesCandidateCarryingThePath() async {
        let cs = AdaptiveToolEvidence.candidates(
            from: ["read_file(path=/Users/user/Projects/App/Auth.swift) ok: 812 lines"]
        )
        #expect(cs.count == 1)
        #expect(cs[0].content.contains("/Users/user/Projects/App/Auth.swift"))
        #expect(cs[0].kind == AdaptiveToolEvidence.kind)
    }

    @Test func emptyEvidenceProducesNoCandidates() async {
        #expect(AdaptiveToolEvidence.candidates(from: []).isEmpty)
        #expect(AdaptiveToolEvidence.candidates(from: ["", "   ", "tiny"]).isEmpty)
    }

    @Test func candidateCapsHold() async {
        let long = String(repeating: "x", count: 4_000)
        let lines = (0..<40).map { "read_file(path=/tmp/f\($0)/\(long)) ok" }
        let cs = AdaptiveToolEvidence.candidates(from: lines)
        #expect(cs.count == AdaptiveToolEvidence.maxLines)
        // "observed: " prefix + the per-line ceiling, and nothing more.
        #expect(cs.allSatisfy { $0.content.count <= AdaptiveToolEvidence.maxLineChars + 10 })
    }

    @Test func identicalEvidenceLinesDedupe() async {
        let line = "list_dir(path=/Users/user/Projects/App/Sources) ok: 12 entries"
        let cs = AdaptiveToolEvidence.candidates(from: [line, line, line])
        #expect(cs.count == 1)
    }

    // MARK: - The approval gate

    @Test func evidenceCandidatesNeverAutoAccept() async {
        let candidate = AdaptiveCandidate(
            content: "observed: read_file(path=/a/b/Auth.swift) ok",
            score: AdaptiveToolEvidence.score,
            kind: AdaptiveToolEvidence.kind
        )
        // Both at the production floor and at a floor of zero: the KIND is
        // outside the auto-accept allowlist, so lowering the floor cannot
        // open the gate.
        #expect(!AdaptiveMemoryPromoter.shouldAutoAccept(
            candidate, confidenceFloor: AdaptiveMemoryPromoter.defaultAutoAcceptThreshold))
        #expect(!AdaptiveMemoryPromoter.shouldAutoAccept(candidate, confidenceFloor: 0))
    }

    @Test func evidenceStagesAsPendingProposalOnly() async throws {
        let memory = makeMemory()
        let promoter = AdaptiveMemoryPromoter(memory: memory)

        let staged = await promoter.observeTurn(
            userMessage: "where does auth live?",
            assistantMessage: "Modules/Auth.",
            toolEvidence: ["read_file(path=/Users/user/Projects/App/Auth.swift) ok: 812 lines"],
            sessionId: "s-evidence"
        )

        #expect(staged.count == 1)
        #expect(staged[0].content.contains("/Users/user/Projects/App/Auth.swift"))
        let pending = try await memory.listProposals(status: "pending")
        #expect(pending.count == 1)
        // Nothing auto-wrote into the memory store.
        let memories = try await memory.listMemory(kind: nil)
        #expect(memories.isEmpty)
    }

    // MARK: - The agent-seat guard covers the new lane

    @Test func agentSeatTurnStagesNoEvidence() async throws {
        let memory = makeMemory()
        let promoter = AdaptiveMemoryPromoter(memory: memory)

        let staged = await promoter.observeTurn(
            userMessage: "[from: claude, via bridge] check the auth module",
            assistantMessage: "done",
            toolEvidence: ["read_file(path=/Users/user/Projects/App/Auth.swift) ok: 812 lines"],
            sessionId: "s-bridge"
        )

        #expect(staged.isEmpty)
        #expect(try await memory.listProposals(status: "pending").isEmpty)
    }

    // MARK: - Prose-only behavior unchanged

    @Test func turnWithoutEvidenceIsUnchanged() async throws {
        let memory = makeMemory()
        let promoter = AdaptiveMemoryPromoter(memory: memory)

        let staged = await promoter.observeTurn(
            userMessage: "My name is Example User.",
            assistantMessage: "Got it.",
            sessionId: "s-prose-only"
        )

        #expect(staged.count == 1)
        #expect(staged[0].content.lowercased().contains("example user"))
        let observation = await AdaptiveMemoryPromoter(memory: makeMemory()).observeTurnWithReport(
            userMessage: "My name is Example User.",
            assistantMessage: "Got it.",
            sessionId: "s-prose-only-report"
        )
        #expect(observation.toolEvidenceCandidateCount == 0)
    }

    @Test func evidenceAndProseBothStageOnTheSameTurn() async throws {
        let memory = makeMemory()
        let promoter = AdaptiveMemoryPromoter(memory: memory)

        let observation = await promoter.observeTurnWithReport(
            userMessage: "My name is Example User.",
            assistantMessage: "Got it.",
            toolEvidence: ["read_file(path=/Users/user/Projects/App/Auth.swift) ok: 812 lines"],
            sessionId: "s-both"
        )

        #expect(observation.toolEvidenceCandidateCount == 1)
        #expect(observation.proposals.count == 2)
        // The prose fact still auto-accepts; the evidence fact still does not.
        #expect(try await memory.listMemory(kind: nil).count == 1)
        #expect(try await memory.listProposals(status: "pending").count == 1)
    }
}

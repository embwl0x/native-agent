import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

private struct InlineCognitionProposalCardEvalLLM: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        "view: A completion claim must name the evidence that verified it."
    }
}

@Suite("Inline cognition proposal card behavior", .serialized)
struct InlineCognitionProposalCardBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inline-cognition-proposal-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seedProposal(
        root: URL
    ) async throws -> (NativeCognitionRuntime, CognitiveStandingView) {
        let persona = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        try "# Eval identity\n\nStay grounded in verified outcomes."
            .write(to: persona.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        await runtime.bootstrap()
        await runtime.observe(CognitiveEvent(
            id: "inline-card-proposal",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "conversation", id: "inline-card-proposal"),
            sourceClass: .userStated,
            occurredAt: Date(),
            summary: "Show only conclusions that are backed by observable evidence.",
            importance: 0.95,
            turnKind: .live
        ))
        let reflection = await runtime.runReflectionIfDue(
            llm: InlineCognitionProposalCardEvalLLM(),
            reason: "inline cognition proposal card evaluation"
        )
        guard case .completed = reflection else {
            throw NSError(domain: "InlineCognitionProposalCardEval", code: 1)
        }
        let detail = await runtime.observatoryDetail()
        let proposal = try #require(detail.standingViews.first { $0.status == .proposed })
        return (runtime, proposal)
    }

    // app.mind / ui.InlineCognitionProposalCard
    @Test("an inline approve is single-flight, records its durable outcome, and removes the card from the pending feed")
    @MainActor func approveRefreshesTheRealProposalFeed() async throws {
        let root = try temporaryRoot("approve")
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, proposal) = try await seedProposal(root: root)
        let state = InlineCognitionProposalCardActionState()

        #expect(state.begin(.approve))
        #expect(!state.begin(.reject))
        let result = await CognitionProposalActions.resolveWithOutcome(
            runtime: runtime,
            id: proposal.id,
            approved: true
        )
        let feedback = state.settle(result.status, decision: .approve)

        #expect(feedback == .saved("Standing view approved and saved."))
        #expect(state.inFlight == nil)
        #expect(state.feedback == feedback)
        #expect((await CognitionProposalsFeed.pending(runtime: runtime)).standingViews.isEmpty)
        #expect((await runtime.observatoryDetail()).standingViews
            .first { $0.id == proposal.id }?.status == .active)
    }

    // app.mind / ui.InlineCognitionProposalCard
    @Test("a stale inline decision reports unavailable instead of presenting a second saved outcome")
    @MainActor func staleDecisionKeepsTheDurableDecisionAndShowsAnError() async throws {
        let root = try temporaryRoot("stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, proposal) = try await seedProposal(root: root)
        _ = await CognitionProposalActions.resolveWithOutcome(
            runtime: runtime,
            id: proposal.id,
            approved: false
        )

        let state = InlineCognitionProposalCardActionState()
        #expect(state.begin(.approve))
        let stale = await CognitionProposalActions.resolveWithOutcome(
            runtime: runtime,
            id: proposal.id,
            approved: true
        )
        let feedback = state.settle(stale.status, decision: .approve)

        guard case .unavailable(let message) = feedback else {
            Issue.record("a stale inline decision rendered as saved")
            return
        }
        #expect(message.contains("not applied"))
        #expect(state.inFlight == nil)
        #expect((await CognitionProposalsFeed.pending(runtime: runtime)).standingViews.isEmpty)
        #expect((await runtime.observatoryDetail()).standingViews
            .first { $0.id == proposal.id }?.status == .retired)
    }
}

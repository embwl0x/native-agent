import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

private struct ActivityInlineDecisionEvalLLM: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        "view: A proposed conclusion needs evidence before it becomes durable."
    }
}

@MainActor
@Suite("app.mac · Activity inline decision actions", .serialized)
struct ActivityInlineDecisionActionsEvalTests {
    @Test("Approve calls the canonical resolver once and locks the saved decision")
    func approveUsesRealStandingViewResolution() async throws {
        let root = try temporaryRoot("approve")
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, proposal) = try await seedProposal(root: root)
        let state = InlineCognitionProposalCardActionState()
        var resolverCalls = 0
        let resolve: @MainActor (Bool) async -> CognitionProposalActions.ResolveStatus = { approved in
            resolverCalls += 1
            return await CognitionProposalActions.resolveWithOutcome(
                runtime: runtime,
                id: proposal.id,
                approved: approved
            ).status
        }

        #expect(state.canResolve)
        #expect(state.begin(.approve))
        let feedback = state.settle(await resolve(true), decision: .approve)

        #expect(resolverCalls == 1)
        #expect((await runtime.observatoryDetail()).standingViews
            .first(where: { $0.id == proposal.id })?.status == .active)
        #expect(feedback == .saved("Standing view approved and saved."))
        #expect(!state.canResolve,
                "a durable decision must not permit a second inline decision before the feed removes the card")
    }

    @Test("unavailable resolution remains explicit and retryable instead of pretending the decision saved")
    func unavailableDecisionIsVisibleAndDoesNotLockTheActions() async throws {
        let state = InlineCognitionProposalCardActionState()
        let resolve: @MainActor (Bool) async -> CognitionProposalActions.ResolveStatus = { _ in
            .unavailable("That standing view is no longer awaiting review.")
        }

        #expect(state.begin(.reject))
        let feedback = state.settle(await resolve(false), decision: .reject)

        #expect(feedback == .unavailable(
            "Standing-view review not applied: That standing view is no longer awaiting review."
        ))
        #expect(state.canResolve)
        #expect(state.begin(.reject), "an unavailable outcome must leave the action retryable")
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-inline-decision-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seedProposal(root: URL) async throws -> (NativeCognitionRuntime, CognitiveStandingView) {
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
            id: "activity-inline-decision",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "conversation", id: "activity-inline-decision"),
            sourceClass: .userStated,
            occurredAt: Date(),
            summary: "Show only conclusions backed by observable evidence.",
            importance: 0.95,
            turnKind: .live
        ))
        guard case .completed = await runtime.runReflectionIfDue(
            llm: ActivityInlineDecisionEvalLLM(),
            reason: "Activity inline decision evaluation"
        ) else {
            throw NSError(domain: "ActivityInlineDecisionActionsEval", code: 1)
        }
        let detail = await runtime.observatoryDetail()
        return (runtime, try #require(detail.standingViews.first { $0.status == .proposed }))
    }

}

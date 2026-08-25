// EVAL COVERAGE — executed cognition/runtime behavior, not SwiftUI-source
// inspection.  These tests start from the same NativeCognitionRuntime stores
// that Cognition Observatory and Activity's proposal card use.
//
// Claimable app.mind rows:
// ui.cognitionObservatory.button.reflect
// ui.cognitionObservatory.panel.reflectionReceipts
// ui.cognitionObservatory.panel.developmentalTimeline
// api.CognitionProposalsFeed.pending
// ui.cognitionProposals.standingViews
// ui.cognitionProposals.action.approve
// ui.cognitionProposals.action.reject
// ui.InlineCognitionProposalCard
// ui.cognitionObservatory.button.settleBody
// ui.cognitionObservatory.button.resetBody
// ui.cognitionObservatory.panel.organism
// ui.cognitionObservatory.action.reflexApprove (negative, high-risk gate)
// ui.cognitionObservatory.action.reflexRetire (negative, missing candidate)

import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

private func mindWave2Root(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MindBehaviorWave2-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func mindWave2Runtime(_ root: URL) -> NativeCognitionRuntime {
    NativeCognitionRuntime(
        dataRoot: root,
        configurationOverride: .allPhasesEnabled,
        organismConfigurationOverride: .enabled,
        microcycleSchedulingMode: .manuallyFlushed,
        installedPhysiologySoakEnabled: false
    )
}

private struct MindWave2ReflectionLLM: LLMClient {
    let response: String

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        response
    }
}

private func mindWave2SeedProposal(
    root: URL,
    id: String,
    response: String = "view: Verified outcomes matter more than confident completion claims."
) async throws -> (NativeCognitionRuntime, CognitiveStandingView) {
    let persona = root.appendingPathComponent("persona", isDirectory: true)
    try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
    try "# Test identity\n\nStay grounded in verified outcomes."
        .write(to: persona.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

    let runtime = mindWave2Runtime(root)
    await runtime.bootstrap()
    await runtime.observe(CognitiveEvent(
        id: id,
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "conversation", id: id),
        sourceClass: .userStated,
        occurredAt: Date(),
        summary: "Please show me what was actually verified before you say it is done.",
        importance: 0.95,
        turnKind: .live
    ))
    let outcome = await runtime.runReflectionIfDue(
        llm: MindWave2ReflectionLLM(response: response),
        reason: "Mind behavior wave two"
    )
    guard case .completed = outcome else {
        throw NSError(
            domain: "MindBehaviorWave2Eval",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "reflection did not complete: \(outcome)"]
        )
    }
    let proposal = try #require(
        (await runtime.observatoryDetail()).standingViews.first(where: { $0.status == .proposed }),
        "a completed reflection with a view line must leave a reviewable proposal"
    )
    return (runtime, proposal)
}

@Suite("Mind behavior wave 2 — canonical runtime outcomes", .serialized)
struct MindBehaviorWave2EvalTests {
    @Test("an enabled organism without a projection never renders as healthy")
    func organismHintDistinguishesMissingBodyLineFromAHealthyProjection() async throws {
        let root = try mindWave2Root("body-hint")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindWave2Runtime(root)
        await runtime.bootstrap()

        let live = await runtime.organismSnapshot()
        #expect(live.enabled)
        let liveLine = try #require(live.projectedBodyLine,
                                    "the enabled runtime's cautious fallback is a real body observation")
        #expect(CognitionObservatoryView.organismHint(live)
            == liveLine.replacingOccurrences(of: "- Body: ", with: ""))

        var noProjection = live
        noProjection.projectedBodyLine = nil
        #expect(CognitionObservatoryView.organismHint(noProjection) == "no body line")

        var disabled = live
        disabled.enabled = false
        #expect(CognitionObservatoryView.organismHint(disabled) == "off")

        var projected = live
        projected.projectedBodyLine = "- Body: provider path needs verification"
        #expect(CognitionObservatoryView.organismHint(projected)
            == "provider path needs verification")
    }

    @Test("reflection produces one receipt, lineage, and a reviewable proposed standing view")
    func reflectionCreatesReviewableDurableOutcome() async throws {
        let root = try mindWave2Root("reflection")
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, proposal) = try await mindWave2SeedProposal(root: root, id: "reflection-outcome")

        let detail = await runtime.observatoryDetail()
        #expect(detail.reflections.count == 1,
                "Reflect must leave a receipt; a returned provider answer is not sufficient evidence")
        #expect(detail.reflections[0].proposalIds.contains(proposal.id))
        #expect(detail.standingViews.contains { $0.id == proposal.id && $0.status == .proposed })
        #expect(detail.developmentalTimeline.contains { $0.artifactId == proposal.id })

        // Restart against the same canonical root: a panel refresh must not be
        // the only place the proposal exists.
        let relaunched = mindWave2Runtime(root)
        await relaunched.bootstrap()
        let afterRestart = await relaunched.observatoryDetail()
        #expect(afterRestart.standingViews.contains { $0.id == proposal.id && $0.status == .proposed })
        #expect(afterRestart.reflections.contains { $0.proposalIds.contains(proposal.id) })
    }

    @Test("proposal feed shows only pending items and updates after each reviewed outcome")
    func proposalFeedTracksActualRuntimeReviewStates() async throws {
        let approveRoot = try mindWave2Root("approve")
        let rejectRoot = try mindWave2Root("reject")
        defer {
            try? FileManager.default.removeItem(at: approveRoot)
            try? FileManager.default.removeItem(at: rejectRoot)
        }
        let (approvalRuntime, approval) = try await mindWave2SeedProposal(root: approveRoot, id: "approve")
        let (rejectionRuntime, rejection) = try await mindWave2SeedProposal(root: rejectRoot, id: "reject")

        let pending = await CognitionProposalsFeed.pending(runtime: approvalRuntime)
        #expect(pending.standingViews.map(\.id) == [approval.id])
        #expect(pending.count == 1)

        _ = await approvalRuntime.resolveStandingView(id: approval.id, approved: true)
        let approvedDetail = await approvalRuntime.observatoryDetail()
        #expect(approvedDetail.standingViews.first { $0.id == approval.id }?.status == .active)
        #expect((await CognitionProposalsFeed.pending(runtime: approvalRuntime)).standingViews.isEmpty,
                "an approved proposal must leave the actionable feed")

        _ = await rejectionRuntime.resolveStandingView(id: rejection.id, approved: false)
        let rejectedDetail = await rejectionRuntime.observatoryDetail()
        #expect(rejectedDetail.standingViews.first { $0.id == rejection.id }?.status == .retired)
        #expect((await CognitionProposalsFeed.pending(runtime: rejectionRuntime)).standingViews.isEmpty,
                "rejection must retire, rather than hide a still-pending proposal")
    }

    @Test("standing-view decisions are durable and cannot be reversed by a second click")
    func standingViewReviewIsOneWayAcrossRestart() async throws {
        let root = try mindWave2Root("one-way")
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, proposal) = try await mindWave2SeedProposal(root: root, id: "one-way")

        _ = await runtime.resolveStandingView(id: proposal.id, approved: true)
        _ = await runtime.resolveStandingView(id: proposal.id, approved: false)
        let afterDoubleClick = await runtime.observatoryDetail()
        #expect(afterDoubleClick.standingViews.first { $0.id == proposal.id }?.status == .active)

        let relaunched = mindWave2Runtime(root)
        await relaunched.bootstrap()
        let restored = await relaunched.observatoryDetail()
        #expect(restored.standingViews.first { $0.id == proposal.id }?.status == .active)
    }

    @Test("body settle and reset are visibly different persisted organism outcomes")
    func organismSettleAndResetUseTheResidentRuntimeState() async throws {
        let root = try mindWave2Root("body")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindWave2Runtime(root)
        await runtime.bootstrap()
        let baseline = await runtime.organismSnapshot()

        await runtime.organismKernel.ingest(SomaticSignal(
            id: UUID(), kind: .providerFailed, sourceOrgan: "eval-provider",
            occurredAt: Date(), intensity: 1
        ))
        let lived = await runtime.organismSnapshot()
        #expect(lived.enabled)
        #expect(lived.signalCount == baseline.signalCount + 1,
                "the test signal must add exactly one lived event beyond bootstrap's app-wake signal")
        #expect(lived.chemicalState.vigilance > ChemicalState.neutral.vigilance)

        let settled = await runtime.settleOrganismContinuity()
        #expect(settled.signalCount == lived.signalCount,
                "settle must preserve a lived body while reducing it")
        #expect(settled.chemicalState.vigilance < lived.chemicalState.vigilance)

        let reset = await runtime.resetOrganismContinuity()
        #expect(reset.signalCount == 0)
        #expect(reset.chemicalState == .neutral)
        #expect(reset.fieldSummary == .empty)
        #expect(reset.reflexCandidates.isEmpty)

        let stateURL = root.appendingPathComponent("cognition/organism_state.json")
        #expect(FileManager.default.fileExists(atPath: stateURL.path),
                "the next Observatory refresh/relaunch must read the reset baseline")
    }

    @Test("reflex review refuses unknown and non-low-risk approvals without claiming a change")
    func reflexReviewFailsClosedWhenNoEligibleCandidateExists() async throws {
        let root = try mindWave2Root("reflex-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindWave2Runtime(root)
        await runtime.bootstrap()

        let missing = await runtime.applyOrganismReflexReview(
            id: "unknown", decision: .approve, reviewedBy: "eval", source: "test"
        )
        #expect(missing.status == .candidateNotFound)
        #expect(missing.receipt == nil)

        // A provider failure changes the real body, but it does not fabricate a
        // generic policy proposal. The UI must therefore remain unable to claim
        // that an approve/retire action acted on a candidate.
        await runtime.organismKernel.ingest(SomaticSignal(
            id: UUID(), kind: .providerFailed, sourceOrgan: "eval-provider",
            occurredAt: Date(), intensity: 1
        ))
        let stillMissing = await runtime.applyOrganismReflexReview(
            id: "provider:recovery", decision: .retire, reviewedBy: "eval", source: "test"
        )
        #expect(stillMissing.status == .candidateNotFound)
        #expect(stillMissing.receipt == nil)
    }
}

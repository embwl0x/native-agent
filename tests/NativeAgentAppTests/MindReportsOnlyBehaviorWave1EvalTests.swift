// EVAL COVERAGE — fence `app.mind`, reports-only hardening wave 1 (2026-08-24).
//
// These tests deliberately stop at the app's canonical cognition boundary:
// NativeCognitionRuntime -> CognitiveSubstrate / OrganismKernel -> durable
// injected root -> Observatory/Activity read model.  They do not scrape Swift
// source or merely construct a View.  Each proof uses a fixed clock, a fresh
// temporary root, and an adverse control, so an apparently quiet Observatory
// cannot turn a failed state transition into a convincing zero.
//
// Rows exercised here:
//   ui.cognitionObservatory.button.refresh
//   ui.cognitionObservatory.button.reflect
//   ui.cognitionObservatory.panel.reflectionReceipts
//   ui.cognitionObservatory.panel.developmentalTimeline
//   ui.cognitionProposals.standingViews
//   ui.cognitionProposals.action.approve
//   ui.cognitionProposals.action.reject
//   ui.cognitionObservatory.button.settleBody
//   ui.cognitionObservatory.button.resetBody
//   ui.cognitionObservatory.panel.organism
//   ui.cognitionObservatory.action.reflexApprove
//   ui.cognitionObservatory.action.reflexRetire
//   ui.cognitionObservatory.panel.thoughtSeeds

import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

private let mindReportsOnlyWave1Time = Date(timeIntervalSince1970: 1_785_974_400)

private func mindReportsOnlyWave1Root(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MindReportsOnlyWave1-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func mindReportsOnlyWave1Runtime(_ root: URL, organismEnabled: Bool = true) -> NativeCognitionRuntime {
    NativeCognitionRuntime(
        dataRoot: root,
        configurationOverride: .allPhasesEnabled,
        organismConfigurationOverride: organismEnabled ? .enabled : .disabled,
        now: { mindReportsOnlyWave1Time },
        monotonicNowNanoseconds: { 42 },
        microcycleSchedulingMode: .manuallyFlushed,
        installedPhysiologySoakEnabled: false
    )
}

private func mindReportsOnlyWave1Event(_ id: String, summary: String) -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "conversation", id: id),
        sourceClass: .userStated,
        occurredAt: mindReportsOnlyWave1Time,
        summary: summary,
        importance: 0.95,
        turnKind: .live
    )
}

private struct MindReportsOnlyWave1LLM: LLMClient {
    let result: Result<String, MindReportsOnlyWave1LLMFailure>

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try result.get()
    }
}

private enum MindReportsOnlyWave1LLMFailure: Error {
    case unavailable
}

private actor MindReportsOnlyWave1FailingOrganismWriter {
    func write(_: OrganismPersistentState, to _: URL) async throws {
        throw MindReportsOnlyWave1LLMFailure.unavailable
    }
}

private func mindReportsOnlyWave1SeedReflection(
    root: URL,
    eventID: String,
    response: String
) async throws -> (NativeCognitionRuntime, CognitiveStandingView) {
    let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try "# Agent\n\nStay grounded in verified outcomes.\n"
        .write(to: personaRoot.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

    let runtime = mindReportsOnlyWave1Runtime(root)
    await runtime.bootstrap()
    await runtime.observe(mindReportsOnlyWave1Event(
        eventID,
        summary: "Please distinguish verified completion from a response that merely arrived."
    ))
    let outcome = await runtime.runReflectionIfDue(
        llm: MindReportsOnlyWave1LLM(result: .success(response)),
        reason: "reports-only wave 1"
    )
    guard case .completed = outcome else {
        throw NSError(domain: "MindReportsOnlyWave1", code: 1)
    }
    let detail = await runtime.observatoryDetail()
    let proposal = try #require(
        detail.standingViews.first(where: { $0.status == .proposed }),
        "a real reflection with a view line must create a reviewable proposal"
    )
    return (runtime, proposal)
}

@Suite("Mind reports-only wave 1 — canonical behavior", .serialized)
struct MindReportsOnlyBehaviorWave1EvalTests {
    @Test("reflection success produces a durable receipt, proposal, and timeline outcome")
    func reflectionSuccessLeavesAllObservableOutcomes() async throws {
        let root = try mindReportsOnlyWave1Root("reflection-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, proposal) = try await mindReportsOnlyWave1SeedReflection(
            root: root,
            eventID: "reflection-success",
            response: "view: Completion language must follow verified terminal evidence."
        )

        let detail = await runtime.observatoryDetail()
        let receipt = try #require(detail.reflections.first)
        #expect(receipt.proposalIds.contains(proposal.id))
        #expect(detail.developmentalTimeline.contains { $0.artifactId == proposal.id })

        let relaunched = mindReportsOnlyWave1Runtime(root)
        await relaunched.bootstrap()
        let restored = await relaunched.observatoryDetail()
        #expect(restored.reflections.contains { $0.id == receipt.id })
        #expect(restored.standingViews.contains { $0.id == proposal.id && $0.status == .proposed })
    }

    @Test("a failed reflection records its failure without fabricating an actionable view")
    func failedReflectionIsVisibleButNeverPromoted() async throws {
        let root = try mindReportsOnlyWave1Root("reflection-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
        try "# Agent\n".write(to: personaRoot.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        let runtime = mindReportsOnlyWave1Runtime(root)
        await runtime.bootstrap()
        await runtime.observe(mindReportsOnlyWave1Event("reflection-failure", summary: "Do not infer success from transport."))

        _ = await runtime.runReflectionIfDue(
            llm: MindReportsOnlyWave1LLM(result: .failure(.unavailable)),
            reason: "negative control"
        )
        let detail = await runtime.observatoryDetail()
        #expect(detail.reflections.count == 1)
        #expect(detail.reflections[0].resultSummary.contains("reflection failed"))
        #expect(detail.standingViews.isEmpty)
    }

    @Test("approve moves exactly one proposed standing view into the durable active set")
    func approvalUpdatesFeedTimelineAndSurvivesRestart() async throws {
        let root = try mindReportsOnlyWave1Root("approval")
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, proposal) = try await mindReportsOnlyWave1SeedReflection(
            root: root,
            eventID: "approval",
            response: "view: Safety claims should name the evidence that settles them."
        )

        let afterApproval = await CognitionProposalActions.resolve(
            runtime: runtime, id: proposal.id, approved: true)
        #expect(afterApproval.standingViews.first { $0.id == proposal.id }?.status == .active)
        #expect(afterApproval.developmentalTimeline.contains {
            $0.artifactId == proposal.id && $0.summary.contains("activated")
        })

        let relaunched = mindReportsOnlyWave1Runtime(root)
        await relaunched.bootstrap()
        #expect((await relaunched.observatoryDetail()).standingViews.first { $0.id == proposal.id }?.status == .active)
    }

    @Test("reject retires the proposal, removes it from the feed, and cannot be reversed")
    func rejectionIsDurableAndOneWay() async throws {
        let root = try mindReportsOnlyWave1Root("rejection")
        defer { try? FileManager.default.removeItem(at: root) }
        let (runtime, proposal) = try await mindReportsOnlyWave1SeedReflection(
            root: root,
            eventID: "rejection",
            response: "view: A careful refusal is better than a confident invented answer."
        )

        _ = await CognitionProposalActions.resolve(runtime: runtime, id: proposal.id, approved: false)
        let after = await CognitionProposalActions.resolve(runtime: runtime, id: proposal.id, approved: true)
        #expect(after.standingViews.first { $0.id == proposal.id }?.status == .retired)
        #expect(after.developmentalTimeline.contains {
            $0.artifactId == proposal.id && $0.summary.contains("retired")
        })

        // Retired views deliberately delete their live artifact. The durable
        // record is the timeline, so a restart must not resurrect it into the
        // actionable feed merely because it has no row to render anymore.
        let relaunched = mindReportsOnlyWave1Runtime(root)
        await relaunched.bootstrap()
        let restored = await relaunched.observatoryDetail()
        #expect(restored.standingViews.contains { $0.id == proposal.id } == false)
        #expect(restored.developmentalTimeline.contains {
            $0.artifactId == proposal.id && $0.summary.contains("retired")
        })
    }

    @Test("refresh reads a new event and pin concern has a real seed to return")
    func observatoryRefreshSeesLiveFieldAndPinsOnlyARealConcern() async throws {
        let root = try mindReportsOnlyWave1Root("refresh-and-pin")
        defer { try? FileManager.default.removeItem(at: root) }
        let disabled = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: CognitiveConfiguration(enabled: false),
            organismConfigurationOverride: .disabled,
            now: { mindReportsOnlyWave1Time },
            monotonicNowNanoseconds: { 42 },
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        await disabled.bootstrap()
        #expect(await disabled.pinTopConcern() == nil,
                "a disabled field is the negative control: it must not fabricate a concern")

        let runtimeRoot = try mindReportsOnlyWave1Root("refresh-and-pin-live")
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let runtime = mindReportsOnlyWave1Runtime(runtimeRoot)
        await runtime.bootstrap()

        await runtime.observe(mindReportsOnlyWave1Event(
            "refresh-and-pin",
            summary: "The release verification remains unresolved and should be followed up."
        ))
        // Concern selection only draws from the owner’s thought-seed lane;
        // ordinary ingress must not be lexically re-scored by this UI action.
        // Seed that canonical lane directly, then prove Pin carries through it.
        let substrate = await runtime.substrateForIntegration()
        _ = await substrate.addThoughtSeed(
            kind: .followUp,
            text: "release verification remains unresolved",
            priority: 0.95
        )
        let beforePin = await CognitionObservatoryActions.refresh(runtime: runtime)
        try #require(beforePin.summary.nodeCount > 0)
        let pinned = try #require(await runtime.pinTopConcern())
        let afterPin = await CognitionObservatoryActions.refresh(runtime: runtime)
        #expect(afterPin.thoughtSeeds.count == beforePin.thoughtSeeds.count + 1)
        #expect(afterPin.thoughtSeeds.contains { $0.text == "Pinned concern: \(pinned)" })
    }

    @Test("organism signals are visible, durable, and settle without erasing history")
    func organismSettlePreservesTheLivedSignalAcrossRestart() async throws {
        let root = try mindReportsOnlyWave1Root("organism-settle")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindReportsOnlyWave1Runtime(root)
        await runtime.bootstrap()
        let baseline = await runtime.organismSnapshot()
        await runtime.organismKernel.ingest(SomaticSignal(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: .providerFailed,
            sourceOrgan: "wave1",
            occurredAt: mindReportsOnlyWave1Time,
            intensity: 1
        ))
        let lived = await runtime.organismSnapshot()
        #expect(lived.signalCount == baseline.signalCount + 1)
        #expect(lived.chemicalState.vigilance > baseline.chemicalState.vigilance)

        let settled = await CognitionObservatoryActions.settleBody(runtime: runtime)
        #expect(settled.organism.signalCount == lived.signalCount)
        #expect(settled.organism.chemicalState.vigilance <= lived.chemicalState.vigilance)
        let relaunched = mindReportsOnlyWave1Runtime(root)
        await relaunched.bootstrap()
        // Bootstrap emits exactly one canonical app-wake signal. Everything
        // before it is restored continuity, rather than a synthetic reset.
        #expect((await relaunched.organismSnapshot()).signalCount == settled.organism.signalCount + 1)
    }

    @Test("reset clears the organism state durably instead of reporting a cosmetic refresh")
    func organismResetPersistsAnActuallyEmptyBaseline() async throws {
        let root = try mindReportsOnlyWave1Root("organism-reset")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindReportsOnlyWave1Runtime(root)
        await runtime.bootstrap()
        await runtime.organismKernel.ingest(SomaticSignal(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            kind: .providerFailed,
            sourceOrgan: "wave1",
            occurredAt: mindReportsOnlyWave1Time,
            intensity: 1
        ))
        try #require((await runtime.organismSnapshot()).signalCount > 0)

        let reset = await CognitionObservatoryActions.resetBody(runtime: runtime)
        #expect(reset.organism.signalCount == 0)
        #expect(reset.organism.fieldSummary == .empty)
        let relaunched = mindReportsOnlyWave1Runtime(root)
        await relaunched.bootstrap()
        // The persisted reset baseline has no lived signal. Relaunch then adds
        // exactly its one app-wake event, proving the earlier failure did not
        // leak back through persistence.
        #expect((await relaunched.organismSnapshot()).signalCount == 1)
    }

    @Test("reflex controls fail closed when the body is off or candidate identity is absent")
    func reflexControlsCannotClaimAnUnappliedReview() async throws {
        let disabledRoot = try mindReportsOnlyWave1Root("reflex-disabled")
        let enabledRoot = try mindReportsOnlyWave1Root("reflex-missing")
        defer {
            try? FileManager.default.removeItem(at: disabledRoot)
            try? FileManager.default.removeItem(at: enabledRoot)
        }
        let disabled = mindReportsOnlyWave1Runtime(disabledRoot, organismEnabled: false)
        await disabled.bootstrap()
        let disabledReview = await CognitionObservatoryActions.reviewReflex(
            runtime: disabled,
            id: "candidate", decision: .approve, note: "negative", reviewedBy: "eval", source: "wave1"
        )
        #expect(disabledReview.outcome.status == .organismDisabled)
        #expect(disabledReview.outcome.receipt == nil)

        let enabled = mindReportsOnlyWave1Runtime(enabledRoot)
        await enabled.bootstrap()
        let missingReview = await CognitionObservatoryActions.reviewReflex(
            runtime: enabled,
            id: "candidate", decision: .retire, note: "negative", reviewedBy: "eval", source: "wave1"
        )
        #expect(missingReview.outcome.status == .candidateNotFound)
        #expect(missingReview.outcome.receipt == nil)
        #expect(missingReview.detail.organism.reflexCandidates.isEmpty)
    }

    @Test("panel presentation distinguishes unavailable body state, seed truncation, and evidence from fabricated conviction")
    func panelPresentationDoesNotInventHealthyLookingValues() async throws {
        let disabled = OrganismSnapshot(
            generatedAt: mindReportsOnlyWave1Time,
            enabled: false,
            chemicalState: .neutral,
            bodySchema: .neutral,
            signalCount: 0,
            lastSignalAt: nil
        )
        #expect(CognitionObservatoryPresentation.organismIsUnavailable(disabled))
        #expect(CognitionObservatoryPresentation.thoughtSeedOverflowLabel(total: 8) == nil)
        #expect(CognitionObservatoryPresentation.thoughtSeedOverflowLabel(total: 9) == "Showing 8 of 9 thought seeds.")

        for evidenceCount in [0, 1, 5, 20] {
            let view = CognitiveStandingView(
                id: UUID(), title: "view", body: "body", status: .active,
                moodValenceAtFormation: 0,
                evidenceNodeIds: (0..<evidenceCount).map { _ in UUID() },
                createdAt: mindReportsOnlyWave1Time,
                updatedAt: mindReportsOnlyWave1Time
            )
            let label = CognitionObservatoryPresentation.standingViewStatus(view)
            #expect(label.contains("\(evidenceCount) felt moments"))
            #expect(!label.localizedCaseInsensitiveContains("conviction"))
        }
    }

    @Test("checked body mutations restore the durable baseline when their writer refuses")
    func checkedBodyMutationsNeverClaimAnUnpersistedReset() async throws {
        let root = try mindReportsOnlyWave1Root("checked-body-refusal")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MindReportsOnlyWave1FailingOrganismWriter()
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .enabled,
            now: { mindReportsOnlyWave1Time },
            monotonicNowNanoseconds: { 42 },
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false,
            organismPersistenceWriterOverride: { state, url in
                try await writer.write(state, to: url)
            }
        )
        await runtime.bootstrap()
        await runtime.organismKernel.ingest(SomaticSignal(
            id: UUID(), kind: .providerFailed, sourceOrgan: "writer-refusal",
            occurredAt: mindReportsOnlyWave1Time, intensity: 1
        ))
        let before = await runtime.organismSnapshot()
        try #require(before.signalCount > 0)

        let reset = await CognitionObservatoryActions.resetBodyChecked(runtime: runtime)
        #expect(reset.outcome.status == .persistenceFailed)
        #expect(reset.detail.organism.signalCount == before.signalCount,
                "a refused reset must render the restored state, not an empty cosmetic baseline")
        await MainActor.run {
            let toasts = SystemToastCenter()
            CognitionObservatoryControlFeedback.publish(reset.outcome, action: "reset", to: toasts)
            #expect(toasts.queue.last?.kind == .error)
            #expect(toasts.queue.last?.text.localizedCaseInsensitiveContains("previous organism state was restored") == true)
        }

        let settle = await CognitionObservatoryActions.settleBodyChecked(runtime: runtime)
        #expect(settle.outcome.status == .persistenceFailed)
        #expect(settle.detail.organism.signalCount == before.signalCount)
    }

    @Test("proposal action reports a concurrent second review instead of treating its redraw as success")
    func proposalActionReportsAlreadyResolvedCandidate() async throws {
        let root = try mindReportsOnlyWave1Root("proposal-action-race")
        let rejectRoot = try mindReportsOnlyWave1Root("proposal-action-reject")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: rejectRoot) }
        let (runtime, proposal) = try await mindReportsOnlyWave1SeedReflection(
            root: root,
            eventID: "proposal-action-race",
            response: "view: Review must name the durable outcome it saved."
        )

        let approved = await CognitionProposalActions.resolveWithOutcome(
            runtime: runtime, id: proposal.id, approved: true
        )
        #expect(approved.status == .applied(.active))
        let secondClick = await CognitionProposalActions.resolveWithOutcome(
            runtime: runtime, id: proposal.id, approved: false
        )
        guard case .unavailable(let message) = secondClick.status else {
            Issue.record("a second review cannot be reported as a saved rejection")
            return
        }
        #expect(message.contains("no longer awaiting review"))
        #expect(secondClick.detail.standingViews.first { $0.id == proposal.id }?.status == .active)

        let (rejectRuntime, rejectProposal) = try await mindReportsOnlyWave1SeedReflection(
            root: rejectRoot,
            eventID: "proposal-action-reject",
            response: "view: A rejected proposal must leave the actionable feed."
        )
        let rejected = await CognitionProposalActions.resolveWithOutcome(
            runtime: rejectRuntime, id: rejectProposal.id, approved: false
        )
        #expect(rejected.status == .applied(.retired))
        #expect((await CognitionProposalsFeed.pending(runtime: rejectRuntime)).standingViews.isEmpty,
                "both Activity and the full proposal screen draw from this pending feed")
    }

    @Test("manual Reflect returns its typed gate denial and durable skip receipt together")
    func manualReflectReportsTheRuntimeGateOutcome() async throws {
        let root = try mindReportsOnlyWave1Root("manual-reflect-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = CognitiveConfiguration.allPhasesEnabled
        configuration.reflectiveCallsEnabled = false
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration,
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )

        let result = await CognitionObservatoryActions.reflectWithOutcome(runtime: runtime)
        guard case .skipped(let reason) = result.status else {
            Issue.record("an unavailable manual reflection must return a typed skip, got \(String(describing: result.status))")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("reflection is disabled"))
        let receipt = try #require(result.detail.receipts.first { $0.kind == "reflection.skipped" })
        guard case .object(let payload) = receipt.payload else {
            Issue.record("manual reflection skip lost its durable payload")
            return
        }
        #expect(payload["status"] == .string("gate_denied"))
        await MainActor.run {
            let toasts = SystemToastCenter()
            CognitionObservatoryControlFeedback.publish(result.status, to: toasts)
            #expect(toasts.queue.last?.kind == .info)
            #expect(toasts.queue.last?.text.localizedCaseInsensitiveContains("reflection skipped") == true)
        }
    }

    @Test("approve and retire reflex reviews persist their exact visible candidate outcome")
    func reflexReviewsCommitAndSurviveRelaunch() async throws {
        func makeRuntime(_ root: URL, id: String) async -> NativeCognitionRuntime {
            let runtime = mindReportsOnlyWave1Runtime(root)
            await runtime.bootstrap()
            let candidate = OrganismReflexCandidate(
                id: id,
                pattern: "A low-risk durable reflex",
                trustClass: .lowRisk,
                evidenceCount: 4,
                successCount: 4,
                confidence: 0.8,
                firstSeenAt: mindReportsOnlyWave1Time,
                lastUpdatedAt: mindReportsOnlyWave1Time
            )
            await runtime.organismKernel.restorePersistentState(OrganismPersistentState(
                savedAt: mindReportsOnlyWave1Time,
                reflexState: OrganismReflexState(candidates: [id: candidate])
            ))
            return runtime
        }

        let approveRoot = try mindReportsOnlyWave1Root("reflex-approve")
        let retireRoot = try mindReportsOnlyWave1Root("reflex-retire")
        defer {
            try? FileManager.default.removeItem(at: approveRoot)
            try? FileManager.default.removeItem(at: retireRoot)
        }
        let approveRuntime = await makeRuntime(approveRoot, id: "approve")
        let approved = await CognitionObservatoryActions.reviewReflex(
            runtime: approveRuntime, id: "approve", decision: .approve,
            note: "approved", reviewedBy: "eval", source: "mac_observatory"
        )
        #expect(approved.outcome.applied)
        #expect(approved.outcome.receipt?.source == "mac_observatory")
        #expect(approved.detail.organism.reflexCandidates.first?.autoActivationAllowed == true)
        let approveReload = mindReportsOnlyWave1Runtime(approveRoot)
        await approveReload.bootstrap()
        #expect((await approveReload.organismSnapshot()).reflexCandidates.first?.autoActivationAllowed == true)

        let retireRuntime = await makeRuntime(retireRoot, id: "retire")
        let retired = await CognitionObservatoryActions.reviewReflex(
            runtime: retireRuntime, id: "retire", decision: .retire,
            note: "retired", reviewedBy: "eval", source: "mac_observatory"
        )
        #expect(retired.outcome.applied)
        #expect(retired.outcome.receipt?.decision == .retire)
        #expect(retired.detail.organism.reflexCandidates.isEmpty,
                "a retired candidate must leave the observable candidate set")
        let retireReload = mindReportsOnlyWave1Runtime(retireRoot)
        await retireReload.bootstrap()
        let restoredRetire = await retireReload.organismSnapshot()
        #expect(restoredRetire.reflexCandidates.isEmpty)
        #expect(restoredRetire.reflexReviewReceipts.first?.decision == .retire)
    }
}

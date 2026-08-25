// EVAL COVERAGE — canonical behavior seams for the remaining Desk / Mind UI
// rows. These tests deliberately do not inspect a SwiftUI body: each starts at
// the store/runtime a visible control calls and proves the durable state the
// following render must read. Every root is fresh and removed at the end.
//
// Desk rows: desk.board.sequencingPills, desk.board.blockerPillNavigation,
// desk.board.freshnessChip, desk.action.optimisticRollback, desk.nag.bellSymbol
// (the model states they render are real; view-only labels remain a strict-UI
// concern).
// Mind rows: ui.cognitionProposals.action.approve,
// ui.cognitionProposals.action.reject, ui.cognitionProposals.standingViews,
// ui.cognitionObservatory.button.settleBody,
// ui.cognitionObservatory.button.resetBody.

import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

private func canonicalEvalRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskMindCanonicalEval-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func canonicalMindRuntime(dataRoot: URL) -> NativeCognitionRuntime {
    NativeCognitionRuntime(
        dataRoot: dataRoot,
        configurationOverride: .allPhasesEnabled,
        organismConfigurationOverride: .enabled,
        microcycleSchedulingMode: .manuallyFlushed,
        installedPhysiologySoakEnabled: false
    )
}

private struct OneStandingViewLLM: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        "I keep returning to verification as a source of trust.\nview: Verified outcomes matter more than confident completion claims."
    }
}

private func seedStandingView(
    dataRoot: URL,
    id: String
) async throws -> (runtime: NativeCognitionRuntime, viewID: UUID) {
    let personaRoot = dataRoot.appendingPathComponent("persona", isDirectory: true)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try "# Test identity\n\nStay grounded in verified outcomes."
        .write(to: personaRoot.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
    let runtime = canonicalMindRuntime(dataRoot: dataRoot)
    await runtime.bootstrap()
    await runtime.observe(CognitiveEvent(
        id: id,
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "conversation", id: id),
        sourceClass: .userStated,
        occurredAt: Date(),
        summary: "Please keep the outcome proof honest.",
        importance: 0.9,
        turnKind: .live
    ))
    let outcome = await runtime.runReflectionIfDue(
        llm: OneStandingViewLLM(), reason: "form one reviewable standing view")
    let substrate = await runtime.substrateForIntegration()
    let views = await substrate.standingViewSnapshot()
    guard case .completed = outcome,
          let viewID = views.first(where: { $0.status == .proposed })?.id
    else {
        throw NSError(domain: "DeskMindCanonicalBehaviorEval", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "runtime did not form expected standing view: \(outcome)"])
    }
    return (runtime, viewID)
}

@Suite("Desk and Mind canonical behavior evals", .serialized)
struct DeskMindCanonicalBehaviorEvalTests {

    @Test("Desk sequencing reflects durable blockers and parks without a background repair")
    func deskSequencingReflectsStoreTransitions() async throws {
        let root = try canonicalEvalRoot("desk-sequencing")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let prerequisite = try await store.createItem(
            kind: .plan, project: "Release", title: "Prove the receipt")
        let dependent = try await store.createItem(
            kind: .plan, project: "Release", title: "Install the build")
        try await store.setBlockedOn(dependent.handle, blockers: [prerequisite.handle])

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = try await store.liveState()
        var plan = DeskSequencing.compute(state, now: now)
        let blocked = try #require(plan.byHandle[dependent.handle])
        #expect(blocked.effectiveBlockers == [prerequisite.handle])
        #expect(!blocked.isReady, "a live blocker must keep the card out of Next up")

        // Closing the blocker changes only canonical Desk state. The next read
        // must auto-unblock; no optimistic UI echo or background repair is
        // allowed to invent that transition.
        try await store.setStatus(prerequisite.handle, status: .done)
        state = try await store.liveState()
        plan = DeskSequencing.compute(state, now: now)
        let unblocked = try #require(plan.byHandle[dependent.handle])
        #expect(unblocked.effectiveBlockers.isEmpty)
        #expect(unblocked.isReady, "a terminal blocker must not leave a stale blocked pill")

        try await store.setDeferUntil(dependent.handle, until: "2030-01-01")
        state = try await store.liveState()
        plan = DeskSequencing.compute(state, now: now)
        let parked = try #require(plan.byHandle[dependent.handle])
        #expect(parked.isDeferred)
        #expect(!parked.isReady, "a deliberate park must not be presented as fresh actionable work")

        await #expect(throws: DeskError.deferUntilUnparseable(
            handle: dependent.handle, value: "when it feels right"
        )) {
            try await store.setDeferUntil(dependent.handle, until: "when it feels right")
        }
        let afterRefusal = try await store.liveState()
        #expect(afterRefusal.items.first { $0.handle == dependent.handle }?.deferUntil == "2030-01-01",
                "a refused park must preserve the previously rendered canonical state")

        try await store.setDeferUntil(dependent.handle, until: nil)
        let cleared = DeskSequencing.compute(try await store.liveState(), now: now)
        #expect(cleared.byHandle[dependent.handle]?.isReady == true)
    }

    @Test("Desk nag state persists a real off, mute, and re-armed window")
    func deskNagStateRoundTripsWithoutConflatingMutedAndOff() async throws {
        let root = try canonicalEvalRoot("desk-nags")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeskNagConfigStore(dataRoot: root)
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

        let fresh = await store.load()
        #expect(!fresh.enabled)
        #expect(fresh.mutedUntil == nil)
        #expect(!FileManager.default.fileExists(atPath: store.configPath.path),
                "reading a fresh Desk must not fabricate a nag preference")

        let enabled = try await store.update { config in
            config
                .settingScope(kind: .project, id: "Release", enabled: true)
                .settingGlobal(true)
        }
        #expect(enabled.enabled)
        #expect(enabled.scopeEnabled(for: DeskItem(
            handle: "desk_release", alias: "1", kind: .plan, project: "release",
            title: "Ship", openedAt: "2027-01-01T00:00:00Z", updatedAt: "2027-01-01T00:00:00Z")))

        let muted = try await store.update { $0.muted(until: nil) }
        #expect(muted.enabled, "muted is distinct from globally off")
        #expect(muted.isMuted(now: fixedNow))
        #expect(muted.mutedUntil == DeskNagConfig.indefiniteMuteSentinel)

        let restored = try await store.update { $0.unmuted() }
        #expect(restored.enabled)
        #expect(!restored.isMuted(now: fixedNow))
        #expect(restored.windowId == muted.windowId + 1,
                "unmute must re-arm one new attention window, not silently reuse the old ledger")
        #expect(await store.load() == restored, "the next render must read the state the action committed")
    }

    @Test("standing-view approval and rejection leave distinct durable, reviewable outcomes")
    func standingViewDecisionsAreOneWayAndVisibleInRuntimeDetail() async throws {
        let approvalRoot = try canonicalEvalRoot("standing-view-approve")
        let rejectionRoot = try canonicalEvalRoot("standing-view-reject")
        defer {
            try? FileManager.default.removeItem(at: approvalRoot)
            try? FileManager.default.removeItem(at: rejectionRoot)
        }
        let approval = try await seedStandingView(
            dataRoot: approvalRoot, id: "standing-view-approval")
        let rejection = try await seedStandingView(
            dataRoot: rejectionRoot, id: "standing-view-rejection")

        await approval.runtime.resolveStandingView(id: approval.viewID, approved: true)
        await rejection.runtime.resolveStandingView(id: rejection.viewID, approved: false)
        let approvedDetail = await approval.runtime.observatoryDetail()
        let rejectedDetail = await rejection.runtime.observatoryDetail()
        #expect(approvedDetail.standingViews.first { $0.id == approval.viewID }?.status == .active,
                "Approve must create an active lens, not merely remove an action button")
        #expect(rejectedDetail.standingViews.first { $0.id == rejection.viewID }?.status == .retired,
                "Reject must preserve an explicit retired outcome, not silently delete history")

        // Decisions are proposal-shaped: a later click cannot reverse a prior
        // recorded outcome under the same id.
        await approval.runtime.resolveStandingView(id: approval.viewID, approved: false)
        let final = await approval.runtime.observatoryDetail()
        #expect(final.standingViews.first { $0.id == approval.viewID }?.status == .active)
    }

    @Test("organism settle decays a lived body and reset writes the empty baseline")
    func organismSettleAndResetDoNotReportTheSameOutcome() async throws {
        let root = try canonicalEvalRoot("organism")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = canonicalMindRuntime(dataRoot: root)
        await runtime.bootstrap()
        let stateURL = root
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("organism_state.json")

        // Give the kernel real, non-neutral turn evidence. The observable
        // runtime route (rather than a kernel-only fixture) is exactly what
        // the Observatory buttons share.
        for index in 0..<3 {
            await runtime.observeTurnMessage(
                surface: "chat", role: "user", text: "I need a careful release check \(index).",
                sessionId: "organism-eval", messageId: "u-\(index)"
            )
            await runtime.observeAssistantTurnCompleted(
                surface: "chat", text: "I will verify the outcome \(index).",
                sessionId: "organism-eval", messageId: "a-\(index)"
            )
        }
        // A typed operational failure is the real organism input that raises
        // vigilance. It uses the runtime's resident kernel, not a stand-alone
        // kernel fixture, so the settle/reset controls operate on this exact
        // same state.
        await runtime.organismKernel.ingest(SomaticSignal(
            id: UUID(), kind: .providerFailed, sourceOrgan: "eval",
            occurredAt: Date(), intensity: 1
        ))
        let lived = await runtime.organismSnapshot()
        #expect(lived.signalCount > 0, "the settle assertion needs an actual lived body")
        #expect(lived.chemicalState.vigilance > ChemicalState.neutral.vigilance)

        let settled = await runtime.settleOrganismContinuity()
        #expect(settled.enabled)
        #expect(settled.signalCount == lived.signalCount,
                "settling must decay continuity, not silently discard the body")
        #expect(settled.chemicalState.vigilance < lived.chemicalState.vigilance,
                "the settle action must move live chemistry toward rest")
        #expect(FileManager.default.fileExists(atPath: stateURL.path),
                "settling must persist the state that the next launch will read")

        let reset = await runtime.resetOrganismContinuity()
        #expect(reset.signalCount == 0, "reset must clear the signal/field history, not only its visible label")
        #expect(reset.chemicalState == .neutral)
        #expect(reset.fieldSummary == .empty)
        #expect(reset.predictionSummary == .empty)
        #expect(FileManager.default.fileExists(atPath: stateURL.path),
                "reset must write a new empty baseline so relaunch cannot resurrect the old body")
    }
}

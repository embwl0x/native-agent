import CognitiveSubstrate
import Context
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

private enum Wave8ReceiptWriteFailure: Error, Sendable {
    case refused
}

private actor Wave8ReflexReviewFaults {
    private var continuityFailuresRemaining: Int
    private var successfulContinuityWritesBeforeFailure: Int
    private var receiptFailuresRemaining: Int
    private var continuityWriteStarted = false

    init(
        continuityFailures: Int = 0,
        successfulContinuityWritesBeforeFailure: Int = 0,
        receiptFailures: Int = 0
    ) {
        continuityFailuresRemaining = continuityFailures
        self.successfulContinuityWritesBeforeFailure = successfulContinuityWritesBeforeFailure
        receiptFailuresRemaining = receiptFailures
    }

    func writeOrganism(_ state: OrganismPersistentState, to url: URL) async throws {
        if successfulContinuityWritesBeforeFailure > 0 {
            successfulContinuityWritesBeforeFailure -= 1
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: url, options: .atomic)
            return
        }
        if continuityFailuresRemaining > 0 {
            continuityFailuresRemaining -= 1
            continuityWriteStarted = true
            try? await Task.sleep(for: .milliseconds(40))
            throw Wave8ReceiptWriteFailure.refused
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    func recordReceipt(_: UUID, _: String, _: JSONValue) throws {
        guard receiptFailuresRemaining > 0 else { return }
        receiptFailuresRemaining -= 1
        throw Wave8ReceiptWriteFailure.refused
    }

    func continuityStarted() -> Bool { continuityWriteStarted }
}

// EVAL — ledger fence core.substrate.organism, Wave 8.
//
// This follows the canonical chat-tool event shape through the normal runtime
// observer, somatic adapter, and organism producer, then uses the exact
// Observatory action. The relaunch is the persistence reader: a receipt that
// only exists in the actor's memory is not a successful review.

@Suite("Substrate organism Wave 8", .serialized)
struct SubstrateOrganismWave8EvalTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("substrate-organism-wave8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func successfulToolEvent(
        _ sequence: Int,
        domain: String = "wave8_safe",
        at date: Date
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: "wave8-tool-success-\(domain)-\(sequence)",
            kind: .toolSucceeded,
            subject: CognitiveSubjectReference(
                type: "motor_action",
                id: "\(domain)-action-\(sequence)",
                label: domain
            ),
            sourceClass: .observed,
            occurredAt: date,
            summary: "The verified bounded tool action completed.",
            importance: 0.7,
            turnKind: .live,
            metadata: [
                "motorDomain": .string(domain),
                "motorActionIdentity": .string("\(domain)-action-\(sequence)"),
                "trustRisk": .string("low"),
                "verification": .string("satisfied"),
            ]
        )
    }

    private func runtime(
        root: URL,
        now: Date,
        preferenceDefaults: NativeCognitionPreferenceDefaults = .standard,
        organismConfigurationOverride: OrganismConfiguration? = .enabled,
        organismWriter: (@Sendable (OrganismPersistentState, URL) async throws -> Void)? = nil,
        receiptRecorder: (@Sendable (UUID, String, JSONValue) async throws -> Void)? = nil
    ) -> NativeCognitionRuntime {
        NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            preferenceDefaults: preferenceDefaults,
            organismConfigurationOverride: organismConfigurationOverride,
            now: { now },
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false,
            organismPersistenceWriterOverride: organismWriter,
            organismReflexReceiptRecorderOverride: receiptRecorder
        )
    }

    @MainActor
    private func waitFor(
        _ predicate: @MainActor @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<80 {
            if await predicate() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("an Observatory approve then retire acts on a normal-observe candidate and survives relaunch")
    func reflexReviewIsProducedAppliedRetiredAndRestored() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let now = Date(timeIntervalSince1970: 2_200_000_000)
        let first = runtime(root: dataRoot, now: now)
        await first.bootstrap()

        // The event shape is the canonical ChatOrchestration tool observer
        // contract. Each one enters through the normal runtime observer, not
        // a kernel fixture or direct candidate injection.
        for sequence in 0..<3 {
            await first.observe(successfulToolEvent(
                sequence,
                at: now.addingTimeInterval(Double(sequence + 1))
            ))
        }
        let candidate = try #require((await first.organismSnapshot()).reflexCandidates.first {
            $0.id == "tool:tool-wave8-safe"
        })
        #expect(candidate.trustClass == .lowRisk)
        #expect(candidate.reviewRequired)
        #expect(!candidate.autoActivationAllowed)
        #expect(candidate.evidenceCount == 3)

        let approved = await CognitionObservatoryActions.reviewReflex(
            runtime: first,
            id: candidate.id,
            decision: .approve,
            note: "three verified low-risk observations",
            reviewedBy: "operator",
            source: "mac_observatory"
        )
        #expect(approved.outcome.status == .applied)
        let receipt = try #require(approved.outcome.receipt)
        #expect(receipt.candidateID == candidate.id)
        #expect(receipt.decision == .approve)
        #expect(receipt.reviewedBy == "operator")
        #expect(receipt.source == "mac_observatory")
        #expect(receipt.autoActivationAllowed)
        #expect(approved.detail.organism.reflexCandidates.first { $0.id == candidate.id }?.autoActivationAllowed == true)

        let duplicateApprove = await CognitionObservatoryActions.reviewReflex(
            runtime: first,
            id: candidate.id,
            decision: .approve,
            note: "Duplicate approval must be inert",
            reviewedBy: "operator",
            source: "mac_observatory"
        )
        #expect(duplicateApprove.outcome.status == .notAwaitingReview)
        #expect(duplicateApprove.outcome.receipt == nil)
        #expect(duplicateApprove.detail.organism.reflexReviewReceipts.count == 1)

        for sequence in 0..<3 {
            await first.observe(successfulToolEvent(
                sequence,
                domain: "wave8_retire",
                at: now.addingTimeInterval(Double(sequence + 10))
            ))
        }
        let retireCandidate = try #require((await first.organismSnapshot()).reflexCandidates.first {
            $0.id == "tool:tool-wave8-retire"
        })
        let retired = await CognitionObservatoryActions.reviewReflex(
            runtime: first,
            id: retireCandidate.id,
            decision: .retire,
            note: "Retired from Cognition Observatory",
            reviewedBy: "operator",
            source: "mac_observatory"
        )
        #expect(retired.outcome.status == .applied)
        let retireReceipt = try #require(retired.outcome.receipt)
        #expect(retireReceipt.decision == .retire)
        #expect(!retireReceipt.autoActivationAllowed)
        // Retired candidates remain in continuity for audit, but are excluded
        // from the active candidate summary and review surface.
        #expect(retired.detail.organism.reflexSummary.candidateCount == 1)
        #expect(retired.detail.organism.reflexSummary.reviewRequiredCount == 0)
        #expect(retired.detail.organism.reflexSummary.approvedLowRiskCount == 1)

        // A missing candidate must remain distinguishable from both applied
        // actions so the control cannot quietly present a no-op as success.
        let beforeMissing = retired.detail.organism.reflexReviewReceipts.count
        let missing = await CognitionObservatoryActions.reviewReflex(
            runtime: first,
            id: "no-such-reflex",
            decision: .retire,
            note: "Retired from Cognition Observatory",
            reviewedBy: "operator",
            source: "mac_observatory"
        )
        #expect(missing.outcome.status == .candidateNotFound)
        #expect(missing.outcome.receipt == nil)
        #expect(missing.detail.organism.reflexReviewReceipts.count == beforeMissing)

        let stateURL = dataRoot
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("organism_state.json")
        #expect(FileManager.default.fileExists(atPath: stateURL.path))

        // The second runtime is the normal restore reader used after restart.
        let relaunched = runtime(root: dataRoot, now: now.addingTimeInterval(60))
        await relaunched.bootstrap()
        let restoredSnapshot = await relaunched.organismSnapshot()
        #expect(restoredSnapshot.reflexSummary.candidateCount == 1)
        #expect(restoredSnapshot.reflexSummary.reviewRequiredCount == 0)
        #expect(restoredSnapshot.reflexSummary.approvedLowRiskCount == 1)
        let restoredReceipts = restoredSnapshot.reflexReviewReceipts
        #expect(restoredReceipts.count == 2)
        #expect(restoredReceipts.contains { $0.id == receipt.id && $0.decision == .approve })
        #expect(restoredReceipts.contains { $0.id == retireReceipt.id && $0.decision == .retire })
    }

    @Test("Observatory organism controls and review actions reach their injected runtime")
    func organismControlsAndReviewActionsReachInjectedRuntime() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let suite = "NativeAgentTests.Wave8Reflex.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "organismKernelEnabled")
        let now = Date(timeIntervalSince1970: 2_200_000_100)
        let resident = runtime(
            root: dataRoot,
            now: now,
            preferenceDefaults: NativeCognitionPreferenceDefaults(defaults: defaults),
            organismConfigurationOverride: nil
        )
        await resident.bootstrap()

        let initiallyOn = CognitionObservatoryOrganismControlPresentation(
            cognitiveSubstrateEnabled: true,
            organismKernelEnabled: true
        )
        #expect(initiallyOn.isEnabled)
        #expect(initiallyOn.isOn)
        await resident.setOrganismKernelEnabled(false)
        let disabledSnapshot = await resident.organismSnapshot()
        #expect(!disabledSnapshot.enabled)
        #expect(CognitionObservatoryOrganismPresentation(snapshot: disabledSnapshot, now: now).state
            == .disabled("Organism body kernel is off — no live body readout is available."))
        let disabledControl = CognitionObservatoryOrganismControlPresentation(
            cognitiveSubstrateEnabled: true,
            organismKernelEnabled: disabledSnapshot.enabled
        )
        #expect(disabledControl.isEnabled)
        #expect(!disabledControl.isOn)

        await resident.setOrganismKernelEnabled(true)
        let enabledSnapshot = await resident.organismSnapshot()
        #expect(enabledSnapshot.enabled)
        #expect(CognitionObservatoryOrganismPresentation(snapshot: enabledSnapshot, now: now).state == .live)

        for sequence in 0..<3 {
            await resident.observe(successfulToolEvent(
                sequence,
                domain: "mounted_approve",
                at: now.addingTimeInterval(Double(sequence + 1))
            ))
        }
        let approveCandidate = try #require((await resident.organismSnapshot()).reflexCandidates.first {
            $0.id == "tool:tool-mounted-approve"
        })
        let approved = await CognitionObservatoryActions.reviewReflex(
            runtime: resident,
            id: approveCandidate.id,
            decision: .approve,
            note: "Approved from Cognition Observatory",
            reviewedBy: "operator",
            source: "mac_observatory"
        )
        #expect(approved.outcome.status == .applied)
        #expect(approved.detail.organism.reflexReviewReceipts.count == 1)
        #expect(approved.detail.organism.reflexCandidates.first(where: { $0.id == approveCandidate.id })?.autoActivationAllowed == true)

        for sequence in 0..<3 {
            await resident.observe(successfulToolEvent(
                sequence,
                domain: "mounted_retire",
                at: now.addingTimeInterval(Double(sequence + 10))
            ))
        }
        let retireCandidate = try #require((await resident.organismSnapshot()).reflexCandidates.first {
            $0.id == "tool:tool-mounted-retire"
        })
        let retired = await CognitionObservatoryActions.reviewReflex(
            runtime: resident,
            id: retireCandidate.id,
            decision: .retire,
            note: "Retired from Cognition Observatory",
            reviewedBy: "operator",
            source: "mac_observatory"
        )
        #expect(retired.outcome.status == .applied)
        #expect(retired.detail.organism.reflexReviewReceipts.count == 2)
        #expect(retired.detail.organism.reflexSummary.reviewRequiredCount == 0)
        #expect(retired.detail.organism.reflexSummary.approvedLowRiskCount == 1)
    }

    @Test("a journal rolls a reflex review forward through continuity and receipt failures without losing other signals")
    func reflexReviewJournalRecoversAcrossBothStoresWithoutRollingBackUnrelatedIngest() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let now = Date(timeIntervalSince1970: 2_200_000_200)
        let seeded = runtime(root: dataRoot, now: now)
        await seeded.bootstrap()
        for sequence in 0..<3 {
            await seeded.observe(successfulToolEvent(
                sequence,
                domain: "journal_review",
                at: now.addingTimeInterval(Double(sequence + 1))
            ))
        }
        #expect(await seeded.flushOrganismPersistenceForProof())

        let continuityFault = Wave8ReflexReviewFaults(
            continuityFailures: 1,
            // The injected writer is also used by this runtime's bootstrap
            // continuity checkpoint. Preserve that normal write plus the
            // review's required candidate-preparation write, then refuse the
            // reviewed-state write so the journal recovery path is exercised.
            successfulContinuityWritesBeforeFailure: 2
        )
        let failing = runtime(
            root: dataRoot,
            now: now,
            organismWriter: { state, url in
                try await continuityFault.writeOrganism(state, to: url)
            }
        )
        await failing.bootstrap()
        let candidate = try #require((await failing.organismSnapshot()).reflexCandidates.first {
            $0.id == "tool:tool-journal-review"
        })
        async let pendingReview = CognitionObservatoryActions.reviewReflex(
            runtime: failing,
            id: candidate.id,
            decision: .approve,
            note: "Journal this review until both stores acknowledge it.",
            reviewedBy: "operator",
            source: "mac_observatory"
        )
        #expect(await waitFor { await continuityFault.continuityStarted() })
        // This arrives while the review's first state write is suspended. A
        // stale rollback would erase it; a roll-forward journal must retain it.
        for sequence in 0..<3 {
            await failing.observe(successfulToolEvent(
                sequence,
                domain: "unrelated_during_review",
                at: now.addingTimeInterval(Double(sequence + 20))
            ))
        }
        let failed = await pendingReview
        #expect(failed.outcome.status == .persistenceFailed)
        #expect(failed.outcome.receipt == nil)
        #expect(await failing.flushOrganismPersistenceForProof())
        let beforeRelaunch = await failing.organismSnapshot()
        #expect(beforeRelaunch.reflexReviewReceipts.count == 1)
        #expect(beforeRelaunch.signalCount >= 6)
        #expect(beforeRelaunch.reflexCandidates.contains { $0.id == "tool:tool-unrelated-during-review" })

        let relaunched = runtime(root: dataRoot, now: now.addingTimeInterval(120))
        await relaunched.bootstrap()
        let restoredRead = await CognitionObservatoryActions.refreshRead(runtime: relaunched)
        #expect(restoredRead.evidenceStatus == .complete)
        let restored = restoredRead.detail
        #expect(restored.organism.reflexReviewReceipts.count == 1)
        #expect(restored.organism.reflexReviewReceipts.first?.candidateID == candidate.id)
        #expect(restored.organism.reflexCandidates.first { $0.id == candidate.id }?.autoActivationAllowed == true)
        #expect(restored.organism.reflexCandidates.contains { $0.id == "tool:tool-unrelated-during-review" })
        #expect(restored.receipts.filter { $0.kind == "organism.reflex_review" }.count == 1)

        // A receipt refusal is the other half of the same journal protocol:
        // it leaves no committed review until a later normal launch can write
        // the required cognitive receipt and then finish the organism state.
        let receiptRoot = try root()
        defer { try? FileManager.default.removeItem(at: receiptRoot) }
        let receiptSeed = runtime(root: receiptRoot, now: now)
        await receiptSeed.bootstrap()
        for sequence in 0..<3 {
            await receiptSeed.observe(successfulToolEvent(
                sequence,
                domain: "journal_receipt",
                at: now.addingTimeInterval(Double(sequence + 200))
            ))
        }
        #expect(await receiptSeed.flushOrganismPersistenceForProof())
        let receiptFault = Wave8ReflexReviewFaults(receiptFailures: 1)
        let receiptFailing = runtime(
            root: receiptRoot,
            now: now.addingTimeInterval(240),
            receiptRecorder: { id, kind, payload in
                try await receiptFault.recordReceipt(id, kind, payload)
            }
        )
        await receiptFailing.bootstrap()
        let receiptCandidate = try #require((await receiptFailing.organismSnapshot()).reflexCandidates.first {
            $0.id == "tool:tool-journal-receipt"
        })
        let receiptFailure = await CognitionObservatoryActions.reviewReflex(
            runtime: receiptFailing,
            id: receiptCandidate.id,
            decision: .approve,
            note: "Receipt fault must keep this journal pending.",
            reviewedBy: "operator",
            source: "mac_observatory"
        )
        #expect(receiptFailure.outcome.status == .persistenceFailed)
        let receiptRecovered = runtime(root: receiptRoot, now: now.addingTimeInterval(300))
        await receiptRecovered.bootstrap()
        let recoveredRead = await CognitionObservatoryActions.refreshRead(runtime: receiptRecovered)
        #expect(recoveredRead.evidenceStatus == .complete)
        let recovered = recoveredRead.detail
        #expect(recovered.organism.reflexReviewReceipts.count == 1)
        #expect(recovered.organism.reflexCandidates.first { $0.id == receiptCandidate.id }?.autoActivationAllowed == true)
        #expect(recovered.receipts.filter { $0.kind == "organism.reflex_review" }.count == 1)
    }
}

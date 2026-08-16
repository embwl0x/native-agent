import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

private func reflexSignal(
    _ kind: SomaticSignalKind,
    sourceOrgan: String = "tool.search",
    canonicalRisk: String = "low",
    id: UUID = UUID(uuidString: "52000000-0000-0000-0000-000000000001")!,
    at date: Date = Date(timeIntervalSince1970: 5_000)
) -> SomaticSignal {
    SomaticSignal(
        id: id,
        kind: kind,
        sourceOrgan: sourceOrgan,
        occurredAt: date,
        intensity: 1,
        metadata: ["trustRisk": .string(canonicalRisk)]
    )
}

@Test func repeatedSuccessesCreateReviewCandidate() async throws {
    let date = Date(timeIntervalSince1970: 5_000)
    var state = OrganismReflexState.empty

    state = OrganismReflexCompiler.applying(signal: reflexSignal(.toolSucceeded, at: date), to: state)
    #expect(state.summary().candidateCount == 0)
    state = OrganismReflexCompiler.applying(signal: reflexSignal(.toolSucceeded, at: date.addingTimeInterval(1)), to: state)
    #expect(state.summary().candidateCount == 0)
    state = OrganismReflexCompiler.applying(signal: reflexSignal(.toolSucceeded, at: date.addingTimeInterval(2)), to: state)

    let summary = state.summary()
    let candidate = try #require(state.candidates["tool:tool-search"])
    #expect(summary.candidateCount == 1)
    #expect(summary.lowRiskCount == 1)
    #expect(summary.reviewRequiredCount == 1)
    #expect(summary.highestConfidence > 0.5)
    #expect(candidate.evidenceCount == 3)
    #expect(candidate.successCount == 3)
    #expect(candidate.failureCount == 0)
    #expect(candidate.reviewRequired)
    #expect(candidate.autoActivationAllowed == false)
}

@Test func failureLowersConfidenceForExistingCandidate() async throws {
    let date = Date(timeIntervalSince1970: 5_000)
    var state = OrganismReflexState.empty
    for offset in 0..<3 {
        state = OrganismReflexCompiler.applying(
            signal: reflexSignal(.toolSucceeded, at: date.addingTimeInterval(Double(offset))),
            to: state
        )
    }
    let before = try #require(state.candidates["tool:tool-search"])

    state = OrganismReflexCompiler.applying(
        signal: reflexSignal(.toolFailed, at: date.addingTimeInterval(10)),
        to: state
    )
    let after = try #require(state.candidates["tool:tool-search"])

    #expect(after.failureCount == 1)
    #expect(after.evidenceCount == 4)
    #expect(after.confidence < before.confidence)
    #expect(after.autoActivationAllowed == false)
}

@Test func highRiskReflexCannotAutoActivate() async throws {
    let date = Date(timeIntervalSince1970: 5_000)
    var state = OrganismReflexState.empty

    for offset in 0..<3 {
        state = OrganismReflexCompiler.applying(
            signal: reflexSignal(.toolSucceeded, sourceOrgan: "tool.shell", canonicalRisk: "critical", at: date.addingTimeInterval(Double(offset))),
            to: state
        )
    }
    let candidate = try #require(state.candidates["tool:tool-shell"])

    #expect(candidate.trustClass == .highRisk)
    #expect(candidate.reviewRequired)
    #expect(candidate.autoActivationAllowed == false)
    #expect(state.summary().highRiskCount == 1)
}

@Test func toolReflexRiskUsesCanonicalMetadataAndFailsClosedWhenMissing() throws {
    let date = Date(timeIntervalSince1970: 5_100)
    let medium = OrganismReflexCompiler.applying(
        signal: reflexSignal(
            .toolSucceeded,
            sourceOrgan: "tool.write-file",
            canonicalRisk: "medium",
            at: date
        ),
        to: .empty,
        limits: OrganismReflexLimits(minimumEvidenceForCandidate: 1)
    )
    #expect(medium.candidates["tool:tool-write-file"]?.trustClass == .confirmRequired)

    let missing = SomaticSignal(
        id: UUID(uuidString: "52000000-0000-0000-0000-000000000002")!,
        kind: .toolSucceeded,
        sourceOrgan: "tool.search",
        occurredAt: date,
        intensity: 1
    )
    let unknown = OrganismReflexCompiler.applying(
        signal: missing,
        to: .empty,
        limits: OrganismReflexLimits(minimumEvidenceForCandidate: 1)
    )
    #expect(unknown.candidates["tool:tool-search"]?.trustClass == .highRisk)
}

@Test func lowRiskReflexApprovalAllowsOnlyApprovedLowRiskActivation() async throws {
    let date = Date(timeIntervalSince1970: 5_000)
    var state = OrganismReflexState.empty

    for offset in 0..<3 {
        state = OrganismReflexCompiler.applying(
            signal: reflexSignal(.toolSucceeded, at: date.addingTimeInterval(Double(offset))),
            to: state
        )
    }

    state = state.reviewedCandidate(
        id: "tool:tool-search",
        decision: .approve,
        reviewedAt: date.addingTimeInterval(10),
        note: "safe observed path"
    )
    let approved = try #require(state.candidates["tool:tool-search"])
    #expect(approved.reviewRequired == false)
    #expect(approved.autoActivationAllowed == true)
    #expect(approved.approvedAt != nil)
    #expect(approved.reviewNote == "safe observed path")
    let approvalReceipt = try #require(state.reviewReceipts.last)
    #expect(approvalReceipt.decision == .approve)
    #expect(approvalReceipt.candidateID == "tool:tool-search")
    #expect(approvalReceipt.autoActivationAllowed)

    state = OrganismReflexCompiler.applying(
        signal: reflexSignal(.toolFailed, at: date.addingTimeInterval(20)),
        to: state
    )
    let failedAgain = try #require(state.candidates["tool:tool-search"])
    #expect(failedAgain.reviewRequired)
    #expect(failedAgain.autoActivationAllowed == false)
    #expect(failedAgain.approvedAt == nil)
}

@Test func holdKeepsCandidateInactiveAndAccruingWithAuditReceipt() async throws {
    let date = Date(timeIntervalSince1970: 5_000)
    var state = OrganismReflexState.empty
    for offset in 0..<3 {
        state = OrganismReflexCompiler.applying(
            signal: reflexSignal(.toolSucceeded, at: date.addingTimeInterval(Double(offset))),
            to: state
        )
    }

    let application = try #require(state.applyingReview(
        id: "tool:tool-search",
        decision: .hold,
        reviewedAt: date.addingTimeInterval(10),
        reviewedBy: "agent",
        source: "reflex_review:codex",
        note: "thin evidence",
        receiptID: "hold-receipt"
    ))
    state = application.state
    let held = try #require(state.candidates["tool:tool-search"])
    #expect(held.reviewRequired)
    #expect(!held.autoActivationAllowed)
    #expect(held.lastReviewDecision == .hold)
    #expect(application.receipt.reviewedBy == "agent")
    #expect(application.receipt.source == "reflex_review:codex")
    #expect(application.receipt.note == "thin evidence")

    state = OrganismReflexCompiler.applying(
        signal: reflexSignal(.toolSucceeded, at: date.addingTimeInterval(20)),
        to: state
    )
    #expect(state.candidates["tool:tool-search"]?.evidenceCount == 4)
    #expect(state.candidates["tool:tool-search"]?.reviewRequired == true)
    #expect(state.candidates["tool:tool-search"]?.autoActivationAllowed == false)
}

@Test func rejectMakesCandidatePermanentlyDeliberateAndNeverReproposes() async throws {
    let date = Date(timeIntervalSince1970: 5_000)
    var state = OrganismReflexCompiler.applying(
        signal: reflexSignal(.toolFailed, sourceOrgan: "tool.bash", canonicalRisk: "critical", at: date),
        to: .empty
    )
    let before = try #require(state.candidates["tool:tool-bash"])
    #expect(before.trustClass == .highRisk)

    let application = try #require(state.applyingReview(
        id: before.id,
        decision: .reject,
        reviewedAt: date.addingTimeInterval(1),
        reviewedBy: "agent",
        source: "reflex_review:codex",
        note: "arbitrary execution remains deliberate",
        receiptID: "reject-receipt"
    ))
    state = application.state
    let rejected = try #require(state.candidates[before.id])
    #expect(rejected.rejectedAt != nil)
    #expect(rejected.isPermanentlyDeliberate)
    #expect(!rejected.autoActivationAllowed)
    #expect(!rejected.reviewRequired)
    #expect(state.reviewCandidates().isEmpty)
    #expect(application.receipt.permanentlyDeliberate)

    for offset in 2..<12 {
        state = OrganismReflexCompiler.applying(
            signal: reflexSignal(.toolSucceeded, sourceOrgan: "tool.bash", canonicalRisk: "critical", at: date.addingTimeInterval(Double(offset))),
            to: state
        )
    }
    #expect(state.reviewCandidates().isEmpty)
    #expect(state.candidates[before.id]?.isPermanentlyDeliberate == true)
    #expect(state.candidates[before.id]?.autoActivationAllowed == false)
}

@Test func approvalFailsClosedForNonLowRiskCandidate() async throws {
    let date = Date(timeIntervalSince1970: 5_000)
    let state = OrganismReflexCompiler.applying(
        signal: reflexSignal(.toolFailed, sourceOrgan: "tool.bash", canonicalRisk: "critical", at: date),
        to: .empty
    )
    let application = state.applyingReview(
        id: "tool:tool-bash",
        decision: .approve,
        reviewedAt: date.addingTimeInterval(1),
        reviewedBy: "agent",
        source: "reflex_review:codex",
        receiptID: "unsafe-approval"
    )
    #expect(application == nil)
    #expect(state.reviewReceipts.isEmpty)
    #expect(state.candidates["tool:tool-bash"]?.autoActivationAllowed == false)
}

@Test func summaryClassifiesApprovedHeldAndRejectedCandidatesHonestly() async throws {
    let date = Date(timeIntervalSince1970: 5_000)
    let baseCandidates = [
        OrganismReflexCandidate(
            id: "approved",
            pattern: "Approved low-risk preference",
            trustClass: .lowRisk,
            evidenceCount: 4,
            successCount: 4,
            confidence: 0.7,
            firstSeenAt: date,
            lastUpdatedAt: date
        ),
        OrganismReflexCandidate(
            id: "held",
            pattern: "Held low-risk preference",
            trustClass: .lowRisk,
            evidenceCount: 4,
            successCount: 4,
            confidence: 0.7,
            firstSeenAt: date,
            lastUpdatedAt: date
        ),
        OrganismReflexCandidate(
            id: "rejected",
            pattern: "Rejected high-risk action",
            trustClass: .highRisk,
            evidenceCount: 4,
            successCount: 4,
            confidence: 0.7,
            firstSeenAt: date,
            lastUpdatedAt: date
        ),
    ]
    var state = OrganismReflexState(
        candidates: Dictionary(uniqueKeysWithValues: baseCandidates.map { ($0.id, $0) })
    )

    state = try #require(state.applyingReview(
        id: "approved",
        decision: .approve,
        reviewedAt: date.addingTimeInterval(1),
        reviewedBy: "test",
        source: "test",
        receiptID: "approved-receipt"
    )).state
    state = try #require(state.applyingReview(
        id: "held",
        decision: .hold,
        reviewedAt: date.addingTimeInterval(2),
        reviewedBy: "test",
        source: "test",
        receiptID: "held-receipt"
    )).state
    state = try #require(state.applyingReview(
        id: "rejected",
        decision: .reject,
        reviewedAt: date.addingTimeInterval(3),
        reviewedBy: "test",
        source: "test",
        receiptID: "rejected-receipt"
    )).state

    let summary = state.summary()
    #expect(summary.candidateCount == 2)
    #expect(summary.reviewRequiredCount == 1)
    #expect(summary.approvedLowRiskCount == 1)
    #expect(summary.lowRiskCount == 2)
    #expect(summary.highRiskCount == 0)
    #expect(summary.reviewReceiptCount == 3)
    #expect(state.candidates["approved"]?.autoActivationAllowed == true)
    #expect(state.candidates["approved"]?.reviewRequired == false)
    #expect(state.candidates["held"]?.autoActivationAllowed == false)
    #expect(state.candidates["held"]?.reviewRequired == true)
    #expect(state.candidates["rejected"]?.isPermanentlyDeliberate == true)
    #expect(state.candidates["rejected"]?.autoActivationAllowed == false)
    #expect(state.candidates["rejected"]?.reviewRequired == false)
    #expect(Set(state.reviewCandidates().map(\.id)) == Set(["approved", "held"]))
}

@Test func retiredReflexCandidateDropsFromReviewSnapshot() async throws {
    let date = Date(timeIntervalSince1970: 5_000)
    var state = OrganismReflexCompiler.applying(
        signal: reflexSignal(.providerFailed, sourceOrgan: "provider", at: date),
        to: .empty
    )

    state = state.reviewedCandidate(
        id: "provider:recovery",
        decision: .retire,
        reviewedAt: date.addingTimeInterval(1),
        note: "not a useful reflex"
    )

    #expect(state.summary().candidateCount == 0)
    #expect(state.summary().reviewRequiredCount == 0)
    #expect(state.reviewCandidates().isEmpty)
    #expect(state.candidates["provider:recovery"]?.retiredAt != nil)

    state = OrganismReflexCompiler.applying(
        signal: reflexSignal(.providerFailed, sourceOrgan: "provider", at: date.addingTimeInterval(2)),
        to: state
    )
    #expect(state.summary().candidateCount == 0)
    #expect(state.reviewCandidates().isEmpty)
    #expect(state.candidates["provider:recovery"]?.retiredAt != nil)
}

@Test func failedPatternPromotesImmediateReviewCandidate() async throws {
    let state = OrganismReflexCompiler.applying(
        signal: reflexSignal(.providerFailed, sourceOrgan: "provider"),
        to: .empty
    )
    let candidate = try #require(state.candidates["provider:recovery"])

    #expect(candidate.trustClass == .confirmRequired)
    #expect(candidate.evidenceCount == 1)
    #expect(candidate.failureCount == 1)
    #expect(candidate.reviewRequired)
    #expect(candidate.autoActivationAllowed == false)
}

@Test func disabledKernelKeepsReflexSummaryEmpty() async throws {
    let kernel = OrganismKernel(configuration: .disabled)

    await kernel.ingest(reflexSignal(.toolSucceeded))
    await kernel.ingest(reflexSignal(.toolSucceeded, at: Date(timeIntervalSince1970: 5_001)))
    await kernel.ingest(reflexSignal(.toolSucceeded, at: Date(timeIntervalSince1970: 5_002)))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.reflexSummary == .empty)
}

@Test func clearTransientStateClearsReflexCandidates() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let date = Date(timeIntervalSince1970: 5_000)

    await kernel.ingest(reflexSignal(.toolSucceeded, at: date))
    await kernel.ingest(reflexSignal(.toolSucceeded, at: date.addingTimeInterval(1)))
    await kernel.ingest(reflexSignal(.toolSucceeded, at: date.addingTimeInterval(2)))
    await kernel.clearTransientState()
    let snapshot = await kernel.snapshot()

    #expect(snapshot.reflexSummary == .empty)
}

@Test func enabledKernelDoesNotCompileRoutineGenericReviewCandidates() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let date = Date(timeIntervalSince1970: 5_000)

    await kernel.ingest(reflexSignal(
        .toolFailed,
        sourceOrgan: "tool.shell",
        canonicalRisk: "critical",
        at: date
    ))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.reflexSummary == .empty)
    #expect(snapshot.reflexCandidates.isEmpty)
}

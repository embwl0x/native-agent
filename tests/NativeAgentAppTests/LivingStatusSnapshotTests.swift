import Foundation
import Testing
import CognitiveSubstrate
import NativeAgentShared
import PersistenceCore
@testable import NativeAgentApp

private func livingOrganismSnapshot(
    enabled: Bool = true,
    chemicalState: ChemicalState = .neutral,
    bodySchema: BodySchema = BodySchema(iPhoneReachable: true),
    projectedBodyLine: String? = nil,
    fieldSummary: OrganismFieldSummary = .empty,
    dreamRepairSummary: OrganismDreamRepairSummary = .empty,
    reflexSummary: OrganismReflexSummary = .empty
) -> OrganismSnapshot {
    OrganismSnapshot(
        generatedAt: Date(timeIntervalSince1970: 6_000),
        enabled: enabled,
        chemicalState: chemicalState,
        bodySchema: bodySchema,
        fieldSummary: fieldSummary,
        dreamRepairSummary: dreamRepairSummary,
        reflexSummary: reflexSummary,
        projectedBodyLine: projectedBodyLine,
        signalCount: enabled ? 1 : 0,
        lastSignalAt: enabled ? Date(timeIntervalSince1970: 6_000) : nil
    )
}

@Test func livingStatusNeutralDisabledStateIsCalmAndHidesDetails() {
    let snapshot = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(enabled: false),
        activeDeskCount: 0,
        blockedDeskCount: 0,
        pendingApprovals: 0,
        latestDream: nil
    )

    #expect(snapshot.posture == "Quiet")
    #expect(snapshot.bodyState == "body kernel off")
    #expect(snapshot.needsText == "needs nothing")
    #expect(snapshot.showsOrganismDetails == false)
}

@Test func livingStatusNeedsUserOnlyForExplicitOwnerDecisionOrApproval() {
    let snapshot = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(),
        activeDeskCount: 3,
        blockedDeskCount: 1,
        ownerDecisionDeskCount: 1,
        pendingApprovals: 0,
        latestDream: DreamEntry(date: "2026-07-07", content: "private dream content")
    )

    #expect(snapshot.needsText == "needs you")
    #expect(snapshot.postureStatus == "warn")
    #expect(snapshot.deskSummary == "3 desk items, 1 blocked")
    #expect(snapshot.approvalsSummary == "no approvals pending")
    #expect(snapshot.whyLine == "Desk has work explicitly waiting on your decision.")
    #expect(snapshot.lastDreamSummary == "last dream 2026-07-07")
}

@Test func livingStatusKeepsGenericBlockedAndProviderTroubleOutOfNeedsUser() {
    let snapshot = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(
            bodySchema: BodySchema(iPhoneReachable: true, providersHealthy: false)
        ),
        activeDeskCount: 3,
        blockedDeskCount: 1,
        ownerDecisionDeskCount: 0,
        pendingApprovals: 0,
        latestDream: nil,
        agentDisplayName: "River"
    )

    #expect(snapshot.needsText == "no action needed")
    #expect(snapshot.postureStatus == "warn")
    #expect(snapshot.homeLine == "River is careful and does not need you.")
    #expect(snapshot.whyLine == "Provider or tool path is brittle, so completion claims tighten.")
    #expect(snapshot.deskSummary == "3 desk items, 1 blocked")
    #expect(snapshot.approvalsSummary == "no approvals pending")
}

@Test func livingStatusStillNeedsUserForCanonicalPendingApproval() {
    let snapshot = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(),
        activeDeskCount: 0,
        blockedDeskCount: 0,
        pendingApprovals: 1,
        latestDream: nil
    )

    #expect(snapshot.needsText == "needs you")
    #expect(snapshot.homeLine.contains("needs you"))
    #expect(snapshot.whyLine == "Waiting on approval before irreversible movement.")
}

@Test func livingStatusKeepsOptionalReviewsVisibleWithoutClaimingItNeedsUser() {
    let snapshot = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(),
        activeDeskCount: 0,
        blockedDeskCount: 0,
        pendingApprovals: 7,
        requiredApprovals: 0,
        latestDream: nil
    )

    #expect(snapshot.needsText == "needs nothing")
    #expect(snapshot.homeLine.contains("does not need you"))
    #expect(snapshot.approvalsSummary == "7 optional reviews")
    #expect(snapshot.whyLine == "Optional reviews are ready, but nothing is waiting on you.")
}

@Test func livingAttentionPolicySeparatesOptionalReviewsFromRequiredConsent() {
    func approval(action: String) -> ApprovalRequest {
        ApprovalRequest(
            id: UUID().uuidString,
            title: action,
            action: action,
            risk: "medium",
            status: "pending"
        )
    }
    let rows = [
        approval(action: "rem.proposal"),
        approval(action: "self_improvement.apply"),
        approval(action: "connector.external_send"),
    ]

    #expect(LivingAttentionPolicy.requiredApprovalCount(in: rows) == 1)
}

@Test func deskOwnerInputRequiresAnExactNonterminalWaitingParty() {
    let base = DeskItem(
        handle: "desk_fixture",
        alias: "1",
        kind: .project,
        status: .blocked,
        project: "Fixture",
        title: "Blocked verification",
        openedAt: "2026-07-15T00:00:00.000000+00:00",
        updatedAt: "2026-07-15T00:00:00.000000+00:00",
        blockedReason: "verification_failed",
        waitingOn: "domain verification"
    )
    var owner = base
    owner.waitingOn = " owner "
    var user = base
    user.waitingOn = "USER"
    var human = base
    human.waitingOn = "human"
    var terminal = owner
    terminal.status = .canceled

    #expect(base.requiresOwnerInput == false)
    #expect(owner.requiresOwnerInput)
    #expect(user.requiresOwnerInput)
    #expect(human.requiresOwnerInput)
    #expect(terminal.requiresOwnerInput == false)
    #expect(LivingAttentionPolicy.ownerDecisionDeskCount(in: [base, owner, terminal]) == 1)
}

@Test func livingStatusDoesNotCarryRawDreamOrDeskContent() {
    let snapshot = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(projectedBodyLine: "- Body: system posture feels integrated and steady."),
        activeDeskCount: 1,
        blockedDeskCount: 0,
        pendingApprovals: 0,
        latestDream: DreamEntry(date: "2026-07-07", content: "sensitive dream detail that should not display")
    )
    let visible = snapshot.visibleText.joined(separator: "\n").lowercased()

    #expect(!visible.contains("sensitive dream detail"))
    #expect(!visible.contains("should not display"))
    #expect(!visible.contains(FileManager.default.homeDirectoryForCurrentUser.path.lowercased()))
}

@Test func livingStatusSanitizesSecretLookingBodyLine() {
    let authMarker = ["bear", "er "].joined()
    let tokenMarker = ["to", "ken:"].joined()
    let keyMarker = ["sk", "fixture"].joined(separator: "-")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let snapshot = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(projectedBodyLine: "- Body: \(authMarker)\(tokenMarker) \(keyMarker) from \(home)/private"),
        activeDeskCount: 0,
        blockedDeskCount: 0,
        pendingApprovals: 0,
        latestDream: nil
    )

    #expect(snapshot.innerLine == "private body cue hidden")
}

@Test func livingStatusAvoidsPushNotificationAndRawChemicalText() {
    let snapshot = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(
            chemicalState: ChemicalState(vigilance: 0.6),
            bodySchema: BodySchema(iPhoneReachable: false, notificationPathHealthy: false)
        ),
        activeDeskCount: 0,
        blockedDeskCount: 0,
        pendingApprovals: 0,
        latestDream: nil
    )
    let visible = snapshot.visibleText.joined(separator: "\n").lowercased()

    #expect(snapshot.bodyState == "phone path stale")
    #expect(!visible.contains("notification"))
    #expect(!visible.contains("chemicalstate"))
    #expect(!visible.contains("vigilance"))
}

@Test func livingStatusExplainsQuietBodyAndCarriedState() {
    let snapshot = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(
            bodySchema: BodySchema(iPhoneReachable: true),
            fieldSummary: OrganismFieldSummary(nodeCount: 4),
            dreamRepairSummary: OrganismDreamRepairSummary(proposedStandingViews: 1),
            reflexSummary: OrganismReflexSummary(candidateCount: 2, reviewRequiredCount: 1, approvedLowRiskCount: 1)
        ),
        activeDeskCount: 0,
        blockedDeskCount: 0,
        pendingApprovals: 0,
        latestDream: nil
    )
    let visible = snapshot.visibleText.joined(separator: "\n").lowercased()

    #expect(snapshot.homeLine.contains("NativeAgent is"))
    #expect(snapshot.needsText == "no action needed")
    #expect(snapshot.whyLine == "NativeAgent has review work queued, but no user action is requested.")
    #expect(snapshot.carryLine.contains("approved biases"))
    #expect(visible.contains("dream proposals"))
}

@Test func livingStatusExplainsActiveSettledBodyWithoutCallingItPressure() {
    let snapshot = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(
            chemicalState: ChemicalState(warmth: 0.4, curiosity: 0.6),
            bodySchema: BodySchema(iPhoneReachable: true),
            projectedBodyLine: "- Body: settled and clear, curious."
        ),
        activeDeskCount: 0,
        blockedDeskCount: 0,
        pendingApprovals: 0,
        latestDream: nil
    )

    #expect(snapshot.whyLine == "Body line is active because the current state is shaping the turn.")
    #expect(!snapshot.whyLine.lowercased().contains("pressure"))
    #expect(snapshot.innerLine == "settled and clear, curious.")
}

@Test func livingStatusLeavesTiredPostureWhenSettledFatigueCrossesThreshold() {
    let tired = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(chemicalState: ChemicalState(fatigue: 0.36)),
        activeDeskCount: 0,
        blockedDeskCount: 0,
        pendingApprovals: 0,
        latestDream: nil
    )
    let rested = LivingStatusSnapshot.make(
        organism: livingOrganismSnapshot(
            chemicalState: ChemicalState(fatigue: 0.34, coherence: 0.8, confidence: 0.8)
        ),
        activeDeskCount: 0,
        blockedDeskCount: 0,
        pendingApprovals: 0,
        latestDream: nil
    )

    #expect(tired.posture == "Tired")
    #expect(tired.behaviorLine.contains("lightweightOnly"))
    #expect(rested.posture != "Tired")
    #expect(rested.behaviorLine.contains("tools normal"))
}

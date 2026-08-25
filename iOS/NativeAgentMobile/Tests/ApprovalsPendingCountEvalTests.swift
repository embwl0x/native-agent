import Foundation
import XCTest
import NativeAgentShared
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`, row `ios.approvals.store.pendingCount`.
///
/// Silent-failure class: SILENT ZERO. The Activity tab badge and the Approvals
/// list both count `status.lowercased() == "pending"`. Case drift on the Mac is
/// absorbed; a NEW status word is not — the badge silently reads 0 and a risky
/// action sits unapproved with nothing on screen asking for a decision.
///
/// The Mac's canonical status vocabulary is read off the Core source, so a new
/// word added there fails this eval instead of quietly zeroing the badge.
@MainActor
final class ApprovalsPendingCountEvalTests: XCTestCase {

    /// Coverage-ledger fence `ios.approvals.card.approveDeny`.
    /// The visible card emits `approve` and `deny`; pin their exact signed
    /// action routes and ensure a future stray label cannot become approve.
    func test_approvalCardVerbsResolveToTheirSafeSignedActions() {
        XCTAssertEqual(ApprovalDecisionRoute.resolve("approve"), .approve)
        XCTAssertEqual(ApprovalDecisionRoute.resolve("deny"), .reject)
        XCTAssertEqual(ApprovalDecisionRoute.resolve("deny")?.action, "reject")
        XCTAssertEqual(ApprovalDecisionRoute.resolve("deny")?.finalDecision, "denied")
        XCTAssertNil(
            ApprovalDecisionRoute.resolve("unexpected_card_verb"),
            "an unknown card decision must fail loudly instead of defaulting to approve"
        )
    }

    /// Coverage-ledger fence `ios.memory.segmentPicker`.
    /// The Activity deep-link owns a distinct initial segment from the root
    /// Memory tab; it must never be rebuilt as the default Memories screen.
    func test_activityMemoryProposalDestinationSelectsTheProposalsSegment() {
        XCTAssertEqual(
            ActivityScreenPresentation.memoryInitialSegment(for: .memoryProposals),
            .proposals
        )
        XCTAssertEqual(
            ActivityScreenPresentation.memoryInitialSegment(for: .approvals),
            .memories
        )
    }

    private static let macInboxPath = "Modules/NativeAgentCore/Sources/ApprovalInbox/ApprovalInbox.swift"

    /// The one status the phone treats as "needs a human". Anything the Mac adds
    /// beyond the list below must be triaged deliberately.
    private static let phoneCountsAsPending = "pending"
    private static let knownNonPendingStatuses: Set<String> = ["resolved", "denied", "canceled", "orphaned"]

    private func approval(_ id: String, status: String) -> PendingApproval {
        PendingApproval(
            id: id,
            title: "Run a risky thing",
            action: "shell",
            risk: "high",
            reason: nil,
            status: status,
            createdAt: "2026-08-23T12:00:00Z"
        )
    }

    func test_theMacStatusVocabularyStillSplitsExactlyOneWayForThePhone() throws {
        let source = try MobileEvalSources.repoFile(Self.macInboxPath)
        // The Mac's canonical allow-list literal — the authoritative vocabulary
        // the phone is counting against. Read it, never restate it.
        guard let listStart = source.range(of: "let validStatuses: Set<String> = ["),
              let listEnd = source.range(of: "]", range: listStart.upperBound..<source.endIndex) else {
            return XCTFail("could not locate the Mac's validStatuses allow-list in \(Self.macInboxPath)")
        }
        let macStatuses = Set(
            MobileEvalSources.matches(#""([a-z_]+)""#, in: String(source[listStart.upperBound..<listEnd.lowerBound]))
        )
        XCTAssertFalse(macStatuses.isEmpty, "parsed no statuses out of the Mac allow-list — parser drift")
        XCTAssertEqual(
            macStatuses, Self.knownNonPendingStatuses.union([Self.phoneCountsAsPending]),
            """
            The Mac's approval status vocabulary changed. ApprovalsStore.pendingCount counts exactly
            one word ("pending"); any NEW status meaning "a human still has to decide" silently reads
            as zero on the Activity badge. Triage the new word, then update this eval.
            """
        )

        let store = ApprovalsStore()
        for status in Self.knownNonPendingStatuses {
            store.approvals = [approval("a", status: status)]
            XCTAssertEqual(store.pendingCount, 0, "'\(status)' was counted as awaiting a human decision")
        }
        store.approvals = [approval("a", status: Self.phoneCountsAsPending)]
        XCTAssertEqual(store.pendingCount, 1)
    }

    func test_caseAndWhitespaceDriftOnTheWireDoesNotZeroTheBadge() {
        let store = ApprovalsStore()
        store.approvals = [
            approval("a", status: "Pending"),
            approval("b", status: "PENDING"),
            approval("c", status: "pending"),
        ]
        XCTAssertEqual(store.pendingCount, 3, "a capitalisation change on the Mac silently emptied the approvals badge")
    }

    func test_anUnknownStatusIsNotCountedAndThatIsTheDocumentedRisk() {
        // Pinned deliberately: the phone counts ONE word. This assertion is the
        // tripwire for anyone adding a new "awaiting" status on the Mac — the
        // badge would read 0 and this eval says why.
        let store = ApprovalsStore()
        store.approvals = [approval("a", status: "awaiting_human")]
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(store.approvals.count, 1, "the row itself is still listed — only the badge undercounts")
    }

    func test_anEmptySnapshotAndAnAllResolvedSnapshotAreBothZeroButNotTheSameThing() {
        let store = ApprovalsStore()
        store.approvals = []
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertTrue(store.approvals.isEmpty)

        store.approvals = [approval("a", status: "resolved"), approval("b", status: "denied")]
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(
            store.approvals.count, 2,
            "resolved history was dropped from the list, so 'nothing synced' and 'nothing pending' look identical"
        )
    }
}

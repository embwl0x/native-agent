import Foundation
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`.
///
/// Rows closed here:
///   * `ios.inbox.severityPresentation` — `sourceIcon` / `sourceBadgeLabel` are
///     ~12 hardcoded prefix matches; a Mac-side source rename silently downgrades
///     a card to the generic bell + a raw uppercased source string.
///   * `ios.inbox.groupFilter` — a related-group whose match rule is too broad
///     (or too narrow) turns the digest sheet into an empty-looking inbox.
///
/// Silent-failure class: WRONG VALUE / SILENT ZERO. Nothing throws when a badge
/// is wrong; the card just quietly stops looking like what it is.
final class InboxPresentationEvalTests: XCTestCase {

    private func item(
        id: String = "card-1",
        source: String,
        severity: String = "important",
        title: String = "A card",
        approval: String? = nil
    ) -> InboxItemRecord {
        InboxItemRecord(
            id: id,
            created_at: "2026-08-23T12:00:00Z",
            source: source,
            severity: severity,
            title: title,
            summary: "summary",
            detail: nil,
            relatedWorkshopExecutionId: nil,
            related_approval_id: approval,
            related_paths: nil,
            related_groups: nil,
            actions: [],
            status: "unread",
            read_at: nil
        )
    }

    // MARK: - ios.inbox.severityPresentation

    /// Every source family the Mac publishes must reach a SPECIFIC badge, and
    /// no two families may collapse onto the same one — a collision is how a
    /// dream-cycle card starts reading as a REM card with nobody noticing.
    func test_everyKnownSourceFamilyGetsItsOwnBadgeAndIcon() {
        let families: [String: String] = [
            "proactive_autonomy:idea-1": "IDEA",
            "harness_learning:run-9": "LEARNING",
            "dream_cycle": "DREAM",
            "rem_cycle": "REM",
            "trigger:file_watch:/tmp/x": "FILE-WATCH",
            "trigger:morning_brief": "MORNING-BRIEF",
            "trigger:stuck_pattern": "STUCK-PATTERNS",
            "idle_checkin": "IDLE-CHECKIN",
            "execution_complete:abc": "WORKSHOP",
            "mission_complete:abc": "WORKSHOP",
        ]

        for (source, expected) in families {
            XCTAssertEqual(item(source: source).sourceBadgeLabel, expected, "badge drifted for \(source)")
            XCTAssertNotEqual(
                item(source: source).sourceIcon, "bell.fill",
                "\(source) fell through to the generic bell icon — the card lost its identity"
            )
        }

        // The two spellings of the same event are the ONLY intended collision.
        let labels = families.map { item(source: $0.key).sourceBadgeLabel }
        let collisions = Dictionary(grouping: labels, by: { $0 }).filter { $0.value.count > 1 }
        XCTAssertEqual(
            collisions.keys.sorted(), ["WORKSHOP"],
            "two distinct source families now render the same badge"
        )
    }

    func test_anUnknownSourceDegradesToARawBadgeNeverToAKnownOne() {
        let unknown = item(source: "some_new_mac_publisher")
        XCTAssertEqual(unknown.sourceIcon, "bell.fill")
        XCTAssertEqual(unknown.sourceBadgeLabel, "SOME_NEW_MAC_P")  // uppercased, capped at 14
        XCTAssertEqual(unknown.sourceBadgeLabel.count, 14)
        XCTAssertLessThanOrEqual(
            item(source: String(repeating: "z", count: 40)).sourceBadgeLabel.count, 14,
            "an unbounded source string would blow out the badge and push the title off the row"
        )
    }

    func test_aLinkedApprovalOutranksEverySourceRule() {
        // An approval-linked card must read as an approval no matter which
        // publisher produced it — this is the one gate the user must not miss.
        let linked = item(source: "dream_cycle", approval: "approval-77")
        XCTAssertTrue(linked.hasLinkedApproval)
        XCTAssertEqual(linked.sourceBadgeLabel, "APPROVAL")
        XCTAssertEqual(linked.sourceIcon, "checkmark.shield.fill")

        XCTAssertFalse(item(source: "dream_cycle", approval: "").hasLinkedApproval,
                       "an empty approval id counted as a linked approval")
        XCTAssertEqual(item(source: "dream_cycle", approval: "").sourceBadgeLabel, "DREAM")
    }

    func test_severityColorsAreDistinctAndUnknownSeverityIsNotDressedAsUrgent() {
        let actionable = item(source: "idle_checkin", severity: "actionable").severityColor
        let important = item(source: "idle_checkin", severity: "important").severityColor
        let unknown = item(source: "idle_checkin", severity: "who_knows").severityColor
        XCTAssertNotEqual(actionable, important)
        XCTAssertNotEqual(actionable, unknown, "an unrecognised severity renders in the ACTIONABLE colour")
        XCTAssertEqual(unknown, item(source: "idle_checkin", severity: "").severityColor)
    }

    // MARK: - ios.inbox.groupFilter / related groups

    func test_aRelatedGroupNeverMatchesItselfAndAnEmptyGroupMatchesNothing() {
        let itemA = item(id: "a", source: "dream_cycle", title: "Nightly sweep")
        let itemB = item(id: "b", source: "dream_cycle", title: "Nightly sweep")

        let selfGroup = InboxRelatedGroup(id: "a", title: "Nightly sweep", count: 2, item_ids: ["a", "b"], source: nil)
        XCTAssertFalse(selfGroup.matches(itemA), "a group matched the card it is attached to — the sheet would list the card under itself")
        XCTAssertTrue(selfGroup.matches(itemB))

        let emptyGroup = InboxRelatedGroup(id: "g", title: "   ", count: 0, item_ids: nil, source: nil)
        XCTAssertFalse(
            emptyGroup.matches(itemA),
            "a group with no ids and a blank title matched an arbitrary card — every card would be pulled into it"
        )
    }

    func test_groupCountNeverUnderReportsTheIDsItActuallyCarries() {
        // A Mac-side count that lags the id list must not hide rows.
        let lagging = InboxRelatedGroup(id: "g", title: "Failures", count: 0, item_ids: ["a", "b", "c"], source: nil)
        XCTAssertEqual(lagging.displayCount, 3, "the badge under-reported a group that carries 3 ids")
        XCTAssertEqual(lagging.itemIDs, ["a", "b", "c"])

        let idless = InboxRelatedGroup(id: "g", title: "Failures", count: 7, item_ids: nil, source: nil)
        XCTAssertEqual(idless.displayCount, 7)
        XCTAssertTrue(idless.itemIDs.isEmpty)
        XCTAssertTrue(
            idless.matches(item(id: "x", source: "dream_cycle", title: "Failures")),
            "an id-less group stopped matching by title, so a summary-only digest would show zero members"
        )
    }

    // MARK: - ios.inbox.detailSheet.reviewGroups

    func test_detailSheetReviewGroupsPreferCurrentStructuredDigestWireAndRetainLegacyFallback() throws {
        let structured = InboxRelatedGroup(
            id: "digest-actionable-scan-7",
            title: "Actionable inbox items",
            count: 2,
            item_ids: ["item-a", "item-b"],
            source: "proactive_inbox_digest"
        )
        let currentDigestData = try JSONSerialization.data(withJSONObject: [
            "id": "digest-card",
            "created_at": "2026-08-24T12:00:00Z",
            "source": "proactive_autonomy:inbox_digest:scan-7",
            "severity": "important",
            "title": "Review inbox blockers",
            "summary": "2 actionable inbox items are waiting.",
            "detail": "Current scan found 2 unresolved attention-worthy inbox item(s), excluding routine receipts and prior proactive scan cards.",
            "related_mission_id": NSNull(),
            "related_approval_id": NSNull(),
            "related_paths": [],
            "related_groups": [[
                "id": structured.id,
                "title": structured.title,
                "count": structured.count,
                "item_ids": structured.item_ids ?? [],
                "source": structured.source ?? "",
            ]],
            "actions": [],
            "status": "unread",
            "read_at": NSNull(),
        ])
        let currentDigest = try JSONDecoder().decode(
            InboxItemRecord.self, from: currentDigestData
        )
        XCTAssertEqual(
            InboxDetailGroupProjection.groups(item: currentDigest, allItems: []),
            [structured],
            "the current Mac digest wire lost its Review Groups control on iOS"
        )

        let legacyDigest = InboxItemRecord(
            id: "legacy-digest",
            created_at: "2026-08-24T12:00:00Z",
            source: "autonomy_maintenance:inbox_digest",
            severity: "important",
            title: "Legacy inbox digest",
            summary: "Old cards must remain reviewable.",
            detail: "Inbox review.\nTop groups:\n- Waiting on approval (2)\n\nOlder detail.",
            relatedWorkshopExecutionId: nil,
            related_approval_id: nil,
            related_paths: nil,
            related_groups: nil,
            actions: [],
            status: "unread",
            read_at: nil
        )
        let members = [
            legacyDigest,
            item(id: "approval-1", source: "trigger:file_watch:/tmp/a", title: "Waiting on approval"),
            item(id: "approval-2", source: "trigger:file_watch:/tmp/b", title: "Waiting on approval"),
        ]
        let legacyGroups = InboxDetailGroupProjection.groups(item: legacyDigest, allItems: members)
        XCTAssertEqual(legacyGroups.map(\.title), ["Waiting on approval"])
        XCTAssertEqual(legacyGroups.first?.displayCount, 2)
        XCTAssertEqual(legacyGroups.first?.itemIDs, ["approval-1", "approval-2"])

        XCTAssertTrue(
            InboxDetailGroupProjection.groups(
                item: item(source: "dream_cycle", title: "Not a digest"), allItems: members
            ).isEmpty,
            "unrelated prose must not create a phantom Review Groups section"
        )
    }
}

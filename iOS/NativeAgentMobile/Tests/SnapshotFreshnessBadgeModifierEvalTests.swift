import Foundation
import XCTest
import SwiftUI
@testable import NativeAgentMobile

/// E6 (upgrade-sweep 2026-08): the freshness badge every snapshot screen shares.
///
/// Silent-failure class: STALE UI. An overnight-stale approvals queue renders
/// exactly like a measured-empty one. The badge's whole job is to make those
/// two states different, so the contract under test is *when it shows* and what
/// it says — not its pixels.
final class SnapshotFreshnessBadgeModifierEvalTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test_aFreshSnapshotShowsNoBadge() {
        let state = StatusConnectionPresentation.syncState(
            lastSyncedAt: now.addingTimeInterval(-5),
            now: now
        )
        XCTAssertFalse(
            StatusConnectionPresentation.needsAttention(state),
            "a 5s-old snapshot must not put a warning banner over the screen"
        )
    }

    func test_aStaleSnapshotRaisesTheBadgeAndSaysHowOld() {
        let age = MobileSnapshotFreshnessPresentation.staleAfter + 90
        let state = StatusConnectionPresentation.syncState(
            lastSyncedAt: now.addingTimeInterval(-age),
            now: now
        )
        XCTAssertTrue(StatusConnectionPresentation.needsAttention(state))
        XCTAssertTrue(
            StatusConnectionPresentation.cardValue(for: state).contains("STALE"),
            "the badge must name staleness, not just show a time"
        )
        XCTAssertNotNil(StatusConnectionPresentation.detail(for: state))
    }

    func test_aScreenThatNeverSyncedIsBadgedRatherThanShownAsEmpty() {
        let state = StatusConnectionPresentation.syncState(lastSyncedAt: nil, now: now)
        XCTAssertTrue(StatusConnectionPresentation.needsAttention(state))
        XCTAssertEqual(StatusConnectionPresentation.cardValue(for: state), "Never synced")
    }

    func test_theBadgeIsBuildableForEveryStateItCanBeGiven() {
        // Guards the modifier's own construction path: a badge that cannot be
        // built for the never-synced case would silently vanish exactly when
        // it matters most.
        for lastSyncedAt in [nil, now.addingTimeInterval(-1), now.addingTimeInterval(-9_000)] {
            let badge = MacSnapshotFreshnessBadge(lastSyncedAt: lastSyncedAt)
            XCTAssertEqual(badge.lastSyncedAt, lastSyncedAt)
        }
    }

    // MARK: - Per-group staleness (sweep 2026-09-01 item 2)

    /// The failure this closes: `data/icloud/snapshot_skips.json` named
    /// `memories` and `knowledge_graph` as unrebuildable while the phone
    /// rendered both as current, because staleness was purely a function of
    /// snapshot AGE and the sync timestamp itself was fresh.
    func test_aGroupTheMacCouldNotRebuildBadgesTheScreenEvenWhenTheSyncIsFresh() {
        let markers = ["memories": "The operation couldn’t be completed. (Swift.CancellationError error 1.)"]
        let reason = MacSnapshotGroupStaleness.reason(in: markers, group: "memories")
        XCTAssertNotNil(reason, "Memory renders a group the Mac skipped and says nothing")
        XCTAssertEqual(reason, markers["memories"])

        let freshState = StatusConnectionPresentation.syncState(
            lastSyncedAt: now.addingTimeInterval(-5),
            now: now
        )
        XCTAssertFalse(
            StatusConnectionPresentation.needsAttention(freshState),
            "age alone would hide this, which is exactly why the marker exists"
        )
        let badge = MacSnapshotFreshnessBadge(
            lastSyncedAt: now.addingTimeInterval(-5),
            staleGroupReason: reason
        )
        XCTAssertEqual(badge.staleGroupReason, reason)
        XCTAssertTrue(MacSnapshotGroupStaleness.title.contains("STALE"))
    }

    func test_aGroupThatRebuiltIsNotBadged() {
        // The Mac publishes an EMPTY marker on a healthy pass; a screen whose
        // group is absent from it must render with no banner.
        XCTAssertNil(MacSnapshotGroupStaleness.reason(in: [:], group: "memories"))
        XCTAssertNil(
            MacSnapshotGroupStaleness.reason(
                in: ["knowledge_graph": "unreadable"],
                group: "memories"
            ),
            "another group's failure must not badge this screen"
        )
        XCTAssertNil(MacSnapshotGroupStaleness.reason(in: ["memories": "x"], group: nil))
        // A reason the Mac left blank is still a skip, and must still badge.
        XCTAssertNotNil(MacSnapshotGroupStaleness.reason(in: ["memories": "   "], group: "memories"))
    }

    func test_memoryAndKnowledgeGraphNameTheGroupTheyRender() throws {
        XCTAssertTrue(
            try MobileEvalSources.mobileSource("MemoryView.swift")
                .contains("MacSnapshotGroupStaleness.reason(in: sync.staleSnapshotGroups, group: Self.snapshotGroup(for: segment))"),
            "Memory renders Mac-owned rows with no per-group staleness badge"
        )
        XCTAssertTrue(
            try MobileEvalSources.mobileSource("KnowledgeGraphView.swift")
                .contains(#".macSnapshotFreshnessBadge(group: "knowledge_graph")"#)
        )
    }

    /// Memory's two tabs come from two Mac groups that fail independently
    /// (`memories` vs `memory_proposals`), and the marker lookup is an exact
    /// key match — so a badge pinned to "memories" left a failed proposals
    /// rebuild rendering as a fresh, measured-empty Proposals list.
    func test_aFailedProposalsRebuildBadgesTheProposalsTabNotJustMemories() {
        XCTAssertEqual(MemoryView.snapshotGroup(for: .memories), "memories")
        XCTAssertEqual(MemoryView.snapshotGroup(for: .proposals), "memory_proposals")

        let markers = ["memory_proposals": "memory proposals unreadable: EIO"]
        XCTAssertEqual(
            MacSnapshotGroupStaleness.reason(
                in: markers,
                group: MemoryView.snapshotGroup(for: .proposals)
            ),
            markers["memory_proposals"],
            "a skipped memory_proposals group left the Proposals tab looking fresh"
        )
        XCTAssertNil(
            MacSnapshotGroupStaleness.reason(
                in: markers,
                group: MemoryView.snapshotGroup(for: .memories)
            ),
            "the Memories tab must not be badged for the other tab's failure"
        )
        // ...and the reverse direction, so the two tabs never share a verdict.
        XCTAssertNil(
            MacSnapshotGroupStaleness.reason(
                in: ["memories": "unreadable"],
                group: MemoryView.snapshotGroup(for: .proposals)
            )
        )
    }

    /// The screens E6 covers must actually apply the shared modifier. A
    /// source check is the honest instrument here: the alternative is asserting
    /// on rendered SwiftUI internals, which passes when the modifier is applied
    /// to the wrong subtree.
    func test_theSixUnguardedSnapshotScreensApplyTheSharedModifier() throws {
        for screen in [
            "ApprovalsView.swift",
            "InboxView.swift",
            "KnowledgeGraphView.swift",
            "AutonomyView.swift",
            "SkillsToolsView.swift",
            "TurnInspectorView.swift",
            // 2026-09-01: Memory was the screen this modifier's own header
            // claimed to cover and never mounted on.
            "MemoryView.swift",
        ] {
            let text = try MobileEvalSources.mobileSource(screen)
            if screen == "MemoryView.swift" {
                XCTAssertTrue(text.contains("MacSnapshotGroupStaleness.reason(in: sync.staleSnapshotGroups, group: Self.snapshotGroup(for: segment))"))
                XCTAssertTrue(text.contains("Saved memories may be out of date."))
                continue
            }
            XCTAssertTrue(
                text.contains(".macSnapshotFreshnessBadge("),
                "\(screen) renders Mac snapshot data with no freshness badge"
            )
        }
    }
}

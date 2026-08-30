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

    /// The six screens E6 covers must actually apply the shared modifier. A
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
        ] {
            let text = try MobileEvalSources.mobileSource(screen)
            XCTAssertTrue(
                text.contains(".macSnapshotFreshnessBadge()"),
                "\(screen) renders Mac snapshot data with no freshness badge"
            )
        }
    }
}

import Foundation
import XCTest
import SwiftUI
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`.
///
/// Rows closed here:
///   * `ios.desk.syncBadge` — `SyncBadge` renders NOTHING until the snapshot is
///     older than its threshold, so "never synced" and "synced a second ago"
///     look identical on Desk.
///   * `ios.advanced.status.lastSyncedFreshness` — all snapshot-age UI projects
///     through one shared threshold; a drift must fail at that contract, not by
///     scraping view source.
///   * `ios.shared.StatusBadge` — the shared status→colour map used by Runs,
///     Autonomy and Workshop has no default beyond `.secondary`.
///
/// Silent-failure class: STALE UI. Nothing errors; the phone just keeps showing
/// old numbers as if they were live.
final class MobileStalenessBadgeEvalTests: XCTestCase {

    // MARK: - ios.desk.syncBadge

    func test_aNeverSyncedSnapshotIsAlwaysReportedStale() {
        XCTAssertTrue(
            SyncBadge(date: .distantPast).isStale,
            "a never-synced Desk renders no staleness badge at all, so it reads exactly like a fresh one"
        )
        XCTAssertFalse(SyncBadge(date: Date()).isStale)
    }

    func test_theSharedStalenessThresholdDrivesTheSyncBadge() {
        let threshold = MobileSnapshotFreshnessPresentation.staleAfter
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertTrue(
            SyncBadge.isStale(date: now.addingTimeInterval(-(threshold + 1)), now: now),
            "a snapshot older than the shared \(threshold)s threshold is still reported fresh"
        )
        XCTAssertFalse(SyncBadge.isStale(date: now.addingTimeInterval(-threshold), now: now))
    }

    // MARK: - ios.advanced.status.lastSyncedFreshness

    func test_statusSurfacesUseTheSharedFreshnessPresentation() {
        let threshold = MobileSnapshotFreshnessPresentation.staleAfter
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertEqual(
            StatusConnectionPresentation.syncState(
                lastSyncedAt: now.addingTimeInterval(-(threshold + 1)),
                now: now
            ),
            .stale(age: threshold + 1, limit: threshold),
            "the shared status projection did not mark an expired snapshot stale"
        )
        XCTAssertEqual(
            StatusConnectionPresentation.syncState(
                lastSyncedAt: now.addingTimeInterval(-threshold),
                now: now
            ),
            .current(age: threshold),
            "the shared status projection disagrees with the badge at the freshness boundary"
        )
    }

    // MARK: - ios.shared.StatusBadge

    func test_theSharedStatusBadgeDistinguishesHealthyFromFailedAndFlagsTheUnknown() {
        let unknown = StatusBadge(status: "some_new_mac_status").color
        XCTAssertEqual(unknown, Color.secondary, "the documented fallback colour changed without this eval being updated")

        // The three outcomes a user must never confuse.
        let succeeded = StatusBadge(status: "succeeded").color
        let failed = StatusBadge(status: "failed").color
        let queued = StatusBadge(status: "queued").color
        XCTAssertNotEqual(succeeded, failed)
        XCTAssertNotEqual(succeeded, queued)
        XCTAssertNotEqual(failed, queued)
        for status in ["succeeded", "failed", "queued", "running", "done", "blocked", "timeout", "paused"] {
            XCTAssertNotEqual(
                StatusBadge(status: status).color, unknown,
                "'\(status)' now renders in the unknown-status grey — a real outcome became unreadable"
            )
        }

        // Case drift from the Mac must not knock a known status into grey.
        XCTAssertEqual(StatusBadge(status: "FAILED").color, failed)
        XCTAssertEqual(StatusBadge(status: "Succeeded").color, succeeded)
    }
}

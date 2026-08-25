import Foundation
import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.screens.snapshotFreshness
final class SnapshotFreshnessEvalTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testFreshnessSeparatesFreshStaleUnavailableAndClockMismatchSnapshots() {
        XCTAssertEqual(
            StatusConnectionPresentation.syncState(
                lastSyncedAt: now.addingTimeInterval(-30),
                now: now
            ),
            .current(age: 30)
        )
        XCTAssertEqual(
            StatusConnectionPresentation.syncState(
                lastSyncedAt: now.addingTimeInterval(-31),
                now: now
            ),
            .stale(age: 31, limit: 30)
        )
        XCTAssertEqual(
            StatusConnectionPresentation.syncState(lastSyncedAt: nil, now: now),
            .neverSynced
        )
        XCTAssertEqual(
            StatusConnectionPresentation.syncState(
                lastSyncedAt: now.addingTimeInterval(61),
                now: now
            ),
            .clockMismatch(futureBy: 61)
        )
    }

    func testUncertainSnapshotStatesHaveExplicitHonestCopy() {
        let stale = StatusConnectionPresentation.SyncState.stale(age: 90, limit: 30)

        XCTAssertEqual(StatusConnectionPresentation.cardValue(for: stale), "STALE · 1m old")
        XCTAssertEqual(
            StatusConnectionPresentation.detail(for: stale),
            "Expected a newer iCloud snapshot within 30s."
        )
        XCTAssertEqual(
            StatusConnectionPresentation.detail(for: .neverSynced),
            "No iCloud snapshot has reached this phone yet."
        )
        XCTAssertEqual(
            StatusConnectionPresentation.detail(for: .clockMismatch(futureBy: 61)),
            "The Mac snapshot is 1m ahead of this phone."
        )
        XCTAssertTrue(StatusConnectionPresentation.needsAttention(stale))
    }

    func testSettingsConnectionRendersTheSameFreshnessProjectionForEveryState() throws {
        let source = try MobileEvalSources.mobileSource("SettingsViewFull.swift")
        let settings = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "SettingsViewFull", keyword: "struct", in: source)
        )

        XCTAssertTrue(settings.contains("StatusConnectionPresentation.syncState("))
        XCTAssertTrue(settings.contains("StatusConnectionPresentation.cardValue(for: snapshotState)"))
        XCTAssertTrue(settings.contains("StatusConnectionPresentation.detail(for: snapshotState)"))
        XCTAssertTrue(settings.contains("StatusConnectionPresentation.needsAttention(snapshotState)"))
    }
}

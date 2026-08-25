import Foundation
import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.status.connectionCards`.
///
/// A status timestamp must never degrade into an indefinite orange relative
/// value. The card names its stale state and the maximum acceptable age.
final class StatusConnectionCardsEvalTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func test_syncCardDistinguishesFreshStaleNeverSyncedAndClockMismatch() {
        XCTAssertEqual(
            StatusConnectionPresentation.syncState(
                lastSyncedAt: now.addingTimeInterval(-30), now: now
            ),
            .current(age: 30)
        )
        XCTAssertEqual(
            StatusConnectionPresentation.syncState(
                lastSyncedAt: now.addingTimeInterval(-31), now: now
            ),
            .stale(age: 31, limit: 30)
        )
        XCTAssertEqual(
            StatusConnectionPresentation.syncState(lastSyncedAt: nil, now: now),
            .neverSynced
        )
        XCTAssertEqual(
            StatusConnectionPresentation.syncState(
                lastSyncedAt: now.addingTimeInterval(61), now: now
            ),
            .clockMismatch(futureBy: 61)
        )
    }

    func test_staleCardMakesTheUpperBoundAndFailureActionable() {
        let stale = StatusConnectionPresentation.SyncState.stale(age: 125, limit: 30)

        XCTAssertEqual(
            StatusConnectionPresentation.cardValue(for: stale),
            "STALE · 2m old"
        )
        XCTAssertEqual(
            StatusConnectionPresentation.detail(for: stale),
            "Expected a newer iCloud snapshot within 30s."
        )
        XCTAssertTrue(StatusConnectionPresentation.needsAttention(stale))

        XCTAssertEqual(
            StatusConnectionPresentation.detail(for: .neverSynced),
            "No iCloud snapshot has reached this phone yet."
        )
        XCTAssertEqual(
            StatusConnectionPresentation.detail(for: .clockMismatch(futureBy: 61)),
            "The Mac snapshot is 1m ahead of this phone."
        )
        XCTAssertFalse(StatusConnectionPresentation.needsAttention(.current(age: 1)))
    }

    func test_statusScreenRendersTheExplicitSyncCardProjection() throws {
        let source = try MobileEvalSources.mobileSource("AdvancedView.swift")
        XCTAssertTrue(source.contains("StatusConnectionPresentation.syncState("))
        XCTAssertTrue(source.contains("label: \"Last synced\""))
        XCTAssertTrue(source.contains("StatusConnectionPresentation.cardValue(for: syncState)"))
        XCTAssertTrue(source.contains("StatusConnectionPresentation.detail(for: syncState)"))
    }
}

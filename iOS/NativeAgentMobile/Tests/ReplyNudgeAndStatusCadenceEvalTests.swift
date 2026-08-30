import Foundation
import XCTest
@testable import NativeAgentMobile

/// E1 + E8 (upgrade-sweep 2026-08): the two iOS timers that ran hot forever.
///
/// Silent-failure class: BATTERY/QUOTA — nothing errors, the phone just burns
/// requests. The tests pin the floors and the age-sensitivity, because a
/// regression here is invisible on screen.
@MainActor
final class ReplyNudgeAndStatusCadenceEvalTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - E1 reply nudge floors

    func test_theReplyNudgeFloorIsEightSecondsWhileAReplyIsOutstanding() {
        XCTAssertEqual(ChatStore.iCloudReplyNudgeFloorSeconds, 8)
    }

    func test_theSnapshotRereadIsABackstopNotTheTransport() {
        XCTAssertGreaterThanOrEqual(
            ChatStore.iCloudReplySnapshotBackstopSeconds,
            ChatStore.iCloudReplyNudgeFloorSeconds,
            "the heavy transcript re-read must never run more often than the cheap drain"
        )
        XCTAssertEqual(ChatStore.iCloudReplySnapshotBackstopSeconds, 30)
    }

    func test_theStillWorkingHintStillAppearsAtTenSeconds() {
        // The hint used to be a side effect of the 5s snapshot cadence. With
        // that cadence gone it must be timed explicitly, or the user stares at
        // a silent bubble.
        XCTAssertEqual(ChatStore.iCloudReplyPollingHintAfterSeconds, 10)
        XCTAssertLessThan(
            ChatStore.iCloudReplyPollingHintAfterSeconds,
            ChatStore.iCloudReplySnapshotBackstopSeconds
        )
    }

    func test_theNudgeBudgetOverAThreeMinuteWaitIsCutSubstantially() {
        // Old loop: 20 nudges at 0.5s, then 1.2s, plus a 5s snapshot re-read
        // for the first 60s.
        let window: TimeInterval = 180
        let oldNudges = 20 + Int((window - 10) / 1.2)
        let oldSnapshots = 12
        let newNudges = Int(window / ChatStore.iCloudReplyNudgeFloorSeconds)
        let newSnapshots = Int(
            min(window, ChatStore.iCloudReplySnapshotBackstopWindowSeconds)
                / ChatStore.iCloudReplySnapshotBackstopSeconds
        )
        let oldTotal = oldNudges + oldSnapshots
        let newTotal = newNudges + newSnapshots
        XCTAssertLessThan(newTotal * 5, oldTotal,
                          "expected at least a 5x cut in iCloud operations per outstanding reply")
    }

    // MARK: - E8 status refresh cadence

    func test_aSettledOfflineProjectionArmsNoTimerAtAll() {
        let interval = MacBridgeStatusRefreshPolicy.refreshInterval(
            now: now,
            lastSeenAt: nil,
            connectingStartedAt: nil,
            bridgeUnavailableSince: now.addingTimeInterval(-3_600),
            isPaired: true,
            recentLastSeenInterval: 60,
            initialConnectingInterval: 30,
            macUnreachableThreshold: 30
        )
        XCTAssertNil(interval, "nothing time-dependent remains; the 5s timer must stop")
    }

    func test_animminentBoundaryKeepsTheFastCadence() {
        let connecting = MacBridgeStatusRefreshPolicy.refreshInterval(
            now: now,
            lastSeenAt: nil,
            connectingStartedAt: now.addingTimeInterval(-5),
            bridgeUnavailableSince: nil,
            isPaired: false,
            recentLastSeenInterval: 60,
            initialConnectingInterval: 30,
            macUnreachableThreshold: 30
        )
        XCTAssertEqual(connecting, MacBridgeStatusRefreshPolicy.activeInterval)

        let recentlySeen = MacBridgeStatusRefreshPolicy.refreshInterval(
            now: now,
            lastSeenAt: now.addingTimeInterval(-10),
            connectingStartedAt: nil,
            bridgeUnavailableSince: nil,
            isPaired: true,
            recentLastSeenInterval: 60,
            initialConnectingInterval: 30,
            macUnreachableThreshold: 30
        )
        XCTAssertEqual(recentlySeen, MacBridgeStatusRefreshPolicy.activeInterval)
    }

    func test_theStaleTickFollowsTheLabelsOwnGranularity() {
        // Review fix 2026-08-28: while the label shows minutes, tick once a
        // minute; once it reads in hours, hourly — a long-settled stale state
        // must not keep a 60s wakeup forever.
        func interval(ageSeconds: TimeInterval) -> TimeInterval? {
            MacBridgeStatusRefreshPolicy.refreshInterval(
                now: now,
                lastSeenAt: now.addingTimeInterval(-ageSeconds),
                connectingStartedAt: nil,
                bridgeUnavailableSince: nil,
                isPaired: true,
                recentLastSeenInterval: 60,
                initialConnectingInterval: 30,
                macUnreachableThreshold: 30
            )
        }
        XCTAssertEqual(interval(ageSeconds: 900),
                       MacBridgeStatusRefreshPolicy.minuteCounterInterval)
        XCTAssertEqual(interval(ageSeconds: 3_600), 3_600)
        XCTAssertEqual(interval(ageSeconds: 86_400), 3_600)
    }

    // MARK: - E8 device-offline honesty

    func test_anOfflinePhoneSaysSoInsteadOfBlamingTheMac() {
        XCTAssertEqual(BridgeStatus.deviceOffline.displayName, "iPhone offline")
        XCTAssertNotEqual(BridgeStatus.deviceOffline, .macUnreachable)
        XCTAssertNotNil(NetworkPathObserver.offlineBannerMessage(isOffline: true))
    }

    func test_anUnknownNetworkPathIsNotPaintedAsAnOutage() {
        XCTAssertNil(NetworkPathObserver.offlineBannerMessage(isOffline: nil))
        XCTAssertNil(NetworkPathObserver.offlineBannerMessage(isOffline: false))
    }

    func test_pathRestorationFiresOnComingOnlineIncludingColdLaunch() {
        // Review fix 2026-08-28: a cold launch that comes up already online
        // (nil -> online) counts as restored too, or persisted queued sends
        // sit until the network flaps. Steady online never re-fires.
        let observer = NetworkPathObserver()
        var restored = 0
        observer.onPathRestored = { restored += 1 }
        observer.apply(isOffline: false)   // first report: cold launch, online
        XCTAssertEqual(restored, 1)
        observer.apply(isOffline: false)   // steady online: no edge
        XCTAssertEqual(restored, 1)
        observer.apply(isOffline: true)
        observer.apply(isOffline: false)   // the offline -> online edge
        XCTAssertEqual(restored, 2)
        observer.apply(isOffline: false)   // no edge
        XCTAssertEqual(restored, 2)
    }
}

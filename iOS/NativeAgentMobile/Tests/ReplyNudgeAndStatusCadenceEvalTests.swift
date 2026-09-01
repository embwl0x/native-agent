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

    func test_aRestoreThatLandsBeforeTheCallbackIsInstalledIsReplayedNotLost() {
        // MacBridgeClient hooks the observer in its init, but the chat-store
        // callback behind it is installed from ContentView.onAppear — which
        // never runs while onboarding is on screen. The restore must be
        // latched and replayed, or the cold-launch-online queued-send resume
        // is lost for the whole session.
        let client = MacBridgeClient()
        let observer = NetworkPathObserver.shared
        observer.apply(isOffline: true)
        observer.apply(isOffline: false)   // restore with nothing downstream
        var resumed = 0
        client.onNetworkPathRestored = { resumed += 1 }
        XCTAssertEqual(resumed, 1, "the missed restore must replay on install")
        client.onNetworkPathRestored = { resumed += 1 }
        XCTAssertEqual(resumed, 1, "the latch is one-shot, not a replay on every install")
    }

    func test_aRestoreReplayedBeforeTheChatTabOpensStillSendsWhenTheClientArrives() async {
        // The whole chain on a launch that lands on a NON-CHAT tab: the path
        // observer fires, MacBridgeClient latches it, ContentView.onAppear
        // replays it into resumeQueuedSends — but `scheduleQueuedSendDrain`
        // also needs `pendingRetryClient`, which only ChatView.onAppear
        // installs. Consuming the one-shot latch with no client installed must
        // not lose the resume.
        let suiteName = "NativeAgentMobileTests.restoreOrdering.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.setSelectedSessionID("session-a")
        store.queuedSends = [
            QueuedChatSend(
                id: UUID(),
                sessionID: "session-a",
                text: "queued before the network came back",
                controls: .defaults,
                attachments: [],
                createdAt: Date()
            )
        ]
        store.pausedQueueSessionKeys.insert(store.queueSessionKey("session-a"))

        let client = MacBridgeClient()   // held strong — pendingRetryClient is weak
        let observer = NetworkPathObserver.shared
        observer.apply(isOffline: true)
        observer.apply(isOffline: false)   // restore, latched
        client.onNetworkPathRestored = { [weak store] in store?.resumeQueuedSends() }

        XCTAssertFalse(store.isSelectedQueuePaused, "the replayed restore must un-pause the queue")
        XCTAssertNil(store.sendTask, "nothing can send before the chat tab installs the client")

        store.pendingRetryClient = client   // ChatView.onAppear, one tab later
        for _ in 0..<50 {
            if store.sendTask != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(
            store.sendTask,
            "the queued send never resumed — the restore was consumed while no client was installed"
        )
    }
}

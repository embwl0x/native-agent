import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentMobile

struct CloudKitNotificationRoutingTests {
    @Test
    func visualCloudKitSubscriptionSuppressesLocalDuplicate() {
        #expect(
            NativeAgentCloudKitNotificationRouting.shouldScheduleLocalCopy(
                transportPresentsVisualNotification: true
            ) == false
        )
    }

    @Test
    func localFallbackRemainsWhenVisualSubscriptionIsUnavailable() {
        #expect(
            NativeAgentCloudKitNotificationRouting.shouldScheduleLocalCopy(
                transportPresentsVisualNotification: false
            )
        )
    }
}

// MARK: - ios.sync fence evals (2026-08-23, coverage ledger wave A)
//
// The notification lane's failures are all invisible from the app: a dedup key
// that stops matching gives the user TWO banners for one event; one that
// over-matches silences a real one. A launch flag that is set but never
// consumed hijacks the NEXT unrelated launch. A screen name the Mac starts
// sending that is not in the hardcoded allow-set silently lands on Activity.
// A push receipt that is never written removes the only evidence that splits
// "delivered but silenced" from "never delivered".
//
// Ledger rows: ios.app.notificationLaunchIntent / ios.push.notificationLaunchIntent,
// ios.app.notificationEventGate.add / ios.push.notificationEventGate,
// ios.app.remoteNotificationPayload.string / ios.push.remoteNotificationPayload,
// ios.push.receiptLedger / ios.pushReceiptLedger.

private func canonicalEventID(_ seed: String) -> String {
    NativeAgentDeviceEventIdentity.notification(userInfo: ["itemId": seed])
}

private func withRestoredUserDefaults(_ keys: [String], _ body: () throws -> Void) rethrows {
    let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    defer {
        for (key, value) in saved {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
    try body()
}

@Suite("Notification launch intent")
@MainActor
struct NotificationLaunchIntentFenceTests {
    private static let openActivityKey = "NativeAgentMobile.pendingOpenActivityFromNotification"
    private static let pendingScreenKey = "NativeAgentMobile.pendingNotificationScreen"
    private static let keys = [openActivityKey, pendingScreenKey]

    /// The whole point of the pending flag is that it is consumed exactly
    /// once. A flag left set routes the NEXT cold launch — one the user
    /// started themselves — straight to a notification screen, which reads as
    /// the app forgetting where they were.
    @Test func aConsumedLaunchIntentCannotHijackTheNextLaunch() {
        withRestoredUserDefaults(Self.keys) {
            UserDefaults.standard.removeObject(forKey: Self.openActivityKey)
            UserDefaults.standard.removeObject(forKey: Self.pendingScreenKey)

            #expect(NativeAgentNotificationLaunchIntent.pendingScreen == nil)
            #expect(NativeAgentNotificationLaunchIntent.consumePendingScreen() == nil)
            #expect(NativeAgentNotificationLaunchIntent.consumeOpenActivityPending() == false)

            NativeAgentNotificationLaunchIntent.markOpenActivityPending(screen: "inbox")
            #expect(NativeAgentNotificationLaunchIntent.hasPendingOpenActivity)
            #expect(NativeAgentNotificationLaunchIntent.consumePendingScreen() == "inbox")

            // Consumed — both keys gone, and a second read is empty.
            #expect(NativeAgentNotificationLaunchIntent.hasPendingOpenActivity == false)
            #expect(NativeAgentNotificationLaunchIntent.pendingScreen == nil)
            #expect(NativeAgentNotificationLaunchIntent.consumePendingScreen() == nil)
            #expect(UserDefaults.standard.object(forKey: Self.pendingScreenKey) == nil,
                    "the screen key must be cleared with the flag, not left to leak into the next launch")
        }
    }

    /// A screen the Mac sends that this build does not know must degrade to
    /// Activity, never to nil (which would drop the tap entirely) and never
    /// to the raw string (which would route nowhere).
    @Test func unknownScreenNamesDegradeToActivityRatherThanDroppingTheTap() {
        withRestoredUserDefaults(Self.keys) {
            for unknown in ["workshop", "SOMETHING_NEW", "", "   ", "../etc/passwd"] {
                UserDefaults.standard.removeObject(forKey: Self.openActivityKey)
                UserDefaults.standard.removeObject(forKey: Self.pendingScreenKey)
                NativeAgentNotificationLaunchIntent.markOpenActivityPending(screen: unknown)
                #expect(NativeAgentNotificationLaunchIntent.hasPendingOpenActivity,
                        "an unknown screen must still register the launch")
                #expect(NativeAgentNotificationLaunchIntent.consumePendingScreen() == "activity",
                        "unknown screen \(unknown.debugDescription) must fall back to activity")
            }

            // A nil screen (a notification with no screen field) is the same.
            UserDefaults.standard.removeObject(forKey: Self.openActivityKey)
            NativeAgentNotificationLaunchIntent.markOpenActivityPending(screen: nil)
            #expect(NativeAgentNotificationLaunchIntent.consumePendingScreen() == "activity")
        }
    }

    /// Every allowed screen must survive the round trip, case-insensitively —
    /// the Mac sends "Inbox"/"MAC_INTEGRATION" spellings and a case-sensitive
    /// compare silently routes all of them to Activity.
    @Test func everyAllowedScreenRoundTripsCaseInsensitively() {
        withRestoredUserDefaults(Self.keys) {
            #expect(NativeAgentNotificationLaunchIntent.allowedScreens.contains("activity"))
            for screen in NativeAgentNotificationLaunchIntent.allowedScreens {
                UserDefaults.standard.removeObject(forKey: Self.openActivityKey)
                UserDefaults.standard.removeObject(forKey: Self.pendingScreenKey)
                NativeAgentNotificationLaunchIntent.markOpenActivityPending(screen: " \(screen.uppercased()) ")
                #expect(NativeAgentNotificationLaunchIntent.consumePendingScreen() == screen,
                        "\(screen) did not survive an upper-cased, padded round trip")
            }
        }
    }

    /// `consumeOpenActivityPending` is the other consumer (ContentView's
    /// boolean path). It must clear the same two keys, otherwise the two
    /// consumers disagree about whether the launch was handled.
    @Test func bothConsumersClearTheSameState() {
        withRestoredUserDefaults(Self.keys) {
            UserDefaults.standard.removeObject(forKey: Self.openActivityKey)
            NativeAgentNotificationLaunchIntent.markOpenActivityPending(screen: "memories")
            #expect(NativeAgentNotificationLaunchIntent.consumeOpenActivityPending())
            #expect(NativeAgentNotificationLaunchIntent.hasPendingOpenActivity == false)
            #expect(NativeAgentNotificationLaunchIntent.pendingScreen == nil)
            #expect(UserDefaults.standard.object(forKey: Self.pendingScreenKey) == nil)
        }
    }
}

@Suite("Remote notification payload + dedup identity")
struct NotificationIdentityFenceTests {

    /// The ONLY bridge between the APNS payload vocabulary (flat `screen` /
    /// `eventId` keys) and the CloudKit record vocabulary
    /// (`notificationScreen` / `notificationEventId`). A break here means
    /// every CloudKit-delivered push loses its routing and lands on Activity.
    @Test func directKeysWinAndBlankValuesAreTreatedAsAbsent() {
        #expect(
            NativeAgentRemoteNotificationPayload.string(
                directKey: "screen",
                cloudKitRecordKey: "notificationScreen",
                in: ["screen": "inbox"]
            ) == "inbox"
        )
        // Whitespace-padded values are trimmed, not passed through raw.
        #expect(
            NativeAgentRemoteNotificationPayload.string(
                directKey: "screen",
                cloudKitRecordKey: "notificationScreen",
                in: ["screen": "  approvals \n"]
            ) == "approvals"
        )
        // A blank direct value must be treated as ABSENT so the CloudKit
        // fallback still gets a chance — returning "" would pin routing to a
        // screen that does not exist.
        for blank in ["", "   ", "\n"] {
            #expect(
                NativeAgentRemoteNotificationPayload.string(
                    directKey: "screen",
                    cloudKitRecordKey: "notificationScreen",
                    in: ["screen": blank]
                ) == nil
            )
        }
        // A non-string value must not crash or coerce.
        #expect(
            NativeAgentRemoteNotificationPayload.string(
                directKey: "screen",
                cloudKitRecordKey: "notificationScreen",
                in: ["screen": 42]
            ) == nil
        )
        // A foreign push yields nil rather than throwing through the CloudKit
        // branch.
        #expect(
            NativeAgentRemoteNotificationPayload.string(
                directKey: "screen",
                cloudKitRecordKey: "notificationScreen",
                in: ["aps": ["alert": "hi"]]
            ) == nil
        )
    }

    /// The dedup identity is the ONLY thing between the APNS lane and the
    /// iCloud-bridge lane. It must accept only CANONICAL ids — a loose match
    /// lets a truncated/foreign id dedup a real event away.
    @Test func onlyCanonicalEventIDsAreAcceptedForDedup() {
        let canonical = canonicalEventID("approval-42")
        #expect(NativeAgentDeviceEventIdentity.isCanonical(canonical))
        #expect(canonical.count == 64)

        #expect(NativeAgentNotificationEventGate.eventID(in: ["eventId": canonical]) == canonical)
        #expect(NativeAgentNotificationEventGate.eventID(in: ["eventId": "  \(canonical)  "]) == canonical)

        // Non-canonical shapes must be refused outright, not truncated or padded.
        for bad in [
            String(canonical.dropLast()),          // 63 chars
            canonical + "0",                       // 65 chars
            String(repeating: "z", count: 64),     // right length, not hex
            "approval-42",
            "",
        ] {
            #expect(
                NativeAgentNotificationEventGate.eventID(in: ["eventId": bad]) == nil,
                "\(bad.debugDescription) must not be accepted as a dedup identity"
            )
        }
    }

    /// The nested `nativeagent.eventId` form is the CloudKit-relayed spelling.
    /// When the flat key carries a non-canonical value the nested canonical one
    /// must still be found — otherwise the two lanes stop deduping and the
    /// user gets two banners for one event.
    @Test func aCanonicalNestedEventIDIsFoundWhenTheFlatKeyIsUnusable() {
        let canonical = canonicalEventID("task-7")
        #expect(
            NativeAgentNotificationEventGate.eventID(in: [
                "eventId": "legacy-task-7",
                "nativeagent": ["eventId": canonical],
            ]) == canonical
        )
        // Both unusable → nil, so the caller falls back to a fresh identity
        // rather than deduping against garbage.
        #expect(
            NativeAgentNotificationEventGate.eventID(in: [
                "eventId": "legacy-task-7",
                "nativeagent": ["eventId": "also-legacy"],
            ]) == nil
        )
        #expect(NativeAgentNotificationEventGate.eventID(in: [:]) == nil)
    }

    /// The identity must be CONTENT-FREE and stable: the same semantic event
    /// produces the same id across transports, and changing the prose cannot
    /// mint a second alert for one event.
    @Test func eventIdentityIsStableAcrossTransportsAndIndependentOfProse() {
        let viaAPNS = NativeAgentDeviceEventIdentity.notification(
            userInfo: ["itemId": "inbox-99", "title": "Approval needed"]
        )
        let viaBridge = NativeAgentDeviceEventIdentity.notification(
            userInfo: ["itemId": "inbox-99", "title": "Totally different wording"]
        )
        #expect(viaAPNS == viaBridge, "prose must not be part of the dedup identity")
        #expect(NativeAgentDeviceEventIdentity.isCanonical(viaAPNS))

        // Distinct events must not collide.
        let other = NativeAgentDeviceEventIdentity.notification(userInfo: ["itemId": "inbox-100"])
        #expect(other != viaAPNS)

        // An explicit canonical eventId wins over the derived key, lower-cased.
        let explicit = canonicalEventID("explicit").uppercased()
        #expect(
            NativeAgentDeviceEventIdentity.notification(
                userInfo: ["eventId": explicit, "itemId": "ignored"]
            ) == explicit.lowercased()
        )

        // With nothing usable it falls back — and the fallback is still canonical.
        let fallback = NativeAgentDeviceEventIdentity.notification(userInfo: [:], fallback: "msg-1")
        #expect(NativeAgentDeviceEventIdentity.isCanonical(fallback))
        #expect(fallback == NativeAgentDeviceEventIdentity.notification(userInfo: [:], fallback: "msg-1"))
    }
}

@Suite("Push receipt ledger")
struct PushReceiptLedgerFenceTests {
    private static let key = "NativeAgentMobile.pushReceipts"

    /// This ledger exists to split "delivered but silenced" from "never
    /// delivered". If the write is dropped the diagnostic reads as "never
    /// delivered" for every push — the exact wrong answer, silently.
    @Test func aReceivedPushIsRecordedWithItsRoutingAndCanonicalIdentity() {
        withRestoredUserDefaults([Self.key]) {
            UserDefaults.standard.removeObject(forKey: Self.key)
            let canonical = canonicalEventID("inbox-11")

            let entry = PushReceiptLedger.record(userInfo: [
                "source": "mac_apns",
                "screen": "inbox",
                "itemId": "inbox-11",
                "eventId": canonical,
            ])

            #expect(entry.source == "mac_apns")
            #expect(entry.screen == "inbox")
            #expect(entry.itemId == "inbox-11")
            #expect(entry.eventId == canonical)
            #expect(entry.id == canonical)

            let loaded = PushReceiptLedger.load()
            #expect(loaded.count == 1)
            #expect(loaded.first?.itemId == "inbox-11")
        }
    }

    /// Missing fields must degrade to placeholders, never drop the row —
    /// a push that arrives with an odd payload is exactly the one worth
    /// having evidence for. And a non-canonical eventId must not be stored
    /// as an identity (it would dedup against nothing).
    @Test func anOddPayloadStillProducesAnEvidenceRow() {
        withRestoredUserDefaults([Self.key]) {
            UserDefaults.standard.removeObject(forKey: Self.key)
            let entry = PushReceiptLedger.record(userInfo: ["eventId": "legacy-id"])
            #expect(entry.source == "unknown")
            #expect(entry.screen == "")
            #expect(entry.itemId == "")
            #expect(entry.eventId == nil, "a non-canonical id must not masquerade as a dedup identity")
            #expect(!entry.id.isEmpty, "every receipt needs some id or the list collapses")
            #expect(PushReceiptLedger.load().count == 1)
        }
    }

    /// Newest-first with a hard cap: the diagnostic must show the pushes from
    /// the incident the user is reporting, not the twenty oldest ones.
    @Test func theLedgerKeepsTheNewestEntriesAndCapsGrowth() {
        withRestoredUserDefaults([Self.key]) {
            UserDefaults.standard.removeObject(forKey: Self.key)
            for i in 0..<25 {
                _ = PushReceiptLedger.record(userInfo: [
                    "source": "mac_apns",
                    "itemId": "item-\(i)",
                ])
            }
            let loaded = PushReceiptLedger.load()
            #expect(loaded.count == 20, "the ledger must be capped, not unbounded")
            #expect(loaded.first?.itemId == "item-24", "newest first")
            #expect(loaded.last?.itemId == "item-5", "the oldest entries are the ones evicted")
            #expect(!loaded.contains { $0.itemId == "item-0" })
        }
    }
}

import Foundation
import PersistenceCore
import TriggerScheduler

// MARK: - Trigger → paired-device push binding
//
// The app side of the Core `TriggerNotifier` seam. `TriggerScheduler` is a
// NativeAgentCore target and cannot import NativeAgentApp, where MacSyncEngine /
// SwiftNativeAPNS / MobileNotificationDeliveryReceipt live — so the sender is
// injected as a closure from here.
//
// This is the SAME call the DeskNotify loop makes
// (BackgroundLoopsAssembly+DeskNotify.swift). It never throws: a failed push
// must not un-fire a trigger, and it must not suppress the activity receipt —
// the receipt records `.null` delivery and the failure is logged.

enum TriggerNotifierBinding {
    /// THE THIRD-ROOT FIX (2026-07-09): the trigger engine writes its item into
    /// the legacy ProactiveInboxStore (<root>/inbox/) — a parallel silo NOTHING
    /// user-facing reads. The Mac UI, getInboxItems, and the iOS snapshot all
    /// read NotificationInbox (<root>/notifications/inbox.jsonl). Mirror the
    /// EXACT built card (scheduler id, severity, detail — carried through the
    /// seam) into the REAL inbox, normalized to the notifications-store shape.
    ///
    /// Shared by the notifier below AND by the two app-side fire sites, which
    /// mirror the cards of NON-notified fires (board M18). One normalization,
    /// so a notify:false card is indistinguishable from a notify:true one.
    ///
    /// Outcome of a mirror attempt. `.duplicate` means an ACTIVE equivalent
    /// card (same source+title+summary, unread/read, within 7 days) already
    /// sits in the live inbox — checked ATOMICALLY under the inbox file lock
    /// right before the append, closing the check-then-append race between
    /// concurrent fires that the scheduler's advisory `surface()` dedup can't
    /// see (gpt-5.5 review, 2026-07-24: two overlapping fires could both pass
    /// the advisory check and double-card).
    enum MirrorOutcome {
        case appended
        case duplicate(existingId: String)
        case failed
    }

    /// Returns `.failed` on write failure, having logged loudly; each caller
    /// decides what a failed or deduped mirror means for it.
    static func mirrorCardIntoRealInbox(_ card: JSONValue, triggerName: String) async -> MirrorOutcome {
        guard case .object(var cardObj) = card else {
            NSLog("trigger_mirror: card for %@ is not a JSON object — NOT written to the real inbox",
                  triggerName)
            return .failed
        }
        let inboxPath = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        // Normalize the card to the notifications-store shape.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if cardObj["created_at"] == nil { cardObj["created_at"] = .string(fmt.string(from: Date())) }
        if cardObj["status"] == nil { cardObj["status"] = .string("unread") }
        if cardObj["read_at"] == nil { cardObj["read_at"] = .null }
        if cardObj["actions"] == nil {
            cardObj["actions"] = .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See full detail")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ])
        }
        let normalizedObj = cardObj
        let normalized: JSONValue = .object(normalizedObj)
        let persistence = SwiftNativePersistenceCore()
        do {
            // 2026-07-21 audit (MED): route through the shared capped append —
            // notifications/inbox.jsonl is the LIVE inbox the UI and iOS read.
            // A5.2 (2026-07-24): dedup-check + append run under ONE file lock
            // (appendJSONLCapped with takeLock:false inside our lock) so two
            // concurrent fires can't both pass the check and double-card.
            return try await persistence.withFileLock(inboxPath) { () async throws -> MirrorOutcome in
                if let existingId = ProactiveInboxStore.activeDuplicateId(
                    for: normalizedObj,
                    notificationsInboxPath: inboxPath
                ) {
                    return .duplicate(existingId: existingId)
                }
                try await appendJSONLCapped(
                    normalized, to: inboxPath, using: persistence,
                    maxLines: JSONLLineCaps.notificationInbox,
                    logLabel: "TriggerNotifierBinding.inbox",
                    takeLock: false
                )
                return .appended
            }
        } catch {
            NSLog("trigger_mirror: REAL-inbox card write FAILED for %@: %@",
                  triggerName, String(describing: error))
            return .failed
        }
    }

    static let pairedDevicePush: TriggerNotifier = { note in
        // A card the seam couldn't carry (empty id / non-object) is rebuilt from
        // the push-truncated fields rather than dropped.
        let card: JSONValue
        if case .object = note.item, !note.itemId.isEmpty {
            card = note.item
        } else {
            card = .object([
                "id": .string(UUID().uuidString.lowercased()),
                "source": .string("trigger:\(note.triggerName)"),
                "severity": .string("info"),
                "title": .string(note.title),
                "summary": .string(String(note.body.prefix(500))),
            ])
        }
        // FAIL-LOUD (gpt-5.5 HIGH, 2026-07-09): if the card cannot land, DO NOT
        // push — a knock with nothing behind it is the exact bug this exists to
        // fix, and at-most-once means it would never self-heal.
        switch await mirrorCardIntoRealInbox(card, triggerName: note.triggerName) {
        case .failed:
            NSLog("trigger_notify: suppressing push for %@ — no knock without a card", note.triggerName)
            return .null
        case .duplicate(let existingId):
            // The atomic check found an active equivalent card a concurrent
            // fire landed first. No new card → no knock; non-null delivery so
            // the scheduler records the fire as handled and never re-mirrors.
            NSLog("trigger_notify: %@ deduped at the mirror against active card %@ — no push",
                  note.triggerName, existingId)
            return .object([
                "delivered": .bool(false),
                "mirrored": .bool(true),
                "deduped_against": .string(existingId),
            ])
        case .appended:
            break
        }
        // The card must be IN the cloud BEFORE the knock (User, 2026-07-09: tapping
        // the notification opened an inbox that didn't have the brief yet).
        // writeSnapshots refreshes snapshots/inbox.json from the store we JUST
        // wrote; digest-dedup makes it cheap, and pushing AFTER gives iCloud its
        // head start so the tap lands on a synced inbox.
        await MacSyncEngine.shared.writeSnapshots()
        do {
            let receipt = try await MacSyncEngine.shared.sendNotificationToPairedDevices(
                title: note.title,
                body: note.body,
                userInfo: [
                    "screen": note.screen,
                    "source": note.source,
                    "urgency": note.urgency,
                    "itemId": note.itemId,
                    "trigger": note.triggerName,
                ]
            )
            return .object(receipt.deliveryFields())
        } catch {
            NSLog("trigger_notify: paired-device push failed for \(note.triggerName): \(error)")
            // Partial outcome, NOT .null (gpt-5.5 review, 2026-07-09): the card
            // IS in the real inbox — only the knock failed. `.null` from this
            // notifier means "card never landed" and makes the scheduler leave
            // notified=false, which would send the fire-site fallback to mirror
            // the card a second time.
            return .object([
                "delivered": .bool(false),
                "mirrored": .bool(true),
                "error": .string(String(describing: error)),
            ])
        }
    }

    /// Mirror the card of a fire that the notifier did NOT handle.
    ///
    /// A notify:true fire is already mirrored inside `pairedDevicePush`, so
    /// mirroring here too would double-write the card. A fire deduped against an
    /// active card carries no `item` — the card it would mirror is the one
    /// already in the inbox. Everything else (notify:false, notify-with-no-
    /// notifier) used to land ONLY in the legacy ProactiveInboxStore, where
    /// nothing user-facing reads it: that is the silo this closes (board M18).
    ///
    /// Refreshes snapshots after a successful mirror so the iOS companion sees
    /// the card too, the same way the notify path does before it knocks.
    ///
    /// Returns false ONLY when a mirror was needed and failed — a fire that
    /// needs no mirror (not fired, already notified, deduped) is true, so the
    /// manual "Fire now" path can report an honest failure instead of success
    /// with an empty inbox (gpt-5.5 review, 2026-07-09).
    @discardableResult
    static func mirrorNonNotifiedFire(_ result: TriggerFireResult) async -> Bool {
        guard result.status == "fired", result.notified != true, let item = result.item else { return true }
        let name = result.name ?? "unknown"
        switch await mirrorCardIntoRealInbox(item, triggerName: name) {
        case .failed:
            NSLog("trigger_mirror: non-notified fire for %@ (item %@) did NOT reach the real inbox — the card was DROPPED",
                  name, result.itemId ?? "?")
            return false
        case .duplicate:
            // An active equivalent card is already in the inbox — nothing to
            // mirror; the fire is honestly represented by the existing card.
            return true
        case .appended:
            await MacSyncEngine.shared.writeSnapshots()
            return true
        }
    }

    /// The scheduler the two FIRE call sites use — the event/deadline due-work
    /// runner and manual "fire now". Every other call site (list / enable / disable /
    /// configure) keeps the plain `makeTriggerScheduler()`: they never fire, so
    /// they must never carry a sender.
    static func makeNotifyingTriggerScheduler() -> any TriggerSchedulerClient {
        makeTriggerScheduler(notifier: pairedDevicePush)
    }
}

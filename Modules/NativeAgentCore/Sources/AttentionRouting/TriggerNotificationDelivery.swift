import Foundation
import PersistenceCore
import TriggerScheduler
import DeviceSync

/// Trigger delivery policy; the inbox owns the card and host ports carry it.
public enum TriggerNotificationDelivery {
    /// Item 26 classification for a fired trigger.
    ///
    /// A CLOCK trigger (the morning brief) fires on the hour, not on a fact User
    /// is blocked on — informational, so it lands on the PHONE, once, and the
    /// mirrored card is its receipt. It is never a chat message (NORTHSTAR
    /// clause 6; User's explicit call). An event trigger whose card came out
    /// `important` (urgency "high") is Agent reaching for User — owner-waiting,
    /// routed to the surface he is actually on.
    static func importance(for note: TriggerNotification) -> AttentionImportance {
        if note.kind == "time" { return .informational }
        return note.urgency == "high" ? .ownerWaiting : .informational
    }

    public static func notify(
        _ note: TriggerNotification,
        delivery: any TriggerSnapshotDeliveryPort,
        router: @Sendable () -> AttentionRouter
    ) async -> JSONValue {
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
        switch await TriggerNotificationInbox.mirrorCardIntoRealInbox(card, triggerName: note.triggerName) {
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
        await delivery.writeSnapshots()
        do {
            // Item 26. A CLOCK trigger (the morning brief) fires on the hour,
            // not on a fact User is blocked on — informational, so it lands on
            // the PHONE, once, and the card written above is its receipt. It is
            // never a chat message (NORTHSTAR clause 6; User's explicit call).
            // An event trigger that built an `important` card is Agent reaching
            // for User: owner-waiting, routed to the surface he is on.
            // Payload unchanged.
            let importance = Self.importance(for: note)
            let outcome = try await router().route(
                eventId: note.itemId.isEmpty
                    ? "trigger:\(note.triggerName):\(AttentionRouter.stableDigest(note.title + "|" + note.body))"
                    : "trigger:\(note.itemId)",
                importance: importance,
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
            guard let receipt = outcome.receipt else {
                // Routed to Telegram, or already delivered for this card. The
                // card IS in the inbox either way, so this is a delivered fire
                // with no APNS receipt — never `.null`, which means "the card
                // never landed" and would make the scheduler re-mirror.
                //
                // `deliveryFailed` is the third case and is NOT a delivery: the
                // Telegram send failed with the phone switched off, so nothing
                // reached him. Reporting it as delivered was the lying signal.
                let projection = outcome.deliveryProjection
                if !projection.reachedAChannel {
                    NSLog("trigger_notify: %@ mirrored but no channel accepted the knock (%@)",
                          note.triggerName, projection.rawValue)
                }
                // `delivered` is the router's own projection, not "no failure
                // was reported". A routing that chose no channel, or deferred
                // for quiet hours, delivered nothing. `mirrored` (the card was
                // saved) stays a separate fact.
                var fields: [String: JSONValue] = [
                    "delivered": .bool(projection.reachedAChannel),
                    "delivery": .string(projection.rawValue),
                    "mirrored": .bool(true),
                    "routedTo": .string(outcome.delivery.rawValue),
                    "suppressed": .bool(outcome.suppressed),
                    "delivery_failed": .bool(outcome.deliveryFailed),
                ]
                if projection == .failed {
                    fields["error"] = .string(
                        "the knock was tried and no channel accepted it; the card is in the "
                        + "inbox but nothing reached him")
                }
                return .object(fields)
            }
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
                "delivery": .string(AttentionOutcome.Delivery.failed.rawValue),
                "mirrored": .bool(true),
                "error": .string(String(describing: error)),
            ])
        }
    }
}

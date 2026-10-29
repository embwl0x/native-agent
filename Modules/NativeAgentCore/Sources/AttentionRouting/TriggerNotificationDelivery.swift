import Foundation
import PersistenceCore
import TriggerScheduler
import DeviceSync
import NativeAgentShared
// Blueprint: | `TriggerNotificationDelivery.swift` | `TriggerNotificationDelivery` enum; `importance`, `notify` |

/// Trigger delivery policy; the inbox owns the card and host ports carry it.
public enum TriggerNotificationDelivery {
    public static func notify(
        _ note: TriggerNotification,
        notify: Bool,
        delivery: any TriggerSnapshotDeliveryPort,
        router: @Sendable () -> AttentionRouter
    ) async -> JSONValue {
        let itemID = note.itemId
        let eventID = "trigger:\(itemID)"
        let importance: AttentionImportance = note.ownerWaiting ? .ownerWaiting : .informational
        let userInfo = ["screen": note.screen, "source": note.source, "urgency": note.urgency,
                        "itemId": itemID, "trigger": note.triggerName]
        // The accepted card reaches the phone snapshot before the knock.
        await delivery.writeSnapshots()
        guard notify else { return .object(["delivered": .bool(false), "mirrored": .bool(true)]) }
        do {
            let outcome = try await router().route(
                eventId: eventID,
                importance: importance,
                title: note.title,
                body: note.body,
                userInfo: userInfo
            )
            guard let receipt = outcome.receipt else {
                let projection = outcome.deliveryProjection
                if !projection.reachedAChannel {
                    nativeLog("trigger_notify: %@ mirrored but no channel accepted the knock (%@)",
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
            nativeLog("trigger_notify: paired-device push failed for \(note.triggerName): \(error)")
            return .object([
                "delivered": .bool(false),
                "delivery": .string(AttentionOutcome.Delivery.failed.rawValue),
                "mirrored": .bool(true),
                "error": .string(String(describing: error)),
            ])
        }
    }
}

import Foundation
import ChatTurnContracts
import PersistenceCore
import TriggerScheduler
import DeviceSync
import NativeAgentShared
import NativeAgentCore
// Blueprint: | `TriggerNotificationDelivery.swift` | Deliver the trigger's already-filed obligations; no second tell or separate occurrence |

public enum TriggerNotificationDelivery {
    public static func notify(
        _ note: TriggerNotification,
        notify: Bool,
        delivery: any TriggerSnapshotDeliveryPort,
        router: @Sendable () -> AttentionRouter,
        turn: Turn?
    ) async -> JSONValue {
        let attention = router()
        let root = await attention.dataRoot
        // Acceptance already told the matter; this host publishes its reading and sends the obligations it owes.
        await delivery.writeSnapshots()
        guard notify else { return .object(["delivered": .bool(false), "mirrored": .bool(true)]) }
        do {
            _ = try await AttentionRouter.release(dataRoot: root, router: attention)
            let outcome = try await attention.outcome(note.itemId,
                held: AttentionRouter.inQuietHours(at: Date(), dataRoot: root))
            let projection = outcome.deliveryProjection
            if projection != .accepted {
                nativeLog("trigger_notify: %@ mirrored; destination acceptance remains incomplete (%@)", note.triggerName, projection.rawValue)
            }
            var fields = outcome.receipt?.deliveryFields() ?? [:]
            fields["delivered"] = .bool(projection == .accepted)
            fields["delivery"] = .string(projection.rawValue)
            fields["mirrored"] = .bool(true)
            fields["destinations"] = .object(outcome.destinationFields)
            fields["suppressed"] = .bool(outcome.suppressed)
            if projection == .failed {
                fields["error"] = .string("At least one destination refused the knock; the card and remaining delivery stay in their owners.")
            }
            return .object(fields)
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

import Foundation
import ChatTurnContracts
import PersistenceCore
import TriggerScheduler
import DeviceSync
import NativeAgentShared
import NativeAgentCore
import Experiences
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
            guard let matter = try await ForPerson.at(root).matter(note.itemId) else { throw CocoaError(.fileReadNoSuchFile) }
            let outcome: AttentionOutcome
            if matter.face?.row?.tone != .failed, let end = try AttentionRouter.quietHoursEnd(at: Date(), dataRoot: root) {
                outcome = try await attention.outcome(note.itemId, deferredUntil: end)
            } else {
                outcome = try await attention.deliver(note.itemId)
            }
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
            if let held = outcome.deferredFields { fields.merge(held) { _, new in new } }
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

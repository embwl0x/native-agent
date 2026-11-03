import Foundation
import NativeAgentShared
import PersistenceCore
import DeviceSync
import NativeAgentCore
import NotificationInbox
// Blueprint: | `AttentionRouter+MemoryReview.swift` | Memory-review source crossings retain a cycle identity; only the common native destination ledger records acceptance; below-threshold sources supersede unsent reminders |

extension NativeAgentNotifications {
    static let memoryReviewEventKey = "memoryReviewReminder.eventID"

    /// Defaults holds ONLY the source cycle, never a copy of delivery state.
    @MainActor public static func postMemoryReview(pending: Int, agentName: String) {
        let defaults = UserDefaults.standard
        let existing = defaults.object(forKey: memoryReviewEventKey)
        guard existing == nil || (existing as? String)?.isEmpty == false else {
            nativeLog("Memory-review source identity is unreadable; no notification admitted")
            return
        }
        let previous = existing as? String
        if let previous, !previous.hasPrefix("review:"), !previous.hasPrefix("below:") {
            nativeLog("Memory-review source cycle has an unsupported identity; no notification admitted")
            return
        }
        // DATA PRESENT format: an old false flag meant the old producer spent
        // its crossing before attempting delivery. That proves only uncertainty.
        let oldSpent: Bool
        if previous == nil, let saved = defaults.object(forKey: "memoryReviewReminder.belowThreshold") {
            guard let armed = saved as? Bool else {
                nativeLog("Retained memory-review crossing is unreadable; no notification admitted")
                return
            }
            oldSpent = !armed
        } else { oldSpent = false }
        let below = pending < 10
        let cycle: String
        if let previous, previous.hasPrefix("below:") == below { cycle = previous }
        else {
            cycle = (below ? "below:" : "review:") + UUID().uuidString.lowercased()
            defaults.set(cycle, forKey: memoryReviewEventKey)
        }
        Task {
            let root = PersistenceCore.defaultDataRoot()
            let ledger = NotificationDeliveryLedger(dataRoot: root)
            let event = NativeAgentDeviceEventIdentity.notification(userInfo: ["eventId": "memory-review"]) + ":mac"
            do {
                let state = try ledger.read()
                let id: String
                if let current = state.current[event], state.entries[current]?.occurrence.sourceRevision == cycle { id = current }
                else {
                    let occurrence = try NotificationOccurrence(eventID: event, cardID: nil,
                        title: "Memories to look over",
                        body: "\(pending) things \(agentName) wants to keep are waiting for your yes or no on the Memories page.",
                        reason: cycle, userInfo: [memoryReviewEventKey: cycle, NativeAgentNotificationRoute.pageKey: "memories"],
                        importance: AttentionImportance.ownerWaiting.rawValue, route: AttentionDelivery.none.rawValue,
                        destinations: below ? [] : ["mac"], sourceRevision: cycle)
                    id = try await ledger.retain(occurrence,
                        priorOutcome: oldSpent ? .unknown(sent: true, reason: "Old producer spent the review crossing before a checked delivery receipt") : nil,
                        isCurrent: { UserDefaults.standard.string(forKey: memoryReviewEventKey) == cycle })
                }
                guard !below else { return }
                if AttentionRouter.holdsResidentWake(session: nil, dataRoot: root) {
                    try await LiveNotificationInbox.hold(dataRoot: root, title: "Memories to look over", body: "Memories are waiting for review.",
                        ways: [], id: "held:" + id, fields: ["notification_occurrence_id": .string(id)])
                    return
                }
                let result = await deliverOccurrence(id, dataRoot: root)
                if let error = result.error { nativeLog("Memory review %@: %@", id, error) }
            } catch { nativeLog("Memory-review delivery remains unavailable: %@", error.localizedDescription) }
        }
    }
}

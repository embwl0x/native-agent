import Foundation
import NativeAgentShared
import PersistenceCore
import DeviceSync
import NativeAgentCore
import Experiences
// Blueprint: | `AttentionRouter+MemoryReview.swift` | Memory-review crossing tells one Mac matter; dropping below threshold resolves that matter |

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
        let below = pending < 10
        let cycle: String
        if let previous, previous.hasPrefix("below:") == below { cycle = previous }
        else {
            cycle = (below ? "below:" : "review:") + UUID().uuidString.lowercased()
            defaults.set(cycle, forKey: memoryReviewEventKey)
        }
        Task {
            let root = PersistenceCore.defaultDataRoot()
            do {
                let forPerson = ForPerson.at(root)
                guard UserDefaults.standard.string(forKey: memoryReviewEventKey) == cycle else { return }
                if below {
                    for matter in try await forPerson.matters() where matter.face?.from == "memory_review" && matter.outcome == nil {
                        guard UserDefaults.standard.string(forKey: memoryReviewEventKey) == cycle else { return }
                        try await forPerson.putAway(matter.id, .resolved)
                    }
                    return
                }
                guard UserDefaults.standard.string(forKey: memoryReviewEventKey) == cycle else { return }
                try await forPerson.tell(Matter(id: "memory-review:" + cycle, form: .words, from: "memory_review",
                    title: "Memories to look over",
                    summary: "\(pending) things \(agentName) wants to keep are waiting for your yes or no on the Memories page.",
                    symbol: "brain", open: "page:memories"), doors: [.mac])
            } catch { nativeLog("Memory-review delivery remains unavailable: %@", error.localizedDescription) }
        }
    }
}

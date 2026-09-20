import Foundation

/// One nudge when the pile of memories waiting for a yes or no gets tall.
///
/// Proposals wait on the Memories page, which is off to the side, so they are
/// easy to forget; at twenty-four waiting the memory lane stops staging new
/// ones. The reminder fires ONCE as the count reaches ten and stays quiet until
/// the pile has been worked back under ten. It is a nudge, not a nag: no repeat,
/// no daily timer, nothing when the count is merely still high.
enum MemoryReviewReminder {
    static let threshold = 10
    private static let armedKey = "memoryReviewReminder.belowThreshold"

    static func consider(pending: Int, agentName: String) {
        let defaults = UserDefaults.standard
        // Absent key reads as armed, so a first crossing on an existing pile fires.
        let armed = defaults.object(forKey: armedKey) as? Bool ?? true
        if pending < threshold {
            if !armed { defaults.set(true, forKey: armedKey) }
            return
        }
        guard armed else { return }
        defaults.set(false, forKey: armedKey)
        NativeAgentNotifications.post(
            title: "Memories to look over",
            body: "\(DeskPageWords.spelled(pending)) things \(agentName) wants to keep are waiting for your yes or no on the Memories page."
        )
    }
}

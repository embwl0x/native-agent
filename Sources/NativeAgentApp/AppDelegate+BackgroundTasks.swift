import Foundation
import AppKit
import BackgroundLoops
import NativeAgentShared

extension AppDelegate {
    // Swift-native cutover/fin-integration: NSBackgroundActivityScheduler entries.
    // No periodic dream wrapper is registered here: unattended dreams have
    // exactly one owner, the `nativeagent-nightly-dream` TriggerScheduler job at
    // 03:30 America/Chicago.
    //
    // RETIRED 2026-08-31: `rem_cycle`. Weekly REM has exactly one owner, the
    // `nativeagent-weekly-rem` TriggerScheduler job (Sun 04:30 America/Chicago
    // → NativeClient.runRem). Live evidence: every row in
    // `data/rem_proposals.jsonl` and every `rem.proposal` approval card carries
    // a Sunday ~09:30Z stamp — the scheduler job's minute. The duplicate loop's
    // own weekly tick (last 2026-08-28T14:43:32Z) has never produced a single
    // proposal, so it would have tripped DoctorLoopHealth's dormancy bound
    // (~2026-09-18) while the real lane was healthy.
    static var bgTaskIdentifiers: [String] {
        [
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("memory_consolidation"),
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("self_improvement_sweep"),
        ]
    }

    /// Activity identifiers an OLDER build scheduled with `repeats = true`.
    /// NSBackgroundActivityScheduler persists those registrations per bundle,
    /// so dropping a row from `bgTaskIdentifiers` is not enough — the OS keeps
    /// waking the retired identifier until something invalidates it.
    private static var retiredTaskIdentifiers: [String] {
        [
            // Loose-cadence dream wrapper: the 03:30 Central scheduler job owns
            // unattended dreams, and this could wake independently of it.
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("dream_cycle"),
            // Duplicate weekly REM lane (retired 2026-08-31) — see above.
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("rem_cycle"),
        ]
    }

    private static var backgroundLoopIDsByTaskIdentifier: [String: String] {
        [
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("memory_consolidation"): "memory_consolidation",
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("self_improvement_sweep"): "self_improvement_sweep",
        ]
    }

    private static var backgroundTaskIntervalsByIdentifier: [String: TimeInterval] {
        [
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("memory_consolidation"): 7 * 24 * 60 * 60,
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("self_improvement_sweep"): 7 * 24 * 60 * 60,
        ]
    }

    static func registerBackgroundTaskHandlers() {
        // Cancel every retired activity an older build may still have on the
        // OS scheduler. Dropping the row from `bgTaskIdentifiers` alone leaves
        // the persisted registration waking forever.
        for retired in retiredTaskIdentifiers {
            NSBackgroundActivityScheduler(identifier: retired).invalidate()
        }

        // BGTaskScheduler is iOS-only; on macOS use NSBackgroundActivityScheduler.
        for id in bgTaskIdentifiers {
            let activity = NSBackgroundActivityScheduler(identifier: id)
            guard let interval = backgroundTaskIntervalsByIdentifier[id],
                  let loopId = backgroundLoopIDsByTaskIdentifier[id] else { continue }
            activity.interval = interval
            activity.tolerance = 12 * 60 * 60
            activity.repeats = true
            activity.qualityOfService = .utility
            activity.schedule { completion in
                Task.detached(priority: .utility) {
                    let outcome = await BackgroundLoopsManager.shared.runTickIfDue(loopId: loopId)
                    if case .failed = outcome {
                        completion(.deferred)
                    } else {
                        completion(.finished)
                    }
                }
            }
        }
    }
}

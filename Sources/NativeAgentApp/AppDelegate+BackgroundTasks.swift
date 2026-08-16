import Foundation
import AppKit
import BackgroundLoops
import NativeAgentShared

extension AppDelegate {
    // Swift-native cutover/fin-integration: NSBackgroundActivityScheduler entries.
    // No periodic dream wrapper is registered here: unattended dreams have
    // exactly one owner, the `nativeagent-nightly-dream` TriggerScheduler job at
    // 03:30 America/Chicago.
    static var bgTaskIdentifiers: [String] {
        [
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("rem_cycle"),
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("memory_consolidation"),
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("self_improvement_sweep"),
        ]
    }

    private static var retiredDreamTaskIdentifier: String {
        NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("dream_cycle")
    }

    private static var backgroundLoopIDsByTaskIdentifier: [String: String] {
        [
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("rem_cycle"): "rem_cycle",
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("memory_consolidation"): "memory_consolidation",
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("self_improvement_sweep"): "self_improvement_sweep",
        ]
    }

    private static var backgroundTaskIntervalsByIdentifier: [String: TimeInterval] {
        [
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("rem_cycle"): 7 * 24 * 60 * 60,
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("memory_consolidation"): 7 * 24 * 60 * 60,
            NativeAgentICloudBridgeConstants.backgroundTaskIdentifier("self_improvement_sweep"): 7 * 24 * 60 * 60,
        ]
    }

    static func registerBackgroundTaskHandlers() {
        // Cancel retired loose-cadence dream activity from older builds. It
        // could otherwise wake independently of the 03:30 Central scheduler.
        NSBackgroundActivityScheduler(identifier: retiredDreamTaskIdentifier).invalidate()

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

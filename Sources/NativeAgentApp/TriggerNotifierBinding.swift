import Foundation
import AttentionRouting
import PersistenceCore
import TriggerScheduler
import DeviceSync

/// App composition for Core's trigger inbox and attention-routing owners.
enum TriggerNotifierBinding {
    static let pairedDevicePush: TriggerNotifier = { note in
        await TriggerNotificationDelivery.notify(
            note, delivery: AppTriggerSnapshotDelivery(), router: { .shared }
        )
    }

    @discardableResult
    static func mirrorNonNotifiedFire(
        _ result: TriggerFireResult,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> Bool {
        await TriggerNotificationInbox.mirrorNonNotifiedFire(
            result, dataRoot: dataRoot, delivery: AppTriggerSnapshotDelivery()
        )
    }

    /// The scheduler the two FIRE call sites use — the event/deadline due-work
    /// runner and manual "fire now". Every other call site (list / enable / disable /
    /// configure) keeps the plain `makeTriggerScheduler()`: they never fire, so
    /// they must never carry a sender.
    static func makeNotifyingTriggerScheduler(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> any TriggerSchedulerClient {
        // L5 G3: manual "fire now" is a FIRE site, so it gets the same brief a
        // scheduled fire gets — synthesized lead over deterministic evidence.
        // A "fire now" that produced a visibly different brief from the 8am one
        // would make the button useless for checking what the 8am one will say.
        let isLiveRoot = dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        return makeTriggerScheduler(
            notifier: isLiveRoot ? pairedDevicePush : nil,
            dataRoot: dataRoot,
            morningBriefSynthesizer: isLiveRoot
                ? BackgroundLoopsAssembly.makeMorningBriefSynthesizer()
                : nil
        )
    }
}

private struct AppTriggerSnapshotDelivery: TriggerSnapshotDeliveryPort {
    func writeSnapshots() async {
        await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots()
    }
}

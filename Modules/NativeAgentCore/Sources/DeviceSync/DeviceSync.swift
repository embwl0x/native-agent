import Foundation
import Cognition
import NativeAgentShared

// The app's names for the NativeAgentShared variants, kept in the moved code
// so every unqualified reference resolves the way it did in the app.
typealias MemoryRecord = NativeAgentShared.MemoryRecord
typealias MultimodalAttachment = NativeAgentShared.MultimodalAttachment
typealias ChatSession = NativeAgentShared.ChatSession

/// One engine root's device sync: the CloudKit/KVS bridge to the phone, the
/// snapshot writer and signed inbox, paired phones, the phone's Mac
/// integration projection, APNs and the mobile notification relay.
@MainActor
public final class DeviceSync {
    public nonisolated let dataRoot: URL
    nonisolated let host: any DeviceSyncHost
    nonisolated let cognition: NativeCognitionRuntime
    public nonisolated let apns = SwiftNativeAPNSSender()
    nonisolated let needsUser: NeedsUserEdgeNotifier

    public lazy var bridge = iCloudBridge(sync: self)
    public lazy var engine = MacSyncEngine(sync: self, stateDataRootOverride: nil)
    public lazy var relay = MacSyncMobileNotificationRelay(sync: self)
    public lazy var pairedPhones = PairedPhoneStore(url: dataRoot.appendingPathComponent("paired_phones.json"))
    public lazy var macIntegrationPermissions = MacIntegrationICloudBridge()

    public nonisolated init(dataRoot: URL, host: any DeviceSyncHost, cognition: NativeCognitionRuntime) {
        self.dataRoot = dataRoot
        self.host = host
        self.cognition = cognition
        self.needsUser = NeedsUserEdgeNotifier(dataRoot: dataRoot) { title, body, userInfo in
            try await host.knockNeedsUser(title: title, body: body, userInfo: userInfo)
        }
    }
}

extension Notification.Name {
    /// Posted once the Mac has processed a phone's inbox action.
    public static let iCloudInboxDidProcess = Notification.Name("NativeAgent.iCloudInboxDidProcess")
}

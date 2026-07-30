// ICloudBridgeConstants.swift — shared iCloud bridge namespace.
//
// Mac and iOS both use these values as wire/storage paths. Keeping them in the
// shared module prevents one side from silently drifting from the other.
import Foundation

public enum NativeAgentICloudBridgeConstants {
    public static let defaultContainerID = "iCloud.io.github.embwl0x.nativeagent"
    public static let defaultMobileSourceKey = "mobile_app"
    public static let defaultMacBundleID = "io.github.embwl0x.nativeagent.mac"
    public static let defaultBackgroundTaskIDPrefix = "io.github.embwl0x.nativeagent"

    public static var containerID: String {
        configuredValue(
            infoKey: "NativeAgentICloudContainerID",
            envKey: "NATIVEAGENT_ICLOUD_CONTAINER_ID",
            defaultValue: defaultContainerID
        )
    }

    public static var mobileSourceKey: String {
        configuredValue(
            infoKey: "NativeAgentMobileSourceKey",
            envKey: "NATIVEAGENT_MOBILE_SOURCE_KEY",
            defaultValue: defaultMobileSourceKey
        )
    }

    public static var macBundleID: String {
        configuredValue(
            infoKey: "NativeAgentMacBundleID",
            envKey: "NATIVEAGENT_MAC_BUNDLE_ID",
            defaultValue: defaultMacBundleID
        )
    }

    public static var backgroundTaskIDPrefix: String {
        configuredValue(
            infoKey: "NativeAgentBackgroundTaskIDPrefix",
            envKey: "NATIVEAGENT_BACKGROUND_TASK_PREFIX",
            defaultValue: defaultBackgroundTaskIDPrefix
        )
    }

    public static var mobileDocumentsFolderName: String {
        containerID.replacingOccurrences(of: ".", with: "~")
    }

    public static func isMobileSourceKey(_ sourceKey: String?) -> Bool {
        guard let raw = sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return false
        }
        return raw == mobileSourceKey
    }

    public static func backgroundTaskIdentifier(_ suffix: String) -> String {
        "\(backgroundTaskIDPrefix).\(suffix)"
    }

    private static func configuredValue(infoKey: String, envKey: String, defaultValue: String) -> String {
        if let value = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           !value.contains("$(") {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains("$(") {
                return trimmed
            }
        }
        return defaultValue
    }

    public enum KVSKey {
        public static let macToIosPrefix = "mac_to_ios:"
        public static let iosToMacPrefix = "ios_to_mac:"
        public static let macStatus = "mac_status"
        public static let iosStatus = "ios_status"
        public static let newMessageInDrive = "new_msg_in_drive"
        public static let chatProgressLatest = "chat_progress_latest"
    }

    public enum DriveFolder {
        public static let outboxMac = "outbox/mac"
        public static let outboxIos = "outbox/ios"
        public static let processing = "processing"
        public static let processed = "processed"
    }
}

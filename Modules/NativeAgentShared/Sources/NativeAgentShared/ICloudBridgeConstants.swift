// ICloudBridgeConstants.swift — shared iCloud bridge namespace.
//
// Mac and iOS both use these values as wire/storage paths. Keeping them in the
// shared module prevents one side from silently drifting from the other.
import Foundation

// Blueprint: | `ICloudBridgeConstants.swift` | Checked bundle-owned iCloud identity, mobile source and background task identifiers; shared retained Drive and current KVS namespaces |

public enum NativeAgentICloudBridgeConstants {
    public static var containerID: String {
        get throws {
            let value = try configuredValue(infoKey: "NativeAgentICloudContainerID")
            guard value.hasPrefix("iCloud."), validDottedIdentifier(value), value.split(separator: ".").count >= 3 else {
                throw ConfigurationFailure(infoKey: "NativeAgentICloudContainerID")
            }
            return value
        }
    }

    public static var mobileSourceKey: String {
        get throws { try configuredValue(infoKey: "NativeAgentMobileSourceKey") }
    }

    public static var backgroundTaskIDPrefix: String {
        get throws {
            let value = try configuredValue(infoKey: "NativeAgentBackgroundTaskIDPrefix")
            guard validDottedIdentifier(value), value.contains(".") else {
                throw ConfigurationFailure(infoKey: "NativeAgentBackgroundTaskIDPrefix")
            }
            return value
        }
    }

    public static func backgroundTaskIdentifier(_ suffix: String) throws -> String {
        "\(try backgroundTaskIDPrefix).\(suffix)"
    }

    public struct ConfigurationFailure: LocalizedError, Sendable {
        public let infoKey: String
        public var errorDescription: String? {
            "NativeAgent build configuration '\(infoKey)' is missing or invalid. Install a build with resolved iCloud identifiers."
        }
    }

    /// The signed bundle is the one runtime configuration. Source-build defaults
    /// belong in xcconfig, never in an environment override or a failed read.
    private static func configuredValue(infoKey: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
              !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte)
                      || (48...57).contains(byte) || byte == 45 || byte == 46 || byte == 95
              }) else { throw ConfigurationFailure(infoKey: infoKey) }
        return value
    }

    private static func validDottedIdentifier(_ value: String) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || byte == 45
            }
        }
    }

    public enum KVSKey {
        public static let newMessageInDrive = "new_msg_in_drive"
        public static let chatProgressLatest = "chat_progress_latest"
        /// Notices use their own latest-value key so tool progress cannot overwrite them in the same KVS sync.
        public static let chatNoticeLatest = "chat_notice_latest"
    }

    public enum DriveFolder {
        public static let outboxMac = "outbox/mac"
        public static let outboxIos = "outbox/ios"
        public static let processing = "processing"
        public static let processed = "processed"
    }
}

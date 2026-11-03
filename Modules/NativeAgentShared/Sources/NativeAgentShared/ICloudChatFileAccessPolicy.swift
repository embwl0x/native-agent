import Foundation

// Blueprint: | `ICloudChatFileAccessPolicy.swift` | `ICloudChatFileAccessPolicy.Mode`: shared closed Mac/phone file-access vocabulary; `normalized` preserves invalid input for refusal instead of selecting Auto |

/// Canonical file-access IDs carried by signed iPhone chat envelopes and
/// admitted by the Mac iCloud chat route. Keeping this at the transport
/// boundary prevents the control pill from advertising a mode the router does
/// not recognize.
public enum ICloudChatFileAccessPolicy {
    public enum Mode: String, CaseIterable, Sendable {
        case auto, readOnly = "read_only", workspace, full, none

        public init?(_ rawValue: String) {
            self.init(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    public static let acceptedIDs = Set(Mode.allCases.map(\.rawValue))

    /// Unknown or malformed remote metadata never reaches the chat dispatcher
    /// as a permissive access mode.
    public static func normalized(_ rawValue: String) -> String {
        Mode(rawValue)?.rawValue ?? rawValue
    }
}

import Foundation

/// Canonical file-access IDs carried by signed iPhone chat envelopes and
/// admitted by the Mac iCloud chat route. Keeping this at the transport
/// boundary prevents the control pill from advertising a mode the router does
/// not recognize.
public enum ICloudChatFileAccessPolicy {
    public static let acceptedIDs: Set<String> = ["auto", "read_only", "workspace", "full"]

    /// Unknown or malformed remote metadata never reaches the chat dispatcher
    /// as a permissive access mode.
    public static func normalized(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return acceptedIDs.contains(value) ? value : "auto"
    }
}

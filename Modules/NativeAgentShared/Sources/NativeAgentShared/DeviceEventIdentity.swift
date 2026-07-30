import CryptoKit
import Foundation

/// Stable, payload-free identity for one user-visible cross-device event.
///
/// The same semantic key produces the same 64-byte-safe APNS collapse id,
/// iCloud notification id, and local snapshot notification id. Content is not
/// part of identity: changing prose cannot create another alert for one event.
public enum NativeAgentDeviceEventIdentity {
    private static let canonicalHexCount = 64

    public static func notification(
        userInfo: [String: String],
        fallback: @autoclosure () -> String = UUID().uuidString
    ) -> String {
        if let explicit = clean(userInfo["eventId"]), isCanonical(explicit) {
            return explicit.lowercased()
        }
        let keys = ["eventId", "dedupKey", "itemId", "approvalId", "taskId", "githubCommandItemId", "trigger"]
        for key in keys {
            if let value = clean(userInfo[key]) {
                return digest("notification:\(key):\(value)")
            }
        }
        return digest("notification:fallback:\(fallback())")
    }

    public static func isCanonical(_ value: String) -> Bool {
        value.utf8.count == canonicalHexCount
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            }
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

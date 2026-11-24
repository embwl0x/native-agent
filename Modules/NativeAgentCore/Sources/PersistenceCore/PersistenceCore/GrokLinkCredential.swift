import CoreFoundation
import Foundation
import Security
// Blueprint: | `GrokLinkCredential.swift` | `GrokLinkCredential`, `GrokReplyInput` |

/// Shared by the signed app and its signed local helper. Never serialize this value outside Keychain or expose it in a tool/approval projection.
public struct GrokLinkCredential: Codable, Sendable {
    public var descriptorPath: String
    public var replyToken: String
    public var webhookURL: String?
    public var webhookKey: String?

    public init(descriptorPath: String, replyToken: String) {
        self.descriptorPath = descriptorPath; self.replyToken = replyToken
    }

    public enum Failure: Error, LocalizedError {
        case unavailable, invalid
        public var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Grok Bot's saved connection credentials are unavailable. Connect Grok Bot again to finish secure setup."
            case .invalid:
                return "Grok Bot connection data failed validation. Connect Grok Bot again to finish setup."
            }
        }
    }
    private static func query(_ peer: String) throws -> [String: Any] {
        guard UUID(uuidString: peer)?.uuidString.lowercased() == peer else { throw Failure.invalid }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.nativeagent.grok-reply",
                kSecAttrAccount as String: peer,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    public static func read(peer: String) throws -> Self {
        var q = try query(peer)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard unsafe SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count <= 16_384,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { throw Failure.unavailable }
        return value
    }
    public func write(peer: String, helperPath: String? = nil) throws {
        let q = try Self.query(peer)
        let data = try JSONEncoder().encode(self)
        guard data.count <= 16_384 else { throw Failure.invalid }
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add.removeValue(forKey: kSecUseAuthenticationUI as String)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if let helperPath {
                var app: SecTrustedApplication?
                var helper: SecTrustedApplication?
                guard SecTrustedApplicationCreateFromPath(nil, &app) == errSecSuccess,
                      SecTrustedApplicationCreateFromPath(helperPath, &helper) == errSecSuccess,
                      let app, let helper else { throw Failure.unavailable }
                var access: SecAccess?
                guard SecAccessCreate("NativeAgent Grok reply" as CFString, [app, helper] as CFArray, &access) == errSecSuccess,
                      let access else { throw Failure.unavailable }
                add[kSecAttrAccess as String] = access
            }
            guard unsafe SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        } else if status != errSecSuccess { throw Failure.unavailable }
    }
    public static func delete(peer: String) throws {
        let status = SecItemDelete(try query(peer) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
    }
    private static func usableURL(_ url: String) -> Bool {
        guard url.utf8.count <= 4096, let parts = URLComponents(string: url) else { return false }
        return parts.scheme == "https" && parts.host?.isEmpty == false && parts.user == nil && parts.password == nil && parts.fragment == nil
    }
    private static func usableKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 8192 && key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 })
    }
    /// What one paste names. Accepted forms: `{"url":"…","key":"…"}`; the webhook address and the key one after the other, separated by a space or a new
    /// line (in either order); or either one alone. Nil: none of these.
    public static func pasted(_ text: String) -> (url: String?, key: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 16_384 else { return nil }
        if trimmed.hasPrefix("{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: String],
                  Set(object.keys) == ["url", "key"] else { return nil }
            return (object["url"], object["key"])
        }
        var url: String?, key: String?
        for part in trimmed.split(whereSeparator: \.isWhitespace).map(String.init) {
            if part.lowercased().hasPrefix("https://") {
                guard url == nil else { return nil }
                url = part
            } else {
                guard key == nil else { return nil }
                key = part
            }
        }
        return (url, key)
    }
    /// Take a pasted address and/or key; the other part already saved stays.
    public mutating func takePasted(url: String?, key: String?) throws {
        if let url { guard Self.usableURL(url) else { throw Failure.invalid } }
        if let key { guard Self.usableKey(key) else { throw Failure.invalid } }
        if let url { webhookURL = url }
        if let key { webhookKey = key }
    }
    public var webhookComplete: Bool { webhookURL != nil && webhookKey != nil }
}

public struct GrokReplyInput: Codable, Sendable {
    public let message_id: String
    public let text: String
    public static let maximumBytes = 70_000
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["message_id", "text"],
              let messageID = object["message_id"] as? String,
              let text = object["text"] as? String,
              UUID(uuidString: messageID)?.uuidString.lowercased() == messageID,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 64_000 else { throw GrokLinkCredential.Failure.invalid }
        return Self(message_id: messageID, text: text)
    }
}

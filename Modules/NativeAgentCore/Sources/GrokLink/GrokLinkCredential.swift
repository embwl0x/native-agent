import Foundation
import Security

/// Shared by the signed app and its signed local helper. Never serialize this
/// value outside Keychain or expose it in a tool/approval projection.
public struct GrokLinkCredential: Codable, Sendable {
    public var descriptorPath: String
    public var replyToken: String
    public var webhookURL: String?
    public var webhookKey: String?

    public init(descriptorPath: String, replyToken: String) {
        self.descriptorPath = descriptorPath; self.replyToken = replyToken
    }

    public enum Failure: Error { case unavailable, invalid }
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
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
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
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        } else if status != errSecSuccess { throw Failure.unavailable }
    }
    public static func delete(peer: String) throws {
        let status = SecItemDelete(try query(peer) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
    }
    public mutating func importWebhook(url: String, key: String) throws {
        guard url.utf8.count <= 4096, let parts = URLComponents(string: url),
              parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              !key.isEmpty, key.utf8.count <= 8192,
              key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw Failure.invalid }
        webhookURL = url; webhookKey = key
    }
}

public struct GrokReplyInput: Codable, Sendable {
    public let message_id: String
    public let text: String
    public static let maximumBytes = 70_000
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["message_id", "text"],
              let value = try? JSONDecoder().decode(Self.self, from: data),
              UUID(uuidString: value.message_id)?.uuidString.lowercased() == value.message_id,
              !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.text.utf8.count <= 64_000 else { throw GrokLinkCredential.Failure.invalid }
        return value
    }
}

import Foundation
import Security

/// Device-only secret bytes. Callers own reference commits and serialize their
/// lifecycle with the same lock as the legacy file they replace.
public enum DeviceSecretKeychain {
    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    public static func read(service: String, account: String) throws -> Data? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.unavailable }
        return data
    }

    public static func insert(_ data: Data, service: String, account: String) throws {
        var item = query(service: service, account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        do {
            guard try read(service: service, account: account) == data else { throw Failure.unavailable }
        } catch {
            try? delete(service: service, account: account)
            throw Failure.unavailable
        }
    }

    public static func replace(_ data: Data, service: String, account: String) throws {
        guard let previous = try read(service: service, account: account) else { throw Failure.unavailable }
        let status = SecItemUpdate(query(service: service, account: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw Failure.unavailable }
        do {
            guard try read(service: service, account: account) == data else { throw Failure.unavailable }
        } catch {
            _ = SecItemUpdate(query(service: service, account: account) as CFDictionary,
                              [kSecValueData as String: previous] as CFDictionary)
            throw Failure.unavailable
        }
    }

    public static func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
    }

    public enum Failure: LocalizedError {
        case unavailable
        public var errorDescription: String? { "Device Keychain secret is unavailable." }
    }
}

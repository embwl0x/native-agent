import Foundation
import Security

/// ProviderRouting owns the config reference and this device-only Keychain
/// item. Immutable references keep the old config usable until its replacement
/// is committed. No credential bytes are written to provider JSON.
public enum ProviderAPIKeyStore {
    public static let referenceField = "api_key_keychain_ref"
    private static let service = "NativeAgent.provider-api-key"

    private static func query(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: reference,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    static func insert(_ key: String) throws -> String {
        let reference = UUID().uuidString
        var item = query(reference)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        do {
            guard try read(reference) == key else { throw Failure.unavailable }
        } catch {
            try? delete(reference)
            throw Failure.unavailable
        }
        return reference
    }

    public static func read(_ reference: String) throws -> String? {
        guard UUID(uuidString: reference) != nil else { throw Failure.unavailable }
        var request = query(reference)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw Failure.unavailable }
        return key
    }

    public static func delete(_ reference: String) throws {
        guard UUID(uuidString: reference) != nil else { throw Failure.unavailable }
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
    }

    private enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Provider Keychain credential is unavailable." }
    }
}

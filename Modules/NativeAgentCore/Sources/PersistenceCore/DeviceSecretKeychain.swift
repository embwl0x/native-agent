import Foundation
import Security
// Blueprint: | `DeviceSecretKeychain.swift` | Device-only Keychain bytes and account listing; accepted writes retain exact-item unverified evidence on readback failure, without restoration or deletion; callers own locked references |

/// Device-only secret bytes. Callers serialize the lifecycle and reference
/// commits under their authority owner's lock.
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

    /// Every account kept under `service`.
    public static func accounts(service: String) throws -> [String] {
        var request = query(service: service, account: "")
        request.removeValue(forKey: kSecAttrAccount as String)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw Failure.unavailable }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public static func insert(_ data: Data, service: String, account: String) throws {
        var item = query(service: service, account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        try verifyAcceptedWrite(data, service: service, account: account)
    }

    public static func replace(_ data: Data, service: String, account: String) throws {
        let status = SecItemUpdate(query(service: service, account: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw Failure.unavailable }
        try verifyAcceptedWrite(data, service: service, account: account)
    }

    /// Acceptance is real even when verification is unavailable. Never undo it;
    /// the caller must reread this exact item before a deliberate forward repair.
    private static func verifyAcceptedWrite(_ data: Data, service: String, account: String) throws {
        let observed: Data?
        do { observed = try read(service: service, account: account) }
        catch { throw Failure.acceptedButUnverified(service: service, account: account) }
        guard observed == data else {
            throw Failure.acceptedButUnverified(service: service, account: account)
        }
    }

    public static func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
    }

    public enum Failure: LocalizedError {
        case unavailable
        case acceptedButUnverified(service: String, account: String)
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "Device Keychain secret is unavailable."
            case .acceptedButUnverified(let service, let account):
                return "Keychain accepted the write to \(service)/\(account), but its bytes could not be verified. No restoration or deletion ran. Reread this exact item before deliberately repairing it; do not assume the prior secret is active."
            }
        }
    }
}

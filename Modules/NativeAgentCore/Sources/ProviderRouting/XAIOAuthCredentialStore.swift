import Foundation
import PersistenceCore

/// xAI credentials retain their locked metadata file; only immutable Keychain
/// references are committed there. Legacy token bytes migrate before use.
enum XAIOAuthCredentialStore {
    static let referenceField = "oauth_tokens_keychain_ref"
    private static let service = "NativeAgent.xai-oauth"
    private static let secretFields = ["access_token", "refresh_token", "id_token", "tokens"]

    static func read(at path: URL) throws -> [String: Any] {
        try CredentialFileLock.withLock(path) {
            guard let data = try ProviderStateValidation.dataIfPresent(at: path) else { return [:] }
            var object = try ProviderStateValidation.credential(data: data)
            if secretFields.contains(where: { object[$0] != nil }) {
                try write(object, to: path)
                object = try ProviderStateValidation.credential(data: Data(contentsOf: path))
            }
            return try resolve(object)
        }
    }

    static func resolve(_ object: [String: Any]) throws -> [String: Any] {
        guard let reference = object[referenceField] as? String else { return object }
        guard UUID(uuidString: reference) != nil,
              let data = try DeviceSecretKeychain.read(service: service, account: reference) else {
            throw DeviceSecretKeychain.Failure.unavailable
        }
        let secrets = try ProviderStateValidation.credential(data: data)
        var resolved = object
        for key in secretFields { resolved[key] = secrets[key] }
        return resolved
    }

    static func write(_ object: [String: Any], to path: URL) throws {
        try CredentialFileLock.withLock(path) {
            try ProviderStateValidation.credential(object)
            let previous = try ProviderStateValidation.dataIfPresent(at: path)
            let oldReference = previous.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?[referenceField] as? String
            let secrets = object.filter { secretFields.contains($0.key) }
            guard !secrets.isEmpty else { throw DeviceSecretKeychain.Failure.unavailable }
            let reference = UUID().uuidString
            let secretData = try JSONSerialization.data(withJSONObject: secrets, options: [.sortedKeys])
            try DeviceSecretKeychain.insert(secretData, service: service, account: reference)
            var metadata = object
            for key in secretFields { metadata.removeValue(forKey: key) }
            metadata[referenceField] = reference
            do {
                let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
                guard try Data(contentsOf: path) == data else { throw DeviceSecretKeychain.Failure.unavailable }
            } catch {
                if let previous { try SwiftNativePersistenceCore.writeDataAtomicDurable(previous, to: path) }
                else {
                    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                    try SwiftNativePersistenceCore.syncDirectory(path.deletingLastPathComponent())
                }
                try? DeviceSecretKeychain.delete(service: service, account: reference)
                throw error
            }
            if let oldReference, oldReference != reference {
                do { try DeviceSecretKeychain.delete(service: service, account: oldReference) }
                catch { nativeLog("[xAI] Credentials saved; previous Keychain item cleanup failed: %@", error.localizedDescription) }
            }
        }
    }

    static func remove(at path: URL) throws {
        try CredentialFileLock.withLock(path) {
            guard let data = try ProviderStateValidation.dataIfPresent(at: path) else { return }
            let object = try ProviderStateValidation.credential(data: data)
            if let reference = object[referenceField] as? String {
                try DeviceSecretKeychain.delete(service: service, account: reference)
            }
            try FileManager.default.removeItem(at: path)
        }
    }
}

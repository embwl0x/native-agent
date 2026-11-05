import Foundation
import PersistenceCore
import NativeAgentShared
// Blueprint: | `XAIOAuthCredentialStore.swift` | Locked xAI token storage, immutable Keychain references, refresh reads and sign-out cleanup |

/// xAI credentials retain their locked metadata file; only immutable Keychain references are committed there. Token bytes are resolved only from the
/// checked Keychain reference.
enum XAIOAuthCredentialStore {
    static let referenceField = "oauth_tokens_keychain_ref"
    private static let service = "NativeAgent.xai-oauth"
    private static let secretFields = ["access_token", "refresh_token", "id_token"]

    static func read(at path: URL) throws -> [String: Any] {
        try CredentialFileLock.withLock(path) {
            guard let data = try ProviderStateValidation.dataIfPresent(at: path) else { return [:] }
            return try resolve(ProviderStateValidation.credential(data: data), at: path)
        }
    }

    /// The caller validates and locks this metadata generation before resolving it.
    static func resolve(_ object: [String: Any], at path: URL) throws -> [String: Any] {
        guard object["tokens"] == nil, !secretFields.contains(where: { object[$0] != nil }) else {
            throw ProviderRoutingError.configurationFailed(
                "Saved xAI credentials contain plaintext tokens. Save the account through Providers to repair its Keychain storage.")
        }
        guard let reference = object[referenceField] as? String else { return object }
        guard UUID(uuidString: reference) != nil,
              let data = try DeviceSecretKeychain.read(service: service, account: reference) else {
            throw DeviceSecretKeychain.Failure.unavailable
        }
        let secrets = try ProviderStateValidation.credential(data: data)
        guard secrets["tokens"] == nil else {
            throw ProviderRoutingError.configurationFailed("Saved xAI credentials require a flat token set. Reconnect the account in Providers.")
        }
        var resolved = object
        for key in secretFields { resolved[key] = secrets[key] }
        return resolved
    }

    @discardableResult
    static func write(_ object: [String: Any], to path: URL) throws -> [String: Any] {
        try CredentialFileLock.withLock(path) {
            guard object["tokens"] == nil else {
                throw ProviderRoutingError.configurationFailed("xAI credentials require a flat token set; no credential was saved.")
            }
            try ProviderStateValidation.credential(object)
            let previous = try ProviderStateValidation.dataIfPresent(at: path)
            let oldMetadata = try previous.map { try ProviderStateValidation.credential(data: $0) }
            let oldReference = oldMetadata?[referenceField] as? String
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
                try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path.resolvingSymlinksInPath())
                guard try Data(contentsOf: path) == data else { throw DeviceSecretKeychain.Failure.unavailable }
                guard try DeviceSecretKeychain.read(service: service, account: reference) == secretData else {
                    throw DeviceSecretKeychain.Failure.unavailable
                }
            } catch {
                let persistenceFailure = error.localizedDescription
                let state: String
                do {
                    if let current = try ProviderStateValidation.dataIfPresent(at: path) {
                        let saved = try ProviderStateValidation.credential(data: current)
                        if saved[referenceField] as? String == reference {
                            state = "The new credential reference is on disk."
                        } else if current == previous {
                            state = "The preceding credential metadata is still on disk; its refresh grant may have been consumed."
                        } else {
                            state = "Different credential metadata is on disk."
                        }
                    } else { state = "The credential metadata is absent." }
                } catch {
                    throw ProviderRoutingError.configurationFailed("""
                        xAI credential save failed: \(persistenceFailure). Committed reference could not be read: \(error.localizedDescription). Keychain \
                        items were retained; repair the saved account in Providers.
                        """)
                }
                // Rotation may already be committed or may have consumed the preceding grant. Retain both items; never restore old authority.
                throw ProviderRoutingError.configurationFailed(
                    "xAI credential save failed: \(persistenceFailure). \(state) Keychain items were retained; repair the saved account in Providers.")
            }
            if let oldReference, oldReference != reference {
                do { try DeviceSecretKeychain.delete(service: service, account: oldReference) }
                catch { nativeLog("[xAI] Credentials saved; previous Keychain item cleanup failed: %@", error.localizedDescription) }
            }
            return metadata
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

import Foundation
import PersistenceCore
// Blueprint: | `ProviderAPIKeyStore.swift` | Provider reference/string validation; byte insertion, readback and deletion delegate to DeviceSecretKeychain |

/// ProviderRouting owns the config reference and this device-only Keychain
/// item. Immutable references keep the old config usable until its replacement
/// is committed. No credential bytes are written to provider JSON.
public enum ProviderAPIKeyStore {
    public static let referenceField = "api_key_keychain_ref"
    private static let service = "NativeAgent.provider-api-key"

    static func insert(_ key: String) throws -> String {
        guard !key.isEmpty else { throw Failure.unavailable }
        let reference = UUID().uuidString
        do {
            try DeviceSecretKeychain.insert(Data(key.utf8), service: service, account: reference)
        } catch { throw Failure.unavailable }
        return reference
    }

    public static func read(_ reference: String) throws -> String? {
        guard UUID(uuidString: reference) != nil else { throw Failure.unavailable }
        do {
            guard let data = try DeviceSecretKeychain.read(service: service, account: reference) else { return nil }
            guard let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw Failure.unavailable }
            return key
        } catch {
            throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                detail: "Provider Keychain read: \(ProviderFailure.diagnosticDescription(error))")
        }
    }

    public static func delete(_ reference: String) throws {
        guard UUID(uuidString: reference) != nil else { throw Failure.unavailable }
        do { try DeviceSecretKeychain.delete(service: service, account: reference) }
        catch { throw Failure.unavailable }
    }

    private enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Provider Keychain credential is unavailable." }
    }
}

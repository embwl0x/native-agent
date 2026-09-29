import Foundation
import Darwin
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

/// Checked inputs for provider credential mutations. Listing and routing retain
/// their own read contracts; unrelated registry rows are never a mutation gate.
public enum ProviderStateValidation {
    public static func dataIfPresent(at path: URL) throws -> Data? {
        var info = stat()
        if lstat(path.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw invalid("provider file is unreadable")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw invalid("provider file must be a regular file")
        }
        return try Data(contentsOf: path)
    }

    public static func credential(at path: URL) throws -> [String: Any] {
        guard let data = try dataIfPresent(at: path) else { return [:] }
        return try credential(data: data)
    }

    public static func credential(data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalid("provider credential must be an object")
        }
        try credential(object)
        return object
    }

    public static func credential(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw invalid("provider credential must be an object")
        }
        try credentialFields(fields)
    }

    public static func credentialFields(_ fields: [String: JSONValue]) throws {
        try strings(fields, ["provider_id", "auth_mode", "authMode", "api_key", "apiKey", "key",
            "access_token", "accessToken", "setup_token", "token", "refresh_token", "id_token", "account_id",
            "default_model", "defaultModel", "model", "client_id", "scope", "base_url",
            "redirect_uri", "token_type", "last_refresh", "email",
            "oauth_account_identity", "refresh_token_account_identity"])
        if let value = fields[ProviderAPIKeyStore.referenceField] {
            guard case .string(let reference) = value, UUID(uuidString: reference) != nil else {
                throw invalid("provider Keychain reference must be a UUID string")
            }
        }
        if let value = fields["OPENAI_API_KEY"], value != .null {
            try strings(["OPENAI_API_KEY": value], ["OPENAI_API_KEY"])
        }
        for key in ["expires_at", "expires_in", "expiresAt"] {
            if let value = fields[key] {
                if key == "expires_in" {
                    switch value {
                    case .int(let seconds) where seconds >= 0: break
                    case .double(let seconds) where seconds >= 0 && Int(exactly: seconds.rounded(.towardZero)) != nil: break
                    case .string(let seconds) where Int(seconds).map({ $0 >= 0 }) == true: break
                    default: throw invalid("provider expires_in must be a nonnegative number of seconds")
                    }
                    continue
                }
                switch value {
                case .int: break
                case .double(let number) where number.isFinite: break
                case .string(let string) where SwiftNativeProviderRouting.parseAuthExpiresAt(string)?.timeIntervalSince1970.isFinite == true: break
                default: throw invalid("provider \(key) must be a valid expiry")
                }
            }
        }
        for key in ["tokens", "discovery", "user_info"] {
            if let value = fields[key] {
                guard case .object(let nested) = value else { throw invalid("provider \(key) must be an object") }
                if key == "tokens" { try credentialFields(nested) }
                if key == "discovery" { try strings(nested, ["authorization_endpoint", "token_endpoint"]) }
                if key == "user_info" { try strings(nested, ["email", "name", "id"]) }
            }
        }
    }

    /// Decode only the row being removed with routing's supported Provider codec.
    /// A nil result means the registry is absent or has no matching row to change.
    public static func registryRemovingProvider(at path: URL, providerID: String) throws -> [JSONValue]? {
        guard let data = try dataIfPresent(at: path) else { return nil }
        guard case .array(let rows) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw invalid("provider registry must be an array")
        }
        var matchingIndex: Int?
        for (index, row) in rows.enumerated() {
            guard case .object(let fields) = row else { continue }
            let id = ["id", "provider_id", "providerId"].compactMap { key -> String? in
                if case .string(let value)? = fields[key] { return value }
                return nil
            }.first
            guard id == providerID else { continue }
            _ = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(row))
            guard matchingIndex == nil else { throw invalid("provider registry identity is invalid or duplicated") }
            matchingIndex = index
        }
        guard let matchingIndex else { return nil }
        var remaining = rows
        remaining.remove(at: matchingIndex)
        return remaining
    }

    private static func strings(_ fields: [String: JSONValue], _ keys: [String], nullable: Bool = false) throws {
        for key in keys {
            guard let value = fields[key] else { continue }
            if nullable, value == .null { continue }
            guard case .string = value else { throw invalid("provider field \(key) must be a string") }
        }
    }

    private static func invalid(_ detail: String) -> ProviderRoutingError {
        .underlying("Saved \(detail). Repair the saved state before changing providers.")
    }
}

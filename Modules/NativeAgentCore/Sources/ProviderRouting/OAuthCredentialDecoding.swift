import Foundation

public func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var body = String(parts[1])
    while body.count % 4 != 0 { body.append("=") }
    body = body.replacingOccurrences(of: "-", with: "+")
               .replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: body),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
}

public func parseExpiresAt(_ raw: Any?) -> Date? {
    SwiftNativeProviderRouting.parseAuthExpiresAt(raw)
}

/// A refresh belongs to one sign-in. If the endpoint supplies no identity,
/// a fresh local sign-in ID still prevents borrowing a previous grant.
public enum OAuthRefreshBinding {
    static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func identity(_ tokens: [String: Any], provider: String) -> String? {
        switch provider {
        case "anthropic_oauth_direct":
            let account = tokens["account"] as? [String: Any] ?? [:]
            let user = tokens["user_info"] as? [String: Any] ?? [:]
            return string(account["uuid"]) ?? string(user["id"]) ?? string(user["email"])
        case "openai_oauth_direct":
            let access = string(tokens["access_token"]).flatMap(jwtPayload) ?? [:]
            let auth = access["https://api.openai.com/auth"] as? [String: Any] ?? [:]
            return string(auth["chatgpt_account_id"]) ?? string(tokens["account_id"])
        default:
            let claims = string(tokens["id_token"]).flatMap(jwtPayload) ?? [:]
            return string(claims["sub"])
        }
    }

    static func bindSignIn(_ tokens: inout [String: Any], provider: String) {
        let identity = identity(tokens, provider: provider) ?? "sign-in:\(UUID().uuidString)"
        tokens["oauth_account_identity"] = identity
        tokens["refresh_token_account_identity"] = string(tokens["refresh_token"]) == nil ? nil : identity
    }

    static func tokenSet(_ object: [String: Any], provider: String) -> [String: Any] {
        // Read a complete token set, never mix top-level access with nested refresh.
        if provider == "openai_oauth_direct" || (object["access_token"] == nil && object["refresh_token"] == nil) {
            return object["tokens"] as? [String: Any] ?? [:]
        }
        return object
    }

    public static func permitsRefresh(_ object: [String: Any], provider: String) -> Bool {
        let tokens = tokenSet(object, provider: provider)
        guard let account = string(tokens["oauth_account_identity"]),
              account == string(tokens["refresh_token_account_identity"]) else { return false }
        return identity(tokens, provider: provider).map { $0 == account } ?? true
    }

    static func requireSameAccount(_ response: [String: Any], original: [String: Any], provider: String) throws {
        let tokens = tokenSet(original, provider: provider)
        if let identity = identity(response, provider: provider), identity != string(tokens["oauth_account_identity"]) {
            throw LLMError.authRejected(provider: provider,
                detail: "Saved refresh authorization does not match this sign-in. Sign in again.")
        }
    }

    static func requireRefresh(_ object: [String: Any], provider: String) throws {
        guard permitsRefresh(object, provider: provider) else {
            throw LLMError.authRejected(provider: provider,
                detail: "Saved refresh authorization does not match this sign-in. Sign in again.")
        }
    }
}

/// Lives for one request, including its refresh queue wait and HTTP retry.
/// Access-only credentials can continue unchanged, but cannot adopt a new token
/// without a recorded account binding. Read-only CLI sessions can instead
/// prove account continuity from their token identity.
final class OAuthRequestAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var original: (account: String?, access: String?)?

    func check(_ object: [String: Any], provider: String, rejectedToken: String? = nil,
               allowUnboundIdentity: Bool = false) throws {
        let tokens = OAuthRefreshBinding.tokenSet(object, provider: provider)
        let account = OAuthRefreshBinding.string(tokens["oauth_account_identity"])
            ?? (allowUnboundIdentity ? OAuthRefreshBinding.identity(tokens, provider: provider) : nil)
        let access = OAuthRefreshBinding.string(tokens["access_token"])
        lock.lock()
        defer { lock.unlock() }
        if let original {
            guard let expected = original.account, account == expected else {
                guard original.account == nil, account == nil,
                      let priorAccess = original.access, access == priorAccess else {
                    throw Self.changed(provider)
                }
                return
            }
        } else {
            // Token-only callers can prove continuity with the rejected JWT's
            // account claim; opaque tokens require the retained request binding.
            if let rejectedToken, rejectedToken != access {
                guard let rejectedAccount = OAuthRefreshBinding.identity(["access_token": rejectedToken], provider: provider),
                      rejectedAccount == account else { throw Self.changed(provider) }
            }
            original = (account, access)
        }
    }

    static func changed(_ provider: String) -> LLMError {
        .providerError(message: "\(provider) account changed — retry the request.")
    }
}

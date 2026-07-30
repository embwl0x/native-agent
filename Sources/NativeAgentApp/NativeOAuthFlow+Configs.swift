import Foundation
import ProviderRouting

// MARK: - Provider config

struct ProviderOAuthConfig: @unchecked Sendable {
    let providerId: String
    let clientId: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let scope: String
    /// Pre-registered custom-scheme redirect URI (nativeagent://oauth/<name>).
    let redirectURI: String
    /// Anthropic uses the PKCE verifier as state (pi-ai convention).
    let stateEqualsVerifier: Bool
    /// Extra query params appended to the authorization URL.
    let extraAuthParams: [String: String]
    /// Token exchange body — form vs JSON varies per provider.
    let tokenBodyFormat: TokenBodyFormat
    /// Function that takes the parsed token response dict and writes it to
    /// the right on-disk shape for `LLMCredentialResolver` / the adapter.
    let persistTokens: ([String: Any]) throws -> Void
    /// Function building the token-exchange body params (extras vary).
    let extraTokenParams: (_ state: String) -> [String: String]

    enum TokenBodyFormat { case form, json }

    func buildAuthURL(redirectURI: String, state: String, challenge: String) -> URL {
        var params: [(String, String)] = [
            ("client_id",             clientId),
            ("response_type",         "code"),
            ("redirect_uri",          redirectURI),
            ("scope",                 scope),
            ("code_challenge",        challenge),
            ("code_challenge_method", "S256"),
            ("state",                 state),
        ]
        for (k, v) in extraAuthParams { params.append((k, v)) }
        var comps = URLComponents(string: authorizationEndpoint)!
        comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return comps.url!
    }

    func exchangeCode(code: String, verifier: String, state: String,
                      redirectURI: String) async throws -> [String: Any] {
        var body: [String: String] = [
            "grant_type":    "authorization_code",
            "client_id":     clientId,
            "code":          code,
            "redirect_uri":  redirectURI,
            "code_verifier": verifier,
        ]
        for (k, v) in extraTokenParams(state) { body[k] = v }

        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        switch tokenBodyFormat {
        case .form:
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = formEncode(body).data(using: .utf8)
        case .json:
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw NSError(domain: "NativeOAuthFlow", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                    "HTTP \(http.statusCode): \(redact(snippet))"])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NativeOAuthFlow", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Token endpoint returned non-JSON."])
        }
        return obj
    }

    // MARK: Provider catalog

    static let openai = ProviderOAuthConfig(
        providerId:            "openai_oauth_direct",
        clientId:              "app_EMoamEEZ73f0CkXaXp7hrann",
        authorizationEndpoint: "https://auth.openai.com/oauth/authorize",
        tokenEndpoint:         "https://auth.openai.com/oauth/token",
        scope:                 "openid profile email offline_access",
        // Loopback, not a custom scheme: OpenAI's ChatGPT client only allows
        // http://localhost:1455/auth/callback. The loopback flow passes this
        // explicitly (see NativeOAuthFlow+Loopback); this field mirrors it.
        redirectURI:           "http://localhost:1455/auth/callback",
        stateEqualsVerifier:   false,
        extraAuthParams: [
            "id_token_add_organizations": "true",
            "codex_cli_simplified_flow":  "true",
            "originator":                 "nativeagent",
        ],
        tokenBodyFormat: .form,
        persistTokens: { tokens in
            var existing = (try? loadJSONObject(NativeOAuthFlow.openAIAuthPath())) ?? [:]
            if existing["auth_mode"] == nil { existing["auth_mode"] = "chatgpt" }
            if existing["OPENAI_API_KEY"] == nil { existing["OPENAI_API_KEY"] = NSNull() }
            var merged = (existing["tokens"] as? [String: Any]) ?? [:]
            for key in ["access_token", "refresh_token", "id_token"] {
                if let v = tokens[key] { merged[key] = v }
            }
            if let access = tokens["access_token"] as? String,
               let payload = jwtPayload(access),
               let auth = payload["https://api.openai.com/auth"] as? [String: Any],
               let acct = auth["chatgpt_account_id"] as? String, !acct.isEmpty {
                merged["account_id"] = acct
            }
            existing["tokens"] = merged
            existing["last_refresh"] = isoNow()
            try writeJSONObject(existing, to: NativeOAuthFlow.openAIAuthPath())
        },
        extraTokenParams: { _ in [:] }
    )

    static let anthropic = ProviderOAuthConfig(
        providerId:            "anthropic_oauth_direct",
        clientId:              "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        authorizationEndpoint: "https://claude.ai/oauth/authorize",
        tokenEndpoint:         "https://platform.claude.com/v1/oauth/token",
        scope:                 "org:create_api_key user:profile user:inference "
                             + "user:sessions:claude_code user:mcp_servers user:file_upload",
        redirectURI:           "nativeagent://oauth/anthropic",
        stateEqualsVerifier:   true,
        extraAuthParams: ["code": "true"],   // pi-ai-required extra
        tokenBodyFormat: .json,
        persistTokens: { tokens in
            var existing = (try? loadJSONObject(NativeOAuthFlow.anthropicTokenPath())) ?? [:]
            existing["client_id"] = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
            if let access = tokens["access_token"] as? String { existing["access_token"] = access }
            if let refresh = tokens["refresh_token"] as? String { existing["refresh_token"] = refresh }
            else if existing["refresh_token"] == nil { existing["refresh_token"] = "" }
            let expiresIn = (tokens["expires_in"] as? Int)
                         ?? Int(tokens["expires_in"] as? Double ?? 3600)
            let exp = Date().addingTimeInterval(TimeInterval(expiresIn))
            existing["expires_at"] = isoBasic(exp)
            existing["scope"] = (tokens["scope"] as? String) ?? ""
            existing["token_type"] = (tokens["token_type"] as? String) ?? "Bearer"
            if existing["user_info"] == nil { existing["user_info"] = [String: Any]() }
            try writeJSONObject(existing, to: NativeOAuthFlow.anthropicTokenPath())
        },
        extraTokenParams: { state in ["state": state] }
    )
}

// MARK: - Connector OAuth config

struct ConnectorOAuthConfig: Sendable {
    let connectorId: String
    let clientIdEnv: String
    let clientSecretEnv: String
    let authURL: String
    let tokenURL: String
    let scopes: String
    let redirectURI: String
    let extraAuthParams: [(String, String)]
    let extraTokenParams: [String: String]

    static let x = ConnectorOAuthConfig(
        connectorId:    "x",
        clientIdEnv:    "NATIVE_AGENT_X_CLIENT_ID",
        clientSecretEnv:"NATIVE_AGENT_X_CLIENT_SECRET",
        authURL:        "https://twitter.com/i/oauth2/authorize",
        tokenURL:       "https://api.twitter.com/2/oauth2/token",
        // 2026-06-06 x-connector port: match the scope set Agent's
        // persisted token already carries (follows.read + tweet.write +
        // tweet.read + users.read + offline.access). Narrowing here would
        // make a re-auth round-trip downgrade her capabilities.
        scopes:         "follows.read offline.access tweet.write users.read tweet.read",
        redirectURI:    "http://127.0.0.1:53682/oauth/callback",
        extraAuthParams: [],
        extraTokenParams: [:]
    )

    static let gmail = ConnectorOAuthConfig(
        connectorId:    "gmail",
        clientIdEnv:    "NATIVE_AGENT_GMAIL_CLIENT_ID",
        clientSecretEnv:"NATIVE_AGENT_GMAIL_CLIENT_SECRET",
        authURL:        "https://accounts.google.com/o/oauth2/v2/auth",
        tokenURL:       "https://oauth2.googleapis.com/token",
        scopes:         "https://www.googleapis.com/auth/gmail.readonly",
        redirectURI:    "http://127.0.0.1:53683/oauth/callback",
        // Google requires access_type=offline + prompt=consent to reliably
        // return a refresh_token for an already-consented user.
        extraAuthParams: [("access_type", "offline"), ("prompt", "consent")],
        extraTokenParams: [:]
    )

    static let calendar = ConnectorOAuthConfig(
        connectorId:    "calendar",
        clientIdEnv:    "NATIVE_AGENT_CALENDAR_CLIENT_ID",
        clientSecretEnv:"NATIVE_AGENT_CALENDAR_CLIENT_SECRET",
        authURL:        "https://accounts.google.com/o/oauth2/v2/auth",
        tokenURL:       "https://oauth2.googleapis.com/token",
        scopes:         "https://www.googleapis.com/auth/calendar.readonly",
        redirectURI:    "http://127.0.0.1:53684/oauth/callback",
        extraAuthParams: [("access_type", "offline"), ("prompt", "consent")],
        extraTokenParams: [:]
    )
}

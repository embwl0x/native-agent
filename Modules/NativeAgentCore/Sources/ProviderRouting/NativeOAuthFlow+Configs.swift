import Foundation
import NativeAgentShared
import NativeAgentCore
// Blueprint: | `NativeOAuthFlow+Configs.swift` | ProviderOAuthConfig owns provider client identities and token endpoints; buildAuthURL, exchangeCode |

// MARK: - Provider config

public struct ProviderOAuthConfig: Sendable {
    public let clientId: String
    let authorizationEndpoint: String
    public let tokenEndpoint: String
    let scope: String
    /// Redirect URIs must match the pre-registered provider client.
    let redirectURI: String
    let extraAuthParams: [String: String]
    /// Providers require distinct token-exchange encodings.
    let tokenBodyFormat: TokenBodyFormat
    /// Persist the exact format the selected root's adapter reads.
    let persistTokens: @Sendable ([String: Any], URL) throws -> Void
    let extraTokenParams: @Sendable (_ state: String) -> [String: String]

    enum TokenBodyFormat: Sendable { case form, json }

    func buildAuthURL(redirectURI: String, state: String, challenge: String) throws -> URL {
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
        guard var comps = URLComponents(string: authorizationEndpoint) else {
            throw URLError(.badURL)
        }
        comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = comps.url else { throw URLError(.badURL) }
        return url
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
        return try await OAuthGrantOperations.postToken(tokenEndpoint, body, json: tokenBodyFormat == .json)
    }

    // MARK: Provider catalog

    public static let openai = ProviderOAuthConfig(
        clientId:              "app_EMoamEEZ73f0CkXaXp7hrann",
        authorizationEndpoint: "https://auth.openai.com/oauth/authorize",
        tokenEndpoint:         "https://auth.openai.com/oauth/token",
        scope:                 "openid profile email offline_access",
        // The ChatGPT client permits only its registered localhost callback; the loopback flow passes it explicitly.
        redirectURI:           "http://localhost:1455/auth/callback",
        extraAuthParams: [
            "id_token_add_organizations": "true",
            "codex_cli_simplified_flow":  "true",
            "originator":                 ChatGPTTransport.codexBackendOriginator,
        ],
        tokenBodyFormat: .form,
        persistTokens: { tokens, dataRoot in
            let answer = try OAuthGrantOperations.validateTokenResponse(tokens, requiringRefreshToken: true)
            // Sign-in writes the app-owned path, which precedes the shared CLI session in resolution.
            let authPath = NativeOAuthFlow.openAIAppOwnedAuthPath(dataRoot: dataRoot)
            guard !ChatGPTTransport.isUserCodexPath(authPath) else {
                throw NSError(
                    domain: "NativeOAuthFlow", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "ChatGPT sign-in cannot write to the shared Codex CLI folder."]
                )
            }
            try OAuthGrantOperations.updateProviderCredential(at: authPath) { existing in
                if existing["auth_mode"] == nil { existing["auth_mode"] = "chatgpt" }
                if existing["OPENAI_API_KEY"] == nil { existing["OPENAI_API_KEY"] = NSNull() }
                // Sign-in replaces identity without borrowing missing fields from the previous account.
                var merged: [String: Any] = ["access_token": answer.accessToken]
                merged["refresh_token"] = answer.refreshToken
                // Optional response metadata is kept only when supplied as a string; JSON null must not become a malformed saved field.
                merged["id_token"] = tokens["id_token"] as? String
                if let access = tokens["access_token"] as? String,
                   let payload = jwtPayload(access),
                   let auth = payload["https://api.openai.com/auth"] as? [String: Any],
                   let acct = auth["chatgpt_account_id"] as? String, !acct.isEmpty {
                    merged["account_id"] = acct
                }
                OAuthRefreshBinding.bindSignIn(&merged, provider: "openai_oauth_direct")
                existing["tokens"] = merged
                existing["last_refresh"] = NativeTimestampFormat.plainZulu(Date())
                existing.removeValue(forKey: "expires_in")
                existing["expires_at"] = answer.expiresIn.map { NativeTimestampFormat.plainZulu(Date().addingTimeInterval($0)) }
            }
            // The sign-in is saved; a failed child copy is re-synced (and reported) by the next Codex spawn.
            do {
                try ChatGPTTransport.syncCodexChildCopy(from: authPath)
            } catch {
                FileHandle.standardError.write(Data(
                    "NativeOAuthFlow: Codex child credential copy failed: \(error)\n".utf8
                ))
            }
        },
        extraTokenParams: { _ in [:] }
    )

    public static let anthropic = ProviderOAuthConfig(
        clientId:              "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        authorizationEndpoint: "https://claude.ai/oauth/authorize",
        tokenEndpoint:         "https://platform.claude.com/v1/oauth/token",
        scope:                 "org:create_api_key user:profile user:inference "
                             + "user:sessions:claude_code user:mcp_servers user:file_upload",
        redirectURI:           "nativeagent://oauth/anthropic",
        extraAuthParams: ["code": "true"],
        tokenBodyFormat: .json,
        persistTokens: { tokens, dataRoot in
            try NativeOAuthFlow.persistAnthropicOAuthTokens(tokens, dataRoot: dataRoot)
        },
        extraTokenParams: { state in ["state": state] }
    )

    public static let xaiClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let xaiTokenEndpoint = "https://auth.x.ai/oauth/token"
}

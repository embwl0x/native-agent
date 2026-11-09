import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `NativeOAuthFlow+XAI.swift` | `NativeOAuthFlow`: `startXAIOAuthFlow` |

private struct XAIOIDCDiscovery: Sendable {
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
}

extension NativeOAuthFlow {
    @concurrent
    public static func startXAIOAuthFlow(
        platform: any NativeOAuthPlatformPort.Type,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> OAuthFlowResult {
        let attempt = signInAttempts.begin(providerId: "xai_oauth_direct", dataRoot: dataRoot)
        defer { signInAttempts.finish(attempt) }
        let server: NativeOAuthLoopbackCallbackServer
        do {
            server = try platform.makeLoopbackSession(
                preferredPort: 0,
                path: "/callback",
                displayName: "xAI"
            )
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Could not start xAI callback listener: \(error.localizedDescription)")
        }
        defer { server.cancel() }

        let discovery: XAIOIDCDiscovery
        do {
            discovery = try await fetchXAIDiscovery()
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Could not read xAI OAuth discovery: \(OAuthGrantOperations.redact(error.localizedDescription))")
        }

        let pkce = PKCE.generate()
        let state = OAuthGrantOperations.randomHex(16)
        let nonce = OAuthGrantOperations.randomHex(16)
        let redirectURI = server.redirectURI.absoluteString
        let scope = "openid profile email offline_access grok-cli:access api:access"

        var comps = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "client_id", value: XAIOAuthTransport.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "plan", value: "generic"),
            URLQueryItem(name: "referrer", value: "nativeagent"),
        ]
        guard let authURL = comps?.url else {
            return OAuthFlowResult(ok: false, error: "Could not build xAI authorization URL.")
        }

        guard await platform.openBrowser(authURL) else {
            return OAuthFlowResult(ok: false, error: "Could not open browser for xAI sign-in.")
        }

        let callbackURL: URL
        do {
            callbackURL = try await server.wait(expectedState: state)
        } catch {
            return OAuthFlowResult(ok: false,
                error: "xAI sign-in failed: \(OAuthGrantOperations.redact(error.localizedDescription))")
        }

        let code: String
        switch validateCallback(callbackURL, expectedState: state,
            providerErrorMessage: { "xAI returned error: \(OAuthGrantOperations.redact($0))" },
            missingCodeMessage: "xAI did not return an authorization code.") {
        case .code(let value): code = value
        case .failure(let message): return OAuthFlowResult(ok: false, error: message)
        }

        let tokens: [String: Any]
        do {
            tokens = try await exchangeXAIToken(
                tokenEndpoint: discovery.tokenEndpoint,
                code: code,
                verifier: pkce.verifier,
                challenge: pkce.challenge,
                redirectURI: redirectURI
            )
        } catch {
            return OAuthFlowResult(ok: false,
                error: "xAI token exchange failed: \(OAuthGrantOperations.redact(error.localizedDescription))")
        }

        do {
            try signInAttempts.commit(attempt) {
                try persistXAITokens(
                    tokens,
                    discovery: discovery,
                    redirectURI: redirectURI,
                    scope: scope,
                    dataRoot: dataRoot
                )
            }
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Could not save xAI credentials in Keychain: \(error.localizedDescription)")
        }

        return OAuthFlowResult(ok: true, error: nil)
    }


    private static func fetchXAIDiscovery() async throws -> XAIOIDCDiscovery {
        guard let url = URL(string: "https://auth.x.ai/.well-known/openid-configuration") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = .infinity
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = ProviderHTTP.makeSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode >= 400 {
            throw NSError(domain: "NativeOAuthFlow.xAI", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "xAI discovery endpoint answered HTTP \(http.statusCode).",
            ])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authRaw = obj["authorization_endpoint"] as? String,
              let tokenRaw = obj["token_endpoint"] as? String,
              let authURL = URL(string: authRaw),
              let tokenURL = URL(string: tokenRaw),
              XAIOAuthTransport.isTrustedXAIURL(authURL),
              XAIOAuthTransport.isTrustedXAIURL(tokenURL) else {
            throw NSError(domain: "NativeOAuthFlow.xAI", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Discovery returned untrusted xAI OAuth endpoints.",
            ])
        }
        return XAIOIDCDiscovery(authorizationEndpoint: authURL, tokenEndpoint: tokenURL)
    }

    private static func exchangeXAIToken(
        tokenEndpoint: URL,
        code: String,
        verifier: String,
        challenge: String,
        redirectURI: String
    ) async throws -> [String: Any] {
        guard XAIOAuthTransport.isTrustedXAIURL(tokenEndpoint) else {
            throw NSError(domain: "NativeOAuthFlow.xAI", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "xAI token endpoint is not trusted.",
            ])
        }
        let (data, response) = try await OAuthGrantOperations.post(tokenEndpoint, [
            "grant_type": "authorization_code",
            "client_id": XAIOAuthTransport.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        ])
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode >= 400 {
            throw NSError(domain: "NativeOAuthFlow.xAI", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "xAI token endpoint answered HTTP \(http.statusCode).",
            ])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NativeOAuthFlow.xAI", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "Token endpoint returned non-JSON.",
            ])
        }
        return obj
    }

    private static func persistXAITokens(
        _ tokens: [String: Any],
        discovery: XAIOIDCDiscovery,
        redirectURI: String,
        scope: String,
        dataRoot: URL
    ) throws {
        let answer = try OAuthGrantOperations.validateTokenResponse(tokens, requiringRefreshToken: true)
        let path = XAIOAuthTransport.tokenPath(dataRoot: dataRoot)
        try OAuthGrantOperations.updateProviderCredential(at: path, replacingXAIGrant: true) { existing in
            // Identity, expiry and refresh fields belong only to this sign-in.
            for key in ["tokens", "refresh_token", "id_token", "expires_in", "expires_at",
                        "oauth_account_identity", "refresh_token_account_identity"] {
                existing.removeValue(forKey: key)
            }
            existing["provider_id"] = "xai_oauth_direct"
            existing["auth_mode"] = "oauth"
            existing["client_id"] = XAIOAuthTransport.clientID
            existing["scope"] = (tokens["scope"] as? String) ?? scope
            existing["base_url"] = "https://api.x.ai/v1"
            existing["redirect_uri"] = redirectURI
            existing["access_token"] = answer.accessToken
            existing["refresh_token"] = answer.refreshToken
            if let idToken = tokens["id_token"] as? String, !idToken.isEmpty {
                existing["id_token"] = idToken
            }
            existing["token_type"] = (tokens["token_type"] as? String) ?? "Bearer"
            existing["last_refresh"] = NativeTimestampFormat.plainZulu(Date())
            existing["expires_in"] = answer.expiresIn
            existing["expires_at"] = answer.expiresIn.map { NativeTimestampFormat.basicZulu(Date().addingTimeInterval($0)) }
            existing["discovery"] = [
                "authorization_endpoint": discovery.authorizationEndpoint.absoluteString,
                "token_endpoint": discovery.tokenEndpoint.absoluteString,
            ]
            OAuthRefreshBinding.bindSignIn(&existing, provider: "xai_oauth_direct")
        }
    }
}

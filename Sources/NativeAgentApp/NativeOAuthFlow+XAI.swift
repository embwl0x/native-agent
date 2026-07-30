import Foundation
import AppKit
import PersistenceCore
import ProviderRouting

private struct XAIOIDCDiscovery: Sendable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
}

extension NativeOAuthFlow {
    @MainActor
    static func startXAIOAuthFlow() async -> OAuthFlowResult {
        let server: NativeOAuthLoopbackCallbackServer
        do {
            server = try NativeOAuthLoopbackCallbackServer(
                preferredPort: 56121,
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
                error: "Could not read xAI OAuth discovery: \(redact(error.localizedDescription))")
        }

        let pkce = PKCE.generate()
        let state = randomHex(16)
        let nonce = randomHex(16)
        let redirectURI = server.redirectURI.absoluteString
        let scope = "openid profile email offline_access grok-cli:access api:access"

        var comps = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "client_id", value: XAIOAuthDirectAdapter.clientID),
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

        guard NSWorkspace.shared.open(authURL) else {
            return OAuthFlowResult(ok: false, error: "Could not open browser for xAI sign-in.")
        }

        let callbackURL: URL
        do {
            callbackURL = try await server.wait(timeoutSeconds: 300)
        } catch NativeOAuthLoopbackCallbackServer.CallbackError.timedOut {
            return OAuthFlowResult(ok: false, error: "xAI sign-in timed out.")
        } catch {
            return OAuthFlowResult(ok: false,
                error: "xAI sign-in failed: \(redact(error.localizedDescription))")
        }

        let (code, returnedState, providerError) = parseCallback(callbackURL)
        if let providerError = providerError {
            return OAuthFlowResult(ok: false,
                error: "xAI returned error: \(redact(providerError))")
        }
        guard let code = code, !code.isEmpty else {
            return OAuthFlowResult(ok: false,
                error: "xAI did not return an authorization code.")
        }
        guard returnedState == state else {
            return OAuthFlowResult(ok: false,
                error: "OAuth state mismatch — possible CSRF; aborting.")
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
                error: "xAI token exchange failed: \(redact(error.localizedDescription))")
        }

        do {
            try persistXAITokens(
                tokens,
                discovery: discovery,
                redirectURI: redirectURI,
                scope: scope
            )
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Could not write xAI token file: \(error.localizedDescription)")
        }

        return OAuthFlowResult(ok: true, error: nil)
    }


    private static func fetchXAIDiscovery() async throws -> XAIOIDCDiscovery {
        let url = URL(string: "https://auth.x.ai/.well-known/openid-configuration")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw NSError(domain: "NativeOAuthFlow.xAI", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Discovery HTTP \(http.statusCode): \(redact(snippet))",
            ])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authRaw = obj["authorization_endpoint"] as? String,
              let tokenRaw = obj["token_endpoint"] as? String,
              let authURL = URL(string: authRaw),
              let tokenURL = URL(string: tokenRaw),
              XAIOAuthDirectAdapter.isTrustedXAIURL(authURL),
              XAIOAuthDirectAdapter.isTrustedXAIURL(tokenURL) else {
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
        guard XAIOAuthDirectAdapter.isTrustedXAIURL(tokenEndpoint) else {
            throw NSError(domain: "NativeOAuthFlow.xAI", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "xAI token endpoint is not trusted.",
            ])
        }
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = formEncode([
            "grant_type": "authorization_code",
            "client_id": XAIOAuthDirectAdapter.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        ]).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let snippet = String(data: data.prefix(600), encoding: .utf8) ?? ""
            throw NSError(domain: "NativeOAuthFlow.xAI", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(redact(snippet))",
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
        scope: String
    ) throws {
        guard let access = tokens["access_token"] as? String,
              !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "NativeOAuthFlow.xAI", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "xAI token response did not include access_token.",
            ])
        }
        let path = XAIOAuthDirectAdapter.tokenPath()
        var existing = (try? loadJSONObject(path)) ?? [:]
        existing["provider_id"] = "xai_oauth_direct"
        existing["auth_mode"] = "oauth_pkce"
        existing["client_id"] = XAIOAuthDirectAdapter.clientID
        existing["scope"] = (tokens["scope"] as? String) ?? scope
        existing["base_url"] = "https://api.x.ai/v1"
        existing["redirect_uri"] = redirectURI
        existing["access_token"] = access
        if let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty {
            existing["refresh_token"] = refresh
        }
        if let idToken = tokens["id_token"] as? String, !idToken.isEmpty {
            existing["id_token"] = idToken
        }
        existing["token_type"] = (tokens["token_type"] as? String) ?? "Bearer"
        existing["last_refresh"] = isoNow()
        if let expiresIn = tokens["expires_in"] as? Int {
            existing["expires_in"] = expiresIn
            existing["expires_at"] = isoBasic(Date().addingTimeInterval(TimeInterval(expiresIn)))
        } else if let expiresInDouble = tokens["expires_in"] as? Double {
            existing["expires_in"] = expiresInDouble
            existing["expires_at"] = isoBasic(Date().addingTimeInterval(expiresInDouble))
        }
        existing["discovery"] = [
            "authorization_endpoint": discovery.authorizationEndpoint.absoluteString,
            "token_endpoint": discovery.tokenEndpoint.absoluteString,
        ]
        try writeJSONObject(existing, to: path)
    }
}

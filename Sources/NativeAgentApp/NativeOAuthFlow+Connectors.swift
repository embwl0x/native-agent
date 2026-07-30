import Foundation
import AppKit
import PersistenceCore

extension NativeOAuthFlow {
    // MARK: - Connector OAuth (X / Gmail / Calendar)
    //
    // Per-connector OAuth through a one-shot loopback callback. Google desktop
    // OAuth supports loopback redirects, and X requires the exact callback URL
    // to be allowlisted. Each
    // connector reads its client_id from an env var
    // (NATIVE_AGENT_<CONNECTOR>_CLIENT_ID) so dev/personal builds opt in
    // explicitly — no silent failure with a missing client. Tokens land at
    //   <dataRoot>/connectors/<id>/auth.json
    // under PersistenceCore.withFileLock.

    /// Drive a full PKCE OAuth2 flow for one of the supported connectors.
    /// Returns when tokens have been persisted (or an error has been surfaced).
    @MainActor
    static func startConnectorOAuthFlow(connectorId: String) async -> OAuthFlowResult {
        let cfg: ConnectorOAuthConfig
        switch connectorId {
        case "x":        cfg = .x
        case "gmail":    cfg = .gmail
        case "calendar": cfg = .calendar
        default:
            return OAuthFlowResult(ok: false,
                error: "Unknown OAuth connector id: \(connectorId)")
        }

        guard let credentials = connectorOAuthAppCredentials(connectorId: connectorId) else {
            return OAuthFlowResult(ok: false,
                error: "Configure the OAuth app in Connectors before signing in.")
        }
        let clientId = credentials.clientId
        guard let redirectURL = URL(string: cfg.redirectURI),
              redirectURL.host == "127.0.0.1",
              let port = redirectURL.port.flatMap(UInt16.init(exactly:)),
              !redirectURL.path.isEmpty else {
            return OAuthFlowResult(ok: false,
                error: "Connector OAuth redirect configuration is invalid.")
        }
        let server: NativeOAuthLoopbackCallbackServer
        do {
            server = try NativeOAuthLoopbackCallbackServer(
                preferredPort: port,
                path: redirectURL.path,
                displayName: cfg.connectorId,
                allowsPortFallback: false
            )
        } catch {
            return OAuthFlowResult(
                ok: false,
                error: "Could not start the local \(cfg.connectorId) sign-in listener on port \(port). Close the app using that port and retry."
            )
        }
        defer { server.cancel() }

        let pkce = PKCE.generate()
        let state = randomHex(16)

        // Build auth URL.
        var params: [(String, String)] = [
            ("client_id",             clientId),
            ("response_type",         "code"),
            ("redirect_uri",          cfg.redirectURI),
            ("scope",                 cfg.scopes),
            ("code_challenge",        pkce.challenge),
            ("code_challenge_method", "S256"),
            ("state",                 state),
        ]
        for (k, v) in cfg.extraAuthParams { params.append((k, v)) }
        var comps = URLComponents(string: cfg.authURL)!
        comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        let authURL = comps.url!

        guard NSWorkspace.shared.open(authURL) else {
            return OAuthFlowResult(ok: false, error: "Could not open the browser for sign-in.")
        }

        let callbackURL: URL
        do {
            callbackURL = try await server.wait(timeoutSeconds: 300)
        } catch NativeOAuthLoopbackCallbackServer.CallbackError.timedOut {
            return OAuthFlowResult(ok: false, error: "Sign-in timed out.")
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Sign-in failed: \(redact(error.localizedDescription))")
        }

        let (code, returnedState, providerError) = parseCallback(callbackURL)
        if let providerError = providerError {
            return OAuthFlowResult(ok: false,
                error: "Provider returned error: \(providerError)")
        }
        guard let code = code, !code.isEmpty else {
            return OAuthFlowResult(ok: false,
                error: "Provider did not return an authorization code.")
        }
        guard returnedState == state else {
            return OAuthFlowResult(ok: false,
                error: "OAuth state mismatch — possible CSRF; aborting.")
        }

        // Token exchange — application/x-www-form-urlencoded for all three.
        let tokens: [String: Any]
        do {
            var body: [String: String] = [
                "grant_type":    "authorization_code",
                "client_id":     clientId,
                "code":          code,
                "redirect_uri":  cfg.redirectURI,
                "code_verifier": pkce.verifier,
            ]
            if let clientSecret = credentials.clientSecret {
                body["client_secret"] = clientSecret
            }
            for (k, v) in cfg.extraTokenParams { body[k] = v }
            var req = URLRequest(url: URL(string: cfg.tokenURL)!)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
            req.httpBody = formEncode(body).data(using: .utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
                return OAuthFlowResult(ok: false,
                    error: "Token exchange HTTP \(http.statusCode): \(redact(snippet))")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return OAuthFlowResult(ok: false,
                    error: "Token endpoint returned non-JSON.")
            }
            tokens = obj
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Token exchange failed: \(redact(error.localizedDescription))")
        }

        // Persist under flock so a concurrent reader/writer can't see a torn file.
        // Pull values out of the [String: Any] response into typed Sendable
        // locals first — [String: Any] itself is not Sendable.
        guard let accessToken = (tokens["access_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return OAuthFlowResult(
                ok: false,
                error: "Token endpoint did not return an access token."
            )
        }
        let refreshToken = tokens["refresh_token"] as? String
        let scopeStr     = (tokens["scope"] as? String) ?? cfg.scopes
        let tokenType    = (tokens["token_type"] as? String) ?? "Bearer"
        let expiresIn    = (tokens["expires_in"] as? Int)
                        ?? Int(tokens["expires_in"] as? Double ?? 3600)
        let expiresAt    = isoBasic(Date().addingTimeInterval(TimeInterval(expiresIn)))

        let path = connectorTokenPath(connectorId: connectorId)
        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(path) {
                var obj: [String: Any] = (try? loadJSONObject(path)) ?? [:]
                obj["client_id"] = clientId
                obj["access_token"] = accessToken
                if let refresh = refreshToken { obj["refresh_token"] = refresh }
                obj["expires_at"] = expiresAt
                obj["scope"]      = scopeStr
                obj["token_type"] = tokenType
                try writeJSONObject(obj, to: path)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: path.path
                )
            }
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Could not write token file: \(error.localizedDescription)")
        }

        // 2026-06-06 x-connector port: the X executor reads the
        // daemon-compatible shape at `<dataRoot>/oauth_tokens/x.json`
        // (epoch-double expires_at, flat keys). Mirror the freshly-
        // exchanged tokens there so a re-auth via the Mac OAuth sheet
        // immediately starts working for x.* actions — without this,
        // the executor only ever saw the migrated daemon-era token
        // and a fresh sign-in would land at the wrong path/shape.
        if connectorId == "x" {
            let xPath = PersistenceCore.defaultDataRoot()
                .appendingPathComponent("oauth_tokens", isDirectory: true)
                .appendingPathComponent("x.json")
            let expiresEpoch = Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970
            try? await persistence.withFileLock(xPath) {
                var x: [String: Any] = (try? loadJSONObject(xPath)) ?? [:]
                x["provider"] = "x"
                x["access_token"] = accessToken
                if let refresh = refreshToken { x["refresh_token"] = refresh }
                x["token_type"] = tokenType.lowercased()
                x["scope"] = scopeStr
                x["expires_at"] = String(expiresEpoch)
                x["saved_at"] = isoBasic(Date())
                try? FileManager.default.createDirectory(
                    at: xPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try writeJSONObject(x, to: xPath)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: xPath.path
                )
            }
        }

        return OAuthFlowResult(ok: true, error: nil)
    }

    static func connectorTokenPath(
        connectorId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> URL {
        dataRoot
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(connectorId, isDirectory: true)
            .appendingPathComponent("auth.json")
    }
}

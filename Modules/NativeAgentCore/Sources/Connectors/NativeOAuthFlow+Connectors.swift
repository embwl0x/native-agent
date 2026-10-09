import ProviderRouting
import Foundation
import PersistenceCore
import XConnector

extension NativeOAuthFlow {
    // MARK: - Connector OAuth (X / Gmail / Calendar)
    //
    // Per-connector OAuth through a one-shot loopback callback. Google desktop
    // OAuth supports loopback redirects, and X requires the exact callback URL
    // to be allowlisted. Each
    // connector reads its client_id from an env var
    // (NATIVE_AGENT_<CONNECTOR>_CLIENT_ID) so dev/personal builds opt in
    // explicitly — no silent failure with a missing client. Metadata lands at
    //   <dataRoot>/connectors/<id>/auth.json
    // under PersistenceCore.withFileLock; secret bytes stay in device Keychain.

    /// Drive a full PKCE OAuth2 flow for one of the supported connectors.
    /// Returns when tokens have been persisted (or an error has been surfaced).
    @MainActor
    public static func startConnectorOAuthFlow(
        platform: any NativeOAuthPlatformPort.Type,
        connectorId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> OAuthFlowResult {
        let cfg: ConnectorOAuthConfig
        switch connectorId {
        case "x":        cfg = .x
        case "gmail":    cfg = .gmail
        case "calendar": cfg = .calendar
        default:
            return OAuthFlowResult(ok: false,
                error: "Unknown OAuth connector id: \(connectorId)")
        }

        guard let credentials = connectorOAuthAppCredentials(
            connectorId: connectorId,
            dataRoot: dataRoot
        ) else {
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
        let server: any OAuthLoopbackSession
        do {
            server = try platform.makeLoopbackSession(
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
        let state = NativeOAuthSupport.randomHex(16)

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

        guard platform.openBrowser(authURL) else {
            return OAuthFlowResult(ok: false, error: "Could not open the browser for sign-in.")
        }

        let callbackURL: URL
        do {
            callbackURL = try await server.wait(timeoutSeconds: 300, expectedState: state)
        } catch OAuthLoopbackCallbackError.timedOut {
            return OAuthFlowResult(ok: false, error: "Sign-in timed out.")
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Sign-in failed: \(NativeOAuthSupport.redact(error.localizedDescription))")
        }

        let code: String
        switch validateCallback(callbackURL, expectedState: state) {
        case .code(let validatedCode):
            code = validatedCode
        case .failure(let message):
            return OAuthFlowResult(ok: false, error: message)
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
            if cfg.connectorId != "x", let clientSecret = credentials.clientSecret {
                body["client_secret"] = clientSecret
            }
            for (k, v) in cfg.extraTokenParams { body[k] = v }
            var req = URLRequest(url: URL(string: cfg.tokenURL)!)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
            if cfg.connectorId == "x" {
                req.setValue(XConnectorActions.oauthClientAuthorization(
                    clientID: clientId, clientSecret: credentials.clientSecret
                ), forHTTPHeaderField: "Authorization")
            }
            req.httpBody = NativeOAuthSupport.formEncode(body).data(using: .utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
                return OAuthFlowResult(ok: false,
                    error: "Token exchange HTTP \(http.statusCode): \(NativeOAuthSupport.redact(snippet))")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return OAuthFlowResult(ok: false,
                    error: "Token endpoint returned non-JSON.")
            }
            tokens = obj
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Token exchange failed: \(NativeOAuthSupport.redact(error.localizedDescription))")
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
        let rawRefreshToken = (tokens["refresh_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = rawRefreshToken?.isEmpty == false ? rawRefreshToken : nil
        let accountSubject: String?
        if connectorId == "x" {
            do {
                accountSubject = try await XConnectorActions.accountID(accessToken: accessToken)
            } catch {
                return OAuthFlowResult(ok: false,
                    error: "Could not verify the X account. Reconnect X in Connectors.")
            }
        } else {
            do {
                accountSubject = try await GoogleOAuthCredentials.accountSubject(accessToken: accessToken)
            } catch {
                return OAuthFlowResult(ok: false,
                    error: "Could not verify the Google account. Sign in again in Settings → Connectors.")
            }
        }
        let scopeStr     = (tokens["scope"] as? String) ?? cfg.scopes
        let tokenType    = (tokens["token_type"] as? String) ?? "Bearer"
        let expiresIn    = (tokens["expires_in"] as? Int)
                        ?? (tokens["expires_in"] as? Double).flatMap { Int(exactly: $0.rounded(.towardZero)) } ?? 3600
        let expiresAt    = NativeOAuthSupport.isoBasic(Date().addingTimeInterval(TimeInterval(expiresIn)))

        let path = connectorTokenPath(connectorId: connectorId, dataRoot: dataRoot)
        let persistence = SwiftNativePersistenceCore()
        do {
            try await markOAuthConnectorConnected(connectorId, dataRoot: dataRoot) {
                try await persistence.withFileLock(path) {
                    var object = try ConnectorOAuthRegistry.checkedCredentialObject(at: path, resolveSecrets: false)
                    if connectorId == "x", let accountSubject {
                        object["account_id"] = .string(accountSubject)
                        object["refresh_token"] = refreshToken.map(JSONValue.string)
                        object["refresh_token_account_id"] = refreshToken.map { _ in .string(accountSubject) }
                    } else if let accountSubject {
                        // Retain only a refresh token bound to this account and app.
                        // Legacy credentials without identity cannot prove ownership.
                        let sameAccount = object["account_sub"] == .string(accountSubject)
                            && object["refresh_token_account_sub"] == .string(accountSubject)
                            && object["client_id"] == .string(clientId)
                        if refreshToken == nil, sameAccount {
                            object = try ConnectorOAuthRegistry.checkedCredentialObject(at: path)
                        }
                        if let refreshToken {
                            object["refresh_token"] = .string(refreshToken)
                            object["refresh_token_account_sub"] = .string(accountSubject)
                        } else if !sameAccount {
                            object.removeValue(forKey: "refresh_token")
                            object.removeValue(forKey: "refresh_token_account_sub")
                        }
                        object["account_sub"] = .string(accountSubject)
                    }
                    object["client_id"] = .string(clientId)
                    object["access_token"] = .string(accessToken)
                    object["expires_at"] = .string(expiresAt)
                    object["scope"] = .string(scopeStr)
                    object["token_type"] = .string(tokenType)
                    let prepared = object
                    if connectorId == "x" {
                        let xPath = OAuthCredentialDestinations.xConnectorRuntimeMirror(dataRoot: dataRoot)
                        try await persistence.withFileLock(xPath) {
                            // Validate both destinations before publishing either.
                            var mirror = try ConnectorOAuthRegistry.checkedCredentialObject(at: xPath, resolveSecrets: false)
                            mirror["provider"] = .string("x")
                            mirror["access_token"] = .string(accessToken)
                            mirror["refresh_token"] = refreshToken.map(JSONValue.string)
                            mirror["account_id"] = accountSubject.map(JSONValue.string)
                            mirror["refresh_token_account_id"] = refreshToken.flatMap { _ in accountSubject }.map(JSONValue.string)
                            mirror["token_type"] = .string(tokenType.lowercased())
                            mirror["scope"] = .string(scopeStr)
                            mirror["expires_at"] = .string(String(Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970))
                            mirror["saved_at"] = .string(NativeOAuthSupport.isoBasic(Date()))
                            try ConnectorCredentialFile.write(JSONValue.object(prepared).serializedData(pretty: true), to: path)
                            try ConnectorCredentialFile.write(JSONValue.object(mirror).serializedData(pretty: true), to: xPath)
                        }
                    } else {
                        try ConnectorCredentialFile.write(JSONValue.object(prepared).serializedData(pretty: true), to: path)
                    }
                }
            }
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Could not save connector setup: \(error.localizedDescription)")
        }
        return OAuthFlowResult(ok: true, error: nil)
    }

    public static func connectorTokenPath(
        connectorId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> URL {
        if connectorId == "x" {
            return OAuthCredentialDestinations.xConnector(dataRoot: dataRoot)
        }
        return dataRoot
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(connectorId, isDirectory: true)
            .appendingPathComponent("auth.json")
    }
}

import AppKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import os
import PersistenceCore
// Blueprint: | `NativeOAuthFlow+Keyring.swift` | `Keyring`, `granted`, `grant`, `forget`, `values`, `NativeOAuthFlow`, `grantSecret` |

/// Serialize each secret's grant, removal and renewal on one queue so read/check/refresh/commit cannot spend a grant twice.
extension Keyring {
    private static let renewals = OAuthRefreshQueueRegistry()
    /// Each grant or removal advances the name: an earlier sign-in cannot overwrite a grant that finished while it was under way.
    private static let generations = OSAllocatedUnfairLock(initialState: [String: Int]())

    public static func generation(_ name: String) -> Int { generations.withLock { $0[name, default: 0] } }

    /// Pending device grants expose only the code and verification destination.
    fileprivate static let signingIn = OSAllocatedUnfairLock(initialState: [String: String]())
    public static func signInNote(_ name: String) -> String? { signingIn.withLock { $0[name] } }

    /// Removal must follow operations already queued for that secret.
    public static func forget(_ name: String) async throws {
        try await renewals.queue(forKey: name).run {
            generations.withLock { $0[name, default: 0] += 1 }
            try remove(name)
        }
    }

    /// Program grants bind to executable identity recorded at launch, not just a path.
    public enum Destination: Sendable, CustomStringConvertible {
        case host(String), program(path: String, identity: String)
        public var description: String {
            switch self { case .host(let host): "host \(host)"; case .program(let path, _): "program \(path)" }
        }
    }

    /// Refusal words must never carry the secret.
    public struct Refusal: LocalizedError, Sendable {
        public let code: String
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Every destination must match the secret's grant, including the current executable identity.
    public static func granted(_ name: String, hosts: [String], programs: [String]) -> Bool {
        guard let entry = try? entry(name) else { return false }
        return Set(hosts).isSubset(of: entry.hosts) && programs.allSatisfy { path in
            AgentHostCommandLines.identity(ofExecutable: path).map { entry.programs.contains(Program(path: path, identity: $0)) } == true
        }
    }

    /// Bind grants to the destinations shown on the card. Refuse stale generations and closed cards so an earlier sign-in cannot overwrite a newer
    /// decision.
    public static func grant(_ name: String, value: String, hosts: [String], programs: [String],
                             renewal: Renewal? = nil, account: String? = nil, generation: Int,
                             open: @escaping @Sendable () async -> Bool) async throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validName(name), !value.isEmpty else {
            throw Refusal(code: "bad_input", message: "A secret needs a name of lowercase letters, digits, . _ - and a value.")
        }
        try await renewals.queue(forKey: name).run {
            guard Self.generation(name) == generation else {
                throw Refusal(code: "state_changed", message: "\(name) was changed while this was being granted, so nothing was kept.")
            }
            guard await open() else {
                throw Refusal(code: "declined", message: "The card was answered before this finished, so nothing was kept.")
            }
            try commitGrant(name, value: value, hosts: hosts, programs: programs, renewal: renewal, account: account)
            generations.withLock { $0[name, default: 0] += 1 }
        }
    }

    private static func commitGrant(_ name: String, value: String, hosts: [String], programs: [String], renewal: Renewal?, account: String?) throws {
        let bound = try programs.map { path in
            guard let identity = AgentHostCommandLines.identity(ofExecutable: path) else {
                throw Refusal(code: "not_found", message: "\(path) could not be read to bind the grant to it.")
            }
            return Program(path: path, identity: identity)
        }
        try save(name, Entry(value: value, hosts: Array(Set(hosts)).sorted(),
                             programs: bound.sorted { $0.path < $1.path }, renewal: renewal, at: Date(), account: account))
    }

    /// Read, destination check, renewal and commit share one queue per secret. Only the rejected credential's unchanged grant may authorize resend; a
    /// concurrent new account never does.
    public static func values(_ names: [String], to destination: Destination, rejected: [String: String] = [:],
                              grants: [String: Date] = [:]) async throws -> (values: [String: String], grants: [String: Date], renewed: Bool) {
        var values: [String: String] = [:], granted: [String: Date] = [:], renewed = false, regranted = false
        for name in names {
            guard validName(name) else {
                throw Refusal(code: "bad_input", message: "{{secret:\(name)}} is no secret name: names are lowercase letters, digits, . _ -.")
            }
            let got = try await renewals.queue(forKey: name).run { try await current(name, to: destination, rejected: rejected[name]) }
            values[name] = got.value
            granted[name] = got.grant
            renewed = renewed || got.renewed
            regranted = regranted || grants[name].map { $0 != got.grant } == true
        }
        return (values, granted, renewed && !regranted)
    }

    private static func current(_ name: String, to destination: Destination, rejected: String?) async throws -> (value: String, renewed: Bool, grant: Date) {
        guard var entry = try entry(name) else {
            throw Refusal(code: "no_secret", message: "No secret named \(name) is kept. Ask the person once: app card.request "
                + """
                    {kind:\"api_key\", target:\"secret:\(name)\", hosts:[…] and/or programs:[…], why}; the value goes from their card to the keyring, \
                    never through you.
                    """)
        }
        let allowed = switch destination {
        case .host(let host): Keyring.host(host).map(entry.hosts.contains) == true
        case .program(let path, _): entry.programs.contains { $0.path == path }
        }
        if case .program(let path, let identity) = destination, allowed, !entry.programs.contains(Program(path: path, identity: identity)) {
            throw Refusal(code: "program_changed", message: "\(path) changed since the person granted \(name) to it. "
                + "Ask again (card.request with replace:true and programs:[\"\(path)\"]) and they grant it as it is now.")
        }
        guard allowed else {
            let line = (entry.hosts.map { "host \($0)" } + entry.programs.map { "program \($0.path)" }).joined(separator: ", ")
            throw Refusal(code: "permission_denied", message: "Secret \(name) is granted for \(line.isEmpty ? "nowhere" : line), not \(destination). "
                + "Ask for it again naming \(destination); the card keeps where it already goes and adds this.")
        }
        // A grant with no stated expiry (RFC 6749: expires_in omitted) is used until the provider rejects it; only a known, near expiry or a rejection
        // renews it.
        guard let renewal = entry.renewal,
              renewal.expires.map({ $0 <= Date().addingTimeInterval(OAuthGrantOperations.renewalMargin) }) == true || rejected == entry.value else {
            return (entry.value, rejected.map { $0 != entry.value } ?? false, entry.at)
        }
        let read = entry
        var form = ["grant_type": "refresh_token", "refresh_token": renewal.refreshToken, "client_id": renewal.clientID]
        form["client_secret"] = renewal.clientSecret
        var answered: String?
        do {
            let tokens = try await OAuthGrantOperations.postToken(renewal.token, form, basic: renewal.clientAuth == "basic")
            let answer = try OAuthGrantOperations.validateTokenResponse(tokens, requiringRefreshToken: false)
            answered = account(tokens, hiding: [renewal.refreshToken, renewal.clientSecret])
            entry.value = answer.accessToken
            var updatedRenewal = renewal
            if let refresh = answer.refreshToken { updatedRenewal.refreshToken = refresh }
            updatedRenewal.expires = answer.expiresIn.map { Date().addingTimeInterval($0) }
            entry.renewal = updatedRenewal
        } catch let failure as ProviderFailure.Diagnostic {
            throw failure
        } catch {
            throw Refusal(code: "not_connected", message: "Secret \(name)'s sign-in could not be renewed (\(exchangeFailure(error))). "
                + "Ask for it again with replace:true, and the person signs in once more.")
        }
        if let account = entry.account, let answered, answered != account {
            throw Refusal(code: "not_connected", message: "Secret \(name)'s renewal answered for another account than \(account), the one the person granted; "
                + "nothing was kept or sent. Ask for it again with replace:true, and the person signs in once more.")
        }
        // A renewal commits only onto the entry it read; otherwise its result is dropped.
        guard try Self.entry(name) == read else {
            throw Refusal(code: "state_changed", message: "Secret \(name) changed while it was being renewed; nothing was sent. Call again.")
        }
        try save(name, entry)
        return (entry.value, true, entry.at)
    }

    /// A failed exchange in fixed words: its HTTP status, never the service's text.
    static func exchangeFailure(_ error: Error) -> String {
        let error = error as NSError
        return error.domain == "NativeOAuthFlow" && error.code >= 300 ? "the token endpoint answered HTTP \(error.code)"
            : "the token endpoint gave no usable answer"
    }

    /// TLS token-endpoint identity may name the account, but strip every credential before exposing the subject.
    static func account(_ tokens: [String: Any], hiding credentials: [String?]) -> String? {
        guard let subject = (tokens["id_token"] as? String).flatMap({ jwtPayload($0)?["sub"] as? String }) else { return nil }
        return (credentials + [tokens["access_token"] as? String, tokens["refresh_token"] as? String]).compactMap { $0 }
            .filter { !$0.isEmpty }.reduce(subject) { $0.replacingOccurrences(of: $1, with: "[secret]") }
    }

    /// Only admitted provider evidence constructs renewal authority. A grant without a refresh token is nonrenewable. Refresh responses may keep the
    /// current renewal's refresh token by omitting a replacement (RFC 6749 §6).
    static func renewal(_ answer: OAuthGrantOperations.TokenResponse, token: String, clientID: String, clientSecret: String?,
                        clientAuth: String?) -> Renewal? {
        guard let refresh = answer.refreshToken else { return nil }
        return Renewal(token: token, clientID: clientID, clientSecret: clientSecret, clientAuth: clientAuth, refreshToken: refresh,
                       expires: answer.expiresIn.map { Date().addingTimeInterval($0) })
    }
}

extension NativeOAuthFlow {
    /// Keep sign-in tokens private and client secrets only while the card is open. PKCE/device sign-in parameters are data, and errors never carry values.
    @MainActor
    public static func grantSecret(_ name: String, ask: InlineInteraction.SecretAsk, pasted: String?,
                                   open: @escaping @Sendable () async -> Bool, shown: @MainActor () async -> Void) async -> String? {
        let generation = Keyring.generation(name)
        guard let signIn = ask.signIn else {
            do { try await Keyring.grant(name, value: pasted ?? "", hosts: ask.hosts, programs: ask.programs, generation: generation, open: open); return nil }
            catch { return error.localizedDescription }
        }
        let clientSecret = pasted.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        guard signIn.clientAuth != "basic" || clientSecret != nil else {
            return """
                oauth_client_secret_missing: This sign-in requires HTTP Basic client authentication. Enter the service-issued client secret on this \
                sign-in card.
                """
        }
        func keep(_ tokens: [String: Any]) async -> String? {
            do {
                let answer = try OAuthGrantOperations.validateTokenResponse(tokens, requiringRefreshToken: false)
                try await Keyring.grant(name, value: answer.accessToken, hosts: ask.hosts, programs: ask.programs,
                                        renewal: Keyring.renewal(answer, token: signIn.token, clientID: signIn.clientID, clientSecret: clientSecret,
                                                                 clientAuth: signIn.clientAuth),
                                        account: Keyring.account(tokens, hiding: [clientSecret]), generation: generation, open: open)
                return nil
            } catch { return error.localizedDescription }
        }
        if let device = signIn.device {
            var client = ["client_id": signIn.clientID]
            client["client_secret"] = clientSecret
            do { return await keep(try await deviceSignIn(name, signIn, device: device, client: client, shown: shown)) }
            catch is CancellationError { return "oauth_sign_in_cancelled: Sign-in was cancelled. Leave it stopped; no further action is needed." }
            catch { return error.localizedDescription }
        }
        let given = signIn.redirect.flatMap(URL.init(string:))
        guard signIn.redirect == nil || given?.scheme == "http" && ["127.0.0.1", "localhost"].contains(given?.host ?? ""),
              let port = UInt16(exactly: given?.port ?? 0),
              var authorize = signIn.authorize.flatMap(URLComponents.init(string:)), authorize.scheme == "https" else {
            return """
                oauth_sign_in_parameters_invalid: Sign-in requires an HTTPS authorize address and, if set, an HTTP loopback redirect. Correct \
                sign_in.authorize and sign_in.redirect (http://127.0.0.1:<port>/<path>) in app card.request.
                """
        }
        let server: NativeOAuthLoopbackCallbackServer
        do {
            server = try NativeOAuthLoopbackCallbackServer(preferredPort: port, path: given.map(\.path).flatMap { $0.isEmpty ? nil : $0 } ?? "/callback",
                                                           displayName: name)
        } catch {
            return """
                oauth_listener_failed: Could not open the sign-in listener on port \(port): \(error.localizedDescription) Correct the reported socket \
                problem or sign_in.redirect in app card.request before starting a new sign-in.
                """
        }
        defer { server.cancel() }
        let redirect = signIn.redirect ?? server.redirectURI.absoluteString
        let pkce = PKCE.generate(), state = OAuthGrantOperations.randomHex(16)
        authorize.queryItems = (authorize.queryItems ?? []) + [
            URLQueryItem(name: "client_id", value: signIn.clientID), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
        ] + (signIn.scopes.map { [URLQueryItem(name: "scope", value: $0)] } ?? [])
        guard let url = authorize.url, NSWorkspace.shared.open(url) else {
            return """
                oauth_browser_open_failed: macOS could not open the sign-in URL. Set a working default web browser in System Settings → Desktop & Dock → \
                Default web browser, then choose Try again on the \(name) card.
                """
        }
        let code: String
        do {
            switch validateCallback(try await server.wait(timeoutSeconds: 300, expectedState: state), expectedState: state,
                                    providerErrorMessage: { _ in "The service rejected browser sign-in." }) {
            case .code(let returned): code = returned
            case .failure(let reason):
                return "oauth_callback_invalid: \(reason) Start a new sign-in with Try again on the \(name) card."
            }
        } catch OAuthLoopbackCallbackError.timedOut {
            return """
                oauth_callback_timeout: No browser callback arrived within 300 seconds. Choose Try again on the \(name) card and finish browser sign-in \
                within five minutes.
                """
        } catch OAuthLoopbackCallbackError.canceled {
            return "oauth_sign_in_cancelled: Sign-in was cancelled. Leave it stopped; no further action is needed."
        } catch is CancellationError {
            return "oauth_sign_in_cancelled: Sign-in was cancelled. Leave it stopped; no further action is needed."
        } catch { return """
            oauth_callback_failed: \(error.localizedDescription) Inspect the callback failure before starting a new sign-in with Try again on the \(name) \
            card.
            """ }
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                    "code_verifier": pkce.verifier, "client_id": signIn.clientID]
        form["client_secret"] = clientSecret
        let tokens: [String: Any]
        do { tokens = try await OAuthGrantOperations.postToken(signIn.token, form, basic: signIn.clientAuth == "basic") }
        catch let failure as ProviderFailure.Diagnostic { return failure.localizedDescription }
        catch { return """
            oauth_token_exchange_failed: Browser approval finished, but sign-in is incomplete (\(Keyring.exchangeFailure(error))). Inspect sign_in.token \
            and client authentication in app card.request before starting a new sign-in.
            """ }
        return await keep(tokens)
    }

    /// Show the verification code/link before waiting for remote approval.
    @MainActor
    private static func deviceSignIn(_ name: String, _ signIn: InlineInteraction.SecretAsk.SignIn, device: String, client: [String: String],
                                     shown: @MainActor () async -> Void) async throws -> [String: Any] {
        let basic = signIn.clientAuth == "basic"
        let code = try await OAuthGrantOperations.deviceCode(device, client: client, scopes: signIn.scopes, basic: basic)
        Keyring.signingIn.withLock { $0[name] = "Enter \(code.userCode) at \(code.verificationURI.absoluteString)" }
        defer { Keyring.signingIn.withLock { $0[name] = nil } }
        _ = NSWorkspace.shared.open(code.verificationURIComplete ?? code.verificationURI)
        await shown()
        return try await OAuthGrantOperations.deviceToken(code, endpoint: signIn.token, client: client, basic: basic)
    }
}

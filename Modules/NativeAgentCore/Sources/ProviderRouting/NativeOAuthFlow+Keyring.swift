import AppKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import os
import PersistenceCore
// Blueprint: | `NativeOAuthFlow+Keyring.swift` | `Keyring`: `granted`, `grant`, `forget`, `values` — grant, removal and renewal of one secret on its one queue of the refresh queue registry; a renewal commits only onto the entry it read, and a successful grant or removal voids sign-ins begun before it; `NativeOAuthFlow`: `grantSecret` — the person's grant of a keyring secret, pasted or by a sign-in run from parameters they supplied (PKCE, loopback redirect, token redeemed and kept, never shown) |

/// The keyring's use, owned here with every other sign-in and renewal: a
/// value is read, checked against where its grant lets it go, renewed when
/// a signed-in one expired, and committed, one secret at a time. Grant,
/// replace, remove and renew of one secret all run on its one queue.
extension Keyring {
    private static let renewals = OAuthRefreshQueueRegistry()
    /// Each grant or removal advances the name: an earlier sign-in cannot
    /// overwrite a grant that finished while it was under way.
    private static let generations = OSAllocatedUnfairLock(initialState: [String: Int]())

    public static func generation(_ name: String) -> Int { generations.withLock { $0[name, default: 0] } }

    /// What a device sign-in under way shows on its card: the code, and where to enter it.
    fileprivate static let signingIn = OSAllocatedUnfairLock(initialState: [String: String]())
    public static func signInNote(_ name: String) -> String? { signingIn.withLock { $0[name] } }

    /// The person's removal, after anything already queued for the name.
    public static func forget(_ name: String) async throws {
        try await renewals.queue(forKey: name).run {
            generations.withLock { $0[name, default: 0] += 1 }
            try remove(name)
        }
    }

    /// Where a value is about to go: a host, or a running program as the
    /// file it was launched from (its identity recorded at launch).
    public enum Destination: Sendable, CustomStringConvertible {
        case host(String), program(path: String, identity: String)
        public var description: String {
            switch self { case .host(let host): "host \(host)"; case .program(let path, _): "program \(path)" }
        }
    }

    /// Why a value was not inserted. Its words never carry a value.
    public struct Refusal: LocalizedError, Sendable {
        public let code: String
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Whether a value is kept under `name` that may already go everywhere
    /// asked: each host, and each program as the file it is now.
    public static func granted(_ name: String, hosts: [String], programs: [String]) -> Bool {
        guard let entry = try? entry(name) else { return false }
        return Set(hosts).isSubset(of: entry.hosts) && programs.allSatisfy { path in
            AgentHostCommandLines.identity(ofExecutable: path).map { entry.programs.contains(Program(path: path, identity: $0)) } == true
        }
    }

    /// The person's grant: the value, and exactly where the card said it may
    /// go (each program bound to the executable's identity now), in place of
    /// where it could before; refused when the name was granted or removed since
    /// `generation` was read, or the card is no longer `open` (declined).
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

    /// The values to insert toward one destination, each with its grant
    /// (when the person granted it: a renewal keeps it, a new grant does not);
    /// refuses a name that is not kept or not granted there. A signed-in value
    /// is renewed shortly before it expires, and when it is still the one
    /// `rejected` names (its destination answered 401); `renewed` says a
    /// rejected one was renewed here or by another run since, under the grant
    /// in `grants`: one granted again meanwhile (another account, perhaps)
    /// never says renewed, so a request is not sent again under it. Read,
    /// check, renew and commit run as one step per secret, so two runs never
    /// redeem one refresh token twice.
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
                + "{kind:\"api_key\", target:\"secret:\(name)\", hosts:[…] and/or programs:[…], why}; the value goes from their card to the keyring, never through you.")
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
        guard let renewal = entry.renewal, renewal.expires <= Date().addingTimeInterval(OAuthGrantOperations.renewalMargin) || rejected == entry.value else {
            return (entry.value, rejected.map { $0 != entry.value } ?? false, entry.at)
        }
        let read = entry
        var form = ["grant_type": "refresh_token", "refresh_token": renewal.refreshToken, "client_id": renewal.clientID]
        form["client_secret"] = renewal.clientSecret
        var answered: String?
        do {
            let tokens = try await OAuthGrantOperations.postToken(renewal.token, form, basic: renewal.clientAuth == "basic")
            guard let value = tokens["access_token"] as? String, !value.isEmpty else { throw Refusal(code: "not_connected", message: "no access token came back") }
            answered = account(tokens, hiding: [renewal.refreshToken, renewal.clientSecret])
            entry.value = value
            entry.renewal = Self.renewal(tokens, token: renewal.token, clientID: renewal.clientID, clientSecret: renewal.clientSecret,
                                         clientAuth: renewal.clientAuth, refreshToken: renewal.refreshToken)
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

    /// The account a token answer is for: its OpenID token's subject, when
    /// it carries one (taken from the token endpoint over TLS, OIDC 3.1.3.7),
    /// with every credential of the sign-in cut from it, since she reads it.
    static func account(_ tokens: [String: Any], hiding credentials: [String?]) -> String? {
        guard let subject = (tokens["id_token"] as? String).flatMap({ jwtPayload($0)?["sub"] as? String }) else { return nil }
        return (credentials + [tokens["access_token"] as? String, tokens["refresh_token"] as? String]).compactMap { $0 }
            .filter { !$0.isEmpty }.reduce(subject) { $0.replacingOccurrences(of: $1, with: "[secret]") }
    }

    /// How a token answer renews: its refresh token (or the one it renewed
    /// with) until its expiry; nil when the service gave no way to renew.
    static func renewal(_ tokens: [String: Any], token: String, clientID: String, clientSecret: String?, clientAuth: String?,
                        refreshToken: String?) -> Renewal? {
        guard let refresh = tokens["refresh_token"] as? String ?? refreshToken else { return nil }
        let seconds = OAuthGrantOperations.seconds(tokens["expires_in"])
        return Renewal(token: token, clientID: clientID, clientSecret: clientSecret, clientAuth: clientAuth, refreshToken: refresh,
                       expires: seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture)
    }
}

extension NativeOAuthFlow {
    /// The person's grant of a keyring secret: the value they pasted, or a
    /// sign-in NativeAgent runs from the parameters she supplied as data (PKCE
    /// through a loopback redirect, or a device sign-in whose code `shown`
    /// puts on the card; the token is kept, never shown), with the client
    /// secret the person typed, if any, kept only while its card is `open`.
    /// Nil once kept, else the reason, carrying no value.
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
            return "oauth_client_secret_missing: This sign-in requires HTTP Basic client authentication. Enter the service-issued client secret on this sign-in card."
        }
        func keep(_ tokens: [String: Any]) async -> String? {
            guard let value = tokens["access_token"] as? String, !value.isEmpty else {
                return "oauth_token_missing: The service returned no access token; sign-in is incomplete. Check sign_in.token in app card.request before starting a new sign-in."
            }
            do {
                try await Keyring.grant(name, value: value, hosts: ask.hosts, programs: ask.programs,
                                        renewal: Keyring.renewal(tokens, token: signIn.token, clientID: signIn.clientID, clientSecret: clientSecret,
                                                                 clientAuth: signIn.clientAuth, refreshToken: nil),
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
            return "oauth_sign_in_parameters_invalid: Sign-in requires an HTTPS authorize address and, if set, an HTTP loopback redirect. Correct sign_in.authorize and sign_in.redirect (http://127.0.0.1:<port>/<path>) in app card.request."
        }
        let server: NativeOAuthLoopbackCallbackServer
        do {
            server = try NativeOAuthLoopbackCallbackServer(preferredPort: port, path: given.map(\.path).flatMap { $0.isEmpty ? nil : $0 } ?? "/callback",
                                                           displayName: name, allowsPortFallback: false)
        } catch {
            return "oauth_listener_failed: Could not open the sign-in listener on port \(port): \(error.localizedDescription) Correct the reported socket problem or sign_in.redirect in app card.request before starting a new sign-in."
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
            return "oauth_browser_open_failed: macOS could not open the sign-in URL. Set a working default web browser in System Settings → Desktop & Dock → Default web browser, then choose Try again on the \(name) card."
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
            return "oauth_callback_timeout: No browser callback arrived within 300 seconds. Choose Try again on the \(name) card and finish browser sign-in within five minutes."
        } catch OAuthLoopbackCallbackError.canceled {
            return "oauth_sign_in_cancelled: Sign-in was cancelled. Leave it stopped; no further action is needed."
        } catch is CancellationError {
            return "oauth_sign_in_cancelled: Sign-in was cancelled. Leave it stopped; no further action is needed."
        } catch { return "oauth_callback_failed: \(error.localizedDescription) Inspect the callback failure before starting a new sign-in with Try again on the \(name) card." }
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                    "code_verifier": pkce.verifier, "client_id": signIn.clientID]
        form["client_secret"] = clientSecret
        let tokens: [String: Any]
        do { tokens = try await OAuthGrantOperations.postToken(signIn.token, form, basic: signIn.clientAuth == "basic") }
        catch { return "oauth_token_exchange_failed: Browser approval finished, but sign-in is incomplete (\(Keyring.exchangeFailure(error))). Inspect sign_in.token and client authentication in app card.request before starting a new sign-in." }
        return await keep(tokens)
    }

    /// A device sign-in: its code and link on the card, the link opened for
    /// the person, then the token endpoint asked until they approve there.
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

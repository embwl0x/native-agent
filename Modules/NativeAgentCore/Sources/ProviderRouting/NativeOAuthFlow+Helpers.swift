import Foundation
import CoreFoundation
import Privacy
import CryptoKit
import Darwin
import PersistenceCore
import NativeAgentShared
import TurnTrace
// Blueprint: | `NativeOAuthFlow+Helpers.swift` | PKCE and OAuthGrantOperations.post, the redirect-refusing transport for all token grants; one token-response validator for required access, optional refresh and optional positive expiry before persistence; initial native grants require refresh authority; adapters retain sessions, encoding, 20/30-second request bounds and error classification; owned sessions and device polls have elapsed resource bounds. Device authorization requires the server code lifetime and polls at its valid interval through expiry, denial or cancel |

extension NativeOAuthFlow {
    public struct InlineSetupOutcome: Sendable {
        public var error: String?
        public var note: String?

        public init(error: String? = nil, note: String? = nil) {
            self.error = error
            self.note = note
        }
    }

    /// A failure and its recovery in fixed words. The raw text goes to the local log
    /// only, through the chat secret redactor with every typed value removed
    /// too; it never reaches the card, the transcript or the agent.
    public nonisolated static func inlineSetupFailureReason(
        _ raw: String, service: String, secret: String = "token", typed: [String] = [],
        otherwise: String? = nil
    ) -> String {
        var logged = TurnTraceRedactor.redactText(raw)
        for value in typed where value.count >= 6 {
            logged = logged.replacingOccurrences(of: value, with: "[redacted]")
        }
        nativeLog("%@", "[inline-setup] \(service) failed: \(logged)")
        let text = raw.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        // Local allowlist checks, not service text: the person can fix these.
        if has("at least one allowed", "allowed chat id", "allowed user id", "allowlist") {
            return "\(service) needs a valid allowed chat, channel or user ID. Check the IDs, then try again."
        }
        if has("could not connect", "couldn't connect", "cannot connect", "network connection",
               "timed out", "offline", "not connected to the internet", "hostname", "could not be found",
               "unreachable") {
            return "Couldn't reach \(service). Check your internet connection, then try again."
        }
        // Before the scope check: the format hints name "OAuth & Permissions".
        if has("401", "reject", "unauthorized", "such as", "botfather", "isn't a setup token",
               "enter a valid", "not a valid", "invalid_auth", "invalid token", "invalid api key",
               "incorrect api key", "didn't accept", "not_authed", "bad credentials") {
            return "\(service) rejected the \(secret). Check it's pasted in full, then try again."
        }
        if has("scope", "permission", "forbidden", "403", "not accessible") {
            return "\(service) is missing a permission or scope this needs. Add it in \(service), then try again."
        }
        return otherwise ?? "\(service): other error (details in the app log)."
    }

    /// A pasted provider key, checked with the provider BEFORE it is saved —
    /// Providers' own probe (`testProvider` with the draft key), so a key the
    /// provider rejects is never written and never reads as connected. A
    /// provider Providers has no probe for (e.g. Codex, xAI) is saved and
    /// says so rather than claiming a check that did not happen.
    @MainActor
    public static func saveInlineProviderKey(
        _ key: String, providerName name: String,
        testProvider: @MainActor () async throws -> NativeAgentShared.ProviderTestResult,
        configureProvider: @MainActor () async throws -> Void
    ) async -> InlineSetupOutcome {
        // A typed cause decides the sentence; only a peer that sent none is read as prose.
        func refusal(_ failure: ProviderFailure?, raw: String) -> String {
            switch failure {
            case .authExpired?: return "\(name) rejected the key."
            case .network?: return "Couldn't reach \(name)."
            case let failure?: return "\(name) could not check the key: \(failure.errorDescription ?? "it did not answer")"
            case nil: return inlineSetupFailureReason(raw, service: name, secret: "key", typed: [key])
            }
        }
        let probe: NativeAgentShared.ProviderTestResult
        do {
            probe = try await testProvider()
        } catch {
            return InlineSetupOutcome(error: refusal(ProviderFailure.classify(error), raw: error.localizedDescription))
        }
        let failure = probe.cause.flatMap(ProviderFailure.decoded)
        // A refused check neither rejects nor proves the key: saved, unproven.
        let unproven = probe.tested && probe.status != "ok" && failure == .refused
        if probe.tested, probe.status != "ok", !unproven {
            return InlineSetupOutcome(error: refusal(failure, raw: probe.error ?? ""))
        }
        do {
            // Providers' own configure call — the same one its sheet makes.
            // `defaultModel: nil` so saving a key never silently repoints the
            // provider at a different model.
            try await configureProvider()
        } catch {
            return InlineSetupOutcome(error: inlineSetupFailureReason(
                error.localizedDescription, service: name, secret: "key", typed: [key]
            ))
        }
        if unproven { return InlineSetupOutcome(note: "\(name) API key saved; its last check failed: \(probe.error ?? "refused")") }
        return InlineSetupOutcome(note: probe.tested ? "key checked with \(name)"
                       : "key saved; \(name) has no check to run")
    }
}

// MARK: - PKCE + helpers

public struct PKCE {
    public let verifier: String
    public let challenge: String

    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        let verifier = OAuthGrantOperations.base64URLEncode(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = OAuthGrantOperations.base64URLEncode(Data(digest))
        return PKCE(verifier: verifier, challenge: challenge)
    }
}

public enum OAuthGrantOperations {
    public static let renewalMargin: TimeInterval = 120

    /// Provider answers are admitted here, never by the saved-state reader.
    /// Keep tokens opaque and diagnostics fixed: no response values are echoed.
    public struct TokenResponse {
        public let fields: [String: Any]
        public let accessToken: String
        public let refreshToken: String?
        public let expiresIn: TimeInterval?
    }

    public static func malformedTokenResponse() -> ProviderFailure.Diagnostic {
        ProviderFailure.Diagnostic(cause: .malformedResponse,
            detail: "OAuth token endpoint returned malformed credential data; no saved credential was changed. Try again.")
    }

    public static func validateTokenResponse(_ data: Data, requiringRefreshToken: Bool) throws -> TokenResponse {
        let fields: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw malformedTokenResponse()
            }
            fields = object
        } catch { throw malformedTokenResponse() }
        return try validateTokenResponse(fields, requiringRefreshToken: requiringRefreshToken)
    }

    public static func validateTokenResponse(_ fields: [String: Any], requiringRefreshToken: Bool) throws -> TokenResponse {
        do {
            let invalidCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            func token(_ raw: Any?) throws -> String {
                guard let value = raw as? String, !value.isEmpty,
                      value.rangeOfCharacter(from: invalidCharacters) == nil else {
                    throw malformedTokenResponse()
                }
                return value
            }
            let access = try token(fields["access_token"])
            // Optional JSON null carries no value, just like omission. Network
            // metadata is not a saved credential and has no saved-file schema.
            func supplied(_ key: String) -> Any? {
                guard let value = fields[key], !(value is NSNull) else { return nil }
                return value
            }
            let refresh = try supplied("refresh_token").map { try token($0) }
            guard !requiringRefreshToken || refresh != nil else {
                throw malformedTokenResponse()
            }
            let lifetime = try supplied("expires_in").map { raw -> TimeInterval in
                let seconds: TimeInterval?
                if let string = raw as? String {
                    seconds = TimeInterval(string)
                } else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    seconds = number.doubleValue
                } else {
                    throw malformedTokenResponse()
                }
                guard let seconds, seconds.isFinite, seconds > 0 else {
                    throw malformedTokenResponse()
                }
                return seconds
            }
            return TokenResponse(fields: fields, accessToken: access, refreshToken: refresh, expiresIn: lifetime)
        } catch { throw malformedTokenResponse() }
    }
    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func randomHex(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// One token-endpoint exchange (a code or a refresh grant): the body
    /// posted as a form or JSON, the JSON answer back. A refusal says only its
    /// status: a token endpoint's body can echo a secret no pattern knows.
    public static func postToken(_ endpoint: String, _ body: [String: String], json: Bool = false, basic: Bool = false) async throws -> [String: Any] {
        let (status, answer) = try await post(endpoint, body, json: json, basic: basic)
        if status >= 400 {
            throw NSError(domain: "NativeOAuthFlow", code: status,
                userInfo: [NSLocalizedDescriptionKey: "The token endpoint answered HTTP \(status)."])
        }
        guard let answer else {
            throw malformedTokenResponse()
        }
        return answer
    }

    /// One POST to a sign-in endpoint, its status and JSON answer back
    /// whatever the status. `basic` sends the client's id and secret as HTTP
    /// Basic (RFC 6749 2.3.1), the secret then left out of the body. A
    /// redirect is refused, not followed: a 307/308 would carry the body's
    /// codes and secrets to a host the card never named.
    /// The whole exchange has at most 20 seconds, even if bytes keep arriving;
    /// a device poll may give it less, bounded by the code's remaining lifetime.
    public static func post(_ endpoint: String, _ body: [String: String], json: Bool = false, basic: Bool = false, timeout: TimeInterval = 20) async throws -> (status: Int, answer: [String: Any]?) {
        guard let url = URL(string: endpoint), url.scheme == "https" else {
            throw NSError(domain: "NativeOAuthFlow", code: -2, userInfo: [NSLocalizedDescriptionKey: "The token endpoint must be an https URL."])
        }
        let (data, resp) = try await post(url, body, json: json, basic: basic, timeout: min(20, timeout))
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0,
                (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    /// Shared transport for sign-in and adapter refresh. Adapters keep their
    /// session, encoding and error classification; every grant refuses redirects.
    public static func post(
        _ url: URL, _ body: [String: String], json: Bool = false, basic: Bool = false,
        timeout: TimeInterval = 20, session suppliedSession: URLSession? = nil,
        encodeForm: ([String: String]) -> String = formEncode
    ) async throws -> (data: Data, response: URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var body = body
        if basic, let id = body["client_id"], let secret = body.removeValue(forKey: "client_secret") {
            let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text }
            req.setValue("Basic " + Data("\(encode(id)):\(encode(secret))".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        if json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = encodeForm(body).data(using: .utf8)
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = timeout
        let session = suppliedSession ?? URLSession(configuration: configuration)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        let (data, resp) = try await session.data(for: req, delegate: NoRedirect())
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(status) {
            throw NSError(domain: "NativeOAuthFlow", code: status,
                userInfo: [NSLocalizedDescriptionKey: "The sign-in endpoint answered HTTP \(status), a redirect; sign-in does not follow redirects."])
        }
        return (data, resp)
    }

    /// A device sign-in's code (RFC 8628): what the person enters, where,
    /// until when, and how often to ask whether they have.
    public struct DeviceCode: Sendable, Equatable {
        public let deviceCode: String
        public let userCode: String
        public let verificationURI: URL
        /// The link with the code already in it, when the service gives one.
        public let verificationURIComplete: URL?
        public let expiresAt: Date
        public let interval: TimeInterval
    }

    /// Why a device sign-in ended without a token, in fixed words: an error
    /// code it recognizes (RFC 8628 3.5, RFC 6749 5.2) said its own way, any
    /// other only by its HTTP status, never the endpoint's text.
    public enum DeviceSignInFailure: Error, Equatable, LocalizedError {
        case expired, denied, refused(String)
        init(_ answer: [String: Any]?, status: Int) {
            switch answer?["error"] as? String {
            case "expired_token"?: self = .expired
            case "access_denied"?: self = .denied
            case "invalid_client"?: self = .refused("it did not accept the client id or secret")
            case "invalid_grant"?: self = .refused("it did not accept the device code")
            case "unauthorized_client"?: self = .refused("this client may not sign in by device")
            case "invalid_scope"?: self = .refused("it did not accept the scopes asked for")
            case "unsupported_grant_type"?: self = .refused("it offers no device sign-in there")
            case "invalid_request"?: self = .refused("it found the request malformed")
            default: self = .refused("it answered HTTP \(status)")
            }
        }
        public var errorDescription: String? {
            switch self {
            case .expired: "oauth_code_expired: The code expired before approval. Get a new code with Try again on the sign-in card."
            case .denied: "oauth_sign_in_declined: The sign-in was declined. Leave it declined; no further action is needed unless the person asks to sign in."
            case .refused(let why): "oauth_sign_in_rejected: The service rejected sign-in: \(why). Correct the sign-in parameters in app card.request before asking the person to sign in."
            }
        }
    }

    /// A device authorization endpoint's code for the person to approve
    /// elsewhere. `client` is the client_id and any client_secret.
    public static func deviceCode(_ endpoint: String, client: [String: String], scopes: String?, basic: Bool = false) async throws -> DeviceCode {
        var form = client
        form["scope"] = scopes
        let (status, answer) = try await post(endpoint, form, basic: basic)
        if answer?["error"] != nil || status >= 400 { throw DeviceSignInFailure(answer, status: status) }
        let link = { (key: String) in (answer?[key] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil } }
        guard let answer, let deviceCode = answer["device_code"] as? String, let userCode = answer["user_code"] as? String,
              let uri = link("verification_uri") ?? link("verification_url") else { throw DeviceSignInFailure.refused("its answer was incomplete") }
        let lifetime = try deviceCodeLifetime(answer)
        let interval: TimeInterval
        if let raw = answer["interval"] {
            guard let supplied = seconds(raw), supplied > 0 else {
                throw DeviceSignInFailure.refused("its polling interval was invalid")
            }
            interval = supplied
        } else { interval = 5 } // RFC 8628's omitted-interval default.
        return DeviceCode(deviceCode: deviceCode, userCode: userCode, verificationURI: uri,
                          verificationURIComplete: link("verification_uri_complete"),
                          expiresAt: Date().addingTimeInterval(lifetime), interval: interval)
    }

    /// Asks the token endpoint at the server's interval (5 seconds more at
    /// each slow_down, RFC 8628 3.5; never a sleep past the code's expiry)
    /// until the person approves (the token answer comes back), declines, or
    /// the code expires.
    /// A dropped connection or a 5xx while they approve is asked again at the
    /// next interval; cancelling the task stops it.
    public static func deviceToken(_ code: DeviceCode, endpoint: String, client: [String: String], basic: Bool = false) async throws -> [String: Any] {
        var interval = max(code.interval, 1)
        var form = client
        form["device_code"] = code.deviceCode
        form["grant_type"] = "urn:ietf:params:oauth:grant-type:device_code"
        while Date() < code.expiresAt {
            try await Task.sleep(for: .seconds(min(interval, max(code.expiresAt.timeIntervalSinceNow, 0))))
            let remaining = code.expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { throw DeviceSignInFailure.expired }
            let reply: (status: Int, answer: [String: Any]?)
            do { reply = try await post(endpoint, form, basic: basic, timeout: remaining) }
            catch is URLError { try Task.checkCancellation(); continue }
            guard Date() < code.expiresAt else { throw DeviceSignInFailure.expired }
            guard reply.status < 500, let answer = reply.answer else { continue }
            switch answer["error"] as? String {
            case nil where reply.status < 400:
                return answer
            case "authorization_pending"?: continue
            case "slow_down"?:
                if let raw = answer["interval"] {
                    guard let supplied = seconds(raw), supplied > 0 else {
                        throw DeviceSignInFailure.refused("its polling interval was invalid")
                    }
                    interval = max(supplied, interval + 5)
                } else { interval += 5 }
            default: throw DeviceSignInFailure(answer, status: reply.status)
            }
        }
        throw DeviceSignInFailure.expired
    }

    /// A number of seconds an answer gives as a number or a string, within
    /// what a date and a sleep hold (0 to about 68 years); invalid input is nil.
    public static func seconds(_ raw: Any?) -> TimeInterval? {
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let seconds = number.doubleValue
            return seconds.isFinite && (0...Double(Int32.max)).contains(seconds) ? seconds : nil
        }
        guard let string = raw as? String, let seconds = TimeInterval(string),
              seconds.isFinite, (0...Double(Int32.max)).contains(seconds) else { return nil }
        return seconds
    }

    /// Device codes must expire to bound their polling; token expiry is optional.
    private static func deviceCodeLifetime(_ response: [String: Any]) throws -> TimeInterval {
        guard let raw = response["expires_in"] else {
            throw NSError(domain: "NativeOAuthFlow", code: -22,
                userInfo: [NSLocalizedDescriptionKey: "OAuth response is missing required expires_in; no credential was saved."])
        }
        guard let value = seconds(raw), value > 0 else {
            throw NSError(domain: "NativeOAuthFlow", code: -22,
                userInfo: [NSLocalizedDescriptionKey: "OAuth response has invalid expires_in; no credential was saved."])
        }
        return value
    }

    public static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }

    static func updateProviderCredential(
        at path: URL,
        replacingXAIGrant: Bool = false,
        update: (inout [String: Any]) throws -> Void
    ) throws {
        try CredentialFileLock.withLock(path) {
            var object: [String: Any]
            if replacingXAIGrant {
                object = try ProviderStateValidation.credentialMetadata(at: path)
            } else {
                object = try ProviderStateValidation.credential(at: path)
            }
            try update(&object)
            try ProviderStateValidation.credential(object)
            try writeJSONObject(object, to: path)
        }
    }

    /// Credential writes share the refresh path lock; callers already holding it bypass nonrecursive flock.
    public static func writeJSONObject(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if url.lastPathComponent == "xai_oauth_direct.json",
           ["access_token", "refresh_token", "id_token", "tokens"].contains(where: { obj[$0] != nil }) {
            try XAIOAuthCredentialStore.write(obj, to: url)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys])
        try CredentialFileLock.withLock(url) {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url.resolvingSymlinksInPath())
        }
    }

    public static func redact(_ s: String, bearerReplacement: String = "Bearer ***REDACTED***") -> String {
        var out = NativeAgentSecretRedactor.redactText(s) { kind, value in
            switch kind {
            case "GITHUB_TOKEN": return value.hasPrefix("github_pat_") ? "github_pat_***REDACTED***" : "gh***REDACTED***"
            case "SLACK_TOKEN": return "xox***REDACTED***"
            case "BEARER_TOKEN": return bearerReplacement
            default: return "***REDACTED***"
            }
        }
        let patterns: [(String, String)] = [
            // Short bearer values and PATs, JWTs and refresh tokens are stricter
            // OAuth-boundary additions to the shared baseline.
            ("Bearer [A-Za-z0-9._-]+",                               bearerReplacement),
            ("github_pat_[A-Za-z0-9_]{20,}",                          "github_pat_***REDACTED***"),
            ("eyJ[A-Za-z0-9._-]+\\.[A-Za-z0-9._-]+\\.[A-Za-z0-9._-]+", "***REDACTED***"),
            ("rt_[A-Za-z0-9._-]{16,}",                               "rt_***REDACTED***"),
        ]
        for (pat, repl) in patterns {
            if let re = try? NSRegularExpression(pattern: pat) {
                out = re.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out),
                    withTemplate: repl)
            }
        }
        return out
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

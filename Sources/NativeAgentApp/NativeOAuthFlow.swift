import Foundation
import AppKit
import AuthenticationServices
import CryptoKit
import Darwin
import PersistenceCore
import ProviderRouting

// MARK: - NativeOAuthFlow
//
// Swift-native OAuth entry points for provider sign-in, connector sign-in,
// callback handling, token status, and persisted token files.

struct OAuthFlowResult {
    let ok: Bool
    let error: String?
}

enum NativeOAuthFlow {
    static let signInAttempts = OAuthSignInAttempts()

    /// Custom URL scheme registered in Info.plist and against each provider's
    /// desktop client_id. ASWebAuthenticationSession intercepts navigation to
    /// this scheme; the host segment selects the provider.
    static let callbackURLScheme = "nativeagent"

    // MARK: - Public entry

    /// Drive a full PKCE OAuth flow end-to-end.
    /// Returns when tokens have been persisted (or an error has been surfaced).
    @MainActor
    static func startOAuthFlow(
        providerId: String,
        dataRoot: URL? = nil
    ) async -> OAuthFlowResult {
        // User, 2026-09-06: the xAI and ChatGPT flows dropped the selected root
        // here and persisted under the default one.
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        if normalizedOAuthProviderId(providerId) == "xai_oauth_direct" {
            return await startXAIOAuthFlow(dataRoot: root)
        }

        // ChatGPT/OpenAI (2026-07-05, User): codex-free direct sign-in. OpenAI's
        // ChatGPT client only allows a LOOPBACK redirect, not a custom scheme,
        // so it can't use the ASWebAuthenticationSession path below — it runs a
        // native local-listener flow (:1455) instead. See NativeOAuthFlow+Loopback.
        if providerId == "openai_oauth_direct" {
            return await startOpenAILoopbackFlow(dataRoot: root)
        }

        let config: ProviderOAuthConfig
        switch providerId {
        case "anthropic_oauth_direct": config = .anthropic
        default:
            return OAuthFlowResult(ok: false,
                error: "Unknown OAuth provider id: \(providerId)")
        }

        let attempt = signInAttempts.begin(providerId: providerId, dataRoot: root)
        defer { signInAttempts.finish(attempt) }
        let pkce = PKCE.generate()
        // pi-ai / Claude Code convention: Anthropic uses the verifier as state.
        // OpenAI uses random hex (mirrors pi-ai's randomBytes(16).toString).
        let state: String = (config.stateEqualsVerifier ? pkce.verifier
                                                        : randomHex(16))

        let redirectURI = config.redirectURI

        // Build authorization URL.
        let authURL = config.buildAuthURL(
            redirectURI: redirectURI,
            state: state,
            challenge: pkce.challenge
        )

        // Run the in-process auth session. Throws on user-cancel / scheme
        // mismatch / OS failure; returns the callback URL on success.
        let callbackURL: URL
        do {
            callbackURL = try await runAuthSession(
                authURL: authURL,
                expectedState: state,
                providerId: providerId
            )
        } catch let err as ASWebAuthenticationSessionError
            where err.code == .canceledLogin {
            return OAuthFlowResult(ok: false,
                error: "Sign-in canceled.")
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Auth session failed: \(error.localizedDescription)")
        }

        // Parse and validate the callback URL.
        let code: String
        switch validateCallback(callbackURL, expectedState: state) {
        case .code(let validatedCode):
            code = validatedCode
        case .failure(let message):
            return OAuthFlowResult(ok: false, error: message)
        }

        // Exchange the code for tokens.
        let tokens: [String: Any]
        do {
            tokens = try await config.exchangeCode(
                code: code,
                verifier: pkce.verifier,
                state: state,
                redirectURI: redirectURI
            )
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Token exchange failed: \(redact(error.localizedDescription))")
        }

        guard let accessToken = tokens["access_token"] as? String,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return OAuthFlowResult(ok: false,
                error: "Token exchange did not return an access token.")
        }

        // Persist tokens to disk in the shape the read-side adapters expect.
        do {
            try signInAttempts.commit(attempt) {
                try config.persistTokens(tokens, root)
            }
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Could not write token file: \(error.localizedDescription)")
        }

        return OAuthFlowResult(ok: true, error: nil)
    }

    static func normalizedOAuthProviderId(_ providerId: String) -> String {
        switch providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return "xai_oauth_direct"
        default:
            return providerId
        }
    }
}

/// 2026-09-06: sign-out and newer sign-ins retire suspended native OAuth
/// attempts. The check and synchronous token write share the sign-out lock,
/// so a late browser/token response cannot silently reconnect an account.
final class OAuthSignInAttempts: @unchecked Sendable {
    struct Attempt {
        let key: String
        let id: UUID
    }

    private let lock = NSLock()
    private var current: [String: UUID] = [:]

    private func key(providerId: String, dataRoot: URL) -> String {
        NativeOAuthFlow.normalizedOAuthProviderId(providerId) + "|"
            + dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func begin(providerId: String, dataRoot: URL) -> Attempt {
        let attempt = Attempt(key: key(providerId: providerId, dataRoot: dataRoot), id: UUID())
        lock.withLock { current[attempt.key] = attempt.id }
        return attempt
    }

    func finish(_ attempt: Attempt) {
        lock.withLock {
            if current[attempt.key] == attempt.id { current[attempt.key] = nil }
        }
    }

    func commit(_ attempt: Attempt, write: () throws -> Void) throws {
        try lock.withLock {
            guard current[attempt.key] == attempt.id, !Task.isCancelled else {
                throw NSError(domain: "NativeOAuthFlow", code: -23, userInfo: [
                    NSLocalizedDescriptionKey: "Sign-in was canceled or superseded. Start sign-in again."
                ])
            }
            try write()
        }
    }

    func clear(providerId: String, dataRoot: URL, remove: () -> Bool) -> Bool {
        let key = key(providerId: providerId, dataRoot: dataRoot)
        return lock.withLock {
            current[key] = nil
            return remove()
        }
    }
}

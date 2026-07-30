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

    /// Custom URL scheme registered in Info.plist and against each provider's
    /// desktop client_id. ASWebAuthenticationSession intercepts navigation to
    /// this scheme; the host segment selects the provider.
    static let callbackURLScheme = "nativeagent"

    // MARK: - Public entry

    /// Drive a full PKCE OAuth flow end-to-end.
    /// Returns when tokens have been persisted (or an error has been surfaced).
    @MainActor
    static func startOAuthFlow(providerId: String) async -> OAuthFlowResult {
        if normalizedOAuthProviderId(providerId) == "xai_oauth_direct" {
            return await startXAIOAuthFlow()
        }

        // ChatGPT/OpenAI (2026-07-05, User): codex-free direct sign-in. OpenAI's
        // ChatGPT client only allows a LOOPBACK redirect, not a custom scheme,
        // so it can't use the ASWebAuthenticationSession path below — it runs a
        // native local-listener flow (:1455) instead. See NativeOAuthFlow+Loopback.
        if providerId == "openai_oauth_direct" {
            return await startOpenAILoopbackFlow()
        }

        let config: ProviderOAuthConfig
        switch providerId {
        case "anthropic_oauth_direct": config = .anthropic
        default:
            return OAuthFlowResult(ok: false,
                error: "Unknown OAuth provider id: \(providerId)")
        }

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

        // Persist tokens to disk in the shape the read-side adapters expect.
        do {
            try config.persistTokens(tokens)
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

import Foundation
import PersistenceCore
// Blueprint: | `NativeOAuthFlow+Loopback.swift` | `NativeOAuthFlow`: `startOpenAILoopbackFlow`, `callbackTarget`, `callbackHasResult` |

// MARK: - Loopback OAuth (ChatGPT / OpenAI)
//
// OpenAI's ChatGPT sign-in client (`app_EMoamEEZ73f0CkXaXp7hrann`, the same
// public client the `codex` CLI uses) only allows a LOOPBACK redirect —
// `http://localhost:1455/auth/callback` — never a custom URL scheme. So the
// custom-scheme ASWebAuthenticationSession path that Anthropic/Grok use returns
// an OpenAI "unknown_error" for ChatGPT (redirect_uri not registered).
//
// This runs codex's flow natively, minus the codex binary: bind a one-shot
// local HTTP listener on 127.0.0.1:1455, open auth.openai.com in the default
// browser, catch the `GET /auth/callback?code=…&state=…` redirect, hand the
// browser a "you can close this" page, then PKCE-exchange the code exactly as
// the shared ProviderOAuthConfig.openai already does. Verified port/path/params
// against the shipped codex Rust binary (1455, /auth/callback, /success,
// id_token_add_organizations, codex_cli_simplified_flow) — 2026-07-05.
//
// Hardening (gpt-5.5 review 2026-07-05): per-connection buffering so a split
// request line can't hang; EXACT /auth/callback path match + require code/error
// before resolving (stray probes like /favicon.ico get a 404 and are ignored);
// open the browser only on listener .ready; fail loud on port-in-use; wire task
// cancellation to tear the listener down.

extension NativeOAuthFlow {

    /// Fixed loopback port OpenAI's ChatGPT client is registered against.
    public static let openAILoopbackPort: UInt16 = 1455
    public static let openAILoopbackPath = "/auth/callback"

    @MainActor
    public static func startOpenAILoopbackFlow(
        platform: any NativeOAuthPlatformPort.Type,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> OAuthFlowResult {
        let attempt = signInAttempts.begin(providerId: "openai_oauth_direct", dataRoot: dataRoot)
        defer { signInAttempts.finish(attempt) }
        let config = ProviderOAuthConfig.openai
        let redirectURI = "http://localhost:\(openAILoopbackPort)\(openAILoopbackPath)"

        let pkce = PKCE.generate()
        let state = NativeOAuthSupport.randomHex(16)
        let authURL = config.buildAuthURL(
            redirectURI: redirectURI,
            state: state,
            challenge: pkce.challenge
        )

        let callbackURL: URL
        do {
            callbackURL = try await platform.runLoopbackAuthSession(
                authURL: authURL,
                port: openAILoopbackPort,
                expectedState: state
            )
        } catch {
            return OAuthFlowResult(ok: false,
                error: "ChatGPT sign-in failed: \(error.localizedDescription)")
        }

        let code: String
        switch validateCallback(callbackURL, expectedState: state,
            providerErrorMessage: { "ChatGPT returned an error: \($0)" },
            missingCodeMessage: "ChatGPT did not return an authorization code.") {
        case .code(let value): code = value
        case .failure(let message): return OAuthFlowResult(ok: false, error: message)
        }

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
                error: "Token exchange failed: \(NativeOAuthSupport.redact(error.localizedDescription))")
        }

        do {
            try signInAttempts.commit(attempt) {
                try config.persistTokens(tokens, dataRoot)
            }
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Could not write token file: \(error.localizedDescription)")
        }

        Task {
            do {
                _ = try await ChatGPTAccountModelRefresh.shared.refresh(dataRoot: dataRoot, force: true)
            } catch {
                nativeLog("ChatGPT account model refresh after sign-in failed: %@", error.localizedDescription)
            }
        }
        return OAuthFlowResult(ok: true, error: nil)
    }

    /// The browser tab's one line once the callback lands. The token exchange
    /// hasn't run yet, so the tab claims nothing; the app comes forward with
    /// the real result (OAuthSignInButton.runFlow).
    public static func callbackPageMessage(_ url: URL) -> String {
        let declined = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "error" } == true
        return declined
            ? "Sign-in didn't finish — return to NativeAgent to try again."
            : "Finishing sign-in — return to NativeAgent."
    }

    /// From `GET /auth/callback?code=…&state=… HTTP/1.1`, return the request
    /// target (path+query) ONLY when the path is EXACTLY `/auth/callback`.
    public static func callbackTarget(from requestLine: String) -> String? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = String(parts[1])
        guard OAuthLoopbackCallbackPolicy.validCallbackURL(target: target,
            path: openAILoopbackPath, port: openAILoopbackPort) != nil else { return nil }
        return target
    }

    /// True only when the callback carries an OAuth result (code or error) —
    /// so a bare `/auth/callback` probe can't resolve the flow prematurely.
    public static func callbackHasResult(_ url: URL) -> Bool {
        OAuthLoopbackCallbackPolicy.hasResult(url)
    }

}

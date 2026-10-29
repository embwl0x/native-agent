import Foundation
import PersistenceCore
import NativeAgentShared
// Blueprint: | `NativeOAuthFlow+Loopback.swift` | `NativeOAuthFlow`: `startOpenAILoopbackFlow`, `callbackPageMessage` |

// MARK: - Loopback OAuth (ChatGPT / OpenAI)
//
// ChatGPT sign-in requires the loopback redirect http://localhost:1455/auth/callback and a PKCE exchange.
// Buffer each connection and accept only exact callback paths with code/error; other probes receive 404.
// Open the browser only when the listener is ready; port conflicts fail and cancellation closes the listener.

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
        let state = OAuthGrantOperations.randomHex(16)
        let authURL: URL
        do { authURL = try config.buildAuthURL(
            redirectURI: redirectURI,
            state: state,
            challenge: pkce.challenge
        ) } catch {
            return OAuthFlowResult(ok: false, error: "Invalid authorization URL: \(error.localizedDescription)")
        }

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
                error: "Token exchange failed: \(OAuthGrantOperations.redact(error.localizedDescription))")
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

}

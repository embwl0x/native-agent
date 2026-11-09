import Foundation
import PersistenceCore
import NativeAgentShared
// Blueprint: | `NativeOAuthFlow+Loopback.swift` | `NativeOAuthFlow`: `startOpenAILoopbackFlow`, `callbackPageMessage` |

// MARK: - Loopback OAuth (ChatGPT / OpenAI)
// The ChatGPT client requires its registered loopback redirect and PKCE. Open the browser only after listener readiness; port conflicts fail and
// cancellation closes the listener.

extension NativeOAuthFlow {

    /// Fixed loopback port OpenAI's ChatGPT client is registered against.
    public static let openAILoopbackPort: UInt16 = 1455
    public static let openAILoopbackPath = "/auth/callback"

    @concurrent
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

        // Awaited: Chat selects the account as soon as this returns, and selecting needs the account's model catalog.
        do {
            _ = try await ChatGPTAccountModelRefresh.shared.refresh(dataRoot: dataRoot, force: true)
        } catch {
            nativeLog("ChatGPT account model refresh after sign-in failed: %@", error.localizedDescription)
        }
        return OAuthFlowResult(ok: true, error: nil)
    }

    /// The callback precedes token exchange, so the browser tab cannot claim sign-in success; the app presents the actual result.
    public static func callbackPageMessage(_ url: URL) -> String {
        let declined = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "error" } == true
        return declined
            ? "Sign-in didn't finish — return to NativeAgent to try again."
            : "Finishing sign-in — return to NativeAgent."
    }

}

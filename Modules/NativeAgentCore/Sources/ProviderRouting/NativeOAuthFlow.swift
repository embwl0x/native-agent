import Foundation
import CryptoKit
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `NativeOAuthFlow.swift` | `NativeOAuthFlow` enum; `validateSignInDestination`, `startOAuthFlow`, Anthropic setup-token normalization/admission/write |

// MARK: - NativeOAuthFlow
//
// Swift-native OAuth entry points for provider sign-in, connector sign-in,
// callback handling, token status, and persisted token files.

public struct OAuthFlowResult: Sendable {
    public init(ok: Bool, error: String?) { self.ok = ok; self.error = error }
    public let ok: Bool
    public let error: String?
}

public enum NativeOAuthFlow {
    /// Save a pasted setup token; nil on success, else the reason. Shared with
    /// the inline provider card, so both write the one shape.
    public static func saveAnthropicSetupToken(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        guard t.hasPrefix("sk-ant-oat") else {
            return "That isn't a setup token. Setup tokens start with sk-ant-oat."
        }
        do {
            let dataRoot = PersistenceCore.defaultDataRoot()
            let providersDir = dataRoot.appendingPathComponent("providers", isDirectory: true)
            let path = providersDir.appendingPathComponent("anthropic_oauth_direct.json")
            try FileManager.default.createDirectory(at: providersDir, withIntermediateDirectories: true)
            let now = ISO8601DateFormatter().string(from: Date())
            let payload: [String: Any] = [
                "access_token": t,
                "auth_mode": "setup_token",
                "saved_at": now,
            ]
            try OAuthGrantOperations.writeJSONObject(payload, to: path)
            return nil
        } catch {
            return "Failed to save setup-token: \(error.localizedDescription)"
        }
    }

    static let signInAttempts = OAuthSignInAttempts()

    /// Custom URL scheme registered in Info.plist and against each provider's
    /// desktop client_id. ASWebAuthenticationSession intercepts navigation to
    /// this scheme; the host segment selects the provider.
    public static let callbackURLScheme = "nativeagent"

    public static func validateSignInDestination(providerId: String, dataRoot: URL) throws {
        let path: URL
        switch normalizedOAuthProviderId(providerId) {
        case "openai_oauth_direct": path = openAIAppOwnedAuthPath(dataRoot: dataRoot)
        case "anthropic_oauth_direct": path = anthropicTokenPath(dataRoot: dataRoot)
        case "xai_oauth_direct": path = XAIOAuthTransport.tokenPath(dataRoot: dataRoot)
        default: throw ProviderRoutingError.providerNotFound
        }
        do {
            if normalizedOAuthProviderId(providerId) == "xai_oauth_direct" {
                _ = try ProviderStateValidation.credentialMetadata(at: path)
            } else {
                _ = try ProviderStateValidation.credential(at: path)
            }
        } catch {
            // The checker, its reason and the lever: an absent file passes, so moving it aside clears the way.
            throw ToolFailureError(
                "Sign-in was not started: \(path.path) could not be read as a saved sign-in (\(error.localizedDescription)). Move that file aside on the Mac, then sign in again.",
                effects: .none, owner: path.path, tap: "Finder › \(path.path)", personDecides: true)
        }
    }

    // MARK: - Public entry

    /// Drive a full PKCE OAuth flow end-to-end.
    /// Returns when tokens have been persisted (or an error has been surfaced).
    @MainActor
    public static func startOAuthFlow(
        platform: any NativeOAuthPlatformPort.Type,
        providerId: String,
        dataRoot: URL? = nil
    ) async -> OAuthFlowResult {
        // Every sign-in flow persists under the selected root.
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        if normalizedOAuthProviderId(providerId) == "xai_oauth_direct" {
            return await startXAIOAuthFlow(platform: platform, dataRoot: root)
        }

        // ChatGPT sign-in uses the native loopback listener because its client requires a loopback redirect.
        if providerId == "openai_oauth_direct" {
            return await startOpenAILoopbackFlow(platform: platform, dataRoot: root)
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
        // Anthropic binds state to the PKCE verifier.
        let state = pkce.verifier

        let redirectURI = config.redirectURI

        // Build authorization URL.
        let authURL: URL
        do { authURL = try config.buildAuthURL(
            redirectURI: redirectURI,
            state: state,
            challenge: pkce.challenge
        ) } catch {
            return OAuthFlowResult(ok: false, error: "Invalid authorization URL: \(error.localizedDescription)")
        }

        // Run the in-process auth session. Throws on user-cancel / scheme
        // mismatch / OS failure; returns the callback URL on success.
        let callbackURL: URL
        do {
            callbackURL = try await platform.runAuthSession(
                authURL: authURL,
                expectedState: state,
                providerId: providerId
            )
        } catch where platform.isCanceledLogin(error) {
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
                error: "Token exchange failed: \(OAuthGrantOperations.redact(error.localizedDescription))")
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

    public static func normalizedOAuthProviderId(_ providerId: String) -> String {
        switch providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return "xai_oauth_direct"
        default:
            return providerId
        }
    }
}

/// Sign-out and newer sign-ins retire pending attempts; checks and token writes share the sign-out lock.
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

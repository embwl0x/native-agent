import Foundation
import Testing
@testable import NativeAgentApp

private func anthropicOAuthButtonRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("anthropic-oauth-button-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Provider Settings Anthropic OAuth button — canonical credential boundary")
struct ProviderSettingsAnthropicOAuthButtonEvalTests {
    @Test("the Anthropic OAuth control reads the same injected credential root its flow writes")
    @MainActor
    func mountedButtonUsesInjectedRootForSignedInStatus() async throws {
        let root = try anthropicOAuthButtonRoot("ready")
        defer { try? FileManager.default.removeItem(at: root) }
        try NativeOAuthFlow.persistAnthropicOAuthTokens([
            "access_token": "anthropic-access-token",
            "refresh_token": "anthropic-refresh-token",
            "expires_in": 3_600,
            "scope": "user:profile",
        ], dataRoot: root)
        let path = NativeOAuthFlow.anthropicTokenPath(dataRoot: root)
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(NativeOAuthFlow.isSignedIn(
            providerId: "anthropic_oauth_direct",
            dataRoot: root
        ))

        let presentation = OAuthSignInPresentation.status(
            providerID: "anthropic_oauth_direct",
            dataRoot: root
        )
        #expect(presentation.state == .complete,
                "the control must not inspect the global provider root")
        #expect(presentation.detail?.hasPrefix("Signed in") == true)
        #expect(OAuthSignInPresentation.buttonControl(
            providerDisplayShort: "Anthropic", state: presentation.state
        ) == .init(title: "Re-authenticate Anthropic", isDisabled: false))
    }

    @Test("browser sign-in offers cancellation while waiting and a retry action when idle")
    func browserSignInRecoveryControls() {
        let running = OAuthSignInPresentation.buttonControl(
            providerDisplayShort: "ChatGPT", state: .running
        )
        #expect(running.title == "Signing in…")
        #expect(running.isDisabled)
        #expect(running.showsCancel)
        #expect(running.guidance == "Finish signing in in your browser")

        let idle = OAuthSignInPresentation.buttonControl(
            providerDisplayShort: "ChatGPT", state: .idle
        )
        #expect(idle.title == "Sign in with ChatGPT")
        #expect(!idle.isDisabled)
        #expect(!idle.showsCancel)
        #expect(idle.guidance == nil)
        #expect(!OAuthSignInPresentation.buttonControl(
            providerDisplayShort: "ChatGPT", state: .complete
        ).showsCancel)
    }

    @Test("missing exchange access token and damaged credentials fail closed without overwriting bytes")
    func invalidOrDamagedAnthropicOAuthPersistenceIsAdverse() throws {
        let root = try anthropicOAuthButtonRoot("damaged")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = NativeOAuthFlow.anthropicTokenPath(dataRoot: root)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let damaged = Data("{ damaged credential".utf8)
        try damaged.write(to: path)

        #expect(throws: Error.self) {
            try NativeOAuthFlow.persistAnthropicOAuthTokens([
                "access_token": "replacement-token",
            ], dataRoot: root)
        }
        #expect(try Data(contentsOf: path) == damaged)
        #expect(!NativeOAuthFlow.isSignedIn(
            providerId: "anthropic_oauth_direct",
            dataRoot: root
        ))
        #expect(OAuthSignInPresentation.status(
            providerID: "anthropic_oauth_direct", dataRoot: root
        ).error?.contains("credentials unavailable") == true)

        let emptyRoot = try anthropicOAuthButtonRoot("missing-access")
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        #expect(throws: Error.self) {
            try NativeOAuthFlow.persistAnthropicOAuthTokens([
                "refresh_token": "refresh-only",
            ], dataRoot: emptyRoot)
        }
        #expect(!FileManager.default.fileExists(
            atPath: NativeOAuthFlow.anthropicTokenPath(dataRoot: emptyRoot).path
        ))
    }

    @Test("root-scoped sign-out removes only the provider token it just displayed")
    func signOutUsesTheInjectedAnthropicRoot() throws {
        let root = try anthropicOAuthButtonRoot("signout")
        defer { try? FileManager.default.removeItem(at: root) }
        try NativeOAuthFlow.persistAnthropicOAuthTokens([
            "access_token": "anthropic-access-token",
        ], dataRoot: root)
        #expect(NativeOAuthFlow.clearTokens(
            providerId: "anthropic_oauth_direct",
            dataRoot: root
        ))
        #expect(!FileManager.default.fileExists(
            atPath: NativeOAuthFlow.anthropicTokenPath(dataRoot: root).path
        ))
        #expect(OAuthSignInPresentation.status(
            providerID: "anthropic_oauth_direct", dataRoot: root
        ).state == .idle)
    }
}

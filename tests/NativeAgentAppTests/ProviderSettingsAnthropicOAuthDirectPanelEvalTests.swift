import Foundation
import Testing
@testable import NativeAgentApp

private func anthropicOAuthPanelRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("anthropic-oauth-panel-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Provider Settings Anthropic OAuth direct panel — canonical control")
struct ProviderSettingsAnthropicOAuthDirectPanelEvalTests {
    @Test("the direct panel and canonical credential reader use the injected OAuth root")
    @MainActor
    func directPanelShowsTheCanonicalRootScopedStatus() async throws {
        let root = try anthropicOAuthPanelRoot("expired")
        defer { try? FileManager.default.removeItem(at: root) }
        try NativeOAuthFlow.persistAnthropicOAuthTokens([
            "access_token": "panel-token",
            "expires_in": 0,
        ], dataRoot: root)
        #expect(AnthropicOAuthDirectPanelPresentation.title == "Connect via Anthropic OAuth")
        #expect(NativeOAuthFlow.anthropicOAuthCredentialState(dataRoot: root) == .ready)
        let control = OAuthSignInPresentation.status(
            providerID: "anthropic_oauth_direct",
            dataRoot: root
        )
        #expect(control.state == .complete)
        #expect(control.detail == "Expired — refresh on next chat")
        #expect(OAuthSignInPresentation.buttonControl(
            providerDisplayShort: "Anthropic", state: control.state
        ) == .init(title: "Re-authenticate Anthropic", isDisabled: false))
    }

    @Test("a damaged direct-panel credential store is visibly unavailable and byte-preserved")
    @MainActor
    func damagedCredentialsStayVisibleAsAnAdversePanelState() async throws {
        let root = try anthropicOAuthPanelRoot("damaged")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = NativeOAuthFlow.anthropicTokenPath(dataRoot: root)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let damaged = Data("{bad credential bytes".utf8)
        try damaged.write(to: path)
        guard case .unavailable(let detail) = NativeOAuthFlow.anthropicOAuthCredentialState(dataRoot: root) else {
            Issue.record("damaged credentials were not surfaced as unavailable")
            return
        }
        #expect(detail.contains("could not be read"))
        let control = OAuthSignInPresentation.status(
            providerID: "anthropic_oauth_direct",
            dataRoot: root
        )
        #expect(control.state == .idle)
        #expect(control.error?.contains("credentials unavailable") == true)
        #expect(OAuthSignInPresentation.buttonControl(
            providerDisplayShort: "Anthropic", state: control.state
        ) == .init(title: "Sign in with Anthropic", isDisabled: false))
        #expect(try Data(contentsOf: path) == damaged)
    }
}

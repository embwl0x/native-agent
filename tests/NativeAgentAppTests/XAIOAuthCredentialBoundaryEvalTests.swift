import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.ProviderSettings.xaiOAuthButton

@Suite("xAI provider OAuth credential boundary")
struct XAIOAuthCredentialBoundaryEvalTests {
    @Test("xAI provider and X connector flows resolve to disjoint persisted credentials")
    func providerAndConnectorNeverShareARevocationTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xai-oauth-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let providerPath = OAuthCredentialDestinations.xAIProvider(dataRoot: root)
        let connectorPath = NativeOAuthFlow.connectorTokenPath(connectorId: "x", dataRoot: root)
        let runtimeMirror = OAuthCredentialDestinations.xConnectorRuntimeMirror(dataRoot: root)

        #expect(OAuthCredentialDestinations.areDisjoint(dataRoot: root))
        #expect(providerPath != connectorPath)
        #expect(providerPath != runtimeMirror)
        #expect(providerPath.lastPathComponent == "xai_oauth_direct.json")
        #expect(connectorPath.lastPathComponent == "auth.json")
        #expect(runtimeMirror.lastPathComponent == "x.json")

        try FileManager.default.createDirectory(at: providerPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: connectorPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"access_token":"provider-token"}"#.utf8).write(to: providerPath)
        try Data(#"{"access_token":"connector-token"}"#.utf8).write(to: connectorPath)

        #expect(try Data(contentsOf: providerPath) != Data(contentsOf: connectorPath))
    }

    @Test("non-X connector paths stay in their own connector namespaces")
    func connectorDestinationDoesNotAliasTheXProvider() {
        let root = URL(fileURLWithPath: "/tmp/nativeagent-xai-boundary", isDirectory: true)
        #expect(NativeOAuthFlow.connectorTokenPath(connectorId: "github", dataRoot: root)
            != OAuthCredentialDestinations.xAIProvider(dataRoot: root))
    }
}

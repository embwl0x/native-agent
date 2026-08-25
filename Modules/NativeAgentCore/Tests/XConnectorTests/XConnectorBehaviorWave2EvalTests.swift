import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import XConnector

@Suite("X connector behavior wave 2")
struct XConnectorBehaviorWave2EvalTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("x-behavior-wave2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let value): return value
        case .array(let values): return values.map(text).joined(separator: " ")
        case .object(let object): return object.values.map(text).joined(separator: " ")
        default: return ""
        }
    }

    @Test("X client id prefers nonblank environment over the persisted OAuth app")
    func clientIDEnvironmentPrecedenceAndFileFallback() throws {
        let root = try root()
        let path = root.appending(path: "connectors/x/oauth_app.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"client_id":" file-client "}"#.utf8).write(to: path)

        #expect(XConnectorActions.resolveClientID(environment: [:], dataRoot: root) == "file-client")
        #expect(XConnectorActions.resolveClientID(
            environment: ["NATIVE_AGENT_X_CLIENT_ID": " env-client "], dataRoot: root
        ) == "env-client")
        #expect(XConnectorActions.resolveClientID(
            environment: ["NATIVE_AGENT_X_CLIENT_ID": "  "], dataRoot: root
        ) == "file-client")
    }

    @Test("X client id fails closed for malformed or blank persisted credentials")
    func clientIDRejectsMalformedAndBlankFile() throws {
        let root = try root()
        let path = root.appending(path: "connectors/x/oauth_app.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: path)
        #expect(XConnectorActions.resolveClientID(environment: [:], dataRoot: root) == nil)
        try Data(#"{"client_id":"  "}"#.utf8).write(to: path)
        #expect(XConnectorActions.resolveClientID(environment: [:], dataRoot: root) == nil)
    }

    @Test("X OAuth1 secrets refuse group or world readable credentials")
    func oauth1SecretsRequirePrivateRegularFile() throws {
        let root = try root()
        let path = root.appendingPathComponent("x.json")
        try Data(#"{"api_key":"key"}"#.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        #expect(throws: Error.self) { try XConnectorActions.loadOAuth1Secrets(at: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        #expect(try XConnectorActions.loadOAuth1Secrets(at: path)["api_key"] as? String == "key")
    }

    @Test("X HTTP failure receipts preserve status but redact nested provider secrets")
    func httpFailureRedactsProviderSecret() {
        let token = "xapp-" + String(repeating: "a", count: 28)
        let envelope = XConnectorActions.httpFailureEnvelope(
            actionId: "x.me", statusCode: 401, data: Data("denied \(token)".utf8)
        )
        guard case .object(let object) = envelope else {
            Issue.record("expected a typed failure envelope")
            return
        }
        #expect(object["status"] == .string("failed"))
        #expect(object["statusCode"] == .int(401))
        #expect(!text(envelope).contains(token))
        #expect(text(envelope).contains("[REDACTED_CONNECTOR_SECRET]"))
    }

    @Test("X status credential display never contains the complete key")
    func credentialMaskKeepsOnlyEdgeCharacters() {
        let raw = "abcdefghijklmnop"
        let masked = XConnectorActions.mask(raw)
        #expect(masked == "abcd...mnop")
        #expect(!masked.contains("efghijkl"))
    }

    @Test("X user identity cache is partitioned by credential identity")
    func userIdentityCacheCannotCrossCredentialLanes() async {
        let cache = XConnectorActions.UserIDCache()
        let oauth2 = XConnectorActions.credentialCacheKey(kind: "oauth2", material: "bearer-a")
        let oauth1 = XConnectorActions.credentialCacheKey(kind: "oauth1", material: "key-a:token-a")
        let rotated = XConnectorActions.credentialCacheKey(kind: "oauth2", material: "bearer-b")
        await cache.set("user-a", for: oauth2)
        await cache.set("user-b", for: oauth1)
        #expect(await cache.get(for: oauth2) == "user-a")
        #expect(await cache.get(for: oauth1) == "user-b")
        #expect(await cache.get(for: rotated) == nil)
    }
}

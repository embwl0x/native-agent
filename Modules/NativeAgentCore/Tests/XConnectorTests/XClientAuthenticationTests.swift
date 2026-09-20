import Foundation
import Testing
@testable import XConnector

struct XClientAuthenticationTests {
    @Test func refreshUsesTheSecretFromTheSameSourceAsTheClientID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("connectors/x/oauth_app.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"client_id":"saved-id","client_secret":"saved-secret"}"#.utf8).write(to: path)

        let saved = try #require(XConnectorActions.resolveClientCredentials(environment: [:], dataRoot: root))
        #expect(saved.id == "saved-id")
        #expect(saved.secret == "saved-secret")
        let publicClient = try #require(XConnectorActions.resolveClientCredentials(
            environment: ["NATIVE_AGENT_X_CLIENT_ID": "public-id"], dataRoot: root
        ))
        #expect(publicClient.secret == nil)
        #expect(XConnectorActions.oauthClientAuthorization(clientID: publicClient.id, clientSecret: publicClient.secret) == nil)
        let confidential = try #require(XConnectorActions.resolveClientCredentials(environment: [
            "NATIVE_AGENT_X_CLIENT_ID": " client:id ",
            "NATIVE_AGENT_X_CLIENT_SECRET": " secret+value ",
        ], dataRoot: root))
        let header = try #require(XConnectorActions.oauthClientAuthorization(
            clientID: confidential.id, clientSecret: confidential.secret
        ))
        let decoded = try #require(Data(base64Encoded: String(header.dropFirst("Basic ".count))))
        #expect(String(decoding: decoded, as: UTF8.self) == "client%3Aid:secret%2Bvalue")
    }
}

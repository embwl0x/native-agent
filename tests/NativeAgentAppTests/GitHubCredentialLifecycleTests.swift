import Foundation
import GitHubConnector
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

private final class AppTestGitHubCredentialVault: GitHubCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(service: String, account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values["\(service)|\(account)"]
    }

    func write(_ token: String, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values["\(service)|\(account)"] = token
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: "\(service)|\(account)")
    }

    func token(dataRoot: URL) -> String? {
        try? read(
            service: GitHubCredentialStore.keychainService,
            account: GitHubCredentialStore.credentialAccount(dataRoot: dataRoot)
        )
    }
}

@Test func githubOAuthSaveAndRevokeUseKeychainLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-app-github-credential-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let token = "ghp_" + "appfixtureabcdefghijklmnopqrstuvwxyz123456"
    let vault = AppTestGitHubCredentialVault()
    let store = GitHubCredentialStore(vault: vault)

    let result = await NativeOAuthFlow.saveGitHubToken(
        token,
        validateWithGitHub: false,
        dataRoot: root,
        credentialStore: store
    )
    #expect(result.ok)
    #expect(vault.token(dataRoot: root) == token)
    for path in GitHubCredentialStore.metadataPaths(dataRoot: root) {
        guard case .object(let object) = try JSONValue.parse(Data(contentsOf: path)) else {
            Issue.record("Expected GitHub metadata object")
            continue
        }
        #expect(object["access_token"] == nil)
        #expect(object["credential_store"] == .string("macos_keychain"))
    }

    try await NativeClient(baseURL: "").revokeConnector(
        provider: "github",
        githubCredentialStore: store,
        dataRoot: root
    )
    #expect(vault.token(dataRoot: root) == nil)
    for path in GitHubCredentialStore.metadataPaths(dataRoot: root) {
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}

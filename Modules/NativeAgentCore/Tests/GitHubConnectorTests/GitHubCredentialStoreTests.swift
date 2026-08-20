import Foundation
import LocalAuthentication
import NativeAgentCore
import PersistenceCore
import Security
import Testing
@testable import GitHubConnector

enum TestGitHubCredentialVaultError: Error {
    case readFailed
    case writeFailed
}

final class TestGitHubCredentialVault: GitHubCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failReads = false
    var failWrites = false

    func read(service: String, account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if failReads { throw TestGitHubCredentialVaultError.readFailed }
        return values["\(service)|\(account)"]
    }

    func write(_ token: String, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw TestGitHubCredentialVaultError.writeFailed }
        values["\(service)|\(account)"] = token
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: "\(service)|\(account)")
    }

    func seed(_ token: String, dataRoot: URL) {
        lock.lock(); defer { lock.unlock() }
        values[
            "\(GitHubCredentialStore.keychainService)|\(GitHubCredentialStore.credentialAccount(dataRoot: dataRoot))"
        ] = token
    }

    func token(dataRoot: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[
            "\(GitHubCredentialStore.keychainService)|\(GitHubCredentialStore.credentialAccount(dataRoot: dataRoot))"
        ]
    }
}

@Test func systemGitHubCredentialVaultIsNonInteractiveAndRefusesTheTestHarness() throws {
    let query = SystemGitHubCredentialVault.nonInteractiveIdentityQuery(
        service: "com.nativeagent.tests.never-touch-keychain.\(UUID().uuidString)",
        account: "fixture"
    )
    let context = query[kSecUseAuthenticationContext as String] as? LAContext
    #expect(context?.interactionNotAllowed == true)
    #expect(SystemGitHubCredentialVault.isRunningUnderTestHarness)

    do {
        _ = try SystemGitHubCredentialVault().read(
            service: "com.nativeagent.tests.never-touch-keychain.\(UUID().uuidString)",
            account: "fixture"
        )
        Issue.record("the system Keychain vault must refuse every test process before Security.framework")
    } catch GitHubCredentialVaultError.testHarnessAccessRefused {
        // Expected: no SecItem call was made, so no password UI can appear.
    } catch {
        Issue.record("unexpected test-harness refusal: \(error)")
    }
}

@Test func githubCredentialMigrationScrubsOnlyExactGitHubPaths() async throws {
    let root = try githubCredentialTempRoot()
    let token = "ghp_" + "migrationfixtureabcdefghijklmnopqrstuvwxyz"
    let paths = GitHubCredentialStore.metadataPaths(dataRoot: root)
    try writeObject(["access_token": .string(token), "login": .string("octocat")], to: paths[0])
    try writeObject(["pat": .string(token), "saved_at": .string("2026-07-11T00:00:00Z")], to: paths[1])

    let codexAuth = root
        .appendingPathComponent("codex_home", isDirectory: true)
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("auth.json")
    try writeObject(["access_token": .string("codex-credential-must-not-move")], to: codexAuth)

    let vault = TestGitHubCredentialVault()
    let store = GitHubCredentialStore(vault: vault)
    #expect(try await store.resolveToken(dataRoot: root) == token)
    #expect(vault.token(dataRoot: root) == token)

    for path in paths {
        let object = try readObject(path)
        #expect(object["access_token"] == nil)
        #expect(object["token"] == nil)
        #expect(object["pat"] == nil)
        #expect(object["credential_store"] == .string("macos_keychain"))
        #expect(object["credential_version"] == .int(1))
    }
    #expect(try readObject(codexAuth)["access_token"] == .string("codex-credential-must-not-move"))
}

@Test func githubCredentialMigrationDoesNotScrubWhenVaultWriteFails() async throws {
    let root = try githubCredentialTempRoot()
    let token = "github_pat_" + "writefailurefixtureabcdefghijklmnopqrstuvwxyz"
    let path = GitHubCredentialStore.metadataPaths(dataRoot: root)[0]
    try writeObject(["access_token": .string(token)], to: path)
    let vault = TestGitHubCredentialVault()
    vault.failWrites = true
    let store = GitHubCredentialStore(vault: vault)

    await #expect(throws: TestGitHubCredentialVaultError.writeFailed) {
        _ = try await store.resolveToken(dataRoot: root)
    }
    #expect(try readObject(path)["access_token"] == .string(token))
}

@Test func githubCredentialResolutionScrubsStalePlaintextWhenKeychainAlreadyExists() async throws {
    let root = try githubCredentialTempRoot()
    let token = "ghp_" + "existingkeychainfixtureabcdefghijklmnopqrstuvwxyz"
    let path = GitHubCredentialStore.metadataPaths(dataRoot: root)[0]
    try writeObject(["access_token": .string("stale-plaintext-value")], to: path)
    let vault = TestGitHubCredentialVault()
    vault.seed(token, dataRoot: root)
    let store = GitHubCredentialStore(vault: vault)

    #expect(try await store.resolveToken(dataRoot: root) == token)
    #expect(try readObject(path)["access_token"] == nil)
}

@Test func githubCredentialResolutionFailsClosedWhenVaultReadFails() async throws {
    let root = try githubCredentialTempRoot()
    let token = "ghp_" + "readfailurefixtureabcdefghijklmnopqrstuvwxyz"
    let path = GitHubCredentialStore.metadataPaths(dataRoot: root)[0]
    try writeObject(["access_token": .string(token)], to: path)
    let vault = TestGitHubCredentialVault()
    vault.failReads = true
    let store = GitHubCredentialStore(vault: vault)

    await #expect(throws: TestGitHubCredentialVaultError.readFailed) {
        _ = try await store.resolveToken(dataRoot: root)
    }
    #expect(try readObject(path)["access_token"] == .string(token))
}

@Test func githubCredentialSaveWritesMetadataWithoutSecrets() async throws {
    let root = try githubCredentialTempRoot()
    let token = "ghp_" + "savefixtureabcdefghijklmnopqrstuvwxyz"
    let vault = TestGitHubCredentialVault()
    let store = GitHubCredentialStore(vault: vault)
    let metadata = GitHubCredentialMetadata(
        savedAt: "2026-07-11T12:00:00Z",
        validatedAt: "2026-07-11T12:00:00Z",
        login: "octocat",
        name: "Octo Cat",
        htmlURL: "https://github.com/octocat",
        type: "User",
        userID: 42
    )

    try await store.saveToken(token, metadata: metadata, dataRoot: root)
    #expect(vault.token(dataRoot: root) == token)
    for path in GitHubCredentialStore.metadataPaths(dataRoot: root) {
        let object = try readObject(path)
        #expect(object["access_token"] == nil)
        #expect(object["token"] == nil)
        #expect(object["pat"] == nil)
        #expect(object["login"] == .string("octocat"))
        #expect(object["user_id"] == .int(42))
    }
}

@Test func githubCredentialUsesDifferentOpaqueAccountsPerDataRoot() throws {
    let first = try githubCredentialTempRoot()
    let second = try githubCredentialTempRoot()
    let firstAccount = GitHubCredentialStore.credentialAccount(dataRoot: first)
    let secondAccount = GitHubCredentialStore.credentialAccount(dataRoot: second)
    #expect(firstAccount != secondAccount)
    #expect(!firstAccount.contains(first.path))
    #expect(!secondAccount.contains(second.path))
}

@Test func githubCredentialDeleteRemovesVaultItemAndBothMetadataFiles() async throws {
    let root = try githubCredentialTempRoot()
    let token = "ghp_" + "deletefixtureabcdefghijklmnopqrstuvwxyz"
    let vault = TestGitHubCredentialVault()
    let store = GitHubCredentialStore(vault: vault)
    try await store.saveToken(
        token,
        metadata: GitHubCredentialMetadata(savedAt: "2026-07-11T12:00:00Z"),
        dataRoot: root
    )

    try await store.deleteCredential(dataRoot: root)

    #expect(vault.token(dataRoot: root) == nil)
    for path in GitHubCredentialStore.metadataPaths(dataRoot: root) {
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}

private func githubCredentialTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-github-credential-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeObject(_ object: [String: JSONValue], to path: URL) throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONValue.object(object).serializedData(pretty: true).write(to: path, options: .atomic)
}

private func readObject(_ path: URL) throws -> [String: JSONValue] {
    guard case .object(let object) = try JSONValue.parse(Data(contentsOf: path)) else { return [:] }
    return object
}

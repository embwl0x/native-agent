import Foundation
import Connectors
import GitHubConnector

struct AppGitHubOAuthCredentials: GitHubOAuthCredentialPort {
    let store: GitHubCredentialStore = .shared

    func saveToken(_ token: String, metadata: GitHubCredentialMetadata, dataRoot: URL,
                   persistConnection: @Sendable () async throws -> Void) async throws {
        try await store.saveToken(token, metadata: metadata, dataRoot: dataRoot, persistConnection: persistConnection)
    }

    func saveOAuthToken(_ token: GitHubOAuthDeviceFlow.Token, metadata: GitHubCredentialMetadata, dataRoot: URL,
                        persistConnection: @Sendable () async throws -> Void) async throws {
        try await store.saveOAuthToken(token, metadata: metadata, dataRoot: dataRoot, persistConnection: persistConnection)
    }

    func resolveToken(dataRoot: URL) async throws -> String? {
        try await store.resolveToken(dataRoot: dataRoot)
    }
}

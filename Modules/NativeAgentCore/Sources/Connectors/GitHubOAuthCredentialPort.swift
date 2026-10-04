import Foundation
import GitHubConnector

/// The application supplies access to its existing Keychain credential store.
public protocol GitHubOAuthCredentialPort: Sendable {
    func saveToken(_ token: String, metadata: GitHubCredentialMetadata, dataRoot: URL,
                   persistConnection: @Sendable () async throws -> Void) async throws
    func saveOAuthToken(_ token: GitHubOAuthDeviceFlow.Token, metadata: GitHubCredentialMetadata, dataRoot: URL,
                        persistConnection: @Sendable () async throws -> Void) async throws
    func resolveToken(dataRoot: URL) async throws -> String?
}

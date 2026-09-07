import Foundation
import PersistenceCore
import Connectors
import GitHubConnector


extension NativeClient {
    func revokeConnector(
        provider: String,
        githubCredentialStore: GitHubCredentialStore = .shared,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws {
        if provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "github" {
            try await githubCredentialStore.deleteCredential(dataRoot: dataRoot)
        }
        let impl = makeConnectorAuthClient(root: dataRoot)
        _ = try await impl.revokeConnector(provider: provider)
        return
    }

}

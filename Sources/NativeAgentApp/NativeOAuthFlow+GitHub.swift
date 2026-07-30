import Foundation
import PersistenceCore
import GitHubConnector

private struct GitHubSavedUserFields: Sendable {
    var login: String?
    var name: String?
    var htmlURL: String?
    var type: String?
    var userID: Int64?

    init(_ fields: [String: Any]) {
        self.login = fields["login"] as? String
        self.name = fields["name"] as? String
        self.htmlURL = fields["html_url"] as? String
        self.type = fields["type"] as? String
        if let id = fields["id"] as? Int {
            self.userID = Int64(id)
        } else if let id = fields["id"] as? Int64 {
            self.userID = id
        } else {
            self.userID = nil
        }
    }
}

extension NativeOAuthFlow {
    static func saveGitHubToken(
        _ rawToken: String,
        validateWithGitHub: Bool = true,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        credentialStore: GitHubCredentialStore = .shared
    ) async -> OAuthFlowResult {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleGitHubToken(token) else {
            return OAuthFlowResult(ok: false,
                error: "Paste a GitHub Personal Access Token such as ghp_... or github_pat_....")
        }

        let userFields: GitHubSavedUserFields
        if validateWithGitHub {
            do {
                userFields = GitHubSavedUserFields(try await GitHubConnectorActions.validateToken(token))
            } catch {
                return OAuthFlowResult(ok: false,
                    error: "GitHub token validation failed: \(redact(error.localizedDescription))")
            }
        } else {
            userFields = GitHubSavedUserFields([:])
        }

        let now = isoBasic(Date())
        let metadata = GitHubCredentialMetadata(
            savedAt: now,
            validatedAt: validateWithGitHub ? now : nil,
            login: userFields.login,
            name: userFields.name,
            htmlURL: userFields.htmlURL,
            type: userFields.type,
            userID: userFields.userID
        )

        do {
            try await credentialStore.saveToken(token, metadata: metadata, dataRoot: dataRoot)

            _ = try await NativeClient.mutateConnectorRegistryEntry(
                root: dataRoot,
                provider: "github",
                createIfMissing: true
            ) { entry in
                entry["id"] = .string("github")
                entry["name"] = .string("GitHub")
                entry["kind"] = .string("connector")
                entry["description"] = .string("GitHub REST API connector using a local Personal Access Token.")
                entry["enabled"] = .bool(true)
                entry["registered"] = .bool(true)
                entry["client_id_present"] = .bool(true)
                entry["authState"] = .string("connected")
                entry["healthStatus"] = .string("ok")
                entry["connected"] = .bool(true)
                entry["connected_at"] = .string(now)
                entry["connectedAt"] = .string(now)
            }
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Could not save GitHub token: \(redact(error.localizedDescription))")
        }

        return OAuthFlowResult(ok: true, error: nil)
    }

    static func loadGitHubToken(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        credentialStore: GitHubCredentialStore = .shared
    ) async throws -> String? {
        try await credentialStore.resolveToken(dataRoot: dataRoot)
    }

    private static func isPlausibleGitHubToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        let acceptedPrefix = lower.hasPrefix("ghp_")
            || lower.hasPrefix("github_pat_")
            || lower.hasPrefix("gho_")
            || lower.hasPrefix("ghu_")
            || lower.hasPrefix("ghs_")
            || lower.hasPrefix("ghr_")
        guard acceptedPrefix else { return false }
        return token.count > 20 && token.range(of: #"\s"#, options: .regularExpression) == nil
    }

}

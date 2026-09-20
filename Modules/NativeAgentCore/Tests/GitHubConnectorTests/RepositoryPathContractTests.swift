import Testing
import PersistenceCore
@testable import GitHubConnector

@Test func toolContractGitHubRepositoryRootAndPaths() throws {
    for repo in ["owner/repo", "https://github.com/owner/repo", "/owner/repo/"] {
        let identity = try GitHubConnectorActions.repositoryIdentity(["repo": .string(repo), "owner": .null])
        #expect(identity.fullName == "owner/repo")
        for path in ["/", "", "."] {
            #expect(try GitHubConnectorActions.repositoryContentPath(.string(path)) == "")
        }
    }
    #expect(try GitHubConnectorActions.repositoryContentPath(.null) == "")
    #expect(try GitHubConnectorActions.repositoryContentPath(.string("/Sources/main.swift")) == "Sources/main.swift")
    do {
        _ = try GitHubConnectorActions.repositoryContentPath(.string("Sources/../Secrets"))
        Issue.record("Traversal accepted")
    } catch {
        #expect(String(describing: error).contains("path must be repository-relative"))
        #expect(String(describing: error).contains("Sources/main.swift"))
    }
}

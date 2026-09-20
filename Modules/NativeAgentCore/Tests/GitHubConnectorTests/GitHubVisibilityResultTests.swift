import Foundation
import Testing
import PersistenceCore
@testable import GitHubConnector

@Test func visibilityChangeRequiresConfirmation() throws {
    for requested in [false, true] {
        for observed: Any in [requested, !requested, NSNull(), "true", 1] {
            let result = GitHubConnectorActions.visibilityResult(
                repository: "owner/repo", requestedPrivate: requested, response: ["private": observed])
            guard case .object(let fields) = result else { Issue.record("Expected a result object"); continue }
            let confirmed = JSONValue(fromFoundation: observed) == .bool(requested)
            #expect(fields["ok"] == .bool(confirmed))
            #expect(fields["status"] == .string(confirmed ? "completed" : "outcome_unknown"))
            #expect(fields["private"] == JSONValue(fromFoundation: observed))
        }
    }
}

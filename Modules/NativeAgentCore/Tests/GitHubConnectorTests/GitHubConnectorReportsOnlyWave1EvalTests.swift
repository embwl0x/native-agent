import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import GitHubConnector

// MARK: - Wave 1 behavioral promotions — core.connectors
//
// Every assertion exercises a request/envelope seam used by the production
// action itself. No request is sent: malformed identities fail before transport
// and successful cases stop at the canonical bounded request representation.

@Suite("core.connectors reports-only wave 1")
struct GitHubConnectorReportsOnlyWave1EvalTests {
    @Test("github.status emits a stable redacted success envelope")
    func githubStatusEnvelopeIsTypedAndRedacted() throws {
        let token = "ghp_" + String(repeating: "a", count: 36)
        let value = GitHubConnectorActions.statusEnvelope(user: [
            // `GitHubToolProjection.user` is intentionally bounded, so put
            // the credential-shaped control in a retained projection field.
            "login": "octo-\(token)",
            "name": "Octo Cat",
        ])
        guard case .object(let object) = value else {
            Issue.record("github.status must return an object envelope")
            return
        }
        #expect(object["actionId"] == .string("github.status"))
        #expect(object["connectorId"] == .string("github"))
        #expect(object["ok"] == .bool(true))
        #expect(object["status"] == .string("completed"))
        let rendered = try value.serialize(pretty: false)
        #expect(!rendered.contains(token), "status output must never leak its credential-shaped input")
        #expect(rendered.contains("[REDACTED_GITHUB_TOKEN]"), "positive control: the redactor must actually bite")
    }

    @Test("github.list_pull_requests preserves defaults, explicit bounds, and exact repository identity")
    func pullRequestReadRequestIsBoundedAndDeterministic() throws {
        let defaults = try GitHubConnectorActions.pullRequestReadRequest(input: [
            "repo": .string(" owner/widgets "),
        ])
        #expect(defaults.repo == "owner/widgets")
        #expect(defaults.path == "repos/owner/widgets/pulls")
        #expect(defaults.page == 1)
        #expect(defaults.perPage == 20)
        #expect(defaults.params == [
            "state": "open", "sort": "updated", "direction": "desc",
            "page": "1", "per_page": "20",
        ])

        let explicit = try GitHubConnectorActions.pullRequestReadRequest(input: [
            "repo": .string("owner/widgets"), "page": .int(9), "limit": .int(9_999),
            "state": .string("closed"), "sort": .string("created"),
            "direction": .string("asc"), "head": .string("owner:branch"), "base": .string("release"),
        ])
        #expect(explicit.page == 9)
        #expect(explicit.perPage == 20)
        #expect(explicit.params["state"] == "closed")
        #expect(explicit.params["head"] == "owner:branch")
        #expect(explicit.params["base"] == "release")

        // Negative control: a bare repository must fail before it can produce
        // a plausible request path for a different owner.
        #expect(throws: GitHubConnectorError.self) {
            _ = try GitHubConnectorActions.pullRequestReadRequest(input: ["repo": .string("widgets")])
        }
    }

    @Test("github.get_issue never coerces a missing or non-positive issue identity")
    func issueReadRequestRefusesAmbiguousIdentity() throws {
        let request = try GitHubConnectorActions.issueReadRequest(input: [
            "repository": .string("owner/widgets"), "number": .int(42),
        ])
        #expect(request.repo == "owner/widgets")
        #expect(request.number == 42)
        #expect(request.path == "repos/owner/widgets/issues/42")

        for input: [String: JSONValue] in [
            ["repo": .string("owner/widgets")],
            ["repo": .string("owner/widgets"), "number": .int(0)],
            ["repo": .string("owner/widgets"), "number": .int(-2)],
        ] {
            #expect(throws: GitHubConnectorError.self) {
                _ = try GitHubConnectorActions.issueReadRequest(input: input)
            }
        }
    }

    @Test("contribution tracking binds only to the authenticated account")
    func contributionLoginGuardFailsClosedForAnotherAccount() throws {
        #expect(try GitHubConnectorActions.contributionLogin(requested: nil, authenticated: "Agent") == "Agent")
        #expect(try GitHubConnectorActions.contributionLogin(requested: " agent ", authenticated: "Agent") == "Agent")
        #expect(throws: GitHubConnectorError.self) {
            _ = try GitHubConnectorActions.contributionLogin(requested: "someone-else", authenticated: "Agent")
        }
        #expect(throws: GitHubConnectorError.self) {
            _ = try GitHubConnectorActions.contributionLogin(requested: nil, authenticated: "   ")
        }
    }

    @Test("tracker cadence clamps both forgotten-work and refresh bounds")
    func trackingTimingIsExplicitlyBounded() {
        let defaults = GitHubConnectorActions.trackingTiming(input: [:])
        #expect(defaults.refreshIntervalMinutes == 5)
        #expect(defaults.staleAfterHours == 72)

        let low = GitHubConnectorActions.trackingTiming(input: [
            "refresh_interval_minutes": .int(0), "stale_after_hours": .int(0),
        ])
        #expect(low.refreshIntervalMinutes == 5)
        #expect(low.staleAfterHours == 1)

        let high = GitHubConnectorActions.trackingTiming(input: [
            "refresh_interval_minutes": .int(99_999), "stale_after_hours": .int(99_999),
        ])
        #expect(high.refreshIntervalMinutes == 1_440)
        #expect(high.staleAfterHours == 2_160)
    }
}

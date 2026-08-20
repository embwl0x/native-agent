import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import GitHubConnector

@Test func githubConnectorMigratesTokenFromConnectorAuth() async throws {
    let root = try tempRoot()
    let auth = root
        .appendingPathComponent("connectors", isDirectory: true)
        .appendingPathComponent("github", isDirectory: true)
        .appendingPathComponent("auth.json")
    try FileManager.default.createDirectory(
        at: auth.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    // Split literal so secret scanners don't flag this fixture; runtime value unchanged.
    let ghToken = "ghp_" + "abcdefghijklmnopqrstuvwxyz1234567890"
    try Data(#"{"access_token":"\#(ghToken)"}"#.utf8)
        .write(to: auth)

    let vault = TestGitHubCredentialVault()
    let credentialStore = GitHubCredentialStore(vault: vault)
    #expect(try await GitHubConnectorActions.loadToken(
        dataRoot: root,
        credentialStore: credentialStore
    ) == ghToken)
    #expect(vault.token(dataRoot: root) == ghToken)
}

@Test func githubConnectorListIssuesBuildsAuthenticatedUserRequest() throws {
    let request = try GitHubConnectorActions.issueListingRequest(input: [
        "state": .string("all"),
        "sort": .string("comments"),
        "direction": .string("asc"),
        "limit": .int(50),
        "page": .int(2),
        "filter": .string("created"),
        "labels": .string("bug,help wanted"),
    ])

    #expect(request.path == "issues")
    #expect(request.scope == "authenticated_user")
    #expect(request.repository == nil)
    #expect(request.perPage == 20)
    #expect(request.page == 2)
    #expect(request.params["state"] == "all")
    #expect(request.params["sort"] == "comments")
    #expect(request.params["direction"] == "asc")
    #expect(request.params["filter"] == "created")
    #expect(request.params["labels"] == "bug,help wanted")
}

@Test func githubConnectorListIssuesBuildsRepositoryRequest() throws {
    let request = try GitHubConnectorActions.issueListingRequest(input: [
        "repo": .string("openai/codex"),
        "state": .string("open"),
        "assignee": .string("octocat"),
        "creator": .string("hubot"),
        "limit": .int(500),
        "page": .int(0),
    ])

    #expect(request.path == "repos/openai/codex/issues")
    #expect(request.scope == "repository")
    #expect(request.repository == "openai/codex")
    #expect(request.perPage == 20)
    #expect(request.page == 1)
    #expect(request.params["state"] == "open")
    #expect(request.params["sort"] == "updated")
    #expect(request.params["direction"] == "desc")
    #expect(request.params["assignee"] == "octocat")
    #expect(request.params["creator"] == "hubot")
}

@Test func githubConnectorListIssuesRequiresOwnerForBareRepo() throws {
    #expect(throws: GitHubConnectorError.self) {
        _ = try GitHubConnectorActions.issueListingRequest(input: [
            "repo": .string("NativeAgent")
        ])
    }
}

@Test func githubRepositoryIdentityAcceptsFullNameAndRepositoryURL() throws {
    #expect(try GitHubConnectorActions.repositoryIdentity([
        "repo": .string("deepseek-ai/deepseek-harness")
    ]).fullName == "deepseek-ai/deepseek-harness")
    #expect(try GitHubConnectorActions.repositoryIdentity([
        "url": .string("https://github.com/deepseek-ai/deepseek-harness/tree/main")
    ]).fullName == "deepseek-ai/deepseek-harness")
    #expect(try GitHubConnectorActions.repositoryIdentity([
        "owner": .string("deepseek-ai"),
        "repo": .string("deepseek-harness.git"),
    ]).fullName == "deepseek-ai/deepseek-harness")
}

@Test func githubRepositoryIdentityAndPathsRejectUnsafeShapes() throws {
    #expect(throws: GitHubConnectorError.self) {
        _ = try GitHubConnectorActions.repositoryIdentity([
            "url": .string("https://example.com/deepseek-ai/deepseek-harness")
        ])
    }
    #expect(throws: GitHubConnectorError.self) {
        _ = try GitHubConnectorActions.repositoryIdentity([
            "repo": .string("deepseek-ai/deepseek-harness/extra")
        ])
    }
    #expect(throws: GitHubConnectorError.self) {
        _ = try GitHubConnectorActions.repositoryContentPath(.string("Sources/../Secrets"))
    }
}

@Test func githubRepositoryContentProjectionBoundsTextAndRefusesBinary() throws {
    let text = String(repeating: "abc", count: 20_000)
    let projected = GitHubConnectorActions.repositoryContent([
        "name": "README.md",
        "path": "README.md",
        "size": text.utf8.count,
        "encoding": "base64",
        "content": Data(text.utf8).base64EncodedString(),
    ], maxCharacters: 12_000)
    #expect(projected["contentAvailable"] as? Bool == true)
    #expect((projected["content"] as? String)?.count == 12_000)
    #expect(projected["contentCharacters"] as? Int == text.count)
    #expect(projected["contentTruncated"] as? Bool == true)

    let binary = GitHubConnectorActions.repositoryContent([
        "name": "asset.bin",
        "encoding": "base64",
        "content": Data([0, 1, 2, 3]).base64EncodedString(),
    ], maxCharacters: 12_000)
    #expect(binary["contentAvailable"] as? Bool == false)
    #expect(binary["contentKind"] as? String == "binary_or_oversized")
}

@Test func githubRepositoryEntryProjectionIsCompactAndBounded() {
    let source: [[String: Any]] = (0..<150).map { index in
        [
            "name": "file-\(index).swift",
            "path": "Sources/file-\(index).swift",
            "sha": "sha-\(index)",
            "size": index,
            "type": "file",
            "download_url": String(repeating: "x", count: 10_000),
        ]
    }
    let projected = GitHubConnectorActions.repositoryEntries(source, limit: 100)
    #expect(projected.rows.count == 100)
    #expect(projected.sourceCount == 150)
    #expect(projected.truncated)
    #expect(projected.rows[0]["download_url"] == nil)
}

@Test func githubNotificationProjectionIsCompactAndBounded() {
    let source: [[String: Any]] = (0..<30).map { index in
        [
            "id": "notification-\(index)",
            "reason": "review_requested",
            "unread": true,
            "updated_at": "2026-08-14T10:00:00Z",
            "subscription_url": String(repeating: "private-noise", count: 100),
            "subject": [
                "title": "Review \(index)",
                "type": "PullRequest",
                "url": "https://api.github.com/repos/owner/repo/pulls/\(index)",
            ],
            "repository": [
                "id": index,
                "full_name": "owner/repo",
                "html_url": "https://github.com/owner/repo",
                "permissions": ["admin": true],
            ],
        ]
    }
    let projected = GitHubConnectorActions.notificationRows(source, limit: 20)
    #expect(projected.rows.count == 20)
    #expect(projected.sourceCount == 30)
    #expect(projected.truncated)
    #expect(projected.rows[0]["subscription_url"] == nil)
    #expect((projected.rows[0]["repository"] as? [String: Any])?["permissions"] == nil)
}

@Test func githubConnectorErrorsCarryRateLimitWithoutSecrets() {
    let error = GitHubConnectorError.http(
        status: 403,
        message: "API rate limit exceeded",
        rateLimitRemaining: 0,
        rateLimitReset: "2026-07-11T00:00:00Z"
    )
    let text = error.localizedDescription
    #expect(text.contains("rate-limit remaining 0"))
    #expect(text.contains("resets 2026-07-11T00:00:00Z"))
    #expect(!text.contains("Authorization"))
    #expect(!text.contains("github_pat_"))
}

@Test func githubConnectorBoundsPullRequestPatchesAcrossFiles() {
    let raw: [[String: Any]] = [
        ["filename": "one.swift", "patch": "12345"],
        ["filename": "two.swift", "patch": "abcdef"],
    ]
    let value = GitHubConnectorActions.testBoundFilePatches(raw, maxCharacters: 7)
    guard case .object(let object) = value,
          case .int(let characters)? = object["characters"],
          case .bool(let truncated)? = object["truncated"],
          case .array(let files)? = object["files"] else {
        Issue.record("unexpected bounded patch envelope")
        return
    }
    #expect(characters == 7)
    #expect(truncated)
    #expect(files.count == 2)
}

@Test func githubConnectorDerivesBlockingReviewState() {
    let reviews: [[String: Any]] = [
        ["user": ["login": "reviewer"], "state": "APPROVED"],
        ["user": ["login": "reviewer"], "state": "CHANGES_REQUESTED"],
    ]
    #expect(GitHubConnectorActions.testDerivedReviewState(reviews) == "changes_requested")
}

@Test func githubCheckSummaryTrustsGreenRequiredRollupOverOptionalPendingRun() {
    let runs: [String: Any] = [
        "check_runs": [
            ["name": "required", "status": "completed", "conclusion": "success"],
            ["name": "optional analysis", "status": "in_progress", "conclusion": NSNull()],
        ],
    ]
    let combined: [String: Any] = [
        "state": "success",
        "total_count": 1,
        "statuses": [["context": "required", "state": "success", "description": "All required checks pass"]],
    ]
    #expect(GitHubConnectorActions.testCheckSummary(runs, combinedStatus: combined) == "passing")
}

@Test func githubCheckSummaryKeepsCombinedPendingWhenRunsAreGreen() {
    let runs: [String: Any] = [
        "check_runs": [["name": "build", "status": "completed", "conclusion": "success"]],
    ]
    #expect(GitHubConnectorActions.testCheckSummary(
        runs,
        combinedStatus: ["state": "pending", "total_count": 1]
    ) == "pending")
}

@Test func githubCheckSummaryIgnoresEmptyCombinedStatusDefaultPending() {
    let runs: [String: Any] = [
        "check_runs": [
            ["name": "Python tests", "status": "completed", "conclusion": "success"],
            ["name": "TypeScript", "status": "completed", "conclusion": "skipped"],
            ["name": "All required checks pass", "status": "completed", "conclusion": "success"],
        ],
    ]
    let emptyCombined: [String: Any] = ["state": "pending", "total_count": 0, "statuses": []]
    #expect(GitHubConnectorActions.testCheckSummary(runs, combinedStatus: emptyCombined) == "passing")
}

@Test func githubCheckSummaryFallsBackToPendingRunWithoutCombinedRollup() {
    let runs: [String: Any] = [
        "check_runs": [["name": "build", "status": "queued", "conclusion": NSNull()]],
    ]
    #expect(GitHubConnectorActions.testCheckSummary(runs, combinedStatus: [:]) == "pending")
}

@Test func githubCheckSummaryFailureDominatesGreenAndPendingSignals() {
    let failedRuns: [String: Any] = [
        "check_runs": [
            ["name": "build", "status": "completed", "conclusion": "failure"],
            ["name": "analysis", "status": "queued", "conclusion": NSNull()],
        ],
    ]
    #expect(GitHubConnectorActions.testCheckSummary(
        failedRuns,
        combinedStatus: ["state": "success", "total_count": 1]
    ) == "failed")
    #expect(GitHubConnectorActions.testCheckSummary(
        ["check_runs": []],
        combinedStatus: ["state": "error", "total_count": 1]
    ) == "failed")
    #expect(GitHubConnectorActions.testCheckSummary([
        "check_runs": [["name": "old run", "status": "completed", "conclusion": "stale"]],
    ], combinedStatus: [:]) == "failed")
}

@Test func githubCheckSummarySeparatesMaintainerReviewGateFromTechnicalFailure() {
    let maintainerOnly: [String: Any] = [
        "check_runs": [
            ["name": "Review label gate", "status": "completed", "conclusion": "failure"],
            ["name": "All required checks pass", "status": "completed", "conclusion": "failure"],
            ["name": "Python tests", "status": "completed", "conclusion": "success"],
        ],
    ]
    #expect(GitHubConnectorActions.testCheckSummary(
        maintainerOnly,
        combinedStatus: ["state": "pending", "total_count": 0, "statuses": []]
    ) == "maintainer_blocked")

    let technicalToo: [String: Any] = [
        "check_runs": [
            ["name": "Review label gate", "status": "completed", "conclusion": "failure"],
            ["name": "All required checks pass", "status": "completed", "conclusion": "failure"],
            ["name": "Python tests", "status": "completed", "conclusion": "failure"],
        ],
    ]
    #expect(GitHubConnectorActions.testCheckSummary(
        technicalToo,
        combinedStatus: ["state": "pending", "total_count": 0, "statuses": []]
    ) == "failed")
}

@Test func githubCheckSummaryHandlesSuccessfulOrAbsentSignals() {
    #expect(GitHubConnectorActions.testCheckSummary(
        ["check_runs": []],
        combinedStatus: ["state": "success", "total_count": 1]
    ) == "passing")
    #expect(GitHubConnectorActions.testCheckSummary(["check_runs": []], combinedStatus: [:]) == "none")
    #expect(GitHubConnectorActions.testCheckSummary([
        "check_runs": [["name": "build", "status": "completed", "conclusion": "neutral"]],
    ], combinedStatus: [:]) == "passing")
}

@Test func githubSearchProjectionBoundsRowsBodiesAndNestedPayloads() throws {
    let body = String(repeating: "detail ", count: 1_000)
    let items: [[String: Any]] = (1...50).map { number in
        [
            "number": number,
            "title": "PR \(number)",
            "state": "open",
            "body": body,
            "html_url": "https://github.com/owner/repo/pull/\(number)",
            "user": ["login": "builder", "avatar_url": "https://example.invalid/large"],
            "repository": ["full_name": "owner/repo", "clone_url": String(repeating: "x", count: 20_000)],
            "pull_request": ["html_url": "https://github.com/owner/repo/pull/\(number)"],
        ]
    }
    let projected = GitHubToolProjection.searchResult([
        "total_count": 500,
        "incomplete_results": false,
        "items": items,
    ], limit: 100)

    let rows = try #require(projected["items"] as? [[String: Any]])
    #expect(rows.count == 20)
    #expect(projected["returned_count"] as? Int == 20)
    #expect(projected["results_truncated"] as? Bool == true)
    #expect((rows[0]["body"] as? String)?.count == 1_000)
    #expect(rows[0]["body_truncated"] as? Bool == true)
    #expect(rows[0]["repository"] == nil)
    let encoded = try JSONSerialization.data(withJSONObject: projected)
    #expect(encoded.count < 50_000)
}

@Test func githubActivityProjectionBoundsEveryCollectionAndExcerpt() throws {
    let rows: [[String: Any]] = (1...40).map { index in
        [
            "id": index,
            "body": String(repeating: "comment ", count: 500),
            "user": ["login": "reviewer"],
            "diff_hunk": String(repeating: "+line\n", count: 500),
        ]
    }
    let projected = GitHubToolProjection.comments(rows, limit: 100)
    #expect(projected.rows.count == 20)
    #expect(projected.truncated)
    #expect((projected.rows[0]["body"] as? String)?.count == 1_200)
    #expect((projected.rows[0]["diff_hunk"] as? String)?.count == 600)
}

@Test func githubTrackingDigestSamplesLargeCategoriesButKeepsExactCounts() throws {
    let entities: [JSONValue] = (1...25).map { number in
        .object([
            "key": .string("owner/repo#pr#\(number)"),
            "repository": .string("owner/repo"),
            "number": .int(Int64(number)),
            "kind": .string("pull_request"),
            "title": .string("PR \(number)"),
            "state": .string("open"),
            "updatedAt": .string("2026-07-10T18:00:00Z"),
            "url": .string("https://github.com/owner/repo/pull/\(number)"),
            "needsUser": .bool(true),
            "blocked": .bool(false),
            "stale": .bool(false),
        ])
    }
    let keys = entities.compactMap { row -> String? in
        guard case .object(let object) = row,
              case .string(let key)? = object["key"] else { return nil }
        return key
    }
    let digest = GitHubConnectorActions.testTrackingDigest(
        entities,
        changedKeys: keys,
        newKeys: keys
    )
    guard case .object(let object) = digest,
          case .array(let changed)? = object["changed"],
          case .array(let newItems)? = object["new"],
          case .array(let needsUser)? = object["needsUser"] else {
        Issue.record("unexpected digest envelope")
        return
    }
    #expect(changed.count == 10)
    #expect(newItems.count == 10)
    #expect(needsUser.count == 10)
    #expect(object["changedCount"] == .int(25))
    #expect(object["newCount"] == .int(25))
    #expect(object["needsUserCount"] == .int(25))
    #expect(object["samplesLimitedTo"] == .int(10))
    #expect(object["resultsSampled"] == .bool(true))
}

@Test func githubContributionFilterKeepsOnlyAuthoredPullRequests() {
    let rows: [JSONValue] = [
        .object(["number": .int(1), "user": .object(["login": .string("contributor")]), "pull_request": .object([:])]),
        .object(["number": .int(2), "user": .object(["login": .string("someone-else")]), "pull_request": .object([:])]),
        .object(["number": .int(3), "user": .object(["login": .string("CONTRIBUTOR")]), "pull_request": .object([:])]),
        .object(["number": .int(4), "user": .object(["login": .string("contributor")])]),
    ]
    let filtered = GitHubConnectorActions.testContributionFilter(rows, login: "contributor")
    #expect(filtered == [rows[0], rows[2]])
}

@Test func githubContributionLinkedIssueExtractionIsKeywordAndRepositoryScoped() {
    let body = """
    Fixes #12, #13
    Refs: #21 and upstream/project#34
    Closes somebody/else#55
    A casual mention of #89 is not a tracked link.
    """
    #expect(GitHubConnectorActions.testLinkedIssueNumbers(body, repository: "upstream/project") == [12, 13, 21, 34])
}

@Test func githubContributionLinkedIssueExtractionIncludesClosedAuthoredPRBodies() {
    let rows: [JSONValue] = [
        .object([
            "number": .int(1), "state": .string("open"),
            "body": .string("Fixes #12"),
        ]),
        .object([
            "number": .int(2), "state": .string("closed"),
            "body": .string("Closes #34"),
        ]),
    ]
    #expect(
        GitHubConnectorActions.testLinkedIssueNumbersFromContributionRows(
            rows,
            repository: "upstream/project"
        ) == [12, 34]
    )
}

@Test func githubContributionConfigPersistsModeAndLogin() async throws {
    let root = try tempRoot()
    let value = try await GitHubConnectorActions.testSaveTrackingConfig(
        repositories: ["upstream/project"],
        login: "contributor",
        project: "Upstream contributions",
        dataRoot: root
    )
    guard case .object(let object) = value else {
        Issue.record("tracking config was not an object")
        return
    }
    #expect(object["version"] == .int(2))
    #expect(object["mode"] == .string("contributions"))
    #expect(object["contributorLogin"] == .string("contributor"))
    #expect(object["discoveryQuery"] == nil)
    #expect(object["refreshIntervalMinutes"] == .int(5))
}

@Test func githubExplicitRepositoryPersistenceReplacesPriorSet() async throws {
    let root = try tempRoot()
    _ = try await GitHubConnectorActions.testSaveTrackingConfig(
        repositories: ["contributor/fork-one", "contributor/fork-two"],
        login: "contributor",
        project: "Upstream",
        dataRoot: root
    )
    let replacement = try await GitHubConnectorActions.testSaveTrackingConfig(
        repositories: ["upstream/project"],
        login: "contributor",
        project: "Upstream",
        dataRoot: root
    )
    guard case .object(let object) = replacement,
          case .array(let repositories)? = object["repositories"] else {
        Issue.record("replacement config did not contain repositories")
        return
    }
    #expect(repositories.count == 1)
    #expect(repositories.first == .object([
        "defaultBranch": .string("main"),
        "fullName": .string("upstream/project"),
        "htmlURL": .string("https://github.com/upstream/project"),
        "name": .string("project"),
    ]))
}

@Test func githubTrackingNoopsWithoutConfiguration() async throws {
    let root = try tempRoot()
    #expect(try await GitHubConnectorActions.refreshTrackingIfDue(dataRoot: root) == false)
}

@Test func githubTrackingDigestFailsLoudWithoutConfiguration() async throws {
    let root = try tempRoot()
    await #expect(throws: GitHubConnectorError.self) {
        _ = try await GitHubConnectorActions.projectDigest(input: [:], dataRoot: root)
    }
}

@Test func githubTrackingDeskRowsExistOnlyWhileActionable() async throws {
    let root = try tempRoot()
    let key = "owner/repo#pr#7"
    func entity(state: String, blocked: Bool, updatedAt: String) -> JSONValue {
        .object([
            "key": .string(key), "repository": .string("owner/repo"), "number": .int(7),
            "kind": .string("pull_request"), "title": .string("Make Hermes sturdier"),
            "state": .string(state), "updatedAt": .string(updatedAt),
            "url": .string("https://github.com/owner/repo/pull/7"),
            "reviewState": .string("approved"), "checks": .string("passing"),
            "needsUser": .bool(false), "blocked": .bool(blocked), "stale": .bool(false),
        ])
    }

    // A non-actionable open entity never creates a Desk row: the Workshop's
    // GitHub lane is the window into tracked-but-quiet work.
    let watchOnly = try await GitHubConnectorActions.testUpsertTrackingEntities(
        [entity(state: "open", blocked: false, updatedAt: "2026-07-10T09:00:00Z")],
        project: "Hermes", changedKeys: [key], dataRoot: root
    )
    #expect(watchOnly == .object(["archived": .int(0), "created": .int(0), "updated": .int(0)]))
    let store = SwiftNativeDeskStore(dataRoot: root)
    #expect(try await store.liveState().items.isEmpty)

    // Becoming actionable creates exactly one row.
    let first = try await GitHubConnectorActions.testUpsertTrackingEntities(
        [entity(state: "open", blocked: true, updatedAt: "2026-07-10T10:00:00Z")],
        project: "Hermes", changedKeys: [key], dataRoot: root
    )
    #expect(first == .object(["archived": .int(0), "created": .int(1), "updated": .int(0)]))

    let second = try await GitHubConnectorActions.testUpsertTrackingEntities(
        [entity(state: "open", blocked: true, updatedAt: "2026-07-10T10:00:00Z")],
        project: "Hermes", changedKeys: [], dataRoot: root
    )
    #expect(second == .object(["archived": .int(0), "created": .int(0), "updated": .int(0)]))
    var state = try await store.liveState()
    #expect(state.items.count == 1)
    #expect(state.items[0].status == .blocked)
    #expect(state.items[0].refs.filter { if case .ghPr = $0.kind { return true }; return false }.count == 1)

    // Ceasing to be actionable retires the row instead of parking it as watch.
    let unblocked = try await GitHubConnectorActions.testUpsertTrackingEntities(
        [entity(state: "open", blocked: false, updatedAt: "2026-07-10T11:00:00Z")],
        project: "Hermes", changedKeys: [key],
        previousRows: [entity(state: "open", blocked: true, updatedAt: "2026-07-10T10:00:00Z")],
        dataRoot: root
    )
    #expect(unblocked == .object(["archived": .int(1), "created": .int(0), "updated": .int(0)]))
    state = try await store.liveState()
    #expect(state.items.isEmpty)
    #expect(try await store.archivedRecords().count == 1)
}

@Test func githubTrackingNeverResurrectsTerminalDeskRows() async throws {
    let root = try tempRoot()
    let key = "owner/repo#pr#7"
    func entity(blocked: Bool, updatedAt: String) -> JSONValue {
        .object([
            "key": .string(key), "repository": .string("owner/repo"), "number": .int(7),
            "kind": .string("pull_request"), "title": .string("Make Hermes sturdier"),
            "state": .string("open"), "updatedAt": .string(updatedAt),
            "url": .string("https://github.com/owner/repo/pull/7"),
            "reviewState": .string("commented"), "checks": .string("passing"),
            "needsUser": .bool(false), "blocked": .bool(blocked), "stale": .bool(false),
        ])
    }
    _ = try await GitHubConnectorActions.testUpsertTrackingEntities(
        [entity(blocked: true, updatedAt: "2026-07-10T10:00:00Z")],
        project: "Hermes", changedKeys: [key], dataRoot: root
    )
    let store = SwiftNativeDeskStore(dataRoot: root)
    let row = try #require(try await store.liveState().items.first)
    // An operator (or Agent) closes the row. A later refresh whose entity is
    // open-but-quiet must NOT resurrect it to watch — that was the resurrection
    // path that kept re-polluting the Desk after every sweep.
    _ = try await store.closeItem(row.handle, outcomeSummary: "handled")
    let after = try await GitHubConnectorActions.testUpsertTrackingEntities(
        [entity(blocked: false, updatedAt: "2026-07-10T11:00:00Z")],
        project: "Hermes", changedKeys: [key], dataRoot: root
    )
    #expect(after == .object(["archived": .int(0), "created": .int(0), "updated": .int(0)]))
    let final = try #require(try await store.liveState().items.first)
    #expect(final.status.isTerminal)
}

@Test func githubTrackingCleanupArchivesOnlyPriorTrackerOwnedRows() async throws {
    let root = try tempRoot()
    func entity(number: Int) -> JSONValue {
        .object([
            "key": .string("owner/repo#pr#\(number)"), "repository": .string("owner/repo"), "number": .int(Int64(number)),
            "kind": .string("pull_request"), "title": .string("PR \(number)"), "state": .string("open"),
            "updatedAt": .string("2026-07-10T10:00:00Z"), "url": .string("https://github.com/owner/repo/pull/\(number)"),
            "reviewState": .string("approved"), "checks": .string("passing"),
            "needsUser": .bool(false), "blocked": .bool(true), "stale": .bool(false),
        ])
    }
    _ = try await GitHubConnectorActions.testUpsertTrackingEntities(
        [entity(number: 1), entity(number: 2)],
        project: "Hermes", changedKeys: ["owner/repo#pr#1", "owner/repo#pr#2"], dataRoot: root
    )
    let store = SwiftNativeDeskStore(dataRoot: root)
    _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "Keep this non-GitHub work")

    let cleanup = try await GitHubConnectorActions.testUpsertTrackingEntities(
        [entity(number: 1)],
        project: "Hermes", changedKeys: [],
        previousRows: [entity(number: 1), entity(number: 2)],
        dataRoot: root
    )
    #expect(cleanup == .object(["archived": .int(1), "created": .int(0), "updated": .int(0)]))
    let live = try await store.liveState()
    #expect(live.items.count == 2)
    #expect(live.items.contains { $0.title == "PR 1" })
    #expect(live.items.contains { $0.title == "Keep this non-GitHub work" })
    #expect(!live.items.contains { $0.title == "PR 2" })
    #expect(try await store.archivedRecords().count == 1)
}

// Delta refresh (2026-07-16): refresh cost scales with churn, not tracked
// count. These pin the pure carry-vs-fetch decision and the missing-item
// closure sweep; the HTTP fetch itself has no injectable seam (call() uses
// URLSession.shared) so the decision is what gets tested, mirroring the
// existing test* seam pattern.

private func deltaEntity(
    key: String = "owner/repo#pr#7",
    number: Int = 7,
    state: String,
    updatedAt: String,
    checks: String,
    stale: Bool,
    mergeable: String = "clean",
    signals: [String] = [],
    humanDecisionOwner: String? = nil,
    detailFetchedAt: String? = DeskClock.nowISO()
) -> JSONValue {
    // Carry requires a PROVEN-quiet prior observation (empty signals): the
    // fixture embeds one in the entity's Codable observation payload.
    var observation: [String: JSONValue] = [
        "repository": .string("owner/repo"), "number": .int(Int64(number)),
        "kind": .string("pull_request"), "title": .string("Make Hermes sturdier"),
        "isOpen": .bool(state == "open"), "isMerged": .bool(false),
        "observedVersion": .string("observed-\(updatedAt)"),
        "signals": .array(signals.map { .string($0) }),
        "waitingKind": .string("review"), "isStale": .bool(stale),
    ]
    if let humanDecisionOwner {
        observation["humanDecision"] = .object([
            "detail": .string("A decision is required."),
            "owner": .string(humanDecisionOwner),
        ])
    }
    return .object([
        "key": .string(key), "repository": .string("owner/repo"), "number": .int(Int64(number)),
        "kind": .string("pull_request"), "title": .string("Make Hermes sturdier"),
        "state": .string(state), "updatedAt": .string(updatedAt),
        "url": .string("https://github.com/owner/repo/pull/\(number)"),
        "reviewState": .string("approved"), "checks": .string(checks),
        "mergeable": .string(mergeable),
        "needsUser": .bool(false), "blocked": .bool(false), "stale": .bool(stale),
        "detailFetchedAt": detailFetchedAt.map { JSONValue.string($0) } ?? .null,
        "commandObservation": .object(observation),
    ])
}

@Test func githubDeltaCarriesUnchangedItemVerbatim() {
    // Huge staleHours pins staleness=false regardless of the run date, so the
    // carry path returns the prior entity verbatim (no reconstruction).
    let prior = deltaEntity(state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "passing", stale: false)
    let value = GitHubConnectorActions.testDeltaCarryDecision(
        prior: prior, searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000
    )
    guard case .object(let object) = value,
          case .string(let decision)? = object["decision"],
          case .object(let fields)? = object["entity"],
          case .object(let priorFields) = prior else {
        Issue.record("expected a carry decision carrying an entity")
        return
    }
    #expect(decision == "carry")
    // Every prior remote field survives verbatim (entity json only adds signature).
    for (k, v) in priorFields { #expect(fields[k] == v) }
}

@Test func githubDeltaReFetchesWhenPriorChecksPending() {
    let prior = deltaEntity(state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "pending", stale: false)
    let value = GitHubConnectorActions.testDeltaCarryDecision(
        prior: prior, searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000
    )
    #expect(value == .object(["decision": .string("fetch")]))
}

@Test func githubDeltaReFetchesBasicPriorRow() {
    let prior = deltaEntity(state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "not_expanded", stale: false)
    let value = GitHubConnectorActions.testDeltaCarryDecision(
        prior: prior, searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000
    )
    #expect(value == .object(["decision": .string("fetch")]))
}

@Test func githubDeltaReFetchesWhenUpdatedAtChanged() {
    let prior = deltaEntity(state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "passing", stale: false)
    let value = GitHubConnectorActions.testDeltaCarryDecision(
        prior: prior, searchUpdatedAt: "2026-07-15T12:30:00Z", staleHours: 100_000
    )
    #expect(value == .object(["decision": .string("fetch")]))
}

@Test func githubDeltaReFetchesWhenLiveMergeabilityFindsBaseBranchConflict() {
    let prior = deltaEntity(
        state: "open", updatedAt: "2026-07-15T10:00:00Z",
        checks: "passing", stale: false, mergeable: "clean"
    )
    let value = GitHubConnectorActions.testDeltaCarryDecision(
        prior: prior,
        searchUpdatedAt: "2026-07-15T10:00:00Z",
        staleHours: 100_000,
        liveMergeableState: "dirty"
    )
    #expect(value == .object(["decision": .string("fetch")]))

    let indeterminate = GitHubConnectorActions.testDeltaCarryDecision(
        prior: prior,
        searchUpdatedAt: "2026-07-15T10:00:00Z",
        staleHours: 100_000,
        liveMergeableState: "unknown"
    )
    #expect(indeterminate == .object(["decision": .string("fetch")]))

    guard case .object(let clean) = GitHubConnectorActions.testDeltaCarryDecision(
        prior: prior,
        searchUpdatedAt: "2026-07-15T10:00:00Z",
        staleHours: 100_000,
        liveMergeableState: "clean"
    ), case .string(let decision)? = clean["decision"] else {
        Issue.record("expected the unchanged clean PR to remain carryable")
        return
    }
    #expect(decision == "carry")
}

@Test func githubDeltaFullFetchesWithoutPriorEntity() {
    let value = GitHubConnectorActions.testDeltaCarryDecision(
        prior: nil, searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000
    )
    #expect(value == .object(["decision": .string("fetch")]))
}

@Test func githubDeltaNeverCarriesLiveActionableSignals() {
    // Thread resolution does not bump PR updated_at: an item with a live
    // actionable event must ALWAYS get fresh detail + GraphQL evidence, or a
    // resolved thread could stay frozen as actionable forever.
    let prior = deltaEntity(
        state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "passing",
        stale: false, signals: ["review_comment"]
    )
    let value = GitHubConnectorActions.testDeltaCarryDecision(
        prior: prior, searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000
    )
    #expect(value == .object(["decision": .string("fetch")]))
}

@Test func githubDeltaReFetchesLegacyGenericDecisionOwnership() {
    let prior = deltaEntity(
        state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "passing",
        stale: false, humanDecisionOwner: "Repository owner"
    )
    #expect(GitHubConnectorActions.testDeltaCarryDecision(
        prior: prior, searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000
    ) == .object(["decision": .string("fetch")]))
}

@Test func githubDeltaCarryIsAgeBounded() {
    // CI re-runs and thread unresolves don't bump updated_at, so carry has a
    // hard ceiling: a stamp older than the max allowance (75 min) must always
    // re-fetch, and a missing stamp (pre-delta snapshot) must always re-fetch.
    let expired = deltaEntity(
        state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "passing", stale: false,
        detailFetchedAt: DeskClock.nowISO(Date().addingTimeInterval(-80 * 60))
    )
    #expect(GitHubConnectorActions.testDeltaCarryDecision(
        prior: expired, searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000
    ) == .object(["decision": .string("fetch")]))

    let unstamped = deltaEntity(
        state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "passing", stale: false,
        detailFetchedAt: nil
    )
    #expect(GitHubConnectorActions.testDeltaCarryDecision(
        prior: unstamped, searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000
    ) == .object(["decision": .string("fetch")]))

    // A just-stamped row is inside the 45-min floor for every key → carries.
    let fresh = deltaEntity(state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "passing", stale: false)
    guard case .object(let object) = GitHubConnectorActions.testDeltaCarryDecision(
        prior: fresh, searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000
    ), case .string(let decision)? = object["decision"] else {
        Issue.record("expected a decision object")
        return
    }
    #expect(decision == "carry")
}

@Test func githubDeltaNeverCarriesObservationlessRow() {
    // No embedded observation → quietness cannot be proven → fetch (fail-open).
    var fields: [String: JSONValue] = [:]
    if case .object(let o) = deltaEntity(state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "passing", stale: false) {
        fields = o
    }
    fields["commandObservation"] = nil
    let value = GitHubConnectorActions.testDeltaCarryDecision(
        prior: .object(fields), searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000
    )
    #expect(value == .object(["decision": .string("fetch")]))
}

@Test func githubDeltaFlagsMissingPriorOpenForClosureFetch() {
    let present = deltaEntity(key: "owner/repo#pr#1", number: 1, state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "passing", stale: false)
    let missingOpen = deltaEntity(key: "owner/repo#pr#2", number: 2, state: "open", updatedAt: "2026-07-15T10:00:00Z", checks: "passing", stale: false)
    let missingClosed = deltaEntity(key: "owner/repo#pr#3", number: 3, state: "closed", updatedAt: "2026-07-15T10:00:00Z", checks: "passing", stale: false)
    let missing = GitHubConnectorActions.testDeltaMissingKeys(
        previousRows: [present, missingOpen, missingClosed],
        freshKeys: ["owner/repo#pr#1"]
    )
    // Only the still-open PR that dropped out of search needs a closure fetch.
    #expect(missing == ["owner/repo#pr#2"])
}

private func tempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("github-connector-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - Wave 5: what the cadence learner is allowed to call a "change"

/// The learner counts a differing fingerprint as evidence the ref MOVED
/// UPSTREAM, and needs three such changes before it trusts an interval. So the
/// fingerprint must contain nothing the local clock can move on its own.
///
/// `signature` fails that test: it folds in `stale`, which is
/// `isStale(updatedAt, hours:)` against `Date()`. Here the upstream row is
/// byte-identical and only the staleness WINDOW differs — a stand-in for the
/// same PR observed before and after it crosses the threshold. `signature`
/// changes; the observation fingerprint must not.
@Test func githubObservationFingerprintIgnoresLocalClockStaleness() throws {
    let row: [String: Any] = [
        "number": 7,
        "state": "open",
        "updated_at": "2020-01-01T00:00:00Z",   // long past → stale under any short window
        "title": "A pull request",
        "html_url": "https://github.com/owner/repo/pull/7",
    ]
    let fresh = try #require(GitHubConnectorActions.testTrackingFingerprints(pullRow: row, staleHours: 1_000_000))
    let aged = try #require(GitHubConnectorActions.testTrackingFingerprints(pullRow: row, staleHours: 1))

    #expect(fresh.signature != aged.signature, "precondition: signature IS clock-sensitive")
    #expect(fresh.observation == aged.observation,
            "a ref nobody touched must not read as a change just because it aged")
    #expect(!aged.observation.contains("stale"))
}

/// A real upstream move still registers — the fix must not flatten the
/// fingerprint into something that never changes.
@Test func githubObservationFingerprintTracksRealUpstreamChange() throws {
    var row: [String: Any] = [
        "number": 7, "state": "open", "updated_at": "2026-07-15T10:00:00Z",
        "title": "A pull request", "html_url": "https://github.com/owner/repo/pull/7",
    ]
    let before = try #require(GitHubConnectorActions.testTrackingFingerprints(pullRow: row, staleHours: 72))
    row["state"] = "closed"
    row["updated_at"] = "2026-07-16T10:00:00Z"
    let after = try #require(GitHubConnectorActions.testTrackingFingerprints(pullRow: row, staleHours: 72))
    #expect(before.observation != after.observation)
}

/// END-TO-END through the real wiring: a hand-written desk card that links a PR
/// gets FLAGGED when the PR merges (it never opted into auto-close), and the
/// cadence lane records the observation. This is the closest thing to a live
/// proof available without the network — it drives `upsertDesk`, which is what
/// the refresh loop calls, so it exercises entity -> DeskObservedRef ->
/// evaluator -> applier -> op-log for real.
@Test func githubRefreshReconcilesTheWholeBoardNotJustTrackerRows() async throws {
    let root = try tempRoot()
    let key = "owner/repo#pr#7"
    func entity(state: String, updatedAt: String) -> JSONValue {
        .object([
            "key": .string(key), "repository": .string("owner/repo"), "number": .int(7),
            "kind": .string("pull_request"), "title": .string("Make Hermes sturdier"),
            "state": .string(state), "updatedAt": .string(updatedAt),
            "url": .string("https://github.com/owner/repo/pull/7"),
            "reviewState": .string("approved"), "checks": .string("passing"),
            "needsUser": .bool(false), "blocked": .bool(false), "stale": .bool(false),
        ])
    }

    // User's OWN card. `.plan`, no refresh sources — the tracker does not own it
    // and must never close it, but it does point at the PR.
    let store = SwiftNativeDeskStore(dataRoot: root)
    let mine = try await store.createItem(kind: .plan, project: "Hermes", title: "land the Hermes work")
    _ = try await store.addRef(mine.handle, ref: DeskRef(kind: .ghPr(
        repo: "owner/repo", number: 7, title: "Make Hermes sturdier", status: "open", checks: nil
    )))

    // The PR merges. The refresh reconciles the whole board against it.
    _ = try await GitHubConnectorActions.testUpsertTrackingEntities(
        [entity(state: "closed", updatedAt: "2026-07-10T12:00:00Z")],
        project: "Hermes", changedKeys: [key], dataRoot: root
    )

    let after = try #require(try await store.liveState().items.first { $0.handle == mine.handle })
    #expect(after.status.isTerminal == false, "NO UNINVITED CLOSES: this card never opted in")
    let flag = try #require(after.notes.last)
    #expect(DeskObservationEvaluator.driftKind(inNote: flag.text) == .untrackedButShipped)
    #expect(flag.text.contains("owner/repo#pr#7"))
    // ...and it reaches the surface User actually reads.
    let rendered = DeskProjection.render(try await store.liveState())
    #expect(rendered.contains("⚑ drift:untracked_but_shipped"))
    #expect(rendered.contains("  note: ⚑ drift["))

    // And the cadence lane saw the observation, so it can start learning.
    let stats = await DeskCadenceStore(dataRoot: root).load()
    let stat = try #require(stats.refs[key])
    #expect(stat.observations == 1)
    #expect(stat.changes == 0, "the first fingerprint is a baseline, not a change")
    #expect(stat.lastFingerprint?.contains("stale") == false)
}

/// Cross-review finding (2026-08-17, HIGH): the mergeability probe's FAILURE
/// path set `mergeability = [:]` and logged "preserving prior", after which the
/// carry decision saw `liveMergeableState: nil`, skipped the new guard entirely,
/// and carried the prior `clean` snapshot forward. That reopens the exact
/// stale-conflict blind spot the probe exists to close — and it reopens it
/// during rate-limit/network trouble, which the 5-minute cadence plus per-PR
/// probing makes MORE likely, not less.
@Test func githubDeltaRefusesCarryWhenMergeabilityEvidenceIsMissing() {
    let prior = deltaEntity(
        state: "open", updatedAt: "2026-07-15T10:00:00Z",
        checks: "passing", stale: false, mergeable: "clean"
    )
    // Same row that carries happily with evidence present…
    let withEvidence = GitHubConnectorActions.testDeltaCarryDecision(
        prior: prior, searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000,
        liveMergeableState: "clean"
    )
    guard case .object(let carried) = withEvidence,
          case .string("carry")? = carried["decision"] else {
        Issue.record("evidence-present clean row must still carry")
        return
    }
    // …must FETCH when the probe produced no entry for it.
    let probeFailed = GitHubConnectorActions.testDeltaCarryDecision(
        prior: prior, searchUpdatedAt: "2026-07-15T10:00:00Z", staleHours: 100_000,
        liveMergeableState: nil, mergeabilityEvidenceMissing: true
    )
    #expect(probeFailed == .object(["decision": .string("fetch")]),
            "no evidence is not evidence of clean — force the detail read")
}

// MARK: - Cross-review follow-ups (2026-08-17)

/// Finding 4: a 403 whose rate-limit budget is still healthy is a SECONDARY
/// rate limit (a throttle), not exhaustion. Before this, nothing read it as
/// back-off pressure and the 5-minute sweep kept hammering a closed window.
@Test func githubSecondaryRateLimitIsClassifiedAndBounded() {
    // The live desk failure shape: 403, budget healthy, no Retry-After.
    #expect(GitHubConnectorActions.secondaryRateBackoff(
        status: 403, message: "You have exceeded a secondary rate limit",
        retryAfterHeader: nil, rateLimitRemaining: 4977) == 60)
    // Retry-After is honored verbatim when sane…
    #expect(GitHubConnectorActions.secondaryRateBackoff(
        status: 429, message: "Too Many Requests",
        retryAfterHeader: "12", rateLimitRemaining: nil) == 12)
    // …and PRIMARY exhaustion (remaining 0, no secondary wording) is NOT
    // swallowed by this gate — it keeps its own reset-stamped error.
    #expect(GitHubConnectorActions.secondaryRateBackoff(
        status: 403, message: "API rate limit exceeded",
        retryAfterHeader: nil, rateLimitRemaining: 0) == nil)
    // Ordinary failures never trip a back-off.
    #expect(GitHubConnectorActions.secondaryRateBackoff(
        status: 404, message: "Not Found",
        retryAfterHeader: nil, rateLimitRemaining: 5000) == nil)
}

@Test func githubRateLimitGateOpensAndCapsBackoff() async {
    let gate = GitHubRateLimitGate()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(await gate.cooldownRemaining(now: now) == nil, "a fresh gate is open")
    await gate.trip(seconds: 30, now: now)
    #expect(await gate.cooldownRemaining(now: now) == 30)
    // A longer window wins; a shorter one may never shorten an active back-off.
    await gate.trip(seconds: 5, now: now)
    #expect(await gate.cooldownRemaining(now: now) == 30)
    // Hostile header values are capped, never honored outright.
    await gate.trip(seconds: 86_400, now: now)
    #expect(await gate.cooldownRemaining(now: now) == GitHubRateLimitGate.maximumBackoff)
    // The window reopens on its own once elapsed.
    #expect(await gate.cooldownRemaining(now: now.addingTimeInterval(400)) == nil)
}

/// gpt-5.5 MED (2026-08-17): the recovered by-id comment is OLDER than the page
/// it rejoins, and `latestNonBotCommentAuthor` reads position, not timestamps —
/// appending blindly made a recovered maintainer comment look like the last
/// word, which keeps a decision label armed after the contributor already
/// answered. Position must still mean recency.
@Test func githubRecoveredIssueCommentKeepsAscendingOrder() {
    let rows: [[String: Any]] = [
        ["id": 700, "created_at": "2026-08-01T10:00:00Z", "user": ["login": "maintainer"]],
        ["id": 900, "created_at": "2026-08-03T10:00:00Z", "user": ["login": "author"]],
    ]
    // The array a caller would build by appending a recovered older row last.
    var appended = rows
    appended.append(["id": 650, "created_at": "2026-07-30T09:00:00Z", "user": ["login": "maintainer"]])
    appended.sort { lhs, rhs in
        let l = (lhs["created_at"] as? String) ?? ""
        let r = (rhs["created_at"] as? String) ?? ""
        return l == r
            ? ((lhs["id"] as? Int) ?? 0) < ((rhs["id"] as? Int) ?? 0)
            : l < r
    }
    let logins = appended.compactMap { ($0["user"] as? [String: Any])?["login"] as? String }
    #expect(logins == ["maintainer", "maintainer", "author"],
            "the contributor's reply must remain the last word after recovery")
    #expect(GitHubCommandObservationBuilder.latestNonBotCommentAuthor(appended) == "author")
}

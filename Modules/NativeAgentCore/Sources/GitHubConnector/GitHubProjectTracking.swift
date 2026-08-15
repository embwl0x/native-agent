import Foundation
import NativeAgentCore
import PersistenceCore

// First-class GitHub project reads, safe write execution, and durable Desk
// tracking. Tool/TrustCenter callers own approval before `mutate` can execute;
// this module never invents a side channel around that policy boundary.

public extension GitHubConnectorActions {
    static func search(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let query = try required(input, "query")
        let page = clamp(int(input["page"], default: 1), min: 1, max: 1_000)
        let perPage = clamp(int(input["limit"] ?? input["per_page"], default: 20), min: 1, max: GitHubToolProjection.collectionLimit)
        var params = ["q": query, "page": String(page), "per_page": String(perPage)]
        if let sort = normalized(input["sort"]) { params["sort"] = sort }
        if let order = normalized(input["order"] ?? input["direction"]) { params["order"] = order }
        let result = try await call(path: "search/issues", params: params, dataRoot: dataRoot)
        let projection = GitHubToolProjection.searchResult(result, limit: perPage)
        return envelope("github.search", fields: [
            "query": .string(query), "page": .int(Int64(page)), "perPage": .int(Int64(perPage)),
            "result": JSONValue(fromFoundation: projection),
        ])
    }

    static func listPullRequests(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let repo = try repository(input)
        let page = clamp(int(input["page"], default: 1), min: 1, max: 1_000)
        let perPage = clamp(int(input["limit"] ?? input["per_page"], default: 20), min: 1, max: GitHubToolProjection.collectionLimit)
        var params = [
            "state": normalized(input["state"]) ?? "open",
            "sort": normalized(input["sort"]) ?? "updated",
            "direction": normalized(input["direction"]) ?? "desc",
            "page": String(page), "per_page": String(perPage),
        ]
        for key in ["head", "base"] where normalized(input[key]) != nil { params[key] = normalized(input[key]) }
        let result = try await call(path: "repos/\(repo)/pulls", params: params, dataRoot: dataRoot)
        let projection = GitHubToolProjection.pullRequests(result, limit: perPage)
        return envelope("github.list_pull_requests", fields: [
            "repository": .string(repo), "count": .int(Int64(projection.rows.count)),
            "sourcePageCount": .int(Int64(projection.sourceCount)),
            "resultsTruncated": .bool(projection.truncated),
            "page": .int(Int64(page)), "perPage": .int(Int64(perPage)),
            "pullRequests": JSONValue(fromFoundation: projection.rows),
        ])
    }

    static func getIssue(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let repo = try repository(input)
        let number = try positiveNumber(input)
        let issue = try await call(path: "repos/\(repo)/issues/\(number)", dataRoot: dataRoot)
        return envelope("github.get_issue", fields: [
            "repository": .string(repo), "number": .int(Int64(number)),
            "issue": JSONValue(fromFoundation: GitHubToolProjection.issue(issue as? [String: Any] ?? [:])),
        ])
    }

    static func getPullRequest(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let repo = try repository(input)
        let number = try positiveNumber(input)
        guard let pull = try await call(path: "repos/\(repo)/pulls/\(number)", dataRoot: dataRoot) as? [String: Any] else {
            throw GitHubConnectorError.invalidResponse("pull request was not an object")
        }
        let limit = clamp(int(input["limit"], default: 20), min: 1, max: GitHubToolProjection.collectionLimit)
        let reviews = try await call(path: "repos/\(repo)/pulls/\(number)/reviews", params: ["per_page": String(limit)], dataRoot: dataRoot)
        let commits = try await call(path: "repos/\(repo)/pulls/\(number)/commits", params: ["per_page": String(limit)], dataRoot: dataRoot)
        var fields: [String: JSONValue] = [
            "repository": .string(repo), "number": .int(Int64(number)),
            "pullRequest": JSONValue(fromFoundation: GitHubToolProjection.pullRequest(pull)),
            "reviews": JSONValue(fromFoundation: GitHubToolProjection.reviews(reviews, limit: limit).rows),
            "commits": JSONValue(fromFoundation: GitHubToolProjection.commits(commits, limit: limit).rows),
            "reviewState": .string(derivedReviewState(reviews)),
        ]
        if let head = pull["head"] as? [String: Any], let sha = head["sha"] as? String, !sha.isEmpty {
            let checkRuns = try await call(path: "repos/\(repo)/commits/\(sha)/check-runs", params: ["per_page": String(limit)], dataRoot: dataRoot)
            let combinedStatus = try await call(path: "repos/\(repo)/commits/\(sha)/status", dataRoot: dataRoot)
            fields["headSHA"] = .string(sha)
            fields["checks"] = boundedChecks(checkRuns, combinedStatus: combinedStatus)
        }
        return envelope("github.get_pull_request", fields: fields)
    }

    static func pullRequestFiles(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let repo = try repository(input)
        let number = try positiveNumber(input)
        let page = clamp(int(input["page"], default: 1), min: 1, max: 1_000)
        let perPage = clamp(int(input["limit"] ?? input["per_page"], default: 50), min: 1, max: 100)
        let maxPatchCharacters = clamp(int(input["max_patch_characters"], default: 80_000), min: 0, max: 250_000)
        let raw = try await call(
            path: "repos/\(repo)/pulls/\(number)/files",
            params: ["page": String(page), "per_page": String(perPage)],
            dataRoot: dataRoot
        )
        let bounded = boundFilePatches(raw, maxCharacters: maxPatchCharacters)
        return envelope("github.pull_request_files", fields: [
            "repository": .string(repo), "number": .int(Int64(number)),
            "page": .int(Int64(page)), "perPage": .int(Int64(perPage)),
            "maxPatchCharacters": .int(Int64(maxPatchCharacters)),
            "files": JSONValue(fromFoundation: bounded.files),
            "patchCharactersReturned": .int(Int64(bounded.characters)),
            "patchesTruncated": .bool(bounded.truncated),
        ])
    }

    static func pullRequestActivity(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let repo = try repository(input)
        let number = try positiveNumber(input)
        let page = clamp(int(input["page"], default: 1), min: 1, max: 1_000)
        let limit = clamp(int(input["limit"] ?? input["per_page"], default: 20), min: 1, max: GitHubToolProjection.activityLimit)
        let params = ["page": String(page), "per_page": String(limit)]
        let comments = try await call(path: "repos/\(repo)/issues/\(number)/comments", params: params, dataRoot: dataRoot)
        let reviewComments = try await call(path: "repos/\(repo)/pulls/\(number)/comments", params: params, dataRoot: dataRoot)
        let reviews = try await call(path: "repos/\(repo)/pulls/\(number)/reviews", params: params, dataRoot: dataRoot)
        let timeline = try await call(path: "repos/\(repo)/issues/\(number)/timeline", params: params, dataRoot: dataRoot)
        return envelope("github.pull_request_activity", fields: [
            "repository": .string(repo), "number": .int(Int64(number)),
            "page": .int(Int64(page)), "perPage": .int(Int64(limit)),
            "issueComments": JSONValue(fromFoundation: GitHubToolProjection.comments(comments, limit: limit).rows),
            "reviewComments": JSONValue(fromFoundation: GitHubToolProjection.comments(reviewComments, limit: limit).rows),
            "reviews": JSONValue(fromFoundation: GitHubToolProjection.reviews(reviews, limit: limit).rows),
            "timeline": JSONValue(fromFoundation: GitHubToolProjection.timeline(timeline, limit: limit).rows),
        ])
    }

    /// Executes only after the caller's normal TrustCenter/autonomy approval
    /// gate allows `github_mutate`. Direct bridge calls have no approval filer
    /// and therefore fail closed before reaching here.
    static func mutate(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let operation = try required(input, "operation").lowercased()
        let repo = try repository(input)
        let number = int(input["number"], default: 0)
        let request: (path: String, method: String, body: [String: Any])
        switch operation {
        case "create_issue":
            request = ("repos/\(repo)/issues", "POST", try issueBody(input, requireTitle: true))
        case "update_issue", "close_issue", "reopen_issue":
            try requirePositive(number)
            var body = try issueBody(input, requireTitle: false)
            if operation == "close_issue" { body["state"] = "closed" }
            if operation == "reopen_issue" { body["state"] = "open" }
            request = ("repos/\(repo)/issues/\(number)", "PATCH", body)
        case "comment_issue", "comment_pull_request":
            try requirePositive(number)
            request = ("repos/\(repo)/issues/\(number)/comments", "POST", ["body": try required(input, "body")])
        case "create_pull_request":
            request = ("repos/\(repo)/pulls", "POST", try pullRequestBody(input, creating: true))
        case "update_pull_request", "close_pull_request", "reopen_pull_request":
            try requirePositive(number)
            var body = try pullRequestBody(input, creating: false)
            if operation == "close_pull_request" { body["state"] = "closed" }
            if operation == "reopen_pull_request" { body["state"] = "open" }
            request = ("repos/\(repo)/pulls/\(number)", "PATCH", body)
        case "review_pull_request":
            try requirePositive(number)
            var body: [String: Any] = ["event": (normalized(input["event"]) ?? "COMMENT").uppercased()]
            if let value = normalized(input["body"]) { body["body"] = value }
            request = ("repos/\(repo)/pulls/\(number)/reviews", "POST", body)
        case "request_reviewers":
            try requirePositive(number)
            let reviewers = stringArray(input["reviewers"])
            let teams = stringArray(input["team_reviewers"])
            guard !reviewers.isEmpty || !teams.isEmpty else {
                throw GitHubConnectorError.invalidInput("Requesting reviewers requires reviewers or team_reviewers.")
            }
            request = ("repos/\(repo)/pulls/\(number)/requested_reviewers", "POST", ["reviewers": reviewers, "team_reviewers": teams])
        case "merge_pull_request":
            try requirePositive(number)
            var body: [String: Any] = [:]
            for key in ["commit_title", "commit_message", "sha", "merge_method"] {
                if let value = normalized(input[key]) { body[key] = value }
            }
            request = ("repos/\(repo)/pulls/\(number)/merge", "PUT", body)
        default:
            throw GitHubConnectorError.invalidInput("Unsupported GitHub mutation operation '\(operation)'.")
        }
        if request.body.isEmpty && !["close_issue", "reopen_issue", "close_pull_request", "reopen_pull_request", "merge_pull_request"].contains(operation) {
            throw GitHubConnectorError.invalidInput("GitHub mutation '\(operation)' has no fields to update.")
        }
        let result = try await call(path: request.path, method: request.method, body: request.body, dataRoot: dataRoot)
        return envelope("github.mutate", fields: [
            "operation": .string(operation), "repository": .string(repo),
            "number": number > 0 ? .int(Int64(number)) : .null,
            "result": JSONValue(fromFoundation: result),
        ])
    }

    static func discoverTracking(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let explicit = stringArray(input["repositories"] ?? input["repos"])
        let suppliedQuery = normalized(input["query"])
        guard !explicit.isEmpty || suppliedQuery != nil else {
            throw GitHubConnectorError.invalidInput("GitHub tracking discovery requires query or repositories.")
        }
        let mode = try TrackingMode(input: normalized(input["mode"] ?? input["tracking_mode"]) ?? "contributions")
        let authenticatedLogin = try await authenticatedLogin(dataRoot: dataRoot)
        let contributorLogin: String?
        if mode == .contributions {
            let requested = normalized(input["contributor_login"] ?? input["contributor"] ?? input["login"])
                ?? authenticatedLogin
            guard requested.caseInsensitiveCompare(authenticatedLogin) == .orderedSame else {
                throw GitHubConnectorError.invalidInput(
                    "Contribution tracking login '\(requested)' does not match the authenticated GitHub account '\(authenticatedLogin)'."
                )
            }
            contributorLogin = authenticatedLogin
        } else {
            contributorLogin = nil
        }
        // An explicit repository selection is authoritative. Do not retain a
        // discovery query that could later widen or reconstitute an older set.
        let discoveryQuery = explicit.isEmpty ? suppliedQuery : nil
        var matches: [[String: Any]] = []
        if !explicit.isEmpty {
            for name in explicit {
                let fullName = try canonicalRepository(name)
                guard let repo = try await call(path: "repos/\(fullName)", dataRoot: dataRoot) as? [String: Any] else { continue }
                matches.append(repo)
            }
        } else if let query = suppliedQuery {
            let terms = query.lowercased().split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
            let maxPages = clamp(int(input["max_pages"], default: 5), min: 1, max: 10)
            for page in 1...maxPages {
                guard let repos = try await call(
                    path: "user/repos",
                    params: ["per_page": "100", "page": String(page), "sort": "updated", "affiliation": "owner,collaborator,organization_member"],
                    dataRoot: dataRoot
                ) as? [[String: Any]], !repos.isEmpty else { break }
                matches.append(contentsOf: repos.filter { repo in
                    let haystack = [repo["full_name"], repo["name"], repo["description"]]
                        .compactMap { $0 as? String }.joined(separator: " ").lowercased()
                    return terms.allSatisfy { haystack.contains($0) }
                })
                if repos.count < 100 { break }
            }
        }
        let resolved = matches.compactMap(trackedRepository(from:))
            .reduce(into: [String: TrackedRepository]()) { $0[$1.fullName.lowercased()] = $1 }
            .values.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        guard !resolved.isEmpty else {
            throw GitHubConnectorError.invalidInput("No accessible GitHub repositories matched the tracking selection.")
        }
        let persist = bool(input["persist"]) ?? true
        let project = normalized(input["project"]) ?? suppliedQuery ?? resolved.first!.name
        let interval = clamp(int(input["refresh_interval_minutes"], default: 15), min: 5, max: 1_440)
        let priorRepositoryCount = (try? GitHubProjectTracker.loadConfig(dataRoot: dataRoot).repositories.count) ?? 0
        if persist {
            try await GitHubProjectTracker.saveConfig(
                TrackingConfig(
                    version: 2,
                    project: project,
                    mode: mode,
                    contributorLogin: contributorLogin,
                    discoveryQuery: discoveryQuery,
                    repositories: resolved,
                    refreshIntervalMinutes: interval,
                    staleAfterHours: clamp(int(input["stale_after_hours"], default: 72), min: 1, max: 2_160),
                    updatedAt: DeskClock.nowISO()
                ),
                dataRoot: dataRoot
            )
        }
        var fields: [String: JSONValue] = [
            "persisted": .bool(persist), "project": .string(project),
            "mode": .string(mode.rawValue),
            "count": .int(Int64(resolved.count)),
            "replacedRepositoryCount": .int(Int64(persist ? priorRepositoryCount : 0)),
            "repositories": .array(resolved.map(\.json)),
        ]
        if let contributorLogin { fields["contributorLogin"] = .string(contributorLogin) }
        return envelope("github.discover_tracking", fields: fields)
    }

    static func projectDigest(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let refresh = bool(input["refresh"]) ?? true
        let snapshot = refresh
            ? try await GitHubProjectTracker.refresh(dataRoot: dataRoot, force: true)
            : try await GitHubProjectTracker.loadSnapshot(dataRoot: dataRoot)
        return snapshot.digestEnvelope
    }

    static func refreshTrackingIfDue(dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> Bool {
        try await GitHubProjectTracker.refreshIfDue(dataRoot: dataRoot)
    }
}

extension GitHubConnectorActions {
    // Internal pure seams used by focused connector tests; production callers
    // use the bounded action envelopes above.
    static func testBoundFilePatches(_ raw: Any, maxCharacters: Int) -> JSONValue {
        let value = boundFilePatches(raw, maxCharacters: maxCharacters)
        return .object([
            "files": JSONValue(fromFoundation: value.files),
            "characters": .int(Int64(value.characters)),
            "truncated": .bool(value.truncated),
        ])
    }

    static func testDerivedReviewState(_ raw: Any) -> String { derivedReviewState(raw) }

    static func testCheckSummary(_ runs: Any, combinedStatus: Any) -> String {
        checkSummary(runs, combinedStatus: combinedStatus)
    }

    static func testDetailedTrackingEntity(
        pull: [String: Any],
        reviews: Any,
        reviewComments: Any,
        reviewThreads: [GitHubCommandReviewThreadEvidence]
    ) -> JSONValue {
        GitHubProjectTracker.makeDetailedPREntity(
            repo: "owner/repo",
            number: pull["number"] as? Int ?? 7,
            staleHours: 72,
            actor: "contributor",
            pull: pull,
            reviews: reviews,
            reviewComments: reviewComments,
            reviewThreads: reviewThreads,
            checkRuns: ["check_runs": []],
            combinedStatus: ["statuses": []],
            checks: "none"
        ).json
    }

    /// (signature, observationFingerprint) for one PR row at a given staleness
    /// window. The seam exists so a test can hold the UPSTREAM row fixed and vary
    /// only the local-clock-derived `stale` bit.
    static func testTrackingFingerprints(
        pullRow: [String: Any],
        staleHours: Int
    ) -> (signature: String, observation: String)? {
        guard let entity = basicPREntity(pullRow, repo: "owner/repo", staleHours: staleHours) else { return nil }
        return (entity.signature, entity.observationFingerprint)
    }

    static func testUpsertTrackingEntities(
        _ rows: [JSONValue],
        project: String,
        changedKeys: Set<String>,
        previousRows: [JSONValue] = [],
        dataRoot: URL
    ) async throws -> JSONValue {
        let entities = rows.compactMap(TrackingEntity.fromJSON)
        let previous = previousRows.compactMap(TrackingEntity.fromJSON)
        let config = TrackingConfig(
            version: 2,
            project: project,
            mode: .contributions,
            contributorLogin: "contributor",
            discoveryQuery: nil,
            repositories: [TrackedRepository(fullName: "owner/repo", name: "repo", htmlURL: "https://github.com/owner/repo", defaultBranch: "main")],
            refreshIntervalMinutes: 15,
            staleAfterHours: 72,
            updatedAt: DeskClock.nowISO()
        )
        let result = try await GitHubProjectTracker.upsertDesk(
            entities: entities,
            previousEntities: previous,
            previousProject: project,
            config: config,
            changed: changedKeys,
            dataRoot: dataRoot
        )
        return .object([
            "archived": .int(Int64(result.archived)),
            "created": .int(Int64(result.created)),
            "updated": .int(Int64(result.updated)),
        ])
    }

    /// W6/L4-03 test hook — drives the bounded, per-repo-isolated sweep with an
    /// injected clock so "a slow repo cannot eat the whole tick" is provable
    /// without a network or a wall-clock sleep.
    static func testRepositoryPass(
        _ repositories: [String],
        budgetSeconds: TimeInterval,
        startedAt: Date,
        clock: @escaping @Sendable () -> Date,
        body: (String) async throws -> Void
    ) async -> (completed: [String], failed: [String], skippedForBudget: [String]) {
        let outcome = await GitHubProjectTracker.runRepositoryPass(
            repositories,
            budget: GitHubProjectTracker.RefreshBudget(
                seconds: budgetSeconds,
                startedAt: startedAt,
                clock: clock
            ),
            name: { $0 },
            body: body
        )
        return (outcome.completed, outcome.failed.map(\.repo), outcome.skippedForBudget)
    }

    /// W6/L4-03 test hook — the data-loss guard that pairs with the pass: a
    /// degraded repo's prior rows must come back, or Desk archives live work.
    static func testCarryForwardRepositories(
        _ repositories: [String],
        previous: [JSONValue]
    ) -> [String] {
        let entities = previous.compactMap { TrackingEntity.fromJSON($0) }
        return GitHubProjectTracker.carryForwardEntities(for: repositories, from: entities).map(\.key)
    }

    static func testLinkedIssueNumbers(_ body: String, repository: String) -> [Int] {
        linkedIssueNumbers(in: body, repository: repository).sorted()
    }

    static func testLinkedIssueNumbersFromContributionRows(_ rows: [JSONValue], repository: String) -> [Int] {
        let bodies = rows.compactMap { row -> String? in
            guard case .object(let object) = row,
                  case .string(let body)? = object["body"] else { return nil }
            return body
        }
        return linkedIssueNumbers(in: bodies, repository: repository).sorted()
    }

    static func testContributionFilter(_ rows: [JSONValue], login: String) -> [JSONValue] {
        rows.filter { row in
            guard case .object(let object) = row,
                  case .object(let user)? = object["user"],
                  case .string(let author)? = user["login"],
                  object["pull_request"] != nil else { return false }
            return author.caseInsensitiveCompare(login) == .orderedSame
        }
    }

    static func testTrackingDigest(
        _ rows: [JSONValue],
        changedKeys: [String],
        newKeys: [String]
    ) -> JSONValue {
        TrackingSnapshot(
            project: "Test project",
            mode: .contributions,
            contributorLogin: "contributor",
            refreshedAt: "2026-07-10T18:00:00Z",
            entities: rows.compactMap(TrackingEntity.fromJSON),
            changedKeys: changedKeys,
            newKeys: newKeys,
            deskCreated: 0,
            deskUpdated: 0,
            deskArchived: 0
        ).digestEnvelope
    }

    static func testSaveTrackingConfig(
        repositories: [String],
        login: String,
        project: String,
        dataRoot: URL
    ) async throws -> JSONValue {
        let tracked = repositories.map {
            TrackedRepository(fullName: $0, name: String($0.split(separator: "/").last ?? "repo"), htmlURL: "https://github.com/\($0)", defaultBranch: "main")
        }
        try await GitHubProjectTracker.saveConfig(
            TrackingConfig(
                version: 2,
                project: project,
                mode: .contributions,
                contributorLogin: login,
                discoveryQuery: nil,
                repositories: tracked,
                refreshIntervalMinutes: 15,
                staleAfterHours: 72,
                updatedAt: DeskClock.nowISO()
            ),
            dataRoot: dataRoot
        )
        return try GitHubProjectTracker.loadConfig(dataRoot: dataRoot).json
    }

    static func testDeltaCarryDecision(
        prior: JSONValue?,
        searchUpdatedAt: String,
        staleHours: Int
    ) -> JSONValue {
        let priorEntity = prior.flatMap(TrackingEntity.fromJSON)
        if let carried = GitHubProjectTracker.carriedForwardEntity(
            prior: priorEntity,
            searchUpdatedAt: searchUpdatedAt,
            staleHours: staleHours
        ) {
            return .object(["decision": .string("carry"), "entity": carried.json])
        }
        return .object(["decision": .string("fetch")])
    }

    static func testDeltaMissingKeys(
        previousRows: [JSONValue],
        freshKeys: [String]
    ) -> [String] {
        GitHubProjectTracker.priorOpenKeysMissing(
            from: previousRows.compactMap(TrackingEntity.fromJSON),
            freshKeys: Set(freshKeys)
        ).map(\.key).sorted()
    }
}

private struct TrackedRepository: Sendable, Equatable {
    let fullName: String
    let name: String
    let htmlURL: String
    let defaultBranch: String?

    var json: JSONValue {
        var out: [String: JSONValue] = ["fullName": .string(fullName), "name": .string(name), "htmlURL": .string(htmlURL)]
        if let defaultBranch { out["defaultBranch"] = .string(defaultBranch) }
        return .object(out)
    }

    static func fromJSON(_ value: JSONValue) -> TrackedRepository? {
        guard case .object(let o) = value,
              case .string(let fullName)? = o["fullName"],
              case .string(let name)? = o["name"],
              case .string(let htmlURL)? = o["htmlURL"] else { return nil }
        let defaultBranch: String? = { if case .string(let s)? = o["defaultBranch"] { return s }; return nil }()
        return TrackedRepository(fullName: fullName, name: name, htmlURL: htmlURL, defaultBranch: defaultBranch)
    }
}

private enum TrackingMode: String, Sendable, Equatable {
    case repository
    case contributions

    init(input: String) throws {
        guard let mode = TrackingMode(rawValue: input.lowercased()) else {
            throw GitHubConnectorError.invalidInput("GitHub tracking mode must be 'contributions' or 'repository'.")
        }
        self = mode
    }
}

private struct TrackingConfig: Sendable, Equatable {
    let version: Int
    let project: String
    let mode: TrackingMode
    let contributorLogin: String?
    let discoveryQuery: String?
    let repositories: [TrackedRepository]
    let refreshIntervalMinutes: Int
    let staleAfterHours: Int
    let updatedAt: String

    var json: JSONValue {
        var out: [String: JSONValue] = [
            "version": .int(Int64(version)), "project": .string(project),
            "mode": .string(mode.rawValue),
            "repositories": .array(repositories.map(\.json)),
            "refreshIntervalMinutes": .int(Int64(refreshIntervalMinutes)),
            "staleAfterHours": .int(Int64(staleAfterHours)), "updatedAt": .string(updatedAt),
        ]
        if let contributorLogin { out["contributorLogin"] = .string(contributorLogin) }
        if let discoveryQuery { out["discoveryQuery"] = .string(discoveryQuery) }
        return .object(out)
    }

    static func fromJSON(_ value: JSONValue) -> TrackingConfig? {
        guard case .object(let o) = value,
              case .string(let project)? = o["project"],
              case .string(let rawMode)? = o["mode"],
              let mode = TrackingMode(rawValue: rawMode),
              case .array(let rawRepos)? = o["repositories"] else { return nil }
        let intValue: (String, Int) -> Int = { key, fallback in
            if case .int(let value)? = o[key] { return Int(value) }
            return fallback
        }
        let query: String? = { if case .string(let s)? = o["discoveryQuery"] { return s }; return nil }()
        let contributor: String? = { if case .string(let s)? = o["contributorLogin"] { return s }; return nil }()
        let updated: String = { if case .string(let s)? = o["updatedAt"] { return s }; return "" }()
        let repos = rawRepos.compactMap(TrackedRepository.fromJSON)
        guard !repos.isEmpty else { return nil }
        if mode == .contributions, contributor?.isEmpty != false { return nil }
        return TrackingConfig(
            version: intValue("version", 2),
            project: project,
            mode: mode,
            contributorLogin: contributor,
            discoveryQuery: query,
            repositories: repos,
            refreshIntervalMinutes: intValue("refreshIntervalMinutes", 15),
            staleAfterHours: intValue("staleAfterHours", 72),
            updatedAt: updated
        )
    }
}

private struct TrackingEntity: Sendable, Equatable {
    let key: String
    let repo: String
    let number: Int
    let kind: String
    let title: String
    let state: String
    let updatedAt: String
    let url: String
    let author: String?
    let reviewState: String?
    let checks: String?
    let mergeable: String?
    let needsUser: Bool
    let blocked: Bool
    let stale: Bool
    let commandObservation: GitHubCommandObservation?
    // When this entity's detail calls last actually ran (ISO). Local
    // bookkeeping for the delta-refresh carry bound — deliberately excluded
    // from `signature` (it is not remote state) and optional so pre-delta
    // snapshots decode as nil, which fails open into a full detail fetch.
    var detailFetchedAt: String? = nil

    var signature: String {
        // "needs_user" is an internal fingerprint token (never persisted —
        // signature recomputes from fields on both sides of every compare),
        // renamed from a personal name for public-identity neutrality
        // (release-polish item 9, last residue).
        [state, updatedAt, reviewState ?? "", checks ?? "", mergeable ?? "", needsUser ? "needs_user" : "", blocked ? "blocked" : "", stale ? "stale" : ""].joined(separator: "|")
    }

    /// Fingerprint for the CADENCE LEARNER, which counts "this differs from last
    /// time" as evidence that the ref moved upstream.
    ///
    /// NOT `signature`. `signature` folds in `stale`, and `stale` is
    /// `isStale(updatedAt, hours:)` — a comparison against the LOCAL CLOCK. A PR
    /// nobody has touched flips it false→true the moment it crosses the staleness
    /// window, so `signature` would report a change on a ref where upstream did
    /// nothing at all: a fabricated sample in the EWMA, and a third of the
    /// evidence the learner needs before it trusts an interval. Everything below
    /// is a value GitHub reported. `needsUser`/`blocked` are dropped for the same
    /// reason they'd be redundant — they derive from `reviewState`/`checks`,
    /// which are already here.
    var observationFingerprint: String {
        [state, updatedAt, reviewState ?? "", checks ?? "", mergeable ?? ""].joined(separator: "|")
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "key": .string(key), "repository": .string(repo), "number": .int(Int64(number)),
            "kind": .string(kind), "title": .string(title), "state": .string(state),
            "updatedAt": .string(updatedAt), "url": .string(url),
            "needsUser": .bool(needsUser), "blocked": .bool(blocked), "stale": .bool(stale),
            "signature": .string(signature),
        ]
        if let author { o["author"] = .string(author) }
        if let reviewState { o["reviewState"] = .string(reviewState) }
        if let checks { o["checks"] = .string(checks) }
        if let mergeable { o["mergeable"] = .string(mergeable) }
        if let detailFetchedAt { o["detailFetchedAt"] = .string(detailFetchedAt) }
        if let commandObservation,
           let data = try? JSONEncoder().encode(commandObservation),
           let value = try? JSONValue.parse(data) {
            o["commandObservation"] = value
        }
        return .object(o)
    }

    static func fromJSON(_ value: JSONValue) -> TrackingEntity? {
        guard case .object(let o) = value,
              case .string(let key)? = o["key"], case .string(let repo)? = o["repository"],
              case .int(let number)? = o["number"], case .string(let kind)? = o["kind"],
              case .string(let title)? = o["title"], case .string(let state)? = o["state"],
              case .string(let updatedAt)? = o["updatedAt"], case .string(let url)? = o["url"] else { return nil }
        func str(_ key: String) -> String? { if case .string(let s)? = o[key] { return s }; return nil }
        func flag(_ key: String) -> Bool { if case .bool(let b)? = o[key] { return b }; return false }
        let commandObservation: GitHubCommandObservation? = {
            guard let raw = o["commandObservation"],
                  let data = try? raw.serializedData(pretty: false) else { return nil }
            return try? JSONDecoder().decode(GitHubCommandObservation.self, from: data)
        }()
        return TrackingEntity(key: key, repo: repo, number: Int(number), kind: kind, title: title, state: state, updatedAt: updatedAt, url: url, author: str("author"), reviewState: str("reviewState"), checks: str("checks"), mergeable: str("mergeable"), needsUser: flag("needsUser"), blocked: flag("blocked"), stale: flag("stale"), commandObservation: commandObservation, detailFetchedAt: str("detailFetchedAt"))
    }
}

private struct TrackingSnapshot: Sendable, Equatable {
    let project: String
    let mode: TrackingMode?
    let contributorLogin: String?
    let refreshedAt: String
    let entities: [TrackingEntity]
    let changedKeys: [String]
    let newKeys: [String]
    let deskCreated: Int
    let deskUpdated: Int
    let deskArchived: Int

    var json: JSONValue {
        var out: [String: JSONValue] = [
        "version": .int(2), "project": .string(project), "refreshedAt": .string(refreshedAt),
        "entities": .array(entities.map(\.json)), "changedKeys": .array(changedKeys.map(JSONValue.string)),
        "newKeys": .array(newKeys.map(JSONValue.string)), "deskCreated": .int(Int64(deskCreated)),
        "deskUpdated": .int(Int64(deskUpdated)), "deskArchived": .int(Int64(deskArchived)),
        ]
        if let mode { out["mode"] = .string(mode.rawValue) }
        if let contributorLogin { out["contributorLogin"] = .string(contributorLogin) }
        return .object(out)
    }

    var digestEnvelope: JSONValue {
        let changed = entities.filter { changedKeys.contains($0.key) }
        let newEntities = entities.filter { newKeys.contains($0.key) }
        let needsUser = entities.filter(\.needsUser)
        let blocked = entities.filter(\.blocked)
        let stale = entities.filter(\.stale)
        let sampleLimit = 10
        func sample(_ rows: [TrackingEntity]) -> JSONValue {
            .array(rows.prefix(sampleLimit).map(\.json))
        }
        let next: String
        if let first = needsUser.first { next = "Review \(first.repo)#\(first.number): \(first.title)" }
        else if let first = blocked.first { next = "Unblock \(first.repo)#\(first.number): \(first.title)" }
        else if let first = stale.first { next = "Triage stale \(first.kind) \(first.repo)#\(first.number): \(first.title)" }
        else { next = "No immediate GitHub action is required." }
        return GitHubConnectorActions.envelope("github.project_digest", fields: [
            "project": .string(project), "refreshedAt": .string(refreshedAt),
            "mode": mode.map { .string($0.rawValue) } ?? .string("legacy"),
            "contributorLogin": contributorLogin.map(JSONValue.string) ?? .null,
            "openCount": .int(Int64(entities.filter { $0.state == "open" }.count)),
            "openPullRequestCount": .int(Int64(entities.filter { $0.kind == "pull_request" && $0.state == "open" }.count)),
            "closedPullRequestHistoryCount": .int(Int64(entities.filter { $0.kind == "pull_request" && $0.state != "open" }.count)),
            "linkedIssueCount": .int(Int64(entities.filter { $0.kind == "issue" }.count)),
            "changed": sample(changed), "changedCount": .int(Int64(changed.count)),
            "new": sample(newEntities), "newCount": .int(Int64(newEntities.count)),
            "needsUser": sample(needsUser), "needsUserCount": .int(Int64(needsUser.count)),
            "blocked": sample(blocked), "blockedCount": .int(Int64(blocked.count)),
            "stale": sample(stale), "staleCount": .int(Int64(stale.count)),
            "samplesLimitedTo": .int(Int64(sampleLimit)),
            "resultsSampled": .bool([changed, newEntities, needsUser, blocked, stale].contains { $0.count > sampleLimit }),
            "recommendedNextAction": .string(next),
            "deskCreated": .int(Int64(deskCreated)), "deskUpdated": .int(Int64(deskUpdated)),
            "deskArchived": .int(Int64(deskArchived)),
            "notificationPolicy": .string("change-driven digest; no direct notification unless Desk policy is explicitly raised"),
        ])
    }

    static func fromJSON(_ value: JSONValue) -> TrackingSnapshot? {
        guard case .object(let o) = value, case .string(let project)? = o["project"],
              case .string(let refreshedAt)? = o["refreshedAt"], case .array(let rows)? = o["entities"] else { return nil }
        func strings(_ key: String) -> [String] { if case .array(let a)? = o[key] { return a.compactMap { if case .string(let s) = $0 { return s }; return nil } }; return [] }
        func int(_ key: String) -> Int { if case .int(let i)? = o[key] { return Int(i) }; return 0 }
        let mode: TrackingMode? = { if case .string(let s)? = o["mode"] { return TrackingMode(rawValue: s) }; return nil }()
        let contributor: String? = { if case .string(let s)? = o["contributorLogin"] { return s }; return nil }()
        return TrackingSnapshot(
            project: project,
            mode: mode,
            contributorLogin: contributor,
            refreshedAt: refreshedAt,
            entities: rows.compactMap(TrackingEntity.fromJSON),
            changedKeys: strings("changedKeys"),
            newKeys: strings("newKeys"),
            deskCreated: int("deskCreated"),
            deskUpdated: int("deskUpdated"),
            deskArchived: int("deskArchived")
        )
    }
}

private enum GitHubProjectTracker {
    static func configPath(_ root: URL) -> URL { root.appendingPathComponent("connectors/github/tracking.json") }
    static func snapshotPath(_ root: URL) -> URL { root.appendingPathComponent("connectors/github/tracking_snapshot.json") }

    static func saveConfig(_ config: TrackingConfig, dataRoot: URL) async throws {
        let persistence = SwiftNativePersistenceCore()
        let path = configPath(dataRoot)
        try await persistence.withFileLock(path) { try await persistence.writeJSON(config.json, to: path) }
    }

    static func loadConfig(dataRoot: URL) throws -> TrackingConfig {
        let path = configPath(dataRoot)
        guard let data = try? Data(contentsOf: path), let config = try? JSONValue.parse(data), let decoded = TrackingConfig.fromJSON(config) else {
            throw GitHubConnectorError.invalidInput("GitHub project tracking is not configured. Run github_discover_tracking with a query or repository list first.")
        }
        return decoded
    }

    static func loadSnapshot(dataRoot: URL) async throws -> TrackingSnapshot {
        guard let data = try? Data(contentsOf: snapshotPath(dataRoot)), let raw = try? JSONValue.parse(data), let snapshot = TrackingSnapshot.fromJSON(raw) else {
            throw GitHubConnectorError.invalidInput("No GitHub tracking snapshot exists yet. Refresh the project digest first.")
        }
        return snapshot
    }

    static func refreshIfDue(dataRoot: URL) async throws -> Bool {
        guard let config = try? loadConfig(dataRoot: dataRoot) else { return false }
        if let snapshot = try? await loadSnapshot(dataRoot: dataRoot),
           let refreshed = DeskClock.parseISO(snapshot.refreshedAt) {
            let due = await learnedDueInterval(
                dataRoot: dataRoot,
                entities: snapshot.entities,
                configuredSeconds: Double(config.refreshIntervalMinutes * 60),
                now: Date()
            )
            if Date().timeIntervalSince(refreshed) < due { return false }
        }
        _ = try await refresh(dataRoot: dataRoot, force: false)
        return true
    }

    /// How long this snapshot may sit before it is refetched, given what the
    /// cadence lane LEARNED about the refs in it. The policy (configured rate is
    /// a floor, learning may only stretch, partial knowledge stretches nothing)
    /// lives in `DeskCadenceLearner.batchIntervalSeconds` — it is a cadence rule,
    /// not a GitHub one, and it is tested there. This is the IO shim.
    ///
    /// Note `refresh(force:)` keeps its own gate on the raw configured interval.
    /// That gate is the rate-limit backstop for direct callers; this one only
    /// ever makes the opportunistic path fire LESS often, so the two never fight.
    static func learnedDueInterval(
        dataRoot: URL,
        entities: [TrackingEntity],
        configuredSeconds: Double,
        now: Date
    ) async -> Double {
        guard !entities.isEmpty else { return configuredSeconds }
        let stats = await DeskCadenceStore(dataRoot: dataRoot).load()
        return DeskCadenceLearner.batchIntervalSeconds(
            refKeys: entities.map(\.key),
            stats: stats,
            configuredSeconds: configuredSeconds,
            now: now
        )
    }

    /// W6/L4-03 — wall-clock budget for one refresh pass.
    ///
    /// The 2026-07 fix for the 120s tick timeout was to raise the timeout to
    /// 600s (`BackgroundLoopsAssembly+GitHubTracking.swift:49`). That moved the
    /// wall, it did not bound the pass: the loop is still ONE sequential sweep
    /// of every tracked repository, each repo costing a search page plus a
    /// per-open-PR detail fan-out (pull + reviews + review-comments + check-runs
    /// + status, each with a 30s per-request ceiling). Cost is
    /// `sum over repos`, unbounded above, so a single slow or 5xx-flapping
    /// repository still walks the whole tick into the timeout — and when the
    /// tick is cancelled mid-pass NOTHING is written, so every other
    /// repository's work is discarded too. Live receipts:
    /// `timeout after 600s` on 2026-07-30 and again 2026-08-11.
    ///
    /// This budget makes the pass end on its own terms and PERSIST what it got.
    /// Deliberately well under the 600s tick ceiling so the snapshot write,
    /// command-store observe and Desk upsert that follow the pass all still fit.
    static let defaultRefreshBudgetSeconds: TimeInterval = 300

    struct RefreshBudget: Sendable {
        let deadline: Date
        private let clock: @Sendable () -> Date

        init(
            seconds: TimeInterval = GitHubProjectTracker.defaultRefreshBudgetSeconds,
            startedAt: Date = Date(),
            clock: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.deadline = startedAt.addingTimeInterval(seconds)
            self.clock = clock
        }

        var isExhausted: Bool { clock() >= deadline }
    }

    /// Outcome of one bounded, per-repository-isolated pass. `failed` and
    /// `skippedForBudget` are what makes the degradation legible instead of
    /// silent — a partial refresh that logged nothing would read exactly like a
    /// clean one.
    struct RepositoryPassOutcome: Sendable, Equatable {
        var completed: [String] = []
        var failed: [(repo: String, error: String)] = []
        var skippedForBudget: [String] = []

        var isPartial: Bool { !failed.isEmpty || !skippedForBudget.isEmpty }
        /// Repos whose current-cycle work did not land, in either lane. Their
        /// prior entities must be carried forward or the snapshot would report
        /// them as vanished and Desk would archive live work.
        var degraded: [String] { failed.map(\.repo) + skippedForBudget }

        static func == (lhs: RepositoryPassOutcome, rhs: RepositoryPassOutcome) -> Bool {
            lhs.completed == rhs.completed
                && lhs.skippedForBudget == rhs.skippedForBudget
                && lhs.failed.map(\.repo) == rhs.failed.map(\.repo)
                && lhs.failed.map(\.error) == rhs.failed.map(\.error)
        }
    }

    /// Runs `body` once per repository, isolating BOTH failure modes that
    /// currently let one repository eat the whole tick:
    ///
    ///  * a throw (the live 404/502/504 receipts) aborts only that repository,
    ///    not the sweep — previously `try await` inside the `for repo in` loop
    ///    propagated straight out of `refresh()` and lost every repo's work;
    ///  * an exhausted wall-clock budget stops the sweep at a repository
    ///    boundary, so the remaining repos are recorded as skipped and the pass
    ///    returns normally instead of being killed mid-flight by the tick
    ///    timeout.
    static func runRepositoryPass<R>(
        _ repositories: [R],
        budget: RefreshBudget,
        name: (R) -> String,
        body: (R) async throws -> Void
    ) async -> RepositoryPassOutcome {
        var outcome = RepositoryPassOutcome()
        for repository in repositories {
            let label = name(repository)
            // Checked BEFORE the repo's work, never mid-repo: a repository is
            // the unit that carries forward cleanly.
            if budget.isExhausted {
                outcome.skippedForBudget.append(label)
                continue
            }
            do {
                try await body(repository)
                outcome.completed.append(label)
            } catch {
                outcome.failed.append((repo: label, error: error.localizedDescription))
            }
        }
        return outcome
    }

    /// Prior-snapshot entities belonging to a repository whose current-cycle
    /// work was skipped or failed. Carrying these forward is the difference
    /// between "we could not refresh this repo this tick" and "this repo's PRs
    /// no longer exist".
    static func carryForwardEntities(
        for repositories: [String],
        from previousEntities: [TrackingEntity]
    ) -> [TrackingEntity] {
        guard !repositories.isEmpty else { return [] }
        let wanted = Set(repositories.map { $0.lowercased() })
        return previousEntities.filter { wanted.contains($0.repo.lowercased()) }
    }

    static func refresh(dataRoot: URL, force: Bool) async throws -> TrackingSnapshot {
        let config = try loadConfig(dataRoot: dataRoot)
        if !force, let prior = try? await loadSnapshot(dataRoot: dataRoot),
           let refreshed = DeskClock.parseISO(prior.refreshedAt),
           Date().timeIntervalSince(refreshed) < Double(config.refreshIntervalMinutes * 60) { return prior }
        let previous = try? await loadSnapshot(dataRoot: dataRoot)
        var previousReviewThreads: [String: [GitHubCommandReviewThreadEvidence]] = Dictionary(
            uniqueKeysWithValues: (previous?.entities ?? []).compactMap { entity -> (String, [GitHubCommandReviewThreadEvidence])? in
                guard let threads = entity.commandObservation?.reviewThreads else { return nil }
                return (GitHubCommandObservation.itemId(repository: entity.repo, number: entity.number), threads)
            }
        )
        // Callback verification writes fresher thread evidence into the command
        // store between snapshot refreshes. Seeding generation reconciliation
        // from the snapshot alone would replay a stale generation after a
        // resolve→reopen race, so merge in the store's per-item evidence and
        // keep whichever entry is further along the thread lifecycle.
        let commandStore = GitHubCommandStore(dataRoot: dataRoot)
        for item in (try await commandStore.liveState()).items {
            guard let threads = item.observation?.reviewThreads else { continue }
            previousReviewThreads[item.itemId] = GitHubConnectorActions.mergeReviewThreadEvidence(
                previousReviewThreads[item.itemId], threads
            )
        }
        let actor = try await GitHubConnectorActions.authenticatedLogin(dataRoot: dataRoot)
        let budget = RefreshBudget()
        let built: (entities: [TrackingEntity], detailFetched: Int, carriedForward: Int, pass: RepositoryPassOutcome)
        switch config.mode {
        case .contributions:
            guard let contributor = config.contributorLogin,
                  contributor.caseInsensitiveCompare(actor) == .orderedSame else {
                throw GitHubConnectorError.invalidInput(
                    "GitHub contribution tracking is configured for a different account. Re-run github_discover_tracking with the authenticated contributor login."
                )
            }
            built = try await contributionEntities(
                config: config,
                contributor: contributor,
                previousEntities: previous?.entities ?? [],
                previousReviewThreads: previousReviewThreads,
                budget: budget,
                dataRoot: dataRoot
            )
        case .repository:
            built = try await repositoryEntities(
                config: config,
                actor: actor,
                previousEntities: previous?.entities ?? [],
                previousReviewThreads: previousReviewThreads,
                budget: budget,
                dataRoot: dataRoot
            )
        }
        // Refresh cost scales with churn, not tracked count: carried-forward items
        // skipped every per-item detail call this cycle. Recorded so wall-time
        // drops are attributable and no silent cap hides skipped work.
        NSLog(
            "[github-tracking] refresh %@: detail-fetched=%d carried-forward=%d entities=%d",
            config.project, built.detailFetched, built.carriedForward, built.entities.count
        )
        // W6/L4-03: a partial pass must never read as a clean one. Repos whose
        // work failed or was budget-skipped had their prior entities carried
        // forward inside the builders, so the snapshot below is complete —
        // this line is what makes the degradation attributable in the log.
        if built.pass.isPartial {
            NSLog(
                "[github-tracking] refresh %@ PARTIAL: completed=%d failed=%@ budget-skipped=%@",
                config.project,
                built.pass.completed.count,
                built.pass.failed.map { "\($0.repo)(\($0.error))" }.joined(separator: ", "),
                built.pass.skippedForBudget.joined(separator: ", ")
            )
        }
        var sortedEntities = built.entities
        sortedEntities.sort { $0.updatedAt > $1.updatedAt }
        let existingCommandIDs = Set((try await commandStore.liveState()).items.map(\.itemId))
        let previouslyOpen = Set((previous?.entities ?? []).filter { $0.state == "open" }.map {
            GitHubCommandObservation.itemId(repository: $0.repo, number: $0.number)
        })
        let observations = sortedEntities.compactMap { entity -> GitHubCommandObservation? in
            guard let observation = entity.commandObservation else { return nil }
            // Contribution snapshots retain bounded closed PR history. Historical
            // closures are not newly tracked work; only open items, existing
            // command items, or rows that just closed enter the operational feed.
            guard observation.isOpen
                    || existingCommandIDs.contains(observation.itemId)
                    || previouslyOpen.contains(observation.itemId) else { return nil }
            return observation
        }
        _ = try await commandStore.observe(observations)
        let old = Dictionary(uniqueKeysWithValues: (previous?.entities ?? []).map { ($0.key, $0.signature) })
        let changed = sortedEntities.filter { old[$0.key] != nil && old[$0.key] != $0.signature }.map(\.key)
        let fresh = sortedEntities.filter { old[$0.key] == nil && $0.state == "open" }.map(\.key)
        let desk = try await upsertDesk(
            entities: sortedEntities,
            previousEntities: previous?.entities ?? [],
            previousProject: previous?.project,
            config: config,
            changed: Set(changed + fresh),
            dataRoot: dataRoot
        )
        let snapshot = TrackingSnapshot(
            project: config.project,
            mode: config.mode,
            contributorLogin: config.contributorLogin,
            refreshedAt: DeskClock.nowISO(),
            entities: sortedEntities,
            changedKeys: changed,
            newKeys: fresh,
            deskCreated: desk.created,
            deskUpdated: desk.updated,
            deskArchived: desk.archived
        )
        let persistence = SwiftNativePersistenceCore()
        let path = snapshotPath(dataRoot)
        try await persistence.withFileLock(path) { try await persistence.writeJSON(snapshot.json, to: path) }
        return snapshot
    }

    private static func repositoryEntities(
        config: TrackingConfig,
        actor: String,
        previousEntities: [TrackingEntity],
        previousReviewThreads: [String: [GitHubCommandReviewThreadEvidence]],
        budget: RefreshBudget,
        dataRoot: URL
    ) async throws -> (entities: [TrackingEntity], detailFetched: Int, carriedForward: Int, pass: RepositoryPassOutcome) {
        var entities: [TrackingEntity] = []
        var detailedPullRequests: [GitHubTrackedPullRequest] = []
        var remainingPRBudget = 25
        // W6/L4-03: the issue-list call now throws INTO the per-repo isolator
        // instead of out of refresh(). A 404 on one archived/renamed repo used
        // to discard every other repo's rows for the whole tick.
        let pass = await runRepositoryPass(config.repositories, budget: budget, name: \.fullName) { repo in
            guard let rows = try await GitHubConnectorActions.call(
                path: "repos/\(repo.fullName)/issues",
                params: ["state": "all", "sort": "updated", "direction": "desc", "per_page": "100", "page": "1"],
                dataRoot: dataRoot
            ) as? [[String: Any]] else { return }
            for row in rows {
                let isPR = row["pull_request"] != nil
                if isPR && remainingPRBudget > 0, let number = row["number"] as? Int {
                    remainingPRBudget -= 1
                    detailedPullRequests.append(GitHubTrackedPullRequest(
                        repository: repo.fullName,
                        number: number
                    ))
                } else if isPR, let entity = basicPREntity(row, repo: repo.fullName, staleHours: config.staleAfterHours) {
                    entities.append(entity)
                } else if !isPR, let entity = issueEntity(row, repo: repo.fullName, staleHours: config.staleAfterHours, actor: actor) {
                    entities.append(entity)
                }
            }
        }
        // Thread evidence is a single batched GraphQL call for the whole pass.
        // Degrade to the prior snapshot's evidence rather than failing the
        // refresh: stale threads are recoverable next tick, a lost pass is not.
        let evidence: [String: [GitHubCommandReviewThreadEvidence]]
        do {
            evidence = try await GitHubConnectorActions.reviewThreadEvidence(
                for: detailedPullRequests,
                previous: previousReviewThreads,
                dataRoot: dataRoot
            )
        } catch {
            NSLog("[github-tracking] review-thread evidence failed, reusing prior: %@", error.localizedDescription)
            evidence = previousReviewThreads
        }
        var detailFetched = 0
        for pullRequest in detailedPullRequests {
            if budget.isExhausted { break }
            do {
                entities.append(try await detailedPREntity(
                    repo: pullRequest.repository,
                    number: pullRequest.number,
                    staleHours: config.staleAfterHours,
                    actor: actor,
                    reviewThreads: evidence[pullRequest.itemId] ?? [],
                    dataRoot: dataRoot
                ))
                detailFetched += 1
            } catch {
                // One unreachable PR is not a reason to lose the pass. Its prior
                // row (if any) is carried forward with the rest below.
                NSLog(
                    "[github-tracking] detail fetch failed %@#%d: %@",
                    pullRequest.repository, pullRequest.number, error.localizedDescription
                )
            }
        }
        let carried = carryForwardEntities(for: pass.degraded, from: previousEntities)
            .filter { prior in !entities.contains { $0.key == prior.key } }
        entities.append(contentsOf: carried)
        return (entities, detailFetched, carried.count, pass)
    }

    private static func contributionEntities(
        config: TrackingConfig,
        contributor: String,
        previousEntities: [TrackingEntity],
        previousReviewThreads: [String: [GitHubCommandReviewThreadEvidence]],
        budget: RefreshBudget,
        dataRoot: URL
    ) async throws -> (entities: [TrackingEntity], detailFetched: Int, carriedForward: Int, pass: RepositoryPassOutcome) {
        var entities: [TrackingEntity] = []
        var detailFetched = 0
        var carriedForward = 0
        let priorByKey = Dictionary(previousEntities.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var repositoryRows: [(repository: TrackedRepository, authored: [[String: Any]], linked: Set<Int>)] = []
        var openPullRequests: [GitHubTrackedPullRequest] = []
        var freshPRKeys: Set<String> = []
        // W6/L4-03 phase 1 — search pages, isolated and budgeted per repository.
        let searchPass = await runRepositoryPass(config.repositories, budget: budget, name: \.fullName) { repo in
            let rows = try await contributionPullRequestRows(repo: repo.fullName, login: contributor, dataRoot: dataRoot)
            let authored = GitHubConnectorActions.contributionRows(rows, login: contributor)
            // Linked issues belong to the contributor's durable body of work,
            // even after the PR that names them closes. Only open remote rows
            // become current Desk work below.
            let linkedNumbers = GitHubConnectorActions.linkedIssueNumbers(
                in: authored,
                repository: repo.fullName
            )
            repositoryRows.append((repo, authored, linkedNumbers))
            for row in authored {
                guard let number = row["number"] as? Int else { continue }
                let key = "\(repo.fullName.lowercased())#pr#\(number)"
                freshPRKeys.insert(key)
                guard (row["state"] as? String) == "open" else { continue }
                // Only PRs that actually need a detail fetch enter the GraphQL
                // review-thread budget. Carried-forward PRs reuse the thread
                // evidence already embedded in their prior observation.
                if carriedForwardEntity(
                    prior: priorByKey[key],
                    searchUpdatedAt: row["updated_at"] as? String ?? "",
                    staleHours: config.staleAfterHours
                ) == nil {
                    openPullRequests.append(GitHubTrackedPullRequest(repository: repo.fullName, number: number))
                }
            }
        }
        let evidence: [String: [GitHubCommandReviewThreadEvidence]]
        do {
            evidence = try await GitHubConnectorActions.reviewThreadEvidence(
                for: openPullRequests,
                previous: previousReviewThreads,
                dataRoot: dataRoot
            )
        } catch {
            NSLog("[github-tracking] review-thread evidence failed, reusing prior: %@", error.localizedDescription)
            evidence = previousReviewThreads
        }
        // W6/L4-03 phase 2 — the detail fan-out, the expensive half. Same
        // isolation and same budget: a repository that 404s or runs the clock
        // out here loses only itself, and its prior entities are carried
        // forward below so nothing looks deleted.
        let detailPass = await runRepositoryPass(repositoryRows, budget: budget, name: { $0.repository.fullName }) { entry in
            let (repo, authored, linkedNumbers) = entry
            for row in authored {
                if budget.isExhausted { break }
                guard let number = row["number"] as? Int else { continue }
                let state = row["state"] as? String ?? "unknown"
                if state == "open" {
                    let key = "\(repo.fullName.lowercased())#pr#\(number)"
                    // Delta skip: remote state confirmed unchanged since the prior
                    // snapshot and checks are settled → carry the prior entity
                    // forward with zero detail calls (staleness re-derived inside).
                    if let carried = carriedForwardEntity(
                        prior: priorByKey[key],
                        searchUpdatedAt: row["updated_at"] as? String ?? "",
                        staleHours: config.staleAfterHours
                    ) {
                        entities.append(carried)
                        carriedForward += 1
                        continue
                    }
                    let entity = try await detailedPREntity(
                        repo: repo.fullName,
                        number: number,
                        staleHours: config.staleAfterHours,
                        actor: contributor,
                        reviewThreads: evidence[
                            GitHubCommandObservation.itemId(repository: repo.fullName, number: number)
                        ] ?? [],
                        dataRoot: dataRoot
                    )
                    detailFetched += 1
                    // Defense in depth: a search result and the detailed PR
                    // must both still belong to the configured contributor.
                    guard entity.author?.caseInsensitiveCompare(contributor) == .orderedSame else { continue }
                    entities.append(entity)
                } else if let entity = basicPREntity(row, repo: repo.fullName, staleHours: config.staleAfterHours) {
                    // Closed authored PRs remain bounded snapshot history. They
                    // are deliberately never created as current Desk work.
                    entities.append(entity)
                }
            }
            for number in linkedNumbers.sorted() {
                if budget.isExhausted { break }
                guard let row = try await GitHubConnectorActions.call(
                    path: "repos/\(repo.fullName)/issues/\(number)",
                    dataRoot: dataRoot
                ) as? [String: Any], row["pull_request"] == nil,
                      let entity = issueEntity(row, repo: repo.fullName, staleHours: config.staleAfterHours, actor: contributor) else { continue }
                entities.append(entity)
            }
        }
        // Contract 2c: a prior-open PR that vanished from search entirely (not even
        // returned as a closed history row) still needs its closure observed.
        // Detail-fetch it once so the merge/close settles instead of silently
        // disappearing. Closed PRs still returned by search settle via basicPREntity.
        //
        // Budget-aware: an unsettled closure is carried forward as its prior
        // (still-open) row and retried next tick — strictly better than losing
        // the whole pass to the tick timeout while chasing it.
        for prior in priorOpenKeysMissing(from: previousEntities, freshKeys: freshPRKeys) {
            if budget.isExhausted { break }
            do {
                let entity = try await detailedPREntity(
                    repo: prior.repo,
                    number: prior.number,
                    staleHours: config.staleAfterHours,
                    actor: contributor,
                    reviewThreads: previousReviewThreads[
                        GitHubCommandObservation.itemId(repository: prior.repo, number: prior.number)
                    ] ?? [],
                    dataRoot: dataRoot
                )
                detailFetched += 1
                entities.append(entity)
            } catch {
                NSLog(
                    "[github-tracking] closure settle failed %@#%d: %@",
                    prior.repo, prior.number, error.localizedDescription
                )
            }
        }
        // Union of both phases: a repo degraded in EITHER the search or the
        // detail phase needs its prior rows back, or upsertDesk would see it as
        // vanished and archive live work.
        var pass = RepositoryPassOutcome(
            completed: searchPass.completed.filter { detailPass.completed.contains($0) },
            failed: searchPass.failed + detailPass.failed,
            skippedForBudget: Array(Set(searchPass.skippedForBudget + detailPass.skippedForBudget)).sorted()
        )
        // A repo skipped in phase 1 never reached phase 2, so it is not in
        // detailPass at all — keep it named exactly once.
        pass.skippedForBudget = pass.skippedForBudget.filter { !pass.failed.map(\.repo).contains($0) }
        let carried = carryForwardEntities(for: pass.degraded, from: previousEntities)
        entities.append(contentsOf: carried)
        // Dedup keeps the FIRST row per key, and carried rows are appended last,
        // so a freshly fetched entity always wins over its carried-forward prior.
        let deduped = Dictionary(grouping: entities, by: \.key).compactMap { $0.value.first }
        return (deduped, detailFetched, carriedForward + carried.count, pass)
    }

    private static func contributionPullRequestRows(repo: String, login: String, dataRoot: URL) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for page in 1...10 {
            let result = try await GitHubConnectorActions.call(
                path: "search/issues",
                params: [
                    "q": "repo:\(repo) is:pr author:\(login)",
                    "sort": "updated", "order": "desc", "per_page": "100", "page": String(page),
                ],
                dataRoot: dataRoot
            )
            guard let object = result as? [String: Any], let pageRows = object["items"] as? [[String: Any]], !pageRows.isEmpty else { break }
            rows.append(contentsOf: pageRows)
            if pageRows.count < 100 { break }
        }
        return rows
    }

    private static func detailedPREntity(
        repo: String,
        number: Int,
        staleHours: Int,
        actor: String?,
        reviewThreads: [GitHubCommandReviewThreadEvidence],
        dataRoot: URL
    ) async throws -> TrackingEntity {
        guard let pull = try await GitHubConnectorActions.call(path: "repos/\(repo)/pulls/\(number)", dataRoot: dataRoot) as? [String: Any] else {
            throw GitHubConnectorError.invalidResponse("tracked pull request was not an object")
        }
        // Reviews/review-comments paginate (bounded at 3 pages, 2026-07-21
        // audit): page-1-only reads hid a late CHANGES_REQUESTED past the
        // first 100 rows and items settled prematurely.
        let reviews = try await GitHubConnectorActions.paginatedArray(path: "repos/\(repo)/pulls/\(number)/reviews", dataRoot: dataRoot)
        let reviewComments = try await GitHubConnectorActions.paginatedArray(path: "repos/\(repo)/pulls/\(number)/comments", dataRoot: dataRoot)
        var checks = "unknown"
        var checkRuns: Any = ["check_runs": []]
        var combinedStatus: Any = ["statuses": []]
        if let head = pull["head"] as? [String: Any], let sha = head["sha"] as? String {
            checkRuns = try await GitHubConnectorActions.call(path: "repos/\(repo)/commits/\(sha)/check-runs", params: ["per_page": "100"], dataRoot: dataRoot)
            combinedStatus = try await GitHubConnectorActions.call(path: "repos/\(repo)/commits/\(sha)/status", dataRoot: dataRoot)
            checks = checkSummary(checkRuns, combinedStatus: combinedStatus)
        }
        // Decision-delivered rule: only decision-labeled PRs pay for the
        // newest NON-BOT issue-comment read. The per-issue endpoint lists
        // ASCENDING and ignores sort/direction, so the newest comments are
        // the LAST page (count rides on the pull) — read it at per_page=10
        // and skip bot authors (2026-07-21 audit: a bot reply after the
        // actor's answer must not re-arm needs_user).
        var latestIssueCommentAuthor: String? = nil
        let issueCommentCount = GitHubCommandObservationBuilder.issueCommentCount(pull: pull)
        if issueCommentCount > 0, GitHubCommandObservationBuilder.labelDecisionArmed(
            pull: pull, repository: repo, actor: actor
        ) {
            let lastPage = (issueCommentCount + 9) / 10
            let latest = try await GitHubConnectorActions.call(
                path: "repos/\(repo)/issues/\(number)/comments",
                params: ["per_page": "10", "page": String(lastPage)],
                dataRoot: dataRoot
            )
            latestIssueCommentAuthor = GitHubCommandObservationBuilder.latestNonBotCommentAuthor(latest)
        }
        return makeDetailedPREntity(
            repo: repo,
            number: number,
            staleHours: staleHours,
            actor: actor,
            pull: pull,
            reviews: reviews,
            reviewComments: reviewComments,
            reviewThreads: reviewThreads,
            checkRuns: checkRuns,
            combinedStatus: combinedStatus,
            checks: checks,
            latestIssueCommentAuthor: latestIssueCommentAuthor
        )
    }

    fileprivate static func makeDetailedPREntity(
        repo: String,
        number: Int,
        staleHours: Int,
        actor: String?,
        pull: [String: Any],
        reviews: Any,
        reviewComments: Any,
        reviewThreads: [GitHubCommandReviewThreadEvidence],
        checkRuns: Any,
        combinedStatus: Any,
        checks: String,
        latestIssueCommentAuthor: String? = nil
    ) -> TrackingEntity {
        let reviewState = GitHubCommandObservationBuilder.reviewState(
            reviews,
            reviewThreads: reviewThreads
        )
        let state = pull["merged_at"] is String ? "merged" : (pull["state"] as? String ?? "unknown")
        let updated = pull["updated_at"] as? String ?? ""
        let observation = GitHubCommandObservationBuilder.pullRequest(
            repository: repo,
            number: number,
            pull: pull,
            reviews: reviews,
            reviewComments: reviewComments,
            checkRuns: checkRuns,
            combinedStatus: combinedStatus,
            actor: actor,
            staleAfterHours: staleHours,
            reviewThreads: reviewThreads,
            latestIssueCommentAuthor: latestIssueCommentAuthor
        )
        let blocking = !observation.signals.isEmpty
        return TrackingEntity(
            key: "\(repo.lowercased())#pr#\(number)", repo: repo, number: number, kind: "pull_request",
            title: pull["title"] as? String ?? "Pull request #\(number)", state: state, updatedAt: updated,
            url: pull["html_url"] as? String ?? "https://github.com/\(repo)/pull/\(number)",
            author: (pull["user"] as? [String: Any])?["login"] as? String,
            reviewState: reviewState, checks: checks, mergeable: pull["mergeable_state"] as? String,
            needsUser: observation.humanDecision != nil, blocked: blocking,
            stale: isStale(updated, hours: staleHours) && state == "open",
            commandObservation: observation,
            detailFetchedAt: DeskClock.nowISO()
        )
    }

    /// Delta refresh decision for one open search row. Returns the prior snapshot
    /// entity to carry forward (zero detail calls) when remote state is confirmed
    /// unchanged and checks are settled; returns nil when the item must be
    /// detail-fetched. `nil` is the fail-open answer for every uncertain case.
    /// Carry is BOUNDED (review round 1): CI re-runs on the same head and
    /// review-thread unresolves do NOT bump PR updated_at, so an unbounded
    /// carry could freeze remote truth forever. Every entity therefore gets a
    /// real detail re-read within [45, 75) minutes of its last one — the
    /// per-key deterministic jitter spreads re-reads across refresh cycles
    /// instead of thundering the whole tracked set on one tick.
    static let carryAgeFloorSeconds: TimeInterval = 45 * 60
    static let carryAgeJitterSeconds: TimeInterval = 30 * 60

    /// Stable across launches (unlike hashValue's per-process SipHash seed):
    /// FNV-1a over the key's UTF-8, reduced into the jitter window.
    fileprivate static func carryAgeAllowance(forKey key: String) -> TimeInterval {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let jitter = TimeInterval(hash % UInt64(carryAgeJitterSeconds))
        return carryAgeFloorSeconds + jitter
    }

    fileprivate static func carriedForwardEntity(
        prior: TrackingEntity?,
        searchUpdatedAt: String,
        staleHours: Int,
        now: Date = Date()
    ) -> TrackingEntity? {
        guard let prior,
              prior.state == "open",          // only carry a still-open, detailed row
              prior.checks != "pending",       // pending CI must be re-read: checks don't bump updated_at
              prior.checks != "not_expanded",  // prior was a basic (never-detailed) row
              !searchUpdatedAt.isEmpty,
              prior.updatedAt == searchUpdatedAt,
              // Never carry an item with a LIVE actionable event: review-thread
              // resolution (and possibly other mutations) does not bump the
              // PR's updated_at, so a carried blocked item could freeze an
              // event that was actually resolved. Quiet items dominate the
              // tracked set, so the savings survive; blocked ones always get
              // fresh detail + GraphQL evidence.
              prior.commandObservation.map(\.signals.isEmpty) ?? false,
              // Builds before the ownership-boundary fix could encode a
              // repository-wide label as a user decision with this generic
              // owner. Never carry that legacy classification across an
              // upgrade: one detail read rewrites it under the current rule,
              // after which ordinary bounded carry resumes.
              prior.commandObservation?.humanDecision?.owner != "Repository owner",
              // Bounded staleness: no stamp (pre-delta snapshot) or an expired
              // stamp forces a real re-read. The stamp is PRESERVED on carry,
              // so age accrues and the bound is a hard ceiling, not a lease
              // that renews itself.
              let stampRaw = prior.detailFetchedAt,
              let stamp = DeskClock.parseISO(stampRaw),
              now.timeIntervalSince(stamp) < carryAgeAllowance(forKey: prior.key)
        else { return nil }
        // Remote state is confirmed unchanged this refresh; only the local
        // staleness window advances with wall-clock. Re-derive it so a carried
        // entity is indistinguishable from a re-fetch of the same unchanged PR.
        let freshStale = isStale(prior.updatedAt, hours: staleHours) && prior.state == "open"
        if freshStale == prior.stale { return prior }
        let refreshedObservation: GitHubCommandObservation? = prior.commandObservation.map { obs in
            GitHubCommandObservation(
                repository: obs.repository, number: obs.number, kind: obs.kind, title: obs.title,
                isOpen: obs.isOpen, isMerged: obs.isMerged, observedVersion: obs.observedVersion,
                actionableEventVersion: obs.actionableEventVersion, signals: obs.signals,
                headSHA: obs.headSHA, humanDecision: obs.humanDecision, waitingKind: obs.waitingKind,
                isStale: freshStale, finalReceipt: obs.finalReceipt, reviewThreads: obs.reviewThreads,
                actionableEvidence: obs.actionableEvidence
            )
        }
        return TrackingEntity(
            key: prior.key, repo: prior.repo, number: prior.number, kind: prior.kind,
            title: prior.title, state: prior.state, updatedAt: prior.updatedAt, url: prior.url,
            author: prior.author, reviewState: prior.reviewState, checks: prior.checks,
            mergeable: prior.mergeable, needsUser: prior.needsUser, blocked: prior.blocked,
            stale: freshStale, commandObservation: refreshedObservation,
            detailFetchedAt: prior.detailFetchedAt
        )
    }

    /// Prior open PRs that vanished from fresh search entirely. Closed PRs still
    /// returned by the (state-agnostic) contribution search settle via their basic
    /// history row; a true drop-out is the only case needing a closure fetch.
    fileprivate static func priorOpenKeysMissing(
        from previousEntities: [TrackingEntity],
        freshKeys: Set<String>
    ) -> [TrackingEntity] {
        previousEntities.filter {
            $0.state == "open" && $0.kind == "pull_request" && !freshKeys.contains($0.key)
        }
    }

    fileprivate static func upsertDesk(
        entities: [TrackingEntity],
        previousEntities: [TrackingEntity],
        previousProject: String?,
        config: TrackingConfig,
        changed: Set<String>,
        dataRoot: URL
    ) async throws -> (created: Int, updated: Int, archived: Int) {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        var state = try await store.liveState()
        var created = 0
        var updated = 0
        var archived = 0
        let trackerProjects = Set([previousProject, config.project].compactMap { $0 })
        for entity in entities {
            let match = state.items.first { item in item.refs.contains { ref in
                switch ref.kind {
                case .ghPr(let repo, let number, _, _, _): return entity.kind == "pull_request" && repo.lowercased() == entity.repo.lowercased() && number == entity.number
                case .ghIssue(let repo, let number, _, _): return entity.kind == "issue" && repo.lowercased() == entity.repo.lowercased() && number == entity.number
                default: return false
                }
            }}
            let summary = deskSummary(entity)
            let desiredStatus: DeskStatus = entity.state == "open" ? (entity.blocked ? .blocked : (entity.needsUser ? .flag : .watch)) : .done
            if let item = match {
                // Ownership guard (2026-07-21 audit): the ref-based match can
                // land on a Desk row the tracker does NOT own — one User filed
                // himself for the same PR, or a row from another project.
                // Only tracker-managed rows may be mutated or retired (the
                // same guard the retire sweep below uses); a foreign row is
                // left exactly as found, and no duplicate row is created.
                guard isTrackerManaged(item, projects: trackerProjects) else { continue }
                guard changed.contains(entity.key) else { continue }
                // A Desk row exists only while the entity is actionable (blocked
                // or needs User). When it stops being actionable the row retires;
                // the Workshop's GitHub lane remains the window into everything
                // else the tracker follows. A TERMINAL row must never be
                // resurrected to watch by the update path below — that is how
                // swept rows kept reappearing after every refresh.
                if desiredStatus == .watch {
                    if !item.status.isTerminal {
                        _ = try await store.setStatus(item.handle, status: .done)
                        _ = try await store.archiveItem(item.handle)
                        archived += 1
                    }
                    continue
                }
                if item.title != entity.title || item.summary != summary { _ = try await store.updateTitle(item.handle, title: entity.title, summary: summary) }
                if item.status != desiredStatus { _ = try await store.setStatus(item.handle, status: desiredStatus, blockedReason: entity.blocked ? "GitHub checks or review state are blocking progress." : nil, waitingOn: entity.needsUser ? "owner" : nil) }
                if let ref = item.refs.first(where: { ref in
                    switch ref.kind { case .ghPr(let r, let n, _, _, _), .ghIssue(let r, let n, _, _): return r.lowercased() == entity.repo.lowercased() && n == entity.number; default: return false }
                }) {
                    var fields: [String: JSONValue] = ["title": .string(entity.title), "status": .string(entity.state)]
                    if let checks = entity.checks { fields["checks"] = .string(checks) }
                    _ = try await store.updateRef(item.handle, refId: ref.refId, cachedFields: fields)
                }
                updated += 1
            } else if entity.state == "open", desiredStatus != .watch {
                // Non-actionable entities never get Desk rows: the tracker
                // snapshot and the Workshop's GitHub lane carry them instead.
                let item = try await store.createItem(kind: .gh, project: config.project, title: entity.title, summary: summary)
                let ref: DeskRef = entity.kind == "pull_request"
                    ? DeskRef(kind: .ghPr(repo: entity.repo, number: entity.number, title: entity.title, status: entity.state, checks: entity.checks))
                    : DeskRef(kind: .ghIssue(repo: entity.repo, number: entity.number, title: entity.title, status: entity.state))
                _ = try await store.addRef(item.handle, ref: ref)
                _ = try await store.addRef(item.handle, ref: DeskRef(kind: .url(url: entity.url, title: entity.title)))
                _ = try await store.setCadence(item.handle, cadence: Cadence(mode: .event, interval: "\(config.refreshIntervalMinutes)m", staleAfter: "\(config.staleAfterHours)h", refreshSources: ["github"]))
                _ = try await store.setNotify(item.handle, policy: NotifyPolicy(level: .digest, on: ["state_change", "blocked", "unblocked", "user_next"], cooldown: "6h"))
                if desiredStatus != .watch { _ = try await store.setStatus(item.handle, status: desiredStatus, blockedReason: entity.blocked ? "GitHub checks or review state are blocking progress." : nil, waitingOn: entity.needsUser ? "owner" : nil) }
                created += 1
                state = try await store.liveState()
            }
        }
        // Snapshot-to-snapshot ownership is the cleanup boundary. Only rows
        // whose GitHub identity was present in the previous tracker snapshot
        // are eligible, and only tracker-shaped `.gh` Desk items are archived.
        // Unrelated/non-GitHub Desk work is never touched.
        let activeKeys = Set(entities.filter { $0.state == "open" }.map(\.key))
        let retiredKeys = Set(previousEntities.map(\.key)).subtracting(activeKeys)
        state = try await store.liveState()
        for item in state.items where isTrackerManaged(item, projects: trackerProjects) {
            guard let key = trackingKey(item), retiredKeys.contains(key) else { continue }
            if !item.status.isTerminal {
                _ = try await store.setStatus(item.handle, status: .canceled)
            }
            _ = try await store.archiveItem(item.handle)
            archived += 1
        }

        // Wave 5 — hand this refresh's observed reality to the desk. Everything
        // above only touches rows the TRACKER owns; this pass covers the rest
        // of the board, which is where stale state actually accumulates: a card
        // User filed himself that points at a PR, a campaign blocked on an issue
        // that closed last week. Those get drift FLAGS (they never opted into
        // auto-close), while rows that did opt in resolve themselves with the
        // receipt attached. Ordering matters: the tracker's own sweep ran
        // first, so anything it already closed is terminal here and produces
        // no second decision.
        await reconcileObservedReality(entities: entities, store: store, dataRoot: dataRoot)

        return (created, updated, archived)
    }

    /// Build observations from this refresh and reconcile the desk against
    /// them. Deliberately best-effort: a failure here must never fail the
    /// tracker refresh that produced the data, so it logs and returns.
    fileprivate static func reconcileObservedReality(
        entities: [TrackingEntity],
        store: SwiftNativeDeskStore,
        dataRoot: URL
    ) async {
        guard !entities.isEmpty else { return }
        let now = Date()
        let observedAt = DeskClock.nowISO()
        let observations = entities.map { entity -> DeskObservedRef in
            let terminal = entity.state.lowercased() != "open"
            let merged = entity.commandObservation?.isMerged == true
            // The receipt is quoted state plus a link — never a paraphrase, and
            // never empty, because empty evidence is what forbids the close.
            let evidence = "\(entity.kind == "pull_request" ? "PR" : "issue") #\(entity.number) "
                + "\(merged ? "merged" : entity.state) in \(entity.repo) as of \(entity.updatedAt) — \(entity.url)"
            return DeskObservedRef(
                refKey: entity.key,
                status: merged ? "merged" : entity.state,
                terminal: terminal,
                evidence: evidence,
                source: "github",
                observedAt: observedAt,
                // Content digest, not the fetch envelope and not anything the
                // local clock can move (see `observationFingerprint`): an
                // unchanged PR polled ten times records ten observations and
                // zero changes, which is what lets the learner stretch.
                fingerprint: entity.observationFingerprint
            )
        }

        let cadenceStore = DeskCadenceStore(dataRoot: dataRoot)
        for observation in observations {
            do {
                _ = try await cadenceStore.recordObservation(
                    refKey: observation.refKey,
                    fingerprint: observation.fingerprint,
                    at: now
                )
            } catch {
                NSLog("[desk-observe] cadence record failed for \(observation.refKey): \(error)")
            }
        }

        do {
            let state = try await store.liveState()
            let verdict = DeskObservationEvaluator.evaluate(state, observations: observations, now: now)
            guard !verdict.isEmpty else { return }
            let outcome = try await DeskObservationApplier.apply(verdict, to: store)
            NSLog("[desk-observe] \(outcome.summary)")
        } catch {
            NSLog("[desk-observe] reconciliation failed: \(error)")
        }
    }

    private static func trackingKey(_ item: DeskItem) -> String? {
        for ref in item.refs {
            switch ref.kind {
            case .ghPr(let repo, let number, _, _, _): return "\(repo.lowercased())#pr#\(number)"
            case .ghIssue(let repo, let number, _, _): return "\(repo.lowercased())#issue#\(number)"
            default: continue
            }
        }
        return nil
    }

    private static func isTrackerManaged(_ item: DeskItem, projects: Set<String>) -> Bool {
        item.kind == .gh
            && projects.contains(item.project)
            && item.cadence.refreshSources.contains("github")
            && trackingKey(item) != nil
    }
}

private extension GitHubConnectorActions {
    static func authenticatedLogin(dataRoot: URL) async throws -> String {
        let user = try await validateStoredToken(dataRoot: dataRoot)
        guard let login = user["login"] as? String, !login.isEmpty else {
            throw GitHubConnectorError.invalidResponse("authenticated GitHub user did not include a login")
        }
        return login
    }

    static func contributionRows(_ rows: [[String: Any]], login: String) -> [[String: Any]] {
        rows.filter { row in
            guard row["pull_request"] != nil,
                  let author = (row["user"] as? [String: Any])?["login"] as? String else { return false }
            return author.caseInsensitiveCompare(login) == .orderedSame
        }
    }

    static func linkedIssueNumbers(in rows: [[String: Any]], repository: String) -> Set<Int> {
        linkedIssueNumbers(in: rows.compactMap { $0["body"] as? String }, repository: repository)
    }

    static func linkedIssueNumbers(in bodies: [String], repository: String) -> Set<Int> {
        bodies.reduce(into: Set<Int>()) { result, body in
            result.formUnion(linkedIssueNumbers(in: body, repository: repository))
        }
    }

    static func linkedIssueNumbers(in body: String, repository: String) -> Set<Int> {
        // GitHub closing/reference syntax is intentionally narrow: only issue
        // tokens in a clause introduced by Fixes/Closes/Resolves/Refs (and
        // common inflections) enter contribution scope. A random "#123" in
        // prose is not enough to create Desk work.
        let clausePattern = #"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?|references?)\s*:?\s+(?:(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#\d+(?:\s*(?:,|and)\s*)?)+"#
        let tokenPattern = #"(?:(?<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+))?#(?<number>\d+)"#
        guard let clauseRegex = try? NSRegularExpression(pattern: clausePattern),
              let tokenRegex = try? NSRegularExpression(pattern: tokenPattern) else { return [] }
        let nsBody = body as NSString
        var numbers: Set<Int> = []
        for clause in clauseRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length)) {
            let text = nsBody.substring(with: clause.range)
            let nsText = text as NSString
            for token in tokenRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let repoRange = token.range(withName: "repo")
                if repoRange.location != NSNotFound {
                    let linkedRepo = nsText.substring(with: repoRange)
                    guard linkedRepo.caseInsensitiveCompare(repository) == .orderedSame else { continue }
                }
                let numberRange = token.range(withName: "number")
                if numberRange.location != NSNotFound, let number = Int(nsText.substring(with: numberRange)) {
                    numbers.insert(number)
                }
            }
        }
        return numbers
    }

    static func envelope(_ action: String, fields: [String: JSONValue]) -> JSONValue {
        var object: [String: JSONValue] = [
            "actionId": .string(action), "connectorId": .string("github"),
            "ok": .bool(true), "status": .string("completed"),
        ]
        for (key, value) in fields { object[key] = value }
        return GitHubConnectorSecretRedactor.redactValue(.object(object))
    }

    static func required(_ input: [String: JSONValue], _ key: String) throws -> String {
        guard let value = normalized(input[key]) else { throw GitHubConnectorError.invalidInput("GitHub action requires \(key).") }
        return value
    }

    static func repository(_ input: [String: JSONValue]) throws -> String {
        let raw = normalized(input["repo"] ?? input["repository"] ?? input["full_name"])
        let owner = normalized(input["owner"])
        guard let raw else { throw GitHubConnectorError.invalidInput("GitHub action requires repo as owner/name.") }
        return try canonicalRepository(raw.contains("/") ? raw : "\(owner ?? "")/\(raw)")
    }

    static func canonicalRepository(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { throw GitHubConnectorError.invalidInput("GitHub repository must be owner/name.") }
        return "\(parts[0])/\(parts[1])"
    }

    static func positiveNumber(_ input: [String: JSONValue]) throws -> Int {
        let value = int(input["number"], default: 0)
        try requirePositive(value)
        return value
    }

    static func requirePositive(_ value: Int) throws {
        guard value > 0 else { throw GitHubConnectorError.invalidInput("GitHub action requires a positive issue or pull request number.") }
    }

    static func stringArray(_ raw: JSONValue?) -> [String] {
        switch raw {
        case .array(let rows): return rows.compactMap { normalized($0) }
        case .string(let value): return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        default: return []
        }
    }

    static func issueBody(_ input: [String: JSONValue], requireTitle: Bool) throws -> [String: Any] {
        var body: [String: Any] = [:]
        for key in ["title", "body", "state", "state_reason"] { if let value = normalized(input[key]) { body[key] = value } }
        for key in ["labels", "assignees"] where input[key] != nil { body[key] = stringArray(input[key]) }
        let milestone = int(input["milestone"], default: 0); if milestone > 0 { body["milestone"] = milestone }
        if requireTitle && body["title"] == nil { throw GitHubConnectorError.invalidInput("Creating an issue requires title.") }
        return body
    }

    static func pullRequestBody(_ input: [String: JSONValue], creating: Bool) throws -> [String: Any] {
        var body: [String: Any] = [:]
        for key in ["title", "head", "base", "body", "state"] { if let value = normalized(input[key]) { body[key] = value } }
        if let draft = bool(input["draft"]) { body["draft"] = draft }
        if creating {
            for key in ["title", "head", "base"] where body[key] == nil { throw GitHubConnectorError.invalidInput("Creating a pull request requires title, head, and base.") }
        }
        return body
    }

    static func trackedRepository(from raw: [String: Any]) -> TrackedRepository? {
        guard let fullName = raw["full_name"] as? String, let name = raw["name"] as? String else { return nil }
        return TrackedRepository(fullName: fullName, name: name, htmlURL: raw["html_url"] as? String ?? "https://github.com/\(fullName)", defaultBranch: raw["default_branch"] as? String)
    }

    static func derivedReviewState(_ raw: Any) -> String {
        guard let rows = raw as? [[String: Any]] else { return "review_required" }
        var latest: [String: String] = [:]
        for row in rows {
            guard let user = (row["user"] as? [String: Any])?["login"] as? String, let state = row["state"] as? String else { continue }
            latest[user] = state.uppercased()
        }
        if latest.values.contains("CHANGES_REQUESTED") { return "changes_requested" }
        if latest.values.contains("APPROVED") { return "approved" }
        if latest.values.contains("COMMENTED") { return "commented" }
        return "review_required"
    }

    static func boundedChecks(_ runs: Any, combinedStatus: Any) -> JSONValue {
        let summary = checkSummary(runs, combinedStatus: combinedStatus)
        let runRows = (runs as? [String: Any])?["check_runs"] as? [[String: Any]] ?? []
        let bounded = runRows.prefix(100).map { row -> JSONValue in
            .object([
                "name": .string(row["name"] as? String ?? "check"),
                "status": .string(row["status"] as? String ?? "unknown"),
                "conclusion": (row["conclusion"] as? String).map(JSONValue.string) ?? .null,
                "url": .string(row["html_url"] as? String ?? row["details_url"] as? String ?? ""),
            ])
        }
        return .object(["summary": .string(summary), "runs": .array(Array(bounded)), "combined": JSONValue(fromFoundation: combinedStatus)])
    }

    static func boundFilePatches(_ raw: Any, maxCharacters: Int) -> (files: [[String: Any]], characters: Int, truncated: Bool) {
        guard let rows = raw as? [[String: Any]] else { return ([], 0, false) }
        var remaining = maxCharacters
        var used = 0
        var truncated = false
        let files = rows.map { source -> [String: Any] in
            var row = source
            guard let patch = row["patch"] as? String else { return row }
            if remaining <= 0 { row.removeValue(forKey: "patch"); row["patch_truncated"] = true; truncated = true; return row }
            let prefix = String(patch.prefix(remaining))
            row["patch"] = prefix
            used += prefix.count; remaining -= prefix.count
            if prefix.count < patch.count { row["patch_truncated"] = true; truncated = true }
            return row
        }
        return (files, used, truncated)
    }
}

private func checkSummary(_ runs: Any, combinedStatus: Any) -> String {
    let rows = (runs as? [String: Any])?["check_runs"] as? [[String: Any]] ?? []
    let normalizedConclusions = rows.compactMap { row in
        (row["conclusion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    let failingConclusions: Set<String> = [
        "failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale",
    ]
    let combinedState = ((combinedStatus as? [String: Any])?["state"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let combinedObject = combinedStatus as? [String: Any]
    let combinedContextCount: Int? = {
        if let count = combinedObject?["total_count"] as? Int { return count }
        if let count = combinedObject?["total_count"] as? NSNumber { return count.intValue }
        if let statuses = combinedObject?["statuses"] as? [Any] { return statuses.count }
        return nil
    }()
    // GitHub's combined-status endpoint reports `pending` when there are zero
    // legacy commit statuses. That is an empty/default projection, not a real
    // pending required check, and must not override successful Check Runs.
    let hasCombinedContexts = combinedContextCount.map { $0 > 0 } ?? (combinedState != nil)

    // A concrete failure from either GitHub signal always wins. After that,
    // the combined commit status is the authoritative required-check rollup:
    // an optional/informational check run may remain queued even when GitHub
    // reports that all required checks pass.
    if normalizedConclusions.contains(where: failingConclusions.contains)
        || (hasCombinedContexts && combinedState == "failure")
        || (hasCombinedContexts && combinedState == "error") {
        return "failed"
    }
    if hasCombinedContexts && combinedState == "pending" { return "pending" }
    if hasCombinedContexts && combinedState == "success" { return "passing" }

    let hasUnfinishedRun = rows.contains { row in
        let status = (row["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return status != "completed" || row["conclusion"] == nil
    }
    if hasUnfinishedRun { return "pending" }
    return rows.isEmpty ? "none" : "passing"
}

private func issueEntity(_ row: [String: Any], repo: String, staleHours: Int, actor: String?) -> TrackingEntity? {
    guard let number = row["number"] as? Int else { return nil }
    let state = row["state"] as? String ?? "unknown"
    let updated = row["updated_at"] as? String ?? ""
    let observation = GitHubCommandObservationBuilder.issue(
        repository: repo, row: row, actor: actor, staleAfterHours: staleHours
    )
    return TrackingEntity(
        key: "\(repo.lowercased())#issue#\(number)", repo: repo, number: number, kind: "issue",
        title: row["title"] as? String ?? "Issue #\(number)", state: state, updatedAt: updated,
        url: row["html_url"] as? String ?? "https://github.com/\(repo)/issues/\(number)",
        author: (row["user"] as? [String: Any])?["login"] as? String, reviewState: nil, checks: nil, mergeable: nil,
        needsUser: observation?.humanDecision != nil, blocked: false,
        stale: isStale(updated, hours: staleHours) && state == "open",
        commandObservation: observation
    )
}

private func basicPREntity(_ row: [String: Any], repo: String, staleHours: Int) -> TrackingEntity? {
    guard let number = row["number"] as? Int else { return nil }
    let state = row["state"] as? String ?? "unknown"
    let updated = row["updated_at"] as? String ?? ""
    let observation = GitHubCommandObservation(
        repository: repo,
        number: number,
        kind: .pullRequest,
        title: row["title"] as? String ?? "Pull request #\(number)",
        isOpen: state == "open",
        observedVersion: "\(updated)|\(state)|not_expanded",
        waitingKind: .maintainer,
        isStale: isStale(updated, hours: staleHours) && state == "open",
        finalReceipt: state == "open" ? nil : "\(repo) #\(number) closed."
    )
    return TrackingEntity(
        key: "\(repo.lowercased())#pr#\(number)", repo: repo, number: number, kind: "pull_request",
        title: row["title"] as? String ?? "Pull request #\(number)", state: state, updatedAt: updated,
        url: row["html_url"] as? String ?? "https://github.com/\(repo)/pull/\(number)",
        author: (row["user"] as? [String: Any])?["login"] as? String,
        reviewState: "not_expanded", checks: "not_expanded", mergeable: nil,
        needsUser: false, blocked: false,
        stale: isStale(updated, hours: staleHours) && state == "open",
        commandObservation: observation
    )
}

private func deskSummary(_ entity: TrackingEntity) -> String {
    var parts = ["\(entity.kind == "pull_request" ? "PR" : "Issue") \(entity.repo)#\(entity.number)", entity.state]
    if let review = entity.reviewState { parts.append("review: \(review)") }
    if let checks = entity.checks { parts.append("CI: \(checks)") }
    if entity.needsUser { parts.append("needs user") }
    if entity.stale { parts.append("stale") }
    return parts.joined(separator: " · ")
}

private func isStale(_ timestamp: String, hours: Int) -> Bool {
    guard let date = ISO8601DateFormatter().date(from: timestamp) else { return false }
    return Date().timeIntervalSince(date) >= Double(hours * 3_600)
}

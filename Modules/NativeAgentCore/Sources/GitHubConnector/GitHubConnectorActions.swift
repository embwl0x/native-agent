import Foundation
import NativeAgentCore
import PersistenceCore

public enum GitHubConnectorError: Error, Sendable, Equatable, LocalizedError {
    case invalidInput(String)
    case notConfigured
    case invalidResponse(String)
    case transport(String)
    case http(status: Int, message: String, rateLimitRemaining: Int?, rateLimitReset: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message): return message
        case .notConfigured:
            return "GitHub token is not configured. Paste a Personal Access Token in Connectors > GitHub."
        case .invalidResponse(let message): return "GitHub returned an invalid response: \(message)"
        case .transport(let message): return "GitHub request failed: \(message)"
        case .http(let status, let message, let remaining, let reset):
            var suffix = "HTTP \(status)"
            if let remaining { suffix += ", rate-limit remaining \(remaining)" }
            if let reset { suffix += ", resets \(reset)" }
            return "GitHub API rejected the request: \(message) (\(suffix))."
        }
    }
}

public enum GitHubConnectorActions {
    private static let baseURL = URL(string: "https://api.github.com")!

    public static func status(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        _ = input
        let user = try await validateStoredToken(dataRoot: dataRoot)
        return GitHubConnectorSecretRedactor.redactValue(.object([
            "actionId": .string("github.status"),
            "connectorId": .string("github"),
            "ok": .bool(true),
            "status": .string("completed"),
            "user": JSONValue(fromFoundation: GitHubToolProjection.user(user)),
        ]))
    }

    public static func listRepos(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let limit = clamp(int(input["limit"] ?? input["per_page"], default: 20), min: 1, max: GitHubToolProjection.collectionLimit)
        let sort = string(input["sort"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let direction = string(input["direction"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibility = string(input["visibility"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let affiliation = string(input["affiliation"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        var params: [String: String] = [
            "per_page": String(limit),
            "sort": sort?.isEmpty == false ? sort! : "updated",
            "direction": direction?.isEmpty == false ? direction! : "desc",
            "affiliation": affiliation?.isEmpty == false ? affiliation! : "owner,collaborator,organization_member",
        ]
        if let visibility, !visibility.isEmpty {
            params["visibility"] = visibility
        }
        let repos = try await call(path: "user/repos", params: params, dataRoot: dataRoot)
        let projection = GitHubToolProjection.repositories(repos, limit: limit)
        return GitHubConnectorSecretRedactor.redactValue(.object([
            "actionId": .string("github.list_repos"),
            "connectorId": .string("github"),
            "ok": .bool(true),
            "status": .string("completed"),
            "count": .int(Int64(projection.rows.count)),
            "sourcePageCount": .int(Int64(projection.sourceCount)),
            "resultsTruncated": .bool(projection.truncated),
            "repos": JSONValue(fromFoundation: projection.rows),
        ]))
    }

    public static func listIssues(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let request = try issueListingRequest(input: input)
        let issues = try await call(path: request.path, params: request.params, dataRoot: dataRoot)
        let projection = GitHubToolProjection.issues(issues, limit: request.perPage)
        return GitHubConnectorSecretRedactor.redactValue(.object([
            "actionId": .string("github.list_issues"),
            "connectorId": .string("github"),
            "ok": .bool(true),
            "status": .string("completed"),
            "count": .int(Int64(projection.rows.count)),
            "sourcePageCount": .int(Int64(projection.sourceCount)),
            "resultsTruncated": .bool(projection.truncated),
            "scope": .string(request.scope),
            "repository": request.repository.map(JSONValue.string) ?? .null,
            "page": .int(Int64(request.page)),
            "perPage": .int(Int64(request.perPage)),
            "issues": JSONValue(fromFoundation: projection.rows),
        ]))
    }

    public static func setRepoVisibility(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> JSONValue {
        let rawOwner = normalized(input["owner"])
        let rawRepo = normalized(input["repo"] ?? input["repository"] ?? input["full_name"])
        guard let rawRepo, !rawRepo.isEmpty else {
            throw GitHubConnectorError.invalidInput("GitHub repository visibility change requires repo as owner/name or owner plus repo.")
        }

        let owner: String
        let repo: String
        let parts = rawRepo.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            owner = String(parts[0])
            repo = String(parts[1])
        } else if let rawOwner, !rawOwner.isEmpty {
            owner = rawOwner
            repo = rawRepo
        } else {
            throw GitHubConnectorError.invalidInput("GitHub repository visibility change requires either repo as owner/name or owner plus repo.")
        }

        guard let makePrivate = bool(input["private"]) ?? bool(input["visibility"]) else {
            throw GitHubConnectorError.invalidInput("GitHub repository visibility change requires private true/false or visibility private/public.")
        }

        let repository = "\(owner)/\(repo)"
        let response = try await call(
            path: "repos/\(owner)/\(repo)",
            method: "PATCH",
            body: ["private": makePrivate],
            dataRoot: dataRoot
        )
        return GitHubConnectorSecretRedactor.redactValue(.object([
            "actionId": .string("github.set_repo_visibility"),
            "connectorId": .string("github"),
            "ok": .bool(true),
            "status": .string("completed"),
            "repository": .string(repository),
            "private": .bool(makePrivate),
            "repo": JSONValue(fromFoundation: response),
        ]))
    }

    struct IssueListingRequest: Equatable {
        let path: String
        let params: [String: String]
        let scope: String
        let repository: String?
        let page: Int
        let perPage: Int
    }

    static func issueListingRequest(input: [String: JSONValue]) throws -> IssueListingRequest {
        let perPage = clamp(int(input["limit"] ?? input["per_page"], default: 20), min: 1, max: GitHubToolProjection.collectionLimit)
        let page = clamp(int(input["page"], default: 1), min: 1, max: 1_000)
        let state = normalized(input["state"]) ?? "open"
        let sort = normalized(input["sort"]) ?? "updated"
        let direction = normalized(input["direction"]) ?? "desc"
        var params: [String: String] = [
            "per_page": String(perPage),
            "page": String(page),
            "state": state,
            "sort": sort,
            "direction": direction,
        ]
        for key in ["labels", "since"] {
            if let value = normalized(input[key]) {
                params[key] = value
            }
        }

        let rawOwner = normalized(input["owner"])
        let rawRepo = normalized(input["repo"] ?? input["repository"] ?? input["full_name"])
        guard let rawRepo, !rawRepo.isEmpty else {
            if let filter = normalized(input["filter"]) {
                params["filter"] = filter
            }
            return IssueListingRequest(
                path: "issues",
                params: params,
                scope: "authenticated_user",
                repository: nil,
                page: page,
                perPage: perPage
            )
        }

        let owner: String
        let repo: String
        let parts = rawRepo.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            owner = String(parts[0])
            repo = String(parts[1])
        } else if let rawOwner, !rawOwner.isEmpty {
            owner = rawOwner
            repo = rawRepo
        } else {
            throw GitHubConnectorError.invalidInput("GitHub repository issue listing requires either repo as owner/name or owner plus repo.")
        }
        for key in ["assignee", "creator", "mentioned", "milestone"] {
            if let value = normalized(input[key]) {
                params[key] = value
            }
        }
        let repository = "\(owner)/\(repo)"
        return IssueListingRequest(
            path: "repos/\(owner)/\(repo)/issues",
            params: params,
            scope: "repository",
            repository: repository,
            page: page,
            perPage: perPage
        )
    }

    public static func validateStoredToken(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        credentialStore: GitHubCredentialStore = .shared
    ) async throws -> [String: Any] {
        let token = try await loadToken(dataRoot: dataRoot, credentialStore: credentialStore)
        return try await validateToken(token)
    }

    public static func validateToken(_ token: String) async throws -> [String: Any] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitHubConnectorError.notConfigured
        }
        let response = try await call(path: "user", token: trimmed)
        guard let user = response as? [String: Any] else {
            throw GitHubConnectorError.invalidResponse("/user returned non-object JSON")
        }
        return user
    }

    public static func loadToken(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        credentialStore: GitHubCredentialStore = .shared
    ) async throws -> String {
        guard let token = try await credentialStore.resolveToken(dataRoot: dataRoot) else {
            throw GitHubConnectorError.notConfigured
        }
        return token
    }

    public static func tokenPaths(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [URL] {
        GitHubCredentialStore.metadataPaths(dataRoot: dataRoot)
    }

    /// Page through a list endpoint and concatenate the rows (bounded at
    /// `maxPages`). Reviews and review-comments were fetched page-1 only
    /// (2026-07-21 audit): a late CHANGES_REQUESTED past the first 100 rows
    /// was invisible, so items settled prematurely. Stops early on a short
    /// page.
    static func paginatedArray(
        path: String,
        params: [String: String] = [:],
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        maxPages: Int = 3
    ) async throws -> Any {
        var rows: [[String: Any]] = []
        for page in 1...max(1, maxPages) {
            var pageParams = params
            pageParams["per_page"] = "100"
            pageParams["page"] = String(page)
            let result = try await call(path: path, params: pageParams, dataRoot: dataRoot)
            guard let pageRows = result as? [[String: Any]], !pageRows.isEmpty else { break }
            rows.append(contentsOf: pageRows)
            if pageRows.count < 100 { break }
        }
        return rows
    }

    /// The last page of issue comments PLUS the expected comment when it has
    /// fallen off that page (cross-review MED, 2026-08-17). The per-issue
    /// endpoint lists ASCENDING, so a dispatched comment slides backwards as
    /// newer ones arrive; once it left the final page, exact verification
    /// silently found nothing and the lane settled work that was never
    /// handled. One direct by-id read answers it exactly: present → the event
    /// still stands, 404 → the comment really is gone and the signal may clear.
    static func issueCommentsIncludingExpected(
        repository: String,
        number: Int,
        commentCount: Int,
        expectedIdentifier: String?,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> Any {
        guard commentCount > 0 else { return [] }
        let lastPage = (commentCount + 99) / 100
        let page = try await call(
            path: "repos/\(repository)/issues/\(number)/comments",
            params: ["per_page": "100", "page": String(lastPage)],
            dataRoot: dataRoot
        )
        guard let expectedIdentifier, !expectedIdentifier.isEmpty,
              var rows = page as? [[String: Any]] else { return page }
        let present = rows.contains { row in
            let id = (row["id"] as? NSNumber)?.stringValue ?? (row["id"] as? Int).map(String.init)
            return id == expectedIdentifier
        }
        if present { return rows }
        do {
            let exact = try await call(
                path: "repos/\(repository)/issues/comments/\(expectedIdentifier)",
                dataRoot: dataRoot
            )
            if let row = exact as? [String: Any] { rows.append(row) }
        } catch GitHubConnectorError.http(let status, _, _, _) where status == 404 {
            // Deleted upstream: the event genuinely cleared.
            return rows
        }
        // The recovered row is OLDER than the page it rejoins, and downstream
        // consumers read this array positionally — `latestNonBotCommentAuthor`
        // walks it in reverse to decide who spoke last (gpt-5.5 MED). Appending
        // blindly would make a recovered maintainer comment look like the last
        // word and keep a decision label armed after the contributor answered.
        // Restore the endpoint's own ascending order so position still means
        // recency for every reader.
        rows.sort { lhs, rhs in
            let l = (lhs["created_at"] as? String) ?? ""
            let r = (rhs["created_at"] as? String) ?? ""
            if l != r { return l < r }
            let lid = (lhs["id"] as? NSNumber)?.intValue ?? (lhs["id"] as? Int) ?? 0
            let rid = (rhs["id"] as? NSNumber)?.intValue ?? (rhs["id"] as? Int) ?? 0
            return lid < rid
        }
        return rows
    }

    static func call(
        path: String,
        params: [String: String] = [:],
        method: String = "GET",
        body: [String: Any]? = nil,
        token explicitToken: String? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> Any {
        let token: String
        if let explicitToken {
            token = explicitToken
        } else {
            token = try await loadToken(dataRoot: dataRoot)
        }
        // Closed back-off window: fail locally instead of adding load to a
        // throttle we already provoked (secondary-rate circuit breaker).
        if let remaining = await GitHubRateLimitGate.shared.cooldownRemaining() {
            throw GitHubConnectorError.http(
                status: 429,
                message: "secondary rate-limit back-off active, \(Int(remaining.rounded()))s remaining",
                rateLimitRemaining: nil,
                rateLimitReset: nil
            )
        }
        let url = try requestURL(path: path, params: params)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("NativeAgent", forHTTPHeaderField: "User-Agent")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw GitHubConnectorError.transport(error.localizedDescription)
        }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) ?? [
            "message": "non_json_response",
            "rawPreview": String(data: data.prefix(300), encoding: .utf8) ?? "",
        ]
        guard let http = resp as? HTTPURLResponse else {
            throw GitHubConnectorError.invalidResponse("missing HTTP response")
        }
        guard http.statusCode < 400 else {
            let message: String
            if let object = parsed as? [String: Any],
               let raw = object["message"] as? String,
               !raw.isEmpty {
                message = raw
            } else {
                message = "HTTP \(http.statusCode)"
            }
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap(TimeInterval.init)
                .map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }
            if let backoff = secondaryRateBackoff(
                status: http.statusCode,
                message: message,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                rateLimitRemaining: remaining
            ) {
                await GitHubRateLimitGate.shared.trip(seconds: backoff)
                NSLog(
                    "[github] secondary rate limit — backing off %ds (status %d, remaining %@)",
                    Int(backoff), http.statusCode, remaining.map(String.init) ?? "n/a"
                )
            }
            throw GitHubConnectorError.http(
                status: http.statusCode,
                message: message,
                rateLimitRemaining: remaining,
                rateLimitReset: reset
            )
        }
        return parsed
    }

    private static func requestURL(path: String, params: [String: String]) throws -> URL {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !params.isEmpty {
            comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name }
        }
        guard let url = comps.url else {
            throw GitHubConnectorError.invalidInput("Could not build GitHub API URL.")
        }
        return url
    }

    static func string(_ raw: JSONValue?) -> String? {
        switch raw {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    static func normalized(_ raw: JSONValue?) -> String? {
        let value = string(raw)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func bool(_ raw: JSONValue?) -> Bool? {
        switch raw {
        case .bool(let value):
            return value
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "private":
                return true
            case "false", "public":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    static func int(_ raw: JSONValue?, default defaultValue: Int) -> Int {
        switch raw {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultValue
        case .bool(let b): return b ? 1 : 0
        default: return defaultValue
        }
    }

    static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}

enum GitHubConnectorSecretRedactor {
    private static let classicPAT = try! NSRegularExpression(
        pattern: "\\bgh[opsru]_[A-Za-z0-9_]{20,}\\b",
        options: [.caseInsensitive]
    )
    private static let fineGrainedPAT = try! NSRegularExpression(
        pattern: "\\bgithub_pat_[A-Za-z0-9_]{20,}\\b",
        options: [.caseInsensitive]
    )

    static func redactValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let raw):
            return .string(redact(raw))
        case .array(let items):
            return .array(items.map { redactValue($0) })
        case .object(let object):
            return .object(object.mapValues { redactValue($0) })
        default:
            return value
        }
    }

    private static func redact(_ raw: String) -> String {
        var out = raw
        for regex in [classicPAT, fineGrainedPAT] {
            let range = NSRange(location: 0, length: (out as NSString).length)
            out = regex.stringByReplacingMatches(
                in: out,
                options: [],
                range: range,
                withTemplate: "[REDACTED_GITHUB_TOKEN]"
            )
        }
        return out
    }
}

/// SECONDARY-RATE CIRCUIT BREAKER (cross-review MED, 2026-08-17).
///
/// GitHub answers a secondary-rate violation with 403 (or 429) while
/// `X-RateLimit-Remaining` is still healthy — the "rate-limit remaining 4977"
/// failures already visible on the desk. Nothing in the connector read that as
/// back-off pressure, so the 5-minute contribution sweep plus a per-PR
/// mergeability probe kept issuing calls into a closed window and stayed
/// throttled. The gate turns that into honest degradation: once tripped, every
/// call fails FAST and locally, repositories land in the pass's `failed` list
/// (their prior rows carry as un-refreshed, never as freshly-confirmed), and
/// the next sweep after the window is the natural retry.
actor GitHubRateLimitGate {
    static let shared = GitHubRateLimitGate()
    private var openAgainAt: Date?

    /// Longest back-off we will honor; a header asking for more is capped so a
    /// single hostile value cannot mute monitoring for hours.
    static let maximumBackoff: TimeInterval = 300

    func cooldownRemaining(now: Date = Date()) -> TimeInterval? {
        guard let openAgainAt, openAgainAt > now else { return nil }
        return openAgainAt.timeIntervalSince(now)
    }

    func trip(seconds: TimeInterval, now: Date = Date()) {
        let bounded = min(max(seconds, 1), Self.maximumBackoff)
        let candidate = now.addingTimeInterval(bounded)
        if let openAgainAt, openAgainAt > candidate { return }
        openAgainAt = candidate
    }

    func reset() { openAgainAt = nil }
}

extension GitHubConnectorActions {
    /// Seconds to back off, or nil when this failure is not a secondary-rate
    /// signal. PURE so the classification is testable without a network.
    static func secondaryRateBackoff(
        status: Int,
        message: String,
        retryAfterHeader: String?,
        rateLimitRemaining: Int?
    ) -> TimeInterval? {
        let lowered = message.lowercased()
        let saysSecondary = lowered.contains("secondary rate limit")
            || lowered.contains("abuse detection")
            || lowered.contains("please wait a few minutes")
        guard status == 429 || status == 403 else { return nil }
        // A 403 with budget still on the clock is a THROTTLE, not exhaustion;
        // primary exhaustion (remaining 0) keeps its reset stamp and must not
        // be swallowed by this gate.
        let healthyBudget = (rateLimitRemaining ?? 0) > 0
        guard saysSecondary || status == 429 || healthyBudget else { return nil }
        if let retryAfterHeader, let seconds = TimeInterval(retryAfterHeader), seconds > 0 {
            return seconds
        }
        return 60
    }
}

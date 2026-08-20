import Foundation
import PersistenceCore

struct GitHubTrackedPullRequest: Hashable, Sendable {
    let repository: String
    let number: Int

    var itemId: String {
        GitHubCommandObservation.itemId(repository: repository, number: number)
    }
}

struct GitHubPullRequestMergeabilityEvidence: Sendable, Equatable {
    let headSHA: String
    let updatedAt: String
    /// REST-compatible values consumed by the existing observation builder.
    let mergeableState: String
}

extension GitHubConnectorActions {
    /// REST frequently returns `mergeable_state=unknown`, and a base-branch
    /// change does not bump a PR's `updated_at`. A delta-carried contribution
    /// can therefore become conflicting without any REST/search field changing.
    /// Read GraphQL's authoritative mergeability for every open authored PR in
    /// bounded batches before deciding which rows may be carried forward.
    static func pullRequestMergeabilityEvidence(
        for pullRequests: [GitHubTrackedPullRequest],
        dataRoot: URL
    ) async throws -> [String: GitHubPullRequestMergeabilityEvidence] {
        var pending = Dictionary(grouping: pullRequests, by: \.itemId)
            .compactMap { $0.value.first }
        guard !pending.isEmpty else { return [:] }
        var result: [String: GitHubPullRequestMergeabilityEvidence] = [:]

        while !pending.isEmpty {
            let batch = Array(pending.prefix(20))
            pending.removeFirst(batch.count)
            let page = try await mergeabilityPage(batch, dataRoot: dataRoot)
            for (itemId, evidence) in page.evidence { result[itemId] = evidence }
            if !pending.isEmpty, let remaining = page.remaining,
               remaining <= reviewThreadRateLimitReserve {
                throw GitHubConnectorError.http(
                    status: 429,
                    message: "GraphQL mergeability refresh stopped to preserve the shared rate-limit reserve",
                    rateLimitRemaining: remaining,
                    rateLimitReset: page.resetAt
                )
            }
        }
        return result
    }

    /// Reads every review-thread page for the supplied pull requests. PR pages
    /// are aliased into bounded GraphQL batches; each response reports its
    /// actual cost/remaining budget, which sizes or stops the next batch before
    /// this background refresh consumes the shared GraphQL reserve.
    static func reviewThreadEvidence(
        for pullRequests: [GitHubTrackedPullRequest],
        previous: [String: [GitHubCommandReviewThreadEvidence]],
        dataRoot: URL
    ) async throws -> [String: [GitHubCommandReviewThreadEvidence]] {
        let unique = Dictionary(grouping: pullRequests, by: \.itemId).compactMap { $0.value.first }
        guard !unique.isEmpty else { return [:] }

        var pending = unique.map { ReviewThreadPageRequest(pullRequest: $0, cursor: nil, page: 1) }
        var accumulated: [String: [String: GitHubCommandReviewThreadEvidence]] = [:]
        var remaining: Int?
        var lastCost: Int?
        var lastBatchCount = 0

        while !pending.isEmpty {
            let limit = reviewThreadBatchLimit(
                remaining: remaining,
                lastCost: lastCost,
                lastBatchCount: lastBatchCount
            )
            guard limit > 0 else {
                throw GitHubConnectorError.http(
                    status: 429,
                    message: "GraphQL review-thread refresh stopped to preserve the shared rate-limit reserve",
                    rateLimitRemaining: remaining,
                    rateLimitReset: nil
                )
            }
            let batch = Array(pending.prefix(limit))
            pending.removeFirst(batch.count)
            let response = try await reviewThreadPage(batch, dataRoot: dataRoot)
            remaining = response.remaining
            lastCost = response.cost
            lastBatchCount = batch.count

            for result in response.results {
                var byThread = accumulated[result.pullRequest.itemId] ?? [:]
                for thread in result.threads { byThread[thread.threadId] = thread }
                accumulated[result.pullRequest.itemId] = byThread
                if let cursor = result.nextCursor {
                    guard result.page < 100 else {
                        throw GitHubConnectorError.invalidResponse(
                            "reviewThreads exceeded 100 pages for \(result.pullRequest.itemId)"
                        )
                    }
                    pending.append(ReviewThreadPageRequest(
                        pullRequest: result.pullRequest,
                        cursor: cursor,
                        page: result.page + 1
                    ))
                }
            }

            if !pending.isEmpty,
               let remaining,
               remaining <= reviewThreadRateLimitReserve {
                throw GitHubConnectorError.http(
                    status: 429,
                    message: "GraphQL review-thread refresh stopped to preserve the shared rate-limit reserve",
                    rateLimitRemaining: remaining,
                    rateLimitReset: response.resetAt
                )
            }
        }

        return Dictionary(uniqueKeysWithValues: unique.map { pullRequest in
            let current = Array((accumulated[pullRequest.itemId] ?? [:]).values)
            return (
                pullRequest.itemId,
                reconcileReviewThreads(current: current, previous: previous[pullRequest.itemId])
            )
        })
    }

    static func reconcileReviewThreads(
        current: [GitHubCommandReviewThreadEvidence],
        previous: [GitHubCommandReviewThreadEvidence]?
    ) -> [GitHubCommandReviewThreadEvidence] {
        let prior = Dictionary(uniqueKeysWithValues: (previous ?? []).map { ($0.threadId, $0) })
        return current.map { thread in
            let old = prior[thread.threadId]
            let generation: Int
            if thread.isActionable {
                if let old, old.isActionable {
                    generation = max(1, old.unresolvedGeneration)
                } else if let old {
                    generation = max(1, old.unresolvedGeneration + 1)
                } else {
                    generation = 1
                }
            } else {
                generation = old?.unresolvedGeneration ?? 0
            }
            return GitHubCommandReviewThreadEvidence(
                threadId: thread.threadId,
                isResolved: thread.isResolved,
                isOutdated: thread.isOutdated,
                rootCommentId: thread.rootCommentId,
                reviewId: thread.reviewId,
                unresolvedGeneration: generation
            )
        }.sorted { $0.threadId < $1.threadId }
    }

    /// Merges thread evidence recorded on two surfaces (tracking snapshot and
    /// command store) into the freshest truth per thread. Lifecycle order is
    /// active g1 < resolved g1 < active g2 < …, so the entry that is further
    /// along wins regardless of which surface recorded it.
    static func mergeReviewThreadEvidence(
        _ lhs: [GitHubCommandReviewThreadEvidence]?,
        _ rhs: [GitHubCommandReviewThreadEvidence]?
    ) -> [GitHubCommandReviewThreadEvidence] {
        GitHubCommandReviewThreadEvidence.mergingFreshest(lhs, rhs) ?? []
    }

    static func testReviewThreadBatchLimit(
        remaining: Int?,
        lastCost: Int?,
        lastBatchCount: Int
    ) -> Int {
        reviewThreadBatchLimit(
            remaining: remaining,
            lastCost: lastCost,
            lastBatchCount: lastBatchCount
        )
    }

    static func testParseReviewThreadPage(
        _ root: [String: Any]
    ) throws -> [GitHubCommandReviewThreadEvidence] {
        let request = ReviewThreadPageRequest(
            pullRequest: GitHubTrackedPullRequest(repository: "owner/repo", number: 7),
            cursor: nil,
            page: 1
        )
        return try parseReviewThreadPage(root, requests: [request]).results[0].threads
    }

    static func testParseMergeabilityPage(
        _ root: [String: Any]
    ) throws -> GitHubPullRequestMergeabilityEvidence {
        let request = GitHubTrackedPullRequest(repository: "owner/repo", number: 7)
        return try requireMergeability(
            parseMergeabilityPage(root, requests: [request]).evidence[request.itemId]
        )
    }
}

private extension GitHubConnectorActions {
    static let reviewThreadMaximumBatchSize = 8
    static let reviewThreadRateLimitReserve = 20

    struct ReviewThreadPageRequest {
        let pullRequest: GitHubTrackedPullRequest
        let cursor: String?
        let page: Int
    }

    struct ReviewThreadPageResult {
        let pullRequest: GitHubTrackedPullRequest
        let page: Int
        let threads: [GitHubCommandReviewThreadEvidence]
        let nextCursor: String?
    }

    struct ReviewThreadBatchResult {
        let results: [ReviewThreadPageResult]
        let cost: Int?
        let remaining: Int?
        let resetAt: String?
    }

    struct MergeabilityBatchResult {
        let evidence: [String: GitHubPullRequestMergeabilityEvidence]
        let remaining: Int?
        let resetAt: String?
    }

    static func mergeabilityPage(
        _ requests: [GitHubTrackedPullRequest],
        dataRoot: URL
    ) async throws -> MergeabilityBatchResult {
        var definitions: [String] = []
        var selections: [String] = []
        var variables: [String: Any] = [:]
        for (index, request) in requests.enumerated() {
            definitions.append(contentsOf: [
                "$owner\(index): String!",
                "$name\(index): String!",
                "$number\(index): Int!",
            ])
            let parts = request.repository.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw GitHubConnectorError.invalidInput("GitHub repository must be owner/name.")
            }
            variables["owner\(index)"] = parts[0]
            variables["name\(index)"] = parts[1]
            variables["number\(index)"] = request.number
            selections.append("""
                pr\(index): repository(owner: $owner\(index), name: $name\(index)) {
                  pullRequest(number: $number\(index)) {
                    headRefOid
                    updatedAt
                    mergeable
                    mergeStateStatus
                  }
                }
                """)
        }
        let query = """
            query PullRequestMergeability(\(definitions.joined(separator: ", "))) {
              \(selections.joined(separator: "\n"))
              rateLimit { cost remaining resetAt }
            }
            """
        let root = try await graphQL(query: query, variables: variables, dataRoot: dataRoot)
        return try parseMergeabilityPage(root, requests: requests)
    }

    static func parseMergeabilityPage(
        _ root: [String: Any],
        requests: [GitHubTrackedPullRequest]
    ) throws -> MergeabilityBatchResult {
        let data = root["data"] as? [String: Any]
        let rate = data?["rateLimit"] as? [String: Any]
        let remaining = integer(rate?["remaining"])
        let resetAt = rate?["resetAt"] as? String
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            let message = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
            if remaining == 0 {
                throw GitHubConnectorError.http(
                    status: 429,
                    message: message.isEmpty ? "GraphQL rate limit exhausted" : message,
                    rateLimitRemaining: remaining,
                    rateLimitReset: resetAt
                )
            }
            throw GitHubConnectorError.invalidResponse(
                "GraphQL mergeability returned errors: \(String(message.prefix(500)))"
            )
        }
        guard let data else {
            throw GitHubConnectorError.invalidResponse("GraphQL mergeability response omitted data")
        }
        var evidence: [String: GitHubPullRequestMergeabilityEvidence] = [:]
        for (index, request) in requests.enumerated() {
            guard let repository = data["pr\(index)"] as? [String: Any],
                  let pullRequest = repository["pullRequest"] as? [String: Any],
                  let headSHA = pullRequest["headRefOid"] as? String,
                  let updatedAt = pullRequest["updatedAt"] as? String,
                  let rawMergeable = pullRequest["mergeable"] as? String else {
                throw GitHubConnectorError.invalidResponse(
                    "GraphQL mergeability omitted \(request.itemId)"
                )
            }
            let mergeStatus = (pullRequest["mergeStateStatus"] as? String)?.uppercased()
            let mergeableState: String
            switch rawMergeable.uppercased() {
            case "CONFLICTING": mergeableState = "dirty"
            case "MERGEABLE": mergeableState = mergeStatus == "DIRTY" ? "dirty" : "clean"
            default: mergeableState = "unknown"
            }
            evidence[request.itemId] = GitHubPullRequestMergeabilityEvidence(
                headSHA: headSHA,
                updatedAt: updatedAt,
                mergeableState: mergeableState
            )
        }
        return MergeabilityBatchResult(
            evidence: evidence,
            remaining: remaining,
            resetAt: resetAt
        )
    }

    static func requireMergeability(
        _ value: GitHubPullRequestMergeabilityEvidence?
    ) throws -> GitHubPullRequestMergeabilityEvidence {
        guard let value else {
            throw GitHubConnectorError.invalidResponse("GraphQL mergeability test row was absent")
        }
        return value
    }

    static func reviewThreadBatchLimit(
        remaining: Int?,
        lastCost: Int?,
        lastBatchCount: Int
    ) -> Int {
        guard let remaining else { return reviewThreadMaximumBatchSize }
        let spendable = remaining - reviewThreadRateLimitReserve
        guard spendable > 0 else { return 0 }
        let estimatedCostPerPR = max(
            1,
            Int(ceil(Double(lastCost ?? lastBatchCount) / Double(max(1, lastBatchCount))))
        )
        // A floor of one page here could overrun the reserve when the spendable
        // budget is smaller than one page's estimated cost; returning 0 makes
        // the caller throw before sending it.
        return min(reviewThreadMaximumBatchSize, spendable / estimatedCostPerPR)
    }

    static func reviewThreadPage(
        _ requests: [ReviewThreadPageRequest],
        dataRoot: URL
    ) async throws -> ReviewThreadBatchResult {
        var definitions: [String] = []
        var selections: [String] = []
        var variables: [String: Any] = [:]
        for (index, request) in requests.enumerated() {
            definitions.append(contentsOf: [
                "$owner\(index): String!",
                "$name\(index): String!",
                "$number\(index): Int!",
                "$cursor\(index): String",
            ])
            let parts = request.pullRequest.repository.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw GitHubConnectorError.invalidInput("GitHub repository must be owner/name.")
            }
            variables["owner\(index)"] = parts[0]
            variables["name\(index)"] = parts[1]
            variables["number\(index)"] = request.pullRequest.number
            variables["cursor\(index)"] = request.cursor ?? NSNull()
            selections.append("""
                pr\(index): repository(owner: $owner\(index), name: $name\(index)) {
                  pullRequest(number: $number\(index)) {
                    reviewThreads(first: 100, after: $cursor\(index)) {
                      nodes {
                        id
                        isResolved
                        isOutdated
                        comments(first: 1) {
                          nodes {
                            databaseId
                            pullRequestReview { databaseId }
                          }
                        }
                      }
                      pageInfo { hasNextPage endCursor }
                    }
                  }
                }
                """)
        }
        let query = """
            query ReviewThreads(\(definitions.joined(separator: ", "))) {
              \(selections.joined(separator: "\n"))
              rateLimit { cost remaining resetAt }
            }
            """
        let root = try await graphQL(query: query, variables: variables, dataRoot: dataRoot)
        return try parseReviewThreadPage(root, requests: requests)
    }

    static func parseReviewThreadPage(
        _ root: [String: Any],
        requests: [ReviewThreadPageRequest]
    ) throws -> ReviewThreadBatchResult {
        let data = root["data"] as? [String: Any]
        let rate = data?["rateLimit"] as? [String: Any]
        let remaining = integer(rate?["remaining"])
        let cost = integer(rate?["cost"])
        let resetAt = rate?["resetAt"] as? String
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            let message = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
            if remaining == 0 {
                throw GitHubConnectorError.http(
                    status: 429,
                    message: message.isEmpty ? "GraphQL rate limit exhausted" : message,
                    rateLimitRemaining: remaining,
                    rateLimitReset: resetAt
                )
            }
            throw GitHubConnectorError.invalidResponse(
                "GraphQL reviewThreads returned errors: \(String(message.prefix(500)))"
            )
        }
        guard let data else {
            throw GitHubConnectorError.invalidResponse("GraphQL reviewThreads response omitted data")
        }

        var results: [ReviewThreadPageResult] = []
        for (index, request) in requests.enumerated() {
            guard let repository = data["pr\(index)"] as? [String: Any],
                  let pullRequest = repository["pullRequest"] as? [String: Any],
                  let connection = pullRequest["reviewThreads"] as? [String: Any],
                  let nodes = connection["nodes"] as? [[String: Any]],
                  let pageInfo = connection["pageInfo"] as? [String: Any] else {
                throw GitHubConnectorError.invalidResponse(
                    "GraphQL reviewThreads omitted \(request.pullRequest.itemId)"
                )
            }
            let threads = try nodes.map { node -> GitHubCommandReviewThreadEvidence in
                guard let id = node["id"] as? String,
                      let isResolved = node["isResolved"] as? Bool,
                      let isOutdated = node["isOutdated"] as? Bool else {
                    throw GitHubConnectorError.invalidResponse(
                        "GraphQL reviewThreads returned a malformed thread for \(request.pullRequest.itemId)"
                    )
                }
                let comment = ((node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first
                let review = comment?["pullRequestReview"] as? [String: Any]
                return GitHubCommandReviewThreadEvidence(
                    threadId: id,
                    isResolved: isResolved,
                    isOutdated: isOutdated,
                    rootCommentId: integer64(comment?["databaseId"]),
                    reviewId: integer64(review?["databaseId"])
                )
            }
            let hasNext = pageInfo["hasNextPage"] as? Bool ?? false
            let cursor = pageInfo["endCursor"] as? String
            if hasNext && (cursor == nil || cursor?.isEmpty == true) {
                throw GitHubConnectorError.invalidResponse(
                    "GraphQL reviewThreads pagination omitted an end cursor for \(request.pullRequest.itemId)"
                )
            }
            results.append(ReviewThreadPageResult(
                pullRequest: request.pullRequest,
                page: request.page,
                threads: threads,
                nextCursor: hasNext ? cursor : nil
            ))
        }
        return ReviewThreadBatchResult(
            results: results,
            cost: cost,
            remaining: remaining,
            resetAt: resetAt
        )
    }

    static func graphQL(
        query: String,
        variables: [String: Any],
        dataRoot: URL
    ) async throws -> [String: Any] {
        // GraphQL is the sweep's FIRST pressure point (mergeability + review
        // threads run before the REST detail fan-out), so it must share the
        // REST breaker or a secondary-rate 403 here would sail straight on
        // into the detail calls (gpt-5.5 MED).
        if let remaining = await GitHubRateLimitGate.shared.cooldownRemaining() {
            throw GitHubConnectorError.http(
                status: 429,
                message: "secondary rate-limit back-off active, \(Int(remaining.rounded()))s remaining",
                rateLimitRemaining: nil,
                rateLimitReset: nil
            )
        }
        let token = try await loadToken(dataRoot: dataRoot)
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": variables,
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NativeAgent", forHTTPHeaderField: "User-Agent")

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GitHubConnectorError.transport(error.localizedDescription)
        }
        let parsed = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        guard let http = response as? HTTPURLResponse else {
            throw GitHubConnectorError.invalidResponse("GraphQL response omitted HTTP metadata")
        }
        guard http.statusCode < 400 else {
            let message = (parsed?["message"] as? String) ?? "HTTP \(http.statusCode)"
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap(TimeInterval.init)
                .map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }
            if let backoff = GitHubConnectorActions.secondaryRateBackoff(
                status: http.statusCode,
                message: message,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                rateLimitRemaining: remaining
            ) {
                await GitHubRateLimitGate.shared.trip(seconds: backoff)
                NSLog("[github] GraphQL secondary rate limit — backing off %ds", Int(backoff))
            }
            throw GitHubConnectorError.http(
                status: http.statusCode,
                message: message,
                rateLimitRemaining: remaining,
                rateLimitReset: reset
            )
        }
        guard let parsed else {
            throw GitHubConnectorError.invalidResponse("GraphQL reviewThreads returned non-object JSON")
        }
        return parsed
    }

    static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    static func integer64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return (value as? NSNumber)?.int64Value
    }
}

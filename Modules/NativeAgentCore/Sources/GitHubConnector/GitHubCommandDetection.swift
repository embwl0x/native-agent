import Foundation
import NativeAgentCore
import PersistenceCore

/// Converts live GitHub evidence into the connector-neutral observation the
/// store routes. No repository name, organization, or project is special.
enum GitHubCommandObservationBuilder {
    static let decisionLabels: Set<String> = [
        "needs-decision", "product-decision", "permission-required",
        "disputed-direction", "breaking-change", "irreversible",
    ]

    /// True when a needs-decision-class label is actually addressed to the
    /// configured contributor. A repository-wide label alone says that
    /// somebody must decide; it does not prove that this user's attention is
    /// required. Explicit assignment (or owning the repository) is the trust
    /// boundary that allows the label to raise needs-you state.
    static func labelDecisionArmed(
        pull: [String: Any],
        repository: String,
        actor: String?
    ) -> Bool {
        let labels = Set(((pull["labels"] as? [[String: Any]]) ?? []).compactMap {
            ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return !labels.intersection(decisionLabels).isEmpty
            && decisionLabelTargetsActor(item: pull, repository: repository, actor: actor)
    }

    private static func decisionLabelTargetsActor(
        item: [String: Any],
        repository: String,
        actor: String?
    ) -> Bool {
        guard let actor = actor?.trimmingCharacters(in: .whitespacesAndNewlines), !actor.isEmpty else {
            return false
        }
        let assignees = ((item["assignees"] as? [[String: Any]]) ?? []).compactMap {
            $0["login"] as? String
        }
        if assignees.contains(where: { $0.caseInsensitiveCompare(actor) == .orderedSame }) {
            return true
        }
        guard let repositoryOwner = repository.split(separator: "/", maxSplits: 1).first else {
            return false
        }
        return String(repositoryOwner).caseInsensitiveCompare(actor) == .orderedSame
    }

    /// Author login of the first row of an issue-comments response fetched
    /// with per_page=1&page=<comment count> — the per-ISSUE comments endpoint
    /// IGNORES sort/direction (verified empirically 2026-07-16 on a
    /// 133-comment issue: desc returned the OLDEST row) and always lists
    /// ascending, so the newest comment is the last page at page size 1. The
    /// issue-comment COUNT rides on the pull/issue object itself.
    static func latestCommentAuthor(_ comments: Any) -> String? {
        let rows = comments as? [[String: Any]] ?? []
        return (rows.first?["user"] as? [String: Any])?["login"] as? String
    }

    /// Automation accounts whose comments never re-arm the decision-delivered
    /// rule (2026-07-21 audit): a bot reply after the actor's answer is not a
    /// maintainer response, so it must not bounce the PR back to needs_user.
    /// The suffix covers GitHub Apps; the list covers the few bare-login
    /// automations.
    static let botLogins: Set<String> = ["dependabot", "renovate", "github-actions", "codecov", "stale"]
    static func isBotLogin(_ login: String?) -> Bool {
        guard let login else { return false }
        let normalized = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix("[bot]") || botLogins.contains(normalized)
    }

    /// Author of the newest NON-BOT issue comment from the LAST page of the
    /// ascending per-issue comments listing (fetched per_page=10 so a bot
    /// trail after the actor's answer costs no extra calls). Nil when the
    /// page is empty or every comment on it is automation — the
    /// decision-delivered rule then stays armed rather than trusting a bot.
    static func latestNonBotCommentAuthor(_ comments: Any) -> String? {
        let rows = comments as? [[String: Any]] ?? []
        for row in rows.reversed() {
            guard let login = (row["user"] as? [String: Any])?["login"] as? String else { continue }
            if !isBotLogin(login) { return login }
        }
        return nil
    }

    /// Issue-comment count from the pull/issue object (`comments` field).
    static func issueCommentCount(pull: [String: Any]) -> Int {
        if let n = pull["comments"] as? Int { return n }
        if let n = pull["comments"] as? NSNumber { return n.intValue }
        return 0
    }

    static func pullRequest(
        repository: String,
        number: Int,
        pull: [String: Any],
        reviews: Any,
        reviewComments: Any,
        checkRuns: Any,
        combinedStatus: Any,
        actor: String?,
        staleAfterHours: Int,
        reviewThreads: [GitHubCommandReviewThreadEvidence]? = nil,
        latestIssueCommentAuthor: String? = nil
    ) -> GitHubCommandObservation {
        let headSHA = ((pull["head"] as? [String: Any])?["sha"] as? String) ?? ""
        let updatedAt = pull["updated_at"] as? String ?? "unknown"
        let state = pull["merged_at"] is String ? "merged" : (pull["state"] as? String ?? "unknown")
        let reviewRows = reviews as? [[String: Any]] ?? []
        let commentRows = reviewComments as? [[String: Any]] ?? []
        let runRows = (checkRuns as? [String: Any])?["check_runs"] as? [[String: Any]] ?? []
        let actionableReviewRows = reviewRows.filter { review in
            guard reviewStateValue(review) == "CHANGES_REQUESTED",
                  let reviewId = numericIdentifier(review),
                  let reviewThreads else { return true }
            let associated = reviewThreads.filter { $0.reviewId == reviewId }
            return associated.isEmpty || associated.contains(where: \.isActionable)
        }
        let reviewState = latestReviewState(actionableReviewRows)
        let checks = checkState(runRows: runRows, combinedStatus: combinedStatus)
        let mergeableState = (pull["mergeable_state"] as? String ?? "unknown").lowercased()
        let conflict = mergeableState == "dirty"
            || (pull["mergeable"] as? Bool == false && ["dirty", "blocked"].contains(mergeableState))

        var signals = Set<GitHubCommandActionSignal>()
        var markers: [String] = []
        var actionableEvidence: [GitHubCommandActionEvidence] = []
        if reviewState == "changes_requested" {
            signals.insert(.changesRequested)
            if let row = latest(actionableReviewRows.filter { (($0["state"] as? String) ?? "").uppercased() == "CHANGES_REQUESTED" }) {
                markers.append("review:\(identifier(row)):\(timestamp(row))")
                actionableEvidence.append(actionEvidence(
                    signal: .changesRequested,
                    row: row,
                    fallback: "A reviewer requested changes."
                ))
                if let reviewId = numericIdentifier(row), let reviewThreads {
                    markers.append(contentsOf: reviewThreads
                        .filter { $0.reviewId == reviewId && $0.isActionable }
                        .map(threadMarker))
                }
            } else {
                markers.append("review:changes_requested")
            }
        }
        let currentHeadComments = commentRows.filter { row in
            guard !headSHA.isEmpty else { return true }
            let commit = row["commit_id"] as? String
            return commit == nil || commit == headSHA
        }.filter { row in
            guard let thread = reviewThread(for: row, in: reviewThreads) else { return true }
            return thread.isActionable
        }
        if let comment = latest(currentHeadComments) {
            signals.insert(.reviewComment)
            markers.append("comment:\(identifier(comment)):\(timestamp(comment))")
            actionableEvidence.append(actionEvidence(
                signal: .reviewComment,
                row: comment,
                fallback: "An unresolved review comment applies to the current head."
            ))
            if let thread = reviewThread(for: comment, in: reviewThreads) {
                markers.append(threadMarker(thread))
            }
        }
        if checks == "failed" {
            signals.insert(.ciFailure)
            let failed = runRows.filter { row in
                let value = ((row["conclusion"] as? String) ?? "").lowercased()
                return ["failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale"].contains(value)
            }
            let marker = latest(failed).map { "\(identifier($0)):\(timestamp($0))" } ?? "combined"
            markers.append("ci:\(headSHA):\(marker)")
            if failed.isEmpty {
                actionableEvidence.append(GitHubCommandActionEvidence(
                    signal: .ciFailure,
                    identifier: "combined-status",
                    summary: "The combined commit status is failing."
                ))
            } else {
                actionableEvidence.append(contentsOf: failed.prefix(8).map { row in
                    let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let conclusion = (row["conclusion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return GitHubCommandActionEvidence(
                        signal: .ciFailure,
                        identifier: identifier(row),
                        summary: [name, conclusion].compactMap { $0 }.joined(separator: ": "),
                        url: row["html_url"] as? String
                    )
                })
            }
        }
        if conflict {
            signals.insert(.conflict)
            markers.append("conflict:\(headSHA):\(updatedAt)")
            actionableEvidence.append(GitHubCommandActionEvidence(
                signal: .conflict,
                identifier: headSHA,
                summary: "GitHub reports that the pull request conflicts with its base branch."
            ))
        }

        let labels = Set(((pull["labels"] as? [[String: Any]]) ?? []).compactMap {
            ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let decisionLabels = Self.decisionLabels
        let requested = ((pull["requested_reviewers"] as? [[String: Any]]) ?? []).compactMap {
            $0["login"] as? String
        }
        let humanDecision: GitHubCommandBlocker?
        // Decision-delivered rule (2026-07-16): a needs-decision-class LABEL
        // outlives the decision — only the repo owner can remove it, and a
        // contributor's answer (live case: #65180, answered at 07:55Z, label
        // still pinned hours later) would otherwise hold needs_user forever.
        // If the LAST issue comment on the PR is the actor's, the decision
        // was delivered and the ball is with the maintainer; a later
        // maintainer comment makes the actor no longer last → re-arms
        // honestly. Applies ONLY to the label branch: an explicit
        // requested-reviewer entry is cleared by GitHub itself when the
        // review is submitted, so commenting must not dismiss it.
        let actorSpokeLast: Bool = {
            guard let actor, let latestIssueCommentAuthor else { return false }
            return latestIssueCommentAuthor.caseInsensitiveCompare(actor) == .orderedSame
        }()
        if let actor, requested.contains(where: { $0.caseInsensitiveCompare(actor) == .orderedSame }) {
            humanDecision = GitHubCommandBlocker(
                detail: "A human review decision is requested on this pull request.", owner: actor
            )
        } else if let label = labels.intersection(decisionLabels).sorted().first,
                  decisionLabelTargetsActor(item: pull, repository: repository, actor: actor),
                  !actorSpokeLast,
                  let actor {
            humanDecision = GitHubCommandBlocker(
                detail: "GitHub explicitly assigns this decision to the configured contributor (\(label)).",
                owner: actor
            )
        } else {
            humanDecision = nil
        }

        let waiting: GitHubCommandWaitingKind
        if checks == "pending" { waiting = .ci }
        else if reviewState == "review_required" || reviewState == "commented" { waiting = .review }
        else if checks == "passing" && reviewState == "approved" && !conflict { waiting = .readyToMerge }
        else { waiting = .maintainer }

        let version = markers.isEmpty ? nil : markers.sorted().joined(separator: "|")
        let threadVersion = reviewThreads.map { threads in
            threads.map { thread in
                "\(thread.threadId):\(thread.isResolved ? "resolved" : "unresolved"):\(thread.isOutdated ? "outdated" : "current"):g\(thread.unresolvedGeneration)"
            }.sorted().joined(separator: ",")
        }
        let merged = state == "merged"
        return GitHubCommandObservation(
            repository: repository,
            number: number,
            kind: .pullRequest,
            title: pull["title"] as? String ?? "Pull request #\(number)",
            isOpen: state == "open",
            isMerged: merged,
            observedVersion: "\(updatedAt)|\(headSHA)|\(state)|\(reviewState)|\(checks)|\(mergeableState)|threads:\(threadVersion ?? "unavailable")",
            actionableEventVersion: version,
            signals: signals,
            headSHA: headSHA.isEmpty ? nil : headSHA,
            humanDecision: humanDecision,
            waitingKind: waiting,
            isStale: isStale(updatedAt, hours: staleAfterHours) && state == "open",
            finalReceipt: state == "open" ? nil : "\(repository) #\(number) \(merged ? "merged" : "closed").",
            reviewThreads: reviewThreads,
            actionableEvidence: actionableEvidence.isEmpty ? nil : actionableEvidence
        )
    }

    static func reviewState(
        _ reviews: Any,
        reviewThreads: [GitHubCommandReviewThreadEvidence]?
    ) -> String {
        let rows = reviews as? [[String: Any]] ?? []
        let actionable = rows.filter { review in
            guard reviewStateValue(review) == "CHANGES_REQUESTED",
                  let reviewId = numericIdentifier(review),
                  let reviewThreads else { return true }
            let associated = reviewThreads.filter { $0.reviewId == reviewId }
            return associated.isEmpty || associated.contains(where: \.isActionable)
        }
        return latestReviewState(actionable)
    }

    static func issue(
        repository: String,
        row: [String: Any],
        actor: String?,
        staleAfterHours: Int
    ) -> GitHubCommandObservation? {
        guard let number = row["number"] as? Int else { return nil }
        let state = row["state"] as? String ?? "unknown"
        let updatedAt = row["updated_at"] as? String ?? "unknown"
        let labels = Set(((row["labels"] as? [[String: Any]]) ?? []).compactMap {
            ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let decisionLabels = Self.decisionLabels
        let decision: GitHubCommandBlocker? = labels.intersection(decisionLabels).sorted().first.flatMap { label in
            guard decisionLabelTargetsActor(item: row, repository: repository, actor: actor),
                  let actor else { return nil }
            return GitHubCommandBlocker(
                detail: "GitHub explicitly assigns this decision to the configured contributor (\(label)).",
                owner: actor
            )
        }
        return GitHubCommandObservation(
            repository: repository,
            number: number,
            kind: .issue,
            title: row["title"] as? String ?? "Issue #\(number)",
            isOpen: state == "open",
            observedVersion: "\(updatedAt)|\(state)|\(labels.sorted().joined(separator: ","))",
            humanDecision: decision,
            waitingKind: .maintainer,
            isStale: isStale(updatedAt, hours: staleAfterHours) && state == "open",
            finalReceipt: state == "open" ? nil : "\(repository) #\(number) closed."
        )
    }

    private static func latestReviewState(_ rows: [[String: Any]]) -> String {
        var latestByLogin: [String: [String: Any]] = [:]
        for row in rows {
            guard let login = (row["user"] as? [String: Any])?["login"] as? String else { continue }
            if let existing = latestByLogin[login], timestamp(existing) >= timestamp(row) { continue }
            latestByLogin[login] = row
        }
        let states = latestByLogin.values.compactMap { ($0["state"] as? String)?.uppercased() }
        if states.contains("CHANGES_REQUESTED") { return "changes_requested" }
        if states.contains("APPROVED") { return "approved" }
        if states.contains("COMMENTED") { return "commented" }
        return "review_required"
    }

    private static func checkState(runRows: [[String: Any]], combinedStatus: Any) -> String {
        let conclusions = runRows.compactMap { ($0["conclusion"] as? String)?.lowercased() }
        let failures: Set<String> = [
            "failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale",
        ]
        let combined = (combinedStatus as? [String: Any]) ?? [:]
        let combinedState = (combined["state"] as? String)?.lowercased()
        let contextCount = (combined["total_count"] as? NSNumber)?.intValue
            ?? (combined["statuses"] as? [Any])?.count
            ?? 0
        if conclusions.contains(where: failures.contains)
            || (contextCount > 0 && ["failure", "error"].contains(combinedState ?? "")) { return "failed" }
        if contextCount > 0 && combinedState == "pending" { return "pending" }
        if contextCount > 0 && combinedState == "success" { return "passing" }
        if runRows.contains(where: { (($0["status"] as? String) ?? "").lowercased() != "completed" || $0["conclusion"] == nil }) {
            return "pending"
        }
        return runRows.isEmpty ? "none" : "passing"
    }

    private static func latest(_ rows: [[String: Any]]) -> [String: Any]? {
        rows.max { timestamp($0) < timestamp($1) }
    }

    private static func timestamp(_ row: [String: Any]) -> String {
        row["updated_at"] as? String
            ?? row["submitted_at"] as? String
            ?? row["created_at"] as? String
            ?? ""
    }

    private static func identifier(_ row: [String: Any]) -> String {
        if let value = row["id"] as? NSNumber { return value.stringValue }
        if let value = row["id"] as? Int { return String(value) }
        return timestamp(row)
    }

    private static func numericIdentifier(_ row: [String: Any]) -> Int64? {
        if let value = row["id"] as? Int64 { return value }
        if let value = row["id"] as? Int { return Int64(value) }
        return (row["id"] as? NSNumber)?.int64Value
    }

    private static func reviewThread(
        for comment: [String: Any],
        in evidence: [GitHubCommandReviewThreadEvidence]?
    ) -> GitHubCommandReviewThreadEvidence? {
        guard let evidence else { return nil }
        let commentId = numericIdentifier(comment)
        let replyRoot: Int64? = {
            if let value = comment["in_reply_to_id"] as? Int64 { return value }
            if let value = comment["in_reply_to_id"] as? Int { return Int64(value) }
            return (comment["in_reply_to_id"] as? NSNumber)?.int64Value
        }()
        return evidence.first { thread in
            // A thread without a root comment ID must never correlate: nil == nil
            // would let an unrelated resolved thread suppress a live comment.
            guard let root = thread.rootCommentId else { return false }
            return root == commentId || root == replyRoot
        }
    }

    private static func threadMarker(_ thread: GitHubCommandReviewThreadEvidence) -> String {
        "thread:\(thread.threadId):unresolved:g\(max(1, thread.unresolvedGeneration))"
    }

    private static func reviewStateValue(_ row: [String: Any]) -> String? {
        (row["state"] as? String)?.uppercased()
    }

    private static func actionEvidence(
        signal: GitHubCommandActionSignal,
        row: [String: Any],
        fallback: String
    ) -> GitHubCommandActionEvidence {
        let body = (row["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let line: Int? = {
            if let value = row["line"] as? Int { return value }
            return (row["line"] as? NSNumber)?.intValue
        }()
        return GitHubCommandActionEvidence(
            signal: signal,
            identifier: identifier(row),
            summary: bounded(body?.isEmpty == false ? body! : fallback, limit: 1_200),
            url: row["html_url"] as? String,
            path: row["path"] as? String,
            line: line,
            author: (row["user"] as? [String: Any])?["login"] as? String
        )
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        // Review bodies are evidence, not prompt structure. Flatten whitespace
        // before persistence so repository-controlled text cannot manufacture
        // extra dispatch fields or instructions by inserting line breaks.
        let flattened = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit))
    }

    private static func isStale(_ timestamp: String, hours: Int) -> Bool {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else { return false }
        return Date().timeIntervalSince(date) >= Double(hours * 3_600)
    }
}

public extension GitHubConnectorActions {
    /// Live read used for callback verification and restart recovery.
    static func commandObservation(
        for item: GitHubCommandItem,
        staleAfterHours: Int = 72,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> GitHubCommandObservation {
        let actor: String?
        if let user = try? await validateStoredToken(dataRoot: dataRoot) {
            actor = user["login"] as? String
        } else {
            actor = nil
        }
        switch item.kind {
        case .issue:
            guard let row = try await call(
                path: "repos/\(item.repository)/issues/\(item.number)", dataRoot: dataRoot
            ) as? [String: Any],
            let observation = GitHubCommandObservationBuilder.issue(
                repository: item.repository, row: row, actor: actor,
                staleAfterHours: staleAfterHours
            ) else {
                throw GitHubConnectorError.invalidResponse("tracked issue was not an object")
            }
            return observation
        case .pullRequest:
            let identity = GitHubTrackedPullRequest(
                repository: item.repository,
                number: item.number
            )
            let threadEvidence = try await reviewThreadEvidence(
                for: [identity],
                previous: [item.itemId: item.observation?.reviewThreads ?? []],
                dataRoot: dataRoot
            )[item.itemId] ?? []
            guard let pull = try await call(
                path: "repos/\(item.repository)/pulls/\(item.number)", dataRoot: dataRoot
            ) as? [String: Any] else {
                throw GitHubConnectorError.invalidResponse("tracked pull request was not an object")
            }
            // Reviews/review-comments paginate (bounded at 3 pages,
            // 2026-07-21 audit): page-1-only reads hid a late
            // CHANGES_REQUESTED past the first 100 rows and items settled
            // prematurely.
            let reviews = try await paginatedArray(
                path: "repos/\(item.repository)/pulls/\(item.number)/reviews",
                dataRoot: dataRoot
            )
            let comments = try await paginatedArray(
                path: "repos/\(item.repository)/pulls/\(item.number)/comments",
                dataRoot: dataRoot
            )
            var runs: Any = ["check_runs": []]
            var status: Any = ["statuses": []]
            if let sha = (pull["head"] as? [String: Any])?["sha"] as? String, !sha.isEmpty {
                runs = try await call(
                    path: "repos/\(item.repository)/commits/\(sha)/check-runs",
                    params: ["per_page": "100"], dataRoot: dataRoot
                )
                status = try await call(
                    path: "repos/\(item.repository)/commits/\(sha)/status", dataRoot: dataRoot
                )
            }
            // Only decision-labeled PRs need the newest NON-BOT issue
            // comment (the decision-delivered rule); everything else skips
            // the call. The per-issue endpoint lists ASCENDING and ignores
            // sort/direction, so the newest comments are the LAST page —
            // read it at per_page=10 and skip bot authors (2026-07-21 audit:
            // a bot reply after the actor's answer must not re-arm needs_user).
            var latestIssueCommentAuthor: String? = nil
            let issueCommentCount = GitHubCommandObservationBuilder.issueCommentCount(pull: pull)
            if issueCommentCount > 0, GitHubCommandObservationBuilder.labelDecisionArmed(
                pull: pull, repository: item.repository, actor: actor
            ) {
                let lastPage = (issueCommentCount + 9) / 10
                let latest = try await call(
                    path: "repos/\(item.repository)/issues/\(item.number)/comments",
                    params: ["per_page": "10", "page": String(lastPage)],
                    dataRoot: dataRoot
                )
                latestIssueCommentAuthor = GitHubCommandObservationBuilder.latestNonBotCommentAuthor(latest)
            }
            return GitHubCommandObservationBuilder.pullRequest(
                repository: item.repository, number: item.number, pull: pull,
                reviews: reviews, reviewComments: comments, checkRuns: runs,
                combinedStatus: status, actor: actor, staleAfterHours: staleAfterHours,
                reviewThreads: threadEvidence,
                latestIssueCommentAuthor: latestIssueCommentAuthor
            )
        }
    }
}

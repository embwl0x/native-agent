import Foundation

/// Provider-facing GitHub read models. GitHub's native API objects contain
/// large bodies, duplicate URLs, and nested repository/user payloads; passing
/// them through verbatim can add tens of thousands of tokens per tool call.
enum GitHubToolProjection {
    static let collectionLimit = 20
    static let activityLimit = 20

    struct Collection {
        let rows: [[String: Any]]
        let sourceCount: Int

        var truncated: Bool { sourceCount > rows.count }
    }

    static func repositories(_ raw: Any, limit: Int) -> Collection {
        projectCollection(raw, limit: limit, transform: repository)
    }

    static func issues(_ raw: Any, limit: Int) -> Collection {
        projectCollection(raw, limit: limit, transform: issue)
    }

    static func pullRequests(_ raw: Any, limit: Int) -> Collection {
        projectCollection(raw, limit: limit, transform: pullRequest)
    }

    static func reviews(_ raw: Any, limit: Int) -> Collection {
        projectCollection(raw, limit: limit, transform: review)
    }

    static func commits(_ raw: Any, limit: Int) -> Collection {
        projectCollection(raw, limit: limit, transform: commit)
    }

    static func comments(_ raw: Any, limit: Int) -> Collection {
        projectCollection(raw, limit: limit, transform: comment)
    }

    static func timeline(_ raw: Any, limit: Int) -> Collection {
        projectCollection(raw, limit: limit, transform: timelineEvent)
    }

    static func searchResult(_ raw: Any, limit: Int) -> [String: Any] {
        guard let object = raw as? [String: Any] else {
            return [
                "total_count": 0,
                "incomplete_results": false,
                "items": [],
                "returned_count": 0,
                "results_truncated": false,
            ]
        }
        let projected = issues(object["items"] ?? [], limit: limit)
        let total = integer(object["total_count"]) ?? projected.sourceCount
        return [
            "total_count": total,
            "incomplete_results": boolean(object["incomplete_results"]) ?? false,
            "items": projected.rows,
            "returned_count": projected.rows.count,
            "source_page_count": projected.sourceCount,
            "results_truncated": projected.truncated || total > projected.rows.count,
        ]
    }

    static func user(_ raw: Any?) -> [String: Any] {
        guard let object = raw as? [String: Any] else { return [:] }
        return selecting(object, keys: ["login", "id", "type", "name", "html_url"])
    }

    static func repository(_ object: [String: Any]) -> [String: Any] {
        var out = selecting(object, keys: [
            "id", "name", "full_name", "private", "fork", "archived", "disabled",
            "html_url", "description", "default_branch", "language", "visibility",
            "created_at", "updated_at", "pushed_at", "stargazers_count", "forks_count",
            "open_issues_count",
        ])
        let owner = user(object["owner"])
        if !owner.isEmpty { out["owner"] = owner }
        return out
    }

    static func issue(_ object: [String: Any]) -> [String: Any] {
        var out = selecting(object, keys: [
            "id", "number", "title", "state", "state_reason", "locked", "comments",
            "author_association", "draft", "html_url", "repository_url", "created_at",
            "updated_at", "closed_at",
        ])
        addBody(from: object, to: &out, limit: 1_000)
        let author = user(object["user"])
        if !author.isEmpty { out["user"] = author }
        let labels = compactLabels(object["labels"])
        if !labels.isEmpty { out["labels"] = labels }
        let assignees = compactUsers(object["assignees"])
        if !assignees.isEmpty { out["assignees"] = assignees }
        if let milestone = compactMilestone(object["milestone"]) { out["milestone"] = milestone }
        if let marker = object["pull_request"] as? [String: Any] {
            out["pull_request"] = selecting(marker, keys: ["url", "html_url", "diff_url", "patch_url", "merged_at"])
        }
        return out
    }

    static func pullRequest(_ object: [String: Any]) -> [String: Any] {
        var out = issue(object)
        for (key, value) in selecting(object, keys: [
            "mergeable", "mergeable_state", "merged", "merged_at", "rebaseable",
            "maintainer_can_modify", "additions", "deletions", "changed_files", "commits",
            "review_comments",
        ]) { out[key] = value }
        if let head = compactBranch(object["head"]) { out["head"] = head }
        if let base = compactBranch(object["base"]) { out["base"] = base }
        let reviewers = compactUsers(object["requested_reviewers"])
        if !reviewers.isEmpty { out["requested_reviewers"] = reviewers }
        if let teams = object["requested_teams"] as? [[String: Any]], !teams.isEmpty {
            out["requested_teams"] = teams.prefix(10).map { selecting($0, keys: ["name", "slug", "html_url"]) }
        }
        return out
    }

    private static func review(_ object: [String: Any]) -> [String: Any] {
        var out = selecting(object, keys: ["id", "state", "submitted_at", "html_url", "commit_id", "author_association"])
        addBody(from: object, to: &out, limit: 1_000)
        let author = user(object["user"])
        if !author.isEmpty { out["user"] = author }
        return out
    }

    private static func commit(_ object: [String: Any]) -> [String: Any] {
        var out = selecting(object, keys: ["sha", "html_url"])
        let author = user(object["author"])
        if !author.isEmpty { out["author"] = author }
        if let commit = object["commit"] as? [String: Any] {
            var detail: [String: Any] = [:]
            if let message = commit["message"] as? String {
                detail["message"] = bounded(message, limit: 1_000)
                detail["message_truncated"] = message.count > 1_000
            }
            for key in ["author", "committer"] {
                if let identity = commit[key] as? [String: Any] {
                    detail[key] = selecting(identity, keys: ["name", "email", "date"])
                }
            }
            out["commit"] = detail
        }
        return out
    }

    private static func comment(_ object: [String: Any]) -> [String: Any] {
        var out = selecting(object, keys: [
            "id", "html_url", "created_at", "updated_at", "author_association", "path",
            "line", "side", "start_line", "start_side", "commit_id", "in_reply_to_id",
        ])
        addBody(from: object, to: &out, limit: 1_200)
        if let diff = object["diff_hunk"] as? String {
            out["diff_hunk"] = bounded(diff, limit: 600)
            out["diff_hunk_truncated"] = diff.count > 600
        }
        let author = user(object["user"])
        if !author.isEmpty { out["user"] = author }
        return out
    }

    private static func timelineEvent(_ object: [String: Any]) -> [String: Any] {
        var out = selecting(object, keys: [
            "id", "event", "created_at", "commit_id", "commit_url", "state_reason",
            "dismissed_review", "requested_team",
        ])
        let actor = user(object["actor"])
        if !actor.isEmpty { out["actor"] = actor }
        let assignee = user(object["assignee"])
        if !assignee.isEmpty { out["assignee"] = assignee }
        let reviewer = user(object["requested_reviewer"])
        if !reviewer.isEmpty { out["requested_reviewer"] = reviewer }
        if let label = object["label"] as? [String: Any] {
            out["label"] = selecting(label, keys: ["name", "color"])
        }
        if let milestone = compactMilestone(object["milestone"]) { out["milestone"] = milestone }
        return out
    }

    private static func projectCollection(
        _ raw: Any,
        limit: Int,
        transform: ([String: Any]) -> [String: Any]
    ) -> Collection {
        let source = raw as? [[String: Any]] ?? []
        let cap = max(1, min(collectionLimit, limit))
        return Collection(rows: source.prefix(cap).map(transform), sourceCount: source.count)
    }

    private static func selecting(_ object: [String: Any], keys: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in keys {
            guard let value = object[key], !(value is NSNull) else { continue }
            if value is String || value is NSNumber || value is Bool { out[key] = value }
        }
        return out
    }

    private static func compactUsers(_ raw: Any?) -> [[String: Any]] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.prefix(10).map(user).filter { !$0.isEmpty }
    }

    private static func compactLabels(_ raw: Any?) -> [[String: Any]] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.prefix(12).map { selecting($0, keys: ["name", "color", "description"]) }
    }

    private static func compactMilestone(_ raw: Any?) -> [String: Any]? {
        guard let object = raw as? [String: Any] else { return nil }
        return selecting(object, keys: ["number", "title", "state", "due_on", "html_url"])
    }

    private static func compactBranch(_ raw: Any?) -> [String: Any]? {
        guard let object = raw as? [String: Any] else { return nil }
        var out = selecting(object, keys: ["label", "ref", "sha"])
        if let repo = object["repo"] as? [String: Any] {
            out["repository"] = selecting(repo, keys: ["full_name", "html_url"])
        }
        let owner = user(object["user"])
        if !owner.isEmpty { out["user"] = owner }
        return out
    }

    private static func addBody(from source: [String: Any], to output: inout [String: Any], limit: Int) {
        guard let body = source["body"] as? String else { return }
        output["body"] = bounded(body, limit: limit)
        output["body_characters"] = body.count
        output["body_truncated"] = body.count > limit
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        String(text.prefix(limit))
    }

    private static func integer(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        return nil
    }
}

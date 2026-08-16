import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Connector Actions Registry (static literal port)
//
// Byte-equivalent port of the STATIC `actions` list literal inside
// `NativeAgentRuntime.connector_actions_registry()` at
// the retired daemon (read 2026-05-31). This file
// ports ONLY the static list — the runtime decoration step that adds
// `connectorStatus`, `authState`, and `enabled` per-entry (Python loop
// at lines 21031-21036) is intentionally OUT OF SCOPE here.

public struct ConnectorActionDescriptor: Codable, Sendable, Equatable {
    public var id: String
    public var connectorId: String
    public var connector: String?
    public var name: String?
    public var description: String?
    public var risk: String
    public var dryRunAvailable: Bool
    public var requiresApproval: Bool
    public var category: String?
    public var statusEndpoint: String?
    public var inputSchema: JSONValue?

    public init(
        id: String,
        connectorId: String,
        connector: String? = nil,
        name: String? = nil,
        description: String? = nil,
        risk: String,
        dryRunAvailable: Bool,
        requiresApproval: Bool,
        category: String? = nil,
        statusEndpoint: String? = nil,
        inputSchema: JSONValue? = nil
    ) {
        self.id = id
        self.connectorId = connectorId
        self.connector = connector
        self.name = name
        self.description = description
        self.risk = risk
        self.dryRunAvailable = dryRunAvailable
        self.requiresApproval = requiresApproval
        self.category = category
        self.statusEndpoint = statusEndpoint
        self.inputSchema = inputSchema
    }
}

// Derive parity from the registry itself. A handwritten stamp drifted when
// actions were added in batches, which then broke capability scoring even
// though the descriptors were valid.
public let connectorActionDescriptorsCount: Int = connectorActionDescriptors().count

// MARK: - JSONValue helpers (file-local, schema-building only)

private func schema(_ properties: [(String, JSONValue)], required: [String] = []) -> JSONValue {
    var props: [String: JSONValue] = [:]
    for (k, v) in properties { props[k] = v }
    return .object([
        "type": .string("object"),
        "properties": .object(props),
        "required": .array(required.map { .string($0) }),
    ])
}

private func emptySchema() -> JSONValue {
    .object([
        "type": .string("object"),
        "properties": .object([:]),
        "required": .array([]),
    ])
}

private func prop(_ type: String) -> JSONValue {
    .object(["type": .string(type)])
}

private func prop(_ type: String, description: String) -> JSONValue {
    .object(["type": .string(type), "description": .string(description)])
}

public func connectorActionDescriptors() -> [ConnectorActionDescriptor] {
    return [
        ConnectorActionDescriptor(
            id: "local_files.search", connectorId: "local_files",
            name: "Search Workspaces", risk: "low",
            dryRunAvailable: true, requiresApproval: false
        ),
        ConnectorActionDescriptor(
            id: "searxng.search", connectorId: "searxng",
            name: "Search SearXNG", risk: "low",
            dryRunAvailable: true, requiresApproval: false
        ),
        ConnectorActionDescriptor(
            id: "searxng.fetch", connectorId: "searxng",
            name: "Fetch URL", risk: "low",
            dryRunAvailable: true, requiresApproval: false
        ),
        ConnectorActionDescriptor(
            id: "markets.status", connectorId: "markets", connector: "markets",
            name: "Market Research Status",
            description: "Read Swift-native market research source/watchlist/TradingView readiness without returning API keys, cookies, or tokens.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "markets",
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "markets.watchlists", connectorId: "markets", connector: "markets",
            name: "Market Watchlists",
            description: "Read configured market watchlist groups from Swift, or TradingView watchlists when source='tradingview'. Secrets are never returned.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "markets",
            inputSchema: schema([
                ("source", prop("string")),
                ("group", prop("string")),
                ("includeSymbols", prop("boolean")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "markets.quote", connectorId: "markets", connector: "markets",
            name: "Market Quote Snapshot",
            description: "Fetch a live read-only market quote/technical snapshot through Swift. Default provider is TradingView.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "markets",
            inputSchema: schema([
                ("symbol", prop("string")),
                ("symbols", .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ])),
                ("provider", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "telegram.test", connectorId: "telegram",
            name: "Send Telegram Test", risk: "external_send",
            dryRunAvailable: true, requiresApproval: true
        ),
        // PATCH-2026-05-15: x-connector-1 X API action registrations
        ConnectorActionDescriptor(
            id: "x.status", connectorId: "x", connector: "x",
            name: "X Status",
            description: "Check X OAuth connection status.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "x.me", connectorId: "x", connector: "x",
            name: "X Me",
            description: "Read the authenticated X account profile.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "x.search_recent", connectorId: "x", connector: "x",
            name: "X Recent Search",
            description: "Search recent public X posts.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("query", prop("string")),
                ("max", prop("integer")),
            ], required: ["query"])
        ),
        ConnectorActionDescriptor(
            id: "x.post_tweet", connectorId: "x", connector: "x",
            name: "X Post Tweet",
            description: "Post to X. Requires approval.",
            risk: "external_send", dryRunAvailable: true, requiresApproval: true,
            inputSchema: schema([
                ("text", prop("string")),
                ("replyToTweetId", prop("string")),
            ], required: ["text"])
        ),
        // PATCH-2026-05-16: x-connector-2 timeline + user-tweets reader actions
        ConnectorActionDescriptor(
            id: "x.timeline_home", connectorId: "x", connector: "x",
            name: "X Home Timeline",
            description: "Read the authenticated user's reverse-chronological Following timeline.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("max", prop("integer")),
                ("exclude", prop("string")),
                ("next_token", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "x.user_tweets", connectorId: "x", connector: "x",
            name: "X User Tweets",
            description: "Read a specific user's recent tweets by username or id.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("username", prop("string")),
                ("id", prop("string")),
                ("max", prop("integer")),
                ("exclude", prop("string")),
                ("next_token", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "x.timeline_home_v1", connectorId: "x", connector: "x",
            name: "X Home Timeline (OAuth1)",
            description: "Read your Following timeline via OAuth1-signed v2 call.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("max", prop("integer")),
                ("exclude", prop("string")),
                ("next_token", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "x.user_tweets_v1", connectorId: "x", connector: "x",
            name: "X User Tweets (OAuth1)",
            description: "Read a specific user's recent tweets via OAuth1-signed v2 call.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("username", prop("string")),
                ("id", prop("string")),
                ("max", prop("integer")),
                ("exclude", prop("string")),
                ("next_token", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "github.status", connectorId: "github",
            name: "GitHub Status", risk: "low",
            dryRunAvailable: true, requiresApproval: false
        ),
        // PATCH-2026-05-06: oauth-template real GitHub action registrations
        ConnectorActionDescriptor(
            id: "gh.create_issue", connectorId: "github",
            name: "GitHub Create Issue", risk: "external_write",
            dryRunAvailable: false, requiresApproval: true
        ),
        ConnectorActionDescriptor(
            id: "github.list_repos", connectorId: "github", connector: "github",
            name: "GitHub List Repos", risk: "low",
            dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("limit", prop("integer")),
                ("visibility", prop("string")),
                ("affiliation", prop("string")),
                ("sort", prop("string")),
                ("direction", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "github.list_issues", connectorId: "github", connector: "github",
            name: "GitHub List Issues", risk: "low",
            dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("owner", prop("string")),
                ("repo", prop("string")),
                ("state", prop("string")),
                ("sort", prop("string")),
                ("direction", prop("string")),
                ("limit", prop("integer")),
                ("page", prop("integer")),
                ("labels", prop("string")),
                ("since", prop("string")),
                ("filter", prop("string")),
                ("assignee", prop("string")),
                ("creator", prop("string")),
                ("mentioned", prop("string")),
                ("milestone", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "github.search", connectorId: "github", connector: "github",
            name: "GitHub Search", description: "Search issues and pull requests with GitHub qualifiers.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([("query", prop("string")), ("sort", prop("string")), ("order", prop("string")), ("limit", prop("integer")), ("page", prop("integer"))], required: ["query"])
        ),
        ConnectorActionDescriptor(
            id: "github.list_pull_requests", connectorId: "github", connector: "github",
            name: "GitHub List Pull Requests", description: "List pull requests for a repository.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([("repo", prop("string")), ("state", prop("string")), ("limit", prop("integer")), ("page", prop("integer"))], required: ["repo"])
        ),
        ConnectorActionDescriptor(
            id: "github.get_issue", connectorId: "github", connector: "github",
            name: "GitHub Get Issue", description: "Read one issue and its full metadata.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([("repo", prop("string")), ("number", prop("integer"))], required: ["repo", "number"])
        ),
        ConnectorActionDescriptor(
            id: "github.get_pull_request", connectorId: "github", connector: "github",
            name: "GitHub Get Pull Request", description: "Read one PR with reviews, commits, mergeability, and CI checks.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([("repo", prop("string")), ("number", prop("integer")), ("limit", prop("integer"))], required: ["repo", "number"])
        ),
        ConnectorActionDescriptor(
            id: "github.pull_request_files", connectorId: "github", connector: "github",
            name: "GitHub Pull Request Files", description: "Read bounded paginated changed files and patches.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([("repo", prop("string")), ("number", prop("integer")), ("limit", prop("integer")), ("page", prop("integer")), ("max_patch_characters", prop("integer"))], required: ["repo", "number"])
        ),
        ConnectorActionDescriptor(
            id: "github.pull_request_activity", connectorId: "github", connector: "github",
            name: "GitHub Pull Request Activity", description: "Read comments, reviews, and timeline events.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([("repo", prop("string")), ("number", prop("integer")), ("limit", prop("integer")), ("page", prop("integer"))], required: ["repo", "number"])
        ),
        ConnectorActionDescriptor(
            id: "github.discover_tracking", connectorId: "github", connector: "github",
            name: "Configure GitHub Tracking", description: "Resolve and persist configurable repository tracking.",
            risk: "app_data_write", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([("query", prop("string")), ("project", prop("string")), ("refresh_interval_minutes", prop("integer")), ("stale_after_hours", prop("integer"))])
        ),
        ConnectorActionDescriptor(
            id: "github.project_digest", connectorId: "github", connector: "github",
            name: "GitHub Project Digest", description: "Refresh tracked repositories, Desk refs, and concise status.",
            risk: "app_data_write", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([("refresh", prop("boolean"))])
        ),
        ConnectorActionDescriptor(
            id: "github.set_repo_visibility", connectorId: "github", connector: "github",
            name: "GitHub Set Repo Visibility", risk: "external_write",
            dryRunAvailable: false, requiresApproval: true,
            inputSchema: schema([
                ("owner", prop("string")),
                ("repo", prop("string")),
                ("private", prop("boolean")),
                ("visibility", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "email.draft", connectorId: "email",
            name: "Draft Email", risk: "external_send",
            dryRunAvailable: true, requiresApproval: true
        ),
        ConnectorActionDescriptor(
            id: "calendar.availability", connectorId: "calendar",
            name: "Check Calendar Availability", risk: "low",
            dryRunAvailable: true, requiresApproval: false
        ),
        // PATCH-2026-05-06: connectors-2.1 Gmail action registrations
        ConnectorActionDescriptor(
            id: "gmail.status", connectorId: "email", connector: "email",
            name: "Gmail Status",
            description: "Check Gmail connection status.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "gmail.list_inbox", connectorId: "email", connector: "email",
            name: "Gmail List Inbox",
            description: "List recent inbox messages, optionally filtered by query.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("query", prop("string", description: "Gmail search query, e.g. 'is:unread'.")),
                ("max", prop("integer", description: "Max results (default 10).")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "gmail.read", connectorId: "email", connector: "email",
            name: "Gmail Read Message",
            description: "Read a Gmail message by ID.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("id", prop("string", description: "Gmail message ID.")),
            ], required: ["id"])
        ),
        ConnectorActionDescriptor(
            id: "gmail.draft", connectorId: "email", connector: "email",
            name: "Gmail Create Draft",
            description: "Create a Gmail draft message.",
            risk: "external_send", dryRunAvailable: true, requiresApproval: true,
            inputSchema: schema([
                ("to", prop("string")),
                ("subject", prop("string")),
                ("body", prop("string")),
            ], required: ["to"])
        ),
        ConnectorActionDescriptor(
            id: "gmail.send", connectorId: "email", connector: "email",
            name: "Gmail Send Draft",
            description: "Send a previously created Gmail draft. Requires approval.",
            risk: "external_send", dryRunAvailable: false, requiresApproval: true,
            inputSchema: schema([
                ("draftId", prop("string", description: "Draft ID from gmail.draft.")),
            ], required: ["draftId"])
        ),
        ConnectorActionDescriptor(
            id: "gmail.search", connectorId: "email", connector: "email",
            name: "Gmail Search",
            description: "Search Gmail messages.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("query", prop("string")),
                ("max", prop("integer")),
            ], required: ["query"])
        ),
        // PATCH-2026-05-11: agentmail-1 AgentMail action registrations
        ConnectorActionDescriptor(
            id: "agentmail.status", connectorId: "agentmail", connector: "agentmail",
            name: "AgentMail Status",
            description: "Check AgentMail API key + reachability.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "agentmail.list_inboxes", connectorId: "agentmail", connector: "agentmail",
            name: "AgentMail List Inboxes",
            description: "List inboxes on the AgentMail account.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("max", prop("integer")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "agentmail.list_inbox", connectorId: "agentmail", connector: "agentmail",
            name: "AgentMail List Inbox",
            description: "List recent messages in an AgentMail inbox.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("inboxId", prop("string")),
                ("max", prop("integer")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "agentmail.read", connectorId: "agentmail", connector: "agentmail",
            name: "AgentMail Read Message",
            description: "Read a single AgentMail message by id.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("id", prop("string")),
                ("inboxId", prop("string")),
            ], required: ["id"])
        ),
        ConnectorActionDescriptor(
            id: "agentmail.search", connectorId: "agentmail", connector: "agentmail",
            name: "AgentMail Search",
            description: "Substring search across recent messages in an AgentMail inbox.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("query", prop("string")),
                ("inboxId", prop("string")),
                ("max", prop("integer")),
            ], required: ["query"])
        ),
        ConnectorActionDescriptor(
            id: "agentmail.send", connectorId: "agentmail", connector: "agentmail",
            name: "AgentMail Send",
            description: "Stage an approval to send email from the configured AgentMail inbox.",
            risk: "external_send", dryRunAvailable: true, requiresApproval: true,
            inputSchema: schema([
                ("to", .object(["type": .array([.string("string"), .string("array")])])),
                ("subject", prop("string")),
                ("text", prop("string")),
                ("cc", .object(["type": .array([.string("string"), .string("array")])])),
                ("inboxId", prop("string")),
            ], required: ["to", "subject", "text"])
        ),
        // PATCH-2026-05-06: connectors-2.2 Google Calendar action registrations
        ConnectorActionDescriptor(
            id: "calendar.status", connectorId: "calendar", connector: "calendar",
            name: "Calendar Status",
            description: "Check Google Calendar connection status.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "calendar.list_events", connectorId: "calendar", connector: "calendar",
            name: "Calendar List Events",
            description: "List calendar events in a time range.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("start", prop("string", description: "RFC3339 start datetime.")),
                ("end", prop("string", description: "RFC3339 end datetime.")),
                ("max", prop("integer")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "calendar.create_event", connectorId: "calendar", connector: "calendar",
            name: "Calendar Create Event",
            description: "Create a calendar event. Requires approval.",
            risk: "external_write", dryRunAvailable: false, requiresApproval: true,
            inputSchema: schema([
                ("title", prop("string")),
                ("start", prop("string", description: "RFC3339 datetime.")),
                ("end", prop("string", description: "RFC3339 datetime.")),
                ("attendees", .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ])),
                ("description", prop("string")),
                ("timeZone", prop("string")),
            ], required: ["title", "start", "end"])
        ),
        ConnectorActionDescriptor(
            id: "calendar.find_availability", connectorId: "calendar", connector: "calendar",
            name: "Calendar Find Availability",
            description: "Find free time slots for a meeting.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("duration_min", prop("integer", description: "Required duration in minutes.")),
                ("window_days", prop("integer", description: "Days to look ahead (default 7).")),
            ], required: ["duration_min"])
        ),
        ConnectorActionDescriptor(
            id: "calendar.cancel_event", connectorId: "calendar", connector: "calendar",
            name: "Calendar Cancel Event",
            description: "Cancel/delete a calendar event. Requires approval.",
            risk: "external_write", dryRunAvailable: false, requiresApproval: true,
            inputSchema: schema([
                ("eventId", prop("string")),
            ], required: ["eventId"])
        ),
        // PATCH-2026-05-06: connectors-2.3 Notion action registrations
        ConnectorActionDescriptor(
            id: "notion.status", connectorId: "notion", connector: "notion",
            name: "Notion Status",
            description: "Check Notion connection status.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "notion.search", connectorId: "notion", connector: "notion",
            name: "Notion Search",
            description: "Search pages and databases in Notion.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("query", prop("string")),
                ("max", prop("integer")),
            ], required: ["query"])
        ),
        ConnectorActionDescriptor(
            id: "notion.read_page", connectorId: "notion", connector: "notion",
            name: "Notion Read Page",
            description: "Read a Notion page and its blocks.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("id", prop("string", description: "Notion page ID.")),
            ], required: ["id"])
        ),
        ConnectorActionDescriptor(
            id: "notion.create_page", connectorId: "notion", connector: "notion",
            name: "Notion Create Page",
            description: "Create a new Notion page.",
            risk: "external_write", dryRunAvailable: false, requiresApproval: true,
            inputSchema: schema([
                ("parentId", prop("string", description: "Parent database or page ID.")),
                ("parentType", .object([
                    "type": .string("string"),
                    "enum": .array([.string("database"), .string("page")]),
                ])),
                ("title", prop("string")),
                ("content", prop("string")),
            ], required: ["parentId", "title"])
        ),
        ConnectorActionDescriptor(
            id: "notion.append_block", connectorId: "notion", connector: "notion",
            name: "Notion Append Block",
            description: "Append content to an existing Notion page.",
            risk: "external_write", dryRunAvailable: false, requiresApproval: true,
            inputSchema: schema([
                ("pageId", prop("string")),
                ("content", prop("string")),
            ], required: ["pageId", "content"])
        ),
        ConnectorActionDescriptor(
            id: "notion.query_database", connectorId: "notion", connector: "notion",
            name: "Notion Query Database",
            description: "Query a Notion database with optional filters.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("databaseId", prop("string")),
                ("filter", .object(["type": .string("object")])),
                ("max", prop("integer")),
            ], required: ["databaseId"])
        ),
        // PATCH-2026-05-07: mac-control Mac OS connector action registrations
        ConnectorActionDescriptor(
            id: "mac.spotlight_search", connectorId: "mac", connector: "mac",
            name: "Mac Spotlight Search",
            description: "Search Mac via Spotlight (mdfind). Read-only.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "spotlight",
            inputSchema: schema([
                ("query", prop("string")),
                ("limit", prop("integer")),
            ], required: ["query"])
        ),
        ConnectorActionDescriptor(
            id: "mac.notify", connectorId: "mac", connector: "mac",
            name: "Mac Notification",
            description: "Post a macOS notification.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "notifications",
            inputSchema: schema([
                ("title", prop("string")),
                ("message", prop("string")),
                ("sound", prop("string")),
            ], required: ["title", "message"])
        ),
        ConnectorActionDescriptor(
            id: "mobile.notify", connectorId: "mobile", connector: "mobile",
            name: "iPhone Push Notification",
            description: "Send the user a real APNS push notification on the paired iPhone when attention is useful. Check readiness through /v1/mobile/push/status or tool_catalog connector_actions runtimeStatus; do not inspect raw APNS config files.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "notifications",
            statusEndpoint: "/v1/mobile/push/status",
            inputSchema: schema([
                ("title", prop("string")),
                ("message", prop("string")),
                ("source", prop("string")),
            ], required: ["title", "message"])
        ),
        ConnectorActionDescriptor(
            id: "codex.work_journal", connectorId: "codex_work", connector: "codex_work",
            name: "Codex Work Journal",
            description: "Scan registered workspaces and immediate ~/Projects repositories for recent Codex work: git commits, dirty status, and handoff summaries. Use this to keep a daily cross-project work log. Does not read .env files or crawl arbitrary folders.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "work_journal",
            statusEndpoint: "/v1/codex/work_journal",
            inputSchema: schema([
                ("days", prop("integer")),
                ("persist", prop("boolean")),
                ("roots", .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ])),
                ("includeSelfRepo", prop("boolean")),
                ("includeRegisteredWorkspaces", prop("boolean")),
                ("includeProjectsDirectory", prop("boolean")),
                ("maxProjects", prop("integer")),
                ("maxCommitsPerProject", prop("integer")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "codex.handoff", connectorId: "codex_handoff", connector: "codex_handoff",
            name: "Codex Handoff",
            description: "Read Codex's human-written cross-project markdown handoff for the assistant. Read-only; use this when the assistant needs to know what Codex has done across any project, or schedule it through connector_action. Does not write the handoff and does not read secrets.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "work_journal",
            statusEndpoint: "/v1/codex/handoff",
            inputSchema: schema([
                ("includeText", prop("boolean")),
                ("maxChars", prop("integer")),
                ("maxEntries", prop("integer")),
                ("maxEntryChars", prop("integer")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "scheduler.schedule_job", connectorId: "scheduler", connector: "scheduler",
            name: "Schedule Any Job",
            description: "The agent's general scheduler. Create one-shot or recurring app-owned jobs for any supported job kind on once/every/hourly/daily/weekly/monthly/cron schedules. Notify jobs can choose delivery channels: push, telegram, mac, chat, inbox, activity.",
            risk: "medium", dryRunAvailable: true, requiresApproval: false,
            category: "scheduler",
            inputSchema: schema([
                ("name", prop("string")),
                ("kind", .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("notify"), .string("connector_action"),
                        .string("dream"), .string("rem"), .string("improve"),
                        .string("harness_benchmark"), .string("proactive_scan"),
                    ]),
                ])),
                ("schedule", .object([
                    "type": .string("object"),
                    "description": .string("Schedule spec: {type:'once', run_at}, {type:'every', seconds/minutes/hours/days}, {type:'hourly', minute}, {type:'daily', at:'HH:MM'}, {type:'weekly', weekdays:['mon'], at:'HH:MM'}, {type:'monthly', day:1, at:'HH:MM'}, or {type:'cron', expression:'*/15 9-17 * * mon-fri'}."),
                ])),
                ("payload", .object([
                    "type": .string("object"),
                    "description": .string("Job payload. notify: title/message plus delivery:['push','telegram','mac','chat','inbox','activity'] and optional deliveryOptions per channel. connector_action: actionId/input. improve/dream/rem: objective. proactive_scan: reason/limit/surfaceLimit."),
                ])),
            ], required: ["name", "kind", "schedule"])
        ),
        ConnectorActionDescriptor(
            id: "scheduler.create_job", connectorId: "scheduler", connector: "scheduler",
            name: "Create Scheduled Job",
            description: "Create a lightweight app-owned recurring or one-shot job. Use for reminders, recurring iPhone notifications, safe connector checks, dreams, self-improvement loops, or proactive idea scans.",
            risk: "medium", dryRunAvailable: true, requiresApproval: false,
            category: "scheduler",
            inputSchema: schema([
                ("name", prop("string")),
                ("kind", .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("notify"), .string("connector_action"),
                        .string("dream"), .string("rem"), .string("improve"),
                        .string("harness_benchmark"), .string("proactive_scan"),
                    ]),
                ])),
                ("interval_seconds", prop("integer", description: "Repeat interval in seconds. Minimum 60 for notify/connector jobs.")),
                ("run_at", prop("string", description: "Optional ISO-8601 first run time.")),
                ("one_shot", prop("boolean")),
                ("payload", .object([
                    "type": .string("object"),
                    "description": .string("For notify: title/message. For connector_action: actionId/input. For improve/dream/rem: objective. For proactive_scan: reason/limit/surfaceLimit."),
                ])),
            ], required: ["name", "kind"])
        ),
        ConnectorActionDescriptor(
            id: "scheduler.list_jobs", connectorId: "scheduler", connector: "scheduler",
            name: "List Scheduled Jobs",
            description: "List NativeAgent's app-owned scheduled jobs and their next run times.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "scheduler",
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "scheduler.cancel_job", connectorId: "scheduler", connector: "scheduler",
            name: "Cancel Scheduled Job",
            description: "Disable a NativeAgent scheduled job by id.",
            risk: "medium", dryRunAvailable: true, requiresApproval: false,
            category: "scheduler",
            inputSchema: schema([
                ("jobId", prop("string")),
            ], required: ["jobId"])
        ),
        ConnectorActionDescriptor(
            id: "mac_assistant.watch_templates", connectorId: "mac_assistant", connector: "mac_assistant",
            name: "Mac Assistant Watch Templates",
            description: "Return access readiness and scheduler payload templates for email, calendar, reminders, Mac notifications, and iPhone watch receipts. Read-only; never creates jobs.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "assistant_setup",
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "mac.mail_list_recent", connectorId: "mac", connector: "mac",
            name: "Mac Mail Recent Messages",
            description: "Read recent Mail.app messages through the unified dispatcher. Read-only and scheduleable.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "mac_pim",
            inputSchema: schema([
                ("limit", prop("integer")),
                ("hours_back", prop("integer")),
                ("unread_only", prop("boolean")),
                ("mailbox", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "mac.calendar_list_upcoming", connectorId: "mac", connector: "mac",
            name: "Mac Calendar Upcoming Events",
            description: "Read upcoming Calendar.app events through the unified dispatcher. Read-only and scheduleable.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "mac_pim",
            inputSchema: schema([
                ("hours_ahead", prop("integer")),
                ("calendar_name", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "mac.reminders_list_due_today", connectorId: "mac", connector: "mac",
            name: "Mac Reminders Due Today",
            description: "Read due and overdue Reminders.app items through the unified dispatcher. Read-only and scheduleable.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "mac_pim",
            inputSchema: schema([
                ("include_completed", prop("boolean")),
                ("list_name", prop("string")),
            ])
        ),
        // PATCH-2026-05-24: Phase 8d — Apple-app native surface fill-out (Messages, Notes, Contacts)
        ConnectorActionDescriptor(
            id: "mac.messages_list_recent", connectorId: "mac", connector: "mac",
            name: "Mac Messages Recent",
            description: "Read recent Messages conversations through NativeAgent's app-owned Apple integration. Read-only and scheduleable.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "mac_pim",
            inputSchema: schema([
                ("limit", prop("integer")),
                ("since_hours", prop("integer")),
                ("contact", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "mac.notes_list_recent", connectorId: "mac", connector: "mac",
            name: "Mac Notes Recent",
            description: "Read recently modified Apple Notes through the unified dispatcher. Read-only and scheduleable.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "mac_pim",
            inputSchema: schema([
                ("limit", prop("integer")),
                ("hours_back", prop("integer")),
                ("folder", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "mac.notes_search", connectorId: "mac", connector: "mac",
            name: "Mac Notes Search",
            description: "Search Apple Notes by substring in title or body through the unified dispatcher. Read-only.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "mac_pim",
            inputSchema: schema([
                ("query", prop("string")),
                ("limit", prop("integer")),
            ], required: ["query"])
        ),
        ConnectorActionDescriptor(
            id: "mac.contacts_search", connectorId: "mac", connector: "mac",
            name: "Mac Contacts Search",
            description: "Search Contacts.app by name substring through the unified dispatcher. Read-only.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "mac_pim",
            inputSchema: schema([
                ("query", prop("string")),
                ("limit", prop("integer")),
            ], required: ["query"])
        ),
        ConnectorActionDescriptor(
            id: "mac.run_shortcut", connectorId: "mac", connector: "mac",
            name: "Mac Run Shortcut",
            description: "Run a named macOS Shortcut.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "shortcuts",
            inputSchema: schema([
                ("name", prop("string")),
                ("input", prop("string")),
            ], required: ["name"])
        ),
        ConnectorActionDescriptor(
            id: "mac.list_shortcuts", connectorId: "mac", connector: "mac",
            name: "Mac List Shortcuts",
            description: "List available macOS Shortcuts.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "shortcuts",
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "mac.read_file", connectorId: "mac", connector: "mac",
            name: "Mac Read File",
            description: "Read a file from the Mac filesystem.",
            risk: "medium", dryRunAvailable: true, requiresApproval: false,
            category: "file_ops",
            inputSchema: schema([
                ("path", prop("string")),
                ("max_bytes", prop("integer")),
            ], required: ["path"])
        ),
        ConnectorActionDescriptor(
            id: "mac.write_file", connectorId: "mac", connector: "mac",
            name: "Mac Write File",
            description: "Write or append to a file on the Mac filesystem. Requires approval.",
            risk: "high", dryRunAvailable: false, requiresApproval: true,
            category: "file_ops",
            inputSchema: schema([
                ("path", prop("string")),
                ("content", prop("string")),
                ("append", prop("boolean")),
            ], required: ["path", "content"])
        ),
        ConnectorActionDescriptor(
            id: "mac.list_directory", connectorId: "mac", connector: "mac",
            name: "Mac List Directory",
            description: "List directory contents on Mac.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "file_ops",
            inputSchema: schema([
                ("path", prop("string")),
            ], required: ["path"])
        ),
        ConnectorActionDescriptor(
            id: "mac.applescript", connectorId: "mac", connector: "mac",
            name: "Mac AppleScript",
            description: "Run an AppleScript. Requires approval.",
            risk: "high", dryRunAvailable: true, requiresApproval: true,
            category: "applescript",
            inputSchema: schema([
                ("script", prop("string")),
                ("timeout", prop("integer")),
            ], required: ["script"])
        ),
        ConnectorActionDescriptor(
            id: "mac.jxa", connectorId: "mac", connector: "mac",
            name: "Mac JXA",
            description: "Run JavaScript for Automation. Requires approval.",
            risk: "high", dryRunAvailable: true, requiresApproval: true,
            category: "jxa",
            inputSchema: schema([
                ("script", prop("string")),
                ("timeout", prop("integer")),
            ], required: ["script"])
        ),
        ConnectorActionDescriptor(
            id: "mac.focus_app", connectorId: "mac", connector: "mac",
            name: "Mac Focus App",
            description: "Bring an app to front by bundle ID. Requires approval.",
            risk: "medium", dryRunAvailable: false, requiresApproval: true,
            category: "accessibility",
            inputSchema: schema([
                ("bundle_id", prop("string")),
            ], required: ["bundle_id"])
        ),
        ConnectorActionDescriptor(
            id: "mac.quit_app", connectorId: "mac", connector: "mac",
            name: "Mac Quit App",
            description: "Quit an app by bundle ID. Requires approval.",
            risk: "high", dryRunAvailable: false, requiresApproval: true,
            category: "accessibility",
            inputSchema: schema([
                ("bundle_id", prop("string")),
                ("force", prop("boolean")),
            ], required: ["bundle_id"])
        ),
        ConnectorActionDescriptor(
            id: "mac.running_apps", connectorId: "mac", connector: "mac",
            name: "Mac Running Apps",
            description: "List running apps on Mac.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "spotlight",
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "mac.set_volume", connectorId: "mac", connector: "mac",
            name: "Mac Set Volume",
            description: "Set Mac output volume (0–100). Requires approval.",
            risk: "medium", dryRunAvailable: false, requiresApproval: true,
            category: "system",
            inputSchema: schema([
                ("percent", prop("integer")),
            ], required: ["percent"])
        ),
        ConnectorActionDescriptor(
            id: "mac.sleep_display", connectorId: "mac", connector: "mac",
            name: "Mac Sleep Display",
            description: "Sleep the Mac display. Requires approval.",
            risk: "medium", dryRunAvailable: false, requiresApproval: true,
            category: "system",
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "mac.lock_screen", connectorId: "mac", connector: "mac",
            name: "Mac Lock Screen",
            description: "Lock the Mac screen. Requires approval.",
            risk: "medium", dryRunAvailable: false, requiresApproval: true,
            category: "system",
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "mac.shell", connectorId: "mac", connector: "mac",
            name: "Mac Shell Command",
            description: "Run a shell command on Mac. Requires approval. Most dangerous gate.",
            risk: "critical", dryRunAvailable: false, requiresApproval: true,
            category: "shell",
            inputSchema: schema([
                ("command", prop("string")),
                ("timeout", prop("integer")),
                ("cwd", prop("string")),
            ], required: ["command"])
        ),
        // PATCH-2026-05-08: review-fix-A.5 — re-register direct mc.* routes
        ConnectorActionDescriptor(
            id: "mac.keystroke", connectorId: "mac", connector: "mac",
            name: "Mac Keystroke",
            description: "Type text and/or press key combinations on this Mac, as if from the physical keyboard. The keystrokes go to whatever app is frontmost. Requires approval.",
            risk: "high", dryRunAvailable: false, requiresApproval: true,
            category: "accessibility",
            inputSchema: schema([
                ("text", prop("string")),
                ("keys", prop("string")),
                ("attention_session", prop("string")),
                ("attention_user_sequence", prop("integer")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "mac.click", connectorId: "mac", connector: "mac",
            name: "Mac Click",
            description: "Click, double-click, right-click or drag at screen coordinates, as if from the physical mouse. Requires approval.",
            risk: "high", dryRunAvailable: false, requiresApproval: true,
            category: "accessibility",
            inputSchema: schema([
                ("x", prop("integer")),
                ("y", prop("integer")),
                ("button", prop("string")),
                ("count", prop("integer")),
                ("double", prop("boolean")),
                ("from", prop("object")),
                ("to", prop("object")),
                ("duration_ms", prop("integer")),
                ("mark", prop("integer")),
                ("view", prop("string")),
                ("attention_session", prop("string")),
                ("attention_user_sequence", prop("integer")),
            ])
        ),
        // W2/W3 injection surface (2026-08-12). Same `accessibility` category,
        // same high risk and approval tier as the two above — these synthesize
        // real input. `mac.ax_act` is the semantic one: it targets an element by
        // the path mac.ax_tree/mac.ax_find returned, so the app runs its own
        // handler instead of a coordinate being guessed at.
        ConnectorActionDescriptor(
            id: "mac.scroll", connectorId: "mac", connector: "mac",
            name: "Mac Scroll",
            description: "Scroll the view under the pointer, as if from the physical mouse wheel or trackpad. Requires approval.",
            risk: "high", dryRunAvailable: false, requiresApproval: true,
            category: "accessibility",
            inputSchema: schema([
                ("dx", prop("integer")),
                ("dy", prop("integer")),
                ("x", prop("integer")),
                ("y", prop("integer")),
                ("units", prop("string")),
                ("attention_session", prop("string")),
                ("attention_user_sequence", prop("integer")),
            ])
        ),
        // W6 (2026-08-12). Same category, same approval tier: it posts a real
        // mouse event. It refuses outright when the screen is password-locked.
        ConnectorActionDescriptor(
            id: "mac.wake", connectorId: "mac", connector: "mac",
            name: "Mac Wake Screen",
            description: "Dismiss a screensaver or wake a sleeping display with a one-point mouse nudge, then return a fresh view of the real screen. Refuses when the Mac is password-locked — it never bypasses a lock. Requires approval.",
            risk: "high", dryRunAvailable: false, requiresApproval: true,
            category: "accessibility",
            inputSchema: schema([
                ("key_tap", prop("boolean")),
                ("settle_ms", prop("integer")),
                ("full_screen", prop("boolean")),
                ("attention_session", prop("string")),
                ("attention_user_sequence", prop("integer")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "mac.ax_act", connectorId: "mac", connector: "mac",
            name: "Mac Accessibility Act",
            description: "Act on one UI element of the frontmost window, addressed by the path from mac.ax_tree or mac.ax_find: press it, or set its value. Runs the app's own accessibility handler; falls back to a synthesized click at the element's centre when the element exposes no usable action. Requires approval.",
            risk: "high", dryRunAvailable: false, requiresApproval: true,
            category: "accessibility",
            inputSchema: schema([
                ("path", prop("array")),
                ("action", prop("string")),
                ("value", prop("string")),
                ("mark", prop("integer")),
                ("view", prop("string")),
                ("attention_session", prop("string")),
                ("attention_user_sequence", prop("integer")),
            ])
        ),
        // W1 accessibility perception organ — READ-ONLY. These read the
        // AXUIElement tree (structured UI data) instead of screenshotting
        // pixels. No input injection: risk low, no approval, same read tier as
        // mac.spotlight_search, under the existing `accessibility` gate.
        ConnectorActionDescriptor(
            id: "mac.ax_status", connectorId: "mac", connector: "mac",
            name: "Mac Accessibility Status",
            description: "Check whether NativeAgent has macOS Accessibility permission. Read-only. Returns trusted:true/false plus how to grant it.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: emptySchema()
        ),
        // W7 — the NUDGE. Low risk and no approval, alongside the reads rather
        // than the injection actions: it posts one bare mouse move, which
        // clicks nothing, types nothing and unlocks nothing. Same
        // `accessibility` gate category as everything else in this organ.
        ConnectorActionDescriptor(
            id: "mac.nudge", connectorId: "mac", connector: "mac",
            name: "Mac Nudge",
            description: "Post a single bare mouse move (one point) to wake a sleeping display or dismiss a screensaver — the software equivalent of bumping the mouse. It cannot click, type, scroll, drag or unlock; on a locked Mac it only brings up the login field. Takes no arguments.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "mac.ax_tree", connectorId: "mac", connector: "mac",
            name: "Mac Accessibility Tree",
            description: "Read the frontmost app's frontmost window as a structured accessibility tree (role, title, value, enabled, frame, available actions, path). Read-only; bounded to 400 nodes / depth 12 and reports honestly when truncated.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([
                ("max_nodes", prop("integer")),
                ("max_depth", prop("integer")),
            ])
        ),
        // W3.5 — the FUSED view: the screenshot and the AX structure in one
        // object, with every actionable element numbered on the image so she
        // acts by name instead of guessing a coordinate. Read tier like the
        // three above; the picture half additionally needs the macOS Screen
        // Recording grant, which the result reports rather than hiding.
        ConnectorActionDescriptor(
            id: "mac.view", connectorId: "mac", connector: "mac",
            name: "Mac Fused View",
            description: "See the frontmost window as one fused view: a screenshot with every clickable and scrollable element outlined and numbered, plus a legend tying each number to that element's real role, label, frame and accessibility path. Read-only. Needs macOS Screen Recording permission for the picture; without it the numbered legend still comes back.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([
                ("full_screen", prop("boolean")),
                ("max_marks", prop("integer")),
                ("max_text_items", prop("integer")),
                ("max_image_bytes", prop("integer")),
                ("max_nodes", prop("integer")),
                ("max_depth", prop("integer")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "mac.attention", connectorId: "mac", connector: "mac",
            name: "Mac Attention",
            description: "Start, continue, inspect or stop a bounded live-attention session over the fused Mac view. It notices coarse physical input and app changes without recording key contents; user input invalidates the old view and wins immediately. Read-only and ephemeral.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([
                ("mode", prop("string")),
                ("session", prop("string")),
                ("after_sequence", prop("integer")),
                ("wait_ms", prop("integer")),
                ("duration_seconds", prop("integer")),
                ("full_screen", prop("boolean")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "mac.ax_find", connectorId: "mac", connector: "mac",
            name: "Mac Accessibility Find",
            description: "Find UI elements in the frontmost window by role, title substring (case-insensitive), and/or value. Read-only; returns up to 20 matches ranked by match quality with their frame and path.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([
                ("role", prop("string")),
                ("title", prop("string")),
                ("value", prop("string")),
                ("limit", prop("integer")),
            ])
        ),
        // W7 (2026-08-14) — the ambient activity watcher's ONLY read path.
        //
        // Its own `activity` category rather than `accessibility`: the two are
        // unrelated gates. Accessibility governs reading/driving the LIVE
        // screen; this reads a local rollup of app+duration metadata the user
        // separately opted into recording, and its real gate is the Trust
        // Center capture toggle, which the impl re-checks and refuses on.
        // Low risk, no approval — it is a read of the user's own local data.
        // MAC-LOCAL: the impl refuses this action on any remote surface.
        ConnectorActionDescriptor(
            id: "activity.query", connectorId: "activity", connector: "activity",
            name: "Activity Query",
            description: "Summarise which apps were in use over a time range, from the locally-recorded activity log (app name + duration, and a secret-redacted window title only where the user enabled titles). Read-only, deterministic, Mac-local: refused on iPhone/Telegram/Slack surfaces. Returns rollup rows plus a few example spans, capped at 50 rows with any truncation stated. Refused entirely when Activity Capture is off in Trust Center.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "activity",
            inputSchema: schema([
                ("range", prop("string")),
                ("from", prop("string")),
                ("to", prop("string")),
                ("bundle_id", prop("string")),
                ("timezone", prop("string")),
                ("limit", prop("integer")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "mac.move_file", connectorId: "mac", connector: "mac",
            name: "Mac Move File",
            description: "Move a file. Requires approval.",
            risk: "high", dryRunAvailable: true, requiresApproval: true,
            category: "file_ops",
            inputSchema: schema([
                ("src", prop("string")),
                ("dst", prop("string")),
            ], required: ["src", "dst"])
        ),
        ConnectorActionDescriptor(
            id: "mac.trash_file", connectorId: "mac", connector: "mac",
            name: "Mac Trash File",
            description: "Move a file to the macOS Trash. Requires approval.",
            risk: "high", dryRunAvailable: true, requiresApproval: true,
            category: "file_ops",
            inputSchema: schema([
                ("path", prop("string")),
            ], required: ["path"])
        ),
        ConnectorActionDescriptor(
            id: "mac.set_brightness", connectorId: "mac", connector: "mac",
            name: "Mac Set Brightness",
            description: "Set Mac display brightness (0–100). Requires approval.",
            risk: "medium", dryRunAvailable: false, requiresApproval: true,
            category: "system",
            inputSchema: schema([
                ("percent", prop("integer")),
            ], required: ["percent"])
        ),
        ConnectorActionDescriptor(
            id: "mac.set_focus_mode", connectorId: "mac", connector: "mac",
            name: "Mac Set Focus Mode",
            description: "Set macOS Focus mode by name. Requires approval.",
            risk: "medium", dryRunAvailable: false, requiresApproval: true,
            category: "system",
            inputSchema: schema([
                ("name", prop("string")),
            ], required: ["name"])
        ),
        // Phase 13 (item 5): mac.self_test through run_connector_action
        ConnectorActionDescriptor(
            id: "mac.self_test", connectorId: "mac", connector: "mac",
            name: "Mac Self-Test",
            description: "Run a safe read-only self-test of the Mac Control bridge.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "system",
            inputSchema: emptySchema()
        ),
        // PATCH-2026-05-06: connectors-2.4 Slack action registrations
        ConnectorActionDescriptor(
            id: "slack.status", connectorId: "slack", connector: "slack",
            name: "Slack Status",
            description: "Check Slack connection status.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "slack.list_channels", connectorId: "slack", connector: "slack",
            name: "Slack List Channels",
            description: "List Slack channels accessible to the bot.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("limit", prop("integer")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "slack.search_messages", connectorId: "slack", connector: "slack",
            name: "Slack Search Messages",
            description: "Search Slack messages.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: schema([
                ("query", prop("string")),
                ("count", prop("integer")),
            ], required: ["query"])
        ),
        ConnectorActionDescriptor(
            id: "slack.post_message", connectorId: "slack", connector: "slack",
            name: "Slack Post Message",
            description: "Stage an approval to post a message to a Slack channel.",
            risk: "external_send", dryRunAvailable: false, requiresApproval: true,
            inputSchema: schema([
                ("channel", prop("string", description: "Channel ID or name.")),
                ("text", prop("string")),
            ], required: ["channel", "text"])
        ),
        ConnectorActionDescriptor(
            id: "slack.list_unreads", connectorId: "slack", connector: "slack",
            name: "Slack List Unreads",
            description: "List Slack channels with unread messages.",
            risk: "low", dryRunAvailable: false, requiresApproval: false,
            inputSchema: emptySchema()
        ),
    ]
}

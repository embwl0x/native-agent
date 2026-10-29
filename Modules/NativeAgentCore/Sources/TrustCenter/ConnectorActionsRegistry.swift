import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ConnectorActionsRegistry.swift` | `ConnectorActionDescriptor` and `connectorActionDescriptors`: static connector action/schema inventory; live authentication decoration belongs elsewhere |

// MARK: - Static connector action descriptors

// Runtime decoration supplies `connectorStatus`, `authState` and `enabled`.

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
            description: "Send the user a real APNS push notification on the paired iPhone when attention is useful. Check readiness on app {page:\"pairing\"}; do not inspect raw APNS config files.",
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
                        .string("dream"), .string("rem"),
                        .string("harness_benchmark"), .string("proactive_scan"),
                    ]),
                ])),
                ("schedule", .object([
                    "type": .string("object"),
                    "description": .string("Schedule spec: {type:'once', run_at}, {type:'every', seconds/minutes/hours/days}, {type:'hourly', minute}, {type:'daily', at:'HH:MM'}, {type:'weekly', weekdays:['mon'], at:'HH:MM'}, {type:'monthly', day:1, at:'HH:MM'}, or {type:'cron', expression:'*/15 9-17 * * mon-fri'}."),
                ])),
                ("payload", .object([
                    "type": .string("object"),
                    "description": .string("Job payload. notify: title/message plus delivery:['push','telegram','mac','chat','inbox','activity'] and optional deliveryOptions per channel. connector_action: actionId/input. dream/rem: objective. proactive_scan: reason/limit/surfaceLimit."),
                ])),
            ], required: ["name", "kind", "schedule"])
        ),
        ConnectorActionDescriptor(
            id: "scheduler.create_job", connectorId: "scheduler", connector: "scheduler",
            name: "Create Scheduled Job",
            description: "Create a lightweight app-owned recurring or one-shot job. Use for reminders, recurring iPhone notifications, safe connector checks, dreams, REM cycles, or proactive idea scans.",
            risk: "medium", dryRunAvailable: true, requiresApproval: false,
            category: "scheduler",
            inputSchema: schema([
                ("name", prop("string")),
                ("kind", .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("notify"), .string("connector_action"),
                        .string("dream"), .string("rem"),
                        .string("harness_benchmark"), .string("proactive_scan"),
                    ]),
                ])),
                ("interval_seconds", prop("integer", description: "Repeat interval in seconds. Minimum 60 for notify/connector jobs.")),
                ("run_at", prop("string", description: "Optional ISO-8601 first run time.")),
                ("one_shot", prop("boolean")),
                ("payload", .object([
                    "type": .string("object"),
                    "description": .string("For notify: title/message. For connector_action: actionId/input. For dream/rem: objective. For proactive_scan: reason/limit/surfaceLimit."),
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
            description: "Read Reminders.app items in today and overdue parts, each with its full count and independently capped reminders/has_more, plus total, summary and the legacy reminders union. Read-only and scheduleable.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "mac_pim",
            inputSchema: schema([
                ("limit", prop("integer")),
                ("include_completed", prop("boolean")),
                ("list_name", prop("string")),
            ])
        ),
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
    ]
}

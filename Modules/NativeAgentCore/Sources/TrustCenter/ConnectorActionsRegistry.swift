import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ConnectorActionsRegistry.swift` | `ConnectorActionDescriptor`, `connectorActionDescriptors`; Static schemas. |

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
            id: "codex.work_journal", connectorId: "codex_work", connector: "codex_work",
            name: "Codex Work Journal",
            description: """
                Scan registered workspaces and immediate ~/Projects repositories for recent Codex work: git commits, dirty status, and handoff \
                summaries. Use this to keep a daily cross-project work log. Does not read .env files or crawl arbitrary folders.
                """,
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
            description: """
                Read Codex's human-written cross-project markdown handoff for the assistant. Read-only; use this when the assistant needs to know \
                what Codex has done across any project, or schedule it through connector_action. Does not write the handoff and does not read secrets.
                """,
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
            name: "Schedule a Read",
            description: """
                Put a watch or proactive scan on the clock, once or on an every/hourly/daily/weekly/monthly/cron rhythm. Intentions, check-ins and \
                reminders use queue.add {text, when, until?, say?}.
                """,
            risk: "medium", dryRunAvailable: true, requiresApproval: false,
            category: "scheduler",
            inputSchema: schema([
                ("name", prop("string")),
                ("kind", .object([
                    "type": .string("string"),
                    "enum": .array([.string("connector_action"), .string("proactive_scan")]),
                    "description": .string("A watch (connector_action) or a proactive scan. Intentions, check-ins and reminders use queue.add."),
                ])),
                ("schedule", .object([
                    "type": .string("object"),
                    "description": .string("""
                        Schedule spec: {type:'once', run_at}, {type:'every', seconds/minutes/hours/days}, {type:'hourly', minute}, {type:'daily', \
                        at:'HH:MM'}, {type:'weekly', weekdays:['mon'], at:'HH:MM'}, {type:'monthly', day:1, at:'HH:MM'}, or {type:'cron', \
                        expression:'*/15 9-17 * * mon-fri'}.
                        """),
                ])),
                ("payload", .object([
                    "type": .string("object"),
                    "description": .string("""
                        connector_action: actionId (a read) and input. proactive_scan: reason/limit/surfaceLimit/staleDays. For fixed reminder words \
                        use queue.add with say.
                        """),
                ])),
            ], required: ["name", "kind", "schedule"])
        ),
        ConnectorActionDescriptor(
            id: "scheduler.create_job", connectorId: "scheduler", connector: "scheduler",
            name: "Create a Scheduled Read",
            description: """
                Put a watch or proactive scan on the clock: a repeating interval, or one read after in_minutes. Intentions, check-ins and \
                reminders use queue.add {text, when, until?, say?}.
                """,
            risk: "medium", dryRunAvailable: true, requiresApproval: false,
            category: "scheduler",
            inputSchema: schema([
                ("name", prop("string")),
                ("kind", .object([
                    "type": .string("string"),
                    "enum": .array([.string("connector_action"), .string("proactive_scan")]),
                    "description": .string("A watch (connector_action) or a proactive scan. Intentions, check-ins and reminders use queue.add."),
                ])),
                ("interval_seconds", prop("integer", description: "Repeat interval in seconds. Minimum 60. Supply this or in_minutes.")),
                ("in_minutes", prop("number", description: "One read after this many minutes. Supply this or interval_seconds.")),
                ("payload", .object([
                    "type": .string("object"),
                    "description": .string("""
                        For connector_action: actionId (a read) and input. For proactive_scan: reason/limit/surfaceLimit/staleDays. Intentions use \
                        queue.add.
                        """),
                ])),
            ], required: ["name", "kind"])
        ),
        ConnectorActionDescriptor(
            id: "scheduler.list_jobs", connectorId: "scheduler", connector: "scheduler",
            name: "List Scheduled Reads",
            description: "List the watches and proactive scans on NativeAgent's clock and their next times.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "scheduler",
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "scheduler.cancel_job", connectorId: "scheduler", connector: "scheduler",
            name: "Cancel a Scheduled Read",
            description: "Withdraw a watch or proactive scan from NativeAgent's clock by id.",
            risk: "medium", dryRunAvailable: true, requiresApproval: false,
            category: "scheduler",
            inputSchema: schema([
                ("jobId", prop("string")),
            ], required: ["jobId"])
        ),
        ConnectorActionDescriptor(
            id: "mac_assistant.watch_templates", connectorId: "mac_assistant", connector: "mac_assistant",
            name: "Mac Assistant Watch Templates",
            description: """
                Return access readiness and scheduler payload templates for email, calendar, reminders, Mac notifications, and iPhone watch receipts. \
                Read-only; never creates jobs.
                """,
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "assistant_setup",
            inputSchema: emptySchema()
        ),
    ]
}

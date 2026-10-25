import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ConnectorActionsRegistry.swift` | `ConnectorActionDescriptor` and `connectorActionDescriptors`: static connector action/schema inventory; live authentication decoration belongs elsewhere |

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
            id: "telegram.test", connectorId: "telegram",
            name: "Send Telegram Test", risk: "external_send",
            dryRunAvailable: true, requiresApproval: true
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
            description: "Write or append to a file on the Mac filesystem. Standard modes prompt; admitted Full Mac YOLO runs directly.",
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
            description: "Run an AppleScript. Standard modes prompt; admitted Full Mac YOLO runs directly.",
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
            description: "Run JavaScript for Automation. Standard modes prompt; admitted Full Mac YOLO runs directly.",
            risk: "high", dryRunAvailable: true, requiresApproval: true,
            category: "jxa",
            inputSchema: schema([
                ("script", prop("string")),
                ("timeout", prop("integer")),
            ], required: ["script"])
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
            description: "Set Mac output volume (0–100). Standard modes prompt; admitted Full Mac YOLO runs directly.",
            risk: "medium", dryRunAvailable: false, requiresApproval: true,
            category: "system",
            inputSchema: schema([
                ("percent", prop("integer")),
            ], required: ["percent"])
        ),
        ConnectorActionDescriptor(
            id: "mac.sleep_display", connectorId: "mac", connector: "mac",
            name: "Mac Sleep Display",
            description: "Sleep the Mac display. Standard modes prompt; admitted Full Mac YOLO runs directly.",
            risk: "medium", dryRunAvailable: false, requiresApproval: true,
            category: "system",
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "mac.lock_screen", connectorId: "mac", connector: "mac",
            name: "Mac Lock Screen",
            description: "Lock the Mac screen. Standard modes prompt; admitted Full Mac YOLO runs directly.",
            risk: "medium", dryRunAvailable: false, requiresApproval: true,
            category: "system",
            inputSchema: emptySchema()
        ),
        ConnectorActionDescriptor(
            id: "mac.shell", connectorId: "mac", connector: "mac",
            name: "Mac Shell Command",
            description: "Run a shell command on Mac. Standard modes prompt; admitted Full Mac YOLO runs directly. Hard safety boundaries still refuse.",
            risk: "critical", dryRunAvailable: false, requiresApproval: true,
            category: "shell",
            inputSchema: schema([
                ("command", prop("string")),
                ("timeout", prop("integer")),
                ("cwd", prop("string")),
            ], required: ["command"])
        ),
        // W6 (2026-08-12). Same category, same approval tier: it posts a real
        // mouse event. It refuses outright when the screen is password-locked.
        ConnectorActionDescriptor(
            id: "mac.wake", connectorId: "mac", connector: "mac",
            name: "Mac Wake Screen",
            description: "Dismiss a screensaver or wake a sleeping display with a one-point mouse nudge, then return a fresh view of the real screen. Refuses when the Mac is password-locked — it never bypasses a lock. Standard modes prompt; admitted Full Mac YOLO runs directly.",
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
        // native-look item 3 (2026-08-22) — the CLOSED-LOOP verb. Same
        // category, same high risk, same approval tier as its neighbours: it
        // presses and types through the same actuator. The percept it returns
        // afterwards is evidence of the effect, never a reason for a lower
        // tier.
        // W1 accessibility perception organ — READ-ONLY. These read the
        // AXUIElement tree (structured UI data) instead of screenshotting
        // pixels. No input injection: risk low, no approval, same read tier as
        // mac.spotlight_search, under the existing `accessibility` gate.
        // W7 — the NUDGE. Low risk and no approval, alongside the reads rather
        // than the injection actions: it posts one bare mouse move, which
        // clicks nothing, types nothing and unlocks nothing. Same
        // `accessibility` gate category as everything else in this organ.
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
        // native-look item 2 (2026-08-22) — the compiled LOOK: the AX tree
        // distilled by the app into a glance line / a structured percept with
        // stable handles / the raw tree, so she pays tokens for the answer,
        // not the parsing. Read tier with no picture, so no
        // Screen Recording dependency.
        ConnectorActionDescriptor(
            id: "mac.screen", connectorId: "mac", connector: "mac",
            name: "Screen",
            description: "The live screen in words: app, position, content as numbered rows, actionable controls, status text. Read-only; nothing held, nothing expires. `part` zooms to a named section; `app` reads another running app's front window without activating it.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([("part", prop("string")), ("app", prop("string"))])
        ),
        // fable51 item 30 — THE CLIPBOARD ORGAN. The read is low risk and
        // dry-runnable like the perception rows above it; the write is medium,
        // beside `mac.act_by_name`, because it replaces what the next paste in
        // any app will produce.
        ConnectorActionDescriptor(
            id: "mac.clipboard_read", connectorId: "mac", connector: "mac",
            name: "Clipboard Read",
            description: "Read Mac clipboard text. Redacts secret lines (password/API key/one-time code/card number/recovery phrase), stating why. Non-text returns type/size, never bytes. Read-only.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([("max_chars", prop("integer"))])
        ),
        ConnectorActionDescriptor(
            id: "mac.clipboard_write", connectorId: "mac", connector: "mac",
            name: "Clipboard Write",
            description: "Replace Mac clipboard text: next paste uses it and previous contents are lost. No keystrokes/clicks. Returns character count and read-back check, never text.",
            risk: "medium", dryRunAvailable: false, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([("text", prop("string"))])
        ),
        // fable51 item 33 — THE READ ORGAN. Low risk and dry-runnable with the
        // perception rows: it returns what a document says and puts the scroll
        // position back where it found it. It is not a file tool — the file it
        // reads is the one already open in front of her, and an explicit path
        // additionally clears Full Mac file access at dispatch.
        ConnectorActionDescriptor(
            id: "mac.read", connectorId: "mac", connector: "mac",
            name: "Read",
            description: "Read a front-window PDF/text file end to end via PDFKit extraction, not scraping; or merge the window's text across overlapping scrolls. Scrolls only for more content, then back. Redacts secret-shaped lines with reasons; password-protected/text-less documents refuse in words.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([("path", prop("string"))])
        ),
        // fable51 item 29 — the menu bar organ. The walk is low risk and
        // dry-runnable like the perception rows; the press runs the app's own
        // handler and sits at medium beside mac.act_by_name.
        ConnectorActionDescriptor(
            id: "mac.menu", connectorId: "mac", connector: "mac",
            name: "Menu Bar",
            description: "List an app's menu bar as nameable paths (File › Export › PDF…), bounded to three levels. Read-only and it opens no menu — the paths come from the published accessibility tree. Greyed-out items are listed as present-but-disabled, never omitted.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([("app", prop("string"))])
        ),
        ConnectorActionDescriptor(
            id: "mac.menu_press", connectorId: "mac", connector: "mac",
            name: "Menu Press",
            description: "Press one named menu path (File › Export › PDF…) through the shared Mac actuator. Unknown, ambiguous and disabled paths refuse in words and press nothing.",
            risk: "medium", dryRunAvailable: false, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([("path", prop("string")), ("app", prop("string"))])
        ),
        ConnectorActionDescriptor(
            id: "mac.act_by_name", connectorId: "mac", connector: "mac",
            name: "Act",
            description: "Do one thing to something on the live screen by NAME (click/open/type/select/toggle/scroll/dismiss). Resolves against a fresh look at act time; ambiguity is returned as a question and nothing is touched. Drives the gated closed loop.",
            risk: "medium", dryRunAvailable: false, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([
                ("verb", prop("string")),
                ("target", prop("string")),
                ("text", prop("string")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "mac.go", connectorId: "mac", connector: "mac",
            name: "Go",
            description: "Move to an app (switch or launch), a file/folder path, or an http/https URL, then read the fresh screen. App activation is verified; a path or URL is only reported as an accepted open request unless the screen proves where it landed.",
            risk: "medium", dryRunAvailable: false, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([("name", prop("string"))])
        ),
        ConnectorActionDescriptor(
            id: "mac.wait", connectorId: "mac", connector: "mac",
            name: "Wait",
            description: "Watch the screen (bounded, max 60s) until it settles or named text appears; honest timeout. Read-only.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([
                ("until", prop("string")),
                ("seconds", prop("integer")),
            ])
        ),
        ConnectorActionDescriptor(
            id: "mac.look", connectorId: "mac", connector: "mac",
            name: "Mac Look",
            description: "Look at the frontmost window at one of three grades: glance (one distilled line), look (the structured percept: focus, modal, landmarks, every labeled control with a stable handle and its element path), or stare (the raw accessibility tree). Read-only; unlabeled controls are counted by role, never hidden.",
            risk: "low", dryRunAvailable: true, requiresApproval: false,
            category: "accessibility",
            inputSchema: schema([
                ("grade", prop("string")),
                ("max_affordances", prop("integer")),
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
        // W7 (2026-08-14) — the ambient activity watcher's ONLY read path.
        //
        // Its own `activity` category rather than `accessibility`: the two are
        // unrelated gates. Accessibility governs reading/driving the LIVE
        // screen; this reads a local rollup of app+duration metadata the user
        // separately opted into recording, and its real gate is the Trust
        // Center capture toggle, which the impl re-checks and refuses on.
        // Low risk, no approval — it is a read of the user's own local data.
        // Without admitted Full Mac, requires Mac-local model access.
        // Admitted Full Mac also permits bounded answers on authenticated remote surfaces.
        ConnectorActionDescriptor(
            id: "activity.query", connectorId: "activity", connector: "activity",
            name: "Activity Query",
            description: "Query recorded app use by time range: app, duration and window titles where enabled. Read-only and deterministic; titles redact shaped secrets, not other private text. Returns rollups and example spans, at most 50 rows, with truncation stated. Capture must be on. Without admitted Full Mac, requires activity model access and Mac-local use; admitted Full Mac permits bounded answers on authenticated remote surfaces.",
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
            description: "Move a file. Standard modes prompt; admitted Full Mac YOLO runs directly.",
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
            description: "Move a file to the macOS Trash. Standard modes prompt; admitted Full Mac YOLO runs directly.",
            risk: "high", dryRunAvailable: true, requiresApproval: true,
            category: "file_ops",
            inputSchema: schema([
                ("path", prop("string")),
            ], required: ["path"])
        ),
        ConnectorActionDescriptor(
            id: "mac.set_brightness", connectorId: "mac", connector: "mac",
            name: "Mac Set Brightness",
            description: "Set Mac display brightness (0–100). Standard modes prompt; admitted Full Mac YOLO runs directly.",
            risk: "medium", dryRunAvailable: false, requiresApproval: true,
            category: "system",
            inputSchema: schema([
                ("percent", prop("integer")),
            ], required: ["percent"])
        ),
        ConnectorActionDescriptor(
            id: "mac.set_focus_mode", connectorId: "mac", connector: "mac",
            name: "Mac Set Focus Mode",
            description: "Set macOS Focus mode by name. Standard modes prompt; admitted Full Mac YOLO runs directly.",
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
    ]
}

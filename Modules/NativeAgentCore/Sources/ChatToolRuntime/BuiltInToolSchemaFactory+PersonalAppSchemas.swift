import Foundation
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
import AgentWorkspace
import MemoryV2
import ProviderRouting
import ToolRegistry
import NativeAgentShared
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Dispatcher
import MacControl
import Senses
import StandingBots
import MacIntegration
// Blueprint: | `BuiltInToolSchemaFactory+PersonalAppSchemas.swift` | `BuiltInToolSchemaFactory`, `personalAppSchemas`: Owned app schemas. |

extension BuiltInToolSchemaFactory {
    func personalAppSchemas() -> [LLMToolSchema?] {
        let schemas: [LLMToolSchema?] = [
            // MacIntegrationPermissionStore owns user-controlled READ/WRITE gates; app-side backends enforce them. PII surfaces default to read-only;
            // notification channels are outbound-only.
            requestedSchema(name: "mac_calendar_calendars", toolClass: .read, reach: .person, capabilities: ["tool_call"],
                macIntegration: .init(MacIntegrationID.calendar, .read),
                description: """
                    List local EventKit calendars with stable IDs and write access. Requires Calendar Read and full EventKit access. Choose a \
                    destination explicitly by ID.
                    """,
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            requestedSchema(name: "mac_calendar_free_busy", toolClass: .read, reach: .person, capabilities: ["tool_call"],
                macIntegration: .init(MacIntegrationID.calendar, .read),
                description: """
                    Check local free/busy across every calendar (or the exact EventKit calendar IDs given) over at most 31 days. Includes tentative \
                    and unavailable intervals; unsupported availability is unknown, never free. Requires Calendar Read and full EventKit access.
                    """,
                parametersJSON: ToolSchema.params(properties: [
                    ("calendar_ids", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.strSchema()), ("minItems", .int(1)), ("maxItems",
                        .int(50)), ("description", .string("Optional; omit to check every calendar."))])),
                    ("start", stringOrIntSchema("Window start: ISO-8601 or epoch seconds.")),
                    ("end", stringOrIntSchema("Window end after start: ISO-8601 or epoch seconds."))
                ], required: ["start", "end"])
            ),
            requestedSchema(name: "mac_calendar_list_upcoming", toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.calendar, .read),
                description: """
                    List the user's Mac calendar events from EventKit. Read-only; requires Calendar -> Read permission. Returns event titles, \
                    start/end timestamps, calendar names, and locations. For today/tomorrow/specific-date questions, pass day ('today', 'tomorrow', \
                    or 'YYYY-MM-DD') instead of relying on a broad hours window.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("day", ToolSchema.strSchema("Optional local-day scope: 'today', 'tomorrow', or 'YYYY-MM-DD'.")),
                        ("range", ToolSchema.strSchema("""
                            Natural local range: today, tomorrow, this week, next week, or next N days (1–30). Takes precedence over day and \
                            hours_ahead; this week runs from now to the end of the local calendar week; next week is the whole following calendar \
                            week.
                            """)),
                        ("hours_ahead", ToolSchema.intSchema("Lookahead window in hours (1-720, default 24).")),
                        ("days", ToolSchema.intSchema("Optional: the next N days (1–30), same as range 'next N days'.")),
                        ("limit", ToolSchema.intSchema("Maximum events to return (1-100, default 20).")),
                        ("calendar_name", ToolSchema.strSchema("Optional filter — return events only from this calendar.")),
                        ("calendar_id", ToolSchema.strSchema("Optional exact EventKit calendar ID from calendar.calendars.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "mac_reminders_query", toolClass: .read, reach: .person, capabilities: ["tool_call"],
                macIntegration: .init(MacIntegrationID.reminders, .read),
                description: """
                    Find Mac Reminders across all dates, including undated tasks. Searches titles and notes; incomplete reminders by default. \
                    Read-only; requires Reminders → Read permission. Follow next_offset with the same filters for more results.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Optional text to find in titles or notes (case insensitive).")),
                        ("list_name", ToolSchema.strSchema("Optional list-name filter (case insensitive contains).")),
                        ("due_start", stringOrIntSchema("Inclusive due-range start: ISO-8601, local YYYY-MM-DD, or epoch seconds.")),
                        ("due_end", stringOrIntSchema("Exclusive due-range end; undated tasks are excluded from date ranges.")),
                        ("split_due_at", stringOrIntSchema("""
                            Optional due-date boundary. Adds before and on_or_after pages from the same snapshot, each with its own total and \
                            next_offset using the requested offset/limit; undated tasks are excluded from these parts.
                            """)),
                        ("undated_only", ToolSchema.boolSchema("Return only tasks with no due date; cannot be combined with a due range or split_due_at.")),
                        ("include_completed", ToolSchema.boolSchema("Include completed reminders (default false).")),
                        ("offset", ToolSchema.intSchema("Result offset (default 0); use next_offset from the preceding page.")),
                        ("limit", ToolSchema.intSchema("""
                            Maximum reminders per page from one native snapshot, independently for split parts (1-200, default 20).
                            """)),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "mac_reminders_lists", toolClass: .read, reach: .person, capabilities: ["tool_call"],
                macIntegration: .init(MacIntegrationID.reminders, .read),
                description: """
                    List every Mac Reminders list with its id, source, write access and how many reminders are still open in it. Read-only; \
                    requires Reminders → Read permission.
                    """,
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            requestedSchema(name: "mac_reminders_read", toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.reminders, .read),
                description: """
                    Read exactly one Mac Reminder by id, regardless of due date or completion. Returns current title, list, due date, completion \
                    and full notes. Read-only; requires Reminders → Read permission.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [("id", ToolSchema.strSchema("Exact reminder id from a reminder query, read or creation."))],
                    required: ["id"]
                )
            ),
            requestedSchema(name: "mac_reminders_list_due_today", toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.reminders, .read),
                description: """
                    List Mac Reminders in two named parts: today (due in the local day, earliest first) and overdue (due before today, oldest \
                    first). Each has its full count, returned_count, reminders and has_more. Returns total and a summary naming both counts. \
                    Read-only; requires Reminders -> Read permission.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("""
                            Maximum reminders per part, independently (1-200, default 50). Counts and total include unreturned reminders.
                            """)),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "mac_notify",
                toolClass: .write, capabilities: ["external_send", "notification", "tool_call"],
                macIntegration: .init(MacIntegrationID.notifyMac, .write),
                description: """
                    Post a macOS user notification on this Mac. Requires Mac Notifications -> Write permission. Use for short, actionable alerts, \
                    not as a substitute for chat.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Optional short notification title; omit and it is your name.")),
                        ("message", ToolSchema.strSchema("Notification body text (required).")),
                        ("subtitle", ToolSchema.strSchema("Optional subtitle shown between title and body.")),
                    ],
                    required: ["message"]
                )
            ),
            requestedSchema(name: "phone_request",
                toolClass: .read, capabilities: ["external_send", "notification", "tool_call"],
                macIntegration: .init(MacIntegrationID.notifyMobile, .write),
                description: """
                    Ask your paired iPhone for its current location or a photo chosen or taken by the person. Open NativeAgent on the phone to \
                    respond. Waits for a result; phone permissions apply.
                    """,
                parametersJSON: ToolSchema.params(properties: [
                    ("kind", ToolSchema.enumStringSchema(["location.current", "photo.pick", "photo.capture"], "What to ask for.")),
                    ("params", .object(["type": .string("object"), "description": .string("Leave empty."),
                        "properties": .object([:]), "additionalProperties": .bool(false)])),
                    ("wait_seconds", ToolSchema.intSchema("Seconds to wait (1–120; default 60).", minimum: 1, maximum: 120)),
                ], required: ["kind"])
            ),
            requestedSchema(name: "mobile_notify",
                toolClass: .write, capabilities: ["external_send", "notification", "tool_call"],
                macIntegration: .init(MacIntegrationID.notifyMobile, .write),
                description: """
                    Push a notification to the paired iPhone via the NativeAgent mobile bridge. Requires iPhone Notifications -> Write permission. \
                    Use sparingly; these wake the phone.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Optional short notification title; omit and it is your name.")),
                        ("message", ToolSchema.strSchema("Notification body text (required).")),
                        ("subtitle", ToolSchema.strSchema("Optional subtitle.")),
                        ("source", ToolSchema.strSchema("Optional source tag for tracking (e.g. 'calendar_reminder').")),
                    ],
                    required: ["message"]
                )
            ),
            requestedSchema(name: "mac_spotlight_search", toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.spotlight, .read),
                description: """
                    Search the Mac with Spotlight and return file paths plus modified_at and added_at dates in files (null when unavailable). Plain \
                    words can match file contents; use an exact-name predicate for a filename. Read-only; requires Spotlight -> Read permission.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("""
                            Spotlight words or predicate. Exact filename: kMDItemFSName == \"hello.txt\". Alias 'q' is also accepted.
                            """)),
                        ("q", ToolSchema.strSchema("Alias for 'query'.")),
                        ("name", ToolSchema.strSchema("Filename contains this text, case-insensitive (files named …); use instead of query.")),
                        ("limit", ToolSchema.intSchema("Maximum paths (1-200, default 10).")),
                    ],
                    required: []
                )
            ),
            // Sensitive Mac Integration writes default off and require the user's toggle.
            requestedSchema(name: "contacts_search", toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.contacts, .read),
                description: """
                    Search local Mac Contacts once by identifier, name, phone or email. Supply at least one search field; query selects email for \
                    @, phone for phone-shaped text, otherwise name. Returns matching records and the selected lookup. Read-only; requires Contacts \
                    -> Read permission.
                    """,
                parametersJSON: try! MacContactsExecutor.searchParameters.serializedData(pretty: false)
            ),
            requestedSchema(name: "contacts_create_or_update",
                toolClass: .write, reach: .person, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.contacts, .write),
                description: """
                    Create a Mac contact, or update one: by identifier, or the single existing contact with the same full name. Phones and emails \
                    are added, never replaced. Requires Contacts -> Write permission.
                    """,
                parametersJSON: try! MacContactsExecutor.saveParameters.serializedData(pretty: false)
            ),
            requestedSchema(name: "mail_save_attachment",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.mail, .read),
                description: """
                    Save one local Apple Mail attachment by index or unique filename using an observed mail.N name or paired message identity from \
                    a Mail read. Defaults to ~/Downloads; destination is a folder within the same writable roots as files.write in the current \
                    mode. Never overwrites: adds a numbered suffix. Returns path and size in bytes. Requires Mail Read access; no Mail UI or \
                    AppleScript is used.
                    """,
                parametersJSON: ToolSchema.params(properties: [
                    ("name", ToolSchema.strSchema("Observed mail.N workspace name; use instead of exact locator fields.")),
                    ("scope", ToolSchema.enumStringSchema(["inbox", "sent"], "Mailbox scope from the same row; default inbox.")),
                    ("index", ToolSchema.intSchema("1-based attachment index from the Mail read; index or filename is required.", minimum: 1)),
                    ("filename", ToolSchema.strSchema("Exact unique attachment filename; index disambiguates duplicate names.")),
                    ("destination", ToolSchema.strSchema("Destination folder; default ~/Downloads.")),
                    ("message_id", ToolSchema.intSchema("Exact positive message ID from the Mail read.", minimum: 1)),
                    ("expected_message_id", ToolSchema.strSchema("Exact RFC message identifier paired with message_id.")),
                    ("expected_account", ToolSchema.strSchema("expected_account from the same row, when present.")),
                    ("position", ToolSchema.intSchema("position from the same row, when present.", minimum: 1)),
                    ("expected_account_id", ToolSchema.strSchema("expected_account_id from the same row.")),
                ], required: [])
            ),
            // Sensitive writes default off; scheduler.write defaults on with no read axis.
            requestedSchema(name: "mac_calendar_create_event",
                toolClass: .write, reach: .person, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.calendar, .write),
                description: """
                    Create a local Calendar entry via EventKit; this does not send invitations. With full access, choose an explicit destination; \
                    with write-only access, omit calendar_id and calendar_name to use the system default. Requires Calendar Write permission. \
                    start/end accept ISO-8601 or epoch seconds.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Event title (required).")),
                        ("start", stringOrIntSchema("Start time — ISO-8601 string (e.g. '2026-06-07T15:00:00Z') or integer epoch seconds (required).")),
                        ("end", stringOrIntSchema("Optional end time — ISO-8601 string or integer epoch seconds. Defaults to start + 1 hour.")),
                        ("notes", ToolSchema.strSchema("Optional notes / description.")),
                        ("location", ToolSchema.strSchema("Optional location string.")),
                        ("calendar_name", ToolSchema.strSchema("Unique exact calendar name, only when calendar_id is omitted; ambiguous names fail.")),
                        ("calendar_id", ToolSchema.strSchema("""
                            Explicit EventKit calendar ID from calendar.calendars. Required with full access unless a unique exact calendar_name is \
                            supplied. With write-only access, omit calendar_id and calendar_name to use the system default.
                            """)),
                    ],
                    required: ["title", "start"]
                )
            ),
            requestedSchema(name: "mac_calendar_modify_event", toolClass: .write, reach: .person,
                macIntegration: .init(MacIntegrationID.calendar, .write),
                description: """
                    Modify an existing calendar event. Requires id from a prior calendar.upcoming. Pass only the fields to change. Requires \
                    Calendar → Write permission.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("EKEvent identifier from calendar.upcoming (required).")),
                        ("title", ToolSchema.strSchema("New event title.")),
                        ("start", stringOrIntSchema("New start time — ISO-8601 string or epoch seconds.")),
                        ("end", stringOrIntSchema("New end time — ISO-8601 string or epoch seconds.")),
                        ("notes", ToolSchema.strSchema("New notes/body text.")),
                        ("location", ToolSchema.strSchema("New location.")),
                        ("clear_fields", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.enumStringSchema(["notes", "location"])),
                            ("description", .string("Fields to empty on the event. A field also given a value keeps that value."))])),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(name: "mac_calendar_delete_event",
                toolClass: .destructive, reach: .person, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.calendar, .write),
                description: """
                    Delete exactly one calendar event occurrence by id from calendar.upcoming. Requires the observed title and start as \
                    preconditions; a changed event is not deleted. Never deletes a recurring series. Requires Calendar → Write and EventKit full \
                    access. Use only for an explicitly requested deletion.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("Exact EKEvent identifier from calendar.upcoming.")),
                        ("expected_title", ToolSchema.strSchema("Exact title observed for this event.")),
                        ("expected_start", stringOrIntSchema("Observed start time, ISO-8601 or epoch seconds.")),
                    ],
                    required: ["id", "expected_title", "expected_start"]
                )
            ),
            requestedSchema(name: "mac_reminders_create",
                toolClass: .write, reach: .person, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.reminders, .write),
                description: "Create a new reminder in the user's Mac Reminders via EventKit. Requires Reminders -> Write permission (off by default).",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Reminder title (required).")),
                        ("notes", ToolSchema.strSchema("Optional notes.")),
                        ("due_date", stringOrIntSchema("Optional due date — ISO-8601 string or integer epoch seconds.")),
                        ("list_name", ToolSchema.strSchema("Optional list name — defaults to the default list when omitted.")),
                    ],
                    required: ["title"]
                )
            ),
            requestedSchema(name: "mac_reminders_list_rename",
                toolClass: .write, reach: .person, capabilities: ["safe_read", "tool_call"],
                macIntegration: .init(MacIntegrationID.reminders, .write),
                description: """
                    Rename exactly one Mac Reminders list via EventKit and read back its saved name. Matches names ignoring case and whitespace; \
                    emoji and variation selectors are significant. Refuses ambiguous or read-only lists and duplicate destination names. Requires \
                    Reminders → Write permission.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("list", ToolSchema.strSchema("Exact existing Reminders list name.")),
                        ("new_name", ToolSchema.strSchema("New nonempty, unique list name.")),
                    ],
                    required: ["list", "new_name"]
                )
            ),
            requestedSchema(name: "mac_reminders_list_create",
                toolClass: .write, reach: .person, capabilities: ["filesystem_write", "outside_app_data_write", "safe_read", "tool_call"],
                macIntegration: .init(MacIntegrationID.reminders, .write),
                description: """
                    Create a Mac Reminders list via EventKit in the default reminder list's account and read back its saved name. Refuses duplicate \
                    names or an unavailable or read-only default list. Requires Reminders → Write permission.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [("name", ToolSchema.strSchema("Nonempty, unique name for the new Reminders list."))],
                    required: ["name"]
                )
            ),
            requestedSchema(name: "mac_reminders_update", toolClass: .write, reach: .person,
                macIntegration: .init(MacIntegrationID.reminders, .write),
                description: """
                    Update exactly one Mac Reminder by id. Change only supplied title, notes or due_date; preserves its list and completion. \
                    Requires Reminders → Write permission.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("Exact reminder id from a reminder query, read or creation.")),
                        ("title", ToolSchema.strSchema("New nonempty title; omitted leaves it unchanged.")),
                        ("notes", ToolSchema.strSchema("New notes; omitted leaves them unchanged. Use clear_fields to remove them.")),
                        ("due_date", stringOrIntSchema("""
                            New due date: ISO-8601, local YYYY-MM-DD, or epoch seconds; omitted leaves it unchanged. Use clear_fields to remove it.
                            """)),
                        ("clear_fields", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.enumStringSchema(["notes", "due_date"])),
                            ("description", .string("Fields to clear: notes or due_date. Do not also supply a value for a cleared field."))])),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(name: "mac_reminders_complete", toolClass: .write, reach: .person,
                macIntegration: .init(MacIntegrationID.reminders, .write),
                description: "Mark a Mac Reminder done by its title (or id from reminders.due_today). Requires Reminders → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("The reminder's exact title (case aside).")),
                        ("id", ToolSchema.strSchema("Reminder id from reminders.due_today, when known.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "mac_reminders_delete",
                toolClass: .destructive, reach: .person, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.reminders, .write),
                description: """
                    Delete exactly one Mac Reminder by id from reminders.create or reminders.due_today. Requires its observed title as a \
                    precondition; a changed reminder is not deleted. Requires Reminders → Write permission. Use only for an explicitly requested \
                    deletion.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("Exact reminder id from reminders.create or reminders.due_today.")),
                        ("expected_title", ToolSchema.strSchema("Exact title observed for this reminder.")),
                    ],
                    required: ["id", "expected_title"]
                )
            ),
            requestedSchema(name: "contacts_delete",
                toolClass: .destructive, reach: .person, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.contacts, .write),
                description: """
                    Delete a Mac contact by its exact identifier from contacts.search. A name is never an identifier. Requires Contacts -> Write \
                    permission.
                    """,
                parametersJSON: try! MacContactsExecutor.deleteParameters.serializedData(pretty: false)
            ),
        ]
        return schemas
    }
}

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
// Blueprint: | `BuiltInToolSchemaFactory+PersonalAppSchemas.swift` | `BuiltInToolSchemaFactory`: `personalAppSchemas`: calendar, reminders, notifications, Spotlight, contacts, Mail, Messages, Notes and Music; bridge declarations retain their place in the sequence |

extension BuiltInToolSchemaFactory {
    func personalAppSchemas() -> [LLMToolSchema?] {
        func mailIdentityFields(_ message: String, expectedMessage: String = "Exact RFC message identifier paired with message_id.",
                                account: String = "expected_account from the same row, when it has one.",
                                accountID: String? = nil, position: String = "position from the same row: finds the message fast.",
                                minimum: Int? = 1) -> [(String, JSONValue)] {
            var fields: [(String, JSONValue)] = [
                ("message_id", ToolSchema.intSchema(message, minimum: minimum)),
                ("expected_message_id", ToolSchema.strSchema(expectedMessage)),
                ("expected_account", ToolSchema.strSchema(account)),
                ("position", ToolSchema.intSchema(position, minimum: minimum)),
            ]
            if let accountID { fields.append(("expected_account_id", ToolSchema.strSchema(accountID))) }
            return fields
        }
        let mailReplyFields: [(String, JSONValue)] = [
            ("subject", ToolSchema.strSchema("Subject for legacy matching; omit when using the exact message locator.")),
        ] + mailIdentityFields("Exact positive inbox message ID from the latest read.", accountID: "expected_account_id from the same row.") + [
            ("body", ToolSchema.strSchema("Reply body (required).")),
            ("sender", ToolSchema.strSchema("Optional sender filter — disambiguates when multiple messages share the subject.")),
            ("reply_all", ToolSchema.boolSchema("Reply to all recipients. Defaults to false.")),
        ]
        func mailBatchItemsSchema(effects: Bool, markReadOnly: Bool = false) -> JSONValue {
            var fields: [(String, JSONValue)] = [
                ("name", ToolSchema.strSchema("Observed workspace name, such as mail.3. Omit locator fields when using a name.")),
            ] + mailIdentityFields("Exact positive message_id from the selected row.", expectedMessage: "RFC identifier from that row; may be empty only for reads.",
                account: "Exact expected_account from that row; required with a locator.",
                accountID: effects ? "expected_account_id from that row, passed along as its identity." : "expected_account_id from that row; Mail's index checks the account with it.",
                position: "Position hint from the same row.", minimum: nil) + [
                ("scope", ToolSchema.strSchema("Same mailbox scope: inbox or sent for reads; inbox for actions.")),
            ]
            if markReadOnly { fields.removeFirst() }
            else if effects {
                fields += [
                    ("mark_read", ToolSchema.boolSchema("true to mark this message read; omit to leave it unchanged.")),
                    ("flagged", ToolSchema.boolSchema("true to flag, false to unflag; omit to leave it unchanged.")),
                    ("archive", ToolSchema.boolSchema("true to move this message to its own account's Archive, after other requested actions.")),
                ]
            } else {
                fields.append(("body_offset", ToolSchema.intSchema("Body continuation from this item's body_end, up to 2000000; omit initially.")))
            }
            return ToolSchema.obj([
                ("type", .string("array")), ("minItems", .int(1)), ("maxItems", .int(markReadOnly ? 50 : 10)),
                ("items", ToolSchema.obj([("type", .string("object")), ("properties", ToolSchema.obj(fields)), ("additionalProperties", .bool(markReadOnly))])),
            ])
        }
        let mailOffsetSchema = ToolSchema.obj([
            ("description", .string("Live mailbox continuation returned as next_offset; copy it unchanged; omit initially.")),
            ("anyOf", .array([
                ToolSchema.obj([("type", .string("integer")), ("minimum", .int(0)), ("maximum", .int(10000))]),
                ToolSchema.obj([("type", .string("object")), ("additionalProperties", ToolSchema.intSchema("", minimum: 0))]),
            ])),
        ])
        let schemas: [LLMToolSchema?] = [
            // ── Mac integration chat tools ──
            // Each tool is gated by MacIntegrationPermissionStore (per-integration
            // READ/WRITE bits the user controls in Settings → Mac Integration). The
            // EventKit / notification / Spotlight backends are injected via the
            // app-side MacIntegrationToolBridge. Defaults bias to READ-only for
            // PII surfaces; the two notification channels are write-only outbound.
            requestedSchema(name: "mac_calendar_calendars", toolClass: .read, reach: .his, capabilities: ["tool_call"],
                description: "List local EventKit calendars with stable IDs and write access. Requires Calendar Read and full EventKit access. Choose a destination explicitly by ID.",
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            requestedSchema(name: "mac_calendar_free_busy", toolClass: .read, reach: .his, capabilities: ["tool_call"],
                description: "Check local free/busy across every calendar (or the exact EventKit calendar IDs given) over at most 31 days. Includes tentative and unavailable intervals; unsupported availability is unknown, never free. Requires Calendar Read and full EventKit access.",
                parametersJSON: ToolSchema.params(properties: [
                    ("calendar_ids", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.strSchema()), ("minItems", .int(1)), ("maxItems", .int(50)), ("description", .string("Optional; omit to check every calendar."))])),
                    ("start", stringOrIntSchema("Window start: ISO-8601 or epoch seconds.")),
                    ("end", stringOrIntSchema("Window end after start: ISO-8601 or epoch seconds."))
                ], required: ["start", "end"])
            ),
            requestedSchema(name: "mac_calendar_list_upcoming", toolClass: .read, reach: .his,
                description: "List the user's Mac calendar events from EventKit. Read-only; requires Calendar -> Read permission. Returns event titles, start/end timestamps, calendar names, and locations. For today/tomorrow/specific-date questions, pass day ('today', 'tomorrow', or 'YYYY-MM-DD') instead of relying on a broad hours window.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("day", ToolSchema.strSchema("Optional local-day scope: 'today', 'tomorrow', or 'YYYY-MM-DD'.")),
                        ("range", ToolSchema.strSchema("Natural local range: today, tomorrow, this week, next week, or next N days (1–30). Takes precedence over day and hours_ahead; this week runs from now to the end of the local calendar week; next week is the whole following calendar week.")),
                        ("hours_ahead", ToolSchema.intSchema("Lookahead window in hours (1-720, default 24).")),
                        ("days", ToolSchema.intSchema("Optional: the next N days (1–30), same as range 'next N days'.")),
                        ("limit", ToolSchema.intSchema("Maximum events to return (1-100, default 20).")),
                        ("calendar_name", ToolSchema.strSchema("Optional filter — return events only from this calendar.")),
                        ("calendar_id", ToolSchema.strSchema("Optional exact EventKit calendar ID from calendar.calendars.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "mac_reminders_query", toolClass: .read, reach: .his, capabilities: ["tool_call"],
                description: "Find Mac Reminders across all dates, including undated tasks. Searches titles and notes; incomplete reminders by default. Read-only; requires Reminders → Read permission. Follow next_offset with the same filters for more results.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Optional text to find in titles or notes (case insensitive).")),
                        ("list_name", ToolSchema.strSchema("Optional list-name filter (case insensitive contains).")),
                        ("due_start", stringOrIntSchema("Inclusive due-range start: ISO-8601, local YYYY-MM-DD, or epoch seconds.")),
                        ("due_end", stringOrIntSchema("Exclusive due-range end; undated tasks are excluded from date ranges.")),
                        ("split_due_at", stringOrIntSchema("Optional due-date boundary. Adds before and on_or_after pages from the same snapshot, each with its own total and next_offset using the requested offset/limit; undated tasks are excluded from these parts.")),
                        ("undated_only", ToolSchema.boolSchema("Return only tasks with no due date; cannot be combined with a due range or split_due_at.")),
                        ("include_completed", ToolSchema.boolSchema("Include completed reminders (default false).")),
                        ("offset", ToolSchema.intSchema("Result offset (default 0); use next_offset from the preceding page.")),
                        ("limit", ToolSchema.intSchema("Maximum reminders per page from one native snapshot, independently for split parts (1-200, default 20).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "mac_reminders_lists", toolClass: .read, reach: .his, capabilities: ["tool_call"],
                description: "List every Mac Reminders list with its id, source, write access and how many reminders are still open in it. Read-only; requires Reminders → Read permission.",
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            requestedSchema(name: "mac_reminders_read", toolClass: .read, reach: .his,
                description: "Read exactly one Mac Reminder by id, regardless of due date or completion. Returns current title, list, due date, completion and full notes. Read-only; requires Reminders → Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [("id", ToolSchema.strSchema("Exact reminder id from a reminder query, read or creation."))],
                    required: ["id"]
                )
            ),
            requestedSchema(name: "mac_reminders_list_due_today", toolClass: .read, reach: .his,
                description: "List Mac Reminders in two named parts: today (due in the local day, earliest first) and overdue (due before today, oldest first). Each has its full count, returned_count, reminders and has_more. Returns total and a summary naming both counts; top-level reminders is their union. Read-only; requires Reminders -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("Maximum reminders per part, independently (1-200, default 50). Counts and total include unreturned reminders.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "mac_notify",
                toolClass: .write, capabilities: ["external_send", "notification", "tool_call"],
                description: "Post a macOS user notification on this Mac. Requires Mac Notifications -> Write permission. Use for short, actionable alerts, not as a substitute for chat.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Notification title (required, short).")),
                        ("message", ToolSchema.strSchema("Notification body text (required).")),
                        ("subtitle", ToolSchema.strSchema("Optional subtitle shown between title and body.")),
                    ],
                    required: ["title", "message"]
                )
            ),
            requestedSchema(name: "phone_request",
                toolClass: .read, capabilities: ["external_send", "notification", "tool_call"],
                description: "Ask your paired iPhone for its current location or a photo chosen or taken by the person. Open NativeAgent on the phone to respond. Waits for a result; phone permissions apply.",
                parametersJSON: ToolSchema.params(properties: [
                    ("kind", ToolSchema.enumStringSchema(["location.current", "photo.pick", "photo.capture"], "What to ask for.")),
                    ("params", .object(["type": .string("object"), "description": .string("Leave empty."),
                        "properties": .object([:]), "additionalProperties": .bool(false)])),
                    ("wait_seconds", ToolSchema.intSchema("Seconds to wait (1–120; default 60).", minimum: 1, maximum: 120)),
                ], required: ["kind"])
            ),
            requestedSchema(name: "mobile_notify",
                toolClass: .write, capabilities: ["external_send", "notification", "tool_call"],
                description: "Push a notification to the paired iPhone via the NativeAgent mobile bridge. Requires iPhone Notifications -> Write permission. Use sparingly; these wake the phone.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Notification title (required, short).")),
                        ("message", ToolSchema.strSchema("Notification body text (required).")),
                        ("subtitle", ToolSchema.strSchema("Optional subtitle.")),
                        ("source", ToolSchema.strSchema("Optional source tag for tracking (e.g. 'calendar_reminder').")),
                    ],
                    required: ["title", "message"]
                )
            ),
            requestedSchema(name: "mac_spotlight_search", toolClass: .read, reach: .his,
                description: "Search the Mac with Spotlight and return file paths plus modified_at and added_at dates in files (null when unavailable). Plain words can match file contents; use an exact-name predicate for a filename. Read-only; requires Spotlight -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Spotlight words or predicate. Exact filename: kMDItemFSName == \"hello.txt\". Alias 'q' is also accepted.")),
                        ("q", ToolSchema.strSchema("Alias for 'query'.")),
                        ("name", ToolSchema.strSchema("Filename contains this text, case-insensitive (files named …); use instead of query.")),
                        ("limit", ToolSchema.intSchema("Maximum paths (1-200, default 10).")),
                    ],
                    required: []
                )
            ),
            // Sensitive Mac Integration writes default off and require the user's toggle.
            requestedSchema(name: "contacts_search", toolClass: .read, reach: .his,
                description: "Search the user's local Mac Contacts by name (including saved names like Mom or Dad), phone, or email and return matching records (name, organization, phones, emails, identifier). Read-only; requires Contacts -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Search string — matches against name, phone, or email.")),
                        ("limit", ToolSchema.intSchema("Maximum contacts to return (1-100, default 20).")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(name: "contacts_create_or_update",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Create a Mac contact, or update one: by identifier, or the single existing contact with the same full name. Phones and emails are added, never replaced. Requires Contacts -> Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("given_name", ToolSchema.strSchema("First name (optional).")),
                        ("family_name", ToolSchema.strSchema("Last name (optional).")),
                        ("organization", ToolSchema.strSchema("Organization / company (optional).")),
                        ("phones", stringArraySchema("Optional list of phone numbers.")),
                        ("emails", stringArraySchema("Optional list of email addresses.")),
                        ("identifier", ToolSchema.strSchema("Contact to update: identifier from contacts.search, or its exact full name.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "mail_list_recent", toolClass: .read, reach: .his,
                description: "List Apple Mail's inbox, sent or drafts metadata and exact mailbox totals; inbox_unread_by_category counts Primary, Transactions, Updates, Promotions and unclassified across the whole inbox. Primary is not proof of a human sender. Filtered or explicitly sorted lists cover all categories. Pass scope + message_id + expected_message_id + expected_account_id from one row to read a body and attachments (filename, content_type, size in bytes, 1-based index). Read-only; requires Mail → Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("Maximum messages to return (1-50, default 10).")),
                        ("scope", ToolSchema.strSchema("Mailbox scope: inbox (default), sent or drafts. Keep the same scope for continuation and message-body reads.")),
                        ("mailbox", ToolSchema.enumStringSchema(["inbox", "sent", "drafts"], "Alias for scope; both must agree when supplied together.")),
                        ("all_categories", ToolSchema.boolSchema("Inbox lists show Mail's Primary and Transactions categories; true lists Updates and Promotions too.")),
                        ("unread", ToolSchema.boolSchema("true selects unread messages, false selects read messages; omit for both.")),
                        ("sort", ToolSchema.enumStringSchema(["newest", "oldest"], "Date order; default newest. Keep unchanged for continuation.")),
                        ("offset", mailOffsetSchema),
                        ("body_offset", ToolSchema.intSchema("Exact detail continuation offset from body_end, up to 2000000; omit initially.")),
                    ] + mailIdentityFields("Exact positive message ID from a prior read in the same scope; returns up to 16000 characters of body.",
                        expectedMessage: "Exact RFC message identifier paired with message_id in the prior read.",
                        accountID: "expected_account_id from the same row; Mail's index checks the account with it."),
                    required: []
                )
            ),
            requestedSchema(name: "mail_save_attachment",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Save one local Apple Mail attachment by index or unique filename using an observed mail.N name or paired message identity from a Mail read. Defaults to ~/Downloads; destination is a folder within the same writable roots as files.write in the current mode. Never overwrites: adds a numbered suffix. Returns path and size in bytes. Requires Mail Read access; no Mail UI or AppleScript is used.",
                parametersJSON: ToolSchema.params(properties: [
                    ("name", ToolSchema.strSchema("Observed mail.N workspace name; use instead of exact locator fields.")),
                    ("scope", ToolSchema.enumStringSchema(["inbox", "sent"], "Mailbox scope from the same row; default inbox.")),
                    ("index", ToolSchema.intSchema("1-based attachment index from the Mail read; index or filename is required.", minimum: 1)),
                    ("filename", ToolSchema.strSchema("Exact unique attachment filename; index disambiguates duplicate names.")),
                    ("destination", ToolSchema.strSchema("Destination folder; default ~/Downloads."))
                ] + mailIdentityFields("Exact positive message ID from the Mail read.", account: "expected_account from the same row, when present.",
                    accountID: "expected_account_id from the same row.", position: "position from the same row, when present."), required: [])
            ),
            requestedSchema(name: "mail_read_batch", toolClass: .read, reach: .his,
                description: "Read bodies for 1–10 selected Apple Mail messages in one bounded call. Each item uses an observed workspace name or exact message_id + expected_message_id + expected_account + expected_account_id and scope. Returns ordered per-item receipts, up to 4000 body characters each, and body_end for continuation when truncated. No rediscovery or retry; unfinished items are explicit. Requires Mail Read permission.",
                parametersJSON: ToolSchema.params(properties: [("items", mailBatchItemsSchema(effects: false))], required: ["items"])
            ),
            requestedSchema(name: "mail_triage_batch",
                toolClass: .write, reach: .his, capabilities: ["app_data_write", "tool_call"],
                description: "Triage 1–10 selected inbox messages in one bounded call: mark read, flag/unflag, then archive in the source account. Each item uses an observed workspace name or exact message_id + expected_message_id + expected_account; actions require a nonempty RFC identifier. Returns ordered per-item and per-action receipts, including partial effects. Cancellation, deadline or uncertain effects stop remaining work; never replay an uncertain item. No deletion: mail.delete retains its move-to-Trash approval gate. Requires Mail Write permission.",
                parametersJSON: ToolSchema.params(properties: [("items", mailBatchItemsSchema(effects: true))], required: ["items"])
            ),
            requestedSchema(name: "mail_search", toolClass: .read, reach: .his,
                description: "Search or list Apple Mail's whole inbox, sent or drafts mailbox, all categories, with optional query, from, since, unread, category, attachment; default newest. Returns matching_total, has_more, next_offset and metadata, plus up to five attachment_names per message when filtering attachments. Inbox search results can be passed to mail.mark_read in one call. Bodies are not searched. Requires Mail → Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", stringOrStringArraySchema("One search term or an array of terms matched with OR against mailbox subject and sender metadata. Example: [\"receipt\", \"order confirmation\"]. Keep the same terms for continuation.")),
                        ("from", ToolSchema.strSchema("Sender name or address fragment, matched case and accents aside; combined with other filters using AND.")),
                        ("attachment", ToolSchema.obj([("description", .string("true selects messages with any attachment; a nonempty string matches an attachment filename fragment, case and accents aside. Combined with other filters using AND.")), ("anyOf", .array([
                            ToolSchema.obj([("type", .string("boolean")), ("enum", .array([.bool(true)]))]),
                            ToolSchema.obj([("type", .string("string")), ("minLength", .int(1))]),
                        ]))])),
                        ("since", ToolSchema.strSchema("Inclusive received date: this week (start of the local calendar week), local YYYY-MM-DD, or ISO-8601 with a time zone.")),
                        ("category", ToolSchema.strSchema("Mail categories: primary, transactions, updates, promotions; comma-separated categories combine. A category is not a guarantee of a human sender.")),
                        ("unread", ToolSchema.boolSchema("true selects unread messages, false selects read messages; omit for both.")),
                        ("sort", ToolSchema.enumStringSchema(["newest", "oldest"], "Date order; default newest. Keep unchanged for continuation.")),
                        ("scope", ToolSchema.strSchema("Mailbox scope: inbox (default), sent or drafts. Keep the same scope for continuation and message-body reads.")),
                        ("mailbox", ToolSchema.enumStringSchema(["inbox", "sent", "drafts"], "Alias for scope; both must agree when supplied together.")),
                        ("limit", ToolSchema.intSchema("Maximum messages to return (1-50, default 10).")),
                        ("offset", mailOffsetSchema),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "mail_senders", toolClass: .read, reach: .his, capabilities: ["tool_call"],
                description: "Rank Apple Mail senders by exact message count in one bounded read-only grouped query, with unread count, newest date, address and display name. Covers inbox by default or all indexed mail; supports date, category and unread filters. Useful for sender frequency and unsubscribe candidates. Requires Mail Read permission and macOS Full Disk Access.",
                parametersJSON: ToolSchema.params(properties: [
                    ("limit", ToolSchema.intSchema("Maximum senders to return (1-50, default 15).")),
                    ("since", ToolSchema.strSchema("Inclusive received date: this week, local YYYY-MM-DD, or ISO-8601 with a time zone.")),
                    ("scope", ToolSchema.enumStringSchema(["inbox", "all"], "Mailbox scope; default inbox.")),
                    ("category", ToolSchema.strSchema("Mail categories: primary, transactions, updates, promotions; comma-separated categories combine.")),
                    ("unread_only", ToolSchema.boolSchema("Count and rank only unread messages; default false.")),
                ], required: [])
            ),
            requestedSchema(name: "mail_send",
                toolClass: .send, reach: .his, capabilities: ["external_send", "tool_call"],
                description: "Sends an email now through Apple Mail. Requires Mail Write permission, requested inline when needed, or admitted Full Mac access. An explicit Mail Write revocation still applies.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("to", stringOrStringArraySchema("Recipient address(es). May be a single string or list of strings.")),
                        ("subject", ToolSchema.strSchema("Email subject (required).")),
                        ("body", ToolSchema.strSchema("Email body text (required).")),
                        ("cc", stringOrStringArraySchema("Optional CC recipient(s). String or array.")),
                        ("bcc", stringOrStringArraySchema("Optional BCC recipient(s). String or array.")),
                    ],
                    required: ["to", "subject", "body"]
                )
            ),
            requestedSchema(name: "messages_recent_threads", toolClass: .read, reach: .his,
                description: "Read Messages: from_me selects newest sent or received messages across all conversations, with named participants and exact sent_count or received_count when since is given; otherwise list conversations with optional fields, since and latest-unread filtering, order by oldest unread incoming message (past 30 days by default), find them by person or words, or open an exact thread. Threads include unread_count across all dates and latest_message_is_read; history includes each message's is_read when chat.db exposes it, otherwise unread_state says unavailable. These are local read flags, not recipient read receipts. Requires Messages Read permission and macOS Full Disk Access. Plain and supported archived text are shown; unsupported formats and attachment content are explicitly unavailable, never presented as empty messages.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("Maximum threads or messages to return (1-30, default 10); exact window counts are independent of this limit.")),
                        ("from_me", ToolSchema.boolSchema("true: latest messages sent by you across all threads, newest first, with thread_id, named participants, date and text or attachment label. false: latest received messages. Omit to keep the conversation view. Cannot combine with thread_id, query, unread_only, sort, offset or before_message_id.")),
                        ("since", ToolSchema.strSchema("Inclusive window: local YYYY-MM-DD, ISO-8601 with time zone, a positive duration such as 7d (m/h/d/w), or this week (start of the local calendar week). Thread lists use latest-message dates; oldest_unread also selects its unread message within this window and defaults to the past 30 days. Other sorts have no default date cutoff. With from_me, returns exact sent_count or received_count over local message records, including attachments, reactions and special records. Omit for an exact thread read.")),
                        ("fields", stringArraySchema("Thread-list row keys to return; omitted returns every existing field. [] returns empty rows with envelope counts. Choose thread_id, name, participants, date, preview, snippet, latest_message_is_read, unread_count, oldest_unread_message_id, oldest_unread_date, oldest_unread_preview, oldest_unread_preview_status. Aliases returned under the requested key: handle is an array of participant handles, last_at is date, unread is the all-date unread_count. For no message text use [handle,name,last_at,unread]. Cannot combine with thread_id or from_me.")),
                        ("offset", ToolSchema.intSchema("Conversations to skip: next_offset from the previous page; omit initially.")),
                        ("unread_only", ToolSchema.boolSchema("List only threads whose latest message is incoming and unread; default false. Older unread records alone do not qualify. Omit for an exact thread read.")),
                        ("sort", ToolSchema.enumStringSchema(["newest", "oldest_unread"], "Thread order; default newest. oldest_unread selects unread incoming messages within since (default past 30 days), earliest first, and includes oldest_unread_message_id, oldest_unread_date, oldest_unread_preview and its availability status unless fields excludes them. Omit for an exact thread read.")),
                        ("query", ToolSchema.strSchema("A person (name, number or email) or words they wrote; lists only matching conversations.")),
                        ("thread_id", ToolSchema.strSchema("Exact thread_id returned by this tool, to inspect that conversation.")),
                        ("before_message_id", ToolSchema.intSchema("Older-page cursor returned as older_before_message_id. Requires the same exact thread_id; omit for recent messages.", minimum: 1)),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "messages_send",
                toolClass: .send, reach: .his, capabilities: ["external_send", "tool_call"],
                description: "Sends a text message now (iMessage/SMS) to an explicit recipient, or sends a reply now to an exact observed Messages thread with its expected participants. Choose exactly one of to or thread_id. Requires Messages write authority.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("to", ToolSchema.strSchema("Phone number or email for a new message (a name: find it with contacts.search). Omit when replying by thread_id.")),
                        ("thread_id", ToolSchema.strSchema("Exact observed Messages thread. Requires expected_participants; do not use a thread ID as to.")),
                        ("expected_participants", stringArraySchema("Exact participant handles from the latest thread read, checked again before sending.")),
                        ("body", ToolSchema.strSchema("Message body (required).")),
                    ],
                    required: ["body"]
                )
            ),
            requestedSchema(name: "notes_search", toolClass: .read, reach: .his,
                description: "Find and read Apple Notes: blank query lists recent notes, query matches title or text, title (exact) or id returns a body page. Each note reports truncated; continue with its id and next_body_offset as body_offset until false. Read-only; requires Notes → Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Words to find in titles or text; blank lists recent notes.")),
                        ("title", ToolSchema.strSchema("Exact note title: returns a body page.")),
                        ("id", ToolSchema.strSchema("A note's id from an earlier result: returns a body page of that exact note.")),
                        ("body_offset", ToolSchema.intSchema("UTF-16 offset from next_body_offset; requires the same note id. Omit to read from the start.")),
                        ("limit", ToolSchema.intSchema("Maximum notes to return (1-50, default 10).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "notes_create",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Create a new Apple Note with title + body, optionally in a named folder. Requires Notes → Write permission (off by default).",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Note title (required).")),
                        ("body", ToolSchema.strSchema("Note body content (required).")),
                        ("folder", ToolSchema.strSchema("Optional folder name; created in the default folder when omitted. A named folder that does not exist is an error listing the folders that do — it is never silently swapped for the default.")),
                    ],
                    required: ["title", "body"]
                )
            ),
            requestedSchema(name: "music_now_playing", toolClass: .read, reach: .his, capabilities: ["tool_call"],
                description: "Report playing / paused / stopped first, track and position, since (first observed, not an inferred transition time), and observed_at. Music closed is stopped. Read-only; requires Music → Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [],
                    required: []
                )
            ),
        ] + bridgeSchemas() + [
            requestedSchema(name: "music_control", toolClass: .write, reach: .his,
                description: "Play, pause, stop or skip in Apple Music. Play a playlist or exact song by name; seconds bounds play and stops Music itself before returning. Returns playback afterward. Requires Music → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("action", ToolSchema.enumStringSchema(["play", "pause", "stop", "toggle", "next", "previous"], "play / pause / stop / toggle / next / previous. Stop ends playback; pause retains its position. Default play when playlist or track is given; with nothing given it only reports what's playing.")),
                        ("playlist", ToolSchema.strSchema("Playlist name to play.")),
                        ("track", ToolSchema.strSchema("Exact song name to play; several with that name play nothing and are listed.")),
                        ("artist", ToolSchema.strSchema("Artist, to pick among songs with the same name.")),
                        ("seconds", ToolSchema.intSchema("Play only: 1–30 whole seconds, then stop through Music's player before returning. Starts the selected song (or the first song of playlist) at the beginning. Stop/cancellation also settles the stop; a different track taken over by someone else is left alone.", minimum: 1, maximum: 30)),
                    ],
                    required: []
                )
            ),
            // Sensitive writes default off; scheduler.write defaults on with no read axis.
            requestedSchema(name: "mac_calendar_create_event",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Create a local Calendar entry via EventKit; this does not send invitations. With full access, choose an explicit destination; with write-only access, omit calendar_id and calendar_name to use the system default. Requires Calendar Write permission. start/end accept ISO-8601 or epoch seconds.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Event title (required).")),
                        ("start", stringOrIntSchema("Start time — ISO-8601 string (e.g. '2026-06-07T15:00:00Z') or integer epoch seconds (required).")),
                        ("end", stringOrIntSchema("Optional end time — ISO-8601 string or integer epoch seconds. Defaults to start + 1 hour.")),
                        ("notes", ToolSchema.strSchema("Optional notes / description.")),
                        ("location", ToolSchema.strSchema("Optional location string.")),
                        ("calendar_name", ToolSchema.strSchema("Unique exact calendar name, only when calendar_id is omitted; ambiguous names fail.")),
                        ("calendar_id", ToolSchema.strSchema("Explicit EventKit calendar ID from calendar.calendars. Required with full access unless a unique exact calendar_name is supplied. With write-only access, omit calendar_id and calendar_name to use the system default.")),
                    ],
                    required: ["title", "start"]
                )
            ),
            requestedSchema(name: "mac_calendar_modify_event", toolClass: .write, reach: .his,
                description: "Modify an existing calendar event. Requires id from a prior calendar.upcoming. Pass only the fields to change. Requires Calendar → Write permission.",
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
                toolClass: .destructive, reach: .his, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                description: "Delete exactly one calendar event occurrence by id from calendar.upcoming. Requires the observed title and start as preconditions; a changed event is not deleted. Never deletes a recurring series. Requires Calendar → Write and EventKit full access. Use only for an explicitly requested deletion.",
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
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
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
                toolClass: .write, reach: .his, capabilities: ["safe_read", "tool_call"],
                description: "Rename exactly one Mac Reminders list via EventKit and read back its saved name. Matches names ignoring case and whitespace; emoji and variation selectors are significant. Refuses ambiguous or read-only lists and duplicate destination names. Requires Reminders → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("list", ToolSchema.strSchema("Exact existing Reminders list name.")),
                        ("new_name", ToolSchema.strSchema("New nonempty, unique list name.")),
                    ],
                    required: ["list", "new_name"]
                )
            ),
            requestedSchema(name: "mac_reminders_list_create",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "safe_read", "tool_call"],
                description: "Create a Mac Reminders list via EventKit in the default reminder list's account and read back its saved name. Refuses duplicate names or an unavailable or read-only default list. Requires Reminders → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [("name", ToolSchema.strSchema("Nonempty, unique name for the new Reminders list."))],
                    required: ["name"]
                )
            ),
            requestedSchema(name: "mac_reminders_update", toolClass: .write, reach: .his,
                description: "Update exactly one Mac Reminder by id. Change only supplied title, notes or due_date; preserves its list and completion. Requires Reminders → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("Exact reminder id from a reminder query, read or creation.")),
                        ("title", ToolSchema.strSchema("New nonempty title; omitted leaves it unchanged.")),
                        ("notes", ToolSchema.strSchema("New notes; omitted leaves them unchanged. Use clear_fields to remove them.")),
                        ("due_date", stringOrIntSchema("New due date: ISO-8601, local YYYY-MM-DD, or epoch seconds; omitted leaves it unchanged. Use clear_fields to remove it.")),
                        ("clear_fields", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.enumStringSchema(["notes", "due_date"])),
                            ("description", .string("Fields to clear: notes or due_date. Do not also supply a value for a cleared field."))])),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(name: "mac_reminders_complete", toolClass: .write, reach: .his,
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
                toolClass: .destructive, reach: .his, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                description: "Delete exactly one Mac Reminder by id from reminders.create or reminders.due_today. Requires its observed title as a precondition; a changed reminder is not deleted. Requires Reminders → Write permission. Use only for an explicitly requested deletion.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("Exact reminder id from reminders.create or reminders.due_today.")),
                        ("expected_title", ToolSchema.strSchema("Exact title observed for this reminder.")),
                    ],
                    required: ["id", "expected_title"]
                )
            ),
            requestedSchema(name: "mail_mark_read",
                toolClass: .write, reach: .his, capabilities: ["app_data_write", "tool_call"],
                description: "Mark read a selected inbox result set: pass messages from mail.search (1–50) as the only argument. Returns per-message receipts; partial or uncertain work is explicit. If unread search has_more, repeat the same search without offset after marking, since the result set shrinks. Also accepts one exact locator or every message with a subject. Requires Mail → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("messages", mailBatchItemsSchema(effects: true, markReadOnly: true)),
                        ("subject", ToolSchema.strSchema("Or the message's subject, when there's no message_id.")),
                        ("sender", ToolSchema.strSchema("Optional sender filter with subject.")),
                    ] + mailIdentityFields("Inbox message_id from mail.recent.", expectedMessage: "expected_message_id from the same row."),
                    required: []
                )
            ),
            requestedSchema(name: "mail_archive", toolClass: .write, reach: .his,
                description: "Archive one inbox message by message_id + expected_message_id from mail.recent, or a subject only one message has. Requires Mail → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("subject", ToolSchema.strSchema("Or the message's subject, when there's no message_id.")),
                        ("sender", ToolSchema.strSchema("Optional sender filter with subject.")),
                    ] + mailIdentityFields("Inbox message_id from mail.recent.", expectedMessage: "expected_message_id from the same row."),
                    required: []
                )
            ),
            requestedSchema(name: "mail_delete",
                toolClass: .write, reach: .his, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                description: "Move one message to its account's Trash, including archived mail, by message_id + expected_message_id from a prior read, or a subject only one indexed message has. Rechecks identity in its current mailbox. Never permanently deletes. Requires Mail → Write permission and the existing approval policy.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("subject", ToolSchema.strSchema("Or the message's subject, when there's no message_id.")),
                        ("sender", ToolSchema.strSchema("Optional sender filter with subject.")),
                    ] + mailIdentityFields("Message_id from a prior Mail read; the message may have been archived since that read.",
                        expectedMessage: "expected_message_id from the same row.", position: "Optional prior position hint; deletion locates the current mailbox by indexed identity."),
                    required: []
                )
            ),
            requestedSchema(name: "mail_reply",
                toolClass: .send, reach: .his, capabilities: ["external_send", "tool_call"],
                description: "Sends a reply now to an exact inbox message_id plus expected_message_id, or a uniquely matching subject (and optional sender). Ambiguous or changed targets are refused. Requires Mail → Write permission (off by default).",
                parametersJSON: ToolSchema.params(properties: mailReplyFields, required: ["body"])
            ),
            requestedSchema(name: "mail_draft", toolClass: .write, reach: .his,
                description: "Saves an unsent email in Apple Mail → Drafts, without sending or opening a window. Use for draft, don't send, just draft, save as draft or not yet requests. For a reply, use an exact inbox message_id plus expected_message_id, or a uniquely matching subject (and optional sender); ambiguous or changed targets are refused. For a new email, supply to, subject and body instead. Requires Mail Write permission. Confirms a new Drafts message by subject, recipients and content after saving; returns created, saved_in and the saved message's draft_id. Inspect drafts with mail.recent or mail.search using mailbox:\"drafts\"; never repeat an unconfirmed save before checking.",
                parametersJSON: ToolSchema.params(properties: mailReplyFields + [
                    ("to", stringOrStringArraySchema("Recipient address(es) for a new draft. Omit for a reply draft.")),
                    ("cc", stringOrStringArraySchema("Optional CC recipient(s) for a new draft.")),
                    ("bcc", stringOrStringArraySchema("Optional BCC recipient(s) for a new draft.")),
                ], required: ["body"])
            ),
            requestedSchema(name: "notes_update", toolClass: .write, reach: .his,
                description: "Update one Apple Note by id from notes.search or a unique exact title. Supply body, append, new_title or clear_fields:[\"body\"]. Clearing empties the body and cannot be combined with body/append. Requires Notes → Write permission (off by default).",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("The note's id from notes.search; use it when two notes share a title.")),
                        ("title", ToolSchema.strSchema("Exact title of the note to update (as notes.search shows it).")),
                        ("body", ToolSchema.strSchema("Replace the note's text under its title; the title stays unless new_title is given.")),
                        ("append", ToolSchema.strSchema("Add this as a new line at the end of the note.")),
                        ("new_title", ToolSchema.strSchema("Rename the note to this title.")),
                        ("clear_fields", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.enumStringSchema(["body"])),
                            ("description", .string("[\"body\"] is a valid update by itself; empties the body. Cannot combine with body or append."))])),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "notes_delete",
                toolClass: .write, reach: .his, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                description: "Delete one Apple Note by id or an exact title only one note has. Moves it to Recently Deleted, where it can be restored; returns that reversible outcome. Requires Notes → Write permission (off by default).",
                parametersJSON: ToolSchema.params(properties: [
                    ("id", ToolSchema.strSchema("The note's id from notes.search; use it when two notes share a title.")),
                    ("title", ToolSchema.strSchema("Exact title of the note to delete; duplicate titles refuse without changing anything.")),
                ], required: [])
            ),
            requestedSchema(name: "music_search_library", toolClass: .read, reach: .his,
                description: "Search the user's Apple Music library by query; returns tracks with count, total and has_more. Read-only; requires Music -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Search string (required).")),
                        ("kind", ToolSchema.enumStringSchema(["track", "artist", "album"], "What to search for — one of track / artist / album. Defaults to track.")),
                        ("limit", ToolSchema.intSchema("Maximum results to return (1-100, default 20).")),
                        ("offset", ToolSchema.intSchema("Zero-based match offset. Defaults to 0.")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(name: "music_list_library", toolClass: .read, reach: .his,
                description: "Page the Apple Music library with sort and filter applied before paging; returns count, filtered total and has_more. Read-only; requires Music -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("offset", ToolSchema.intSchema("Zero-based track offset. Defaults to 0.")),
                        ("limit", ToolSchema.intSchema("Maximum tracks to return (1-100, default 50).")),
                        ("sort", ToolSchema.enumStringSchema(["title", "artist", "added"], "Title or artist ascending, or newest added first. Defaults to title; ties retain library order.")),
                        ("filter", ToolSchema.obj([
                            ("type", .string("object")), ("additionalProperties", .bool(false)),
                            ("properties", ToolSchema.obj([
                                ("artist", ToolSchema.strSchema("Artist contains this text, ignoring case.")),
                                ("album", ToolSchema.strSchema("Album contains this text, ignoring case.")),
                                ("genre", ToolSchema.strSchema("Genre contains this text, ignoring case.")),
                            ])),
                        ])),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "music_list_playlists", toolClass: .read, reach: .his,
                description: "Page Apple Music playlists with names, track counts and kind: owner / smart / library; returns count, total and has_more. Read-only; requires Music -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("offset", ToolSchema.intSchema("Zero-based playlist offset. Defaults to 0.")),
                        ("limit", ToolSchema.intSchema("Maximum playlists to return (1-100, default 50).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "contacts_delete",
                toolClass: .destructive, reach: .his, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                description: "Delete a Mac contact by its identifier from contacts.search or its exact full name. Requires Contacts -> Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("identifier", ToolSchema.strSchema("identifier from contacts.search, or the exact full name.")),
                    ],
                    required: ["identifier"]
                )
            ),
        ]
        return schemas
    }
}

import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AppToolExecutor+ToolSchemas.swift` | `AppToolExecutor`: immutable non-door schemas and independently lazy door schema via `appToolSchemas`, preserving the registry initialization boundary |

extension AppToolExecutor {
    /// `includeDoor: false` leaves out `app` itself, whose description reads
    /// the action registry: the registry's fold table reads the other
    /// schemas from here, and must not reach back into its own initializer.
    public static func appToolSchemas(includeDoor: Bool = true) -> [LLMToolSchema] {
        includeDoor ? doorSchemas + nonDoorSchemas : nonDoorSchemas
    }

    private static let nonDoorSchemas = makeAppToolSchemas(includeDoor: false)
    private static let doorSchemas = makeAppToolSchemas(includeDoor: true)

    private static func makeAppToolSchemas(includeDoor: Bool) -> [LLMToolSchema] {

        func stringArraySchema(_ desc: String) -> JSONValue {
            ToolSchema.obj([
                ("type", .string("array")),
                ("items", .object(["type": .string("string")])),
                ("minItems", .int(1)),
                ("maxItems", .int(100)),
                ("description", .string(desc)),
            ])
        }
        // 09-24: a form in one call; snapshot_id defaults to the last page read.
        let fieldsSchema = ToolSchema.obj([("type", .array([.string("object"), .string("string")])),
            ("additionalProperties", .object(["type": .array([.string("string"), .string("number"), .string("boolean")])])),
            ("description", .string("Fields by shown label/row: {\"Email\":\"a@b.com\",\"Country\":\"Canada\",\"Remember me\":true} or \"Email: a@b.com; Country: Canada\"."))])
        let submitSchema = ToolSchema.obj([("type", .array([.string("string"), .string("boolean")])),
            ("description", .string("After fill: button label/row to click, or true for Enter in the last field."))])
        let snapshotDefault = "Optional; defaults to this tab's last-read page."

        let door: [LLMToolSchema] = !includeDoor ? [] : [
            // One door: always on, static. Pages and actions travel in its
            // results; only the hot actions ride its description, and they
            // change only at a release.
            LLMToolSchema(
                name: "app",
                toolClass: .read, capabilities: ["app_data_write", "safe_read", "tool_call"],
                description: "NativeAgent itself, worked in process: your home, its pages, settings and buttons, and every tool you have. Nothing comes forward on the owner's screen unless an action says screen. {} is your home first, where you left off (open agent windows, work in progress, what waits and what arrived, each with a name like desk.4, mail or an agent's name), then a line per page and the action ids that work on every page. item alone opens a name or ref from home or one of its rooms; its text or fields go in args. page (+item) reads one: what it shows, its settings, its version, and its actions as id(args) label; the owner's ones say why and where they do them. action + args does one; the receipt says what changed and what else the app did. preview:true performs no proposed effects: native preflight reports checks, would_card and approver; authored preview runs live reads with writes previewed; resume preview only inspects stopped work; script previews describe only calls reached. expected_version refuses if the page changed since that read. find takes words (\"disconnect telegram\") and returns matching pages and actions, one line each as id(args) label; an action id named in the words (\"mail.search\") returns its args_schema and example. script runs a JavaScript function body that finishes a task in one call; app.* calls return synchronously and top-level await is not supported: app.<page>.<action>(args) for any action, as app.inbox.archive({ids, reason}), plus app.read(page, item) (a home item opens only outside a script), app.find(words) and app.log(text); return what you want back. Each call passes the turn's gates and gets its own ledger row. A call needing approval waits for the card: approved returns its real result. A call that fails or is declined throws AppError (reason, receipt), which code can catch and continue. A shell or bash command that ran has answered: exit_code, stdout, stderr and timed_out come back as data whatever the exit code; it throws only when the command didn't run. card.request waits and returns the person's answer. Full Mac writes need no approval card. Owner-only or blocked calls still stop at that line; earlier calls stay done. "
                    + "Permitted reads need no permission: do them.mac.go opens apps, files and folders; content readers only read. "
                    + "One action uses app {action:\"files.read\",args:{path:\"README.md\"}}. Put its arguments inside args; page selects a reader, not an action id. find always discovers actions, including with page:\"home\"; use work.context {query} or chat.search {query} for saved work and history. Call these without a read first: " + AppActions.hot.map(\.hotLine).joined(separator: "; ") + ".",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("page", ToolSchema.strSchema("A page id from {}, such as inbox, chat or providers.")),
                        ("item", ToolSchema.strSchema("With page: one thing on it, a note id on inbox or a conversation id on chat; actions reads full action signatures when the page returns a compact catalog. Alone: a name or ref from home or its rooms (desk.4, mail.find, an agent's name), with args {text, conversation?} for an agent message or {fields} for a form.")),
                        ("action", ToolSchema.strSchema("An action id from a read, such as inbox.archive.")),
                        ("args", ToolSchema.obj([("type", .string("object")),
                                      ("description", .string("The action's arguments by name, as its id(args) line shows; for a home item, text or fields. A list where the action takes one value (handle:[…]) runs it once per value."))])),
                        ("actions", ToolSchema.obj([("type", .string("array")), ("items", .object(["type": .string("object")])), ("maxItems", .int(Int64(AppScriptRunner.actionLimit))),
                                         ("description", .string("Many calls in one, in order: each {action, args}, {page[, item]} or {item}, so several pages or items are one call. Every one runs and reports itself with its own receipt; preview and expected_version beside it apply to each, a write's new version passing to the next on its page. Steps are independent: one step's result never reaches the next; to feed one call's output into another, use script."))])),
                        ("preview", ToolSchema.boolSchema("With action or script: report proposed effects without performing them; authored reads run live, resume only inspects. Native preflight reports checks, would_card and approver. Script previews describe only calls reached.")),
                        ("expected_version", ToolSchema.strSchema("With action: the version a read returned. Refused, with nothing done, if that page changed since. It hashes what the page shows, so a page changed and changed back has its old version again.")),
                        ("find", ToolSchema.strSchema("What you want done, in words. Discovers actions on every page, including home, one line each as id(args) label, with the best match's example. Name an action's id in the words for its args_schema and example. Search history explicitly with work.context or chat.search.")),
                        ("script", ToolSchema.strSchema("JavaScript function body: app.* calls return synchronously; top-level await is not supported. No direct network or file APIs; use eligible app actions. Up to 512 KB, 50 actions, 100 reads and 60 seconds of script time; time waiting on app calls does not count.")),
                    ],
                    required: []
                )
            ),
        ]
        if includeDoor { return door }
        return [
            LLMToolSchema(
                name: "chat_reply",
                toolClass: .send, capabilities: ["external_send", "tool_call"],
                description: "Reply to an exact opened human conversation's saved destination; the chat read binds its conversation/latest message. Creates no user turn or foreground-chat change. Answer your active conversation normally. Never automatically resend uncertain delivery.",
                parametersJSON: ToolSchema.params(properties: [
                    ("conversation_session_id", ToolSchema.strSchema("Exact conversation id from app {page:\"chat\", item}.")),
                    ("last_message_id", ToolSchema.strSchema("Exact last_message_id from the opened conversation; changed conversations must be read again.")),
                    ("text", ToolSchema.strSchema("The assistant reply, up to 16000 characters."))
                ], required: ["conversation_session_id", "last_message_id", "text"])
            ),
            LLMToolSchema(
                name: "browser.status",
                toolClass: .read,
                description: "Return visible NativeAgent Browser status and recent browser run receipts.",
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "browser.open_url",
                toolClass: .read, capabilities: ["network_read", "tool_call"],
                description: "Open an http/https URL in the visible NativeAgent Browser and record a browser run receipt.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("url", ToolSchema.strSchema("HTTP or HTTPS URL to open.")),
                        ("capture_source", ToolSchema.boolSchema("After navigation, capture visible page text to a source receipt. Defaults false.")),
                        ("capture_screenshot", ToolSchema.boolSchema("After navigation, capture a PNG screenshot receipt. Defaults false.")),
                        ("dry_run", ToolSchema.boolSchema("If true, only record a dry-run browser receipt. Defaults false.")),
                    ],
                    required: ["url"]
                )
            ),
            LLMToolSchema(
                name: "browser.read_text",
                toolClass: .read,
                description: "Read visible page text from the current NativeAgent Browser page and persist a source receipt. Current page must be http/https.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("dry_run", ToolSchema.boolSchema("If true, record a dry-run receipt without reading the page. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.read_links",
                toolClass: .read,
                description: "Read links from the current NativeAgent Browser page and persist a link-source receipt. Current page must be http/https.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("dry_run", ToolSchema.boolSchema("If true, record a dry-run receipt without reading links. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.screenshot",
                toolClass: .read,
                description: "Capture a PNG screenshot from the current NativeAgent Browser page and persist a screenshot receipt. Current page must be http/https.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("dry_run", ToolSchema.boolSchema("If true, record a dry-run receipt without capturing an image. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_status",
                toolClass: .read,
                description: "Whether the Chrome extension is connected and which tabs are yours in the NativeAgent group. released lists the last eight tabs that stopped being yours in this app run, with their reason, time and URL.",
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_reload_extension",
                toolClass: .write, capabilities: ["safe_read", "tool_call"],
                description: "Reload the connected Chrome extension quietly. Your NativeAgent group tabs stay open. Returns the reconnect receipt or failure.",
                parametersJSON: ToolSchema.params(properties: [("dry_run", ToolSchema.boolSchema("Describe current connection without reloading the extension."))], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_setup",
                toolClass: .write, capabilities: ["ax_injection", "outside_app_data_write", "tool_call"],
                description: "Set up Chrome with your Mac controls and verify the extension connected. Opens Chrome in front, turns on Developer mode and loads the bundled extension. Existing Trust and macOS grants apply.",
                parametersJSON: ToolSchema.params(properties: [("dry_run", ToolSchema.boolSchema("Describe current connection without preparing files or opening apps."))], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_close_tab",
                toolClass: .write, capabilities: ["app_data_write", "tool_call"],
                description: "Explicitly close one of your NativeAgent group tabs. Omit tab_id for this conversation's tab. The person's tabs cannot be closed.",
                parametersJSON: ToolSchema.params(properties: [
                    ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                    ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional observed user sequence; omit to use the current page's sequence."))),
                ], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_look",
                toolClass: .read,
                description: "Look at one of your NativeAgent group tabs: the picture Chrome renders of it now, without activating or moving it. Internal pages return one line with their title, URL and no-reader reason (read_mode none), without a picture attempt. Omit tab_id for this conversation's tab. The person's tabs cannot be looked at.",
                parametersJSON: ToolSchema.params(properties: [
                    ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                ], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_navigate",
                toolClass: .read, capabilities: ["network_read", "tool_call"],
                description: "Open/read a URL in this conversation's last tab if it is still in the NativeAgent group; otherwise open a new tab there. The owner's tabs are never used. Chrome's completed tab and landed URL verify arrival, including internal pages and PDFs. Returns main content as numbered rows, or the displayed picture with a no-DOM note for PDFs/pages without DOM access; HTTP PDFs keep the independent unverified text transcript beside the verified picture. Internal pages return one title/URL/no-reader line with read_mode none. Unsupported schemes such as javascript: and data: refuse before any tab changes. url back/forward moves through this tab's history. fields + submit fills/sends a form in this call.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("url", ToolSchema.strSchema("HTTP(S) destination, or back / forward to go through this tab's history like the Back button.")),
                        ("fields", fieldsSchema),
                        ("submit", submitSchema),
                        ("scope", ToolSchema.enumStringSchema(["main_content", "page"], "Returned page: main_content (default) or page to include the site's nav.")),
                    ],
                    required: ["url"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_snapshot",
                toolClass: .read,
                description: "Read Chrome's ready rendered document in reading order, including inline links; a read says when the tab is still loading. Internal pages return one title/URL/no-reader line with read_mode none. Other pages and PDFs without DOM access return the displayed picture with read_mode picture and an explicit reason. HTTP PDFs retain an independent text transcript in the same receipt: unverified against Chrome's displayed document, without Chrome cookies/authentication. DOM reads carry url, title, snapshot_id, version, captured_at, bytes and has_more; act with node_id (row number as a string or label). Read folded sections with the supplied more address; scrolling remains an action. scope page adds site nav.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional user-sequence proof from the Chrome reader."))),
                        ("max_nodes", ToolSchema.intSchema("Maximum rows, 1 through 200. Defaults 150.")),
                        ("max_text_chars", ToolSchema.intSchema("Maximum readable text characters, 1 through 40000. Defaults 12000.")),
                        ("scope", ToolSchema.enumStringSchema(["page", "main_content"], "Rendered page or main_content: declared main regions, else article bodies, else the document body, excluding navigation. Reports when no main/article region was declared; scope page includes navigation.")),
                        ("more", ToolSchema.strSchema("Structural cursor from the page's More address (the more string in next); reads the current snapshot of the same URL without scrolling.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_click",
                toolClass: .write, capabilities: ["browser_interaction", "tool_call"],
                description: "Click one row of the current Chrome page with node_id: a row number as a string (\"73\") or its label (\"Sign in\"). Waits for any navigation it starts and returns the fresh page; no snapshot call needed.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Row number from the page, or the row's label.")),
                    ],
                    required: ["node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_media",
                toolClass: .write, capabilities: ["safe_read", "tool_call"],
                description: "Play, pause or seek the first audio/video in your Chrome tab, and only that player. Reports paused state, current time and whether the player confirmed it: playback advancing, the pause holding, the seek landing.Resume uses play; stop-playing uses pause.",
                parametersJSON: ToolSchema.params(properties: [
                    ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                    ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional observed user sequence; omit to use the current tab's sequence."))),
                    ("operation", ToolSchema.enumStringSchema(["play", "pause", "seek"], "Media operation.")),
                    ("seconds", .object(["type": .string("number"), "minimum": .int(0), "description": .string("Nonnegative playback position in seconds; required for seek.")])),
                ], required: ["operation"])
            ),
            LLMToolSchema(
                name: "browser.chrome_scroll",
                toolClass: .read,
                description: "Move a Chrome page or scrollable row by delta_y pixels. Returns newly visible rows, distance moved and remaining below; explicitly reports no movement.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema("Snapshot id when targeting a node. For page scrolling omit both optional IDs or supply both as empty strings.")),
                        ("target_node_id", ToolSchema.strSchema("Optional scrollable node id. Node scrolling requires both exact IDs from a fresh snapshot.")),
                        ("delta_x", ToolSchema.intSchema("Horizontal scroll delta.")),
                        ("delta_y", ToolSchema.intSchema("Vertical scroll delta.")),
                    ],
                    required: ["delta_y"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_fill",
                toolClass: .write, capabilities: ["browser_interaction", "tool_call"],
                description: "Fill the current Chrome form: fields {label or row: value} sets text boxes/selects/checkboxes in page order, then submit clicks a button (true presses Enter). Finds all fields before typing. For one row use node_id + value. Returns filled fields and fresh page; never retries ambiguous dispatch.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("fields", fieldsSchema),
                        ("submit", submitSchema),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("One editable row: its number or label.")),
                        ("value", ToolSchema.strSchema("Replacement text for node_id, at most 50000 characters.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_type",
                toolClass: .write, capabilities: ["browser_interaction", "tool_call"],
                description: "Append text to an editable row (number or label), up to 20 s; returns typed progress and the fresh page. On partial progress send only the rest, never the whole text again.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Editable row: its number or label.")),
                        ("text", ToolSchema.strSchema("Text to append, at most 50000 characters.")),
                        ("delay_ms", ToolSchema.intSchema("Optional delay between characters, 0 through 250 milliseconds.")),
                    ],
                    required: ["node_id", "text"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_select",
                toolClass: .write, capabilities: ["browser_interaction", "tool_call"],
                description: "Choose options in a select row by value or label (shown as label=value, * selected). Returns the fresh page.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Select row: its number or label.")),
                        ("values", stringArraySchema("Option values or labels; single-select rows take exactly one.")),
                    ],
                    required: ["node_id", "values"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_keypress",
                toolClass: .write, capabilities: ["browser_interaction", "tool_call"],
                description: "Press a key or chord in a row (number or label): Enter, Tab, Escape, arrows, a single character like j or /. To move down the page use browser.chrome_scroll; to go back, browser.chrome_navigate{url:\"back\"}. Verified by what changed; returns the fresh page.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Row to press in: its number or label.")),
                        ("key", ToolSchema.strSchema("Enter, Tab, Shift+Tab, Escape, ArrowDown/Up/Left/Right, Home, End, PageUp, PageDown, Backspace, Delete, Space, Control+A, Meta+A, or one character (j, k, /).")),
                    ],
                    required: ["node_id", "key"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_set_checked",
                toolClass: .write, capabilities: ["browser_interaction", "tool_call"],
                description: "Set a checkbox, radio or switch row on or off (idempotent). Returns the fresh page.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Checkable row: its number or label.")),
                        ("checked", ToolSchema.boolSchema("Exact checked state to apply.")),
                    ],
                    required: ["node_id", "checked"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_double_click",
                toolClass: .write, capabilities: ["browser_interaction", "tool_call"],
                description: "Double-click a row (number or label). Verified by what changed; returns the fresh page.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Row: its number or label.")),
                    ],
                    required: ["node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_drag",
                toolClass: .write,
                description: "Drag a drag-advertising node onto a drop-advertising node in one exact fresh Chrome snapshot/frame. Uses synthetic HTML events and page DataTransfer handlers without activating the tab. Target must accept dragover. dropDispatched does not prove success; check returned page. No OS/file dragging or pointer-only canvas gestures. Never automatically retry unknown outcomes.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema("Fresh snapshot containing both endpoints.")),
                        ("node_id", ToolSchema.strSchema("Source row number or label advertising drag.")),
                        ("target_node_id", ToolSchema.strSchema("Target row number or label advertising drop; acceptance is checked during the operation.")),
                    ],
                    required: ["snapshot_id", "node_id", "target_node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_wait",
                toolClass: .read,
                description: "Wait up to 10 s for the tab to settle or a row to become visible/hidden/enabled/disabled. Rarely needed: acts already wait for navigation.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("condition", ToolSchema.enumStringSchema(["element_state", "navigation_settled"], "Wait condition.")),
                        ("snapshot_id", ToolSchema.strSchema("Exact current snapshot id for element_state.")),
                        ("node_id", ToolSchema.strSchema("Row number or label that advertised wait for element_state.")),
                        ("state", ToolSchema.enumStringSchema(["visible", "hidden", "enabled", "disabled"], "Required element state.")),
                        ("timeout_ms", ToolSchema.intSchema("Bounded timeout from 100 through 10000 milliseconds. Defaults 5000.")),
                        ("settle_ms", ToolSchema.intSchema("Extra navigation quiet interval from 0 through 2000 milliseconds.")),
                    ],
                    required: ["condition"]
                )
            ),
        ]
    }
}

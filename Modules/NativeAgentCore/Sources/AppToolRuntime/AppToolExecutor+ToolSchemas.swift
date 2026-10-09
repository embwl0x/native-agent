import Foundation
import NativeAgentCore
import PersistenceCore

extension AppToolExecutor {
    /// `includeDoor: false` leaves out `app` itself, whose description reads
    /// the action registry: the registry's fold table reads the other
    /// schemas from here, and must not reach back into its own initializer.
    public static func appToolSchemas(includeDoor: Bool = true) -> [LLMToolSchema] {
        func obj(_ pairs: [(String, JSONValue)]) -> JSONValue {
            var d: [String: JSONValue] = [:]
            for (k, v) in pairs { d[k] = v }
            return .object(d)
        }
        func strSchema(_ desc: String) -> JSONValue {
            obj([
                ("type", .string("string")),
                ("description", .string(desc)),
            ])
        }
        func boolSchema(_ desc: String) -> JSONValue {
            obj([
                ("type", .string("boolean")),
                ("description", .string(desc)),
            ])
        }
        func intSchema(_ desc: String) -> JSONValue {
            obj([
                ("type", .string("integer")),
                ("description", .string(desc)),
            ])
        }
        func nullable(_ schema: JSONValue) -> JSONValue {
            guard case .object(var value) = schema, let type = value["type"] else { return schema }
            value["type"] = .array([type, .string("null")])
            return .object(value)
        }
        func enumStringSchema(_ values: [String], _ desc: String) -> JSONValue {
            obj([
                ("type", .string("string")),
                ("enum", .array(values.map { .string($0) })),
                ("description", .string(desc)),
            ])
        }
        func stringArraySchema(_ desc: String) -> JSONValue {
            obj([
                ("type", .string("array")),
                ("items", .object(["type": .string("string")])),
                ("minItems", .int(1)),
                ("maxItems", .int(100)),
                ("description", .string(desc)),
            ])
        }
        // 09-24: a form in one call; snapshot_id defaults to the last page read.
        let fieldsSchema = obj([("type", .array([.string("object"), .string("string")])),
            ("description", .string("Fields by shown label/row: {\"Email\":\"a@b.com\",\"Country\":\"Canada\",\"Remember me\":true} or \"Email: a@b.com; Country: Canada\"."))])
        let submitSchema = obj([("type", .array([.string("string"), .string("boolean")])),
            ("description", .string("After fill: button label/row to click, or true for Enter in the last field."))])
        let snapshotDefault = "Optional; defaults to this tab's last-read page."
        func params(properties: [(String, JSONValue)], required: [String]) -> Data {
            let v = obj([
                ("type", .string("object")),
                ("properties", obj(properties)),
                ("required", .array(required.map { .string($0) })),
            ])
            return (try? v.serializedData(pretty: false)) ?? Data("{}".utf8)
        }
        let door: [LLMToolSchema] = !includeDoor ? [] : [
            // One door: always on, static. Pages and actions travel in its
            // results; only the hot actions ride its description, and they
            // change only at a release.
            LLMToolSchema(
                name: "app",
                description: "NativeAgent itself, worked in process: your home, its pages, settings and buttons, and every tool you have. Nothing comes forward on the owner's screen unless an action says screen. {} is your home first, where you left off (open agent windows, work in progress, what waits and what arrived, each with a name like desk.4, mail or an agent's name), then the pages and their action ids. item alone opens a name or ref from home or one of its rooms; its text or fields go in args. page (+item) reads one: what it shows, its settings, its version, and its actions as id(args) label; the owner's ones say why and where they do them. action + args does one; the receipt says what changed and what else the app did. preview:true reports checks, would_card and approver and does nothing; script previews describe only calls reached. expected_version refuses if the page changed since that read. find takes words (\"disconnect telegram\") and returns matching pages and actions with args_schema, one example and scriptable. script runs a JavaScript function body that finishes a task in one call; app.* calls return synchronously and top-level await is not supported: app.<page>.<action>(args) for any action whose line does not say not in scripts, as app.inbox.archive({ids, reason}), plus app.read(page, item) (a home item opens only outside a script), app.find(words) and app.log(text); return what you want back. Each call is checked as its own action and gets a ledger row; one that is still the owner's, blocked or waiting on their card stops the script at that line, and the calls before it stay done. "
                    + "Permitted reads need no permission: do them. Finish every requested action and read before answering, and use every option the request names. mac.go opens apps, files and folders; content readers only read. "
                    + "One action uses app {action:\"files.read\",args:{path:\"README.md\"}}. Put its arguments inside args; page selects a reader, not an action id. find always discovers actions, including with page:\"home\"; use work.context {query} or chat.search {query} for saved work and history. Call these without a read first: " + AppActions.hot.map(\.hotLine).joined(separator: "; ") + ".",
                parametersJSON: params(
                    properties: [
                        ("page", strSchema("A page id from {}, such as inbox, chat or providers.")),
                        ("item", strSchema("With page: one thing on it, a note id on inbox or a conversation id on chat; actions reads full action signatures when the page returns a compact catalog. Alone: a name or ref from home or its rooms (desk.4, mail.find, an agent's name), with args {text, conversation?} for an agent message or {fields} for a form.")),
                        ("action", strSchema("An action id from a read, such as inbox.archive.")),
                        ("args", obj([("type", .string("object")),
                                      ("description", .string("The action's arguments by name, as its id(args) line shows; for a home item, text or fields."))])),
                        ("preview", boolSchema("With action or script: report checks, would_card and approver; nothing is done. Script previews describe only calls reached.")),
                        ("expected_version", strSchema("With action: the version a read returned. Refused, with nothing done, if that page changed since. It hashes what the page shows, so a page changed and changed back has its old version again.")),
                        ("find", strSchema("What you want done, in words. Discovers actions on every page, including home, with args_schema, one example and scriptable. Search history explicitly with work.context or chat.search.")),
                        ("script", strSchema("JavaScript function body: app.* calls return synchronously; top-level await is not supported. No direct network or file APIs; use eligible app actions. Up to 8 KB, 50 actions, 100 reads and 60 seconds of script time; time waiting on app calls does not count.")),
                    ],
                    required: []
                )
            ),
        ]
        return door + [
            LLMToolSchema(
                name: "chat_reply",
                description: "Reply to an exact opened human conversation's saved destination; the chat read binds its conversation/latest message. Creates no user turn or foreground-chat change. Answer your active conversation normally. Never automatically resend uncertain delivery.",
                parametersJSON: params(properties: [
                    ("conversation_session_id", strSchema("Exact conversation id from app {page:\"chat\", item}.")),
                    ("last_message_id", strSchema("Exact last_message_id from the opened conversation; changed conversations must be read again.")),
                    ("text", strSchema("The assistant reply, up to 16000 characters."))
                ], required: ["conversation_session_id", "last_message_id", "text"])
            ),
            LLMToolSchema(
                name: "browser.status",
                description: "Return visible NativeAgent Browser status and recent browser run receipts.",
                parametersJSON: params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "browser.open_url",
                description: "Open an http/https URL in the visible NativeAgent Browser and record a browser run receipt.",
                parametersJSON: params(
                    properties: [
                        ("url", strSchema("HTTP or HTTPS URL to open.")),
                        ("capture_source", boolSchema("After navigation, capture visible page text to a source receipt. Defaults false.")),
                        ("capture_screenshot", boolSchema("After navigation, capture a PNG screenshot receipt. Defaults false.")),
                        ("dry_run", boolSchema("If true, only record a dry-run browser receipt. Defaults false.")),
                    ],
                    required: ["url"]
                )
            ),
            LLMToolSchema(
                name: "browser.read_text",
                description: "Read visible page text from the current NativeAgent Browser page and persist a source receipt. Current page must be http/https.",
                parametersJSON: params(
                    properties: [
                        ("dry_run", boolSchema("If true, record a dry-run receipt without reading the page. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.read_links",
                description: "Read links from the current NativeAgent Browser page and persist a link-source receipt. Current page must be http/https.",
                parametersJSON: params(
                    properties: [
                        ("dry_run", boolSchema("If true, record a dry-run receipt without reading links. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.screenshot",
                description: "Capture a PNG screenshot from the current NativeAgent Browser page and persist a screenshot receipt. Current page must be http/https.",
                parametersJSON: params(
                    properties: [
                        ("dry_run", boolSchema("If true, record a dry-run receipt without capturing an image. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_status",
                description: "Whether the Chrome extension is connected and which tabs are yours in the NativeAgent group.",
                parametersJSON: params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_reload_extension",
                description: "Reload the connected Chrome extension quietly. Your NativeAgent group tabs stay open. Returns the reconnect receipt or failure.",
                parametersJSON: params(properties: [("dry_run", boolSchema("Describe current connection without reloading the extension."))], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_setup",
                description: "Set up Chrome on request via Trust's owner: prepare/reveal the bundled extension in a visible folder and open Chrome's extensions page, changing focus. Chrome still must load the unpacked extension; help with authorized Mac controls, then check browser.chrome_status. Copying files never proves installation; permissions never change.",
                parametersJSON: params(properties: [("dry_run", boolSchema("Describe current connection without preparing files or opening apps."))], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_close_tab",
                description: "Explicitly close one of your NativeAgent group tabs. Omit tab_id for this conversation's tab. The person's tabs cannot be closed.",
                parametersJSON: params(properties: [
                    ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                    ("expected_user_sequence", nullable(intSchema("Optional observed user sequence; omit to use the current page's sequence."))),
                ], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_navigate",
                description: "Open/read a URL in this conversation's last tab if it is still in the NativeAgent group; otherwise open a new tab there. The owner's tabs are never used. Returns main content as numbered rows. url back/forward moves through this tab's history. fields + submit fills/sends a form in this call.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("url", strSchema("HTTP(S) destination, or back / forward to go through this tab's history like the Back button.")),
                        ("fields", fieldsSchema),
                        ("submit", submitSchema),
                        ("scope", enumStringSchema(["main_content", "page"], "Returned page: main_content (default) or page to include the site's nav.")),
                    ],
                    required: ["url"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_snapshot",
                description: "Read Chrome's rendered document in reading order, including inline links. Act with node_id (row number as a string or label). Reads carry url, title, snapshot_id, version, captured_at, bytes and has_more. Read folded sections with the supplied more address; scrolling remains an action. scope page adds site nav.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional user-sequence proof from the Chrome reader."))),
                        ("max_nodes", intSchema("Maximum rows, 1 through 200. Defaults 150.")),
                        ("max_text_chars", intSchema("Maximum readable text characters, 1 through 40000. Defaults 12000.")),
                        ("scope", enumStringSchema(["page", "main_content"], "Rendered page or semantic main/article content. A main_content read reports when no semantic content region was found; use page to retain surrounding controls.")),
                        ("more", strSchema("Structural cursor from the page's More address (the more string in next); reads the current snapshot of the same URL without scrolling.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_click",
                description: "Click one row of the current Chrome page with node_id: a row number as a string (\"73\") or its label (\"Sign in\"). Waits for any navigation it starts and returns the fresh page; no snapshot call needed.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema(snapshotDefault)),
                        ("node_id", strSchema("Row number from the page, or the row's label.")),
                    ],
                    required: ["node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_media",
                description: "Play, pause or seek the first audio/video in your Chrome tab, and only that player. Reports paused state, current time and whether the player confirmed it: playback advancing, the pause holding, the seek landing. When it is not confirmed, read the page and click the player's own control. Resume uses play; stop-playing uses pause.",
                parametersJSON: params(properties: [
                    ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                    ("expected_user_sequence", nullable(intSchema("Optional observed user sequence; omit to use the current tab's sequence."))),
                    ("operation", enumStringSchema(["play", "pause", "seek"], "Media operation.")),
                    ("seconds", .object(["type": .string("number"), "minimum": .int(0), "description": .string("Nonnegative playback position in seconds; required for seek.")])),
                ], required: ["operation"])
            ),
            LLMToolSchema(
                name: "browser.chrome_scroll",
                description: "Move a Chrome page or scrollable row by delta_y pixels. Returns newly visible rows, distance moved and remaining below; explicitly reports no movement.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema("Snapshot id when targeting a node. For page scrolling omit both optional IDs or supply both as empty strings.")),
                        ("target_node_id", strSchema("Optional scrollable node id. Node scrolling requires both exact IDs from a fresh snapshot.")),
                        ("delta_x", intSchema("Horizontal scroll delta.")),
                        ("delta_y", intSchema("Vertical scroll delta.")),
                    ],
                    required: ["delta_y"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_fill",
                description: "Fill the current Chrome form: fields {label or row: value} sets text boxes/selects/checkboxes in page order, then submit clicks a button (true presses Enter). Finds all fields before typing. For one row use node_id + value. Returns filled fields and fresh page; never retries ambiguous dispatch.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("fields", fieldsSchema),
                        ("submit", submitSchema),
                        ("snapshot_id", strSchema(snapshotDefault)),
                        ("node_id", strSchema("One editable row: its number or label.")),
                        ("value", strSchema("Replacement text for node_id, at most 50000 characters.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_type",
                description: "Append text to an editable row (number or label), up to 20 s; returns typed progress and the fresh page. On partial progress send only the rest, never the whole text again.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema(snapshotDefault)),
                        ("node_id", strSchema("Editable row: its number or label.")),
                        ("text", strSchema("Text to append, at most 50000 characters.")),
                        ("delay_ms", intSchema("Optional delay between characters, 0 through 250 milliseconds.")),
                    ],
                    required: ["node_id", "text"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_select",
                description: "Choose options in a select row by value or label (shown as label=value, * selected). Returns the fresh page.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema(snapshotDefault)),
                        ("node_id", strSchema("Select row: its number or label.")),
                        ("values", stringArraySchema("Option values or labels; single-select rows take exactly one.")),
                    ],
                    required: ["node_id", "values"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_keypress",
                description: "Press a key or chord in a row (number or label): Enter, Tab, Escape, arrows, a single character like j or /. To move down the page use browser.chrome_scroll; to go back, browser.chrome_navigate{url:\"back\"}. Verified by what changed; returns the fresh page.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema(snapshotDefault)),
                        ("node_id", strSchema("Row to press in: its number or label.")),
                        ("key", strSchema("Enter, Tab, Shift+Tab, Escape, ArrowDown/Up/Left/Right, Home, End, PageUp, PageDown, Backspace, Delete, Space, Control+A, Meta+A, or one character (j, k, /).")),
                    ],
                    required: ["node_id", "key"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_set_checked",
                description: "Set a checkbox, radio or switch row on or off (idempotent). Returns the fresh page.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema(snapshotDefault)),
                        ("node_id", strSchema("Checkable row: its number or label.")),
                        ("checked", boolSchema("Exact checked state to apply.")),
                    ],
                    required: ["node_id", "checked"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_double_click",
                description: "Double-click a row (number or label). Verified by what changed; returns the fresh page.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema(snapshotDefault)),
                        ("node_id", strSchema("Row: its number or label.")),
                    ],
                    required: ["node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_drag",
                description: "Drag a drag-advertising node onto a drop-advertising node in one exact fresh Chrome snapshot/frame. Uses synthetic HTML events and page DataTransfer handlers without activating the tab. Target must accept dragover. dropDispatched does not prove success; check returned page. No OS/file dragging or pointer-only canvas gestures. Never automatically retry unknown outcomes.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema("Fresh snapshot containing both endpoints.")),
                        ("node_id", strSchema("Source row number or label advertising drag.")),
                        ("target_node_id", strSchema("Target row number or label advertising drop; acceptance is checked during the operation.")),
                    ],
                    required: ["snapshot_id", "node_id", "target_node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_wait",
                description: "Wait up to 10 s for the tab to settle or a row to become visible/hidden/enabled/disabled. Rarely needed: acts already wait for navigation.",
                parametersJSON: params(
                    properties: [
                        ("tab_id", nullable(intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("condition", enumStringSchema(["element_state", "navigation_settled"], "Wait condition.")),
                        ("snapshot_id", strSchema("Exact current snapshot id for element_state.")),
                        ("node_id", strSchema("Row number or label that advertised wait for element_state.")),
                        ("state", enumStringSchema(["visible", "hidden", "enabled", "disabled"], "Required element state.")),
                        ("timeout_ms", intSchema("Bounded timeout from 100 through 10000 milliseconds. Defaults 5000.")),
                        ("settle_ms", intSchema("Extra navigation quiet interval from 0 through 2000 milliseconds.")),
                    ],
                    required: ["condition"]
                )
            ),
        ]
    }
}

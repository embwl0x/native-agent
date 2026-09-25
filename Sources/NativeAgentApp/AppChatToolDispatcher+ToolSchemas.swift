import Foundation
import NativeAgentCore
import PersistenceCore

extension AppChatToolDispatcher {
    static func appToolSchemas() -> [LLMToolSchema] {
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
            ("description", .string("Form fields to fill: {\"Email\": \"a@b.com\", \"Country\": \"Canada\", \"Remember me\": true}, keyed by the label or row number the page shows; or \"Email: a@b.com; Country: Canada\"."))])
        let submitSchema = obj([("type", .array([.string("string"), .string("boolean")])),
            ("description", .string("After filling: the button to click (label or row), or true to press Enter in the last field."))])
        let snapshotDefault = "Optional: defaults to the page last read on this tab."
        func params(properties: [(String, JSONValue)], required: [String]) -> Data {
            let v = obj([
                ("type", .string("object")),
                ("properties", obj(properties)),
                ("required", .array(required.map { .string($0) })),
            ])
            return (try? v.serializedData(pretty: false)) ?? Data("{}".utf8)
        }
        return [
            LLMToolSchema(
                name: "chat_reply",
                description: "Reply to an exact opened human conversation using its saved destination. workspace binds the selected conversation and latest message for you. Does not create a user turn or change the foreground chat. For your current active conversation, answer normally instead. An uncertain delivery must not be resent automatically.",
                parametersJSON: params(properties: [
                    ("conversation_session_id", strSchema("Exact conversation_session_id from chat_conversations.")),
                    ("last_message_id", strSchema("Exact last_message_id from the opened conversation; changed conversations must be read again.")),
                    ("text", strSchema("The assistant reply, up to 16000 characters."))
                ], required: ["conversation_session_id", "last_message_id", "text"])
            ),
            LLMToolSchema(
                name: "reflex_review",
                description: "Review one live organism reflex candidate through NativeAgent's in-process runtime owner. Approve activates only a low-risk candidate as soft posture bias; hold leaves it inactive while evidence accrues; reject makes it permanently deliberate so it cannot re-propose. Returns a durable reviewer receipt.",
                parametersJSON: params(
                    properties: [
                        ("candidate_id", strSchema("Exact reflex candidate id from organism state, such as tool:tool-grep.")),
                        ("decision", enumStringSchema(
                            ["approve", "hold", "reject"],
                            "Review decision. Approve is low-risk-only; reject is permanent."
                        )),
                        ("note", strSchema("Optional bounded reason recorded with the audit receipt.")),
                    ],
                    required: ["candidate_id", "decision"]
                )
            ),
            // ── Quiet self-administration (0.4.14) ────────────────────────
            // NativeAgent's OWN pages only. Nothing here can see or touch
            // another app; the Mac verbs remain the only route to the desktop.
            LLMToolSchema(
                name: "app_page_read",
                description: "Read a NativeAgent page in the background; this does not open or show it. Returns its content, controls and Trust mode. To open or show a page, use interaction_act(target: composer, verb: set_page, value: the page name). Reads work in every Trust mode.",
                parametersJSON: params(
                    properties: [
                        ("page", enumStringSchema(
                            QuietPages.ids + ["current"],
                            "Which page to read, by the name on the rail, or current for the visible page."
                        )),
                    ],
                    required: ["page"]
                )
            ),
            LLMToolSchema(
                name: "app_page_screenshot",
                description: "Get a picture of one of NativeAgent's own pages, drawn offscreen and returned as an image. Use it to check how a page looks; use app_page_read for what it says. It draws the app's own view, not the screen, so it needs no screen recording, never captures another app, and never brings the window forward. Reads are allowed in every Trust mode.",
                parametersJSON: params(
                    properties: [
                        ("page", enumStringSchema(
                            QuietPages.ids + QuietPages.drawOnly.map(\.id),
                            "Which page to draw, by the name on the rail; simple is the Simple view, simple_settings_menu the same with its settings menu open."
                        )),
                        ("height", intSchema("Height to draw at, 400 to 2400 points; 860 when omitted. A short height shows how the page behaves in a small window.")),
                    ],
                    required: ["page"]
                )
            ),
            LLMToolSchema(
                name: "app_settings_list",
                description: "List the settings NativeAgent's own pages expose — the exact id, type, allowed values, and whether each one can be changed by the agent. Call this before app_setting_set rather than guessing a name. Settings marked owner_only are the person's own Trust posture: readable, never changeable here.",
                parametersJSON: params(
                    properties: [
                        ("page", enumStringSchema(
                            QuietPages.ids,
                            "Narrow to one page. Omit for every setting on every page."
                        )),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "app_setting_set",
                description: "Change one setting on one of NativeAgent's own pages, through the same in-process action the page's own control takes — so the page shows it immediately, nothing is brought forward and no click is synthesized. The result carries the page, the setting, the old value and the new one, which is the receipt the person reads. Allowed under Work mode, Builder and Full Mac; only Safe refuses, and says so. Trust's own posture (presets, Full Mac, unattended work, Mac control, Mac service access) is never changeable here.",
                parametersJSON: params(
                    properties: [
                        ("setting", strSchema("Exact setting id from app_settings_list, such as providers.chat_model.")),
                        ("value", obj([("description", .string("The new value: a boolean, a string, or a number, matching the setting's stated type."))])),
                        ("page", enumStringSchema(
                            QuietPages.ids,
                            "Optional. When given it must be the page the setting belongs to."
                        )),
                    ],
                    required: ["setting", "value"]
                )
            ),
            LLMToolSchema(
                name: "interaction_act",
                description: "Open, show or go to a NativeAgent page (settings, chat, desk, providers): target=composer, verb=set_page, value=page name. Answer one of the inline cards in the open conversation — the \"Connect Notion\", \"Allow Desktop\", \"Which model\" questions the app raises mid-turn. Get each card's interaction_id from app_page_read page=chat. It takes the same path a tap on the card takes: the control's own writer runs, then the control's owner is re-asked whether the thing is actually done, so a rejected token fails the card in the connector's own words and keeps its retry. Nothing is brought forward and no window is focused. A control that is a page or a browser sign-in (Trust posture, OAuth, Providers' group picker) comes back status needs_glass with the reason. A card raised from a phone or a Telegram chat is refused: it was asked of that person. Allowed under Work mode, Builder and Full Mac; only Safe refuses, and says so. It also works the app's own composer in process: pass target=composer with a verb instead of an interaction_id to read the composer, set or send the draft, pick the model, set the thinking level, open or close a card, or switch the rail page. Nothing goes over accessibility, which would deadlock the turn.",
                parametersJSON: params(
                    properties: [
                        ("interaction_id", strSchema("The card's interaction id, from app_page_read page=chat.")),
                        ("action", enumStringSchema(
                            ["primary", "decline", "retry"],
                            "Required with an interaction_id, and only then: primary takes the card's own action, decline says \"not now\", retry re-runs a failed one. With target=composer the verb says what to do, so leave action out."
                        )),
                        ("value", strSchema("Never ask for a secret in chat: the person types keys and tokens into the card itself. Pass one here only if it reached you outside the conversation. Never echoed back; the receipt says [redacted].")),
                        ("choice", strSchema("The id of the option picked, for a choose or model_choice card. With target=composer and verb=set_model, the model id.")),
                        ("target", enumStringSchema(
                            ["composer"],
                            "Instead of a card: work the app's own composer, in process. Pass verb. Our own window can never be worked over accessibility (it deadlocks the turn asking), so only these verbs reach it."
                        )),
                        ("verb", enumStringSchema(
                            ["read", "set_draft", "send", "set_model", "set_think", "open_card", "close_card", "set_page"],
                            "target=composer only, and then action is not passed at all. read returns draft, model, think, trust word, ring fraction and which pane of the composer shell is open. set_draft takes value. send sends the draft. set_model takes the provider in value and the model id in choice, through the same picker the person uses, and its receipt waits for the write to land. set_think takes a level in value. open_card takes model, think, trust or context in value — one shell, one pane at a time, so opening one is switching to it; close_card closes it. set_page takes a rail page in value. There is no verb that sets Trust posture: that stays the person's."
                        )),
                    ],
                    // Sol, 2026-09-17: `action` belongs to a card, and composer
                    // dispatch ignores it — requiring it here made a strict
                    // caller invent one to reach a documented composer verb.
                    required: []
                )
            ),
            LLMToolSchema(
                name: "doctor_status",
                description: "Run NativeAgent's read-only Doctor checks without repairs and return the bounded check results. The global status keeps every warning visible; active_path_status separately reports the path serving this turn, while maintenance_status covers dormant or aggregate integration upkeep only when the active provider is independently confirmed ready.",
                parametersJSON: params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "telegram_status",
                description: "Return a bounded read-only summary of NativeAgent's Telegram configuration, live poller health, and diagnostic-ledger freshness. Historical error and policy-block counts are explicitly separated from unrecovered errors. Tokens, chat IDs, user IDs, and message contents are never returned.",
                parametersJSON: params(properties: [], required: [])
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
                description: "Whether the Chrome extension is connected right now and Chrome control is on. Navigate needs neither checked first: it says when Chrome is not connected.",
                parametersJSON: params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_setup",
                description: "Set up Chrome from chat using the same owner as Trust: prepare the bundled extension in a visible folder, reveal it and open Chrome's extensions page. Use when asked to set up Chrome; this changes focus. Loading the unpacked extension remains a Chrome step; use normal authorized Mac controls to help, then check browser.chrome_status. Never claims installation from copying files, and never changes permissions.",
                parametersJSON: params(properties: [("dry_run", boolSchema("Describe current connection without preparing files or opening apps."))], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_acquire",
                description: "Rarely needed: browser.chrome_navigate{url} opens and manages its own tab. Use to claim an exact existing tab (mode claim, tab_id, expected_url) or to open an X post in the visible work window. Leases slide: each call keeps the tab for five more idle minutes.",
                parametersJSON: params(
                    properties: [
                        ("mode", enumStringSchema(["create", "claim"], "Create an inactive tab in the purple NativeAgent group alongside the user's tabs in their existing Chrome window, or claim an exact existing user tab. Defaults create; never claim a user tab just to start ordinary browsing.")),
                        ("initial_url", strSchema("Optional HTTP(S) URL for a created background tab.")),
                        ("rendering_mode", strSchema("Create only: optional grouped_background or visible_work_window. X/Twitter post URLs automatically use their own unfocused visible work window to load replies; other URLs default to grouped background tabs. Never selects your existing tabs. Inspect snapshot rendering evidence; visibility does not guarantee complete content.")),
                        ("tab_id", intSchema("Exact Chrome tab id for claim mode.")),
                        ("expected_url", strSchema("Exact current URL for claim mode.")),
                        ("expected_title", strSchema("Exact current title for claim mode.")),
                        ("lease_duration_ms", intSchema("Lease duration from 30000 through 300000 milliseconds. Defaults 60000.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_renew",
                description: "Rarely needed: every Chrome call already keeps its tab alive (five idle minutes, sliding). Extends this conversation's tab lease now.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
                        ("expected_user_sequence", nullable(intSchema("Optional observed user sequence; omit for this conversation's current tab. Renewal refuses user takeover."))),
                        ("lease_duration_ms", intSchema("New lease duration from 30000 through 300000 milliseconds. Defaults 60000.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_navigate",
                description: "Open a web page and read it in one call: loads the URL in this conversation's own background Chrome tab (opened and kept for you) and returns its main content as numbered rows. Move down with browser.chrome_scroll. Add fields and submit to fill and send a form in the same call.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("url", strSchema("HTTP(S) destination.")),
                        ("fields", fieldsSchema),
                        ("submit", submitSchema),
                        ("scope", enumStringSchema(["main_content", "page"], "Returned page: main_content (default) or page to include the site's nav.")),
                    ],
                    required: ["url"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_snapshot",
                description: "Rarely needed: navigate, scroll and every act already return the page. Re-reads the current Chrome page as numbered rows `n role label [state]`; act on a row by its number or label. scope page adds the site's nav; only what is on screen is read, so move with browser.chrome_scroll.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
                        ("max_nodes", intSchema("Maximum rows, 1 through 200. Defaults 150.")),
                        ("max_text_chars", intSchema("Maximum readable text characters, 1 through 40000. Defaults 12000.")),
                        ("scope", enumStringSchema(["page", "main_content"], "Page viewport or semantic main/article content within it. A main_content read reports when no semantic content region was found; use page to retain surrounding controls.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_click",
                description: "Click one row of the current Chrome page by its number or label (\"Sign in\"). Waits for any navigation it starts and returns the fresh page; no snapshot call needed.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema(snapshotDefault)),
                        ("node_id", strSchema("Row number from the page, or the row's label.")),
                    ],
                    required: ["node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_scroll",
                description: "The way to move on a Chrome page: scrolls it (or a scrollable row) by delta_y pixels and returns only the rows that came into view, with how far it moved and what is left below. Nothing moved says so.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema("Snapshot id when targeting a node. For page scrolling omit both optional IDs or supply both as empty strings.")),
                        ("target_node_id", strSchema("Optional scrollable node id. Node scrolling requires both exact IDs from a fresh snapshot.")),
                        ("delta_x", intSchema("Horizontal scroll delta.")),
                        ("delta_y", intSchema("Vertical scroll delta.")),
                    ],
                    required: ["delta_x", "delta_y"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_fill",
                description: "Fill a form on the current Chrome page in one call: fields {label or row: value} sets text boxes, selects and checkboxes in page order, then submit clicks the button (or true presses Enter). Every field is found before anything is typed. Or one row: node_id + value. Returns what was filled plus the fresh page; never retries an ambiguous dispatch.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
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
                description: "Press a key or chord in a row (number or label): Enter, Tab, Escape, arrows, a single character like j or /. To move down the page use browser.chrome_scroll. Verified by what changed; returns the fresh page.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema(snapshotDefault)),
                        ("node_id", strSchema("Row: its number or label.")),
                    ],
                    required: ["node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_drag",
                description: "Drag a node advertising drag onto a node advertising drop from one exact fresh Chrome snapshot and frame. Uses synthetic HTML drag events and the page's DataTransfer handlers without activating the tab. Target must accept dragover; dropDispatched is not proof of a successful move: check the returned page. Does not implement OS/file dragging or pointer-only canvas gestures; never retry an unknown outcome automatically.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema("Fresh snapshot containing both endpoints.")),
                        ("node_id", strSchema("Source node advertising drag.")),
                        ("target_node_id", strSchema("Target node advertising drop; acceptance is checked during the operation.")),
                    ],
                    required: ["snapshot_id", "node_id", "target_node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_wait",
                description: "Wait up to 10 s for the tab to settle or a row to become visible/hidden/enabled/disabled. Rarely needed: acts already wait for navigation.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("condition", enumStringSchema(["element_state", "navigation_settled"], "Wait condition.")),
                        ("snapshot_id", strSchema("Exact current snapshot id for element_state.")),
                        ("node_id", strSchema("Node id that advertised wait for element_state.")),
                        ("state", enumStringSchema(["visible", "hidden", "enabled", "disabled"], "Required element state.")),
                        ("timeout_ms", intSchema("Bounded timeout from 100 through 10000 milliseconds. Defaults 5000.")),
                        ("settle_ms", intSchema("Extra navigation quiet interval from 0 through 2000 milliseconds.")),
                    ],
                    required: ["condition"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_release",
                description: "Optional: an idle tab closes on its own after five minutes. Closes this conversation's tab now (a claimed or active tab stays open).",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Optional; omit for this chat's tab."))),
                        ("close_created_tab", obj([("type", .array([.string("boolean"), .string("null")])),
                                                   ("description", .string("Close an inactive agent-created tab. Defaults true."))])),
                    ],
                    required: []
                )
            ),
        ]
    }
}

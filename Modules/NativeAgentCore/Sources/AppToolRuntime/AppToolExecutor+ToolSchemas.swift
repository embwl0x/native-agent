import Foundation
import NativeAgentCore
import PersistenceCore

extension AppToolExecutor {
    public static func appToolSchemas(pageIDs: [String], drawOnlyPageIDs: [String]) -> [LLMToolSchema] {
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
        return [
            LLMToolSchema(
                name: "chat_reply",
                description: "Reply to an exact opened human conversation's saved destination; workspace binds its conversation/latest message. Creates no user turn or foreground-chat change. Answer your active conversation normally. Never automatically resend uncertain delivery.",
                parametersJSON: params(properties: [
                    ("conversation_session_id", strSchema("Exact conversation_session_id from chat_conversations.")),
                    ("last_message_id", strSchema("Exact last_message_id from the opened conversation; changed conversations must be read again.")),
                    ("text", strSchema("The assistant reply, up to 16000 characters."))
                ], required: ["conversation_session_id", "last_message_id", "text"])
            ),
            LLMToolSchema(
                name: "reflex_review",
                description: "Review one live organism reflex through NativeAgent's in-process owner. Approve activates low-risk candidates only, as soft posture bias; hold keeps inactive while evidence accrues; reject makes permanently deliberate, preventing re-proposal. Returns a durable reviewer receipt.",
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
                description: "Read a NativeAgent page's content, controls and Trust mode in the background, without opening/showing it. To show it: interaction_act(target: composer, verb: set_page, value: page name). Reads work in every Trust mode.",
                parametersJSON: params(
                    properties: [
                        ("page", enumStringSchema(
                            pageIDs + ["current"],
                            "Which page to read, by the name on the rail, or current for the visible page."
                        )),
                    ],
                    required: ["page"]
                )
            ),
            LLMToolSchema(
                name: "app_page_screenshot",
                description: "Return an offscreen image of NativeAgent's own page to inspect appearance; app_page_read reads content. Draws the app view, not the screen: no screen recording, other-app capture or foregrounding. Allowed in every Trust mode.",
                parametersJSON: params(
                    properties: [
                        ("page", enumStringSchema(
                            pageIDs + drawOnlyPageIDs,
                            "Which page to draw, by the name on the rail; simple is the Simple view, simple_settings_menu the same with its settings menu open."
                        )),
                        ("height", intSchema("Height to draw at, 400 to 2400 points; 860 when omitted. A short height shows how the page behaves in a small window.")),
                    ],
                    required: ["page"]
                )
            ),
            LLMToolSchema(
                name: "app_settings_list",
                description: "List NativeAgent page settings: exact id, type, allowed values and agent editability. Call before app_setting_set; never guess IDs. owner_only settings are the person's Trust posture: readable, never editable here.",
                parametersJSON: params(
                    properties: [
                        ("page", enumStringSchema(
                            pageIDs,
                            "Narrow to one page. Omit for every setting on every page."
                        )),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "app_setting_set",
                description: "Change a NativeAgent page setting via its control's in-process action: visible immediately, without foregrounding or synthesized clicks. Receipt includes page, setting, old/new values. Allowed in Work mode/Builder/Full Mac; Safe explicitly refuses. Cannot change Trust posture: presets, Full Mac, unattended work, Mac control or Mac service access.",
                parametersJSON: params(
                    properties: [
                        ("setting", strSchema("Exact setting id from app_settings_list, such as providers.chat_model.")),
                        ("value", obj([("description", .string("The new value: a boolean, a string, or a number, matching the setting's stated type."))])),
                        ("page", enumStringSchema(
                            pageIDs,
                            "Optional. When given it must be the page the setting belongs to."
                        )),
                    ],
                    required: ["setting", "value"]
                )
            ),
            LLMToolSchema(
                name: "interaction_act",
                description: "Open/show/go to a NativeAgent page (settings/chat/desk/providers): target=composer, verb=set_page, value=page name. Answer inline cards in the open conversation (Connect Notion/Allow Desktop/Which model); get interaction_id from app_page_read page=chat. Uses the card's own writer then owner verification: rejected tokens fail in the connector's words and retain retry. Never foregrounds/focuses windows. Page/browser-sign-in controls (Trust posture/OAuth/Providers group picker) return needs_glass with a reason. Refuses phone/Telegram cards addressed to the person. Allowed in Work mode/Builder/Full Mac; Safe explicitly refuses. For the in-process composer, use target=composer + verb instead of interaction_id: read, set/send draft, pick model/thinking level, open/close cards, switch rail page. No accessibility calls: they would deadlock the turn.",
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
                description: "Run bounded read-only NativeAgent Doctor checks, without repairs. Global status retains all warnings; active_path_status covers this turn's serving path. maintenance_status covers dormant/aggregate integration upkeep only when the active provider is independently confirmed ready.",
                parametersJSON: params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "telegram_status",
                description: "Read a bounded summary of NativeAgent Telegram config, live poller health and diagnostic-ledger freshness. Separates historical error/policy-block counts from unrecovered errors. Never returns tokens, chat/user IDs or message contents.",
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
                description: "Set up Chrome on request via Trust's owner: prepare/reveal the bundled extension in a visible folder and open Chrome's extensions page, changing focus. Chrome still must load the unpacked extension; help with authorized Mac controls, then check browser.chrome_status. Copying files never proves installation; permissions never change.",
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
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
                        ("expected_user_sequence", nullable(intSchema("Optional observed user sequence; omit for this conversation's current tab. Renewal refuses user takeover."))),
                        ("lease_duration_ms", intSchema("New lease duration from 30000 through 300000 milliseconds. Defaults 60000.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_navigate",
                description: "Open/read a URL in this conversation's automatically opened/kept background Chrome tab; returns main content as numbered rows. url back/forward moves through tab history (Back button). Scroll with browser.chrome_scroll. fields + submit fills/sends a form in this call.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
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
                description: "Re-read Chrome as numbered rows `n role label [state]`; act by number/label. Rarely needed: navigate/scroll/acts return the page. scope page adds site nav. Only onscreen content is read; move with browser.chrome_scroll.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
                        ("expected_user_sequence", nullable(intSchema("Optional; omit."))),
                        ("snapshot_id", strSchema(snapshotDefault)),
                        ("node_id", strSchema("Row number from the page, or the row's label.")),
                    ],
                    required: ["node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_scroll",
                description: "Move a Chrome page or scrollable row by delta_y pixels. Returns newly visible rows, distance moved and remaining below; explicitly reports no movement.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
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
                description: "Fill the current Chrome form: fields {label or row: value} sets text boxes/selects/checkboxes in page order, then submit clicks a button (true presses Enter). Finds all fields before typing. For one row use node_id + value. Returns filled fields and fresh page; never retries ambiguous dispatch.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
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
                        ("lease_id", nullable(strSchema("Omit for this chat's tab."))),
                        ("close_created_tab", obj([("type", .array([.string("boolean"), .string("null")])),
                                                   ("description", .string("Close an inactive agent-created tab. Defaults true."))])),
                    ],
                    required: []
                )
            ),
        ]
    }
}

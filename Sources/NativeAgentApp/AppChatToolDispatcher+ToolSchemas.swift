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
                name: "mac.notify",
                description: "Post a local macOS notification to the user. Use this only when a short visible Mac alert is useful.",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Short notification title. Defaults to the configured assistant name.")),
                        ("message", strSchema("REQUIRED. Short notification body; must be non-empty — an empty string is refused.")),
                    ],
                    required: ["message"]
                )
            ),
            LLMToolSchema(
                name: "mobile.notify",
                description: "Send the user a paired-iPhone notification. Public CloudKit builds queue an Apple-presented visual push that does not require the companion app to be open; configured direct APNS remains an optional parallel route. Provider-safe alias: mobile_notify. Use for short attention-worthy updates, not long prose.",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Short notification title. Defaults to the configured assistant name.")),
                        ("message", strSchema("REQUIRED. Short notification body; must be non-empty — an empty string is refused.")),
                        ("screen", strSchema("iOS screen to open, such as inbox or activity. Defaults to inbox.")),
                        ("source", strSchema("Source label for audit metadata. Defaults to chat_tool.")),
                        ("urgency", strSchema("Urgency label such as normal or urgent. Defaults to normal.")),
                    ],
                    required: ["message"]
                )
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
                description: "Return visible NativeAgent Browser status and recent browser run receipts. Provider-safe alias: browser_status.",
                parametersJSON: params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "browser.open_url",
                description: "Open an http/https URL in the visible NativeAgent Browser and record a browser run receipt. Provider-safe alias: browser_open_url.",
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
                name: "browser.navigate",
                description: "Navigate the visible NativeAgent Browser to an http/https URL and record a browser run receipt. Provider-safe alias: browser_navigate.",
                parametersJSON: params(
                    properties: [
                        ("url", strSchema("HTTP or HTTPS URL to navigate to.")),
                        ("capture_source", boolSchema("After navigation, capture visible page text to a source receipt. Defaults false.")),
                        ("capture_screenshot", boolSchema("After navigation, capture a PNG screenshot receipt. Defaults false.")),
                        ("dry_run", boolSchema("If true, only record a dry-run browser receipt. Defaults false.")),
                    ],
                    required: ["url"]
                )
            ),
            LLMToolSchema(
                name: "browser.read_text",
                description: "Read visible page text from the current NativeAgent Browser page and persist a source receipt. Current page must be http/https. Provider-safe alias: browser_read_text.",
                parametersJSON: params(
                    properties: [
                        ("dry_run", boolSchema("If true, record a dry-run receipt without reading the page. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.read_links",
                description: "Read links from the current NativeAgent Browser page and persist a link-source receipt. Current page must be http/https. Provider-safe alias: browser_read_links.",
                parametersJSON: params(
                    properties: [
                        ("dry_run", boolSchema("If true, record a dry-run receipt without reading links. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.screenshot",
                description: "Capture a PNG screenshot from the current NativeAgent Browser page and persist a screenshot receipt. Current page must be http/https. Provider-safe alias: browser_screenshot.",
                parametersJSON: params(
                    properties: [
                        ("dry_run", boolSchema("If true, record a dry-run receipt without capturing an image. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_acquire",
                description: "Acquire a short-lived real Chrome tab lease. Creates an inactive background tab by default; claiming requires an exact tab id, URL, and title. Chrome control must be on in Trust Center.",
                parametersJSON: params(
                    properties: [
                        ("mode", enumStringSchema(["create", "claim"], "Create an inactive tab in the purple NativeAgent group alongside the user's tabs in their existing Chrome window, or claim an exact existing user tab. Defaults create; never claim a user tab just to start ordinary browsing.")),
                        ("initial_url", strSchema("Optional HTTP(S) URL for a created background tab.")),
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
                description: "Extend an existing real Chrome tab lease before it expires. The lease is the only thing that keeps a Chrome task alive; without a renew every task has a hard 60-second ceiling. Renewing does not touch the page.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease; a renew fails if the user has touched the tab since.")),
                        ("lease_duration_ms", intSchema("New lease duration from 30000 through 300000 milliseconds. Defaults 60000.")),
                    ],
                    required: ["lease_id", "expected_user_sequence"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_navigate",
                description: "Navigate an already-leased real Chrome background tab without activating it.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease; normally 0.")),
                        ("url", strSchema("HTTP(S) destination.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "url"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_snapshot",
                description: "Read a fresh structured Chrome page: bounded text, article/container hierarchy and actionable node IDs. Use parentNodeId to distinguish repeated controls under different posts/articles; aria-labelledby names are resolved. Layout-only wrappers are omitted. Password values are omitted. After navigation or a stale-node refusal, read again; never guess IDs or repeat a possibly dispatched external action.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("max_nodes", intSchema("Maximum structured nodes, 1 through 500.")),
                        ("max_text_chars", intSchema("Maximum readable text characters, 1 through 50000.")),
                    ],
                    required: ["lease_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_click",
                description: "Click one actionable node from the exact structured Chrome snapshot that exposed it.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact snapshot id.")),
                        ("node_id", strSchema("Exact actionable node id.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_scroll",
                description: "Scroll the leased real Chrome page or a scrollable node from a structured snapshot without activation. Reports actual movedX/movedY, scrolled=false when unchanged, and vertical remainingUp/remainingDown plus atTop/atBottom. These are immediate position observations, not proof a dynamic feed finished loading. Read a fresh snapshot after scrolling; use the named scrollable container for nested feeds.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Snapshot id when targeting a node. For page scrolling omit both optional IDs or supply both as empty strings.")),
                        ("target_node_id", strSchema("Optional scrollable node id. Node scrolling requires both exact IDs from a fresh snapshot.")),
                        ("delta_x", intSchema("Horizontal scroll delta.")),
                        ("delta_y", intSchema("Vertical scroll delta.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "delta_x", "delta_y"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_fill",
                description: "Replace the value of an editable non-password node from the exact current Chrome snapshot. Returns one outcome receipt and never retries an ambiguous dispatch.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Editable node id that advertised fill.")),
                        ("value", strSchema("Replacement text, at most 50000 characters.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id", "value"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_type",
                description: "Append text sequentially to an editable non-password node from the exact current Chrome snapshot. Runs up to 20 seconds or the remaining lease and returns exact Unicode progress. For partial completion, observe a fresh snapshot and continue only the remaining text; never resend the original full text blindly.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Editable node id that advertised type.")),
                        ("text", strSchema("Text to append, at most 50000 characters.")),
                        ("delay_ms", intSchema("Optional delay between characters, 0 through 250 milliseconds.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id", "text"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_select",
                description: "Select one or more exact option values from the select.options list in a fresh Chrome snapshot. That list includes labels, values, selected/disabled state and option groups (up to 100, with explicit truncation). Disabled or changed choices refuse. Form controls expose formState.required, valid and failures; correct invalid fields and observe again before submission. Returns one outcome receipt.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Select node id that advertised select.")),
                        ("values", stringArraySchema("One or more exact option values; single-select nodes require exactly one.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id", "values"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_keypress",
                description: "Press one bounded key or chord on a non-password node from the exact current frame-aware Chrome snapshot. Returns one outcome receipt and never retries an ambiguous dispatch.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Node id that advertised keypress.")),
                        ("key", enumStringSchema([
                            "Enter", "Tab", "Shift+Tab", "Escape", "ArrowDown", "ArrowUp",
                            "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown",
                            "Backspace", "Delete", "Space", "Control+A", "Meta+A"
                        ], "Bounded key or chord.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id", "key"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_set_checked",
                description: "Idempotently set a checkbox, radio, or switch node from the exact current frame-aware Chrome snapshot. Returns one outcome receipt.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Checkable node id that advertised set_checked.")),
                        ("checked", boolSchema("Exact checked state to apply.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id", "checked"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_double_click",
                description: "Double-click one node that advertised double_click in the exact current frame-aware Chrome snapshot. Returns one outcome receipt and never retries an ambiguous dispatch.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Node id that advertised double_click.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_drag",
                description: "Drag a node advertising drag onto a node advertising drop from one exact fresh Chrome snapshot and frame. Uses synthetic HTML drag events and the page's DataTransfer handlers without activating the tab. Target must accept dragover; dropDispatched is not proof of a successful move: read a fresh snapshot. Does not implement OS/file dragging or pointer-only canvas gestures; never retry an unknown outcome automatically.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Exact source and target tab lease.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Fresh snapshot containing both endpoints.")),
                        ("node_id", strSchema("Source node advertising drag.")),
                        ("target_node_id", strSchema("Target node advertising drop; acceptance is checked during the operation.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id", "target_node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_wait",
                description: "Wait a bounded time for a current snapshot node state or for leased-tab navigation to settle. Returns one observational outcome receipt.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("condition", enumStringSchema(["element_state", "navigation_settled"], "Wait condition.")),
                        ("snapshot_id", strSchema("Exact current snapshot id for element_state.")),
                        ("node_id", strSchema("Node id that advertised wait for element_state.")),
                        ("state", enumStringSchema(["visible", "hidden", "enabled", "disabled"], "Required element state.")),
                        ("timeout_ms", intSchema("Bounded timeout from 100 through 10000 milliseconds. Defaults 5000.")),
                        ("settle_ms", intSchema("Extra navigation quiet interval from 0 through 2000 milliseconds.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "condition"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_release",
                description: "Release a real Chrome tab lease. Claimed and active tabs remain open; an untouched inactive agent-created tab closes by default.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id to release.")),
                        ("close_created_tab", boolSchema("Close an inactive agent-created tab. Defaults true.")),
                    ],
                    required: ["lease_id"]
                )
            ),
        ]
    }
}

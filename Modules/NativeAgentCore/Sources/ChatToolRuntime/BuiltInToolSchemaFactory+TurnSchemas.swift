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
// Blueprint: | `BuiltInToolSchemaFactory+TurnSchemas.swift` | `BuiltInToolSchemaFactory`: `turnSchemas`: result paging, interaction, images, context, scratchpad, time, traces and swarms |

extension BuiltInToolSchemaFactory {
    func turnSchemas() -> [LLMToolSchema?] {
        [
            requestedSchema(name: "tool_result_page", toolClass: .read, capabilities: ["catalog_read", "tool_call"],
                description: "Read a result retained this turn without repeating its action. Only full_result_retained:true results are eligible. Follow next_call; continue:true alone selects the sole retained result. Exact result_handle/page also works. Query selects only matching records in source order, with positions and retained-response coverage; it cannot search unread source content. Read-only, redacted; expires at turn end.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("result_handle", ToolSchema.nullable(ToolSchema.strSchema("Opaque handle from the bounded_tool_result receipt."))),
                        ("continue", ToolSchema.nullable(ToolSchema.boolSchema("Continue this turn's last successful read; page is ignored; omit query/raw. result_handle explicitly changes result. Before any read, starts the sole retained result or asks you to choose."))),
                        ("page", ToolSchema.nullable(ToolSchema.intSchema("Zero-based whole-number page index. Omit or null starts at 0; follow next_page while has_more is true. Keep query and raw unchanged while paging."))),
                        ("query", ToolSchema.nullable(ToolSchema.strSchema("Select records containing every whitespace-separated term, case-insensitively. Keep query while paging; start at page 0 when changing it. Empty reads all records."))),
                        ("raw", ToolSchema.nullable(ToolSchema.boolSchema("Exact original bytes instead of sections, only for reconstruction or oversized values. Separate 8000-byte pages may split sentences/JSON; concatenate from page 0 through raw_page_count pages."))),
                        ("session_id", ToolSchema.nullable(ToolSchema.strSchema("Current conversation id; the tool loop auto-fills this."))),
                    ],
                    required: []
                )
            ),
            // A request addressed to the person is a question, not an effect:
            // the person's own answer on the card is the decision, so no
            // posture or steer puts a card in front of the card.
            requestedSchema(name: "request_interaction", toolClass: .read, capabilities: ["tool_call"],
                description: "Raise an inline setup/choice card; required kind and why, with canonical target except choose. Secrets go only in cards, never chat. api_key supports provider sign-in or keys; reach secret:<name> uses api_key target:secret:<name> with hosts/programs and optional sign_in. The person supplies the secret on the card; it stays in the keyring and code uses {{secret:<name>}} without seeing it. Connector cards require an explicit connect/add/set up/enable request; ordinary read/status requests only report the blocker. Other kinds may request a known missing prerequisite. Cards settle to receipts; configured targets return without a card. Connector/permission/capability cards are nonblocking: skip the unavailable step and continue. API-key/model/choice cards stop the turn until the person acts. choose requires title, nonempty options and decline_consequence. Canonical targets and controls are listed in parameters; unsupported targets refuse. For participants use agent.connect; for helpers bot.create. Example: {\"kind\":\"connector\",\"target\":\"slack\",\"why\":\"Connect Slack as requested.\",\"decline_consequence\":\"I will continue without Slack.\"}.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.enumStringSchema(
                            ["connector", "permission", "model_choice", "api_key", "capability", "choose"],
                            "What is needed."
                        )),
                        ("target", ToolSchema.strSchema("Canonical id. connector: slack, telegram, mail (Apple Mail), chrome (Chrome extension), iphone (pair iPhone/iPad). permission: calendar, reminders, contacts, mail, messages, notes, music, notify_mac, notify_mobile, spotlight, scheduler; Mac control: shell, file_ops, applescript:<bundle_id> (macOS Automation for one app), jxa, accessibility, system. api_key: openai, anthropic, openrouter, moonshot, or secret:<name> for a keyring secret; sign-in: openai_oauth_direct (ChatGPT), anthropic_oauth_direct (Claude), xai (Grok). capability: image_generation, screen_capture, vision_api_calls, tts. model_choice: a Providers group id. Omit for choose.")),
                        ("why", ToolSchema.strSchema("One sentence: why this is needed, here, now.")),
                        ("decline_consequence", ToolSchema.strSchema("What happens if they say no. Required for choose; a sensible default is used otherwise.")),
                        ("also_needed", stringArraySchema("For permission: other Mac capabilities this same request needs, so they grant once instead of twice.")),
                        ("hosts", stringArraySchema("For secret:<name>: the hosts (api.example.com) a request may carry it to. Where it is already kept for stays granted unless only:true.")),
                        ("programs", stringArraySchema("For secret:<name>: the programs (npx, or an executable's path) it may be handed to; the grant binds each to the file that runs now, and a changed one asks again.")),
                        ("replace", ToolSchema.boolSchema("For secret:<name>: ask again though it is kept (expired, revoked, or the person wants a new one); the kept value stays until the new one is.")),
                        ("remove", ToolSchema.boolSchema("For secret:<name>: ask the person to remove it from the keyring.")),
                        ("only", ToolSchema.boolSchema("For secret:<name>: grant only the hosts and programs named, so it stops going anywhere else it is kept for; the card says which stop.")),
                        ("sign_in", .object([
                            "type": .string("object"),
                            "description": .string("For secret:<name> from a service's OAuth sign-in: NativeAgent runs it (code flow with PKCE, loopback redirect; or a device sign-in) and keeps and renews the token. A client secret the service issued is typed by the person on the card, never sent here."),
                            "properties": .object([
                                "authorize": .object(["type": .string("string"), "description": .string("https authorize URL; may carry extra query parameters.")]),
                                "device": .object(["type": .string("string"), "description": .string("https device authorization URL, given instead of authorize for a device sign-in: the card shows the person the code and opens where they enter it.")]),
                                "token": .object(["type": .string("string"), "description": .string("https token URL.")]),
                                "client_id": .object(["type": .string("string")]),
                                "scopes": .object(["type": .string("string"), "description": .string("Space-separated.")]),
                                "redirect": .object(["type": .string("string"), "description": .string("A registered http://127.0.0.1:<port>/<path>; default any port, /callback.")]),
                                "client_auth": ToolSchema.enumStringSchema(["body", "basic"], "How the client authenticates at the token endpoint: in the body (default) or by HTTP Basic."),
                            ]),
                            "required": .array([.string("token"), .string("client_id")]),
                        ])),
                        ("mode", ToolSchema.enumStringSchema(
                            ["read", "write", "read_write"],
                            "For permission: which axis the blocked call actually needed. Say read or write when that is all it was - omitting this asks for both, which is a wider grant than the work required."
                        )),
                        ("title", ToolSchema.strSchema("For choose: the question.")),
                        ("scope_noun", ToolSchema.strSchema("For model_choice: the single piece of work this should apply to, e.g. \"this image\". Supplying it scopes the choice to this request and offers the permanent change as the secondary action.")),
                        ("options", .object([
                            "type": .string("array"),
                            "description": .string("For choose and model_choice: the answers, each with a stable id and a label."),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "id": .object(["type": .string("string")]),
                                    "label": .object(["type": .string("string")]),
                                    "detail": .object(["type": .string("string")]),
                                ]),
                                "required": .array([.string("id"), .string("label")]),
                            ]),
                        ])),
                    ],
                    required: ["kind", "why"]
                )
            ),
            requestedSchema(name: "image_generate",
                toolClass: .write, capabilities: ["app_data_write", "image_generation", "network_write", "tool_call"],
                description: "Generate raster images on the route selected for Work in Providers: Codex uses image_gen.imagegen; OpenAI uses its separately billed image API. Only Codex supports edits/local references here. Provider and image model are route-owned, never selected by tool input; an unsupported route asks for a supported Work choice. Requires admitted Full Mac or Trust’s image-generation permission. Saves under data/generated_images/; returns paths, thumbnails and a receipt. " + CodexImageGenerationHelp.usage,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("prompt", ToolSchema.strSchema("Describe the image or the edits, identifying what each reference supplies and what must stay unchanged.")),
                        ("size", ToolSchema.strSchema("Codex: prompt preference, e.g. 16:9 or auto; inspect actual dimensions. OpenAI API: forwarded as size, subject to its model’s limits.")),
                        ("quality", ToolSchema.strSchema("low, medium, high or auto; visual quality, not thinking effort. Codex: prompt preference, fulfillment unknown unless reported. OpenAI API: forwarded as quality.")),
                        ("output_format", ToolSchema.strSchema("png (default), jpeg or webp. Codex: prompt preference; decoded bytes determine extension. OpenAI API: forwarded as output_format.")),
                        ("background", ToolSchema.strSchema("Codex only: auto, opaque or transparent prompt preference; transparency requires PNG/WebP. Inspect alpha. Omit on OpenAI API.")),
                        ("n", ToolSchema.intSchema("Image count, default 1, clamped to 1–4. Codex requests are independent; OpenAI API receives n.")),
                        ("timeout_seconds", ToolSchema.intSchema("Codex only: whole run timeout, 30–1800 seconds, default 600. OpenAI API uses a fixed 180-second request timeout.")),
                        ("referenced_image_paths", stringArraySchema("Codex only: up to four authorized local PNG/JPEG/WebP files, 8 MiB each, 20 MiB total; copied and attached to the run. Resupply for each edit. Omit or [] on OpenAI API.")),
                        ("action", ToolSchema.strSchema("Codex only: auto (default), generate or edit; edit requires references. Omit on OpenAI API.")),
                    ],
                    required: ["prompt"]
                )
            ),
            requestedSchema(name: "context_lookup", toolClass: .read, capabilities: ["tool_call"],
                description: "Find NativeAgent capabilities and where to use them. Supports type='lookup_feature_surface' / 'feature_surface' / 'features'.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Capability or feature text to search for. Empty returns the first bounded feature-surface records.")),
                        ("type", ToolSchema.strSchema("Optional lookup type. Supported: lookup_feature_surface, feature_surface, features.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "scratchpad_read", toolClass: .read,
                description: "Read the current conversation scratchpad written by /scratch controls or app action chat.scratch. The chat tool loop injects session_id when available.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("key", ToolSchema.strSchema("Optional scratch key. If omitted, returns bounded scratch keys and values.")),
                        ("session_id", ToolSchema.strSchema("Optional conversation id; injected by the Swift tool loop for normal chat/Telegram turns.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "time_now", toolClass: .read, capabilities: ["tool_call"],
                description: "Return the current date and time in multiple representations: ISO-8601 UTC, ISO-8601 local timezone, epoch seconds, and a human-readable summary including weekday + day of year. Zero inputs.",
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            requestedSchema(name: "recent_trace_summary", toolClass: .read, capabilities: ["tool_call"],
                description: "Read saved traces and receipts. view:receipts returns compact tool-end evidence with action, target, effect and time; effects_only filters successful non-read receipts, and since accepts today or an ISO-8601 timestamp. completed_turns selects the last N finished turns, excluding unfinished turns; scan limits are reported. name and turn_id select exact evidence. Results are bounded to 32 KiB including metadata; follow next_call for continuation. turn_id or completed_turns plus fields reads bounded, secret-redacted values.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("Maximum events per page, default 10, capped at 50.")),
                        ("offset", ToolSchema.intSchema("Continuation event offset; copy from next_call.")),
                        ("before", ToolSchema.strSchema("Continuation anchor timestamp; copy from next_call to keep the same window.")),
                        ("view", ToolSchema.enumStringSchema(["receipts", "usage", "model_calls"], "Use receipts for compact tool.dispatch end receipts across all conversations unless session_id is explicit; non-read actions precede reads. usage sums recorded model calls across all conversations, defaults since to today, and reports missing measurements and retention coverage. Omit for all event kinds.")),
                        ("trace", ToolSchema.strSchema("For receipt_id, the exact turn_traces/<yyyy-MM-dd>.jsonl file; reads the complete day.")),
                        ("by", ToolSchema.enumStringSchema(["model", "surface", "day"], "Usage grouping; default model. day uses local calendar dates.")),
                        ("effects_only", ToolSchema.boolSchema("Successful non-read receipts with bounded target/effect previews; excludes previews and explicit no-effect results. Does not prove effects still persist.")),
                        ("since", ToolSchema.strSchema("today (local midnight) or an ISO-8601 timestamp with Z or an offset. Reads the complete retained time window without tail scan limits; response pagination still applies.")),
                        ("completed_turns", ToolSchema.intSchema("Last N finished turns, capped at 50; limit and the total response budget still apply. Includes completed, failed and cancelled turns.")),
                        ("kind", ToolSchema.strSchema("Optional event kind substring, e.g. tool.dispatch or turn.terminal; tool/action names belong in name.")),
                        ("name", ToolSchema.strSchema("Optional exact tool or app action filter, e.g. mac.clipboard_read or mac.clipboard_read. For returned values use turn_id or completed_turns with fields:[name,args,result,receipt].")),
                        ("status", ToolSchema.strSchema("Optional exact status filter.")),
                        ("session_id", ToolSchema.strSchema("Optional exact conversation filter. Includes sibling events from turns belonging to that conversation.")),
                        ("sessionId", ToolSchema.strSchema("Compatibility alias for session_id.")),
                        ("turn_id", ToolSchema.strSchema("Optional exact turn id filter.")),
                        ("receipt_id", ToolSchema.strSchema("Exact dispatch receipt id, including from an expired result handle; reads retained evidence without repeating the operation.")),
                        ("fields", stringArraySchema("Optional payload keys; requires turn_id or completed_turns. Up to 16 keys, 80 characters each; values share an 8 KiB cap.", minItems: 1, maxItems: 16, maxItemLength: 80)),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "agent_swarm", toolClass: .write,
                description: "Run temporary workers on an objective. Pass objective as the shared task and optionally agents with individual prompts. Workers use the selected Work model. Set reasoning_effort for the run or each worker; omitted levels inherit the run's level, then Work's Think default. Change that default with app setting.set (setting='providers.work_thinking'). Workers default to read-only reasoning; access='inherit' enables ordinary tools under current Trust. Returns worker outputs, optional synthesis and a receipt.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("objective", ToolSchema.strSchema("Required. The task/question every worker should analyze.")),
                        ("agents", looseObjectArraySchema("Optional worker configs. Each object may include name, role, prompt/lens_brief, reasoning_effort, access ('read_only' or 'inherit'), contextSlice, findingsCap.")),
                        ("reasoning_effort", ToolSchema.strSchema("Optional Think level for workers and synthesis: low, medium, high, xhigh, or another level the selected Work model's catalog supports. Defaults to Work's Think level. Each worker may override it with reasoning_effort.")),
                        ("workers", looseObjectArraySchema("Compatibility alias for agents.")),
                        ("roles", looseObjectArraySchema("Compatibility alias for agents.")),
                        ("agentCount", ToolSchema.intSchema("Optional worker count when no agents array is supplied. Default 4, hard cap 20.")),
                        ("access", ToolSchema.enumStringSchema(["read_only", "inherit"], "Worker capability mode. read_only (default) performs prompt-only reasoning. inherit exposes the ordinary NativeAgent tool loop under the same live TrustCenter and workspace gates as the parent; nested delegation and app install/restart remain parent-only.")),
                        ("readOnly", ToolSchema.boolSchema("Compatibility alias: true maps to access=read_only; false maps to access=inherit.")),
                        ("mode", ToolSchema.strSchema("Optional label such as parallel, council, review, or bughunt.")),
                        ("maxParallel", ToolSchema.intSchema("Maximum concurrent workers. Clamped by trust policy.")),
                        ("timeoutSeconds", ToolSchema.intSchema("Per-worker timeout, default 240, capped 900.")),
                        ("synthesize", ToolSchema.nullable(ToolSchema.boolSchema("Whether to run a final synthesis pass. Defaults true for multi-worker runs."))),
                        ("dryRun", ToolSchema.boolSchema("If true, return the planned workers without calling providers.")),
                        ("maxOutputChars", ToolSchema.intSchema("Per-worker and synthesis output cap, default 4000, max 12000.")),
                        ("digestBudgetTokens", ToolSchema.intSchema("Optional soft token budget for the synthesis digest relayed back. When set, the digest is truncated to ~this many tokens with an explicit notice. Omit (default) for no extra truncation.")),
                    ],
                    required: ["objective"]
                )
            ),
        ]
    }
}

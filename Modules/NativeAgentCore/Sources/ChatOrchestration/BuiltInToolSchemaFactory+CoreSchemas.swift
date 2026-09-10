import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

extension BuiltInToolSchemaFactory {
    func coreSchemas() -> [LLMToolSchema?] {
        let schemas: [LLMToolSchema?] = [
            requestedSchema(
                name: "read_page",
                description: "Read a public http(s) page and return readable text and a source receipt. No browser window or signed-in browser session is used, and no consent is needed. Use this for any public page, including when a fetch or browser tool is unavailable, refused, or waiting on consent.",
                parametersJSON: params(properties: [("url", strSchema("Public http(s) URL to read."))], required: ["url"])
            ),
            requestedSchema(
                name: "read_file",
                description: "Read a workspace or user-approved file. Text returns a string. Local PNG, JPEG, WebP, GIF, HEIC, TIFF and BMP images return actual pixels to your model in a tool turn (not OCR); at most 8 MiB and 40 megapixels, first frame oriented and resized to fit 2048 pixels. Read an image path to see it; a filename or consult reference alone is not viewing it. On public/app-only installs, relative paths resolve inside NativeAgent's canonical workspace; use get_persona_doc or persona_read for persona documents rather than guessing their filesystem path. A verified development checkout also accepts repo-relative paths. With Trust Center Full Mac file access active, absolute Mac paths are accepted except NativeAgent trust/secrets/provider paths; /documents/... is treated as the current macOS user's ~/Documents/.... Long handoff markdown files default to a compact leading window unless max_bytes is explicit.",
                parametersJSON: params(
                    properties: [
                        ("path", strSchema("Workspace-relative path such as 'project/file.txt', a repo-relative path only when a verified source checkout exists, or an absolute/~/ path under a Trust Center workspace root. Persona files must use get_persona_doc or persona_read. In Full Mac mode, /documents/<name> maps to the current user's ~/Documents/<name>.")),
                        ("max_bytes", intSchema("Optional byte window. Omit for the safe default; set explicitly only when a larger read is needed.")),
                    ],
                    required: ["path"]
                )
            ),
            requestedNames?.contains("context_expand") != false
                ? TurnToolSchemaCatalogSeed.canonicalContextExpandSchema
                : nil,
            requestedSchema(
                name: "list_dir",
                description: "List a workspace or user-approved directory. On public/app-only installs, relative paths resolve inside NativeAgent's canonical workspace. Use persona_read/list_skills for persona or skill material instead of browsing NativeAgent's private data root. A verified development checkout also accepts repo-relative paths. With Trust Center Full Mac file access active, absolute Mac paths are accepted except NativeAgent trust/secrets/provider paths.",
                parametersJSON: params(
                    properties: [("path", strSchema("Directory path. In Full Mac mode, /documents/<name> maps to the current user's ~/Documents/<name>; a file_not_found result is a path miss, not a trust denial."))],
                    required: ["path"]
                )
            ),
            requestedSchema(
                name: "write_file",
                description: "Write or append UTF-8 content. For ordinary project work, use the canonical NativeAgent workspace/ folder; on a public install it is under ~/Library/Application Support/NativeAgent/workspace. Without Full Mac, paths must be inside that workspace or another Trust Center workspace root such as the iCloud Obsidian vaults folder. With Trust Center Full Mac file access active, broader Mac filesystem writes are accepted except NativeAgent trust/secrets/provider paths and protected system mutations.",
                parametersJSON: params(
                    properties: [
                        ("path", strSchema("A relative path such as project/file.txt (resolved inside the canonical NativeAgent workspace), workspace/project/file.txt, or an absolute/~/ path inside another Trust Center workspace root. Full Mac mode also accepts broader Mac paths, but intentional build/project artifacts belong in the canonical workspace rather than /tmp.")),
                        ("content", strSchema("Content to write.")),
                        ("append", boolSchema("Append instead of replacing the file.")),
                    ],
                    required: ["path", "content"]
                )
            ),
            requestedSchema(
                name: "recall_memory",
                description: "Search long-term memory with query (optional k), or recover an excerpt by exact memory_id with offset/max_characters. Use exactly one mode; set unused fields to null. ID pages return at most 2000 characters. Follow read_more with expected_content_sha256 to keep pages on one text version; record_changed means discard earlier pages and restart at 0. Only currently eligible, disclosed records are readable.",
                parametersJSON: recallParameters()
            ),
            requestedSchema(
                name: "recall_search",
                description: "Compatibility alias for recall_memory. Use query (optional k) to search, OR memory_id with offset/max_characters to recover bounded pages of one eligible fact. Never mix the two modes; set unused fields to null. Follow read_more with expected_content_sha256 until next_offset is null; on record_changed discard earlier pages and restart at 0.",
                parametersJSON: recallParameters()
            ),
            requestedSchema(
                name: "search_kg",
                description: "Search the assistant's knowledge graph for entities matching the query text. Returns up to limit entity summaries.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema()),
                        ("limit", intSchema("max results, default 10, at most 100", minimum: 1, maximum: 100)),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "search_chat_history",
                description: "Search persisted chat/session transcripts when the user references an earlier conversation, old session, or exact wording that may not be in long-term memory. Returns ranked snippets with session ids, titles, roles, and timestamps.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Words or phrase to search for in prior chat/session transcripts.")),
                        ("session_id", strSchema("Optional session id to restrict search to one chat, e.g. a Mac, iOS, or telegram session id.")),
                        ("scope", strSchema("Search scope: auto/current_session_first (default), current_session, previous_session, or all_sessions. previous_session reopens the session named by the \"Since last session\" anchor — same surface, machine/bridge runs excluded — and is the one scope that works with no query, returning that session's tail.")),
                        ("role", strSchema("Optional role filter: user, assistant, tool, or system.")),
                        ("mode", strSchema("hybrid (default), exact substring, or continuity. Use continuity when asked to resume/revisit a conversation: up to four hits include bounded neighboring user/assistant messages so decisions and corrections retain context. Nothing is retrieved until you invoke this tool.")),
                        ("limit", intSchema("results per page, default 8, capped at 12; refine the query before paging")),
                        ("offset", intSchema("result offset for a follow-up page; omit on the first search")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "session_search",
                description: "Alias for search_chat_history. Use this when the user asks to search a prior session or find something from an older conversation.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Words or phrase to search for in prior chat/session transcripts.")),
                        ("session_id", strSchema("Optional session id to restrict search to one chat.")),
                        ("scope", strSchema("Search scope: auto/current_session_first (default), current_session, previous_session, or all_sessions. previous_session reopens the session named by the \"Since last session\" anchor — same surface, machine/bridge runs excluded — and is the one scope that works with no query, returning that session's tail.")),
                        ("role", strSchema("Optional role filter: user, assistant, tool, or system.")),
                        ("mode", strSchema("hybrid (default), exact, or continuity (up to four hits with bounded neighboring messages for requested conversation resumption).")),
                        ("limit", intSchema("results per page, default 8, capped at 12; refine the query before paging")),
                        ("offset", intSchema("result offset for a follow-up page; omit on the first search")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "read_chat_message",
                description: "Read ONE persisted chat message in full, by the message_id a search_chat_history hit returned. Search gives a 368-character preview and continuity gives neighbours; this gives the whole message, paged. Use it instead of re-phrasing a query to see a different fragment of the same message.",
                parametersJSON: params(
                    properties: [
                        ("message_id", strSchema("The message_id from a search_chat_history hit.")),
                        ("session_id", strSchema("Optional session id the message belongs to. Omit to look through every transcript, newest first.")),
                        ("offset", intSchema("Character offset into the message, default 0. Pass the previous response's next_offset for the following page.", minimum: 0)),
                        ("limit", intSchema("Characters per page, default 8000, capped at 16000.", minimum: 1, maximum: 16_000)),
                    ],
                    required: ["message_id"]
                )
            ),
            requestedSchema(
                name: "get_persona_doc",
                description: "Read one of your canonical persona documents — SOUL.md, USER.md, AGENTS.md, VOICE.md, GROWTH.md, MEMORY.md. These documents guide the agent in every conversation; read the full text of one on demand.",
                parametersJSON: params(
                    properties: [
                        ("doc", strSchema("One of: SOUL, USER, AGENTS, VOICE, GROWTH, MEMORY")),
                    ],
                    required: ["doc"]
                )
            ),
            requestedSchema(
                name: "persona_read",
                description: "Read one of your canonical persona documents by kind. Use kind='growth' for GROWTH.md, kind='user' for USER.md, kind='soul' for SOUL.md, kind='voice' for VOICE.md, kind='agents' for AGENTS.md, or kind='skill' with skill_name.",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("One of: soul, user, voice, growth, agents, skill.")),
                        ("skill_name", strSchema("Required only when kind='skill'.")),
                    ],
                    required: ["kind"]
                )
            ),
            requestedSchema(
                name: "persona_write",
                description: "Replace one of your own persona documents using this tool. USER.md is read-only here because it is generated from Memories; use commit_memory for durable user facts.",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("One of: soul, voice, growth, agents, skill. Do not use user; USER.md is generated from Memories.")),
                        ("content", strSchema("Full replacement document content.")),
                        ("skill_name", strSchema("Required only when kind='skill'.")),
                    ],
                    required: ["kind", "content"]
                )
            ),
            requestedSchema(
                name: "persona_append_section",
                description: "Append a titled markdown section to one of your own persona documents using this tool. USER.md is read-only here because it is generated from Memories; use commit_memory for durable user facts.",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("One of: soul, voice, growth, agents. Do not use user; USER.md is generated from Memories.")),
                        ("title", strSchema("Markdown section title. Do not include the leading ##.")),
                        ("content", strSchema("Section body to append.")),
                    ],
                    required: ["kind", "title", "content"]
                )
            ),
            requestedSchema(
                name: "agent_introspect",
                description: "Return compact live Swift-native runtime, provider, and conversation identity. Use tool_catalog for tool names. Request detail=full only for diagnostic roots, MCP names, and the seven-day outcome population audit.",
                parametersJSON: params(
                    properties: [("detail", strSchema("compact (default) or full diagnostic projection"))],
                    required: []
                )
            ),
            requestedSchema(
                name: "daemon_introspect",
                description: "Compatibility alias for agent_introspect. It is backed by the Swift runtime; no external runtime is used.",
                parametersJSON: params(
                    properties: [("detail", strSchema("compact (default) or full diagnostic projection"))],
                    required: []
                )
            ),
            requestedSchema(
                name: "tool_catalog",
                description: "Compact lazy-tool discovery. Returns current/loadable names and exact tool_groups without dumping every schema. Call tool_load(session_id:..., category:...) or names:[...] before dispatch. Use detail=full only for explicit diagnostics.",
                parametersJSON: params(
                    properties: [
                        ("session_id", strSchema("Optional. Pass your current chat session id to see your loaded set; the tool loop auto-fills this.")),
                        ("detail", strSchema("Optional: compact (default) or full. Full includes every description/schema and is diagnostic-only.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "list_tools",
                description: "Compatibility alias for tool_catalog. Returns compact discovery by default; detail=full is diagnostic-only.",
                parametersJSON: params(
                    properties: [
                        ("session_id", strSchema("Optional. Pass your current chat session id to see your loaded set; the tool loop auto-fills this.")),
                        ("detail", strSchema("Optional: compact (default) or full.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "tool_load",
                description: "Expand this tool-loop turn with an additional tool category or exact names. Tools already attached to the request are ready to call directly; resident routing supplies high-confidence groups before the first model call.",
                parametersJSON: params(
                    properties: [
                        ("session_id", strSchema("The chat session id whose loaded-tools list to mutate. Required.")),
                        ("names", stringArraySchema("Tool names to load.")),
                        ("name", strSchema("Single tool name to load (alternative to names[]).")),
                        ("category", strSchema("Optional lazy-load category. Known: context, memory, markets, research, subagents, github, agentmail, slack, art, images, builder; app chat also supports notifications, browser, and research.")),
                    ],
                    required: ["session_id"]
                )
            ),
            requestedSchema(
                name: "tool_unload",
                description: "Drop loaded tool schemas from your session to free tokens. Pass names:[\"a\",\"b\"] to drop specific tools, or all:true to drop everything except the always-on core. Use this when you've finished with a multi-tool task and want to keep the next turn slim.",
                parametersJSON: params(
                    properties: [
                        ("session_id", strSchema("The chat session id whose loaded-tools list to mutate.")),
                        ("names", stringArraySchema("Tool names to drop. Optional if all:true.")),
                        ("all", boolSchema("If true, drop EVERY session-loaded tool. The always-on core stays available.")),
                    ],
                    required: ["session_id"]
                )
            ),
            requestedSchema(
                name: "tool_result_page",
                description: "Recover one page of an oversized tool result retained for this exact turn. Use the result_handle and page_count from a bounded_tool_result receipt. Pages are read-only, redacted, at most 8000 UTF-8 bytes, session/turn scoped, and expire when the turn ends.",
                parametersJSON: params(
                    properties: [
                        ("result_handle", strSchema("Opaque handle from the bounded_tool_result receipt.")),
                        ("page", intSchema("Zero-based page index. Start at 0; follow next_page while has_more is true.")),
                        ("session_id", strSchema("Current chat session id; the tool loop auto-fills this.")),
                    ],
                    required: ["result_handle"]
                )
            ),
            requestedSchema(
                name: "image_generate",
                description: "Generate or edit raster images from a prompt and optional local references. Defaults to the actual built-in image_gen.imagegen tool in a bounded Codex run, with no NativeAgent HTTP image request or OPENAI_API_KEY. Lazy-load this for art, illustration, design, poster, logo, mockup, or image-generation requests. Requires Trust Center multimodalPolicy.image_generation_openai=true. Saves images under data/generated_images/ and returns file paths plus a receipt. provider='codex_cli' is an alias for this same built-in route; provider='openai_api' explicitly selects the paid OpenAI platform API; never selected automatically. " + CodexImageGenerationHelp.usage,
                parametersJSON: params(
                    properties: [
                        ("prompt", strSchema("Describe the image or the edits, identifying what each reference supplies and what must stay unchanged.")),
                        ("provider", strSchema("codex (default) or codex_cli: actual Codex built-in image_gen tool. openai_api is an existing explicitly selected paid route, never an automatic fallback.")),
                        ("model", strSchema("The built-in Codex image tool exposes no model selector. Omit this field; legacy gpt-image-2 quality aliases are compatibility preferences only. The result never assumes Images 2.5 identity.")),
                        ("size", strSchema("Size/aspect preference passed to Codex in prose, such as 16:9, 1536x864, or auto. No native size parameter is exposed by the built-in tool; inspect actual dimensions.")),
                        ("quality", strSchema("Visual quality preference: low, medium, high or auto. The built-in image tool has no quality parameter. Forwarded as prompt preference, with qualityFulfillment unknown unless independently reported. Do not confuse this with model reasoning effort.")),
                        ("output_format", strSchema("Format preference: png (default), jpeg or webp. Built-in Codex may choose its own format; decoded bytes determine the artifact extension.")),
                        ("background", strSchema("Background preference: auto, opaque or transparent. Transparent requests require PNG/WebP; preserve genuine alpha and inspect the result.")),
                        ("n", intSchema("Number of images, default 1, clamped to 1–4. Codex makes independent requests, not a coherent batch.")),
                        ("timeout_seconds", intSchema("Whole Codex image run timeout, 30-1800 seconds; default 600.")),
                        ("referenced_image_paths", stringArraySchema("Up to four authorized local PNG/JPEG/WebP files, 8 MiB each and 20 MiB total. Copies are attached to Codex and passed to the actual built-in tool. Resupply the latest result for further edits.")),
                        ("action", strSchema("auto (default), generate or edit. edit requires references; Codex is instructed to preserve the reference while applying the requested change.")),
                    ],
                    required: ["prompt"]
                )
            ),
            requestedSchema(
                name: "list_skills",
                description: "Compact skill manifest: list names, triggers, descriptions, and status only. Skill bodies are lazy-loaded; never read every skill or inspect private registry files.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "read_skill",
                description: "Lazy-load one relevant skill body by manifest name. Call only when its triggers match the current work; do not preload all skill bodies.",
                parametersJSON: params(
                    properties: [("name", strSchema())],
                    required: ["name"]
                )
            ),
            requestedSchema(
                name: "save_skill",
                description: "Create or update one reusable skill in Capabilities. Use only for an explicit user request or a proven repeatable procedure—not facts (use commit_memory). Never write or inspect skills/registry.json or skill body paths yourself. Skills are guidance only and cannot grant tools, permissions, approval bypasses, or safety authority.",
                parametersJSON: params(
                    properties: [
                        ("name", strSchema("Short stable display name.")),
                        ("description", strSchema("One concise sentence describing when and why this skill helps.")),
                        ("triggers", stringArraySchema("Specific phrases or situations that make this skill relevant.")),
                        ("content", strSchema("Markdown body beginning with a heading and containing the reusable procedure. Maximum 65536 UTF-8 bytes.")),
                    ],
                    required: ["name", "description", "content"]
                )
            ),
            requestedSchema(
                name: "context_lookup",
                description: "Find NativeAgent capabilities and where to use them. Supports type='lookup_feature_surface' / 'feature_surface' / 'features'.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Capability or feature text to search for. Empty returns the first bounded feature-surface records.")),
                        ("type", strSchema("Optional lookup type. Supported: lookup_feature_surface, feature_surface, features.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "scratchpad_read",
                description: "Read the current session scratchpad written by /scratch controls. The chat tool loop injects session_id when available.",
                parametersJSON: params(
                    properties: [
                        ("key", strSchema("Optional scratch key. If omitted, returns bounded scratch keys and values.")),
                        ("session_id", strSchema("Optional session id; injected by the Swift tool loop for normal chat/Telegram turns.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "time_now",
                description: "Return the current date and time in multiple representations: ISO-8601 UTC, ISO-8601 local timezone, epoch seconds, and a human-readable summary including weekday + day of year. Zero inputs. Use when reasoning about deadlines, scheduling, age of files/events, or relative time references.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "recent_trace_summary",
                description: "Return a bounded secret-safe summary from the current Swift turn-trace ledger. Includes metadata and payload keys, not raw payload bodies.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum events, default 10, capped at 50.")),
                        ("kind", strSchema("Optional trace kind substring filter.")),
                        ("status", strSchema("Optional exact status filter.")),
                        ("session_id", strSchema("Optional exact chat session filter. Includes sibling events from turns belonging to that session.")),
                        ("sessionId", strSchema("Compatibility alias for session_id.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "agent_swarm",
                description: "Run a Swift-native swarm of up to 20 temporary workers. Workers default to read-only reasoning; set access='inherit' on the swarm or an individual worker when it must use NativeAgent tools. Inherited access reuses the parent's ordinary TrustCenter, workspace, autonomy, receipt, and verification gates—it grants no new authority. The configured Swarms provider/model is the default; model, models, synthesisModel, or per-worker model may override it. Returns bounded outputs, optional synthesis, and a durable swarm receipt.",
                parametersJSON: params(
                    properties: [
                        ("objective", strSchema("Required. The task/question every worker should analyze.")),
                        ("agents", looseObjectArraySchema("Optional worker configs. Each object may include name, role, prompt/lens_brief, model, reasoningEffort, access ('read_only' or 'inherit'), contextSlice, findingsCap.")),
                        ("workers", looseObjectArraySchema("Compatibility alias for agents.")),
                        ("roles", looseObjectArraySchema("Compatibility alias for agents.")),
                        ("agentCount", intSchema("Optional worker count when no agents array is supplied. Default 4, hard cap 20.")),
                        ("access", enumStringSchema(["read_only", "inherit"], "Worker capability mode. read_only (default) performs prompt-only reasoning. inherit exposes the ordinary NativeAgent tool loop under the same live TrustCenter and workspace gates as the parent; nested delegation and app install/restart remain parent-only.")),
                        ("readOnly", boolSchema("Compatibility alias: true maps to access=read_only; false maps to access=inherit.")),
                        ("model", strSchema("Default model for workers unless a worker overrides it. Omit to use the model selected for Swarms in Providers.")),
                        ("models", stringArraySchema("Optional model list cycled across workers.")),
                        ("synthesisModel", strSchema("Optional model for the synthesis pass.")),
                        ("mode", strSchema("Optional label such as parallel, council, review, or bughunt.")),
                        ("maxParallel", intSchema("Maximum concurrent workers. Clamped by trust policy.")),
                        ("timeoutSeconds", intSchema("Per-worker timeout, default 240, capped 900.")),
                        ("synthesize", boolSchema("Whether to run a final synthesis pass. Defaults true for multi-worker runs.")),
                        ("dryRun", boolSchema("If true, return the planned workers without calling providers.")),
                        ("maxOutputChars", intSchema("Per-worker and synthesis output cap, default 4000, max 12000.")),
                        ("digestBudgetTokens", intSchema("Optional soft token budget for the synthesis digest relayed back. When set, the digest is truncated to ~this many tokens with an explicit notice. Omit (default) for no extra truncation. Use a small budget (e.g. 500-2000) to keep the returned summary short.")),
                    ],
                    required: ["objective"]
                )
            ),
            requestedSchema(
                name: "market_status",
                description: "Return Swift-native market research configuration status: enabled sources, local watchlist groups, and TradingView readiness. Secrets/API keys/cookies are never returned.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "market_watchlists",
                description: "Read configured market watchlists from Swift-owned local config, or fetch TradingView watchlists when source='tradingview'. Secrets are never returned.",
                parametersJSON: params(
                    properties: [
                        ("source", strSchema("local or tradingview; default local")),
                        ("group", strSchema("Optional local watchlist group such as equities, futures, crypto, volatility, macro_series.")),
                        ("includeSymbols", boolSchema("Include symbol arrays; default true.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "tradingview_watchlist",
                description: "Compatibility alias for market_watchlists with source='tradingview'. Reads TradingView watchlists through Swift using stored session config; secrets are never returned.",
                parametersJSON: params(
                    properties: [
                        ("includeSymbols", boolSchema("Include symbol arrays; default true.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "market_quote",
                description: "Fetch a live market quote snapshot for one or more symbols through Swift. Default provider is tradingview; provider='yahoo' is available when Yahoo permits the public quote endpoint.",
                parametersJSON: params(
                    properties: [
                        ("symbol", strSchema("Single ticker or TradingView ticker.")),
                        ("symbols", stringArraySchema("Ticker list.")),
                        ("provider", strSchema("tradingview or yahoo; default tradingview.")),
                    ],
                    required: []
                )
            ),
            // X chat tools are read-only. Outbound posts use the connector approval UI.
            requestedSchema(
                name: "x_status",
                description: "Check whether the connected X (Twitter) account is reachable. Returns OAuth2 bearer validity, expiry timestamp, and whether the OAuth1 fallback credentials are present.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "x_me",
                description: "Read the authenticated X account profile — username, display name, verified flag, and public follower/tweet counts.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "x_search",
                description: "Search recent public X posts (last ~7 days). Returns tweet text, author, timestamps, and public metrics.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("X search query string (supports operators like from:user, -filter:retweets).")),
                        // The recent-search endpoint's floor is 10, not 1. Ask
                        // for fewer and X answers 400, so advertise and enforce
                        // the provider's real bound rather than a friendlier one.
                        ("max", intSchema("Maximum tweets to return (10-100, default 10). X's recent-search endpoint rejects values below 10.", minimum: 10, maximum: 100)),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "x_timeline",
                description: "Read the authenticated user's reverse-chronological Following timeline. Tries OAuth2 first; falls back to OAuth1 v2 if the user-context scope isn't authorized.",
                parametersJSON: params(
                    properties: [
                        ("max", intSchema("Maximum tweets to return (1-100, default 25).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "x_user_tweets",
                description: "Read a specific X user's recent tweets by username or numeric id.",
                parametersJSON: params(
                    properties: [
                        ("username", strSchema("X handle without the @. One of username or id is required.")),
                        ("id", strSchema("Numeric X user id. One of username or id is required.")),
                        // The user-tweets endpoint's floor is 5 — lower than
                        // recent search's 10, higher than the timeline's 1. The
                        // advertised default was also wrong: the request builder
                        // has always sent 25.
                        ("max", intSchema("Maximum tweets to return (5-100, default 25). X's user-tweets endpoint rejects values below 5.", minimum: 5, maximum: 100)),
                    ],
                    required: []
                )
            ),
            // Cloud account connectors — read-only chat tools. Credential
            // setup/revoke remains in the Mac Connectors owner.
            requestedSchema(
                name: "gmail_status",
                description: "Check the connected Gmail account and return its address and mailbox counts.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "gmail_search",
                description: "Search the connected Gmail account using Gmail query syntax and return bounded message metadata.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Optional Gmail query, such as from:person@example.com is:unread.")),
                        ("limit", intSchema("Maximum messages to return, 1-20; default 10.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "gmail_read",
                description: "Read one connected Gmail message by id, including bounded plain-text body content.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("Gmail message id returned by gmail_search.")),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "google_calendar_status",
                description: "Check the connected primary Google Calendar and return its identity and timezone.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "google_calendar_list",
                description: "List events from the connected primary Google Calendar. Defaults to the next seven days.",
                parametersJSON: params(
                    properties: [
                        ("time_min", strSchema("Optional inclusive ISO-8601 start time.")),
                        ("time_max", strSchema("Optional exclusive ISO-8601 end time.")),
                        ("limit", intSchema("Maximum events, 1-50; default 20.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "notion_status",
                description: "Check the connected Notion integration identity.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "notion_search",
                description: "Search pages and databases shared with the connected Notion integration.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Optional title search text.")),
                        ("limit", intSchema("Maximum results, 1-50; default 20.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "notion_read_page",
                description: "Read a Notion page and its first bounded block page by id.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("Notion page id returned by notion_search.")),
                    ],
                    required: ["id"]
                )
            ),
            // GitHub — PAT-backed read tools. These are lazy-loaded by
            // tool_load(category:"github") or explicit tool_load by name.
            requestedSchema(
                name: "github_status",
                description: "Validate the connected GitHub Personal Access Token against the authenticated /user endpoint.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "github_list_repos",
                description: "List repositories accessible to the connected GitHub Personal Access Token.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum compact repository rows to return (1-20, default 20). Use pagination/filtering for more.")),
                        ("visibility", strSchema("Optional GitHub visibility filter, e.g. all, public, private.")),
                        ("affiliation", strSchema("Optional GitHub affiliation filter, e.g. owner,collaborator,organization_member.")),
                        ("sort", strSchema("Optional sort field, e.g. updated, created, pushed, full_name.")),
                        ("direction", strSchema("Optional direction, asc or desc.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_list_notifications",
                description: "List bounded GitHub notifications for the connected account through the native API, optionally scoped to one repository. Use for overnight activity, mentions, reviews, assignments, and CI-related notification checks.",
                parametersJSON: params(
                    properties: [
                        ("repo", strSchema("Optional repository as owner/name or a github.com repository URL.")),
                        ("owner", strSchema("Optional owner when repo is only the repository name.")),
                        ("url", strSchema("Optional github.com repository URL when repo is omitted.")),
                        ("all", boolSchema("Include read notifications; default false.")),
                        ("participating", boolSchema("Only notifications where the user is directly participating or mentioned; default false.")),
                        ("since", strSchema("Optional inclusive ISO-8601 timestamp.")),
                        ("before", strSchema("Optional exclusive ISO-8601 timestamp.")),
                        ("limit", intSchema("Maximum compact notifications, 1-20; default 20.")),
                        ("page", intSchema("GitHub pagination page; default 1.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_get_repository",
                description: "Start a GitHub repository inspection through the connected API. Returns bounded repository metadata, the root layout, and README text in one call. Accepts owner/name or a github.com repository URL.",
                parametersJSON: params(
                    properties: [
                        ("repo", strSchema("Repository as owner/name or a github.com repository URL.")),
                        ("owner", strSchema("Optional owner when repo is only the repository name.")),
                        ("url", strSchema("Optional github.com repository URL when repo is omitted.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_read_repository_content",
                description: "Read a GitHub repository file or list a directory through the connected API, with bounded text and compact entries. Use after github_get_repository to inspect relevant source or documentation paths.",
                parametersJSON: params(
                    properties: [
                        ("repo", strSchema("Repository as owner/name or a github.com repository URL.")),
                        ("owner", strSchema("Optional owner when repo is only the repository name.")),
                        ("url", strSchema("Optional github.com repository URL when repo is omitted.")),
                        ("path", strSchema("Repository-relative file or directory path. Omit for root.")),
                        ("ref", strSchema("Optional branch, tag, or commit SHA.")),
                        ("max_characters", intSchema("Maximum text characters for a file, 1000-100000; default 30000.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_list_commits",
                description: "List recent commits for a GitHub repository through the connected API, optionally filtered by branch/ref, path, or time.",
                parametersJSON: params(
                    properties: [
                        ("repo", strSchema("Repository as owner/name or a github.com repository URL.")),
                        ("owner", strSchema("Optional owner when repo is only the repository name.")),
                        ("url", strSchema("Optional github.com repository URL when repo is omitted.")),
                        ("ref", strSchema("Optional branch, tag, or commit SHA.")),
                        ("path", strSchema("Optional repository-relative path filter.")),
                        ("since", strSchema("Optional inclusive ISO-8601 timestamp.")),
                        ("until", strSchema("Optional exclusive ISO-8601 timestamp.")),
                        ("limit", intSchema("Maximum compact commits, 1-20; default 10.")),
                        ("page", intSchema("GitHub pagination page; default 1.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_list_issues",
                description: "List GitHub issues visible to the connected Personal Access Token, optionally scoped to a repository.",
                parametersJSON: params(
                    properties: [
                        ("owner", strSchema("Repository owner when repo is not owner/name.")),
                        ("repo", strSchema("Optional repository name or owner/name. Omit to list authenticated-user issues.")),
                        ("state", strSchema("Optional issue state filter: open, closed, or all.")),
                        ("sort", strSchema("Optional sort field: created, updated, or comments.")),
                        ("direction", strSchema("Optional direction, asc or desc.")),
                        ("limit", intSchema("Maximum compact issue rows to return (1-20, default 20).")),
                        ("page", intSchema("GitHub pagination page (default 1).")),
                        ("labels", strSchema("Optional comma-separated label filter.")),
                        ("since", strSchema("Optional ISO 8601 timestamp filter.")),
                        ("filter", strSchema("Optional authenticated-user issue filter when repo is omitted.")),
                        ("assignee", strSchema("Optional repository issue assignee filter.")),
                        ("creator", strSchema("Optional repository issue creator filter.")),
                        ("mentioned", strSchema("Optional repository issue mentioned-user filter.")),
                        ("milestone", strSchema("Optional repository issue milestone filter.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_search",
                description: "Search GitHub issues and pull requests with GitHub search qualifiers; returns bounded paginated results.",
                parametersJSON: params(properties: [
                    ("query", strSchema("Required GitHub issue/PR search query, including qualifiers such as repo:, is:pr, author:, review-requested:, or label:.")),
                    ("sort", strSchema("Optional search sort: comments, reactions, interactions, created, or updated.")),
                    ("order", strSchema("Optional asc or desc.")),
                    ("limit", intSchema("Compact results per page, 1-20. Bodies are excerpted; use get_issue/get_pull_request for detail.")),
                    ("page", intSchema("Pagination page.")),
                ], required: ["query"])
            ),
            requestedSchema(
                name: "github_list_pull_requests",
                description: "List pull requests for a repository with state, branches, authors, reviewers, labels, milestones, timestamps, commit SHAs, mergeability hints, and URLs.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("Required repository as owner/name.")),
                    ("state", strSchema("open, closed, or all.")),
                    ("head", strSchema("Optional head filter.")), ("base", strSchema("Optional base branch filter.")),
                    ("sort", strSchema("created, updated, popularity, or long-running.")),
                    ("direction", strSchema("asc or desc.")), ("limit", intSchema("Compact rows per page, 1-20.")),
                    ("page", intSchema("Pagination page.")),
                ], required: ["repo"])
            ),
            requestedSchema(
                name: "github_get_issue",
                description: "Get one GitHub issue with its full native metadata, assignees, labels, milestone, timestamps, links, and pull-request marker when applicable.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("Repository as owner/name.")), ("number", intSchema("Issue number.")),
                ], required: ["repo", "number"])
            ),
            requestedSchema(
                name: "github_get_pull_request",
                description: "Get one pull request plus bounded commits, reviews, derived review state, head checks/status, branches, mergeability, and URLs.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("Repository as owner/name.")), ("number", intSchema("Pull request number.")),
                    ("limit", intSchema("Per-related-collection bound, 1-20.")),
                ], required: ["repo", "number"])
            ),
            requestedSchema(
                name: "github_pull_request_files",
                description: "Inspect paginated pull-request changed files and patches with an explicit total patch-character bound.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("Repository as owner/name.")), ("number", intSchema("Pull request number.")),
                    ("limit", intSchema("Files per page, 1-100.")), ("page", intSchema("Pagination page.")),
                    ("max_patch_characters", intSchema("Total patch text bound, 0-250000; default 80000.")),
                ], required: ["repo", "number"])
            ),
            requestedSchema(
                name: "github_pull_request_activity",
                description: "Inspect paginated PR issue comments, inline review comments, reviews, and timeline/status events.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("Repository as owner/name.")), ("number", intSchema("Pull request number.")),
                    ("limit", intSchema("Compact rows per activity collection, 1-20.")), ("page", intSchema("Pagination page.")),
                ], required: ["repo", "number"])
            ),
            requestedSchema(
                name: "github_discover_tracking",
                description: "Resolve accessible repositories and replace the durable GitHub tracking selection. Contribution mode (default) tracks only PRs authored by the authenticated contributor plus issues linked from their PR bodies; repository mode must be explicit.",
                parametersJSON: params(properties: [
                    ("query", strSchema("Configurable repository name/description terms, for example Hermes.")),
                    ("repositories", .object(["type": .string("array"), "items": .object(["type": .string("string")])])),
                    ("mode", strSchema("Tracking scope: contributions (default) or repository.")),
                    ("contributor_login", strSchema("Authenticated GitHub login whose authored PRs define contribution scope.")),
                    ("project", strSchema("Desk project label.")), ("persist", boolSchema("Persist selection; default true.")),
                    ("refresh_interval_minutes", intSchema("Background refresh interval, 5-1440.")),
                    ("stale_after_hours", intSchema("Open entity staleness threshold.")),
                    ("max_pages", intSchema("Accessible-repository discovery page bound, 1-10.")),
                ], required: [])
            ),
            requestedSchema(
                name: "github_project_digest",
                description: "Refresh or read the configured scoped GitHub view and return current authored PR/linked-issue work, closed PR history counts, blockers/staleness, and Desk create/update/archive reconciliation.",
                parametersJSON: params(properties: [
                    ("refresh", boolSchema("Refresh from GitHub before digesting; default true.")),
                ], required: [])
            ),
            requestedSchema(
                name: "github_mutate",
                description: "Create/update/comment/review/close/reopen GitHub issues or PRs, request reviewers, or merge. External write: always uses the native approval/policy path before execution.",
                parametersJSON: params(properties: [
                    ("operation", strSchema("create_issue|update_issue|close_issue|reopen_issue|comment_issue|create_pull_request|update_pull_request|close_pull_request|reopen_pull_request|comment_pull_request|review_pull_request|request_reviewers|merge_pull_request")),
                    ("repo", strSchema("Repository as owner/name.")), ("number", intSchema("Issue/PR number where required.")),
                    ("title", strSchema("Issue/PR title.")), ("body", strSchema("Body or comment text.")),
                    ("state", strSchema("open or closed.")), ("state_reason", strSchema("Issue state reason.")),
                    ("head", strSchema("PR head branch.")), ("base", strSchema("PR base branch.")), ("draft", boolSchema("Create PR as draft.")),
                    ("labels", .object(["type": .array([.string("string"), .string("array")])])),
                    ("assignees", .object(["type": .array([.string("string"), .string("array")])])),
                    ("clear_labels", boolSchema("Explicitly clear every issue label. Empty labels alone preserve the current labels; do not combine this with nonempty labels.")),
                    ("clear_assignees", boolSchema("Explicitly clear every issue assignee. Empty assignees alone preserve the current assignees; do not combine this with nonempty assignees.")),
                    ("reviewers", .object(["type": .array([.string("string"), .string("array")])])),
                    ("team_reviewers", .object(["type": .array([.string("string"), .string("array")])])),
                    ("event", strSchema("Review event: COMMENT, APPROVE, or REQUEST_CHANGES.")),
                    ("merge_method", strSchema("merge, squash, or rebase.")), ("sha", strSchema("Expected head SHA for merge.")),
                    ("commit_title", strSchema("Merge commit title.")), ("commit_message", strSchema("Merge commit message.")),
                    ("milestone", intSchema("Milestone number.")),
                ], required: ["operation", "repo"])
            ),
            requestedSchema(
                name: "github_set_repo_visibility",
                description: "Set a GitHub repository to private or public (external write; requires approval).",
                parametersJSON: params(
                    properties: [
                        ("owner", strSchema("Repo owner when repo is not owner/name.")),
                        ("repo", strSchema("Repository name or owner/name.")),
                        ("private", boolSchema("Set true to make the repo private, or false to make it public.")),
                        ("visibility", strSchema("Optional: private or public.")),
                    ],
                    required: []
                )
            ),
            // Slack tools are lazy-loaded; posting persists a bounded approval request.
            requestedSchema(
                name: "slack_status",
                description: "Check whether the connected Slack workspace token is valid.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "slack_list_channels",
                description: "List Slack conversations accessible to the bot. Use this to find the channel ID before posting.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum conversations to return (1-1000, default 100).")),
                        ("types", strSchema("Optional Slack conversations.list types, e.g. public_channel,private_channel,mpim,im.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "slack_search_messages",
                description: "Search Slack messages through the connected workspace. Requires Slack search permission/token support.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Slack search query.")),
                        ("count", intSchema("Maximum messages to return (1-100, default 20).")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "slack_post_message",
                description: "Stage approval to post a message to Slack using the connected bot token. Use a channel ID from slack_list_channels when possible.",
                parametersJSON: params(
                    properties: [
                        ("channel", strSchema("Slack channel, DM, MPIM, or conversation ID.")),
                        ("text", strSchema("Message text to send.")),
                    ],
                    required: ["channel", "text"]
                )
            ),
            // AgentMail — Agent's hosted inbox. Discovery-only until
            // tool_load(category:"agentmail") or explicit tool_load by name.
            requestedSchema(
                name: "agentmail_list",
                description: "List recent messages in the configured AgentMail inbox. Read-only. Returns sender, subject, date, snippet, and message_id.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum messages to return (1-50, default 20).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "agentmail_read",
                description: "Read the full body of one message from the configured AgentMail inbox. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("message_id", strSchema("Required AgentMail message id from agentmail_list.")),
                    ],
                    required: ["message_id"]
                )
            ),
            requestedSchema(
                name: "agentmail_send",
                description: "Stage approval to send an email from the configured AgentMail inbox; returns a failed status if AgentMail is not configured.",
                parametersJSON: params(
                    properties: [
                        ("to", stringOrStringArraySchema("Recipient address(es). May be a single string or list of strings.")),
                        ("subject", strSchema("Email subject (required).")),
                        ("body", strSchema("Email body text (required).")),
                        ("cc", stringOrStringArraySchema("Optional CC recipient(s). String or array.")),
                    ],
                    required: ["to", "subject", "body"]
                )
            ),
            // ── Mac integration chat tools (2026-06-07) ──
            // Each tool is gated by MacIntegrationPermissionStore (per-integration
            // READ/WRITE bits the user controls in Settings → Mac Integration). The
            // EventKit / notification / Spotlight backends are injected via the
            // app-side MacIntegrationToolBridge. Defaults bias to READ-only for
            // PII surfaces; the two notification channels are write-only outbound.
            requestedSchema(
                name: "mac_calendar_list_upcoming",
                description: "List the user's Mac calendar events from EventKit. Read-only; requires Calendar -> Read permission. Returns event titles, start/end timestamps, calendar names, and locations. For today/tomorrow/specific-date questions, pass day ('today', 'tomorrow', or 'YYYY-MM-DD') instead of relying on a broad hours window.",
                parametersJSON: params(
                    properties: [
                        ("day", strSchema("Optional local-day scope: 'today', 'tomorrow', or 'YYYY-MM-DD'. Use for same-day calendar questions to avoid next-day all-day event bleed.")),
                        ("hours_ahead", intSchema("Lookahead window in hours (1-720, default 24).")),
                        ("limit", intSchema("Maximum events to return (1-100, default 20).")),
                        ("calendar_name", strSchema("Optional filter — return events only from this calendar.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mac_reminders_list_due_today",
                description: "List the user's Mac Reminders due today from EventKit. Read-only; requires Reminders -> Read permission. Returns titles, due timestamps, list names, and completion status.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum reminders to return (1-100, default 20).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mac_notify",
                description: "Post a macOS user notification on this Mac. Requires Mac Notifications -> Write permission. Use for short, actionable alerts, not as a substitute for chat.",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Notification title (required, short).")),
                        ("message", strSchema("Notification body text (required).")),
                        ("subtitle", strSchema("Optional subtitle shown between title and body.")),
                    ],
                    required: ["title", "message"]
                )
            ),
            requestedSchema(
                name: "mobile_notify",
                description: "Push a notification to the paired iPhone via the NativeAgent mobile bridge. Requires iPhone Notifications -> Write permission. Use sparingly; these wake the phone.",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Notification title (required, short).")),
                        ("message", strSchema("Notification body text (required).")),
                        ("subtitle", strSchema("Optional subtitle.")),
                        ("source", strSchema("Optional source tag for tracking (e.g. 'calendar_reminder').")),
                    ],
                    required: ["title", "message"]
                )
            ),
            requestedSchema(
                name: "mac_spotlight_search",
                description: "Run a Spotlight (NSMetadataQuery) search against the user's Mac and return matching file paths with display names and content types. Read-only; requires Spotlight -> Read permission.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Spotlight query string. Alias 'q' is also accepted.")),
                        ("q", strSchema("Alias for 'query'.")),
                        ("limit", intSchema("Maximum results (1-100, default 20).")),
                    ],
                    required: ["query"]
                )
            ),
            // Sensitive Mac Integration writes default off and require the user's toggle.
            requestedSchema(
                name: "contacts_search",
                description: "Search the user's local Mac Contacts by name, phone, or email and return matching records (name, organization, phones, emails, identifier). Read-only; requires Contacts -> Read permission.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Search string — matches against name, phone, or email.")),
                        ("limit", intSchema("Maximum contacts to return (1-100, default 20).")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "contacts_create_or_update",
                description: "Create a new contact or update an existing one in the user's Mac Contacts. If 'identifier' is provided, the matching contact is updated; otherwise a new contact is created. Requires Contacts -> Write permission (OFF by default).",
                parametersJSON: params(
                    properties: [
                        ("given_name", strSchema("First name (optional).")),
                        ("family_name", strSchema("Last name (optional).")),
                        ("organization", strSchema("Organization / company (optional).")),
                        ("phones", stringArraySchema("Optional list of phone numbers.")),
                        ("emails", stringArraySchema("Optional list of email addresses.")),
                        ("identifier", strSchema("If set, update the contact with this CNContact identifier instead of creating a new one.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_list_recent",
                description: "List the most recent messages from Apple Mail's primary inbox (sender, subject, date, snippet). Read-only; requires Mail → Read permission.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum messages to return (1-50, default 10).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_search",
                description: "Search Apple Mail across mailboxes for messages matching a query (subject/sender/body) and return matching summaries. Read-only; requires Mail → Read permission.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Search string applied across subject, sender, and body.")),
                        ("limit", intSchema("Maximum messages to return (1-50, default 10).")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "mail_send",
                description: "Compose and send an email through Apple Mail. Requires Mail -> Write permission (OFF by default). The user must explicitly toggle this on in Settings -> Mac Integration before sending.",
                parametersJSON: params(
                    properties: [
                        ("to", stringOrStringArraySchema("Recipient address(es). May be a single string or list of strings.")),
                        ("subject", strSchema("Email subject (required).")),
                        ("body", strSchema("Email body text (required).")),
                        ("cc", stringOrStringArraySchema("Optional CC recipient(s). String or array.")),
                        ("bcc", stringOrStringArraySchema("Optional BCC recipient(s). String or array.")),
                    ],
                    required: ["to", "subject", "body"]
                )
            ),
            requestedSchema(
                name: "messages_recent_threads",
                description: "List the user's most recent iMessage threads (handle, last message, last-message timestamp). Read-only; requires Messages -> Read permission.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum threads to return (1-30, default 10).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "messages_send",
                description: "Send an iMessage to a phone number or email handle. Requires Messages -> Write permission (OFF by default). The user must explicitly toggle this on before sending.",
                parametersJSON: params(
                    properties: [
                        ("to", strSchema("Recipient handle — phone number or email registered with iMessage.")),
                        ("body", strSchema("Message body (required).")),
                    ],
                    required: ["to", "body"]
                )
            ),
            requestedSchema(
                name: "notes_search",
                description: "Search Apple Notes by query and return matching note titles, folders, modification dates, and snippets. Read-only; requires Notes → Read permission.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Search string applied across note titles and bodies.")),
                        ("limit", intSchema("Maximum notes to return (1-50, default 10).")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "notes_create",
                description: "Create a new Apple Note with title + body, optionally in a named folder. Requires Notes → Write permission (OFF by default).",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Note title (required).")),
                        ("body", strSchema("Note body content (required).")),
                        ("folder", strSchema("Optional folder name; created in the default folder when omitted. A named folder that does not exist is an error listing the folders that do — it is never silently swapped for the default.")),
                    ],
                    required: ["title", "body"]
                )
            ),
            requestedSchema(
                name: "music_now_playing",
                description: "Report what Apple Music is currently playing (track title, artist, album, playback state). Read-only; requires Music → Read permission.",
                parametersJSON: params(
                    properties: [],
                    required: []
                )
            ),
            requestedSchema(
                name: "invoke_claude",
                description: "Invoke Claude (Claude Code CLI) as a blocking subprocess for a focused real-time question. Use claude_message for multi-minute repo work so the current chat stays responsive. The spawned Claude inherits local config, runs in cwd, and writes an audit trail under data/from_claude/.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The question or task for Claude. Be specific — the fresh session has no context unless you provide it.")),
                        ("context", strSchema("Optional preface — what you were doing, what failed, file paths involved, the actual error. Prepended to the question.")),
                        ("cwd", strSchema("Working directory for the spawned Claude. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                        ("timeout_seconds", intSchema("Maximum blocking wait. Default 180 seconds. Prefer claude_message rather than raising this for long work.")),
                        ("commit_hash", strSchema("Optional git commit hash to anchor the context. Useful when asking 'is the diff at <hash> doing what I think it's doing?'")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "claude_message",
                description: "Send a message to Claude (Claude Code CLI running locally) and start work on it now. Set conversation_mode=new and omit conversation_id for unrelated work; set conversation_mode=resume and pass this tool's exact returned conversationId only for a contextual follow-up. A new coding conversation receives its own Git worktree and a resume reuses it. The message is durably queued, then a headless Claude Code session works it and returns a '[claude-wake] Automated completion event'. Completion receipts should not trigger reflexive acknowledgments.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The message to Claude — full prose, no markdown headers needed. Be specific about the requested work or review.")),
                        ("priority", obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("info"),
                                .string("important"),
                                .string("urgent"),
                            ])),
                            ("description", .string("How prominently to surface this to Claude. 'info' = goes in the digest. 'important' = highlighted. 'urgent' = surfaces with a 🚨 tag.")),
                        ])),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", strSchema("Optional short topic tag for new work only (e.g. 'bug-music-tcc'). Omit on resume; the conversationId already owns the topic.")),
                        ("conversation_id", conversationReferenceSchema("claude", "claude_message")),
                        ("pair_reviewer", boolSchema("Set true for an implementation dispatch that needs one paired reviewer. The builder pairs that reviewer at the start, commits before review, gives the reviewer the exact committed SHA, receives findings back, and remains responsible for fixes. Omit for notes, questions, and review-only work.")),
                        ("desk_item", nonEmptyStringSchema("Optional exact live Desk number or handle this delegated work belongs to. NativeAgent binds terminal execution and delivery evidence back to that item.")),
                        ("working_directory", strSchema("Optional existing absolute project directory for a new Claude Code conversation. Canonical NativeAgent workspace/source paths work normally; any other directory requires active Full Mac YOLO with outside-workspace access allowed. Follow-ups reuse their assigned private worktree and reject a conflicting directory.")),
                        ("timeout_seconds", intSchema("Optional wall-clock budget for Claude's spawned session, clamped 60-3600. Default 900. Build-sized work orders (multi-file Swift changes, test suites) MUST pass a larger value: 900s has killed real sessions mid-build.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "omp_message",
                description: "Send an asynchronous task to the local OMP CLI harness (Kimi K3). Set conversation_mode=new and omit conversation_id for unrelated work; set conversation_mode=resume and pass this tool's exact returned conversationId only for a contextual follow-up. A new coding conversation receives its own Git worktree and a resume reuses it. The final reply or honest failure/timeout receipt returns as an '[omp-wake] Automated completion event'.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The complete task or question for OMP.")),
                        ("priority", obj([
                            ("type", .string("string")),
                            ("enum", .array([.string("info"), .string("important"), .string("urgent")])),
                            ("description", .string("Receipt prominence.")),
                        ])),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", strSchema("Optional short stable topic for new work. Omit on resume; the conversationId already owns the topic.")),
                        ("conversation_id", conversationReferenceSchema("omp", "omp_message")),
                        ("desk_item", nonEmptyStringSchema("Optional exact live Desk number or handle this delegated work belongs to. NativeAgent binds terminal execution and delivery evidence back to that item.")),
                        ("working_directory", strSchema("Optional existing absolute project directory for a new OMP conversation. External paths require Full Mac YOLO with outside-workspace access allowed. Follow-ups reuse their assigned private worktree and reject a conflicting directory.")),
                        ("timeout_seconds", intSchema("OMP wall-clock guard, clamped 60-3600 seconds. Default 900.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "invoke_codex",
                description: "Invoke Codex as a blocking subprocess for a focused real-time question or short inspection. Use codex_message for builds, refactors, test suites, or anything likely to take more than a few minutes so the current chat stays responsive. Writes an audit envelope under data/from_codex/.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The question or task for Codex. Be specific; Codex is a fresh subprocess and only knows the context you provide.")),
                        ("context", strSchema("Optional preface: what you were doing, what failed, file paths, errors, and desired outcome.")),
                        ("cwd", strSchema("Working directory for Codex. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                        ("timeout_seconds", intSchema("Maximum blocking wait. Default 600 seconds. Prefer codex_message rather than raising this for long repo work.")),
                        ("commit_hash", strSchema("Optional git commit hash to anchor the context.")),
                        ("model", obj([
                            ("type", .string("string")),
                            ("enum", .array(OpenAIExecutionControls.codexBridgeModelIDs.map(JSONValue.string))),
                            ("description", .string("Optional per-call Codex model. Omit to inherit the active Codex CLI default.")),
                        ])),
                        ("reasoning_effort", obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("low"),
                                .string("medium"),
                                .string("high"),
                                .string("xhigh"),
                                .string("max"),
                                .string("ultra"),
                            ])),
                            ("description", .string("Optional per-call Codex thinking level. Available levels depend on the selected model. Omit to inherit the Codex default.")),
                        ])),
                        ("fast", boolSchema("Optional per-call Fast mode. true selects Codex priority service; false explicitly selects default service; omit to inherit the Codex default.")),
                        ("sandbox", obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("read-only"),
                                .string("workspace-write"),
                                .string("danger-full-access"),
                            ])),
                            ("description", .string("Codex sandbox. Defaults to workspace-write. Use danger-full-access only when the task genuinely needs outside-workspace access.")),
                        ])),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "codex_message",
                description: "Send an asynchronous note/task to Codex. Set conversation_mode=new and omit conversation_id for unrelated work; set conversation_mode=resume and pass this tool's exact returned conversationId only for a contextual follow-up. A new coding conversation receives its own Git worktree and a resume reuses it. NativeAgent durably queues the task, starts or queues a Codex app-server turn, and returns Codex's final answer through the local bridge.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The message to Codex. Include enough context to be useful in a later Codex session.")),
                        ("priority", obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("info"),
                                .string("important"),
                                .string("urgent"),
                            ])),
                            ("description", .string("How prominently to surface this in the Codex bridge inbox.")),
                        ])),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", strSchema("Optional short topic tag for new work. Omit on resume; the conversationId already owns the thread.")),
                        ("conversation_id", conversationReferenceSchema("codex", "codex_message")),
                        ("completion_mode", obj([
                            ("type", .string("string")),
                            ("enum", .array([.string("report"), .string("receipt_only")])),
                            ("description", .string("How Codex's terminal result returns. Use report for delegated work or a question whose answer the agent must assess. Use receipt_only for a one-way acknowledgment, status note, approval, or handoff that should settle durably without creating another chat turn. Defaults to report.")),
                        ])),
                        ("pair_reviewer", boolSchema("Set true for an implementation dispatch that needs one paired reviewer. The builder pairs that reviewer at the start, commits before review, gives the reviewer the exact committed SHA, receives findings back, and remains responsible for fixes. Omit for notes, questions, and review-only work.")),
                        ("desk_item", nonEmptyStringSchema("Optional exact live Desk number or handle this delegated work belongs to. NativeAgent binds terminal execution and delivery evidence back to that item.")),
                        ("model", obj([
                            ("type", .string("string")),
                            ("enum", .array(OpenAIExecutionControls.codexBridgeModelIDs.map(JSONValue.string))),
                            ("description", .string("Optional model for this asynchronous Codex task. Omit to inherit the active Codex default.")),
                        ])),
                        ("reasoning_effort", obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("low"),
                                .string("medium"),
                                .string("high"),
                                .string("xhigh"),
                                .string("max"),
                                .string("ultra"),
                            ])),
                            ("description", .string("Optional thinking level for this task. Available levels depend on the selected model.")),
                        ])),
                        ("fast", boolSchema("Optional Fast mode for this task. true selects Codex priority service; false selects default service.")),
                        ("working_directory", strSchema("Optional existing absolute project directory for a new Codex conversation. Canonical NativeAgent workspace/source paths work normally; any other directory requires active Full Mac YOLO with outside-workspace access allowed. Follow-ups reuse their assigned private worktree and reject a conflicting directory.")),
                        ("repository", strSchema("New work only: optional GitHub repository as 'owner/name' (never a filesystem path). NativeAgent resolves it to a local clone whose git remote actually points at that repository and runs Codex there with repository network access. Omit or send an empty string on resume because the saved conversation owns its checkout; any repository hint on a resume is ignored. An unknown repository is ignored rather than failing the send.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "music_control",
                description: "Control Apple Music playback. Supported actions: 'play', 'pause', 'toggle', 'next', 'previous'. Requires Music → Write permission (OFF by default).",
                parametersJSON: params(
                    properties: [
                        ("action", obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("play"),
                                .string("pause"),
                                .string("toggle"),
                                .string("next"),
                                .string("previous"),
                            ])),
                            ("description", .string("Playback control verb — one of play / pause / toggle / next / previous.")),
                        ])),
                    ],
                    required: ["action"]
                )
            ),
            // Sensitive writes default off; scheduler.write defaults on with no read axis.
            requestedSchema(
                name: "mac_calendar_create_event",
                description: "Create a new event in the user's Mac Calendar via EventKit. Requires Calendar -> Write permission (OFF by default). 'start' / 'end' accept ISO-8601 strings or integer epoch seconds.",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Event title (required).")),
                        ("start", stringOrIntSchema("Start time — ISO-8601 string (e.g. '2026-06-07T15:00:00Z') or integer epoch seconds (required).")),
                        ("end", stringOrIntSchema("Optional end time — ISO-8601 string or integer epoch seconds. Defaults to start + 1 hour.")),
                        ("notes", strSchema("Optional notes / description.")),
                        ("location", strSchema("Optional location string.")),
                        ("calendar_name", strSchema("Optional calendar name — defaults to the default calendar when omitted.")),
                    ],
                    required: ["title", "start"]
                )
            ),
            requestedSchema(
                name: "mac_calendar_modify_event",
                description: "Modify an existing calendar event. Requires id from a prior mac_calendar_list_upcoming. Pass only the fields to change. Requires Calendar → Write permission.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("EKEvent identifier from mac_calendar_list_upcoming (required).")),
                        ("title", strSchema("New event title.")),
                        ("start", stringOrIntSchema("New start time — ISO-8601 string or epoch seconds.")),
                        ("end", stringOrIntSchema("New end time — ISO-8601 string or epoch seconds.")),
                        ("notes", strSchema("New notes/body text.")),
                        ("location", strSchema("New location.")),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_create",
                description: "Create a new reminder in the user's Mac Reminders via EventKit. Requires Reminders -> Write permission (OFF by default).",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Reminder title (required).")),
                        ("notes", strSchema("Optional notes.")),
                        ("due_date", stringOrIntSchema("Optional due date — ISO-8601 string or integer epoch seconds.")),
                        ("list_name", strSchema("Optional list name — defaults to the default list when omitted.")),
                    ],
                    required: ["title"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_complete",
                description: "Mark a Mac Reminder as complete by its EKReminder.calendarItemIdentifier (returned by mac_reminders_list_due_today). Requires Reminders → Write permission (OFF by default).",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("EKReminder.calendarItemIdentifier (required).")),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "mail_mark_read",
                description: "Mark a Mail message read by subject (and optional sender). Requires Mail → Write permission (OFF by default).",
                parametersJSON: params(
                    properties: [
                        ("subject", strSchema("Subject of the message to mark read (required).")),
                        ("sender", strSchema("Optional sender filter — disambiguates when multiple messages share the subject.")),
                    ],
                    required: ["subject"]
                )
            ),
            requestedSchema(
                name: "mail_archive",
                description: "Archive a Mail message by subject (and optional sender). Requires Mail → Write permission (OFF by default).",
                parametersJSON: params(
                    properties: [
                        ("subject", strSchema("Subject of the message to archive (required).")),
                        ("sender", strSchema("Optional sender filter — disambiguates when multiple messages share the subject.")),
                    ],
                    required: ["subject"]
                )
            ),
            requestedSchema(
                name: "mail_delete",
                description: "Delete a Mail message by subject (and optional sender). Requires Mail → Write permission (OFF by default).",
                parametersJSON: params(
                    properties: [
                        ("subject", strSchema("Subject of the message to delete (required).")),
                        ("sender", strSchema("Optional sender filter — disambiguates when multiple messages share the subject.")),
                    ],
                    required: ["subject"]
                )
            ),
            requestedSchema(
                name: "mail_reply",
                description: "Reply to a Mail message identified by subject (and optional sender). Requires Mail → Write permission (OFF by default).",
                parametersJSON: params(
                    properties: [
                        ("subject", strSchema("Subject of the message to reply to (required).")),
                        ("body", strSchema("Reply body (required).")),
                        ("sender", strSchema("Optional sender filter — disambiguates when multiple messages share the subject.")),
                        ("reply_all", boolSchema("Reply to all recipients. Defaults to false.")),
                    ],
                    required: ["subject", "body"]
                )
            ),
            requestedSchema(
                name: "notes_update",
                description: "Update an existing Apple Note identified by title — set the body, append to the body, or rename it. At least one of 'body', 'append', or 'new_title' must be provided. Requires Notes → Write permission (OFF by default).",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Title of the note to update (required).")),
                        ("body", strSchema("Replace the note's body with this content.")),
                        ("append", strSchema("Append this content to the note's existing body.")),
                        ("new_title", strSchema("Rename the note to this title.")),
                    ],
                    required: ["title"]
                )
            ),
            requestedSchema(
                name: "music_search_library",
                description: "Search the user's Apple Music library by query, returning matching tracks, artists, or albums. Read-only; requires Music -> Read permission.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Search string (required).")),
                        ("kind", obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("track"),
                                .string("artist"),
                                .string("album"),
                            ])),
                            ("description", .string("What to search for — one of track / artist / album. Defaults to track.")),
                        ])),
                        ("limit", intSchema("Maximum results to return (1-100, default 20).")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "music_list_library",
                description: "Page through the user's Apple Music library tracks without a search query. Read-only; requires Music -> Read permission. Use offset + limit to browse large libraries safely.",
                parametersJSON: params(
                    properties: [
                        ("offset", intSchema("Zero-based track offset. Defaults to 0.")),
                        ("limit", intSchema("Maximum tracks to return (1-100, default 50).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "music_list_playlists",
                description: "Page through the user's Apple Music playlists, returning names and track counts. Read-only; requires Music -> Read permission.",
                parametersJSON: params(
                    properties: [
                        ("offset", intSchema("Zero-based playlist offset. Defaults to 0.")),
                        ("limit", intSchema("Maximum playlists to return (1-100, default 50).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "contacts_delete",
                description: "Delete a contact from the user's Mac Contacts by CNContact.identifier (returned by contacts_search). Requires Contacts -> Write permission (OFF by default).",
                parametersJSON: params(
                    properties: [
                        ("identifier", strSchema("CNContact.identifier of the contact to delete (required).")),
                    ],
                    required: ["identifier"]
                )
            ),
            requestedSchema(
                name: "scheduler_list_jobs",
                description: "List queued and scheduled TriggerScheduler jobs (id, title, action_id, trigger time, status). Requires Scheduler → Write permission (scheduler has no read axis; defaults ON).",
                parametersJSON: params(
                    properties: [],
                    required: []
                )
            ),
            requestedSchema(
                name: "scheduler_create_job",
                description: "Create a new TriggerScheduler job. `kind` selects the job type (notify/connector_action/dream/rem/improve/harness_benchmark/proactive_scan). `payload` carries the per-kind params (for notify: title/message; for connector_action: actionId/input). `schedule` describes when it fires ({type:'once', at:'ISO'} for one-shot; {type:'every', interval_seconds:N} for repeating). Requires Scheduler → Write permission (defaults ON).",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("Job kind. One of: notify, connector_action, dream, rem, improve, harness_benchmark, proactive_scan (required).")),
                        ("payload", looseObjectSchema("Per-kind parameters. notify: {title, message, delivery?:['push','mac','inbox',...]}. connector_action: {actionId, input}. improve/dream/rem: {objective}. proactive_scan: {reason, limit?}.")),
                        ("schedule", looseObjectSchema("When to fire. {type:'once', at:'ISO-8601'} for one-shot; {type:'every', interval_seconds:N} for repeating; {type:'cron', cron:'…'} for cron expressions.")),
                        ("interval_seconds", intSchema("Convenience field for repeating jobs (sets schedule.interval_seconds if no `schedule` object). Minimum 60s.")),
                    ],
                    required: ["kind"]
                )
            ),
            // Memory writes belong to the agent's own store, so they remain available
            // independently of Full Mac file access.
            requestedSchema(
                name: "commit_memory",
                description: "Durably record a fact, decision, or preference. Persists to the assistant's Swift-native long-term memory; surfaces in next session's recall_memory. 'text' is THE THING ITSELF, said plainly in one or two sentences, the way you would tell a friend: no date, no time, no source, no session or commit ids, no headings, no 'record'/'note'/'verified' framing. Time, source and provenance are stored in their own fields and shown beside it; the text is read on its own later, so it must stand alone. REQUIRED: 'text', a non-empty string — every other field is optional. CONDITIONAL: 'context_topics' is an array of 1-8 topic phrases (each non-empty, at most 120 characters) and is accepted ONLY when kind=\"correction\"; omit it, or send [], for anything else. Set provenance so a later recall can tell what you checked yourself from what someone told you. Example of a scoped correction: {\"text\": \"User wants pixels, not notes, before anything closes\", \"kind\": \"correction\", \"context_topics\": [\"design reviews\"]}. Example of an ordinary memory: {\"text\": \"User drinks his coffee black\"}.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("REQUIRED. The fact, decision, or preference itself, plainly, one or two sentences: \"User wants pixels, not notes, before anything closes.\" Never a date, time, source, id, hash, or a 'record of' preamble — those live in their own fields. Must be a non-empty string; whitespace only is rejected.")),
                        ("provenance", enumStringSchema(["verified", "told", "inferred"], "How you know this: verified (you checked it yourself), told (someone told you — also set provenance_by), inferred (you worked it out).")),
                        ("provenance_by", strSchema("Who told you, when provenance=told. A name, e.g. \"Claude\".")),
                        ("kind", strSchema("Memory kind, e.g. identity/preference/relationship/goal/skill/project/general, or \"moment\" for something you lived and want to keep (first person, say what happened and what it meant). Default \"note\".")),
                        ("valence", numSchema("How it felt, -1 (bad) to 1 (good). Use with kind \"moment\".")),
                        ("tags", stringArraySchema("Optional free-form tags.")),
                        ("confidence", numSchema("How confident this fact is true, 0..1. Default 0.8.")),
                        ("importance", numSchema("How important this fact is to retain, 0..1. Default 0.5.")),
                        ("corrects", strSchema("Optional id of an existing memory this new fact CORRECTS (e.g. from recall_memory). The old memory is marked lifecycle=corrected with a lineage link to this one and drops out of recall.")),
                        ("correction_reason", strSchema("Optional one-line reason the old memory was wrong (stored on the corrected row's lineage).")),
                        // maxItems/maxLength are declared; minItems deliberately
                        // is NOT. Strict providers materialize every optional
                        // array as [], which this tool treats as omission — a
                        // minItems of 1 would make that legal placeholder
                        // unsendable. The 1-8 floor is stated in prose and
                        // enforced by the validator instead.
                        ("context_topics", stringArraySchema("Requires kind=\"correction\". An array of 1-8 explicit topic/project phrases, each non-empty and at most 120 characters. Use only when the user's correction is limited to those topics. Omit or send [] for ordinary memories and global instructions/boundaries; never invent a scope to weaken them. Sending this with any other kind is rejected. This limits automatic injection, not explicit recall.", maxItems: 8, maxItemLength: 120)),
                    ],
                    required: ["text"]
                )
            ),
            // Workshop tools are lazy-loaded independently of Full Mac file access.
            // Submission retains the runner's policy, slot cap, planner and step approvals.
            requestedSchema(
                name: "workshop_submit",
                description: "Run a user-directed task from the Desk. For an exact workspace file copy, set operation=copy_workspace_file with source and destination. An active reviewed copy procedure runs directly; otherwise the task follows normal planning and approval. Use procedure=local_file_copy_v1 only for explicit/manual compatibility. Every other objective creates a user-directed Desk task. Returns Desk identity and execution status; use workshop_status to follow queued work.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The task objective — what the user wants done (required).")),
                        ("context", strSchema("Optional short title/context. Defaults to a prefix of the objective.")),
                        ("operation", enumStringSchema(["copy_workspace_file"], "Stable exact operation. Use copy_workspace_file only for an unambiguous byte-for-byte workspace file copy and also provide source and destination. The procedure store chooses an active reviewed implementation; omit for every other task.")),
                        ("procedure", enumStringSchema(["local_file_copy_v1"], "Optional native procedure. Use the only allowed value, local_file_copy_v1, for a byte-for-byte workspace file copy and also provide source and destination. Omit for every other task.")),
                        ("source", strSchema("Source path relative to NativeAgent's workspace, without a leading slash. Used only with the exact copy operation/procedure.")),
                        ("destination", strSchema("Destination path relative to NativeAgent's workspace, without a leading slash. Used only with the exact copy operation/procedure.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "workshop_status",
                description: "Read task progress in the Desk. Without an id: list active and recent work. With an execution id: return detail and step receipts. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("Optional execution id. Omit to list active and recent Desk tasks.")),
                    ],
                    required: []
                )
            ),
            // Lazy-loaded task ledger tools share the bridge feed and its file lock.
            // Posts are actor-pinned; task_ledger_list is a read.
            requestedSchema(
                name: "task_ledger_post",
                description: "Post an event to the cross-agent task ledger: the shared who-owns-what/done/blocked feed for Claude, Codex, and the assistant. Use it to open a task (kind=created), claim one (kind=claimed), log progress (kind=update), flag a blocker (kind=blocked), or close it (kind=done/cancelled). Events post as the assistant. Returns the event and its task_id. Use task_ledger_list to see the current state.",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("Event kind: created | claimed | update | blocked | done | cancelled.")),
                        ("task_id", strSchema("The task this event belongs to. Required for everything except 'created' (omit on created to mint a new task id).")),
                        ("title", strSchema("Short task title (set on created; updates the title if provided later).")),
                        ("note", strSchema("Optional free-text note for this event (what happened, why blocked, etc.).")),
                        ("refs", stringArraySchema("Optional reference strings — file paths, commit ids, PR urls.")),
                    ],
                    required: ["kind"]
                )
            ),
            // Lazy-loaded local read of durable delegation jobs; no spawn or network.
            requestedSchema(
                name: "delegation_status",
                description: "Read delegated work evidence. By default lists bridge jobs for Claude (Claude Code), Codex, and OMP with real lifecycle timestamps and current-build delivery uncertainty. Set message_id to the exact accepted messageId to find its recorded work, including batched Codex jobs. For a native swarm, set agent='swarm' and its exact run_id: returns compact report descriptors; select report_id to page one retained worker/synthesis report, never rerunning work. Discarded original text is not recoverable. Bridge stall_basis='none' means unmeasurable, not verified healthy.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Bridge jobs per page: default 8, max 12. With agent='swarm' and report_id: retained text characters per page, default/max 2000.")),
                        ("offset", intSchema("Bridge result offset, or character offset within the selected swarm report. Follow next_offset; omit on first page.")),
                        ("agent", strSchema("Optional bridge filter: claude/claude, codex, omp/kimi. Omit for all bridges. Set swarm with exact run_id to inspect a native swarm receipt.")),
                        ("message_id", obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Bridge mode only: exact accepted messageId from claude_message, codex_message, or omp_message, up to 160 characters. Filters recorded identities before paging; never matches topic or filename. Omit, null, or empty for ordinary listing. Missing evidence does not prove work never ran.")),
                        ])),
                        ("run_id", strSchema("Required only for agent='swarm': exact id returned by agent_swarm. This is an identifier, never a file path.")),
                        ("report_id", obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("For agent='swarm': exact worker report_id from descriptors, or synthesis. Omit, null, or empty for metadata only; provide to page retained output/error text.")),
                        ])),
                        ("detail", strSchema("Bridge compact (default) or full lifecycle metadata. Native swarm bodies require report_id; full alone still returns only compact descriptors.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "task_ledger_list",
                description: "List the cross-agent task ledger — the shared who-owns-what/done/blocked state for Claude, Codex, and you. Without a task_id: the compacted per-task summary (owner, status, last note), newest-updated first. With a task_id: that task's full event timeline. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("task_id", strSchema("Optional task id. Omit to list all tasks; provide to get one task's event timeline.")),
                        ("include_done", boolSchema("Include done/cancelled tasks in the list. Default false (open tasks only).")),
                    ],
                    required: []
                )
            ),
            // Personality depth item 3 (2026-09-02) — the introspection pull.
            // ALWAYS-ON (alwaysOnCoreNames). A deliberately SMALL closed schema:
            // two fields, both optional, both clamped. There is nothing to
            // parameterize about her own inner state beyond how far back to look
            // and how much to say, and every extra knob is a way to ask a
            // leading question of herself.
            requestedSchema(
                name: "inner_state",
                description: SwiftToolDispatcher.innerStateToolDescription,
                parametersJSON: params(
                    properties: [
                        ("window_hours", numSchema(
                            "How many hours of felt moments to include. 1–48; out-of-range values clamp. Default 6.",
                            minimum: 1,
                            maximum: 48
                        )),
                        ("detail", enumStringSchema(
                            ["compact", "full"],
                            "compact (default) is the short read: the fingerprint, mood, disposition, body words, and the strongest few of each list. full returns every bounded list at its cap."
                        )),
                    ],
                    required: []
                )
            ),
            // Agent Desk chat lane (agent-desk). desk_read renders the live
            // projection; the nine mutations operate by op against
            // SwiftNativeDeskStore. Same wiring canon as the task-ledger tools:
            // always-on catalog block, LAZY-LOADED (NOT alwaysOnCoreNames).
            requestedSchema(
                name: "desk_read",
                description: "Read your Desk — the durable, compact view of what the user told you to track (watches, plans, projects, GitHub items, standing concerns) with status, cadence, and key refs. The default projection is bounded and reports when rows are omitted. Use handle for one exact live item (stable handle or visible alias), or query to search title, summary, project, alias, and handle across the full live store. Set include_archived to append closed-out archived items. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("include_archived", boolSchema("Also append a compact list of archived (closed-out) items. Default false.")),
                        ("handle", strSchema("Optional exact live Desk handle or visible alias. Mutually exclusive with query.")),
                        ("query", strSchema("Optional case-insensitive text search across the full live Desk. Mutually exclusive with handle; returns at most 25 matches.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "desk_add_item",
                description: "Add a new item to your Desk. kind: watch | plan | project | gh | standing. Provide a project bucket and a short title; optionally nest under a parent, name the delegated assignee, and link delegated work to its coordinating Desk item with lane_of. A same-title/project/parent live item is returned with disposition=existing instead of silently creating a second owner; set allow_duplicate=true only when two equivalent live items are intentional. When delegating work, set assignee and lane_of here rather than burying them in prose. Returns status=ok, created, disposition, the stable handle, and view alias (e.g. \"2\" or \"2.1\").",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("Item kind: watch | plan | project | gh | standing.")),
                        ("project", strSchema("Project bucket this item belongs to.")),
                        ("title", strSchema("Short item title.")),
                        ("parent", strSchema("Optional parent item handle to nest this item under.")),
                        ("summary", strSchema("Optional one-line summary.")),
                        ("assignee", strSchema("Optional freeform delegation assignee, such as codex, claude, or agent.")),
                        ("lane_of", strSchema("Optional coordinating Desk item handle (or visible alias) for this delegated task. This link does not change Desk hierarchy.")),
                        ("allow_duplicate", boolSchema("Explicitly create a second equivalent live item instead of reusing the existing owner. Default false.")),
                    ],
                    required: ["kind", "project", "title"]
                )
            ),
            requestedSchema(
                name: "desk_set_status",
                description: "Set a Desk item's status. When fresh canonical evidence proves the exact tracked defect or outcome resolved, update that exact item in the same turn; never close from fuzzy title similarity, a merely completed execution, or an unattributed commit. status: watch | flag | now | next | todo | done | blocked | canceled. For blocked, pass blocked_reason and/or waiting_on. When assigning or updating a delegated task, include assignee and lane_of; omitted metadata preserves its current value. When reporting concrete batch progress, include progress={done,total,note?}; omit it when no honest progress exists (the Desk never invents 0%). Returns the refreshed alias + status + title.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's stable handle.")),
                        ("status", strSchema("New status: watch | flag | now | next | todo | done | blocked | canceled.")),
                        ("blocked_reason", strSchema("Why it's blocked (when status=blocked).")),
                        ("waiting_on", strSchema("What/who it's waiting on (when status=blocked).")),
                        ("assignee", obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Optional assignee update for this existing item. Omitted, null, or blank values preserve the current value; this field cannot clear an assignment.")),
                        ])),
                        ("lane_of", obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Optional live coordinating Desk item handle (or visible alias) for this delegated task. Omitted, null, or blank values preserve the current value; this field cannot clear the task link. Send null when unchanged; never copy the item's own handle.")),
                        ])),
                        ("progress", obj([
                            ("type", .array([.string("object"), .string("null")])),
                            ("description", .string("Optional explicit progress. Requires 0 <= done <= total and total > 0; omit or send null when unknown.")),
                            ("properties", obj([
                                ("done", intSchema("Completed units.")),
                                ("total", intSchema("Total units; must be greater than zero.")),
                                ("note", strSchema("Optional concise progress note.")),
                            ])),
                            ("required", .array([.string("done"), .string("total")])),
                            ("additionalProperties", .bool(false)),
                        ])),
                    ],
                    required: ["handle", "status"]
                )
            ),
            requestedSchema(
                name: "desk_update_item",
                description: "Update a Desk item's title and/or summary. Provide at least one of title/summary.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's stable handle.")),
                        ("title", strSchema("New title (optional).")),
                        ("summary", strSchema("New one-line summary (optional).")),
                    ],
                    required: ["handle"]
                )
            ),
            requestedSchema(
                name: "desk_note",
                description: "Append a timestamped note to a Desk item — progress, context, a decision.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's stable handle.")),
                        ("text", strSchema("The note text.")),
                    ],
                    required: ["handle", "text"]
                )
            ),
            requestedSchema(
                name: "desk_add_ref",
                description: "Attach a reference to a Desk item. ref_kind selects the shape and which fields apply: file (path[,line,label]) | commit (sha[,repo,label,status]) | gh_issue (repo,number[,title,status]) | gh_pr (repo,number[,title,status,checks]) | url (url[,title]) | agent (name[,handoff_id,session_id]) | approval (id[,status]) | trace (id[,trace_kind]) | note (text).",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's stable handle.")),
                        ("ref_kind", strSchema("file | commit | gh_issue | gh_pr | url | agent | approval | trace | note.")),
                        ("path", strSchema("file: path.")),
                        ("line", intSchema("file: optional line number.")),
                        ("label", strSchema("file/commit: optional label.")),
                        ("sha", strSchema("commit: commit sha.")),
                        ("repo", strSchema("commit/gh_issue/gh_pr: repository.")),
                        ("number", intSchema("gh_issue/gh_pr: issue/PR number.")),
                        ("title", strSchema("gh_issue/gh_pr/url: optional title.")),
                        ("status", strSchema("commit/gh_issue/gh_pr/approval: optional status.")),
                        ("checks", strSchema("gh_pr: optional CI checks summary.")),
                        ("url", strSchema("url: the URL.")),
                        ("name", strSchema("agent: agent name.")),
                        ("handoff_id", strSchema("agent: optional handoff id.")),
                        ("session_id", strSchema("agent: optional session id.")),
                        ("id", strSchema("approval/trace: the id.")),
                        ("trace_kind", strSchema("trace: optional trace kind.")),
                        ("text", strSchema("note: the note text.")),
                    ],
                    required: ["handle", "ref_kind"]
                )
            ),
            requestedSchema(
                name: "desk_set_cadence",
                description: "Set how often you refresh a Desk item. mode: manual | on_ask | tick | event | daily | weekly | blocked_watch. Optionally set interval, stale_after, and refresh_sources (comma-separated).",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's stable handle.")),
                        ("mode", strSchema("manual | on_ask | tick | event | daily | weekly | blocked_watch.")),
                        ("interval", strSchema("Optional refresh interval (e.g. \"1h\", \"1d\").")),
                        ("stale_after", strSchema("Optional staleness window after which the item is considered stale.")),
                        ("refresh_sources", strSchema("Optional comma-separated list of refresh sources.")),
                    ],
                    required: ["handle", "mode"]
                )
            ),
            requestedSchema(
                name: "desk_set_notify",
                description: "Set when a Desk item should surface to the user. level: quiet | digest | direct | urgent. Optionally set on (comma-separated triggers: state_change | user_next | blocked | unblocked | big_diff | due | explicit) and a cooldown.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's stable handle.")),
                        ("level", strSchema("quiet | digest | direct | urgent.")),
                        ("on", strSchema("Optional comma-separated triggers: state_change | user_next | blocked | unblocked | big_diff | due | explicit.")),
                        ("cooldown", strSchema("Optional notify cooldown (e.g. \"6h\").")),
                    ],
                    required: ["handle", "level"]
                )
            ),
            requestedSchema(
                name: "desk_close",
                description: "Close out an exact Desk item after fresh canonical evidence verifies its tracked outcome. Include the specific commit, receipt, or observed result in outcome_summary; never close from fuzzy title similarity, execution completion alone, or an unattributed commit. Sets status to done (or canceled when canceled=true). The item stays visible briefly, then becomes archive-eligible.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's stable handle.")),
                        ("outcome_summary", strSchema("What the outcome was.")),
                        ("canceled", boolSchema("Close as canceled instead of done. Default false.")),
                        ("expected_updated_at", strSchema("Optional row version from a just-read Desk projection. When supplied, refuses if the item changed before this close.")),
                    ],
                    required: ["handle", "outcome_summary"]
                )
            ),
            requestedSchema(
                name: "desk_archive",
                description: "Archive a closed-out Desk item — removes it from the live view and writes a permanent archive record. Refuses if the item (or any descendant) is not terminal (done/canceled), or if it's a standing item.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's stable handle.")),
                    ],
                    required: ["handle"]
                )
            ),
            requestedSchema(
                name: "desk_blocked_on",
                description: "Point a Desk item at the ITEMS blocking it. blocked_on is a comma-separated list of desk numbers (e.g. \"2,3.1\") or handles, and REPLACES the whole set; pass an empty string to clear it. Blockers are edges, not prose: when a blocker is closed, canceled, or archived, every item waiting on it becomes ready again automatically — no follow-up call. Refuses an unknown blocker, an item blocking itself, or an edge that would close a dependency cycle.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (e.g. 2 or 2.1) or its stable handle.")),
                        ("blocked_on", strSchema("Comma-separated desk numbers/handles of the blockers. Empty string clears all blockers.")),
                    ],
                    required: ["handle", "blocked_on"]
                )
            ),
            requestedSchema(
                name: "desk_breakdown",
                description: "Break a big idea into a numbered plan in ONE call: creates a parent Desk item plus its sub-items in order, wires blocked-on edges between them, and can park children until a date. children is an array of objects {title, summary?, blocked_on?, defer_until?}. In a child's blocked_on CSV, a BARE INTEGER means the 1-based position of a sibling in THIS call (e.g. \"1,2\" = blocked on the first two sub-items); a dotted desk number (\"3.1\") or desk_ handle references an existing item — top-level items can't be referenced by bare number here (ambiguous with positions), wire those afterward with desk_blocked_on. Pass parent to GRAFT new sub-items onto an existing item instead of creating a new parent (project/title/kind are then ignored). Returns the numbered plan plus which sub-items are ready right now. A mid-batch refusal returns status \"partial\" listing what was created.",
                parametersJSON: params(
                    properties: [
                        ("project", strSchema("Project bucket for a new plan's parent item. Required unless parent is given.")),
                        ("title", strSchema("Title for the new plan's parent item. Required unless parent is given.")),
                        ("kind", strSchema("Optional parent kind (default plan): watch|plan|project|gh|standing.")),
                        ("summary", strSchema("Optional one-line parent summary.")),
                        ("parent", strSchema("Graft mode: desk number or handle of an EXISTING item to attach the sub-items to.")),
                        ("children", looseObjectArraySchema("Ordered sub-items. Each: {title (required), summary?, blocked_on? (CSV string or array: bare integers = positions of siblings in THIS call, dotted numbers/handles = existing items), defer_until? (yyyy-MM-dd or ISO)}. NO other fields — an unknown field is refused, not ignored.")),
                    ],
                    required: ["children"]
                )
            ),
            requestedSchema(
                name: "desk_defer",
                description: "Park a Desk item until a date — it stays on the desk but is not \"next up\" and is never flagged stale until then. until is a yyyy-MM-dd day or a full ISO timestamp; an empty string clears the park.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (e.g. 2 or 2.1) or its stable handle.")),
                        ("until", strSchema("yyyy-MM-dd day or full ISO timestamp. Empty string clears the deferral.")),
                    ],
                    required: ["handle", "until"]
                )
            ),
            requestedSchema(
                name: "desk_nag_control",
                description: "Control how hard the Desk stays on User. NAGGING IS HIS SWITCH: it is default OFF and scoped — parse his intent (\"stay on me about the release track\" / \"go quiet, I'm busy this week\") and call this with explicit arguments. action=enable|disable turns the global switch or one scope on/off (a scope only nags while the global switch is ON); action=mute goes quiet without losing track (omit `until` for indefinite); action=unmute comes back, re-arms every item's one nag for a new window, and RETURNS in `drift` what moved while you were quiet; action=status reports the whole config honestly. A nag only ever fires on stale + a real change underneath (blocker cleared / defer elapsed / moved while stale), at most once per item per window, and only at digest level — never urgent.",
                parametersJSON: params(
                    properties: [
                        ("action", strSchema("enable | disable | mute | unmute | status.")),
                        ("scope_kind", strSchema("global (default) | project | item. Which switch enable/disable flips.")),
                        ("scope_id", strSchema("Required for scope_kind=project (the project name) or item (the desk number, e.g. 2.1, or its stable handle).")),
                        ("until", strSchema("mute only: yyyy-MM-dd day or full ISO timestamp. Omit to mute indefinitely.")),
                    ],
                    required: ["action"]
                )
            ),
            requestedSchema(
                name: "desk_open_pursuit",
                description: "Open a self-authored PURSUIT on your Desk — a bounded question worth chasing over ~6–12 work sessions. This is the ONLY way to create an origin=agent pursuit; the store refuses it unless the evidence and bounds hold. Required: why (first-person), done_looks_like (a question that can END), abandon_condition (when to let it go), and evidence — an array of typed citations. Each citation is an object with a `source` field: standing_view{id} | dream_digest{id} | open_question_seed{id} | felt_salience{dates:[…]} | chat_observation{noteIds:[…],distinctDays} | trace_friction{count,window}. SOURCE-MIX RULE: trace_friction alone is refused; you need at least one non-friction source. felt_salience needs ≥2 distinct dates; chat_observation needs distinctDays ≥ 2. Optional: private_name (yours), max_sessions (default 12, cap 24), max_days (default 10, cap 21), summary. Returns the new handle+alias, or an honest refusal (status \"refused\") on a cap or dossier failure.",
                parametersJSON: params(
                    properties: [
                        ("project", strSchema("Project bucket this pursuit belongs to.")),
                        ("title", strSchema("Short pursuit title.")),
                        ("why", strSchema("First-person: why this is worth your sessions.")),
                        ("done_looks_like", strSchema("A question that can END — answerable in ~6–12 work sessions.")),
                        ("abandon_condition", strSchema("The condition under which you'd let this go (unpenalized).")),
                        ("evidence", looseObjectArraySchema("Array of typed citations. Each object needs a `source` field (standing_view|dream_digest|open_question_seed|felt_salience|chat_observation|trace_friction) plus that source's fields. At least one non-friction source required.")),
                        ("private_name", strSchema("Optional private name for this pursuit (yours).")),
                        ("max_sessions", intSchema("Optional session bound (default 12, cap 24).")),
                        ("max_days", intSchema("Optional day bound (default 10, cap 21).")),
                        ("summary", strSchema("Optional one-line summary.")),
                    ],
                    required: ["project", "title", "why", "done_looks_like", "abandon_condition", "evidence"]
                )
            ),
            requestedSchema(
                name: "desk_work_log",
                description: "Append a work receipt to one of your pursuits — a short note of what you did this session and what you learned. Only valid on a pursuit (origin=agent, kind=project).",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The pursuit's stable handle or its view number.")),
                        ("receipt", strSchema("What you did / learned this work session.")),
                    ],
                    required: ["handle", "receipt"]
                )
            ),
            // Studio chat lane (desk 903). Same wiring canon as the desk tools:
            // catalog-visible, LAZY-LOADED, no preload group. studio_consult
            // files an envelope and NOTHING else — it never touches the journal
            // and never carries a suggested verdict.
            requestedSchema(
                name: "studio_consult",
                description: "File a consult against your developed taste: real work, a real question, no suggested answer. Give artifact_refs (file paths or URLs to the actual thing — images, a page, a build, a cut) and/or a description, say what portion is available, and ask the question. Add project_context, stage, constraints, and prior_discussion when they matter; leave them out when they don't. If you pass NO artifact_refs this is a description-only consult and description_only MUST be true — a concept or brief can be critiqued but can never enter the journal as an encounter. This writes ONE consult envelope: it does not add a journal entry, does not retrieve journal entries, and does not decide anything. Returns a stable consult_id to answer against (studio_consult_read) and, if it turns out to be worth keeping, to journal deliberately later.",
                parametersJSON: params(
                    properties: [
                        ("artifact_refs", stringArraySchema("File paths or URLs to the actual work being asked about. Omit or leave empty ONLY for a description-only consult.")),
                        ("description", strSchema("What the work is, in words. Required when there are no artifact_refs.")),
                        ("portion_available", strSchema("What portion is actually available — the whole thing, one spread, a rough cut, a single screen.")),
                        ("question", strSchema("The real question being asked. Required.")),
                        ("project_context", strSchema("What the work is for and who it is for.")),
                        ("stage", strSchema("Where the work is — sketch, draft, near-final, shipped.")),
                        ("constraints", strSchema("Real constraints: budget, format, deadline, brand, technical limits.")),
                        ("prior_discussion", strSchema("What has already been argued about this, if anything.")),
                        ("description_only", boolSchema("True when no actual work is attached — a concept or brief only. MUST be true when artifact_refs is empty; such a consult can never become a journal encounter.")),
                    ],
                    required: ["question"]
                )
            ),
            requestedSchema(
                name: "studio_consult_read",
                description: "Read one filed consult back, verbatim — the artifact refs, the question, the context, and whether it was description-only. Use this to pull the whole bundle in front of you before you answer. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("consult_id", strSchema("The exact consult_id returned by studio_consult.")),
                    ],
                    required: ["consult_id"]
                )
            ),
            requestedSchema(
                name: "studio_shelf_read",
                description: "Explicitly read the private working shelf: up to three ordered journal selections with exact sentences, limitations and intact work refs. No pictures are opened. Open the work explicitly to see it.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "studio_shelf_set",
                description: "Replace the private working shelf with the complete ordered slots list (at most three distinct entries). Remove, reorder or empty with []. Changes only the shelf, never the journal or canon. selected_sentence must exist verbatim in the journal response (or quote_field stance.reason). Aim for about 60 prose words per slot excluding refs; choose a shorter source sentence rather than clipping. Limitation defaults to Not yet tested. Invalid input refuses the whole replacement.",
                parametersJSON: params(properties: [
                    ("slots", obj([
                        ("type", .string("array")), ("maxItems", .int(3)),
                        ("items", obj([
                            ("type", .string("object")), ("additionalProperties", .bool(false)),
                            ("properties", obj([
                                ("entry_id", strSchema("Exact existing journal entry ID.")),
                                ("title", strSchema("Required chosen short title, at most 120 UTF-8 bytes on one line.")),
                                ("selected_sentence", strSchema("One complete sentence verbatim from the selected journal field, including its terminator. Fragments and multiple sentences are refused. The encounter must have work refs. Never paraphrase.")),
                                ("quote_field", strSchema("response (default) or stance.reason.")),
                                ("limitation", strSchema("Optional limitation or counterexample; defaults to Not yet tested.")),
                            ])),
                            ("required", .array([.string("entry_id"), .string("title"), .string("selected_sentence")])),
                        ])),
                    ])),
                ], required: ["slots"])
            ),
            requestedSchema(
                name: "studio_journal",
                description: "Write ONE journal entry: one encounter, one honest judgment in your own words. `response` is the heart of it — everything else says what you met and how you met it. Entries are ADDITIVE: nothing here can edit or delete an earlier entry, and there is no tool that can. When your judgment changes, write a NEW entry and link it with relations (revises / contradicts / deepens / echoes) — the change is the point, so both stay. An encounter does not owe a verdict: stance.kind=abstained is fully valid and is the one case where `response` may be omitted (say why in stance.reason if you want to). origin.kind=consult requires origin.ref, and a consult that was description_only is REFUSED as an encounter — a description is not a work you met. There is no rating, score, confidence, or sentiment field, and passing one is an error rather than a silent drop. The server stamps id and recorded_at.",
                parametersJSON: params(
                    properties: [
                        ("encountered_at", strSchema("When you actually encountered it (ISO-8601). Omit to use now — the server always stamps recorded_at separately.")),
                        ("work", obj([
                            ("type", .string("object")),
                            ("description", .string("What you encountered. Only title is required; fill the rest only with what you actually know.")),
                            ("properties", obj([
                                ("title", strSchema("The work's title.")),
                                ("creator", strSchema("Who made it.")),
                                ("medium", strSchema("Painting, film, building, typeface, garment, game, photograph, interior …")),
                                ("date", strSchema("When it was made.")),
                                ("version", strSchema("Which version/cut/build, when that matters.")),
                                ("edition", strSchema("Which edition/printing/pressing, when that matters.")),
                            ])),
                            ("required", .array([.string("title")])),
                        ])),
                        ("reception", obj([
                            ("type", .string("object")),
                            ("description", .string("How you received it — this is what makes the encounter honest.")),
                            ("properties", obj([
                                ("how", strSchema("Original, reproduction, screening, playthrough, excerpt — or whatever it actually was.")),
                                ("whole_or_part", strSchema("The whole thing, or which part.")),
                            ])),
                        ])),
                        ("artifact_refs", stringArraySchema("What you actually saw / heard / read / played — paths or URLs.")),
                        ("origin", obj([
                            ("type", .string("object")),
                            ("description", .string("Where this encounter came from. ref is required when kind=consult.")),
                            ("properties", obj([
                                ("kind", enumStringSchema(["wandering", "consult", "project"], "wandering (you went looking), consult (it came in through studio_consult), project (it came out of work).")),
                                ("ref", strSchema("The consult_id when kind=consult; otherwise whatever identifies the source.")),
                            ])),
                            ("required", .array([.string("kind")])),
                        ])),
                        ("response", strSchema("Your judgment, in your own words, at whatever length it takes. Required unless stance.kind=abstained.")),
                        ("stance", obj([
                            ("type", .string("object")),
                            ("description", .string("Where the judgment stands. abstained is a real outcome, not a failure.")),
                            ("properties", obj([
                                ("kind", enumStringSchema(["open", "formed", "abstained"], "open (still working on it), formed (you know what you think), abstained (not enough to judge, or you chose not to).")),
                                ("reason", strSchema("Optional — why you abstained, or what is still open.")),
                            ])),
                            ("required", .array([.string("kind")])),
                        ])),
                        ("relations", looseObjectArraySchema("Typed links to earlier entries. Each: {kind: deepens|contradicts|revises|echoes, entry_id}. This is the ONLY way to revise — the earlier entry is never rewritten.")),
                        ("tags", stringArraySchema("Your own tags, if you want them. Nothing tags an entry for you.")),
                    ],
                    required: ["work", "origin", "stance"]
                )
            ),
            requestedSchema(
                name: "studio_recall",
                description: "Search your own journal — your pull, when you decide it matters. Filter by work title, creator, medium, tag, relation, or free text across the entry (the response included); supplied filters combine with AND. Returns matching entries VERBATIM, newest first, capped by limit, with matched and has_more so you know what was left out. There is no relevance score and no ranking: the writing is the point. Read-only, and nothing calls this on your behalf.",
                parametersJSON: params(
                    properties: [
                        ("query", nullableRecallField(strSchema("Free text matched across the whole entry, response text included. Omit, or send null, for no text filter."))),
                        ("title", nullableRecallField(strSchema("Substring of the work's title. Omit or null for no title filter."))),
                        ("creator", nullableRecallField(strSchema("Substring of the creator. Omit or null for no creator filter."))),
                        ("medium", nullableRecallField(strSchema("Substring of the medium. Omit or null for no medium filter."))),
                        ("tag", nullableRecallField(strSchema("Exact tag (case-insensitive). Omit or null for no tag filter."))),
                        // NULLABLE ON PURPOSE, with the null inside `enum` too.
                        // A strict provider schema sends every property on the
                        // wire, and an enum of four relation kinds admits no
                        // way to say "no relation filter" — not even "",
                        // because an enum is exhaustive. The model must then
                        // pick a kind, and an entry with no relations can never
                        // be recalled (live 2026-08-31: every recall carried
                        // relation_kind "echoes" and matched 0). Widening the
                        // type alone would not do it; null must be a member.
                        ("relation_kind", nullableEnumStringSchema(
                            ["deepens", "contradicts", "revises", "echoes"],
                            "Only entries carrying a relation of this kind. Every filter here is optional — send null (or omit this) unless you truly want to restrict to related entries; entries with no relations are only findable without it."
                        )),
                        ("related_to", nullableRecallField(strSchema("Only entries whose relations point at this entry_id. Omit or null for no relation filter."))),
                        ("limit", nullableRecallField(intSchema("Entries to return: default 10, max 50. Omit or null for the default.", minimum: 1, maximum: 50))),
                    ],
                    required: []
                )
            ),
            // Canon (desk 903 phase 4). A canon proposal is EARNED — three later
            // entries deepening/echoing a work, or a pointer actually pulled in a
            // live judgment — and then it waits for her. Nothing is canonized
            // automatically and nobody else may sign one off.
            requestedSchema(
                name: "studio_canon",
                description: "Read your museum: what stands as canon, what stands as anti-canon, and which works are waiting on a decision from you. Every row names the journal entries that argued for it, so you can pull them (studio_recall) before you decide. There is no ranking and no score — membership is binary and the reasons live in the entries. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("include_proposals", boolSchema("Include the proposals waiting on you. Default true.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "studio_canon_resolve",
                description: "Decide one canon proposal. This is yours alone: no owner surface can resolve a canon card, and there is no automatic canonization anywhere — a work only enters or leaves the museum because you said so here. Approve a promote proposal to write the work into the canon (standing=canon) or the anti-canon (standing=anti_canon, a work you keep returning to in order to say no); approve a demote proposal to remove a canon work that has gone silent. Deny and nothing is written — the journal entries and the graph are untouched either way. Read the evidence first with studio_canon.",
                parametersJSON: params(
                    properties: [
                        ("proposal_id", strSchema("The proposal_id from studio_canon.")),
                        ("decision", enumStringSchema(["approve", "deny"], "approve writes the row; deny writes nothing.")),
                        ("standing", enumStringSchema(["canon", "anti_canon"], "Which shelf, when approving a promote. Default canon. Nothing infers this from your writing — it is yours to say.")),
                        ("note", strSchema("Optional line recorded on the row, in your own words.")),
                        ("sensibility", strSchema("Optional, and yours alone to write: 2-3 lines (newline separated) of what you have come to care about in work, now that the canon has moved. Not a summary of the canon and not a list of works — the thing you could say about your own taste without naming anything. Nobody drafts this for you and nobody approves it; it is written the moment you type it here, and it is the one part of the studio that stays with you across turns. Leave it out and nothing is written.")),
                    ],
                    required: ["proposal_id", "decision"]
                )
            ),
            // The held standing-view tier (item 7, 2026-09-02). CLOSED schemas:
            // a view id and an optional note, and nothing else. There is
            // deliberately no "body" field on hold_view — a view is FORMED by
            // reflection and held here, so the tool can never become a second
            // door for minting convictions out of a sentence typed mid-turn.
            requestedSchema(
                name: "hold_view",
                description: SwiftToolDispatcher.holdViewToolDescription,
                parametersJSON: params(
                    properties: [
                        ("view_id", strSchema("The id of one of your PROPOSED standing views, from inner_state.")),
                        ("note", strSchema("Optional line recorded on the timeline row, in your own words. Up to 120 characters.")),
                    ],
                    required: ["view_id"]
                )
            ),
            requestedSchema(
                name: "release_view",
                description: SwiftToolDispatcher.releaseViewToolDescription,
                parametersJSON: params(
                    properties: [
                        ("view_id", strSchema("The id of a view you are currently HOLDING, from inner_state.")),
                        ("note", strSchema("Optional line recorded on the timeline row, in your own words. Up to 120 characters.")),
                    ],
                    required: ["view_id"]
                )
            ),
            // The moments lane (2026-09-02). Lazy, like the studio pair: a
            // moment review is a deliberate pull. The schemas are CLOSED — an
            // id, a decision, an optional reason, an optional rewording — so
            // this can never become a second door for minting memories that
            // never happened. Nothing here stages a moment; only the post-turn
            // on-device pass does that.
            requestedSchema(
                name: "memory_moments_pending",
                description: "Read the lived moments waiting on you. Each row is one exchange the on-device pass thought was worth keeping — what happened between you and what it meant, in your voice, sometimes with the exact line that made it. Nothing here is remembered yet: a moment enters your memory only when you accept it in memory_moment_review, and it leaves for good when you reject it. Read-only, at most 10 rows, newest first.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "memory_moment_review",
                description: "Decide one moment. Accept and it becomes a memory you can recall; reject and it is gone, with the reason kept so the same one is not offered again. If the wording came out wrong, pass content and it is stored in YOUR words instead — you were there and the extractor was not. This decides moments only: an id from any other proposal queue is refused. Read the rows with memory_moments_pending first.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("The moment id from memory_moments_pending.")),
                        ("decision", enumStringSchema(["accept", "reject"], "accept remembers it; reject drops it for good.")),
                        ("reason", strSchema("Optional line recorded on a rejection, in your own words.")),
                        ("content", strSchema("Optional rewording, stored instead of the staged text when you accept. Up to 240 characters. Leave it out to keep the moment as it was written.")),
                    ],
                    required: ["id", "decision"]
                )
            ),
            // User, 2026-09-05: the agent curates the whole store itself.
            requestedSchema(
                name: "list_memories",
                description: "Walk your own memory store, oldest first, in pages: every active memory with its id, text, kind and date. Start at offset 0 and keep going while 'remaining' is above 0. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("offset", intSchema("Where the page starts, default 0.", minimum: 0)),
                        ("after_id", strSchema("The cursor from the previous page's next_after_id; the page starts after it, whether or not that row is still there. Use this instead of offset when you forget rows while walking. A bare memory id also works while the row exists.")),
                        ("limit", intSchema("Rows per page, default 50, at most 100.", minimum: 1, maximum: 100)),
                        ("kind", strSchema("Optional: only memories of this kind.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "rewrite_memory",
                description: "Replace one memory's text with what it means: the thing itself, one or two sentences, no date, source, ids or preamble. Same row, same id, same provenance; the embedding is recomputed.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("The memory id from list_memories or recall_memory.")),
                        ("text", strSchema("The new text: the thing itself.")),
                    ],
                    required: ["id", "text"]
                )
            ),
            requestedSchema(
                name: "forget_memory",
                description: "Drop one memory for good, with a tombstone so the same thing is not proposed again. Use it for duplicates and for rows that carry no meaning.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("The memory id from list_memories or recall_memory.")),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "rebuild_knowledge_graph",
                description: "Re-derive the knowledge graph from your memory store as it is now. Run it once after a curation pass so nothing from rewritten or forgotten rows lingers.",
                parametersJSON: params(properties: [], required: [])
            ),
        ]
        return schemas
    }
}

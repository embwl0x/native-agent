import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution

// LLMToolSchema is defined canonically in NativeAgentCore.LLMClient.swift (W1).
// W2's fallback declaration was dropped at integration; this file now uses
// the canonical type directly via the `import NativeAgentCore` above.

// MARK: - MCP tools-cache warm (production trigger)

/// Owns the ONE production caller of `SwiftNativeMCPDispatcher
/// .refreshAllToolsCaches()`. `MCPToolBridge.listMCPTools` — the sole producer
/// of `mcp__<server>__<tool>` descriptors for the model — reads
/// `mcp/cache/tools.json` and never refreshes it, so after the daemon was
/// retired the cache had no writer on any non-UI path: a perfectly healthy
/// stdio server advertised zero tools and the capability was simply absent.
///
/// Two properties the chat path depends on:
/// - **Non-blocking.** `kickDetached` schedules and returns; a slow or dead
///   server can never delay a turn's tool-catalog build.
/// - **Bounded.** One sweep at a time, hard-cancelled at `sweepDeadline`, and
///   re-armed no more than once per `rearmInterval` — so a per-turn catalog
///   build cannot fan out into a subprocess storm.
actor MCPToolCatalogWarmer {
    typealias Sweep = @Sendable (URL) async -> Void

    static let shared = MCPToolCatalogWarmer()

    /// Minimum gap between sweeps. A chat turn builds the catalog repeatedly;
    /// only the first build in a window may spawn subprocesses.
    static let rearmInterval: TimeInterval = 300
    /// Hard ceiling on one sweep. A wedged server gets cancelled, not waited on.
    static let sweepDeadline: TimeInterval = 30

    private let sweep: Sweep
    private let clock: @Sendable () -> Date
    private let rearmInterval: TimeInterval
    private let sweepDeadline: TimeInterval
    private var lastStartedAt: Date?
    private var inFlight = false
    /// Test seam: sweeps that ran to completion (or were deadline-cancelled).
    private(set) var finishedSweeps = 0

    init(
        sweep: @escaping Sweep = MCPToolCatalogWarmer.liveSweep,
        clock: @escaping @Sendable () -> Date = { Date() },
        rearmInterval: TimeInterval = MCPToolCatalogWarmer.rearmInterval,
        sweepDeadline: TimeInterval = MCPToolCatalogWarmer.sweepDeadline
    ) {
        self.sweep = sweep
        self.clock = clock
        self.rearmInterval = rearmInterval
        self.sweepDeadline = sweepDeadline
    }

    static let liveSweep: Sweep = { root in
        _ = await SwiftNativeMCPDispatcher(root: root).refreshAllToolsCaches()
    }

    /// Synchronous, allocation-cheap entry point for the tool-catalog build.
    /// Returns immediately; every decision happens on the actor.
    nonisolated func kickDetached(dataRoot: URL) {
        Task.detached(priority: .utility) { [self] in
            await kickIfDue(dataRoot: dataRoot)
        }
    }

    /// True when this call actually started a sweep. False when one is already
    /// running or the re-arm window has not elapsed.
    @discardableResult
    func kickIfDue(dataRoot: URL) async -> Bool {
        guard !inFlight else { return false }
        let now = clock()
        if let last = lastStartedAt, now.timeIntervalSince(last) < rearmInterval {
            return false
        }
        lastStartedAt = now
        inFlight = true
        Task { await self.runBoundedSweep(dataRoot: dataRoot) }
        return true
    }

    private func runBoundedSweep(dataRoot: URL) async {
        let sweep = self.sweep
        let deadline = self.sweepDeadline
        // Deliberately NOT a task group: a group awaits every child before it
        // returns, so a sweep that ignores cancellation (an MCP subprocess
        // wedged inside a `tools/list` round-trip is exactly that) would pin
        // `inFlight` forever and the warmer could never refresh again. The
        // one-shot latch lets the DEADLINE release the slot whether or not the
        // sweep ever notices it was cancelled.
        let latch = OneShotLatch()
        let work = Task.detached(priority: .utility) {
            await sweep(dataRoot)
            await latch.fire()
        }
        let timer = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            await latch.fire()
        }
        await latch.wait()
        work.cancel()
        timer.cancel()
        inFlight = false
        finishedSweeps += 1
    }

    /// Test seam.
    func _testState() -> (inFlight: Bool, finished: Int, lastStartedAt: Date?) {
        (inFlight, finishedSweeps, lastStartedAt)
    }
}

/// Resumes its single waiter on the FIRST `fire()` and ignores every later one.
/// Used to race a bounded deadline against work that may never return.
private actor OneShotLatch {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
        guard !fired else { return }
        fired = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if fired { c.resume() } else { waiter = c }
        }
    }
}

// MARK: - Schema builders

extension SwiftToolDispatcher {
    /// NativeAgent's own MCP endpoint remains available to external MCP
    /// clients and the MCP UI, but advertising it back to NativeAgent's LLM
    /// duplicates native Swift tools and forces a needless self-protocol hop.
    func modelVisibleMCPTools() -> [MCPToolDescriptor] {
        // PRODUCTION TRIGGER for the MCP tools-cache refresh. `listMCPTools`
        // reads `mcp/cache/tools.json` and nothing else; before this, the only
        // callers of `refreshAllToolsCaches` were manual/UI actions, so a
        // configured stdio server with an empty cache contributed ZERO model
        // -visible tools forever with no error (gpt-5.5 NEEDS_FIX, 2026-08-02).
        // Fire-and-forget on purpose: the sweep spawns subprocesses, so it can
        // never sit in front of a chat turn. This build serves whatever is on
        // disk; the sweep stamps the cache for the next catalog build.
        MCPToolCatalogWarmer.shared.kickDetached(dataRoot: dataRoot)
        return MCPToolBridge.listMCPTools(dataRoot: dataRoot).filter {
            $0.serverId != "nativeagent-internal"
        }
    }

    func modelVisibleMCPToolNames() -> [String] {
        modelVisibleMCPTools().map(\.bridgedName)
    }

    func modelVisibleToolNames() async -> [String] {
        let all = (try? await listAvailableTools()) ?? Self.builtInToolNames
        let hidden = Set(
            MCPToolBridge.listMCPTools(dataRoot: dataRoot)
                .filter { $0.serverId == "nativeagent-internal" }
                .map(\.bridgedName)
        )
        return all.filter { !hidden.contains($0) }
    }

    func mcpToolSchemas() -> [LLMToolSchema] {
        // Permissive fallback for tools whose cache row carries no
        // inputSchema — the LLM has to guess argument names for those.
        let fallback = JSONValue.object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(true),
        ])
        let fallbackData = (try? fallback.serializedData(pretty: false)) ?? Data("{}".utf8)
        return modelVisibleMCPTools().map { tool in
            let paramsData = tool.inputSchema
                .flatMap { try? $0.serializedData(pretty: false) }
                ?? fallbackData
            return LLMToolSchema(
                name: tool.bridgedName,
                description: tool.description ?? "Call MCP tool \(tool.toolName) on server \(tool.serverId).",
                parametersJSON: paramsData
            )
        }
    }

    func builtInToolSchemas(
        includeFullMacFileTools: Bool = false,
        includeFullMacSystemTools: Bool = false,
        includeFullMacAppTools: Bool = false,
        requestedNames: Set<String>? = nil
    ) -> [LLMToolSchema] {
        func requestedSchema(
            name: String,
            description: @autoclosure () -> String,
            parametersJSON: @autoclosure () -> Data
        ) -> LLMToolSchema? {
            guard requestedNames?.contains(name) != false else { return nil }
            return LLMToolSchema(
                name: name,
                description: description(),
                parametersJSON: parametersJSON()
            )
        }

        func obj(_ pairs: [(String, JSONValue)]) -> JSONValue {
            var d: [String: JSONValue] = [:]
            for (k, v) in pairs { d[k] = v }
            return .object(d)
        }
        func strSchema(_ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [("type", .string("string"))]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        func enumStringSchema(_ values: [String], _ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [
                ("type", .string("string")),
                ("enum", .array(values.map(JSONValue.string))),
            ]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        func intSchema(_ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [("type", .string("integer"))]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        func boolSchema(_ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [("type", .string("boolean"))]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        func numSchema(_ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [("type", .string("number"))]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        func stringArraySchema(_ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [
                ("type", .string("array")),
                ("items", obj([("type", .string("string"))])),
            ]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        // gpt-5.5 review NEEDS_FIX (Phase 2): mail_send / mobile_notify etc.
        // accept string OR array of strings. Schema must declare both shapes
        // so providers don't reject string forms at validation time.
        func stringOrStringArraySchema(_ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [
                ("anyOf", .array([
                    obj([("type", .string("string"))]),
                    obj([
                        ("type", .string("array")),
                        ("items", obj([("type", .string("string"))])),
                    ]),
                ])),
            ]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        // Phase 3 (2026-06-07): calendar/reminders create accept ISO-8601 STRING
        // or epoch INT for start/end/due_date. Same anyOf shape as
        // stringOrStringArraySchema so providers don't reject either form at
        // validation time.
        func stringOrIntSchema(_ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [
                ("anyOf", .array([
                    obj([("type", .string("string"))]),
                    obj([("type", .string("integer"))]),
                ])),
            ]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        func looseObjectSchema(_ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [
                ("type", .string("object")),
                ("additionalProperties", .bool(true)),
            ]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        func looseObjectArraySchema(_ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [
                ("type", .string("array")),
                ("items", obj([
                    ("type", .string("object")),
                    ("additionalProperties", .bool(true)),
                ])),
            ]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        // Canonical LLMToolSchema (W1, NativeAgentCore) carries the JSON Schema
        // as already-encoded Data (`parametersJSON: Data`). Build the schema as
        // a JSONValue here (ergonomic), then serialize once per tool.
        func params(properties: [(String, JSONValue)], required: [String]) -> Data {
            let v = obj([
                ("type", .string("object")),
                ("properties", obj(properties)),
                ("required", .array(required.map { .string($0) })),
            ])
            // serializedData throws only on un-serializable JSONValue payloads;
            // ours are plain string/array/object literals, so this never throws
            // in practice. Fail-soft to `{}` to avoid crashing the chat turn.
            return (try? v.serializedData(pretty: false)) ?? Data("{}".utf8)
        }

        var schemas: [LLMToolSchema?] = [
            requestedSchema(
                name: "read_file",
                description: "Read a workspace or user-approved file and return its contents as a string. On public/app-only installs, relative paths resolve inside NativeAgent's canonical workspace; use get_persona_doc or persona_read for persona documents rather than guessing their filesystem path. A verified development checkout also accepts repo-relative paths. With Trust Center Full Mac file access active, absolute Mac paths are accepted except NativeAgent trust/secrets/provider paths; /documents/... is treated as the current macOS user's ~/Documents/.... Long handoff markdown files default to a compact leading window unless max_bytes is explicit.",
                parametersJSON: params(
                    properties: [
                        ("path", strSchema("Workspace-relative path such as 'project/file.txt', a repo-relative path only when a verified source checkout exists, or an absolute/~/ path under a Trust Center workspace root. Persona files must use get_persona_doc or persona_read. In Full Mac mode, /documents/<name> maps to the current user's ~/Documents/<name>.")),
                        ("max_bytes", intSchema("Optional byte window. Omit for the safe default; set explicitly only when a larger read is needed.")),
                    ],
                    required: ["path"]
                )
            ),
            requestedSchema(
                name: "context_expand",
                description: "Read one deeper context section offered for this turn. The atom id must come from the current context pointer list; expansion is read-only and pinned to this turn's immutable generation.",
                parametersJSON: params(
                    properties: [
                        ("atom_id", strSchema("Atom id from the current turn's offered context pointers.")),
                        ("max_characters", intSchema("Optional bounded character limit.")),
                    ],
                    required: ["atom_id"]
                )
            ),
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
                description: "Search the assistant's long-term memory for relevant facts about the user or prior conversation context. Returns clean fact text with scores and memory ids; storage timestamps stay internal unless the fact itself is date-critical.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema()),
                        ("k", intSchema("max results, default 5")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "recall_search",
                description: "Compatibility alias for recall_memory. Search the assistant's Swift-native long-term memory for relevant clean facts.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema()),
                        ("k", intSchema("max results, default 5")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "search_kg",
                description: "Search the assistant's knowledge graph for entities matching the query text. Returns up to limit entity summaries.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema()),
                        ("limit", intSchema("max results, default 10")),
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
                        ("scope", strSchema("Search scope: auto/current_session_first (default), current_session, or all_sessions.")),
                        ("role", strSchema("Optional role filter: user, assistant, tool, or system.")),
                        ("mode", strSchema("Search mode: hybrid (default) token/phrase match, or exact for exact substring only.")),
                        ("limit", intSchema("max results, default 8, capped at 25")),
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
                        ("scope", strSchema("Search scope: auto/current_session_first (default), current_session, or all_sessions.")),
                        ("role", strSchema("Optional role filter: user, assistant, tool, or system.")),
                        ("mode", strSchema("Search mode: hybrid (default) or exact.")),
                        ("limit", intSchema("max results, default 8, capped at 25")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "get_persona_doc",
                description: "Read one of your canonical persona documents — SOUL.md, USER.md, AGENTS.md, VOICE.md, GROWTH.md, MEMORY.md. These are the same docs PersonaCompiler bakes into your system prompt every turn; this tool just lets you re-read the FULL text of one of them on demand.",
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
                description: "Replace one of your own persona documents through the Swift persona writer. USER.md is read-only here because MemoryV2 regenerates it from memory SQLite; use commit_memory for durable user facts.",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("One of: soul, voice, growth, agents, skill. Do not use user; USER.md is generated by MemoryV2.")),
                        ("content", strSchema("Full replacement document content.")),
                        ("skill_name", strSchema("Required only when kind='skill'.")),
                    ],
                    required: ["kind", "content"]
                )
            ),
            requestedSchema(
                name: "persona_append_section",
                description: "Append a titled markdown section to one of your own persona documents through the Swift persona writer. USER.md is read-only here because MemoryV2 owns it; use commit_memory for durable user facts.",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("One of: soul, voice, growth, agents. Do not use user; USER.md is generated by MemoryV2.")),
                        ("title", strSchema("Markdown section title. Do not include the leading ##.")),
                        ("content", strSchema("Section body to append.")),
                    ],
                    required: ["kind", "title", "content"]
                )
            ),
            requestedSchema(
                name: "agent_introspect",
                description: "Return the live Swift-native agent runtime status, active tool names, persona/data roots, and MCP bridge count. Use this to verify tool dispatch is actually working.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "daemon_introspect",
                description: "Compatibility alias for agent_introspect. It is backed by the Swift runtime; no external runtime is used.",
                parametersJSON: params(properties: [], required: [])
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
                description: "Load exact tool schemas for this tool-loop turn by category or name. Resident routing preloads high-confidence groups before the first model call; use this fallback only when the needed tool was not already supplied.",
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
                description: "Generate image files from a text prompt. Defaults to Codex/ChatGPT OAuth and the Responses image_generation tool, with no OPENAI_API_KEY required. Lazy-load this for art, illustration, design, poster, logo, mockup, or image-generation requests. Requires Trust Center multimodalPolicy.image_generation_openai=true. Saves images under data/generated_images/ and returns file paths plus a receipt. Optional provider='codex_cli' uses the older CLI artifact collector for diagnostics; provider='openai_api' uses the OpenAI platform API fallback.",
                parametersJSON: params(
                    properties: [
                        ("prompt", strSchema("Text prompt describing the image to generate.")),
                        ("provider", strSchema("Optional backend: codex (default, subscription-backed through Codex/ChatGPT OAuth), codex_cli (diagnostic CLI artifact collector), or openai_api (platform API fallback).")),
                        ("model", strSchema("Optional image model/tier. For codex, gpt-image-2-low/medium/high maps to quality. For openai_api, defaults to gpt-image-2.")),
                        ("size", strSchema("Optional output size, such as 1024x1024, 1024x1536, 1536x1024, or another model-supported size.")),
                        ("quality", strSchema("Optional quality, such as low, medium, high, or auto.")),
                        ("output_format", strSchema("Optional image format: png, jpeg, or webp. Codex OAuth currently saves png; OpenAI API fallback honors this when supported.")),
                        ("n", intSchema("Optional number of images to generate. Defaults to 1, capped at 4.")),
                        ("timeout_seconds", intSchema("Optional timeout for the Codex backend. Defaults to 600 seconds, capped at 1800.")),
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
                description: "Create or update one reusable skill through NativeAgent's canonical skill owner. Use only for an explicit user request or a proven repeatable procedure—not facts (use commit_memory). Never write or inspect skills/registry.json or skill body paths yourself. Skills are guidance only and cannot grant tools, permissions, approval bypasses, or safety authority.",
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
                description: "Search the Swift feature-surface operating map for relevant NativeAgent capabilities. Supports type='lookup_feature_surface' / 'feature_surface' / 'features'.",
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
                        ("digestBudgetTokens", intSchema("Optional soft token budget for the synthesis digest relayed back. When set, the digest is truncated to ~this many tokens with an explicit notice. Omit (default) for no extra truncation. Use a small budget (e.g. 500-2000) for tight orchestrator integration.")),
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
            // ── X (Twitter) — the user's connected account, read-only from chat ──
            // 2026-06-07: surfaced the user's existing X OAuth (`<dataRoot>/connectors/x/`)
            // as callable chat tools. Posting/DM is intentionally NOT in the chat
            // catalog — those go through the Activity-approval UI via
            // NativeClient.runConnectorAction("x.post_tweet") so the user sees + approves
            // every outbound. Agent uses these to READ his timeline/profile/search.
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
                        ("max", intSchema("Maximum tweets to return (1-100, default 10).")),
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
                        ("max", intSchema("Maximum tweets to return (1-100, default 10).")),
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
            // Slack — connected workspace actions. These are lazy-loaded by
            // tool_load(category:"slack") or Slack vocabulary. the user explicitly
            // Slack reads are direct; posting persists a bounded approval request.
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
            // ── Phase 2 (2026-06-07) — Contacts + Mail + Messages + Notes + Music ──
            // Backends: Contacts via CNContactStore (W1), the other four via
            // AppleScript (W2). Each tool is gated by MacIntegrationPermissionStore;
            // the sensitive writes (mail send / messages send / notes create /
            // contacts create-or-update) default to OFF and require the user to flip
            // the toggle in Settings → Mac Integration.
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
                        ("folder", strSchema("Optional folder name; created in the default folder when omitted.")),
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
                description: "Send a message to Claude (Claude Code CLI running locally) AND wake her to work on it now. The message is durably queued in the bridge inbox at ~/.config/claude-bridge/claude-inbox.jsonl, then a headless Claude Code session is started with it as the turn input — no human keystroke required. Claude's final reply comes back to you asynchronously (minutes, not seconds) as a '[claude-wake] Automated completion event' bridge message. That completion is a RECEIPT, not a conversational turn: do not auto-send another claude_message in response to it unless you have genuinely new work for her. Repeated wakes on the same topic are rate-limited, and the message stays in the durable inbox even when a wake is suppressed.",
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
                        ("topic", strSchema("Optional short topic tag (e.g. 'bug-music-tcc', 'review-needed') so Claude can group related messages.")),
                        ("timeout_seconds", intSchema("Optional wall-clock budget for Claude's spawned session, clamped 60-3600. Default 900. Build-sized work orders (multi-file Swift changes, test suites) MUST pass a larger value: 900s has killed real sessions mid-build.")),
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
                            ("enum", .array([
                                .string("gpt-5.6-sol"),
                                .string("gpt-5.6-terra"),
                                .string("gpt-5.6-luna"),
                            ])),
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
                            ("description", .string("Optional per-call Codex thinking level. Sol/Terra support Low through Ultra; Luna supports Low through Max. Omit to inherit the Codex default.")),
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
                description: "Send an asynchronous note/task to Codex. The message lands in the NativeAgent Codex bridge inbox, NativeAgent attempts a local Mac notification, starts or queues a Codex app-server wakeup turn, and watches that turn so Codex's final answer is delivered back through the local bridge. Use for status, questions, or larger Codex work where the assistant can continue the exchange by sending another codex_message.",
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
                        ("topic", strSchema("Optional short topic tag, e.g. 'nativeagent-build' or 'review-needed'.")),
                        ("model", obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("gpt-5.6-sol"),
                                .string("gpt-5.6-terra"),
                                .string("gpt-5.6-luna"),
                            ])),
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
                            ("description", .string("Optional thinking level for this task. Sol/Terra support Low through Ultra; Luna supports Low through Max.")),
                        ])),
                        ("fast", boolSchema("Optional Fast mode for this task. true selects Codex priority service; false selects default service.")),
                        ("repository", strSchema("Optional GitHub repository as 'owner/name' (never a filesystem path) when this task is work on a local checkout. NativeAgent resolves it to a local clone whose git remote actually points at that repository and runs Codex there with repository network access. Omit for ordinary messages; an unknown repository is ignored rather than failing the send.")),
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
            // ── Phase 3 (2026-06-07) — complete read+write coverage on every
            // Mac Integration toggle. EventKit writes + Mail manage + Notes
            // update + Music library read + Contacts delete + Scheduler list
            // and create. Sensitive writes default OFF in MacIntegrationPermissionStore;
            // scheduler.write defaults ON (no read axis on scheduler).
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
            // commit_memory — Agent's memory WRITE path. Daemon parity:
            // always_on + AUTO. This is
            // the persona's OWN long-term memory, not a Mac file op, so it lives
            // in the always-on block, NOT the includeFullMacFileTools-gated
            // block. The write path died in the Python→Swift chat cutover
            // (~2026-05-17); recall_memory was ported but commit_memory never
            // was, leaving the model unable to durably record anything for 3+
            // weeks. Routes to SwiftNativeMemoryV2.shared.store(...).
            requestedSchema(
                name: "commit_memory",
                description: "Durably record a fact, decision, or preference. Persists to the assistant's Swift-native long-term memory; surfaces in next session's recall_memory.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The fact, decision, or preference to remember (required).")),
                        ("kind", strSchema("Memory kind, e.g. identity/preference/relationship/goal/skill/project/general. Default \"note\".")),
                        ("tags", stringArraySchema("Optional free-form tags.")),
                        ("confidence", numSchema("How confident this fact is true, 0..1. Default 0.8.")),
                        ("importance", numSchema("How important this fact is to retain, 0..1. Default 0.5.")),
                        // R13: first-class correction lineage.
                        ("corrects", strSchema("Optional id of an existing memory this new fact CORRECTS (e.g. from recall_memory). The old memory is marked lifecycle=corrected with a lineage link to this one and drops out of recall.")),
                        ("correction_reason", strSchema("Optional one-line reason the old memory was wrong (stored on the corrected row's lineage).")),
                    ],
                    required: ["text"]
                )
            ),
            // workshop_submit / workshop_status — Agent's mission chat lane (U5
            // W-I). She could neither submit nor check a mission from chat
            // (zero mission_* hits anywhere in ChatOrchestration; her own
            // honest refusal caught it). These are STANDARD tools — no Process
            // spawn — so they live in the always-on catalog block, NOT the
            // includeFullMacFileTools-gated block. They are NOT every-turn-hot
            // (a user submits/checks a mission occasionally), so they are
            // LAZY-LOADED: catalog-visible + in builtInToolNames, but NOT in
            // alwaysOnCoreNames — the same classification as
            // scheduler_create_job. workshop_submit is a THIN SHIM into the
            // existing SwiftNativeWorkshopRunner.submit path: the executor's own
            // missionPolicy gate, slot cap, planner, and per-step approval
            // gates all apply DOWNSTREAM (the tool adds NO new policy).
            // Workshop-owned replacements. Kept beside the legacy aliases for
            // one shadow wave so both names dispatch the exact same Desk-first
            // implementation before mission_* is removed.
            requestedSchema(
                name: "workshop_submit",
                description: "Exact workspace byte copy: set operation=copy_workspace_file with source and destination. When the locally reviewed deterministic procedure is active, Workshop skips its planner; otherwise it falls back before admission. Use procedure=local_file_copy_v1 only for explicit/manual compatibility. Every other objective creates a user-directed Workshop task. Returns Desk and execution status; use workshop_status to follow queued work.",
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
                description: "Read Workshop task execution status. Without an id: list active and recent work. With an execution id: return detail and step receipts. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("Optional compatibility execution id. Omit to list active and recent Workshop tasks.")),
                    ],
                    required: []
                )
            ),
            // task_ledger_post / task_ledger_list (U6, 2026-06-11): the
            // cross-agent task ledger — shared who-owns-what / done / blocked
            // state for Claude / Agent / Codex. Same wiring canon as the
            // mission tools: always-on catalog block, LAZY-LOADED (NOT
            // alwaysOnCoreNames). task_ledger_post is a medium WRITE (appends
            // an event under the shared flock; bridge-allowed as of 2026-06-13,
            // actor-pinned to `agent`); task_ledger_list is a read. Claude/Codex
            // write the SAME feed via script/task_ledger.sh -> Swift task-ledger.
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
            // Agent Desk chat lane (agent-desk). desk_read renders the live
            // projection; the nine mutations operate by op against
            // SwiftNativeDeskStore. Same wiring canon as the task-ledger tools:
            // always-on catalog block, LAZY-LOADED (NOT alwaysOnCoreNames).
            requestedSchema(
                name: "desk_read",
                description: "Read your Desk — the durable, compact view of everything the user told you to track (watches, plans, projects, GitHub items, standing concerns) with their status, cadence, and key refs. Returns the rendered projection text. Set include_archived to also list closed-out archived items. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("include_archived", boolSchema("Also append a compact list of archived (closed-out) items. Default false.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "desk_add_item",
                description: "Add a new item to your Desk. kind: watch | plan | project | gh | standing. Provide a project bucket and a short title; optionally nest under a parent (its handle) and add a one-line summary. Returns the new stable handle and its view alias (e.g. \"2\" or \"2.1\").",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("Item kind: watch | plan | project | gh | standing.")),
                        ("project", strSchema("Project bucket this item belongs to.")),
                        ("title", strSchema("Short item title.")),
                        ("parent", strSchema("Optional parent item handle to nest this item under.")),
                        ("summary", strSchema("Optional one-line summary.")),
                    ],
                    required: ["kind", "project", "title"]
                )
            ),
            requestedSchema(
                name: "desk_set_status",
                description: "Set a Desk item's status. status: watch | flag | now | next | todo | done | blocked | canceled. For blocked, pass blocked_reason and/or waiting_on. Returns the refreshed alias + status + title.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's stable handle.")),
                        ("status", strSchema("New status: watch | flag | now | next | todo | done | blocked | canceled.")),
                        ("blocked_reason", strSchema("Why it's blocked (when status=blocked).")),
                        ("waiting_on", strSchema("What/who it's waiting on (when status=blocked).")),
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
                description: "Close out a Desk item with an outcome summary. Sets status to done (or canceled when canceled=true). The item stays visible briefly, then becomes archive-eligible.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's stable handle.")),
                        ("outcome_summary", strSchema("What the outcome was.")),
                        ("canceled", boolSchema("Close as canceled instead of done. Default false.")),
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
                description: "Break a big idea into a numbered campaign in ONE call: creates a parent Desk item plus its sub-items in order, wires blocked-on edges between them, and can park children until a date. children is an array of objects {title, summary?, blocked_on?, defer_until?}. In a child's blocked_on CSV, a BARE INTEGER means the 1-based position of a sibling in THIS call (e.g. \"1,2\" = blocked on the first two sub-items); a dotted desk number (\"3.1\") or desk_ handle references an existing item — top-level items can't be referenced by bare number here (ambiguous with positions), wire those afterward with desk_blocked_on. Pass parent to GRAFT new sub-items onto an existing item instead of creating a new parent (project/title/kind are then ignored). Returns the numbered plan plus which sub-items are ready right now. A mid-batch refusal returns status \"partial\" listing what was created.",
                parametersJSON: params(
                    properties: [
                        ("project", strSchema("Project bucket for a NEW campaign parent. Required unless parent is given.")),
                        ("title", strSchema("Title for the NEW campaign parent. Required unless parent is given.")),
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
        ]
        if includeFullMacFileTools {
            schemas.append(contentsOf: [
                requestedSchema(
                    name: "file_excerpt",
                    description: "Read a line-numbered excerpt from a file on the Mac filesystem. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("path", strSchema("Absolute path or path relative to the NativeAgent repo root.")),
                            ("start_line", intSchema("1-based start line, default 1.")),
                            ("max_lines", intSchema("Maximum lines, default 80, capped at 240.")),
                        ],
                        required: ["path"]
                    )
                ),
                requestedSchema(
                    name: "grep",
                    description: "Search files with rg or grep through the Swift dispatcher. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("pattern", strSchema("Regex/search pattern.")),
                            ("path", strSchema("Directory or file to search. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("max_results", intSchema("Maximum result lines, default/cap 50.")),
                        ],
                        required: ["pattern"]
                    )
                ),
                requestedSchema(
                    name: "git_status",
                    description: "Run git status --short --branch in a repository through the Swift dispatcher and return branch, ahead/behind, clean, staged, unstaged, and untracked metadata. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [("cwd", strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace."))],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "git_diff",
                    description: "Read a git diff through the Swift dispatcher. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("cwd", strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("staged", boolSchema("Use --staged.")),
                            ("path", strSchema("Optional path filter.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "git_log",
                    description: "Read recent git commits through the Swift dispatcher. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("cwd", strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("limit", intSchema("Commit count, default 10, capped at 100.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "repo_dirty_summary",
                    description: "Summarize branch, dirty files, and recent commits through the Swift dispatcher. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("cwd", strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("log_limit", intSchema("Recent commit count, default 5, capped at 20.")),
                        ],
                        required: []
                    )
                ),
                // Builder tools (2026-06-08 agent-builder-tools) — Process-
                // based CLI execution. Catalogued ONLY when Trust Center
                // Full Mac file access is active; cataloguing them
                // unconditionally would advertise capability the dispatcher
                // would then deny, confusing the model. Trust Center
                // file_ops_allowed REQUIRED upstream; default autonomy is
                // `confirm` so every call queues an approval. Audit trail
                // at data/builder_audit/<uuid>.json. On the claude/codex
                // bridge (the user 2026-06-13, "open the bridges") these are
                // available, yolo-gated exactly like local chat; only the
                // external `mcp__*` namespace stays bridge-denied.
                requestedSchema(
                    name: "shell",
                    description: "Run a shell command via /bin/sh -c. Captures stdout/stderr/exit_code. Requires Trust Center Full Mac file_ops_allowed; queues an approval request unless toolAutonomy=auto for 'shell'. Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical <dataRoot>/workspace used by public installs. Default timeout: 120s, max 600s. Use bash tool instead if you need bash-specific syntax (arrays, [[, process substitution). For checks, do not append `| tail; echo EXIT...` because that can mask the real failing exit code.",
                    parametersJSON: params(
                        properties: [
                            ("cmd", strSchema("Required. The shell command line. Passed as -c argument to /bin/sh.")),
                            ("cwd", strSchema("Optional working directory. Must resolve inside the canonical NativeAgent workspace or a verified NativeAgent source checkout.")),
                            ("timeout_seconds", intSchema("Optional. Default 120, max 600. Subprocess group gets SIGTERM then SIGKILL after 2s.")),
                        ],
                        required: ["cmd"]
                    )
                ),
                requestedSchema(
                    name: "bash",
                    description: "Run a shell command via /bin/bash -c (not sh). Same shape as shell. Use this when the command needs bash features: arrays, [[ ]] tests, process substitution, $'...' ANSI-C quoting, etc. For checks, do not append `| tail; echo EXIT...` because that can mask the real failing exit code.",
                    parametersJSON: params(
                        properties: [
                            ("cmd", strSchema("Required. The bash command line. Passed as -c argument to /bin/bash.")),
                            ("cwd", strSchema("Optional working directory. Must resolve inside the canonical NativeAgent workspace or a verified NativeAgent source checkout.")),
                            ("timeout_seconds", intSchema("Optional. Default 120, max 600.")),
                        ],
                        required: ["cmd"]
                    )
                ),
                requestedSchema(
                    name: "git",
                    description: "Run git with explicit args. Equivalent to `git <args>`. Returns stdout/stderr/exit_code. Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace. Default timeout 60s. Use for status, diff, log, blame, show, etc. Args may be an array (preferred) or a shell-style string for forgiving model calls. Mutating ops remain autonomy-gated.",
                    parametersJSON: params(
                        properties: [
                            ("args", stringOrStringArraySchema("Required. Full argv to pass to git. Prefer ['status'], ['log','--oneline','-5'], ['diff','HEAD~1','HEAD']; a string like 'status --short' is also accepted.")),
                            ("cwd", strSchema("Optional working directory inside the canonical NativeAgent workspace or a verified NativeAgent source checkout.")),
                            ("timeout_seconds", intSchema("Optional. Default 60, max 600.")),
                        ],
                        required: ["args"]
                    )
                ),
                requestedSchema(
                    name: "apply_patch",
                    description: "Apply a unified diff patch via `git apply` (3-way merge by default). Writes the patch payload to a tmpfile then runs git apply against it. Returns exit_code + stderr (which contains conflict info on failure). Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.",
                    parametersJSON: params(
                        properties: [
                            ("patch", strSchema("Required. The unified diff text. Will be written to a tmpfile before git apply.")),
                            ("cwd", strSchema("Optional working directory inside the canonical NativeAgent workspace or a verified NativeAgent source checkout.")),
                            ("three_way", boolSchema("Optional. Default true (passes --3way to git apply). Set false for strict apply that fails fast on context mismatch.")),
                        ],
                        required: ["patch"]
                    )
                ),
                requestedSchema(
                    name: "run_tests",
                    description: "Run the NativeAgent test suite via `bash script/test.sh`. Captures full stdout/stderr/exit_code. Default timeout 600s. Always anchored at the NativeAgent repo root — no cwd parameter. Use after a code change to confirm nothing regressed before asking for commit. Scope param reserved for future per-subsystem targeting; currently runs the full suite.",
                    parametersJSON: params(
                        properties: [
                            ("scope", strSchema("Optional. Reserved — currently ignored, runs the full test.sh. Future: 'unit', 'smoke', 'integration'.")),
                            ("timeout_seconds", intSchema("Optional. Default 600, max 3600.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "swift_build",
                    description: "Run fixed-argv SwiftPM build INSIDE NativeAgent's outer sandbox-exec wrapper (workspace-confined). Command shape is `swift build --disable-sandbox --package-path <package_path> --configuration <debug|release>` plus optional product/target/jobs. Requires Trust Center Full Mac file_ops_allowed and follows builder-tool autonomy/audit rules. Use when you want the audited fixed-argv path; `bash`/`shell` SwiftPM builds are also confined and work.",
                    parametersJSON: params(
                        properties: [
                            ("package_path", strSchema("Optional Swift package directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical workspace; it must remain inside one of those roots.")),
                            ("configuration", strSchema("Optional. debug or release. Defaults to debug.")),
                            ("product", strSchema("Optional product name to build. Mutually exclusive with target.")),
                            ("target", strSchema("Optional target name to build. Mutually exclusive with product.")),
                            ("jobs", intSchema("Optional SwiftPM --jobs value, clamped 1...64.")),
                            ("timeout_seconds", intSchema("Optional. Default 600, max 3600.")),
                            ("disable_swiftpm_sandbox", boolSchema("Optional. Defaults true so SwiftPM does not invoke its own sandbox-exec inside our outer wrapper (profiles cannot nest). Leave it true; setting it false makes the build fail at manifest compile.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "swift_test",
                    description: "Run fixed-argv SwiftPM tests INSIDE NativeAgent's outer sandbox-exec wrapper (workspace-confined). Command shape is `swift test --disable-sandbox --package-path <package_path> --configuration <debug|release>` plus optional filter/jobs. Requires Trust Center Full Mac file_ops_allowed and follows builder-tool autonomy/audit rules.",
                    parametersJSON: params(
                        properties: [
                            ("package_path", strSchema("Optional Swift package directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical workspace; it must remain inside one of those roots.")),
                            ("configuration", strSchema("Optional. debug or release. Defaults to debug.")),
                            ("filter", strSchema("Optional SwiftPM --filter regex/specifier.")),
                            ("jobs", intSchema("Optional SwiftPM --jobs value, clamped 1...64.")),
                            ("timeout_seconds", intSchema("Optional. Default 900, max 3600.")),
                            ("disable_swiftpm_sandbox", boolSchema("Optional. Defaults true so SwiftPM does not invoke its own sandbox-exec inside our outer wrapper (profiles cannot nest). Leave it true; setting it false makes the build fail at manifest compile.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "install_app",
                    description: "Canonical NativeAgent app install after Swift source changes. Schedules `script/install_app.sh` outside NativeAgent's outer sandbox, after a short grace delay, so the current reply can persist before the installer rebuilds, signs, installs to ~/Applications/NativeAgent.app, and restarts the app. Use this when `swift_build` passed and the running UI must pick up code changes. Do not use `restart_app` for this; restart_app only relaunches the already-installed bundle.",
                    parametersJSON: params(
                        properties: [
                            ("reason", strSchema("Required. Why the install/rebuild is needed; lands in the audit envelope.")),
                            ("start_delay_seconds", intSchema("Optional. Delay before launching install_app.sh so the final chat reply can persist. Defaults to restart_app's grace window; clamped 5...120.")),
                        ],
                        required: ["reason"]
                    )
                ),
                // restart_app (2026-06-10) — Swift app restart via detached
                // relauncher after a reply-safe grace window. Lives in the
                // Full-Mac-GATED block on
                // purpose: catalogued only when Trust Center file_ops_allowed
                // is on, default autonomy `confirm` (so on the claude/codex
                // bridge, which has no approval inbox, it fails closed), and
                // rate-limited by a 10-minute on-disk cooldown stamp
                // (data/restart_audit/last_restart.json).
                requestedSchema(
                    name: "restart_app",
                    description: "Restart the already-installed NativeAgent.app bundle: writes an audit receipt, spawns a detached relauncher, then terminates the app after a \(Int(AppRestartCoordinator.terminateGraceSeconds))s grace so this turn finishes persisting. This does NOT build, stage, sign, or install new Swift code; after Swift source edits use install_app instead. After this tool returns 'restarting', keep the final reply to one short sentence; it must be composed and persisted inside the grace window. The relauncher waits for the process to exit (up to \(AppRestartCoordinator.relauncherPollSeconds)s) and reopens the app bundle. Refuses if a tool-initiated restart fired within the last 10 minutes (cooldown). Requires Trust Center Full Mac file_ops_allowed; queues an approval unless toolAutonomy=auto for 'restart_app'.",
                    parametersJSON: params(
                        properties: [
                            ("reason", strSchema("Required. Why the restart is needed (lands in the audit envelope at data/restart_audit/<uuid>.json).")),
                        ],
                        required: ["reason"]
                    )
                ),
                // self-evolution chat tools (2026-06-11, U2b). Privileged: they
                // mutate the EvolutionProposalStore and stage a self-install
                // approval card. Live in the Full-Mac-GATED block on purpose
                // (catalogued only when file_ops_allowed is on), all default
                // autonomy `confirm`. Reachable on the claude/codex bridge as of
                // the user's 2026-06-13 "open the bridges" call — but still safe: none
                // spawns a Process, and self_install only STAGES a card a human
                // still approves; it never installs.
                requestedSchema(
                    name: "evolution_propose",
                    description: "File a self-evolution proposal into the evolution store (data/evolution/proposals.json). Use when you have identified a concrete improvement to your own codebase. With a diff it lands as 'proposed' (eligible to build+test in an isolated worktree); without one it lands as 'needs_diff'. This NEVER edits the live repo; it only records a proposal for the build/approve pipeline. Requires Trust Center Full Mac file_ops_allowed; queues an approval unless toolAutonomy=auto for 'evolution_propose'.",
                    parametersJSON: params(
                        properties: [
                            ("title", strSchema("Required. Short one-line description of the proposed change.")),
                            ("evidence", strSchema("Required. Why this change is warranted — the usage/error/observation that motivates it.")),
                            ("diff_text", strSchema("Optional. A unified diff. If given the proposal is 'proposed'; if omitted it is 'needs_diff'.")),
                            ("expected_head", strSchema("Optional. The git HEAD sha the diff was authored against (staleness guard).")),
                        ],
                        required: ["title", "evidence"]
                    )
                ),
                requestedSchema(
                    name: "evolution_status",
                    description: "Read the self-evolution proposal store. With proposal_id, return that one proposal's status + receipts; without it, list the in-flight proposals (proposed / building / candidate_green / staged). Read-only.",
                    parametersJSON: params(
                        properties: [
                            ("proposal_id", strSchema("Optional. The evolution proposal id (evo_…). Omit to list in-flight proposals.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "self_install",
                    description: "Stage the self-install approval card for a self-evolution proposal that has already built+tested GREEN (status candidate_green). This does NOT install anything; it only stages a self_evolution.apply card that the user must still approve, and the install itself only fires once Trust Center systemRebuild is enabled. Returns an honest 'not installable yet' envelope if the proposal is not candidate_green. Requires Trust Center Full Mac file_ops_allowed; queues an approval unless toolAutonomy=auto for 'self_install'.",
                    parametersJSON: params(
                        properties: [
                            ("proposal_id", strSchema("Required. The evolution proposal id (evo_…) to stage for install. Must be status candidate_green.")),
                        ],
                        required: ["proposal_id"]
                    )
                ),
            ])
        }
        if includeFullMacSystemTools {
            schemas.append(
                requestedSchema(
                    name: "system_info",
                    description: "Read basic local system/disk/memory information through the Swift dispatcher. Available only when Trust Center Full Mac system access is active.",
                    parametersJSON: params(properties: [], required: [])
                )
            )
        }
        if includeFullMacAppTools {
            schemas.append(contentsOf: [
                requestedSchema(
                    name: "mac_focus_app",
                    description: "Focus or launch a macOS app by app name, bundle identifier, or .app path through Swift MacControl. Available only when Trust Center Full Mac Accessibility app control is active.",
                    parametersJSON: params(
                        properties: [
                            ("app", strSchema("App name such as Safari, bundle identifier such as com.apple.Safari, or an absolute .app path.")),
                        ],
                        required: ["app"]
                    )
                ),
                requestedSchema(
                    name: "mac_quit_app",
                    description: "Ask a macOS app to quit by app name, bundle identifier, or .app path through Swift MacControl. Available only when Trust Center Full Mac Accessibility app control is active.",
                    parametersJSON: params(
                        properties: [
                            ("app", strSchema("App name such as Safari, bundle identifier such as com.apple.Safari, or an absolute .app path.")),
                        ],
                        required: ["app"]
                    )
                ),
            ])
        }
        return schemas.compactMap { $0 }
    }
}

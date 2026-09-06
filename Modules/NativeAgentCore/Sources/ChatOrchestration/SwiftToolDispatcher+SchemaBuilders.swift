import Darwin
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
        _ = await MCPWarmSweepLedger.shared.sweep(root: root)
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

// MARK: - Warm-sweep per-server change gate (perf wave 2, F6)

/// Decides which stdio servers a warm sweep actually has to handshake.
///
/// `refreshAllToolsCaches` forces a live `tools/list` round-trip for EVERY
/// configured server on every sweep — and because the subprocess pool reaps
/// idle servers, a 300s-cadence sweep re-spawns each of them, waits out the
/// handshake, and rewrites `mcp/cache/tools.json` with descriptors that are
/// byte-for-byte the ones already there. This ledger skips the servers that
/// provably cannot have changed and sweeps the rest exactly as before.
///
/// A server is skipped only when ALL of these hold:
///   • its manifest sources — `mcp/servers.json` and `research/config.json`,
///     which is where the auto-merged `searxng-local` default comes from — are
///     byte-identical (device, inode, size, mtime_ns) to the last SUCCESSFUL
///     handshake's, and
///   • its own command line (transport, endpoint, command, status) is
///     unchanged, and
///   • that handshake is younger than `maxHandshakeAge`.
///
/// The age ceiling is the deliberate part: a server whose PACKAGE is upgraded
/// in place (`npx some-mcp-server@latest`) changes no file this process can
/// see, so without it a newly-added tool would stay invisible forever. With it,
/// the model still picks that tool up — within an hour instead of five minutes.
/// A failed handshake never marks, so a broken server retries on every sweep.
actor MCPWarmSweepLedger {
    static let shared = MCPWarmSweepLedger()

    /// Longest an unchanged server goes without a fresh handshake.
    ///
    /// 3600s. gpt-5.5 wave-2 review: production sweeps cannot START more
    /// often than the warmer's 300s rearm, so a 300s ceiling here skips
    /// nothing — the ledger's savings require the ceiling to exceed the
    /// sweep cadence. The ONLY pickup this ceiling delays is a
    /// stat-INVISIBLE in-place package upgrade (`npx …@latest` with no
    /// manifest/config/command change): any visible change busts the stat
    /// check and re-handshakes on the next sweep at today's ≤5min latency
    /// regardless of this value. Named bound for User: invisible upgrades
    /// reach the model in ≤60min instead of ≤5min; drop this back toward
    /// 300 to undo (and forfeit the skip savings).
    static let maxHandshakeAge: TimeInterval = 60 * 60

    struct Signature: Sendable, Equatable {
        let manifest: String
        let commandLine: String
    }

    private struct Mark: Sendable {
        let signature: Signature
        let at: Date
    }

    private let maxHandshakeAge: TimeInterval
    private let clock: @Sendable () -> Date
    /// key: "<resolved root path>|<serverId>"
    private var marks: [String: Mark] = [:]
    /// Test seam: servers actually handshaken across this ledger's lifetime.
    private(set) var handshakes = 0
    /// Test seam: servers skipped because nothing about them had changed.
    private(set) var skips = 0

    init(
        maxHandshakeAge: TimeInterval = MCPWarmSweepLedger.maxHandshakeAge,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.maxHandshakeAge = maxHandshakeAge
        self.clock = clock
    }

    /// Same contract as `refreshAllToolsCaches`: never throws, returns
    /// serverId → tool count or error text, and logs every failure and every
    /// zero-tool result loudly. Skipped servers are reported as "skipped" and
    /// leave `mcp/cache/tools.json` untouched — which is the point: their
    /// catalog bytes are already the bytes a handshake would rewrite.
    @discardableResult
    func sweep(root: URL) async -> [String: String] {
        let dispatcher = SwiftNativeMCPDispatcher(root: root)
        let servers = (try? await dispatcher.listServers()) ?? []
        let manifest = await Self.manifestStamp(dispatcher: dispatcher, root: root)
        let rootKey = root.resolvingSymlinksInPath().path
        let now = clock()

        var report: [String: String] = [:]
        var liveKeys: Set<String> = []
        for server in servers where server.status != "needs_setup" && server.status != "error" {
            let key = "\(rootKey)|\(server.id)"
            liveKeys.insert(key)
            let signature = Signature(manifest: manifest, commandLine: Self.commandLine(server))
            if let mark = marks[key],
               mark.signature == signature,
               now.timeIntervalSince(mark.at) >= 0,
               now.timeIntervalSince(mark.at) < maxHandshakeAge {
                skips += 1
                report[server.id] = "skipped"
                continue
            }
            do {
                let count = try await dispatcher.refreshToolsCache(forServer: server.id)
                handshakes += 1
                // MARK ON SUCCESS ONLY. A server that threw, or that has not
                // completed a handshake at all, must stay on the sweep list.
                marks[key] = Mark(signature: signature, at: now)
                report[server.id] = "\(count)"
                if count == 0 {
                    FileHandle.standardError.write(Data(
                        "MCPDispatcher: server '\(server.id)' completed tools/list but advertised ZERO tools — it will contribute no mcp__\(server.id)__* descriptors to the model.\n".utf8
                    ))
                }
            } catch {
                handshakes += 1
                report[server.id] = "error: \(error)"
                FileHandle.standardError.write(Data(
                    "MCPDispatcher: tools-cache refresh FAILED for server '\(server.id)': \(error) — its tools stay invisible to the model.\n".utf8
                ))
            }
        }
        // Every insert has a matching remove: a server deleted from the
        // manifest, or a data root that will never be swept again, must not
        // hold a mark for the process lifetime.
        marks = marks.filter { !$0.key.hasPrefix("\(rootKey)|") || liveKeys.contains($0.key) }
        return report
    }

    /// The manifest sources' combined stat identity. Both files feed
    /// `listServers()`: `servers.json` is the manifest proper, and
    /// `research/config.json` supplies `searxng_base_url` for the auto-merged
    /// default server, so a change to either can change a server's command
    /// line without touching the other.
    private static func manifestStamp(dispatcher: SwiftNativeMCPDispatcher, root: URL) async -> String {
        let paths = [await dispatcher.serversPath, await dispatcher.configPath]
        return paths.map(fileStamp).joined(separator: "|")
    }

    /// stat-strength, with "does not exist" as a distinct value from "could not
    /// be stat'd" — the latter is unknowable, so it never compares equal to
    /// itself and the server is always swept.
    private static func fileStamp(_ url: URL) -> String {
        var info = stat()
        if stat(url.path, &info) == 0 {
            return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        }
        return errno == ENOENT ? "absent" : "unknown:\(UUID().uuidString)"
    }

    /// The server's own identity within the manifest. Deliberately built from
    /// named scalar fields in a fixed order rather than by serializing the
    /// record: dictionary serialization has no guaranteed key order, and a
    /// signature that flaps would either never skip or skip on a false match.
    private static func commandLine(_ server: MCPServer) -> String {
        [
            server.transport,
            server.endpoint,
            server.command ?? "",
            server.status,
        ].joined(separator: "\u{1F}")
    }

    /// Test seam.
    func _testStats() -> (handshakes: Int, skips: Int, marks: Int) {
        (handshakes, skips, marks.count)
    }

    /// Test seam: fresh-process equivalent.
    func reset() {
        marks.removeAll()
        handshakes = 0
        skips = 0
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
    /// W5 L1#13 (bash demotion): generic shell is the model's reflex reach even
    /// when a native tool answers the same question with structure, no approval
    /// queue, and no subprocess. Appended to the shell/bash schema DESCRIPTIONS
    /// only — dispatch, gating, and every other tool's behavior are unchanged.
    static let nativeToolPreferenceGuidance = "Best fits: session_search for past conversations; delegation_status for bridge progress; github_* for GitHub repositories, notifications, issues, and pull requests; git_status/git_log/git_diff for routine repo evidence; read_file/list_dir for direct file reads."

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
        // Subtract the four-verb cutover boundary here too. Every catalog field
        // derived from this list — `tool_groups` among them — was one table
        // entry away from advertising a name `tool_load` refuses; the callers
        // that re-filter through modelVisibleCatalogToolNames were carrying the
        // whole guarantee. Same set tool_load resolves against.
        return all.filter {
            !hidden.contains($0) && !Self.legacyMacModelToolNames.contains($0)
        }
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
        includeFullMacAccessibilityReadTools: Bool = false,
        includeFullMacAccessibilityInjectionTools: Bool = false,
        includeActivityQueryTool: Bool = false,
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
        // Recall has mutually exclusive search/page fields. Responses may
        // require every property on the wire, so unused fields must admit
        // null rather than forcing invented strings or integer placeholders.
        func nullableRecallField(_ schema: JSONValue) -> JSONValue {
            guard case .object(var properties) = schema,
                  case .string(let type)? = properties["type"] else { return schema }
            properties["type"] = .array([.string(type), .string("null")])
            return .object(properties)
        }
        func enumStringSchema(_ values: [String], _ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [
                ("type", .string("string")),
                ("enum", .array(values.map(JSONValue.string))),
            ]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        /// An enum field that may also be null: `type` admits null AND `null`
        /// is a member of `enum`, because a JSON Schema `enum` is exhaustive —
        /// widening `type` alone would still reject null.
        func nullableEnumStringSchema(_ values: [String], _ desc: String) -> JSONValue {
            obj([
                ("type", .array([.string("string"), .string("null")])),
                ("enum", .array(values.map(JSONValue.string) + [.null])),
                ("description", .string(desc)),
            ])
        }
        func intSchema(
            _ desc: String? = nil,
            minimum: Int? = nil,
            maximum: Int? = nil
        ) -> JSONValue {
            var props: [(String, JSONValue)] = [("type", .string("integer"))]
            if let minimum { props.append(("minimum", .int(Int64(minimum)))) }
            if let maximum { props.append(("maximum", .int(Int64(maximum)))) }
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        func boolSchema(_ desc: String? = nil) -> JSONValue {
            var props: [(String, JSONValue)] = [("type", .string("boolean"))]
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        func numSchema(
            _ desc: String? = nil,
            minimum: Double? = nil,
            maximum: Double? = nil
        ) -> JSONValue {
            var props: [(String, JSONValue)] = [("type", .string("number"))]
            if let minimum { props.append(("minimum", .double(minimum))) }
            if let maximum { props.append(("maximum", .double(maximum))) }
            if let desc { props.append(("description", .string(desc))) }
            return obj(props)
        }
        func stringArraySchema(
            _ desc: String? = nil,
            minItems: Int? = nil,
            maxItems: Int? = nil,
            maxItemLength: Int? = nil
        ) -> JSONValue {
            var itemProps: [(String, JSONValue)] = [("type", .string("string"))]
            if let maxItemLength { itemProps.append(("maxLength", .int(Int64(maxItemLength)))) }
            var props: [(String, JSONValue)] = [
                ("type", .string("array")),
                ("items", obj(itemProps)),
            ]
            // A bound the validator enforces must also be a bound the schema
            // STATES, or the model only discovers it by being refused.
            if let minItems { props.append(("minItems", .int(Int64(minItems)))) }
            if let maxItems { props.append(("maxItems", .int(Int64(maxItems)))) }
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
        func nonEmptyStringSchema(_ description: String) -> JSONValue {
            obj([
                ("type", .string("string")),
                ("minLength", .int(1)),
                ("description", .string(description)),
            ])
        }
        func conversationModeSchema() -> JSONValue {
            enumStringSchema(
                ["new", "resume"],
                "Choose new for unrelated work and omit conversation_id. Choose resume only for a contextual follow-up and pass the exact conversationId returned by this same tool. Omit this field for backward-compatible inference."
            )
        }
        func conversationReferenceSchema(_ agent: String, _ tool: String) -> JSONValue {
            strSchema(
                "Resume only: exact \(agent):… conversationId returned by an earlier \(tool). "
                + "For new work omit this field, or send an empty string when the caller serializes every optional field. "
                + "Never invent a placeholder and never pass the originating chat session id."
            )
        }

        var schemas: [LLMToolSchema?] = [
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
                parametersJSON: params(
                    properties: [
                        ("query", nullableRecallField(strSchema("Search text; null in ID page mode."))),
                        ("k", nullableRecallField(intSchema("Search result count, default 5; null in ID page mode."))),
                        ("memory_id", nullableRecallField(strSchema("Exact id from a recall hit; null in search mode. Set query/k to null when paging."))),
                        ("offset", nullableRecallField(intSchema("ID mode only: character offset, default 0; follow next_offset. Null in search mode."))),
                        ("max_characters", nullableRecallField(intSchema("ID mode only: positive page size, capped at 2000. Null in search mode."))),
                        ("expected_content_sha256", nullableRecallField(strSchema("ID mode: content_sha256 from the previous page, supplied by read_more. Null for a first page or search. A mismatch returns record_changed without text."))),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "recall_search",
                description: "Compatibility alias for recall_memory. Use query (optional k) to search, OR memory_id with offset/max_characters to recover bounded pages of one eligible fact. Never mix the two modes; set unused fields to null. Follow read_more with expected_content_sha256 until next_offset is null; on record_changed discard earlier pages and restart at 0.",
                parametersJSON: params(
                    properties: [
                        ("query", nullableRecallField(strSchema("Search text; null in ID page mode."))),
                        ("k", nullableRecallField(intSchema("Search result count, default 5; null in ID page mode."))),
                        ("memory_id", nullableRecallField(strSchema("Exact id from a recall hit; null in search mode. Set query/k to null when paging."))),
                        ("offset", nullableRecallField(intSchema("ID mode only: character offset, default 0; follow next_offset. Null in search mode."))),
                        ("max_characters", nullableRecallField(intSchema("ID mode only: positive page size, capped at 2000. Null in search mode."))),
                        ("expected_content_sha256", nullableRecallField(strSchema("ID mode: content_sha256 from the previous page, supplied by read_more. Null for a first page or search. A mismatch returns record_changed without text."))),
                    ],
                    required: []
                )
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
                description: "Send a message to Claude (Claude Code CLI running locally) AND wake her to work on it now. Set conversation_mode=new and omit conversation_id for unrelated work; set conversation_mode=resume and pass this tool's exact returned conversationId only for a contextual follow-up. A new coding conversation receives its own Git worktree and a resume reuses it. The message is durably queued, then a headless Claude Code session works it and returns a '[claude-wake] Automated completion event'. Completion receipts should not trigger reflexive acknowledgments.",
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
                        // R13: first-class correction lineage.
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
            // workshop_submit / workshop_status — Agent's execution chat lane (U5
            // W-I). She could neither submit nor check an execution from chat
            // (zero mission_* hits anywhere in ChatOrchestration; her own
            // honest refusal caught it). These are STANDARD tools — no Process
            // spawn — so they live in the always-on catalog block, NOT the
            // includeFullMacFileTools-gated block. They are NOT every-turn-hot
            // (a user submits/checks an execution occasionally), so they are
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
                description: "Run a user-directed task from the Desk's execution lane (the workshop_* name is retained for compatibility). Exact workspace byte copy: set operation=copy_workspace_file with source and destination. When the locally reviewed deterministic procedure is active, the execution lane skips its planner; otherwise it falls back before admission. Use procedure=local_file_copy_v1 only for explicit/manual compatibility. Every other objective creates a user-directed Desk task. Returns Desk identity and execution status; use workshop_status to follow queued work.",
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
                description: "Read the Desk's directed task execution status (the workshop_* name is retained for compatibility). Without an id: list active and recent work. With an execution id: return detail and step receipts. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("Optional compatibility execution id. Omit to list active and recent Desk tasks.")),
                    ],
                    required: []
                )
            ),
            // task_ledger_post / task_ledger_list (U6, 2026-06-11): the
            // cross-agent task ledger — shared who-owns-what / done / blocked
            // state for Claude / Agent / Codex. Same wiring canon as the
            // execution tools: always-on catalog block, LAZY-LOADED (NOT
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
            // delegation_status (W2, 2026-08-11): the READ side of the
            // delegation loop. claude_message / codex_message enqueue work and
            // the runners write a durable job record per job; nothing in Swift
            // could read those records, so the window between enqueue and the
            // terminal bridge event was dark. Pure local read (no write, no
            // spawn, no network) — same wiring canon as task_ledger_list:
            // catalog-visible, LAZY-LOADED, safe_read/.low.
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
                description: Self.innerStateToolDescription,
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
                description: "Add a new item to your Desk. kind: watch | plan | project | gh | standing. Provide a project bucket and a short title; optionally nest under a parent, name the delegated assignee, and link a lane to its program item with lane_of. A same-title/project/parent live item is returned with disposition=existing instead of silently creating a second owner; set allow_duplicate=true only when two equivalent live items are intentional. When delegating work, set assignee and lane_of here rather than burying them in prose. Returns status=ok, created, disposition, the stable handle, and view alias (e.g. \"2\" or \"2.1\").",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("Item kind: watch | plan | project | gh | standing.")),
                        ("project", strSchema("Project bucket this item belongs to.")),
                        ("title", strSchema("Short item title.")),
                        ("parent", strSchema("Optional parent item handle to nest this item under.")),
                        ("summary", strSchema("Optional one-line summary.")),
                        ("assignee", strSchema("Optional freeform delegation assignee, such as codex, claude, or agent.")),
                        ("lane_of", strSchema("Optional parent program item handle (or visible alias) whose delegated lane this item represents. Projection metadata only; it does not change Desk hierarchy.")),
                        ("allow_duplicate", boolSchema("Explicitly create a second equivalent live item instead of reusing the existing owner. Default false.")),
                    ],
                    required: ["kind", "project", "title"]
                )
            ),
            requestedSchema(
                name: "desk_set_status",
                description: "Set a Desk item's status. When fresh canonical evidence proves the exact tracked defect or outcome resolved, update that exact item in the same turn; never close from fuzzy title similarity, a merely completed execution, or an unattributed commit. status: watch | flag | now | next | todo | done | blocked | canceled. For blocked, pass blocked_reason and/or waiting_on. When assigning or updating a delegated lane, include assignee and lane_of; omitted metadata preserves its current value. When reporting concrete batch progress, include progress={done,total,note?}; omit it when no honest progress exists (the Desk never invents 0%). Returns the refreshed alias + status + title.",
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
                            ("description", .string("Optional live parent program handle (or visible alias) update for this existing lane. Omitted, null, or blank values preserve the current value; this field cannot clear a lane link. Send null when unchanged; never copy the item's own handle.")),
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
                description: Self.holdViewToolDescription,
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
                description: Self.releaseViewToolDescription,
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
                    description: "Run a shell command via /bin/sh -c. Captures stdout/stderr/exit_code. Requires Trust Center Full Mac file_ops_allowed; queues an approval request unless toolAutonomy=auto for 'shell'. Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical <dataRoot>/workspace used by public installs. Default timeout: 120s, max 600s. Use bash tool instead if you need bash-specific syntax (arrays, [[, process substitution). For checks, do not append `| tail; echo EXIT...` because that can mask the real failing exit code. \(Self.nativeToolPreferenceGuidance)",
                    parametersJSON: params(
                        properties: [
                            ("cmd", strSchema("Required. The shell command line. Passed as -c argument to /bin/sh.")),
                            ("cwd", strSchema("Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. Active Full Mac YOLO may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
                            ("timeout_seconds", intSchema("Optional. Default 120, max 600. Subprocess group gets SIGTERM then SIGKILL after 2s.")),
                        ],
                        required: ["cmd"]
                    )
                ),
                requestedSchema(
                    name: "bash",
                    description: "Run a shell command via /bin/bash -c (not sh). Same shape as shell. Use this when the command needs bash features: arrays, [[ ]] tests, process substitution, $'...' ANSI-C quoting, etc. For checks, do not append `| tail; echo EXIT...` because that can mask the real failing exit code. \(Self.nativeToolPreferenceGuidance)",
                    parametersJSON: params(
                        properties: [
                            ("cmd", strSchema("Required. The bash command line. Passed as -c argument to /bin/bash.")),
                            ("cwd", strSchema("Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. Active Full Mac YOLO may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
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
                            ("cwd", strSchema("Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. Active Full Mac YOLO may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
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
                            ("cwd", strSchema("Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. Active Full Mac YOLO may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
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
                    description: "Run a fixed-argv SwiftPM build. Ordinary modes use NativeAgent's workspace-confined outer wrapper; active Full Mac YOLO may build an explicitly selected external package without that wrapper. Command shape is `swift build --disable-sandbox --package-path <package_path> --configuration <debug|release>` plus optional product/target/jobs. TrustCenter, autonomy, audit receipts, and sensitive-path fences still apply.",
                    parametersJSON: params(
                        properties: [
                            ("package_path", strSchema("Optional Swift package directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical workspace. Active Full Mac YOLO may select an ordinary external package directory.")),
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
                    description: "Run fixed-argv SwiftPM tests. Ordinary modes use NativeAgent's workspace-confined outer wrapper; active Full Mac YOLO may test an explicitly selected external package without that wrapper. Command shape is `swift test --disable-sandbox --package-path <package_path> --configuration <debug|release>` plus optional filter/jobs. TrustCenter, autonomy, audit receipts, and sensitive-path fences still apply.",
                    parametersJSON: params(
                        properties: [
                            ("package_path", strSchema("Optional Swift package directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical workspace. Active Full Mac YOLO may select an ordinary external package directory.")),
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
                    name: "remote_node_list",
                    description: "List explicitly configured MacControl trusted remote effect nodes, their pinned host-key fingerprints, enablement, and executable allowlists. This is a read-only inventory; remote nodes never own chat, memory, context, or schedules.",
                    parametersJSON: params(properties: [], required: [])
                ),
                requestedSchema(
                    name: "remote_node_execute",
                    description: "Run one argv-shaped command on an explicitly enabled trusted remote node. The node is re-read at effect time, the executable must exactly match its allowlist, SSH host identity is pinned, output is bounded, and a durable receipt is written. This remains behind Trust Center Full Mac; standard modes follow their normal autonomy gate, while admitted Full Mac YOLO runs without a per-call prompt.",
                    parametersJSON: params(
                        properties: [
                            ("node_id", strSchema("Required node id from remote_node_list.")),
                            ("executable", strSchema("Required absolute executable path; must exactly match the node allowlist.")),
                            ("arguments", stringArraySchema("Optional argv values. Values are individually shell-quoted; multiline/NUL arguments are rejected.")),
                            ("timeout_seconds", intSchema("Optional. Default 60, clamped 1...300.")),
                        ],
                        required: ["node_id", "executable"]
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
                // mutate the EvolutionProposalStore and can stage a self-install
                // approval card in standard modes. Live in the Full-Mac-GATED block on purpose
                // (catalogued only when file_ops_allowed is on), all default
                // autonomy `confirm`. Reachable on the claude/codex bridge as of
                // the user's 2026-06-13 "open the bridges" call. Admitted Full
                // Mac YOLO uses the same candidate/CAS/backup/rollback executor
                // without a per-call card; standard modes retain approval.
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
                // evolution_withdraw (2026-09-02): the queue was write-only
                // from the agent's side — she could file a proposal and read
                // status, but had no way to take back one filed by mistake.
                // This is the only tool that walks a proposal BACKWARD, and it
                // only ever lands on the terminal `denied` state the legal
                // transition table already permits.
                requestedSchema(
                    name: "evolution_withdraw",
                    description: "Withdraw one of YOUR OWN self-evolution proposals — the one you filed by mistake. Moves it to the terminal 'denied' state with deny_reason 'withdrawn by agent: …' and an audit receipt. Refuses: proposals already in a terminal state (verified/reverted/denied), proposals with a candidate build/test run in flight (status 'building'), proposals past the withdrawal point (approved/installed — those need a revert, not a withdrawal), and any proposal you did not file yourself (only source='chat' records are yours; weekly / self_heal / external proposals are not withdrawable here). This never edits the live repo, never touches an installed change, and never withdraws anything on someone else's behalf. Requires Trust Center Full Mac file_ops_allowed; queues an approval unless toolAutonomy=auto for 'evolution_withdraw'; under the Everything (full run) trust posture the approval passes straight through and no card is shown.",
                    parametersJSON: params(
                        properties: [
                            ("id", strSchema("Required. The evolution proposal id (evo_…) to withdraw. Must be one you filed (source='chat').")),
                            ("reason", strSchema("Optional. Why you are withdrawing it. Recorded as the proposal's deny_reason, prefixed 'withdrawn by agent: '. Max 500 characters.")),
                        ],
                        required: ["id"]
                    )
                ),
                requestedSchema(
                    name: "self_install",
                    description: "Advance a self-evolution proposal that has already built+tested GREEN (status candidate_green). Standard modes stage a self_evolution.apply approval card. Admitted Full Mac YOLO enters the same candidate/CAS/backup/rollback executor directly without a per-call prompt; installation still requires Trust Center systemRebuild to be enabled. Returns an honest 'not installable yet' envelope if the proposal is not candidate_green. Requires Trust Center Full Mac file_ops_allowed.",
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
        if includeFullMacAccessibilityReadTools {
            // W1b — READ-ONLY perception. Descriptions state plainly what is
            // read, that nothing is changed, and the two things that must both
            // be true for a call to return data (macOS Accessibility system
            // grant + the Trust Center accessibility category). No approval
            // tier: reading the screen's own UI description mutates nothing.
            schemas.append(contentsOf: [
                // W7 — mac_nudge. Under the SAME include flag as the reads
                // because it clears the same gate. The description says
                // plainly what it does and, just as plainly, what it cannot
                // do, so the model never reaches for it as a way around the
                // approval on mac_click / mac_keystroke.
                requestedSchema(
                    name: "mac_nudge",
                    description: "Post a single bare mouse MOVE (one point) to wake a sleeping display or dismiss a screensaver — the software equivalent of bumping the mouse. It moves the cursor and does nothing else: it cannot click, type, scroll, drag, or authenticate. Takes no arguments. Available only when Trust Center Full Mac is active with the Accessibility category enabled; to actually click or type, use mac_click / mac_keystroke.",
                    parametersJSON: params(properties: [], required: [])
                ),
                // fable51 item 30 — the clipboard READ. Under the read include
                // flag because it clears the read tier. The description states
                // the two things a model must know before reaching for it: the
                // text is shape-redacted (so a blanked line is redaction, not
                // an empty clipboard), and non-text flavors are NAMED, never
                // dumped.
                requestedSchema(
                    name: "clipboard_read",
                    description: "Read what is on this Mac's clipboard right now, as text. Read-only: it changes the clipboard and nothing else on the screen. Pair it with a copy (select all, then ⌘C) to read a dense document the screen cannot show you in words. Lines that are THEMSELVES a secret — a password, an API key, a one-time code, a card number, a recovery phrase — come back as \"[redacted: <reason>]\" and are listed under `redactions`; that is redaction, not an empty clipboard, and re-reading will not reveal them. Non-text contents (an image, a file, an app's own flavor) are reported by type and size under `types` — the bytes are never returned. Available only when Trust Center Full Mac is active with the Accessibility category enabled.",
                    parametersJSON: params(
                        properties: [
                            ("max_chars", intSchema("Maximum characters of clipboard text to return. Default 8000, clamped to 200-32000; the result says whether it cut and how many characters there were.")),
                        ],
                        required: []
                    )
                ),
                // fable51 item 29 — the MENU BAR walk. Under the read include
                // flag: it walks the app's published menu tree and changes
                // nothing. The description says the two things that stop a
                // model misusing it — it does not open menus, and a greyed-out
                // item is present-but-off rather than absent.
                requestedSchema(
                    name: "menu",
                    description: "List an app's menu bar as nameable paths — \"File › Export › PDF…\", \"Edit › Find › Find Next\". This is the cheapest deterministic route to anything an app can do: no coordinates, no scrolling, no guessing which toolbar icon means export. Read-only, and it does NOT open any menu — the paths come from the app's published accessibility tree whether or not a menu is drawn. Bounded: three levels deep, capped in item count, one walk (the result says if a bound cut it). Items that are greyed out are still listed with `enabled: false` — present but switched off in this state, which is different from absent. Press one with menu_press. Available only when Trust Center Full Mac is active with the Accessibility category enabled.",
                    parametersJSON: params(
                        properties: [
                            ("app", strSchema("Optional: read this running app's menu bar instead of the frontmost app's, without activating it. Defaults to whatever is in front.")),
                        ],
                        required: []
                    )
                ),
                // fable51 item 33 — THE READ ORGAN. Under the read include flag
                // because it clears the read tier. The description has one job
                // beyond honesty: teach the SPLIT from `screen`, because a
                // model that has `screen` will otherwise call it in a loop and
                // stitch the frames itself at full token cost — which is the
                // exact failure this organ exists to end.
                requestedSchema(
                    name: "read",
                    description: "READ a document end to end — a contract, a PDF, a long article, a thread. Different from `screen`: `screen` answers \"what is in front of me and what can I do to it\" in one bounded glance; `read` answers \"what does this SAY\" and returns ALL of it. If the window in front is showing a file (or you name one with `path`), the file's own text is extracted — PDFs through PDFKit, plain text directly — so you get the author's characters rather than a scrape of a rendering. Otherwise it reads the front window's text, scrolls one screenful, reads again, merges on the overlap, and keeps going until the content stops changing; it then scrolls back to where it started. It presses nothing, types nothing and opens nothing. Long results are retained whole for this turn — when the answer comes back as a bounded summary with a `result_handle`, call tool_result_page to page through the rest; do NOT re-run this to see more. Lines that are THEMSELVES a secret come back as \"[redacted: <reason>]\". Refusals are in words: no document in front, a password-protected file, a scanned PDF with no text layer (ask for `screen` instead), a secure password field. Available only when Trust Center Full Mac is active with the Accessibility category enabled; naming an explicit `path` additionally needs Full Mac file access.",
                    parametersJSON: params(
                        properties: [
                            ("path", strSchema("Optional: read this file instead of the screen — an absolute path to a PDF or a plain-text file. Omit it to read whatever document is in front of you (or, when the front window names no file, the window's own text).")),
                            ("app", strSchema("Optional: read THIS running app's front window instead of whatever is in front — \"read the contract, app: Preview\". The window is read where it sits: nothing is activated, raised or launched, so your focus does not move and neither does User's. Refused in words if nothing by that name is running or the name matches more than one running app. Ignored when you name a `path`, which reads the file rather than any window.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_ax_status",
                    description: "Report whether this app currently holds the macOS Accessibility (AX) system grant needed to read the on-screen UI tree. Read-only: changes nothing. Available only when Trust Center Full Mac is active with the Accessibility category enabled.",
                    parametersJSON: params(properties: [], required: [])
                ),
                requestedSchema(
                    name: "mac_ax_tree",
                    description: "Read the on-screen accessibility (AX) tree of the frontmost window — the roles, titles and values macOS itself publishes for the UI. This is perception, not control: it clicks nothing, types nothing and changes nothing. Requires the macOS Accessibility system grant; available only when Trust Center Full Mac is active with the Accessibility category enabled. Results are bounded by node/depth caps and may come back truncated.",
                    parametersJSON: params(
                        properties: [
                            ("max_nodes", intSchema("Maximum number of AX nodes to return. Clamped to the reader's own cap; omit for the default.")),
                            ("max_depth", intSchema("Maximum tree depth to descend. Clamped to the reader's own cap; omit for the default.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_ax_find",
                    description: "Search the on-screen accessibility (AX) tree of the frontmost window for elements matching a role, title and/or value, and return their paths. Read-only perception: it locates UI elements, it does not click or focus them. Requires the macOS Accessibility system grant; available only when Trust Center Full Mac is active with the Accessibility category enabled. At least one of role/title/value must be given.",
                    parametersJSON: params(
                        properties: [
                            ("role", strSchema("AX role to match, such as AXButton or AXTextField.")),
                            ("title", strSchema("Substring to match against an element's AX title/label.")),
                            ("value", strSchema("Substring to match against an element's AX value.")),
                            ("limit", intSchema("Maximum number of matches to return. Clamped to the reader's own cap.")),
                        ],
                        required: []
                    )
                ),
                // W3.5 — THE FUSED VIEW. The description has one job beyond
                // honesty: teach the calling convention. A model that reads
                // "screenshot" reaches for coordinates out of habit, so this
                // says plainly that the numbers are the address and the
                // coordinates are the exception.
                requestedSchema(
                    name: "mac_view",
                    description: "SEE the screen the way a person does: one fused view of the frontmost window that returns the accessibility structure AND a screenshot, with every clickable and scrollable element outlined and NUMBERED on the image. Read the structure first — `marks` gives each number's role, label, value, state, frame and real element path, and `text` gives everything the window says in reading order; together they describe the screen completely, and the image is the spatial backdrop showing where each numbered thing sits rather than something you must decode. Act by NUMBER, not by coordinate — pass the returned `view` id with mac_ax_act {mark, view} to press an element the app's own way, or mac_click {mark, view} to click its centre; this call is read-only and changes nothing. Only fall back to raw x/y coordinates for parts of the picture with no marks (a canvas, a game, a video). Marks are valid ONLY for the most recent view: if the screen may have changed, call mac_view again — an older view id is refused rather than guessed at. Read-only perception: it changes nothing. Needs the Trust Center Full Mac Accessibility category, and the picture half also needs the macOS Screen Recording permission (a separate grant from Accessibility) — when that is missing you still get the numbered legend, and the result says so.",
                    parametersJSON: params(
                        properties: [
                            ("full_screen", boolSchema("Capture the whole display instead of just the frontmost window. Defaults to false (the focused window).")),
                            ("max_marks", intSchema("Maximum number of elements to number. Clamped to the view's own cap (60); omit for the default.")),
                            ("max_text_items", intSchema("Maximum lines of on-screen text to return. Clamped to the view's own cap (80); omit for the default.")),
                            ("max_image_bytes", intSchema("Maximum encoded PNG size. The image is downscaled to fit; clamped to the view's own cap. Omit for the default.")),
                            ("max_nodes", intSchema("Maximum number of AX nodes to consider when choosing marks. Clamped to the reader's own cap.")),
                            ("max_depth", intSchema("Maximum AX tree depth to descend. Clamped to the reader's own cap.")),
                        ],
                        required: []
                    )
                ),
                // native-look item 2 — THE PERCEPTION COMPILER. The description
                // teaches the GRADE, because the whole saving is in her picking
                // the cheapest one that answers the question: a glance is one
                // line, a look is the addressable controls, a stare is the tree
                // she almost never needs.
                requestedSchema(
                    name: "screen",
                    description: "Look at the live screen, right now, in words. One structured page: SCREEN (which app and window, whether it is front), WHERE (your position in the app's own navigation), the dominant content as a numbered LIST/GRID (the numbers are addresses — say 'row 3' to point at one) or CANVAS when part of the screen is not controls, DO (everything you can act on, with its state inline), SAYS (status text worth knowing). Nothing to hold and nothing expires: look again by calling again. Pass `part` to lean in — the same shape scoped to the section or thing you name ('the list', 'the toolbar', 'the Send button'). Pass `app` to glance at ANOTHER running app's front window without switching to it: nothing is activated, nothing moves on the user's screen, and the answer says the window is not in front. Acting still needs the app in front — use `go` for that.",
                    parametersJSON: params(
                        properties: [
                            ("part", strSchema("Optional: a section, thing, or status readout to inspect by name. Use hud/readouts for observed status values, or a label such as Last drag or Energy to reveal a readout hidden by the ordinary display cap.")),
                            ("app", strSchema("Optional: read this running app's front window instead of whatever is in front, WITHOUT activating it (\"Mail\", \"Safari\"). If nothing by that name is running, or the name matches more than one, the answer says so and names what is running.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "wait",
                    description: "Watch the screen until it settles or until something you name appears — like watching a page load. Bounded (default 10s, max 60s); returns early when the screen stops changing or when `until` text shows up, and says honestly when it timed out with the screen still moving. Answers with what happened and the final screen.",
                    parametersJSON: params(
                        properties: [
                            ("until", strSchema("Optional: return as soon as this text appears on screen (case-insensitive).")),
                            ("seconds", intSchema("Optional: how long to watch. Default 10, max 60.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_look",
                    description: "LOOK at the frontmost window — the app reads the on-screen accessibility structure and hands you the distilled answer instead of a tree you have to parse. Three grades: `glance` is ONE line (app, window title, how many controls, where the focus is, whether a sheet or dialog is up, the first few buttons); `look` is the structured percept — the window, the focused element, any modal, the landmarks (toolbar, sidebar, table, list, web area) and every LABELED interactive control with a stable `handle`, its role, value and real element path; `stare` is the full raw AX tree, the same payload mac_ax_tree returns, and you should rarely need it. Prefer `glance` to orient and `look` to act: a look costs roughly a tenth to a seventieth of a stare. Controls the app publishes no name for are never hidden — they are counted by role under `unlabeled`. Handles are valid only for the returned `frame_id`; if the screen may have changed, look again. Read-only perception: it clicks nothing, types nothing and changes nothing. Requires the macOS Accessibility system grant; available only when Trust Center Full Mac is active with the Accessibility category enabled.",
                    parametersJSON: params(
                        properties: [
                            ("grade", enumStringSchema(["glance", "look", "stare"], "How hard to look. Defaults to look.")),
                            ("max_affordances", intSchema("Maximum labeled interactive controls to return. Clamped to the compiler's own cap (60); omit for the default.")),
                            ("max_nodes", intSchema("Maximum number of AX nodes to walk. Clamped to the reader's own cap.")),
                            ("max_depth", intSchema("Maximum AX tree depth to descend. Clamped to the reader's own cap.")),
                            ("scope", enumStringSchema(
                                ["page", "chrome", "both"],
                                "For a browser or Electron window: `page` (the default) spends the whole walk on the web page and collapses the browser's own toolbar and bookmarks bar to one summary line; `chrome` looks at the browser's controls instead; `both` walks the whole window in one pass, where the page competes with the chrome for the node budget. Ignored for a window with no web area — the result always says which scope it used."
                            )),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_attention",
                    description: "Pay continuous, explicit attention to this Mac without a polling loop or another model. `start` installs a passive, on-device event observer for a bounded time and returns a fresh fused screen view. `next` waits efficiently for physical pointer/keyboard/scroll activity or an app change (up to wait_ms), then returns one fresh fused view; keyboard CONTENT is never captured, only an activity pulse. Physical user input always wins: it immediately invalidates the old view and motor tools refuse with yielded_to_user until you call `next` and re-observe. `status` reports the live session; `stop` removes every observer and forgets the ephemeral state. While active, pass the returned attention.session and attention.user_sequence as attention_session and attention_user_sequence on every Mac motor action. Read-only perception under the Full Mac Accessibility gate; the screenshot half also needs Screen Recording permission.",
                    parametersJSON: params(
                        properties: [
                            ("mode", enumStringSchema(["start", "next", "status", "stop"], "Attention operation. Defaults to status.")),
                            ("session", strSchema("Session id returned by start. Required for next.")),
                            ("after_sequence", intSchema("For next: wait only for activity newer than this attention sequence.")),
                            ("wait_ms", intSchema("For next: event-driven wait before refreshing anyway, 0-15000ms. Defaults to 1500.")),
                            ("duration_seconds", intSchema("For start: bounded observer lifetime, 15-1800 seconds. Defaults to 300.")),
                            ("full_screen", boolSchema("Capture the whole display instead of the focused window.")),
                            ("max_marks", intSchema("Maximum numbered elements, with the same cap as mac_view.")),
                            ("max_text_items", intSchema("Maximum visible text items, with the same cap as mac_view.")),
                            ("max_image_bytes", intSchema("Maximum encoded PNG bytes, with the same cap as mac_view.")),
                        ],
                        required: []
                    )
                ),
            ])
        }
        // W7 — the ambient activity watcher's query tool. The description's job
        // is to stop the model over-claiming: it must not describe this as
        // knowing what User was DOING (it knows which app was frontmost and for
        // how long), and it must not imply titles are always present or safe.
        if includeActivityQueryTool {
            schemas.append(contentsOf: [
                requestedSchema(
                    name: "activity_query",
                    description: "Summarise which Mac apps were in use over a time range, from a local, on-device activity log the user explicitly opted into and separately allowed this selected AI provider to read. It knows WHICH APP was frontmost and FOR HOW LONG — not what was done inside it, not what was typed, and not the contents of any field. Where the user enabled window titles, a secret-redacted title may appear on example spans; treat it as a weak hint, not a description of the work, and never quote it as fact about content. Apps on the user's exclusion list are absent from the answer entirely, even for days when they were still being recorded, so totals can legitimately be lower than a full day. The answer is capped at 50 rows and refuses rather than silently truncating an over-dense source range. Read-only and deterministic; the store is never exposed to iPhone/Telegram/Slack/iCloud/bridges. If capture or Agent Access is off in Trust Center this tool refuses rather than returning an empty day; do not read a refusal as \"nothing happened\".",
                    parametersJSON: params(
                        properties: [
                            ("range", strSchema("Named range: today, yesterday, last_hour, last_24_hours, last_7_days, last_30_days. Defaults to today. Ignored when `from` is given.")),
                            ("from", strSchema("Explicit range start: epoch seconds, an ISO-8601 instant, or YYYY-MM-DD (midnight in the asking timezone).")),
                            ("to", strSchema("Explicit range end, same formats as `from`. Defaults to now.")),
                            ("bundle_id", strSchema("Restrict the answer to one app's bundle identifier, e.g. com.apple.Safari.")),
                            ("timezone", strSchema("IANA timezone the day/hour buckets are computed in, e.g. Europe/London. Defaults to this Mac's current timezone.")),
                            ("limit", intSchema("Maximum rows in the answer. Clamped to 50; the answer says what the cap removed.")),
                        ],
                        required: []
                    )
                ),
            ])
        }
        if includeFullMacAccessibilityInjectionTools {
            // W2/W3 — INJECTION. The honesty bar here is higher than for the
            // reads: each description says plainly that it drives the real
            // keyboard/mouse or the real app, that it goes to whatever app is
            // frontmost, and that it needs approval. No euphemism ("interact
            // with", "assist") — the model and the approval card both quote
            // this text back to User.
            func intArraySchema(_ desc: String) -> JSONValue {
                obj([
                    ("type", .string("array")),
                    ("items", obj([("type", .string("integer"))])),
                    ("description", .string(desc)),
                ])
            }
            func pointSchema(_ desc: String) -> JSONValue {
                obj([
                    ("type", .string("object")),
                    ("description", .string(desc)),
                    ("properties", obj([
                        ("x", intSchema("Screen x coordinate.")),
                        ("y", intSchema("Screen y coordinate.")),
                    ])),
                ])
            }
            schemas.append(contentsOf: [
                requestedSchema(
                    name: "act",
                    description: "Do something naturally, by NAME or visible ordinal, against a fresh fused screen. Semantic actions: click/open/type/select/toggle/scroll/dismiss. Physical actions: hover, move, drag (give `to`), hold, or key (target may be a bounded key/chord sequence such as `w`, `cmd+s`, or `1 2 3`; `hold` can target `key w`). Prominent unlabeled pixel objects appear in the same screen as numbered visual regions; they accept literal physical actions without being misrepresented as semantic controls. Use `repeat` for a short continuous burst: the target is freshly seen and re-resolved before every attempt, so moving visual targets are followed instead of reusing an old point. Use `holding` to keep one or more keys/modifiers down around a physical move, drag, click, scroll, or key action (for example hold `w d` while dragging a world view). Accessibility targets use the app's own action; coordinated or pixel-only actions use the bounded physical hand. Burst results distinguish requested, accepted, planned, completed, visibly verified, elapsed, and runtime-limited work. Ambiguity, drift, a vanished target, or the elapsed boundary stops the burst before another action. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("verb", enumStringSchema(["click", "open", "type", "select", "toggle", "scroll", "dismiss", "hover", "move", "drag", "hold", "key"], "What to do.")),
                            ("target", strSchema("The thing, by name as the screen shows it — a label, a partial label, an ordinal like 'row 3', or a numbered unlabeled target like 'visual region 2'. For hold, `key w d` holds W and D simultaneously for seconds; space-separated keys/chords and bare modifiers are supported. For key, a space-separated sequence remains sequential.")),
                            ("text", strSchema("For `type`: the text to put in the target.")),
                            ("direction", enumStringSchema(["up", "down", "left", "right"], "For `scroll`: which way to move. Left/right sends horizontal wheel input.")),
                            ("scroll_amount", intSchema("For scroll: wheel magnitude in lines, 1 for fine adjustment through120. Use0 (or omit) for ordinary/default behavior, including all non-scroll verbs. An explicit amount requests wheel input rather than page-key fallback.", minimum: 0, maximum: 120)),
                            ("to", strSchema("For `drag`: the named/numbered destination.")),
                            ("to_app", strSchema("For `drag` only: the running app whose front window `to` lives in, when the drop lands in a DIFFERENT app from the one in front — \"drag report.pdf to the message body, to_app: Mail\". The destination is resolved in that app's window without activating it, so nothing moves while I am looking; then, only if the drop needs it, that app is brought forward once and the result says that focus moved and why. Refused in words if the app is not running, if the name matches more than one running app, if nothing in that window answers to `to`, if raising it would cover the thing being picked up, or if the drag would cross a password field. Hold `option`/`cmd` with `holding` for the app's own copy/move variant. For text, prefer clipboard_write plus a paste — this is for dragging things accessibility can name.")),
                            ("seconds", numSchema("For hover or hold: duration up to10 seconds. For drag: paced travel duration, bounded0.08–2 seconds;0/omission uses0.24 seconds. Drag duration controls movement, not two endpoint pauses.", minimum: 0, maximum: 10)),
                            ("repeat", intSchema("Optional bounded burst count. The target is freshly re-resolved before every attempt; planning and real elapsed execution are capped at 30 seconds.", minimum: 1, maximum: 12)),
                            ("interval", numSchema("Optional pause between repeated attempts.", minimum: 0, maximum: 2)),
                            ("holding", strSchema("Optional keys/modifiers held around a physical action, such as `w d`, `shift`, or `cmd+w`. Works with pointer hold, including right-button hold while movement keys are down. Not valid with a keyboard hold (put all keys in its target) or literal type.")),
                            ("button", enumStringSchema(["auto", "left", "right"], "Use auto for the ordinary/default action, including key, type, scroll, move, and hover. Use left or right only to request an explicit mouse button on click, open (double-click), drag, or pointer hold. Right drag sends genuine right-button events, not Control-left-drag. Omission is equivalent to auto.")),
                        ],
                        required: ["verb", "target"]
                    )
                ),
                // fable51 item 30 — the clipboard WRITE. Under the injection
                // include flag because it clears app-control authority, not
                // because it injects: it posts no event and performs no AX
                // action. It replaces what the next ⌘V anywhere will paste,
                // which the description says plainly.
                // fable51 item 29 — the menu PRESS. Under the injection include
                // flag because it runs the app's own handler: File › Quit and
                // Edit › Delete are one press away.
                requestedSchema(
                    name: "menu_press",
                    description: "Press one menu item by name, as the menu bar shows it: \"File › Export › PDF…\". Levels can be separated by ›, >, or /. This runs the app's OWN menu handler — the same thing that happens when a person picks it — so it can save, close, quit, or delete depending on what you name. Resolve the path with `menu` first: an unknown path refuses and lists what is actually there, an ambiguous one refuses and names the candidates, and an item the app has greyed out refuses in words rather than pressing nothing and calling it done. Whether the intended thing happened is for the next look to say. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("path", strSchema("The menu path to press, e.g. \"File › Export › PDF…\" or \"Edit > Find > Find Next\".")),
                            ("app", strSchema("Optional: press in this running app's menu bar instead of the frontmost app's. Defaults to whatever is in front.")),
                        ],
                        required: ["path"]
                    )
                ),
                requestedSchema(
                    name: "clipboard_write",
                    description: "Put text on this Mac's clipboard, replacing whatever was there. The next paste (⌘V) in ANY app will produce this text, and what was on the clipboard before is gone. It types nothing and clicks nothing by itself — to get the text into a document, paste it afterwards. Bounded at 100000 characters. The result reports how many characters were written and whether reading the clipboard back matched; the text itself is never echoed. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("text", strSchema("The text to place on the clipboard.")),
                        ],
                        required: ["text"]
                    )
                ),
                requestedSchema(
                    name: "go",
                    description: "Get to an app, file, folder, or http/https URL through the canonical Mac-control owner, then read the fresh screen. App activation is independently verified; file/URL opening is reported only as an accepted request unless the screen proves where it landed. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("name", strSchema("An app name, a file/folder path (~ allowed), or an http/https URL.")),
                        ],
                        required: ["name"]
                    )
                ),
                requestedSchema(
                    name: "mac_keystroke",
                    description: "Type text and/or press key combinations on this Mac, exactly as if typed on the physical keyboard. The input goes to WHATEVER APP IS FRONTMOST — focus the intended app first. `text` is typed literally (any Unicode, any layout); `keys` is a space-separated sequence of chords using cmd/shift/opt/ctrl/fn plus a key, for example \"cmd+s\", \"cmd+shift+4\", \"return\", \"cmd+a cmd+c\". At least one of text/keys is required; text is typed before keys. This requires approval and an active Full Mac window with the Accessibility category on.",
                    parametersJSON: params(
                        properties: [
                            ("text", strSchema("Literal text to type, character by character. Any Unicode; layout-independent.")),
                            ("keys", strSchema("Space-separated key chords, e.g. \"cmd+shift+4\" or \"escape\" or \"cmd+a cmd+c\". Modifiers: cmd, shift, opt, ctrl, fn. Named keys: return, tab, escape, space, delete, forward_delete, home, end, pageup, pagedown, up, down, left, right, f1-f20.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_click",
                    description: "Click, double-click, right-click, or drag on this Mac, exactly as if done with the physical mouse. PREFER pointing by NAME: pass `mark` plus the `view` id from mac_view and the click lands on that element's real centre, no coordinate guessing — or better still use mac_ax_act, which presses the control the app's own way. Give x/y only for parts of the screen with no marks (a canvas, a game, a video), or from/to for a drag. This requires approval and an active Full Mac window with the Accessibility category on.",
                    parametersJSON: params(
                        properties: [
                            ("x", intSchema("Screen x coordinate to click.")),
                            ("y", intSchema("Screen y coordinate to click.")),
                            ("button", enumStringSchema(["left", "right"], "Mouse button. Defaults to left.")),
                            ("count", intSchema("Number of clicks, 1-3. Use 2 for a double-click.")),
                            ("double", boolSchema("Shorthand for count:2.")),
                            ("from", pointSchema("Drag start point. Give both from and to to drag instead of click.")),
                            ("to", pointSchema("Drag end point.")),
                            ("duration_ms", intSchema("For a drag: smooth local movement duration, 80-2000ms. Defaults to 240ms; no extra model calls.")),
                            ("mark", intSchema("A number from the latest mac_view legend. Clicks that element's centre; needs `view` too. Preferred over x/y.")),
                            ("view", strSchema("The `view` id mac_view returned with that mark. A mark from any earlier view is refused — take a fresh mac_view instead.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_scroll",
                    description: "Scroll on this Mac with synthesized mouse-wheel events, exactly as if using the physical wheel or trackpad. Positive dy scrolls up, negative dy scrolls down. Optionally give x/y to move the pointer over the view to scroll first. This requires approval and an active Full Mac window with the Accessibility category on.",
                    parametersJSON: params(
                        properties: [
                            ("dy", intSchema("Vertical scroll amount. Positive scrolls up, negative down.")),
                            ("dx", intSchema("Horizontal scroll amount.")),
                            ("x", intSchema("Optional screen x to move the pointer to before scrolling.")),
                            ("y", intSchema("Optional screen y to move the pointer to before scrolling.")),
                            ("units", enumStringSchema(["line", "pixel"], "Scroll units. Defaults to line.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_ax_act",
                    description: "Act on ONE UI element of the frontmost window, addressed either by a `mark` number from the latest mac_view (pass `view` too) or by the `path` that mac_ax_tree or mac_ax_find returned for it. By default it presses the element (AXPress), which runs the app's own handler — more reliable than clicking a coordinate, and it works even when the element is partly covered. Pass `value` instead to set a text field's contents directly. If the element exposes no usable accessibility action, this falls back to a synthesized click at the element's centre and says so in the result's `method` field. The result carries a re-read `post_state` so you can check whether the UI actually changed. Needs Trust Center Full Mac with the Accessibility category on and the macOS Accessibility grant; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("path", intArraySchema("Child-index path from mac_ax_tree / mac_ax_find. [] is the window itself.")),
                            ("action", strSchema("Accessibility action to perform, e.g. AXPress (default), AXShowMenu, AXIncrement.")),
                            ("value", strSchema("When given, set the element's value to this text instead of performing an action. For text fields.")),
                            ("mark", intSchema("A number from the latest mac_view legend, addressing the same element its legend row names. Needs `view` too. Use instead of `path`.")),
                            ("view", strSchema("The `view` id mac_view returned with that mark. A mark from any earlier view is refused — take a fresh mac_view instead.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: []
                    )
                ),
                // native-look item 3 — THE CLOSED LOOP. One call replaces the
                // look→click→look triple: it acts on a handle and returns what
                // changed, so the model never spends a turn finding out.
                requestedSchema(
                    name: "mac_act",
                    description: "ACT on one control you saw in a mac_look, and get back WHAT CHANGED in the same call — you never need to look again to find out whether it landed. Pass the `handle` of a control from the latest look plus that look's `frame_id`, and a `verb`: `click` presses it the app's own way (falling back to a real click at its centre when it advertises no action), `open` opens it — a Finder row, a file, a folder — via AXOpen or a synthesized double-click, `type` puts `text` into it (setting the value directly when the control allows it, otherwise focusing it and typing), `select` picks a row/cell/menu item, `toggle` flips a checkbox/radio/switch, `dismiss` closes the sheet or dialog that is up by pressing its own Cancel/Close/Dismiss/Done/OK button, and `scroll` brings the control into view (`direction` up or down). Before acting it watches the app for accessibility change notifications, then re-reads the window and diffs it: the result's `effect` names the notifications that fired, the acted control's before/after label and value, which affordances appeared, disappeared or changed, whether focus moved, whether a modal opened or closed, and whether the window title changed — with `observed:false` when the app published no change at all, which is itself an answer. It also returns a FRESH `frame_id` and a one-line `glance` of the new state, so the next act continues from there; handles from the previous frame are dead. If the control the handle named is no longer what it was, this refuses with `handle_drifted` rather than acting on a different control; it also refuses with `frame_app_gone` when the app you looked at is no longer there, and with `observer_unavailable` when it cannot watch that app for the effect — in every one of those cases NOTHING is acted on. Needs Trust Center Full Mac with the Accessibility category on and the macOS Accessibility grant; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("handle", strSchema("Handle of the control, from the latest mac_look's affordances.")),
                            ("frame_id", strSchema("The frame_id that mac_look returned with that handle. A handle from any earlier frame is refused — take a fresh mac_look instead.")),
                            ("verb", enumStringSchema(
                                ["click", "open", "type", "select", "toggle", "dismiss", "scroll"],
                                "What to do to the control."
                            )),
                            ("text", strSchema("For verb=type: the characters to put into the control.")),
                            ("direction", enumStringSchema(["up", "down"], "For verb=scroll: which way. Defaults to down.")),
                            ("wait_ms", intSchema("How long to wait for the app to react before reporting no observed effect, 0-2000ms. Defaults to 300, which is ten times the measured latency.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: ["handle", "frame_id", "verb"]
                    )
                ),
                requestedSchema(
                    name: "mac_wake",
                    description: "Wake the screen: if this Mac is showing a screensaver or the display has gone to sleep, nudge it away and hand back a fresh view of the real desktop underneath, in one call. Use it when mac_view shows only the screensaver or the login window and you need to see or act on what is actually there. It posts the smallest possible input — a one-point mouse move plus a bare Shift tap, neither of which can click, type text, or authenticate — and then returns exactly what mac_view returns (`marks`, `text`, the annotated image, and a `view` id you can act on), plus a `wake` block saying whether the screen really came back. If the saver/login layer remains, it reports that observed obstruction without guessing why. Requires approval and an active Full Mac window with the Accessibility category on.",
                    parametersJSON: params(
                        properties: [
                            ("key_tap", boolSchema("Also tap the left shift key, which types nothing but wakes some sleeping displays a mouse move alone does not. Off by default; try it if a first wake reports dismissed:false.")),
                            ("settle_ms", intSchema("How long to wait after the nudge before capturing, 0-3000ms. Defaults to 700, which is enough for the screensaver to finish tearing down. Raise it if the returned view still shows the saver.")),
                            ("full_screen", boolSchema("Capture the whole screen instead of just the frontmost window, same as mac_view.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: []
                    )
                ),
            ])
        }
        return schemas.compactMap { $0 }
    }
}

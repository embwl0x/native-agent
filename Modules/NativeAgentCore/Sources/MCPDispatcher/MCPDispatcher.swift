import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Records
//
// Subsystem #3 — READ-ONLY MCP query surface + consent ledger storage IO.
//
// This file owns persisted MCP server/cache/consent records. Live stdio
// subprocess lifecycle and tool calls are implemented in MCPSubprocessClient.
//
// Storage layout:
//   <root>/mcp/servers.json            — list of server records
//   <root>/mcp/cache/tools.json        — dict[server_id, {createdAt, tools:[...]}]
//   <root>/mcp/consent/ledger.json     — list of consent records
//
// JSONValue? carries lossy-extras for fields older/newer records may extend.

/// One MCP server registration record written back to `data/mcp/servers.json`.
///
/// Records may carry both `command` (stdio) and `endpoint` (http/native).
/// `extras` preserves any unknown keys round-trip so a Swift writer can't
/// silently strip schema additions made on the Python side.
public struct MCPServer: Sendable, Equatable {
    public var id: String
    public var name: String
    public var transport: String          // "native" | "stdio" | "http"
    public var endpoint: String           // may be empty for stdio
    /// Stdio command line — presence-preserving.
    ///
    /// Byte-compat semantics (verified vs daemon on-disk records, 2026-05-30):
    /// - `nil` means the JSON key was ABSENT. `list_mcp_servers` default
    ///   records omit the field entirely, and
    ///   on-disk `data/mcp/servers.json` confirms it: real records have NO
    ///   `command` key. Parse-then-serialize must round-trip without
    ///   re-introducing the key.
    /// - `Some("")` means the JSON key was PRESENT with an empty string.
    ///   `upsert_mcp_server` always writes
    ///   `command` as a (possibly empty) string. Parse-then-serialize must
    ///   round-trip as `"command": ""`.
    /// - `Some("/bin/foo")` round-trips as `"command": "/bin/foo"`.
    public var command: String?
    public var status: String             // "ready" | "configured" | "needs_setup" | "error" | ...
    public var healthStatus: String       // "ok" | "not_checked" | "needs_setup" | "fail" | ...
    public var toolCount: Int
    public var resourceCount: Int
    public var riskClass: String          // "app_data_read" | "network_read" | "network_localhost" | ...
    public var createdAt: String          // ISO-8601
    public var updatedAt: String          // ISO-8601
    public var extras: JSONValue?         // any extra keys the daemon adds

    public init(
        id: String,
        name: String,
        transport: String,
        endpoint: String,
        command: String? = nil,
        status: String,
        healthStatus: String,
        toolCount: Int,
        resourceCount: Int,
        riskClass: String,
        createdAt: String,
        updatedAt: String,
        extras: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.endpoint = endpoint
        self.command = command
        self.status = status
        self.healthStatus = healthStatus
        self.toolCount = toolCount
        self.resourceCount = resourceCount
        self.riskClass = riskClass
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.extras = extras
    }
}

extension MCPServer {
    /// Known keys this struct claims directly — everything else lands in `extras`.
    static let knownKeys: Set<String> = [
        "id", "name", "transport", "endpoint", "command", "status",
        "healthStatus", "toolCount", "resourceCount", "riskClass",
        "createdAt", "updatedAt",
    ]

    public init?(json: JSONValue) {
        guard case .object(let obj) = json else { return nil }
        func str(_ k: String) -> String {
            if case .string(let s) = obj[k] ?? .null { return s }
            return ""
        }
        func optStr(_ k: String) -> String? {
            if case .string(let s) = obj[k] ?? .null { return s }
            return nil
        }
        func intVal(_ k: String) -> Int {
            switch obj[k] ?? .null {
            case .int(let i): return Int(i)
            case .double(let d): return Int(d)
            default: return 0
            }
        }
        let idStr = str("id")
        if idStr.isEmpty { return nil }
        self.id = idStr
        self.name = str("name")
        self.transport = str("transport")
        self.endpoint = str("endpoint")
        // command: presence-preserving. See struct doc. Missing key → nil
        // (so toJSON omits it). Explicit string → Some(value).
        if case .string(let s) = obj["command"] ?? .null {
            self.command = s
        } else {
            // Either the key is absent, or it's present with a non-string
            // value (defensive — daemon never writes non-string for
            // command). Treat both as "don't re-emit".
            self.command = nil
        }
        self.status = str("status")
        self.healthStatus = str("healthStatus")
        self.toolCount = intVal("toolCount")
        self.resourceCount = intVal("resourceCount")
        self.riskClass = str("riskClass")
        self.createdAt = str("createdAt")
        self.updatedAt = str("updatedAt")
        var extra: [String: JSONValue] = [:]
        for (k, v) in obj where !MCPServer.knownKeys.contains(k) {
            extra[k] = v
        }
        self.extras = extra.isEmpty ? nil : .object(extra)
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "transport": .string(transport),
            "endpoint": .string(endpoint),
            "status": .string(status),
            "healthStatus": .string(healthStatus),
            "toolCount": .int(Int64(toolCount)),
            "resourceCount": .int(Int64(resourceCount)),
            "riskClass": .string(riskClass),
            "createdAt": .string(createdAt),
            "updatedAt": .string(updatedAt),
        ]
        // Presence-preserving emit. nil → omit (matches Python's default-
        // record shape on disk at data/mcp/servers.json — no `command` key).
        if let cmd = command {
            obj["command"] = .string(cmd)
        }
        if case .object(let extra)? = extras {
            for (k, v) in extra where !MCPServer.knownKeys.contains(k) {
                obj[k] = v
            }
        }
        return .object(obj)
    }
}

/// One MCP tool descriptor pulled from `cache/tools.json`. The cache is a
/// dict keyed by server-id; we flatten it to a list and stamp `serverId`
/// onto each entry to keep the cross-server view easy.
public struct MCPTool: Sendable, Equatable {
    public var serverId: String
    public var name: String
    public var description: String?
    public var inputSchema: JSONValue?    // arbitrary JSON Schema dict
    public var riskClass: String?         // optional — older records may not stamp it
    public var cachedAt: String?          // server-level createdAt — when this cache row was written
    public var extras: JSONValue?

    public init(
        serverId: String,
        name: String,
        description: String? = nil,
        inputSchema: JSONValue? = nil,
        riskClass: String? = nil,
        cachedAt: String? = nil,
        extras: JSONValue? = nil
    ) {
        self.serverId = serverId
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.riskClass = riskClass
        self.cachedAt = cachedAt
        self.extras = extras
    }
}

extension MCPTool {
    static let knownKeys: Set<String> = [
        "name", "description", "inputSchema", "riskClass", "risk_class",
    ]
}

/// One row in the consent ledger. Mirrors `grant_mcp_consent`'s output
/// shape exactly (id is "<serverId>:<toolName>"; permissions is a sorted
/// list of permission tokens).
public struct MCPConsent: Sendable, Equatable {
    public var id: String                 // "<serverId>:<toolName>"
    public var serverId: String
    public var toolName: String
    public var scope: String              // "server_tool"
    public var risk: String               // mirrors server.riskClass at grant time
    public var status: String             // "granted" | "revoked"
    public var permissions: [String]      // sorted, de-duped at grant time
    public var argumentSummary: String
    public var grantedAt: String          // ISO-8601
    public var updatedAt: String          // ISO-8601
    public var revokedAt: String?         // ISO-8601 or nil
    public var extras: JSONValue?

    public init(
        id: String,
        serverId: String,
        toolName: String,
        scope: String = "server_tool",
        risk: String,
        status: String,
        permissions: [String] = [],
        argumentSummary: String = "",
        grantedAt: String,
        updatedAt: String,
        revokedAt: String? = nil,
        extras: JSONValue? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.toolName = toolName
        self.scope = scope
        self.risk = risk
        self.status = status
        self.permissions = permissions
        self.argumentSummary = argumentSummary
        self.grantedAt = grantedAt
        self.updatedAt = updatedAt
        self.revokedAt = revokedAt
        self.extras = extras
    }
}

extension MCPConsent {
    static let knownKeys: Set<String> = [
        "id", "serverId", "toolName", "scope", "risk", "status",
        "permissions", "argumentSummary", "grantedAt", "updatedAt",
        "revokedAt",
    ]

    public init?(json: JSONValue) {
        guard case .object(let obj) = json else { return nil }
        func str(_ k: String) -> String {
            if case .string(let s) = obj[k] ?? .null { return s }
            return ""
        }
        func optStr(_ k: String) -> String? {
            if case .string(let s) = obj[k] ?? .null { return s }
            return nil
        }
        let idStr = str("id")
        if idStr.isEmpty { return nil }
        self.id = idStr
        self.serverId = str("serverId")
        self.toolName = str("toolName")
        self.scope = {
            let s = str("scope")
            return s.isEmpty ? "server_tool" : s
        }()
        self.risk = str("risk")
        self.status = str("status")
        var perms: [String] = []
        if case .array(let arr) = obj["permissions"] ?? .null {
            for v in arr {
                if case .string(let s) = v { perms.append(s) }
            }
        }
        self.permissions = perms
        self.argumentSummary = str("argumentSummary")
        self.grantedAt = str("grantedAt")
        self.updatedAt = str("updatedAt")
        self.revokedAt = optStr("revokedAt")
        var extra: [String: JSONValue] = [:]
        for (k, v) in obj where !MCPConsent.knownKeys.contains(k) {
            extra[k] = v
        }
        self.extras = extra.isEmpty ? nil : .object(extra)
    }

    /// Serialize to JSONValue matching the legacy grant_mcp_consent
    /// shape: `permissions` always present (possibly empty), `revokedAt`
    /// always present (explicit null when nil — Python writes None on grant).
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "serverId": .string(serverId),
            "toolName": .string(toolName),
            "scope": .string(scope),
            "risk": .string(risk),
            "status": .string(status),
            "permissions": .array(permissions.map(JSONValue.string)),
            "argumentSummary": .string(argumentSummary),
            "grantedAt": .string(grantedAt),
            "updatedAt": .string(updatedAt),
        ]
        obj["revokedAt"] = revokedAt.map(JSONValue.string) ?? .null
        if case .object(let extra)? = extras {
            for (k, v) in extra where !MCPConsent.knownKeys.contains(k) {
                obj[k] = v
            }
        }
        return .object(obj)
    }
}

/// Input for `grantConsent` — the subset of fields a caller specifies. The
/// implementation fills in `grantedAt`, `updatedAt`, derives `id` from
/// `(serverId, toolName)`, and sorts/dedupes permissions.
public struct MCPConsentGrant: Sendable, Equatable {
    public var serverId: String
    public var toolName: String
    public var scope: String
    public var risk: String
    public var permissions: [String]
    public var argumentSummary: String

    public init(
        serverId: String,
        toolName: String,
        scope: String = "server_tool",
        risk: String,
        permissions: [String] = [],
        argumentSummary: String = "Consent granted from NativeAgent UI/API."
    ) {
        self.serverId = serverId
        self.toolName = toolName
        self.scope = scope
        self.risk = risk
        self.permissions = permissions
        self.argumentSummary = argumentSummary
    }
}

// MARK: - Errors

public enum MCPDispatcherError: Error, Equatable {
    /// Server id was not found.
    case serverNotFound(String)
    /// Consent record not found for revocation.
    case consentNotFound(String)
    /// Caller supplied malformed input.
    case invalidRequest(String)
    /// Storage layer rejected a write or returned a malformed shape.
    case malformedResponse(String)
    /// Legacy transport error case retained for API compatibility.
    case http(status: Int, body: String)
    /// Operation is outside the supported Swift-native surface.
    case unsupported(String)
    /// Legacy transport-level failure case retained for API compatibility.
    case unavailable(underlying: String)
}

// MARK: - Protocol

/// Subsystem #3 — MCP query + consent storage IO.
///
/// Tool execution and live subprocess operations are implemented on
/// `SwiftNativeMCPDispatcher` in `MCPSubprocessClient.swift`; this protocol
/// covers the persisted server, cached tool, and consent surfaces.
public protocol MCPDispatcherProtocol: Sendable {
    /// List configured MCP servers from `<root>/mcp/servers.json`.
    /// Sort: by name ascending (matches `list_mcp_servers`).
    func listServers() async throws -> [MCPServer]

    /// List the cached tools advertised by a server. SwiftNative reads
    /// `<root>/mcp/cache/tools.json` and pulls the entry for `serverId`.
    func listTools(forServer serverId: String) async throws -> [MCPTool]

    /// List consent records, sorted updatedAt DESC (falling back to
    /// grantedAt). SwiftNative reads `<root>/mcp/consent/ledger.json`.
    func listConsents() async throws -> [MCPConsent]

    /// Grant or upsert a consent. SwiftNative writes the ledger directly and
    /// returns the resulting record exactly as persisted.
    @discardableResult
    func grantConsent(_ grant: MCPConsentGrant) async throws -> MCPConsent

    /// Revoke an existing consent by (serverId, toolName). SwiftNative
    /// flips status to "revoked" + stamps revokedAt/updatedAt.
    /// Throws `.consentNotFound` when absent.
    func revokeConsent(serverId: String, toolName: String) async throws
}

// MARK: - SwiftNative implementation

/// File-backed implementation. Reads/writes
///   - `<root>/mcp/servers.json` (READ ONLY here — daemon's
///     list_mcp_servers writes back on every call but doing the same from
///     Swift would race the daemon's defaults-merge logic. Swift's read
///     view is just whatever's on disk now.)
///   - `<root>/mcp/cache/tools.json` (READ ONLY)
///   - `<root>/mcp/consent/ledger.json` (READ + WRITE — grant/revoke)
///
/// Actor-isolated to serialize concurrent grant/revoke R-M-W against the
/// same on-disk ledger. Mirrors ApprovalInbox's reentrancy gate.
public actor SwiftNativeMCPDispatcher: MCPDispatcherProtocol {
    let root: URL
    let persistence: any PersistenceCoreProtocol
    private let clock: @Sendable () -> Date
    /// Serializes mutating ledger ops (grant/revoke) — see ApprovalInbox
    /// for the pattern's rationale.
    private var mutationTail: Task<Void, Never>? = nil

    /// Bug 6 fix (2026-05-31): tiny in-actor TTL cache for `listServers()`.
    /// Previously every `swiftMCPServerIsStdio` lookup did its own
    /// servers.json read, AND the subsequent `listToolsLive` /
    /// `listResourcesLive` call's `ensurePool(for: try await listServers())`
    /// did ANOTHER read for the same request. Now both reads share the
    /// cached result within the TTL window. Single source of truth for
    /// server-list freshness; aligns with MCPLiveCache's TTL pattern.
    private struct _ServersCacheRow: Sendable {
        let storedAt: Date
        let value: [MCPServer]
    }
    private var _serversCacheRow: _ServersCacheRow?
    /// Bug 4 fix (2026-05-31, 3rd-round review): in-flight coalescing for
    /// cold concurrent callers. Previously N concurrent listServers() calls
    /// during a cold window each fired their own disk read. Now the first
    /// caller starts a task, subsequent callers await it — so disk reads ==
    /// 1 per refill window, not N.
    private var _inflightListServers: Task<[MCPServer], Error>?
    /// 60-second TTL by default — same as MCPLiveCache so a server-list
    /// add/remove naturally falls out of cache on the next minute boundary.
    /// Tunable so tests can pin behavior; production stays at 60.
    public var listServersTTL: TimeInterval = 60

    public init(
        root: URL,
        persistence: (any PersistenceCoreProtocol)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.persistence = persistence ?? SwiftNativePersistenceCore()
        self.clock = clock
    }

    /// Test seam — invalidate the listServers cache so a fixture change
    /// is picked up on the next call without waiting out the TTL.
    public func _invalidateListServersCache() {
        _serversCacheRow = nil
        _inflightListServers = nil
    }

    /// Test seam — set TTL from outside (mostly to set it to 0 so the
    /// cache is bypassed entirely in cases where a test wants the legacy
    /// per-call read behavior).
    public func _setListServersTTL(_ seconds: TimeInterval) {
        listServersTTL = seconds
        _serversCacheRow = nil
    }

    // MARK: Paths

    public var serversPath: URL {
        root
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("servers.json")
    }

    /// Path to the research config.
    /// Read to extract `searxng_base_url` for the auto-merged default
    /// `searxng-local` server.
    public var configPath: URL {
        root
            .appendingPathComponent("research", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public var toolsCachePath: URL {
        root
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("tools.json")
    }

    public var consentLedgerPath: URL {
        root
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("consent", isDirectory: true)
            .appendingPathComponent("ledger.json")
    }

    /// Daemon's trace/activity ledger — `<root>/traces/events.jsonl`
    ///. grant/
    /// revoke emit an `mcp.consent.grant` / `mcp.consent.revoke` event here so
    /// the SwiftNative path keeps trace parity with the daemon's
    /// record_trace. W31 W02 — closes the trace-
    /// emission gap gpt-5.5 review flagged on the re-enabled gate.
    public var tracesPath: URL {
        root
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    // MARK: Read paths

    public func listServers() async throws -> [MCPServer] {
        // Bug 6 fix (2026-05-31): consult the in-actor TTL cache before
        // hitting disk. Within `listServersTTL` (default 60s) all callers
        // share the same merged list; saves the 2× servers.json reads
        // that swiftMCPServerIsStdio + ensurePool used to do per request.
        if let row = _serversCacheRow,
           clock().timeIntervalSince(row.storedAt) <= listServersTTL {
            return row.value
        }
        if let inflight = _inflightListServers {
            return try await inflight.value
        }
        let task = Task<[MCPServer], Error> { [weak self] in
            guard let self = self else { return [] }
            return try await self._readServersUncached()
        }
        _inflightListServers = task
        do {
            let result = try await task.value
            _serversCacheRow = _ServersCacheRow(storedAt: clock(), value: result)
            _inflightListServers = nil
            return result
        } catch {
            _inflightListServers = nil
            throw error
        }
    }

    /// Uncached read path — extracted so the cache wrapper above can call
    /// the real logic without inlining a 90-line method.
    private func _readServersUncached() async throws -> [MCPServer] {
        let raw = await persistence.readJSON(serversPath, defaultValue: .array([]))
        let savedRecords: [JSONValue]
        if case .array(let items) = raw { savedRecords = items } else { savedRecords = [] }

        // Read searxng_base_url from the Swift-native research config.
        let configRaw = await persistence.readJSON(configPath, defaultValue: .object([:]))
        var searxngURL = ""
        if case .object(let cfg) = configRaw,
           case .string(let s) = cfg["searxng_base_url"] ?? .null {
            searxngURL = s
        }
        let hasSearx = !searxngURL.isEmpty

        // Mirrors the retired daemon. createdAt/updatedAt use
        // now_iso() (= isoTimestamp here); since the daemon overwrites these
        // fields per call anyway, the freshly-stamped value is byte-compat.
        let stamp = Self.isoTimestamp(clock())
        let internalDefault: [String: JSONValue] = [
            "id": .string("nativeagent-internal"),
            "name": .string("NativeAgent Internal MCP"),
            "transport": .string("native"),
            "endpoint": .string("nativeagent://internal"),
            "status": .string("ready"),
            "healthStatus": .string("ok"),
            "toolCount": .int(3),
            "resourceCount": .int(3),
            "riskClass": .string("app_data_read"),
            "createdAt": .string(stamp),
            "updatedAt": .string(stamp),
        ]
        let searxDefault: [String: JSONValue] = [
            "id": .string("searxng-local"),
            "name": .string("SearXNG Local Search"),
            "transport": .string("http"),
            "endpoint": .string(searxngURL),
            "status": .string(hasSearx ? "ready" : "needs_setup"),
            "healthStatus": .string(hasSearx ? "ok" : "needs_setup"),
            "toolCount": .int(hasSearx ? 2 : 0),
            "resourceCount": .int(0),
            "riskClass": .string("network_read"),
            "createdAt": .string(stamp),
            "updatedAt": .string(stamp),
        ]
        let defaults: [[String: JSONValue]] = [internalDefault, searxDefault]

        // by_id index from saved.
        var byID: [String: [String: JSONValue]] = [:]
        for item in savedRecords {
            guard case .object(let obj) = item else { continue }
            if case .string(let id) = obj["id"] ?? .null {
                byID[id] = obj
            }
        }

        // Build merged defaults, overriding from saved EXCEPT for
        // healthStatus/status/updatedAt.
        let skipKeys: Set<String> = ["healthStatus", "status", "updatedAt"]
        var merged: [JSONValue] = []
        var defaultIDs: Set<String> = []
        for def in defaults {
            guard case .string(let did) = def["id"] ?? .null else { continue }
            defaultIDs.insert(did)
            var record = def
            if let override = byID[did] {
                for (k, v) in override where !skipKeys.contains(k) {
                    record[k] = v
                }
            }
            merged.append(.object(record))
        }

        // Append saved items not in the default id set.
        for item in savedRecords {
            guard case .object(let obj) = item,
                  case .string(let id) = obj["id"] ?? .null else { continue }
            if !defaultIDs.contains(id) {
                merged.append(item)
            }
        }

        let records = merged.compactMap(MCPServer.init(json:))
        // Match list_mcp_servers: sorted by name (fallback id).
        return records.sorted { lhs, rhs in
            let lkey = lhs.name.isEmpty ? lhs.id : lhs.name
            let rkey = rhs.name.isEmpty ? rhs.id : rhs.name
            return lkey < rkey
        }
    }

    public func listTools(forServer serverId: String) async throws -> [MCPTool] {
        let raw = await persistence.readJSON(toolsCachePath, defaultValue: .object([:]))
        guard case .object(let dict) = raw else { return [] }
        guard case .object(let entry) = dict[serverId] ?? .null else { return [] }
        let cachedAt: String? = {
            if case .string(let s) = entry["createdAt"] ?? .null { return s }
            return nil
        }()
        guard case .array(let tools) = entry["tools"] ?? .null else { return [] }
        var out: [MCPTool] = []
        out.reserveCapacity(tools.count)
        for t in tools {
            guard case .object(let tobj) = t else { continue }
            let name: String = {
                if case .string(let s) = tobj["name"] ?? .null { return s }
                return ""
            }()
            if name.isEmpty { continue }
            let desc: String? = {
                if case .string(let s) = tobj["description"] ?? .null { return s }
                return nil
            }()
            let schema: JSONValue? = {
                if case .null = tobj["inputSchema"] ?? .null { return nil }
                return tobj["inputSchema"]
            }()
            let risk: String? = {
                if case .string(let s) = tobj["risk_class"] ?? .null { return s }
                if case .string(let s) = tobj["riskClass"] ?? .null { return s }
                return nil
            }()
            var extra: [String: JSONValue] = [:]
            for (k, v) in tobj where !MCPTool.knownKeys.contains(k) {
                extra[k] = v
            }
            out.append(MCPTool(
                serverId: serverId,
                name: name,
                description: desc,
                inputSchema: schema,
                riskClass: risk,
                cachedAt: cachedAt,
                extras: extra.isEmpty ? nil : .object(extra)
            ))
        }
        return out.sorted { $0.name < $1.name }
    }

    public func listConsents() async throws -> [MCPConsent] {
        let records = try Self.readConsentLedgerChecked(at: consentLedgerPath)
        // Match list_mcp_consent: sorted by updatedAt DESC (fallback grantedAt).
        return records.sorted { lhs, rhs in
            let lkey = lhs.updatedAt.isEmpty ? lhs.grantedAt : lhs.updatedAt
            let rkey = rhs.updatedAt.isEmpty ? rhs.grantedAt : rhs.updatedAt
            return lkey > rkey
        }
    }

    // MARK: Mutating paths

    private func runSerialized<T: Sendable>(
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let prior = mutationTail
        let task = Task<T, Error> {
            _ = await prior?.value
            return try await body()
        }
        mutationTail = Task { _ = try? await task.value }
        return try await task.value
    }

    @discardableResult
    public func grantConsent(_ grant: MCPConsentGrant) async throws -> MCPConsent {
        let record = try await runSerialized { [persistence, consentLedgerPath, clock] in
            try await Self._grantImpl(
                grant: grant,
                persistence: persistence,
                ledgerPath: consentLedgerPath,
                now: clock()
            )
        }
        // Trace parity with the daemon's record_trace,
        // emitted AFTER the locked ledger write — same ordering as Python.
        // Best-effort: a trace-append failure must NOT fail the grant (the
        // daemon's append_jsonl is likewise non-fatal). Mirrors the daemon's
        // payload exactly: {serverId, toolName, status, permissions}.
        await emitConsentTrace(
            kind: "mcp.consent.grant",
            title: "\(grant.serverId):\(grant.toolName)",
            payload: [
                "serverId": .string(grant.serverId),
                "toolName": .string(grant.toolName),
                "status": .string("granted"),
                "permissions": .array(record.permissions.map(JSONValue.string)),
            ],
            now: clock()
        )
        return record
    }

    private static func _grantImpl(
        grant: MCPConsentGrant,
        persistence: any PersistenceCoreProtocol,
        ledgerPath: URL,
        now: Date
    ) async throws -> MCPConsent {
        // W31 W02: the read→modify→write of mcp/consent/ledger.json MUST run
        // inside ONE cross-process flock acquisition. The in-actor `mutationTail`
        // (runSerialized) only serializes calls on a SINGLE dispatcher instance —
        // but NativeClient builds a FRESH SwiftNativeMCPDispatcher per grant/revoke
        // call, and MCP tool execution can auto-grant consent. Without the
        // file lock, two such writers that interleave between this read and this
        // write silently clobber each other (lost updates). Mirrors the daemon's
        // `with file_lock(self.mcp_consent_path)` wrap and the
        // ToolRegistry precedent (ToolRegistry.swift:549). Only the concrete
        // SwiftNativePersistenceCore exposes withFileLock, so the lock branch is
        // gated on that type. In practice the SwiftNative grant/revoke path is
        // only ever reached with a SwiftNativePersistenceCore (the
        // .mcpDispatcher gate routes to HTTP otherwise), so the unlocked
        // fall-through is a defensive no-op rather than a live race.
        let work: @Sendable () async throws -> MCPConsent = {
            let key = "\(grant.serverId):\(grant.toolName)"
            // Authority data is never tolerant: only an absent ledger means
            // empty. Corrupt, malformed, or duplicate rows block the mutation
            // and remain byte-for-byte untouched.
            let kept = try Self.readConsentLedgerChecked(at: ledgerPath)
                .filter { $0.id != key }
                .map { $0.toJSON() }
            let stamp = isoTimestamp(now)
            let perms = Array(Set(grant.permissions)).sorted()
            let summary = String(grant.argumentSummary.prefix(500))
            let record = MCPConsent(
                id: key,
                serverId: grant.serverId,
                toolName: grant.toolName,
                scope: grant.scope.isEmpty ? "server_tool" : grant.scope,
                risk: grant.risk,
                status: "granted",
                permissions: perms,
                argumentSummary: summary,
                grantedAt: stamp,
                updatedAt: stamp,
                revokedAt: nil
            )
            var out: [JSONValue] = [record.toJSON()]
            out.append(contentsOf: kept)
            // Match Python's records[:300] cap.
            if out.count > 300 { out = Array(out.prefix(300)) }
            try await persistence.writeJSON(.array(out), to: ledgerPath)
            return record
        }
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        return try await persistence.withFileLock(ledgerPath, work)
    }

    public func revokeConsent(serverId: String, toolName: String) async throws {
        try await runSerialized { [persistence, consentLedgerPath, clock] in
            try await Self._revokeImpl(
                serverId: serverId,
                toolName: toolName,
                persistence: persistence,
                ledgerPath: consentLedgerPath,
                now: clock()
            )
        }
        // Trace parity with the daemon's record_trace,
        // emitted only AFTER a SUCCESSFUL revoke (a .consentNotFound throw above
        // skips this — matching Python, which raises before record_trace).
        // Daemon payload: {consentId: key, status: "revoked"}.
        let key = "\(serverId):\(toolName)"
        await emitConsentTrace(
            kind: "mcp.consent.revoke",
            title: key,
            payload: [
                "consentId": .string(key),
                "status": .string("revoked"),
            ],
            now: clock()
        )
    }

    /// Append an `mcp.consent.*` event to `<root>/traces/events.jsonl` in the
    /// daemon's record_trace envelope shape ({id, kind, title, status, payload,
    /// createdAt}, the retired daemon). Best-effort: never throws — a trace
    /// write failure must not fail the consent operation (the daemon's
    /// append_jsonl is non-fatal too). One-sided flock around the append as a
    /// cross-process precaution (matches DispatchLedger.append); Python's
    /// append_jsonl is unlocked and relies on POSIX O_APPEND atomicity.
    private func emitConsentTrace(
        kind: String,
        title: String,
        payload: [String: JSONValue],
        now: Date
    ) async {
        // The envelope-level `status` mirrors the daemon's record_trace, which
        // pulls `status` out of the payload (defaulting to "ok").
        var statusStr = "ok"
        if case .string(let s)? = payload["status"] { statusStr = s }
        let event: JSONValue = .object([
            "id": .string(UUID().uuidString),
            "kind": .string(kind),
            "title": .string(title),
            "status": .string(statusStr),
            "payload": .object(payload),
            "createdAt": .string(Self.isoTimestamp(now)),
        ])
        let tracesURL = tracesPath
        let work: @Sendable () async throws -> Void = { [persistence] in
            try await persistence.appendJSONL(event, to: tracesURL)
        }
        do {
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            try await persistence.withFileLock(tracesURL, work)
        } catch {
            // Swallow — trace emission is best-effort, parity-only.
        }
    }

    private static func _revokeImpl(
        serverId: String,
        toolName: String,
        persistence: any PersistenceCoreProtocol,
        ledgerPath: URL,
        now: Date
    ) async throws -> Void {
        // W31 W02: same cross-process flock wrap as _grantImpl — the full
        // read→mutate→write of the ledger runs inside ONE flock acquisition so a
        // concurrent grant (fresh dispatcher instance or daemon auto-grant) can't
        // interleave between our read and our write. See _grantImpl for rationale.
        let work: @Sendable () async throws -> Void = {
            let records = try Self.readConsentLedgerChecked(at: ledgerPath)
            let items = records.map { $0.toJSON() }
            let key = "\(serverId):\(toolName)"
            var mutated: [JSONValue] = items
            var found = false
            let stamp = isoTimestamp(now)
            for (idx, item) in items.enumerated() {
                guard case .object(var obj) = item else { continue }
                if case .string(let id) = obj["id"] ?? .null, id == key {
                    obj["status"] = .string("revoked")
                    obj["revokedAt"] = .string(stamp)
                    obj["updatedAt"] = .string(stamp)
                    mutated[idx] = .object(obj)
                    found = true
                    break
                }
            }
            if !found {
                throw MCPDispatcherError.consentNotFound(key)
            }
            try await persistence.writeJSON(.array(mutated), to: ledgerPath)
        }
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        try await persistence.withFileLock(ledgerPath, work)
    }

    /// Checked authority-store read. General persistence reads intentionally
    /// tolerate missing/corrupt informational projections, but consent is an
    /// authorization ledger: treating unreadable authority as an empty list
    /// would silently change the meaning of the store.
    nonisolated static func readConsentLedgerChecked(at path: URL) throws -> [MCPConsent] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw MCPDispatcherError.unavailable(
                underlying: "MCP consent ledger is unreadable: \(error.localizedDescription)"
            )
        }
        let raw: JSONValue
        do {
            raw = try JSONValue.parse(data)
        } catch {
            throw MCPDispatcherError.malformedResponse("MCP consent ledger contains invalid JSON")
        }
        guard case .array(let items) = raw else {
            throw MCPDispatcherError.malformedResponse("MCP consent ledger must be a JSON array")
        }
        guard items.count <= 300 else {
            throw MCPDispatcherError.malformedResponse("MCP consent ledger exceeds 300 records")
        }

        var records: [MCPConsent] = []
        records.reserveCapacity(items.count)
        var seen = Set<String>()
        for (index, item) in items.enumerated() {
            guard let record = strictConsent(item), seen.insert(record.id).inserted else {
                throw MCPDispatcherError.malformedResponse(
                    "MCP consent ledger has malformed or duplicate row at index \(index)"
                )
            }
            records.append(record)
        }
        return records
    }

    private nonisolated static func strictConsent(_ json: JSONValue) -> MCPConsent? {
        guard case .object(let object) = json,
              let record = MCPConsent(json: json),
              !record.serverId.isEmpty,
              !record.toolName.isEmpty,
              record.id == "\(record.serverId):\(record.toolName)",
              !record.scope.isEmpty,
              !record.risk.isEmpty,
              ["granted", "revoked"].contains(record.status),
              !record.grantedAt.isEmpty,
              !record.updatedAt.isEmpty,
              case .string? = object["argumentSummary"],
              case .string? = object["scope"],
              case .string? = object["risk"],
              case .string? = object["status"],
              case .string? = object["grantedAt"],
              case .string? = object["updatedAt"] else { return nil }
        // Pre-Swift consent rows may omit `permissions`, whose established
        // decode meaning is the safe empty list. If present, the field must be
        // a string array; malformed authority is never compact-mapped away.
        if let permissions = object["permissions"] {
            guard case .array(let values) = permissions,
                  values.allSatisfy({ if case .string = $0 { return true }; return false })
            else { return nil }
        }
        if let revokedAt = object["revokedAt"] {
            switch revokedAt {
            case .null, .string: break
            default: return nil
            }
        }
        return record
    }

    // MARK: Helpers

    /// Match Python's `now_iso()`: ISO-8601 with fractional seconds, `+00:00`
    /// suffix (not `Z`). Shared with ApprovalInbox's stamp format.
    nonisolated static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: date)
        if zulu.hasSuffix("Z") {
            return String(zulu.dropLast()) + "+00:00"
        }
        return zulu
    }

    // MARK: Data root resolution (delegated to PersistenceCore)

    /// Thin delegator to `PersistenceCore.defaultDataRoot()` — single source
    /// of truth for the Python `_resolve_data_root` priority chain. Kept on
    /// the actor for back-compat with the existing factory + tests.
    public nonisolated static func defaultDataRoot() -> URL {
        PersistenceCore.defaultDataRoot()
    }
}

// MARK: - Factory

/// Returns SwiftNative. The SwiftNative path resolves its data root via
/// `SwiftNativeMCPDispatcher.defaultDataRoot()` — callers wanting an
/// in-process or override path should construct it directly.
public func makeMCPDispatcher() -> any MCPDispatcherProtocol {
    let root = SwiftNativeMCPDispatcher.defaultDataRoot()
    return SwiftNativeMCPDispatcher(root: root)
}

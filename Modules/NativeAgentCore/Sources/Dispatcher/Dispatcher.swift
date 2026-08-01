import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

// MARK: - Subsystem #18: Dispatcher infrastructure
//
// Swift-native tool dispatcher.
//
// This module ports the *infrastructure* surrounding the unified tool
// dispatcher: the request-shaping, runId/started_at minting, the response
// decoder, the cross-process flock'd JSONL ledger writer, and the factory.
// It does NOT port the 84 connector
// actions, the policy resolver, the approval flow, or the actual tool
// execution. Each connector action must be registered in LocalConnectorActions
// to run. Missing actions fail closed with a Swift receipt; there is no daemon
// HTTP fallback.
//
// Ledger shape: the daemon writes to `<dataRoot>/traces/events.jsonl` via
// `record_trace(kind, title, payload)`. Each
// dispatch yields ONE event:
//   {
//     "id":        <uuid>,
//     "kind":      "dispatch",
//     "title":     "tool:<toolName>",
//     "status":    "ok"|"failed"|"blocked"|"dry_run"|"pending_approval",
//     "payload":   <trace_event dict>,        # see the retired daemon:_make_trace_event
//     "createdAt": <iso8601>
//   }
// The Swift writer below produces the SAME shape (same key order, same fields,
// `sort_keys=true` JSONL) under the SAME `<dataRoot>/traces/events.jsonl`
// path. Concurrency: Python's `append_jsonl`
// is UNLOCKED — line-atomicity for cross-process appends comes from POSIX
// O_APPEND for sub-PIPE_BUF writes (which a dispatch trace always is). The
// Swift side ADDS a `<path>.lock` flock as a precaution against larger
// payloads and future readers that mutate (matches the ToolRegistry pattern).
//
// The ledger is written directly by Swift for both successful native actions
// and refused/unsupported dispatches.

// MARK: - Wire types

/// Context dict passed to `dispatcher.run()`. Mirrors the
/// `_d_ctx` dict built in the retired daemon. Most fields
/// are opaque pass-throughs that the Swift side does not interpret.
public struct DispatchContext: Sendable {
    public var repoRoot: String
    public var cwd: String
    public var surface: String
    public var sessionId: String
    public var persona: String
    public var activeProvider: String
    /// Open-shape fields the Python dispatcher reads but Swift doesn't
    /// interpret today (file_access, mac_control, scratchpad,
    /// trust_policy_tool_autonomy). Stored as a JSON dict so the wire body
    /// round-trips byte-equivalent to the Python build.
    public var extra: [String: JSONValue]

    public init(
        repoRoot: String,
        cwd: String,
        surface: String,
        sessionId: String,
        persona: String,
        activeProvider: String,
        extra: [String: JSONValue] = [:]
    ) {
        self.repoRoot = repoRoot
        self.cwd = cwd
        self.surface = surface
        self.sessionId = sessionId
        self.persona = persona
        self.activeProvider = activeProvider
        self.extra = extra
    }

    /// Convenience constructor with sensible Mac-app defaults.
    public static func defaultForSurface(_ surface: String, sessionId: String = "") -> DispatchContext {
        DispatchContext(
            repoRoot: "",
            cwd: "",
            surface: surface,
            sessionId: sessionId,
            persona: "",
            activeProvider: "",
            extra: [:]
        )
    }

    /// WAVE 42 W01 (§6.260) — ACTION-NAME-SCOPED file-sandbox context selector
    /// for the in-process `_swiftDispatch` seam (NativeAgentApp/NativeClient.swift).
    ///
    /// REOPEN of WAVE 41 W02 (§6.240-rd2 #1). The §6.220-rd2 #2 fix correctly
    /// built a sandbox-ENGAGING `DispatchContext` (non-empty `repoRoot` +
    /// read-only `file_access` + `_na_data_root`) for the `read_file` /
    /// `file_excerpt` native flips so an absolute path can't escape the sandbox.
    /// A prior implementation computed that need from broad read-tool
    /// availability and then applied the resulting `ctx` to whatever tool the call
    /// dispatched. So when EITHER file flag was ON, a `persona_read` /
    /// `workspace_list` / `time_now` / `persona_list_skills` / `system_info`
    /// dispatch in the SAME process got the sandbox-engaging context instead of
    /// its legacy `defaultForSurface("chat")`. Those non-file actions resolve
    /// their OWN roots (persona/workspace) independently and derive persona root
    /// from `_na_data_root` ONLY in test mode — so a prod `_na_data_root` flips
    /// their persona root from `defaultPersonaRoot()` (`<repo>/persona`) to the
    /// `<dataRoot>/memory` legacy fallback: a behavior change. The fix scopes the
    /// sandbox context to the action name (`read_file` / `file_excerpt`) and its
    /// explicit availability — every other tool keeps `defaultForSurface`.
    ///
    /// Pure (no I/O): the caller passes the resolved `dataRoot` URL (the only
    /// production source is `PersistenceCore.defaultDataRoot()`, which ALWAYS
    /// returns a valid non-empty URL — never nil/empty) and the two flag bools,
    /// so this is unit-testable from DispatcherTests. The sandbox-engaging branch
    /// mirrors the daemon `_d_ctx` for the read-tool dispatch path
    /// (`run_dispatcher_read_tool_action`, the retired daemon): `repo_root`/`cwd`
    /// = the data root's parent (`<repo>/data` → `<repo>`), a READ-ONLY
    /// `file_access` ({"mode":"read_only","sandbox":"read_only"} — NOT "full", so
    /// the sandbox stays ENGAGED), and `_na_data_root` (empty-string guarded —
    /// `fromDispatch` treats "" as falsy) so `isSensitiveDataPath` blocks
    /// OAuth tokens / pairing secrets even though they live under the repo root.
    ///
    /// `dataRoot` is a `URL` (NOT a String) so the parent is computed with the
    /// SAME URL-native `deletingLastPathComponent()` the prior inline code used —
    /// reconstructing a URL from `.path` via `URL(fileURLWithPath:)` would silently
    /// EXPAND a literal leading `~` (the `NATIVE_AGENT_DATA_ROOT` env-var tilde
    /// case `PersistenceCore.defaultDataRoot` deliberately preserves), a parity
    /// break. Because the only caller passes a guaranteed-non-empty URL, the
    /// sandbox branch always yields a NON-empty `repoRoot` → `allowedRoots` is
    /// non-empty → the `FileSystemActions` guard ENGAGES (no empty-roots bypass).
    public static func fileSandboxContextForTool(
        _ tool: String,
        readFileEnabled: Bool,
        fileExcerptEnabled: Bool,
        dataRoot: URL,
        surface: String = "chat",
        sessionId: String = ""
    ) -> DispatchContext {
        // ACTION-NAME-scoped: ONLY the file-system read tools engage the sandbox
        // context, and only when that action is available. Every other action —
        // and an unavailable file tool — keeps the default context and will
        // fail closed unless another Swift registry handles it.
        let toolNeedsSandbox =
            (tool == "read_file" && readFileEnabled) ||
            (tool == "file_excerpt" && fileExcerptEnabled)
        guard toolNeedsSandbox else {
            return .defaultForSurface(surface, sessionId: sessionId)
        }
        // Repo root = parent of the data root, mirroring the daemon's
        // `self.repo_root` (the data dir lives at `<repo>/data`). URL-native parent
        // (NOT `URL(fileURLWithPath: dataRoot.path)`) so a literal `~` survives.
        // This is the sole always-allowed sandbox root.
        let repoRoot = dataRoot.deletingLastPathComponent().path
        var extra: [String: JSONValue] = [
            "file_access": .object([
                "mode": .string("read_only"),
                "sandbox": .string("read_only"),
            ]),
        ]
        // Empty-string guarded — `fromDispatch` treats "" as falsy (Python
        // `_resolve_na_data_root`). `defaultDataRoot()` never yields "" in prod;
        // the guard is defensive for a hand-constructed degenerate URL.
        let dataRootPath = dataRoot.path
        if !dataRootPath.isEmpty {
            extra["_na_data_root"] = .string(dataRootPath)
        }
        return DispatchContext(
            repoRoot: repoRoot,
            cwd: repoRoot,
            surface: surface,
            sessionId: sessionId,
            persona: "",
            activeProvider: "",
            extra: extra
        )
    }
}

/// Best-effort decoded output payload. The Python `Receipt.output` is any
/// JSON value (or null); we capture it as JSONValue so the entire response
/// stays inspectable + Sendable. NOT Codable — built manually from the
/// response dict in `decodeDispatchResult` below to dodge JSONValue's lack
/// of a Codable conformance.
public struct DispatchOutput: Sendable, Equatable {
    public var value: JSONValue
    public init(value: JSONValue) { self.value = value }
}

/// Structured error envelope. Mirrors `Receipt.error`.
public struct DispatchError: Sendable, Equatable {
    public var code: String
    public var message: String
    public var tool: String?
    public var argsHash: String?
    public var recoverable: Bool

    public init(code: String, message: String, tool: String?, argsHash: String?, recoverable: Bool) {
        self.code = code
        self.message = message
        self.tool = tool
        self.argsHash = argsHash
        self.recoverable = recoverable
    }
}

/// Decoded `/v1/dispatch` response. Field-for-field copy of
/// `_receipt_to_response_dict`.
public struct DispatchResult: Sendable, Equatable {
    public var ok: Bool
    public var tool: String
    public var status: String          // "ok"|"failed"|"blocked"|"pending_approval"|"dry_run"
    public var output: DispatchOutput?
    public var error: DispatchError?
    public var executed: Bool
    public var verifyPassed: Bool?
    public var durationUs: Int
    public var durationMs: Int
    public var argsHash: String
    public var effectiveAutonomy: String
    public var autonomySource: String
    public var providerMatch: Bool
    public var traceEventId: String
    public var runId: String
    public var startedAt: String

    public init(
        ok: Bool,
        tool: String,
        status: String,
        output: DispatchOutput?,
        error: DispatchError?,
        executed: Bool,
        verifyPassed: Bool?,
        durationUs: Int,
        durationMs: Int,
        argsHash: String,
        effectiveAutonomy: String,
        autonomySource: String,
        providerMatch: Bool,
        traceEventId: String,
        runId: String,
        startedAt: String
    ) {
        self.ok = ok
        self.tool = tool
        self.status = status
        self.output = output
        self.error = error
        self.executed = executed
        self.verifyPassed = verifyPassed
        self.durationUs = durationUs
        self.durationMs = durationMs
        self.argsHash = argsHash
        self.effectiveAutonomy = effectiveAutonomy
        self.autonomySource = autonomySource
        self.providerMatch = providerMatch
        self.traceEventId = traceEventId
        self.runId = runId
        self.startedAt = startedAt
    }
}

// MARK: - Errors

public enum DispatcherError: Error, LocalizedError, Equatable {
    case missingTool
    case invalidInput(String)
    case unavailable
    case invalidResponse(status: Int, body: String)
    case decodeFailure(String)
    case ledgerFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingTool: return "dispatcher: tool name is required"
        case .invalidInput(let m): return "dispatcher: invalid input: \(m)"
        case .unavailable: return "dispatcher: unavailable"
        case .invalidResponse(let s, let b):
            let truncated = b.count > 200 ? String(b.prefix(200)) + "...(truncated)" : b
            return "dispatcher: native handler returned status \(s): \(truncated)"
        case .decodeFailure(let m): return "dispatcher: decode failed: \(m)"
        case .ledgerFailure(let m): return "dispatcher: ledger write failed: \(m)"
        }
    }
}

// MARK: - Protocol

/// One-method tool dispatch protocol. Both impls implement this.
public protocol DispatcherClient: Sendable {
    func dispatch(
        tool: String,
        input: [String: JSONValue],
        ctx: DispatchContext,
        dryRun: Bool
    ) async throws -> DispatchResult
}

// MARK: - HTTP transport DI

/// Tiny request-execute protocol so tests can inject a stub instead of
/// hitting URLSession. The protocol is intentionally Data-in/Data-out so
/// the impls don't share JSON-shaping responsibility.
public protocol DispatcherHTTPClient: Sendable {
    func postJSON(
        url: URL,
        body: Data,
        timeout: TimeInterval
    ) async throws -> (status: Int, body: Data)
}

/// Production transport using URLSession.shared. Equivalent to
/// `_dispatchRaw` in Sources/NativeAgentApp/NativeClient.swift:4631.
public final class URLSessionDispatcherHTTPClient: DispatcherHTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func postJSON(url: URL, body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw DispatcherError.unavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

// MARK: - Request shaping (shared by both impls)

/// Build the `/v1/dispatch` POST body matching the daemon handler at
/// the retired daemon. Tested directly so request-shape parity
/// stays a tested contract, not an implementation detail.
public func buildDispatchRequestBody(
    tool: String,
    input: [String: JSONValue],
    ctx: DispatchContext,
    dryRun: Bool
) throws -> Data {
    let trimmedTool = tool.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedTool.isEmpty {
        throw DispatcherError.missingTool
    }
    // Python: `if not isinstance(_d_input, dict): 400`. Our typed input is
    // already a dict, but we validate non-emptiness of the key set is OK
    // (zero-key dict is legal — some tools take no args).

    var body: [String: JSONValue] = [:]
    body["tool"]      = .string(trimmedTool)
    body["input"]     = .object(input)
    body["surface"]   = .string(ctx.surface.isEmpty ? "chat" : ctx.surface)
    body["dry_run"]   = .bool(dryRun)
    if !ctx.sessionId.isEmpty { body["session_id"] = .string(ctx.sessionId) }
    if !ctx.persona.isEmpty   { body["persona"]    = .string(ctx.persona) }
    if !ctx.activeProvider.isEmpty {
        body["active_provider"] = .string(ctx.activeProvider)
    }
    if !ctx.repoRoot.isEmpty  { body["repo_root"]  = .string(ctx.repoRoot) }
    if !ctx.cwd.isEmpty       { body["cwd"]        = .string(ctx.cwd) }
    // Merge ctx.extra LAST so callers can override the defaults above (e.g.
    // a test pinning `surface` to a custom token); first-write-wins would
    // surprise the caller more than last-write-wins.
    for (k, v) in ctx.extra { body[k] = v }
    return try JSONValue.object(body).serializedData(pretty: false)
}

// MARK: - Dispatch ledger
//
// Append-only JSONL writer. Each entry is one `record_trace`-shaped envelope
// at `<dataRoot>/traces/events.jsonl`. The Swift side wraps the append in a
// `<path>.lock` flock as a one-sided precaution; Python's `append_jsonl`
// is unlocked and relies on POSIX O_APPEND
// atomicity for sub-PIPE_BUF lines. See the retired daemon for the lock
// surface the Swift side reuses.

public struct DispatchLedgerEntry: Sendable, Equatable {
    public var id: String
    public var kind: String              // always "dispatch"
    public var title: String             // "tool:<name>"
    public var status: String            // "ok"|"failed"|"blocked"|"dry_run"|"pending_approval"
    public var payload: JSONValue        // dispatch trace_event body
    public var createdAt: String

    public init(
        id: String,
        kind: String = "dispatch",
        title: String,
        status: String,
        payload: JSONValue,
        createdAt: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.payload = payload
        self.createdAt = createdAt
    }

    /// Canonical JSONL line (sort_keys=true, ensure_ascii=true, compact).
    /// Matches Python's `json.dumps(event, sort_keys=True)` byte-for-byte.
    public func canonicalJSONLine() throws -> String {
        let obj: [String: JSONValue] = [
            "id":        .string(id),
            "kind":      .string(kind),
            "title":     .string(title),
            "status":    .string(status),
            "payload":   payload,
            "createdAt": .string(createdAt),
        ]
        return try JSONValue.object(obj).serialize(pretty: false)
    }
}

public actor DispatchLedger {
    private let ledgerPath: URL
    private let persistence: any PersistenceCoreProtocol

    public init(ledgerPath: URL, persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()) {
        self.ledgerPath = ledgerPath
        self.persistence = persistence
    }

    public nonisolated static func defaultLedgerPath(
        dataRoot: URL = defaultDataRoot()
    ) -> URL {
        dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl", isDirectory: false)
    }

    public var path: URL { ledgerPath }

    /// Append one dispatch entry. Routed through the shared capped append,
    /// which takes the file lock for EVERY persistence conformer (uniform
    /// locking sweep, 2026-08-01) — injected test persistence included.
    public func append(_ entry: DispatchLedgerEntry) async throws {
        let dir = ledgerPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = entry.payload
        let envelope: [String: JSONValue] = [
            "id":        .string(entry.id),
            "kind":      .string(entry.kind),
            "title":     .string(entry.title),
            "status":    .string(entry.status),
            "payload":   payload,
            "createdAt": .string(entry.createdAt),
        ]
        let record: JSONValue = .object(envelope)
        // A5.5(d): traces/events.jsonl is a MULTI-writer feed. The
        // ProviderRouting LLM adapter and Research trace writer cap it to
        // activityEvents (5000); this dispatch co-writer used to append
        // UNBOUNDED under the same flock. Route through the shared capped
        // append (it takes the same flock) so every co-writer trims to the
        // identical newest-N invariant.
        do {
            try await appendJSONLCapped(
                record,
                to: ledgerPath,
                using: persistence,
                maxLines: JSONLLineCaps.activityEvents,
                logLabel: "DispatchLedger"
            )
        } catch {
            throw DispatcherError.ledgerFailure(error.localizedDescription)
        }
    }

    /// Tail the most recent dispatch entries. Convenience for tests + the
    /// upcoming dispatch debug panel.
    public func tail(limit: Int = 20) async throws -> [DispatchLedgerEntry] {
        let raw = try await persistence.tailJSONL(ledgerPath, limit: limit, maxBytes: 1_048_576)
        var out: [DispatchLedgerEntry] = []
        out.reserveCapacity(raw.count)
        for entry in raw {
            guard case .object(let obj) = entry else { continue }
            guard case .string(let id) = obj["id"] ?? .null else { continue }
            let kind: String = {
                if case .string(let s) = obj["kind"] ?? .null { return s }
                return "dispatch"
            }()
            let title: String = {
                if case .string(let s) = obj["title"] ?? .null { return s }
                return ""
            }()
            let status: String = {
                if case .string(let s) = obj["status"] ?? .null { return s }
                return "ok"
            }()
            let createdAt: String = {
                if case .string(let s) = obj["createdAt"] ?? .null { return s }
                return ""
            }()
            let payload = obj["payload"] ?? .null
            out.append(DispatchLedgerEntry(
                id: id, kind: kind, title: title, status: status,
                payload: payload, createdAt: createdAt
            ))
        }
        return out
    }
}

// MARK: - Helpers

public func dispatcherNowISO(_ date: Date = Date()) -> String {
    // Match Python's `datetime.now(timezone.utc).isoformat()` byte-for-byte.
    // Python emits `YYYY-MM-DDTHH:MM:SS+00:00` when microseconds are zero,
    // and `YYYY-MM-DDTHH:MM:SS.ffffff+00:00` otherwise.
    var cal = Calendar(identifier: .iso8601)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
    let micro = max(0, (comps.nanosecond ?? 0) / 1000)
    let head = String(
        format: "%04d-%02d-%02dT%02d:%02d:%02d",
        comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1,
        comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0
    )
    if micro == 0 {
        return head + "+00:00"
    }
    return head + String(format: ".%06d+00:00", micro)
}

/// SHA-256[:16] of canonical JSON-serialised input. Mirrors
/// `_args_hash` in the retired daemon byte-for-byte (sort_keys=True).
public func dispatcherArgsHash(_ input: [String: JSONValue]) -> String {
    let canonical: String
    do {
        canonical = try JSONValue.object(input).serialize(pretty: false)
    } catch {
        canonical = "{}"
    }
    let bytes = Array(canonical.utf8)
    let hex = _sha256Hex(bytes)
    return String(hex.prefix(16))
}

private func _sha256Hex(_ bytes: [UInt8]) -> String {
    let digest = SHA256.hash(data: Data(bytes))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Monotonic-clock duration helper for native action timing (wave 29 W3).
/// Uses `DispatchTime` so the measurement is immune to wall-clock changes.
enum DispatchClockMonotonic {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func elapsedMicros(since start: UInt64) -> Int {
        let endNs = DispatchTime.now().uptimeNanoseconds
        guard endNs > start else { return 0 }
        return Int((endNs - start) / 1000)
    }
}

// MARK: - SwiftNativeDispatcher
//
// Swift owns request shaping, runId minting, response shaping, native action
// execution, and the ledger. Missing action handlers fail closed; they are not
// proxied to any daemon process.

public actor SwiftNativeDispatcher: DispatcherClient {
    private let ledger: DispatchLedger
    private let clock: @Sendable () -> Date
    private let runIdFactory: @Sendable () -> String
    /// Wave 29 W3: optional native connector-action registry. When present and
    /// it knows the requested tool, dispatch runs the action NATIVELY in Swift
    /// (no HTTP round-trip). Nil means only explicitly registered handlers run;
    /// other tools fail closed.
    private let localActions: LocalConnectorActions?
    /// Resolves the autonomy level ("auto"/"ask"/"never") for a given tool.
    /// When nil the native-action paths fall back to "auto" — preserving the
    /// scaffold behavior. In production wiring this is supplied by the app
    /// layer and reads the live trust policy via TrustCenter.autonomyForTool.
    private let autonomyResolver: (@Sendable (String) async -> String)?

    public init(
        baseURL: URL? = nil,
        http: any DispatcherHTTPClient = URLSessionDispatcherHTTPClient(),
        timeout: TimeInterval = 60,
        ledger: DispatchLedger? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        runIdFactory: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        localActions: LocalConnectorActions? = nil,
        autonomyResolver: (@Sendable (String) async -> String)? = nil
    ) {
        _ = baseURL
        _ = http
        _ = timeout
        self.ledger = ledger ?? DispatchLedger(ledgerPath: DispatchLedger.defaultLedgerPath())
        self.clock = clock
        self.runIdFactory = runIdFactory
        self.localActions = localActions
        self.autonomyResolver = autonomyResolver
    }

    public func dispatch(
        tool: String,
        input: [String: JSONValue],
        ctx: DispatchContext,
        dryRun: Bool
    ) async throws -> DispatchResult {
        // 1. Request-shape validation — explicit, surfaces clear errors before
        //    we touch the network.
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Write a failed ledger entry first so the dispatch attempt is
            // visible even when the input is malformed.
            await tryWriteLedger(
                runId: runIdFactory(),
                tool: trimmed,
                status: "failed",
                executed: false,
                ctx: ctx,
                input: input,
                error: DispatchError(
                    code: "invalid_input",
                    message: "tool name is required",
                    tool: nil,
                    argsHash: dispatcherArgsHash(input),
                    recoverable: false
                )
            )
            throw DispatcherError.missingTool
        }

        let runId = runIdFactory()
        let startedAt = dispatcherNowISO(clock())
        do {
            _ = try buildDispatchRequestBody(
                tool: trimmed, input: input, ctx: ctx, dryRun: dryRun
            )
        } catch {
            await tryWriteLedger(
                runId: runId,
                tool: trimmed,
                status: "failed",
                executed: false,
                ctx: ctx,
                input: input,
                error: DispatchError(
                    code: "invalid_input",
                    message: error.localizedDescription,
                    tool: trimmed,
                    argsHash: dispatcherArgsHash(input),
                    recoverable: false
                ),
                startedAt: startedAt,
                runIdOverride: runId
            )
            throw error
        }

        // 1b. NATIVE execution (wave 29 W3). If a local connector-action
        //     registry is wired AND knows this tool, run it in-process and
        //     skip the HTTP round-trip. Still writes the client-side ledger
        //     entry.
        if let actions = localActions, actions.canHandle(trimmed) {
            return await runNativeAction(
                actions: actions,
                tool: trimmed,
                input: input,
                ctx: ctx,
                dryRun: dryRun,
                runId: runId,
                startedAt: startedAt
            )
        }

        let argsHash = dispatcherArgsHash(input)
        let err = DispatchError(
            code: "native_handler_missing",
            message: "No Swift-native handler for tool '\(trimmed)'",
            tool: trimmed,
            argsHash: argsHash,
            recoverable: false
        )
        await tryWriteLedger(
            runId: runId,
            tool: trimmed,
            status: "failed",
            executed: false,
            ctx: ctx,
            input: input,
            error: err,
            startedAt: startedAt,
            runIdOverride: runId,
            argsHashOverride: argsHash,
            effectiveAutonomy: "never",
            autonomySource: "native_handler_missing",
            providerMatch: false
        )
        return DispatchResult(
            ok: false,
            tool: trimmed,
            status: "failed",
            output: nil,
            error: err,
            executed: false,
            verifyPassed: nil,
            durationUs: 0,
            durationMs: 0,
            argsHash: argsHash,
            effectiveAutonomy: "never",
            autonomySource: "native_handler_missing",
            providerMatch: false,
            traceEventId: "",
            runId: runId,
            startedAt: startedAt
        )
    }

    /// Wave 29 W3: run a connector action natively and shape its result into a
    /// DispatchResult, writing the client-side ledger entry. Mirrors the
    /// daemon's receipt construction for these tools: a result dict with
    /// `ok=false` + `error_code` becomes status="failed" + a structured error;
    /// otherwise status="ok". Side-effecting tools (write_file) are NOT executed
    /// on dry_run — they return status="dry_run" / executed=false.
    /// Map the trust-policy autonomy vocabulary to the dispatcher's three
    /// internal levels — "auto" (execute), "ask" (queue for approval), "never"
    /// (block) — mirroring `AutonomyGate.map`. Unknown levels FAIL CLOSED to
    /// "ask" (require approval), never to "auto". This is the single source of
    /// truth for the resolver path; keep it in sync with AutonomyGate.map.
    static func normalizeDispatchAutonomy(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "auto", "app_data_autonomous", "workspace_autonomous":
            return "auto"
        case "ask", "supervised", "confirm", "send_approval":
            return "ask"
        case "never", "deny", "blocked":
            return "never"
        default:
            // Unknown level — safe default (matches AutonomyGate.map). Better an
            // unnecessary approval prompt than a silent auto-execute.
            return "ask"
        }
    }

    private func runNativeAction(
        actions: LocalConnectorActions,
        tool: String,
        input: [String: JSONValue],
        ctx: DispatchContext,
        dryRun: Bool,
        runId: String,
        startedAt: String
    ) async -> DispatchResult {
        let connectorCtx = ConnectorActionContext.fromDispatch(ctx)
        let argsHash = dispatcherArgsHash(input)

        // Resolve the per-tool autonomy from the trust policy. Without a
        // resolver wired we keep the legacy scaffold default ("auto") so
        // existing test wiring stays green; with one we gate execution on
        // the policy decision.
        let resolvedAutonomy: String = {
            switch tool {
            default: return "auto"
            }
        }()
        let effective: String
        let autonomySource: String
        if let resolver = autonomyResolver {
            let v = await resolver(tool).trimmingCharacters(in: .whitespaces).lowercased()
            // A4 fix (loop-A, 2026-06-13): translate the FULL trust-policy
            // autonomy vocabulary to the dispatcher's three internal levels,
            // MIRRORING AutonomyGate.map so the two gates agree on direction.
            // The old `switch v { case auto/ask/never; default: resolvedAutonomy }`
            // fail-OPENed every other level (confirm/supervised/deny/blocked/
            // send_approval — all of which the live trust policy actually emits)
            // to the "auto" scaffold default, i.e. EXECUTE. Unknown now fails
            // CLOSED to "ask" (require approval), matching AutonomyGate's safe
            // default; the rest of the system fails closed on unknown, so this
            // removes the one gate that disagreed.
            effective = Self.normalizeDispatchAutonomy(v)
            autonomySource = "trust_policy"
        } else {
            // A4b guard (loop-A, 2026-06-14): with no trust resolver wired, a
            // read-only tool keeps the legacy "auto" scaffold default (it's
            // side-effect-free), but a SIDE-EFFECTING tool FAILS CLOSED to "ask"
            // rather than silently auto-executing with no trust check. The
            // native-action registry is read-only-only today, so this changes
            // nothing now — it trips the moment a side-effecting action is
            // registered without first wiring a resolver, instead of shipping a
            // silent auto-execute. (A4 closed the resolver path; this closes the
            // no-resolver path.)
            effective = actions.isSideEffecting(tool) ? "ask" : resolvedAutonomy
            autonomySource = "native"
        }

        // 'never' — refuse outright; do not execute, do not queue.
        if effective == "never" && !dryRun {
            let err = DispatchError(
                code: "tool_blocked",
                message: "tool '\(tool)' is blocked by trust policy (effectiveAutonomy=never)",
                tool: tool,
                argsHash: argsHash,
                recoverable: false
            )
            await tryWriteLedger(
                runId: runId, tool: tool, status: "blocked", executed: false,
                ctx: ctx, input: input, error: err,
                startedAt: startedAt, runIdOverride: runId, argsHashOverride: argsHash,
                effectiveAutonomy: effective, autonomySource: autonomySource
            )
            return DispatchResult(
                ok: false, tool: tool, status: "blocked", output: nil, error: err,
                executed: false, verifyPassed: nil, durationUs: 0, durationMs: 0,
                argsHash: argsHash, effectiveAutonomy: effective, autonomySource: autonomySource,
                providerMatch: true, traceEventId: "", runId: runId, startedAt: startedAt
            )
        }

        // 'ask' — queue for approval; do not execute. The approval inbox
        // owns the queued record; we return a pending receipt the caller
        // can poll on. The actual enqueue lives behind the approval flow
        // wired by the app layer; here we surface the gate decision so the
        // caller never silently executes.
        if effective == "ask" && !dryRun {
            await tryWriteLedger(
                runId: runId, tool: tool, status: "pending_approval", executed: false,
                ctx: ctx, input: input, error: nil,
                startedAt: startedAt, runIdOverride: runId, argsHashOverride: argsHash,
                effectiveAutonomy: effective, autonomySource: autonomySource
            )
            return DispatchResult(
                ok: false, tool: tool, status: "pending_approval", output: nil, error: nil,
                executed: false, verifyPassed: nil, durationUs: 0, durationMs: 0,
                argsHash: argsHash, effectiveAutonomy: effective, autonomySource: autonomySource,
                providerMatch: true, traceEventId: "", runId: runId, startedAt: startedAt
            )
        }

        // §6.30 prereq #8 (dry-run uniformity) — wave 36 W11. The Python
        // `Dispatcher.run` short-circuits dry_run for ALL tools BEFORE the
        // handler executes (the retired daemon — status="dry_run",
        // executed=False, output=None), not just side-effecting ones. The
        // original native guard only skipped execution for side-effecting tools,
        // so a read-only native tool would EXECUTE on a dry-run — diverging from
        // Python. Skip execution for EVERY native tool on dry_run, matching the
        // daemon's uniform short-circuit. (output=None mirrors the daemon's
        // dry_run receipt; the prior side-effecting branch already returned nil.)
        if dryRun {
            await tryWriteLedger(
                runId: runId, tool: tool, status: "dry_run", executed: false,
                ctx: ctx, input: input, error: nil,
                startedAt: startedAt, runIdOverride: runId, argsHashOverride: argsHash,
                effectiveAutonomy: effective, autonomySource: autonomySource
            )
            return DispatchResult(
                ok: true, tool: tool, status: "dry_run", output: nil, error: nil,
                executed: false, verifyPassed: nil, durationUs: 0, durationMs: 0,
                argsHash: argsHash, effectiveAutonomy: effective, autonomySource: autonomySource,
                providerMatch: true, traceEventId: "", runId: runId, startedAt: startedAt
            )
        }

        let t0 = DispatchClockMonotonic.now()
        let raw = actions.run(tool, input: input, ctx: connectorCtx) ?? .object([
            "ok": .bool(false), "error": .string("native handler returned nil"),
        ])
        let elapsedUs = DispatchClockMonotonic.elapsedMicros(since: t0)

        // Interpret the native result dict's ok/error_code.
        var resultOK = true
        var errorCode: String? = nil
        var errorMessage = ""
        if case .object(let obj) = raw {
            if case .bool(let b)? = obj["ok"] { resultOK = b }
            // §6.180 (wave 38 W04) — daemon parity: respect the tool's OWN
            // error_code only when it supplies a NON-EMPTY one. The daemon's
            // failed-handler branch uses a
            // TRUTHY guard — `str(result.get("error_code")) if ... result.get
            // ("error_code") else ErrorCode.handler_raised.value` — so an
            // absent OR empty-string error_code both fall through to the
            // default. A plain `if case .string(let s)?` would have captured
            // an empty "" as a non-nil code, then `errorCode ?? default`
            // would keep "" instead of the default — diverging from Python.
            if case .string(let s)? = obj["error_code"], !s.isEmpty { errorCode = s }
            if case .string(let s)? = obj["error"] { errorMessage = s }
        }

        // Receipt parity (gpt-5.5 review, verified against the retired daemon
        // L1376-1423): a handler that RAN and returned a failed dict is
        // status="failed", executed=True, output=result. Only pre-execution
        // rejects (unknown tool / dry_run skip) are executed=False. These
        // native handlers do their own input/sandbox validation INSIDE the
        // handler, so reaching here means the handler executed — executed=true
        // regardless of ok, and the raw result is always attached as output.
        let status: String
        let dispatchError: DispatchError?
        let executed = true
        // §6.30 prereq #9 (verify-write semantics) — wave 36 W11. The daemon
        // sets verify_passed=True for Tool.TRIVIAL_VERIFY read-only tools on a
        // SUCCESSFUL run, and leaves it None for a
        // failed handler return (every failure branch passes verify_passed=None,
        // the retired daemon/1445). Mirror that: verifyPassed=true ONLY
        // when the action is registered TRIVIAL_VERIFY AND it returned ok; nil
        // otherwise (failed run, or a non-TRIVIAL_VERIFY tool — daemon's
        // _DEFAULT_VERIFY read-only tools emit None too). Side-effecting tools
        // never reach this success-path natively on the flip seam (no
        // side-effecting tool is in a flipped registry), so their real
        // verify-on-effect stays server-side.
        let verifyPassed: Bool?
        if resultOK {
            status = "ok"
            dispatchError = nil
            verifyPassed = actions.isTrivialVerify(tool) ? true : nil
        } else {
            status = "failed"
            verifyPassed = nil
            // §6.159 (wave 37 W06) — first-live-flip parity fix. The daemon's
            // failed-handler-return receipt sets recoverable=TRUE
            //`),
            // NOT false. That branch is the EXACT path this native code mirrors: a
            // handler that RAN (executed=true, above) and returned a dict with
            // ok=False — including persona_read's own graceful failures
            // (`bad_input` on an unknown kind, `persona_not_found` on a missing
            // file). The daemon's only recoverable=FALSE error envelopes are the
            // PRE-EXECUTION rejects (tool_unknown:1146 / provider_unsupported:1184 /
            // tool_blocked:1217), all executed=FALSE — none of which this branch can
            // reach (native canHandle() gates tool_unknown; provider/autonomy gating
            // stays server-side; this branch is reached only AFTER the handler ran).
            // Hardcoding false here meant the persona_read native flip — LIVE behind
            // .dispatchPersonaRead via LocalConnectorActions.personaReadOnly — emitted
            // a non-recoverable receipt for a failure the daemon marks recoverable, a
            // real divergence the LLM/UI sees when the flag flips. Match the daemon:
            // a handler that executed and failed is recoverable=true.
            // §6.158 #6 fix (wave 37 W08): a handler that RAN and returned a
            // failed dict must report recoverable=TRUE — the daemon's
            // failed-handler branch sets recoverable=True (the retired daemon
            // L1427), so the model gets a retryable error it can recover from.
            // The W36-W11 persona_read flip hard-coded `false` here, diverging
            // from the daemon on every native failure (e.g. persona_not_found,
            // workspace_list path_not_allowed); both flipped read-only actions
            // traverse THIS shared branch. Pre-execution rejects (unknown tool
            // at L603/629, transport failures) keep their own `false`/`status>=500`
            // recoverability — this only governs the handler-ran-then-failed case
            // that mirrors the daemon's L1410-1428 path.
            // §6.180 (wave 38 W04) — daemon parity fix. The daemon's
            // failed-handler-return branch defaults to ErrorCode.handler_raised
            // ("handler_raised"), NOT "tool_error", when the tool supplies no
            // error_code of its own. The W08
            // workspace_list flip surfaced the divergence: its NotADirectory
            // catch (PersonaSystemActions.swift:439-444) returns {ok:false}
            // with NO error_code, so this branch hit "tool_error" natively
            // while the daemon emits "handler_raised" — a code consumers
            // pattern-match on. Match the daemon default.
            // §6.180 (wave 38 W07) — CLOSES §6.179 #4 (error_code parity). The
            // daemon's failed-handler-return branch
            // respects the handler's OWN `error_code` when present, else defaults to
            // `ErrorCode.handler_raised.value` (= "handler_raised"). The Swift seam
            // here previously defaulted a missing error_code to "tool_error" — a
            // real divergence the consumer sees on any native failure dict that
            // omits error_code (e.g. workspace_list's `contentsOfDirectory` catch
            // branch returns `{ok:false, error:str(exc)}` with NO error_code). Match
            // the daemon: default to "handler_raised". `time_now` (this wave's flip)
            // always sets error_code="bad_input" on its only failure branch, so it
            // never hits the default — but this is the SHARED branch every flipped
            // read-only action traverses, so the fix lands once here for all of them.
            dispatchError = DispatchError(
                code: errorCode ?? "handler_raised",
                message: errorMessage.isEmpty ? "native action failed" : errorMessage,
                tool: tool,
                argsHash: argsHash,
                recoverable: true
            )
        }

        let durationMs = Int((Double(elapsedUs) / 1000.0).rounded())
        await tryWriteLedger(
            runId: runId, tool: tool, status: status, executed: executed,
            ctx: ctx, input: input, error: dispatchError,
            startedAt: startedAt, runIdOverride: runId, argsHashOverride: argsHash,
            durationMs: durationMs, durationUs: elapsedUs,
            effectiveAutonomy: effective, autonomySource: autonomySource,
            verifyPassed: verifyPassed
        )

        return DispatchResult(
            ok: resultOK,
            tool: tool,
            status: status,
            // Python attaches output=result even on a failed handler return
            //, so the failure detail stays
            // inspectable. Mirror that — always attach the raw result.
            output: DispatchOutput(value: raw),
            error: dispatchError,
            executed: executed,
            verifyPassed: verifyPassed,
            durationUs: elapsedUs,
            durationMs: durationMs,
            argsHash: argsHash,
            effectiveAutonomy: effective,
            autonomySource: autonomySource,
            providerMatch: true,
            traceEventId: "",
            runId: runId,
            startedAt: startedAt
        )
    }

    /// Build + write a ledger entry. Failures are swallowed (matches Python's
    /// `_record_trace` swallowing in the retired daemon) because a
    /// trace failure must not break the call that produced the trace.
    private func tryWriteLedger(
        runId: String,
        tool: String,
        status: String,
        executed: Bool,
        ctx: DispatchContext,
        input: [String: JSONValue],
        error: DispatchError?,
        startedAt: String? = nil,
        runIdOverride: String? = nil,
        argsHashOverride: String? = nil,
        durationMs: Int = 0,
        durationUs: Int = 0,
        effectiveAutonomy: String = "",
        autonomySource: String = "",
        providerMatch: Bool = true,
        verifyPassed: Bool? = nil
    ) async {
        do {
            let createdAt = startedAt ?? dispatcherNowISO(clock())
            let argsHash = argsHashOverride ?? dispatcherArgsHash(input)
            var payload: [String: JSONValue] = [
                "id":                 .string(UUID().uuidString.lowercased()),
                "kind":               .string("dispatch"),
                "tool":               .string(tool),
                "surface":            .string(ctx.surface),
                "persona":            .string(ctx.persona),
                "run_id":             .string(runIdOverride ?? runId),
                "input_summary":      .string(truncateForTrace(.object(input))),
                "args_hash":          .string(argsHash),
                "status":             .string(status),
                "verify_passed":      verifyPassed.map { JSONValue.bool($0) } ?? .null,
                "duration_ms":        .int(Int64(durationMs)),
                "duration_us":        .int(Int64(durationUs)),
                "effective_autonomy": effectiveAutonomy.isEmpty ? .null : .string(effectiveAutonomy),
                "autonomy_source":    autonomySource.isEmpty ? .null : .string(autonomySource),
                "provider_match":     .bool(providerMatch),
                "error":              .null,
                "createdAt":          .string(createdAt),
                // Swift-emitted ledger marker — lets a reader tell at a glance
                // that the row came from the Swift dispatcher, not Python.
                // The daemon's own entries don't carry this key, so callers
                // can correlate two-entry-per-runId rows reliably.
                "emitted_by":         .string("swift_dispatcher"),
            ]
            if let err = error {
                payload["error"] = .object([
                    "code":        .string(err.code),
                    "message":     .string(err.message),
                    "tool":        .string(err.tool ?? tool),
                    "args_hash":   .string(err.argsHash ?? argsHash),
                    "recoverable": .bool(err.recoverable),
                ])
                payload["executed"] = .bool(executed)
            } else {
                payload["executed"] = .bool(executed)
            }
            let entry = DispatchLedgerEntry(
                id: UUID().uuidString.lowercased(),
                title: "tool:\(tool)",
                status: status,
                payload: .object(payload),
                createdAt: createdAt
            )
            try await ledger.append(entry)
        } catch {
            // Swallow — never let ledger IO break the dispatch path.
        }
    }
}

/// Best-effort string truncation matching `_truncate_for_trace`
///.
private func truncateForTrace(_ value: JSONValue, maxChars: Int = 200) -> String {
    let s = (try? value.serialize(pretty: false)) ?? "{}"
    if s.count <= maxChars { return s }
    return String(s.prefix(maxChars)) + "...(truncated)"
}

// MARK: - Factory

/// Swift-native dispatcher factory. `baseURL` and `http` are retained only for
/// source compatibility with older callers; they are ignored.
///
/// 2026-07-21 audit (pending_approval dead-end): the dispatch-time A4b guard
/// resolves a SIDE-EFFECTING action with no autonomy resolver to "ask" and
/// returns status="pending_approval" — but NO approval record is staged
/// anywhere and this factory historically couldn't even accept a resolver, so
/// the dispatch queued into the void (latent only because every production
/// registry is read-only). This factory is the production registration seam,
/// so the fail-closed guard lives HERE: registering a side-effecting action
/// without wiring an `autonomyResolver` REFUSES the registration — the
/// side-effecting handlers are stripped (a dispatch then fails HONESTLY with
/// native_handler_missing instead of dead-ending on an unapprovable
/// pending_approval) and a stderr line names the refused tools. Read-only
/// actions pass through exactly as today; a resolver-wired factory keeps the
/// full registry. Direct `SwiftNativeDispatcher` construction is deliberately
/// unguarded so the dispatch-time A4b guard (and its pin test) stays intact.
public func makeDispatcher(
    http: any DispatcherHTTPClient = URLSessionDispatcherHTTPClient(),
    baseURL: URL? = nil,
    ledger: DispatchLedger? = nil,
    // Nil keeps this dispatcher fail-closed for every tool. Production callers
    // pass the concrete Swift registry they want to expose.
    localActions: LocalConnectorActions? = nil,
    // Resolves the trust-policy autonomy level for a tool. REQUIRED when the
    // registry carries any side-effecting action (see the guard above).
    autonomyResolver: (@Sendable (String) async -> String)? = nil
) -> any DispatcherClient {
    var actions = localActions
    if let registry = localActions, autonomyResolver == nil {
        let refused = registry.toolNames.filter { registry.isSideEffecting($0) }.sorted()
        if !refused.isEmpty {
            FileHandle.standardError.write(Data((
                "makeDispatcher: refusing side-effecting action(s) registered without an autonomyResolver "
                + "(unapprovable pending_approval dead-end): \(refused.joined(separator: ", "))\n"
            ).utf8))
            var handlers: [String: ConnectorActionHandler] = [:]
            var trivialVerify: Set<String> = []
            for name in registry.toolNames where !registry.isSideEffecting(name) {
                handlers[name] = { input, ctx in registry.run(name, input: input, ctx: ctx) ?? .null }
                if registry.isTrivialVerify(name) { trivialVerify.insert(name) }
            }
            actions = LocalConnectorActions(
                handlers: handlers,
                sideEffecting: [],
                trivialVerify: trivialVerify
            )
        }
    }
    return SwiftNativeDispatcher(
        baseURL: baseURL,
        http: http,
        ledger: ledger,
        localActions: actions,
        autonomyResolver: autonomyResolver
    )
}

// MARK: - Manual JSONValue-based decoder for DispatchResult
//
// DispatchOutput is not Codable (intentionally — JSONValue lives in
// PersistenceCore and we don't want to pull a Codable conformance into it
// just for this use). So we parse the response bytes via `JSONValue.parse`
// and pattern-match each field. Snake_case keys match
// `_receipt_to_response_dict`.

public func decodeDispatchResult(from data: Data) throws -> DispatchResult {
    let root: JSONValue
    do {
        root = try JSONValue.parse(data)
    } catch {
        throw DispatcherError.decodeFailure("not valid JSON: \(error.localizedDescription)")
    }
    guard case .object(let obj) = root else {
        throw DispatcherError.decodeFailure("expected top-level JSON object")
    }

    func string(_ key: String, default def: String = "") -> String {
        if case .string(let s) = obj[key] ?? .null { return s }
        return def
    }
    func requiredString(_ key: String) throws -> String {
        if case .string(let s) = obj[key] ?? .null { return s }
        throw DispatcherError.decodeFailure("missing or non-string field '\(key)'")
    }
    func bool(_ key: String, default def: Bool) -> Bool {
        if case .bool(let b) = obj[key] ?? .null { return b }
        return def
    }
    func optBool(_ key: String) -> Bool? {
        switch obj[key] ?? .null {
        case .bool(let b): return b
        case .null: return nil
        default: return nil
        }
    }
    func int(_ key: String, default def: Int = 0) -> Int {
        switch obj[key] ?? .null {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return def
        }
    }

    let ok = bool("ok", default: false)
    let tool = try requiredString("tool")
    let status = try requiredString("status")
    let executed = bool("executed", default: false)
    let verifyPassed = optBool("verify_passed")
    let durationUs = int("duration_us", default: 0)
    let durationMs = int("duration_ms", default: 0)
    let argsHash = string("args_hash", default: "")
    let effectiveAutonomy = string("effective_autonomy", default: "")
    let autonomySource = string("autonomy_source", default: "")
    let providerMatch = bool("provider_match", default: true)
    let traceEventId = string("trace_event_id", default: "")
    let runId = string("run_id", default: "")
    let startedAt = string("started_at", default: "")

    let output: DispatchOutput?
    switch obj["output"] ?? .null {
    case .null:
        output = nil
    case let v:
        output = DispatchOutput(value: v)
    }

    let error: DispatchError?
    switch obj["error"] ?? .null {
    case .object(let eobj):
        var code = ""
        if case .string(let s) = eobj["code"] ?? .null { code = s }
        var message = ""
        if case .string(let s) = eobj["message"] ?? .null { message = s }
        var etool: String? = nil
        if case .string(let s) = eobj["tool"] ?? .null { etool = s }
        var eHash: String? = nil
        if case .string(let s) = eobj["args_hash"] ?? .null { eHash = s }
        var recoverable = false
        if case .bool(let b) = eobj["recoverable"] ?? .null { recoverable = b }
        error = DispatchError(
            code: code,
            message: message,
            tool: etool,
            argsHash: eHash,
            recoverable: recoverable
        )
    default:
        error = nil
    }

    return DispatchResult(
        ok: ok,
        tool: tool,
        status: status,
        output: output,
        error: error,
        executed: executed,
        verifyPassed: verifyPassed,
        durationUs: durationUs,
        durationMs: durationMs,
        argsHash: argsHash,
        effectiveAutonomy: effectiveAutonomy,
        autonomySource: autonomySource,
        providerMatch: providerMatch,
        traceEventId: traceEventId,
        runId: runId,
        startedAt: startedAt
    )
}

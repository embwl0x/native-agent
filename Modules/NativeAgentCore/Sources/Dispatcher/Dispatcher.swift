import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

// MARK: - Native dispatcher infrastructure
//
// Shapes requests and receipts, applies autonomy decisions and writes the
// flock-protected dispatch ledger at <dataRoot>/traces/events.jsonl.
// NativeActionDispatch supplies the shipped read-only connector handlers.
// Missing handlers fail closed with a Swift receipt; no daemon HTTP fallback.

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

}

/// Native output payload, kept as JSONValue so the entire response stays
/// inspectable and Sendable.
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
        do {
            try await appendPathOwnedJSONL(
                record,
                to: ledgerPath,
                using: persistence,
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
    /// Runs registered connector actions in-process. Nil or missing handlers
    /// fail closed; production callers supply NativeActionDispatch's registry.
    private let localActions: LocalConnectorActions?
    private let timeout: TimeInterval
    /// Resolves the autonomy level ("auto"/"ask"/"never") for a given tool.
    /// Without a resolver, read-only handlers are automatic and side-effecting
    /// registrations are refused by makeDispatcher.
    private let autonomyResolver: (@Sendable (String) async -> String)?

    public init(
        timeout: TimeInterval = 60,
        ledger: DispatchLedger? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        runIdFactory: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        localActions: LocalConnectorActions? = nil,
        autonomyResolver: (@Sendable (String) async -> String)? = nil
    ) {
        self.timeout = timeout
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

        let resolvedAutonomy = "auto"
        let effective: String
        let autonomySource: String
        if let resolver = autonomyResolver {
            let v = await resolver(tool).trimmingCharacters(in: .whitespaces).lowercased()
            // Match AutonomyGate's vocabulary; unknown levels require approval.
            effective = Self.normalizeDispatchAutonomy(v)
            autonomySource = "trust_policy"
        } else {
            // Without a resolver, only read-only tools may execute automatically.
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
        let raw: JSONValue
        if ["read_file", "file_excerpt", "list_dir"].contains(tool), !actions.isSideEffecting(tool) {
            let imageSink = LocalToolImage.sink
            // Folder permission prompts and unavailable volumes can block even
            // metadata reads. Keep them off the caller's executor; BoundedWait
            // can abandon a read without waiting for that syscall to return.
            do {
                raw = try await BoundedWait.run(seconds: timeout, reason: "file read") {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            LocalToolImage.$sink.withValue(imageSink) {
                                continuation.resume(returning: actions.run(tool, input: input, ctx: connectorCtx) ?? .object([
                                    "ok": .bool(false), "error": .string("native handler returned nil"),
                                ]))
                            }
                        }
                    }
                }
            } catch {
                raw = .object([
                    "ok": .bool(false),
                    "error_code": .string(error is CancellationError ? "cancelled" : "timeout"),
                    "error": .string(error is CancellationError
                        ? "I stopped waiting for the files."
                        : "I couldn’t read the files in time. Check folder access and whether the drive is available."),
                ])
            }
        } else {
            raw = actions.run(tool, input: input, ctx: connectorCtx) ?? .object([
                "ok": .bool(false), "error": .string("native handler returned nil"),
            ])
        }
        let elapsedUs = DispatchClockMonotonic.elapsedMicros(since: t0)

        // Interpret the native result dict's ok/error_code.
        var resultOK = true
        var errorCode: String? = nil
        var errorMessage = ""
        if case .object(let obj) = raw {
            if case .bool(let b)? = obj["ok"] { resultOK = b }
            // Missing or empty handler error codes use the dispatch default.
            if case .string(let s)? = obj["error_code"], !s.isEmpty { errorCode = s }
            if case .string(let s)? = obj["error"] { errorMessage = s }
        }

        // A handler that ran remains executed even when its own validation failed;
        // retain its raw output. Only pre-execution rejects are executed=false.
        let status: String
        let dispatchError: DispatchError?
        let executed = true
        // Successful read-only handlers marked trivialVerify need no separate
        // effect verification. Failed results leave verification unset.
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
            }
            payload["executed"] = .bool(executed)
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

/// Swift-native dispatcher factory.
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
        ledger: ledger,
        localActions: actions,
        autonomyResolver: autonomyResolver
    )
}

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
    case ledgerFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingTool: return "dispatcher: tool name is required"
        case .ledgerFailure(let m): return "dispatcher: ledger write failed: \(m)"
        }
    }
}

// Only input and extra context can contain non-serializable values. Preserve
// the original field paths and extra-context override order without encoding
// a retired HTTP envelope on every native dispatch.
private func validateDispatchValues(_ value: JSONValue, path: String = "") throws {
    switch value {
    case .double(let number) where !number.isFinite:
        throw PersistenceCoreError.nonFiniteFloat(number, path: path)
    case .array(let values):
        for (index, value) in values.enumerated() {
            try validateDispatchValues(value, path: "\(path)[\(index)]")
        }
    case .object(let fields):
        for key in fields.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            try validateDispatchValues(fields[key]!, path: path.isEmpty ? key : "\(path).\(key)")
        }
    default: break
    }
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

/// A read-only dispatcher; writable registrations fail closed before execution.
public actor SwiftNativeDispatcher {
    private let ledger: DispatchLedger
    /// Runs registered connector actions in-process. Nil or missing handlers
    /// fail closed; production callers supply NativeActionDispatch's registry.
    private let localActions: LocalConnectorActions?
    private let timeout: TimeInterval

    public init(
        timeout: TimeInterval = 60,
        ledger: DispatchLedger? = nil,
        localActions: LocalConnectorActions? = nil
    ) {
        self.timeout = timeout
        self.ledger = ledger ?? DispatchLedger(ledgerPath: DispatchLedger.defaultLedgerPath())
        self.localActions = localActions
    }

    public func dispatch(
        tool: String,
        input: [String: JSONValue],
        ctx: DispatchContext,
        dryRun: Bool
    ) async throws -> DispatchResult {
        // Reject malformed input before native execution.
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Write a failed ledger entry first so the dispatch attempt is
            // visible even when the input is malformed.
            await tryWriteLedger(
                runId: UUID().uuidString.lowercased(),
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

        let runId = UUID().uuidString.lowercased()
        let startedAt = dispatcherNowISO(Date())
        do {
            var values = ctx.extra
            if values["input"] == nil { values["input"] = .object(input) }
            try validateDispatchValues(.object(values))
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

        // Writable registrations use the same fail-closed receipt as absent
        // handlers, including when callers construct the dispatcher directly.
        if let actions = localActions, actions.canHandle(trimmed), !actions.isSideEffecting(trimmed) {
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

        let effective = "auto"
        let autonomySource = "native"

        // Dry runs leave even read-only handlers unexecuted.
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
        if ["read_file", "file_excerpt", "list_dir", "file_info"].contains(tool) {
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
            // Executed failures remain recoverable and keep the handler's own
            // error code, with the established handler_raised default.
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
            let createdAt = startedAt ?? dispatcherNowISO(Date())
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

/// Swift-native read-only dispatcher factory.
public func makeDispatcher(
    ledger: DispatchLedger? = nil,
    // Nil keeps this dispatcher fail-closed for every tool. Production callers
    // pass the concrete Swift registry they want to expose.
    localActions: LocalConnectorActions? = nil
) -> SwiftNativeDispatcher {
    SwiftNativeDispatcher(ledger: ledger, localActions: localActions)
}

/// A chat slash command dispatched straight to the read-only local actions:
/// persona_read, workspace_list, time_now, persona_list_skills, read_file,
/// file_excerpt and system_info. Every other tool fails closed inside
/// `SwiftNativeDispatcher` with `native_handler_missing`; there is no daemon
/// or HTTP fallback.
public func dispatchSlashCommand(
    tool: String,
    input: [String: JSONValue],
    sessionId: String?,
    dataRoot: URL
) async throws -> DispatchResult {
    let dispatcher = makeDispatcher(localActions: .nativeReadOnly)
    let ctx: DispatchContext
    // Only the two file reads get the sandbox context. An empty repo root
    // would leave `FileSystemActions.allowedRoots` empty and skip the sandbox
    // guard, so an absolute path like /etc/passwd would read; the other
    // actions derive their persona root from `_na_data_root` in test mode
    // only, so handing them this context would move their persona root.
    if tool == "read_file" || tool == "file_excerpt" {
        // A repo root only when the data root's parent carries every repo
        // marker: a bare Application Support root's parent is the whole
        // Application Support tree. Without one the read is refused locally.
        guard let repoRootURL = PersistenceCore.resolveSandboxRepoRoot(dataRoot: dataRoot) else {
            return missingNativeHandler(tool: tool)
        }
        let repoRoot = repoRootURL.path
        var extra: [String: JSONValue] = [
            "file_access": .object([
                "mode": .string("read_only"),
                "sandbox": .string("read_only"),
            ]),
        ]
        // The data root lets `isSensitiveDataPath` block OAuth tokens, pairing
        // secrets and provider credentials that live under the repo root.
        if !dataRoot.path.isEmpty {
            extra["_na_data_root"] = .string(dataRoot.path)
        }
        ctx = DispatchContext(
            repoRoot: repoRoot,
            cwd: repoRoot,
            surface: "chat",
            sessionId: sessionId ?? "",
            persona: "",
            activeProvider: "",
            extra: extra
        )
    } else {
        ctx = DispatchContext.defaultForSurface("chat", sessionId: sessionId ?? "")
    }
    do {
        return try await dispatcher.dispatch(tool: tool, input: input, ctx: ctx, dryRun: false)
    } catch let err as DispatcherError {
        throw NSError(domain: "NativeAgentDispatcher", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: err.localizedDescription])
    }
}

/// The failed receipt for a tool with no Swift-native handler here.
private func missingNativeHandler(tool: String) -> DispatchResult {
    FileHandle.standardError.write(Data("dispatchSlashCommand: no native handler for tool=\(tool)\n".utf8))
    return DispatchResult(
        ok: false,
        tool: tool,
        status: "failed",
        output: nil,
        error: DispatchError(
            code: "native_handler_missing",
            message: "No Swift-native handler is available for tool '\(tool)'",
            tool: tool.isEmpty ? nil : tool,
            argsHash: nil,
            recoverable: false
        ),
        executed: false,
        verifyPassed: nil,
        durationUs: 0,
        durationMs: 0,
        argsHash: "",
        effectiveAutonomy: "",
        autonomySource: "",
        providerMatch: false,
        traceEventId: "",
        runId: UUID().uuidString.lowercased(),
        startedAt: dispatcherNowISO(Date())
    )
}

import Foundation
import MCPDispatcher
import NativeAgentCore
import PersistenceCore

// MARK: - Tool-output failure-shape heuristic

/// Shared success/failure classification for chat tool envelopes. Lives here
/// (not inside ToolProgressPersistenceBuffer, its original home) because the
/// trace recorder below must classify failures IDENTICALLY to the persisted
/// tool rows — two heuristics would let a dispatch persist as failed in chat
/// history yet trace as ok in events.jsonl.
enum ChatToolOutcome {
    enum ExactResultClass: String, Sendable, Equatable {
        case succeeded
        case failed
        case cancelled
        case timeout
        case unknown
    }

    enum CognitiveResult: String, Sendable, Equatable {
        case succeeded
        case failed
        case unknown
    }

    static func outputLooksSuccessful(_ output: JSONValue) -> Bool {
        if MCPInvocationOutcome.classify(response: output).providerToolResultIsError {
            return false
        }
        guard case .object(let obj) = output else { return true }
        if obj["error"] != nil { return false }
        // Most non-throwing failures on this surface use status:"failed"/
        // "denied" envelopes with NO "error" key (builder tools, Full-Mac
        // gates, lazy-load misses) — without this they persisted as ok:true
        // and the UI rendered failures as successes (audit 2026-06-09).
        if case .string(let status)? = obj["status"] {
            let s = status.lowercased()
            if s == "failed" || s == "denied" || s == "error" { return false }
        }
        if case .int(let code)? = obj["exit_code"], code != 0 { return false }
        if case .double(let code)? = obj["exit_code"], code != 0 { return false }
        return true
    }

    /// Exact machine-envelope classification for evidence and resident
    /// consequence paths. Unlike `outputLooksSuccessful`, this never treats a
    /// missing status as success. Pending transport, approval, partial, and
    /// ambiguous envelopes stay unknown.
    static func exactResultClass(_ output: JSONValue) -> ExactResultClass {
        if MCPInvocationOutcome.classify(response: output).providerToolResultIsError {
            return .failed
        }
        guard case .object(let object) = output else { return .unknown }
        if case .bool(true)? = object["dryRun"] ?? object["dry_run"] {
            return .unknown
        }

        let status: String? = {
            guard case .string(let raw)? = object["status"] else { return nil }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }()
        let pendingStatuses: Set<String> = [
            "accepted", "attention", "awaiting_approval", "blocked", "dry_run",
            "pending", "pending_approval", "partial", "queued", "ready",
            "running", "skipped", "submitted", "unknown", "warning",
        ]
        let failureStatuses: Set<String> = [
            "denied", "error", "failed", "failure", "rejected",
        ]
        let successStatuses: Set<String> = [
            "complete", "completed", "delivered", "done", "ok", "passed",
            "succeeded", "success",
        ]

        if let status, pendingStatuses.contains(status) { return .unknown }
        if let status, ["cancelled", "canceled"].contains(status) { return .cancelled }
        if let status, ["timeout", "timed_out"].contains(status) { return .timeout }
        if let status, failureStatuses.contains(status) { return .failed }
        if case .bool(false)? = object["ok"] { return .failed }
        if case .bool(false)? = object["success"] { return .failed }
        if let error = object["error"], error != .null { return .failed }
        if let exitCode = numericExitCode(object["exit_code"]), exitCode != 0 {
            return .failed
        }
        if let status, successStatuses.contains(status) { return .succeeded }
        if case .bool(true)? = object["ok"] { return .succeeded }
        if case .bool(true)? = object["success"] { return .succeeded }
        if numericExitCode(object["exit_code"]) == 0 { return .succeeded }
        return .unknown
    }

    /// Generic chat-tool completion must not duplicate an existing motor
    /// owner's consequence. Those domains publish from their canonical read
    /// models; their immediate tool envelope is transport evidence only.
    static func cognitiveResult(tool: String, output: JSONValue) -> CognitiveResult {
        let resultClass = exactResultClass(output)
        // Deterministic policy/input refusals are useful transcript and audit
        // failures, but they are not evidence that the tool implementation is
        // brittle. Keeping them out of resident physiology prevents a correctly
        // enforced sensitive-path fence (or a caller's missing path) from
        // manufacturing a low-confidence tool reflex.
        if isDeterministicRefusal(output) {
            return .unknown
        }
        // External protocol responses prove only that transport returned.
        // They do not prove that any external effect settled, and a timeout or
        // stream loss may occur after submission. Keep resident physiology
        // neutral; the model and trace still receive the exact result/error.
        if ToolCausalBoundary.isExternalProtocolTool(tool) {
            return .unknown
        }
        if hasCanonicalMotorOwner(tool) {
            // Once the envelope carries the canonical owner's identity, its
            // read model is the only consequence source. Before admission no
            // owner exists, so an exact failure must still reach resident
            // attention instead of disappearing behind the tool-name rule.
            guard canonicalMotorOwnerReference(tool: tool, output: output) == nil else {
                return .unknown
            }
            switch resultClass {
            case .failed, .cancelled, .timeout: return .failed
            case .succeeded, .unknown: return .unknown
            }
        }
        switch resultClass {
        case .succeeded: return .succeeded
        case .failed, .cancelled, .timeout: return .failed
        case .unknown: return .unknown
        }
    }

    private static func isDeterministicRefusal(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output else { return false }
        if case .bool(true)? = object["requires_approval"] ?? object["requiresApproval"] {
            return true
        }
        if case .bool(true)? = object["permission_denied"] ?? object["permissionDenied"] {
            return true
        }
        if case .string(let rawCode)? = object["error_code"] ?? object["errorCode"] {
            let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let neutralCodes: Set<String> = [
                "approval_required",
                "bad_input",
                "file_not_found",
                "not_loaded",
                "path_not_allowed",
                "permission_denied",
                "policy_denied",
                "security_denied",
                "unsupported",
            ]
            if neutralCodes.contains(code) { return true }
        }
        if case .string(let rawStatus)? = object["status"] {
            let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if status == "awaiting_approval"
                || status == "blocked"
                || status == "pending_approval" {
                return true
            }
            // A typed SecurityCenter denial carries authority evidence beside
            // `status=denied`; an arbitrary domain failure does not.
            if status == "denied",
               object["decision"] != nil
                || object["reasons"] != nil
                || object["capabilities"] != nil {
                return true
            }
        }
        return false
    }

    static func hasCanonicalMotorOwner(_ rawTool: String) -> Bool {
        ToolCausalBoundary.hasCanonicalMotorOwner(tool: rawTool)
    }

    static func canonicalMotorOwnerReference(tool rawTool: String, output: JSONValue) -> String? {
        ToolCausalBoundary.motorReference(tool: rawTool, output: output)?.ownerActionID
    }

    private static func numericExitCode(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let code): return Double(code)
        case .double(let code): return code
        default: return nil
        }
    }
}

// MARK: - ChatToolDispatchTracer

/// Trace-recording ToolDispatchClient. Appends one `tool.dispatch` row to
/// `<dataRoot>/traces/events.jsonl` for EVERY dispatch that flows through it:
/// success, failure-shaped envelope, and thrown error. This keeps
/// `recent_trace_summary` aware of the assistant's own tool activity.
///
/// Wraps the gated chain OUTERMOST (above AutonomyGatedDispatcher /
/// FileAccessGatedDispatcher) so gate denials — which throw before the inner
/// dispatcher runs — still land as status:"failed" rows.
///
/// PRIVACY (hard constraint): rows carry input KEY NAMES, status, duration,
/// and surface only — never argument values or result bodies. The traces
/// file is unencrypted and long-lived.
///
/// Tracing is non-fatal: an IO failure here logs to stderr and the dispatch
/// result (or thrown error) reaches the tool loop unchanged.
///
/// Row schema matches the existing writers (DispatchLedger,
/// NativeClient.appendCapabilityPackTrace):
///   {id, kind, title, status, payload, createdAt} with ISO8601 createdAt.
final class ChatToolDispatchTracer: ToolDispatchClient, @unchecked Sendable {
    /// Cap mirrors the bounded notification-inbox items.jsonl trim: tail-keep
    /// under the same flock acquisition as the append.
    static let maxTraceLines = 5000
    /// A trim requires a whole-file read, so it runs opportunistically:
    /// every Nth append process-wide, or immediately once the file size
    /// passes `trimByteTrigger` — not on every append.
    private static let defaultTrimCheckInterval = 32
    private static let trimByteTrigger = 4 * 1024 * 1024
    private static let counterLock = NSLock()
    // nonisolated(unsafe): every access is guarded by counterLock.
    nonisolated(unsafe) private static var appendCounter = 0

    private let inner: any ToolDispatchClient
    private let tracesPath: URL
    private let persistence = SwiftNativePersistenceCore()
    private let trimCheckInterval: Int

    init(
        inner: any ToolDispatchClient,
        dataRoot: URL,
        trimCheckInterval: Int = ChatToolDispatchTracer.defaultTrimCheckInterval
    ) {
        self.inner = inner
        self.tracesPath = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        self.trimCheckInterval = max(1, trimCheckInterval)
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let startNs = DispatchTime.now().uptimeNanoseconds
        // Turn Inspector W1: mirror a "begin" event onto the bus the instant
        // the dispatch starts, so the live Inspector shows a tool as RUNNING
        // (not just on completion). Bus-only — the events.jsonl row stays a
        // single end-of-dispatch row, unchanged.
        Self.fireBusEvent(
            tool: tool, input: input, surface: surface,
            phase: "begin", status: "running", durationMs: nil, result: nil
        )
        let result: JSONValue
        do {
            result = try await inner.dispatch(tool: tool, input: input, surface: surface)
        } catch {
            let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
            Self.fireBusEvent(
                tool: tool, input: input, surface: surface,
                phase: "end", status: "failed", durationMs: durationMs,
                result: .string(String(describing: error))
            )
            await appendTraceRow(
                tool: tool, input: input, surface: surface,
                status: "failed", startNs: startNs
            )
            throw error
        }
        let status = ChatToolOutcome.outputLooksSuccessful(result) ? "ok" : "failed"
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        Self.fireBusEvent(
            tool: tool, input: input, surface: surface,
            phase: "end", status: status, durationMs: durationMs, result: result
        )
        await appendTraceRow(
            tool: tool, input: input, surface: surface,
            status: status, startNs: startNs
        )
        return result
    }

    /// Turn Inspector W1: fire a tool.dispatch event onto the in-process bus
    /// (fire-and-forget, drop-on-backpressure, NEVER awaited). Carries the tool
    /// name, phase (begin/end), status, duration, and — UNLIKE the privacy-
    /// strict events.jsonl row — a TRUNCATED args/result preview (≤500 chars
    /// each) so the Inspector can show what the tool was called with and what
    /// it returned. The truncation is the redaction-at-emission boundary the
    /// build plan requires; full bodies never reach the bus. Skipped when no
    /// turn is bound.
    private static func fireBusEvent(
        tool: String,
        input: [String: JSONValue],
        surface: String,
        phase: String,
        status: String,
        durationMs: Int?,
        result: JSONValue?
    ) {
        guard TurnTraceContext.turnId != nil else { return }
        var payload: [String: JSONValue] = [
            "name": .string(tool),
            "phase": .string(phase),
            "status": .string(status),
            "argKeys": .array(input.keys.sorted().map { .string($0) }),
            "args": .string(Self.truncatePreview(.object(input))),
        ]
        if let durationMs { payload["durationMs"] = .int(Int64(durationMs)) }
        if let result { payload["result"] = .string(Self.truncatePreview(result)) }
        TurnTraceBus.fireFromContext(
            kind: "tool.dispatch",
            sessionId: traceSessionID(input),
            surface: surface,
            payload: .object(payload)
        )
        // Turn Inspector W2 — derived file.touch event. When the dispatched
        // tool is a known FILE tool, extract the path argument(s) and fire a
        // file.touch event with {tool, paths, mode}. Fired ONLY on a
        // SUCCESSFUL end (gpt-5.5 W2 review: a thrown/gate-denied dispatch
        // never touched the file — recording it as a touch would be a lie; the
        // failed attempt stays visible as the tool.dispatch end event above).
        // Paths are not secrets but are redacted anyway (cheap, consistent
        // with the redaction-at-emission discipline).
        if phase == "end", status == "ok" {
            Self.fireFileTouchEvent(tool: tool, input: input, surface: surface, status: status)
        }
    }

    /// Turn Inspector W2 — known file-tool catalog → mode map. Names mirror the
    /// real dispatch catalog in ChatOrchestrationClient (SwiftToolDispatcher
    /// fullMacFileToolNames + the always-on read/write file tools + the builder
    /// apply_patch). `read` vs `write` is the dominant access axis; tools that
    /// can do either default to the more sensitive `write` only when they
    /// actually mutate (apply_patch / write_file / file_write). git_* and grep
    /// are reads.
    private static let fileToolModes: [String: String] = [
        "read_file": "read",
        "file_excerpt": "read",
        "list_dir": "read",
        "list_directory": "read",
        "grep": "read",
        "git_status": "read",
        "git_diff": "read",
        "git_log": "read",
        "repo_dirty_summary": "read",
        "write_file": "write",
        "file_write": "write",
        "apply_patch": "write",
    ]

    /// Argument keys that carry a filesystem path across the file-tool catalog.
    /// `apply_patch` carries its target paths INSIDE the patch body (the
    /// envelope itself has no path key), so it contributes no extracted path —
    /// the event still records {tool, mode:write} with an empty paths array,
    /// which is honest (we know it touched files, not which without parsing the
    /// patch — out of W2 scope).
    private static let pathArgKeys: [String] = ["path", "dir", "directory", "file", "filepath", "file_path"]

    private static func fireFileTouchEvent(
        tool: String,
        input: [String: JSONValue],
        surface: String,
        status: String
    ) {
        guard TurnTraceContext.turnId != nil else { return }
        guard let mode = fileToolModes[tool] else { return }
        var paths: [String] = []
        for key in pathArgKeys {
            if case .string(let p)? = input[key], !p.isEmpty {
                // Redact BEFORE bounding (TurnTraceEvent bounds leaves; this
                // adds the secret-scrub half). A path is rarely a secret but a
                // signed URL / token-bearing path would be caught.
                paths.append(ChatSecretRedactor.redactText(p))
            }
        }
        var payload: [String: JSONValue] = [
            "tool": .string(tool),
            "mode": .string(mode),
            "status": .string(status),
            "paths": .array(paths.map { .string($0) }),
        ]
        payload["pathCount"] = .int(Int64(paths.count))
        TurnTraceBus.fireFromContext(
            kind: "file.touch",
            sessionId: traceSessionID(input),
            surface: surface,
            payload: .object(payload)
        )
    }

    private static func traceSessionID(_ input: [String: JSONValue]) -> String? {
        for key in ["__session_id", "session_id", "sessionId"] {
            guard case .string(let raw)? = input[key] else { continue }
            let sessionID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sessionID.isEmpty { return sessionID }
        }
        return LLMCallContext.sessionId
    }

    /// Serialize a JSONValue to a compact preview string, SECRET-REDACTED
    /// (gpt-5.5 W1 review blocker: truncation alone is not redaction — a
    /// token/password under the limit would persist to turn_traces verbatim),
    /// then truncated to 500 chars. Best-effort: a serialization failure
    /// yields a short marker.
    private static func truncatePreview(_ value: JSONValue) -> String {
        let limit = 500
        let raw: String
        if let data = try? value.serializedData(pretty: false),
           let s = String(data: data, encoding: .utf8) {
            raw = ChatSecretRedactor.redactText(s)
        } else {
            raw = "[unserializable]"
        }
        guard raw.count > limit else { return raw }
        return String(raw.prefix(limit)) + "…[+\(raw.count - limit) chars]"
    }

    func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }

    private func appendTraceRow(
        tool: String,
        input: [String: JSONValue],
        surface: String,
        status: String,
        startNs: UInt64
    ) async {
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        let argKeys = input.keys.sorted()
        let receipt = CompactActionReceipt.toolDispatch(
            tool: tool,
            surface: surface,
            status: status,
            durationMs: durationMs,
            argKeyCount: argKeys.count
        )
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("tool.dispatch"),
            "title": .string(tool),
            "status": .string(status),
            // Keys only — argument VALUES and result bodies must never land
            // in this file.
            "payload": .object([
                "argKeys": .array(argKeys.map { .string($0) }),
                "durationMs": .int(Int64(durationMs)),
                "surface": .string(surface),
                // Turn Inspector W1: correlate this row to its turn. Unbound
                // (non-turn dispatch) → "unknown".
                "turnId": .string(TurnTraceContext.turnId ?? "unknown"),
                "receipt": receipt.toJSONValue(),
            ]),
            "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        let counterTripped: Bool = {
            Self.counterLock.lock()
            defer { Self.counterLock.unlock() }
            Self.appendCounter &+= 1
            return Self.appendCounter % trimCheckInterval == 0
        }()
        do {
            try await persistence.withFileLock(tracesPath) { [persistence, tracesPath] in
                try await persistence.appendJSONL(row, to: tracesPath)
                if counterTripped || Self.fileSize(tracesPath) > Self.trimByteTrigger {
                    Self.trimLocked(tracesPath, keepLast: Self.maxTraceLines)
                }
            }
        } catch {
            FileHandle.standardError.write(
                Data("ChatToolDispatchTracer: trace append failed (\(tool)): \(error)\n".utf8)
            )
        }
    }

    private static func fileSize(_ path: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else {
            return 0
        }
        return (attrs[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Tail-trim to `keepLast` physical lines. Caller MUST hold the
    /// events.jsonl flock — the read-trim-replace is not atomic on its own.
    /// Best-effort: failures leave the (oversized but valid) file in place.
    private static func trimLocked(_ path: URL, keepLast: Int) {
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count > keepLast else { return }
        let trimmed = lines.suffix(keepLast).joined(separator: "\n") + "\n"
        // Fixed-path tmp: remove on every exit path so a replaceItemAt
        // failure doesn't strand a stale sibling (state-lifecycle hygiene;
            // same shape as the bounded notification-inbox ledger).
        let tmp = path.appendingPathExtension("tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let out = trimmed.data(using: .utf8) else { return }
        do {
            try out.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } catch {
            FileHandle.standardError.write(
                Data("ChatToolDispatchTracer: trace trim failed: \(error)\n".utf8)
            )
        }
    }
}

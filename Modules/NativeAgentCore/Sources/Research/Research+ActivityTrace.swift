import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeResearchClient {
    // MARK: - activity / trace emission (wave 31 W03)
    //
    // Byte-for-byte mirrors of Daemon.record_activity
    // and Daemon.record_trace (L8541). Both append a sort_keys=True JSONL line
    // (persistence.appendJSONL serializes with UTF-8-byte-ordered keys to match
    // Python's json.dumps(sort_keys=True)).
    //
    // ERROR PROPAGATION: these THROW on a failed append, matching the daemon.
    // Python's record_activity / record_trace call append_jsonl directly with
    // no inner try/except, so a write failure
    // propagates out of run_research_lab into the route's outer 500 handler.
    // The run-row write at runs.json already happened by then; an emission
    // failure therefore surfaces as an error to the caller even though the run
    // persisted — preserved here for parity rather than swallowing.

    /// Mirror `Daemon.record_activity`. Envelope keys:
    /// {id, kind, title, detail, status, missionId, payload, createdAt}.
    /// title/detail/payload are redacted (Python redact_secret_text /
    /// redact_secret_value). missionId is always null for the research case.
    func recordActivity(
        kind: String,
        title: String,
        detail: String,
        status: String,
        payload: JSONValue
    ) async throws {
        let event: JSONValue = .object([
            "id": .string(receiptIDFactory()),
            "kind": .string(kind),
            "title": .string(Self.redactSecretText(title)),
            "detail": .string(Self.redactSecretText(detail)),
            "status": .string(status),
            "executionId": .null,
            "payload": Self.redactSecretValue(payload),
            "createdAt": .string(Self.isoTimestamp(now())),
        ])
        // The shared owner takes the one-sided Swift flock and amortizes the
        // newest-5000 trim behind the activity feed's byte trigger.
        try await appendJSONLCapped(
            event,
            to: activityPath,
            using: persistence,
            maxLines: JSONLLineCaps.activityEvents,
            logLabel: "Research"
        )
    }

    /// Mirror `Daemon.record_trace`. Envelope keys:
    /// {id, kind, title, status, payload, createdAt}. The envelope `status`
    /// is `str(payload.get("status") or "ok")`. Trace payloads are NOT
    /// redacted in Python (record_trace does no redaction), so we don't
    /// redact here either — only error-field normalization, which the
    /// research.run trace never carries.
    func recordTrace(
        kind: String,
        title: String,
        payload: JSONValue
    ) async throws {
        var statusField = "ok"
        if case .object(let obj) = payload, case .string(let s) = obj["status"] ?? .null, !s.isEmpty {
            statusField = s
        }
        let event: JSONValue = .object([
            "id": .string(receiptIDFactory()),
            "kind": .string(kind),
            "title": .string(title),
            "status": .string(statusField),
            "payload": payload,
            "createdAt": .string(Self.isoTimestamp(now())),
        ])
        try await appendEnvelope(event, to: tracesPath)
    }

    /// Append one JSONL envelope. When the backing store is the on-disk
    /// SwiftNativePersistenceCore, the append is wrapped in a `<path>.lock`
    /// flock to serialize concurrent SWIFT-side writers (e.g. a future
    /// in-process subsystem also appending to the same feed). NOTE: this lock
    /// is NOT symmetric with the daemon — Python's append_jsonl
    /// is UNLOCKED and relies on POSIX O_APPEND
    /// atomicity for sub-PIPE_BUF lines; the daemon does not take this lock.
    /// So the flock is a one-sided Swift-only precaution, exactly like
    /// DispatchLedger.append. Errors propagate (see ERROR PROPAGATION note).
    private func appendEnvelope(_ envelope: JSONValue, to path: URL) async throws {
        // A5.5(d): traces/events.jsonl is a MULTI-writer feed — the
        // ProviderRouting LLM adapter caps it to activityEvents (5000) via
        // appendJSONLCapped, but this trace co-writer used to append UNBOUNDED.
        // A quiet-on-LLM but research-active install grew the file with no
        // rotation. Match the sibling writers' 5000-line budget so every
        // co-writer trims to the same newest-N invariant (no trim-fighting).
        // appendJSONLCapped takes the same one-sided flock this used to.
        try await appendJSONLCapped(
            envelope,
            to: path,
            using: persistence,
            maxLines: JSONLLineCaps.activityEvents,
            logLabel: "Research.trace"
        )
    }

    /// Python `value[:n]` slices by Unicode code points, not grapheme
    /// clusters. Mirror it exactly (same idiom as PersonaEngine display-name
    /// truncation) so objective[:120] is byte-identical across the cutover.
    nonisolated static func pythonCodepointPrefix(_ value: String, _ n: Int) -> String {
        let scalars = value.unicodeScalars
        if scalars.count <= n { return value }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }

    // MARK: - Secret redaction
    //
    // Mirror Daemon.redact_secret_text / redact_secret_value (the retired daemon
    // L2016-L2059). A research objective is user-supplied free text that could
    // contain a pasted credential, so the activity-feed `title`/`detail` and
    // `payload` are redacted before durable local persistence — identical to
    // what the daemon does. Replacement format: `[REDACTED_<KIND>:<digest>]`
    // where digest = sha256(match).hexdigest()[:12].

    /// Keep the historical test seam while delegating the exact contract to
    /// NativeAgentCore so every activity writer cannot drift independently.
    nonisolated static func redactSecretText(_ value: String) -> String {
        NativeAgentSecretRedactor.redactText(value)
    }

    /// Mirror `redact_secret_value`: recurse into arrays/objects, redact
    /// strings, leave numbers/bools/null untouched.
    nonisolated static func redactSecretValue(_ value: JSONValue) -> JSONValue {
        NativeAgentSecretRedactor.redactValue(value)
    }

}

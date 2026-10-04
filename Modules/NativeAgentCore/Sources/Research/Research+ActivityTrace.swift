import FeedPolicy
import Privacy
import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeResearchClient {
    // MARK: - activity / trace emission (wave 31 W03)
    //
    // Activity and trace retain their legacy envelope shapes with redacted
    // content. Both append a sort_keys=True JSONL line
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
            "title": .string(NativeAgentSecretRedactor.redactText(title)),
            "detail": .string(NativeAgentSecretRedactor.redactText(detail)),
            "status": .string(status),
            "executionId": .null,
            "payload": NativeAgentSecretRedactor.redactValue(payload),
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
    /// is `str(payload.get("status") or "ok")`. Titles and payloads are
    /// redacted before persistence, as they may contain private credentials.
    func recordTrace(
        kind: String,
        title: String,
        payload: JSONValue
    ) async throws {
        let redactedPayload = NativeAgentSecretRedactor.redactValue(payload)
        var statusField = "ok"
        if case .object(let obj) = redactedPayload, case .string(let s) = obj["status"] ?? .null, !s.isEmpty {
            statusField = s
        }
        let event: JSONValue = .object([
            "id": .string(receiptIDFactory()),
            "kind": .string(kind),
            "title": .string(NativeAgentSecretRedactor.redactText(title)),
            "status": .string(statusField),
            "payload": redactedPayload,
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
        try await appendPathOwnedJSONL(
            envelope,
            to: path,
            using: persistence,
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

}

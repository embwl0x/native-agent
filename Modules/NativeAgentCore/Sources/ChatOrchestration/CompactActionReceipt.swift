import Foundation
import PersistenceCore

struct CompactActionReceipt: Equatable, Sendable {
    var action: String
    var surface: String
    var target: String
    var decision: String
    var outcome: String
    var reason: String
    var changedFields: [String]
    var proof: [String]
    var permanence: String
    var risk: String
    var errorClass: String?
    /// Bounded (≤ `ChatToolOutcome.failureDetailLimit` chars), secret-redacted
    /// failure text — composed from error-shaped fields only (error/message/
    /// reason/detail/error_code/status), never a result body. Tool-authored
    /// error strings CAN echo argument-derived text (a bad path, a parse
    /// message), so this is "no bodies, redacted, bounded" — not a guarantee
    /// of zero user-derived characters. nil on success; the key is OMITTED
    /// (not null) when nil so no reader can mistake a present-null for a
    /// present-value.
    var errorDetail: String? = nil
    var tracePath: String

    func toJSONValue() -> JSONValue {
        var payload: [String: JSONValue] = [
            "action": .string(action),
            "surface": .string(surface),
            "target": .string(target),
            "decision": .string(decision),
            "outcome": .string(outcome),
            "reason": .string(reason),
            "changedFields": .array(changedFields.map { .string($0) }),
            "proof": .array(proof.map { .string($0) }),
            "permanence": .string(permanence),
            "risk": .string(risk),
            "tracePath": .string(tracePath),
        ]
        // Match `errorDetail`'s presence convention: an absent error is not
        // represented as a present JSON null. This lets readers distinguish a
        // successful dispatch from a writer that had no error classification.
        if let errorClass, !errorClass.isEmpty {
            payload["errorClass"] = .string(errorClass)
        }
        if let errorDetail, !errorDetail.isEmpty {
            payload["errorDetail"] = .string(errorDetail)
        }
        return .object(payload)
    }

    static func toolDispatch(
        tool: String,
        surface: String,
        status: String,
        durationMs: Int,
        argKeyCount: Int,
        risk: String,
        errorClass: String? = nil,
        errorDetail: String? = nil
    ) -> CompactActionReceipt {
        let ok = status == "ok"
        return CompactActionReceipt(
            action: "tool_dispatch",
            surface: surface,
            target: tool,
            decision: "attempted",
            outcome: ok ? "completed" : "failed",
            reason: ok ? "tool dispatch completed" : "tool dispatch failed",
            changedFields: [],
            proof: [
                "events.jsonl:tool.dispatch",
                "status:\(status)",
                "duration_ms:\(durationMs)",
                "arg_key_count:\(argKeyCount)",
                // The trace is bounded to a tail window, so it proves only
                // that this dispatch was recorded here — never that its effect
                // persists or settled outside this file.
                "permanence_source:events_jsonl_tail_retention",
                // Risk comes from the same pure SecurityCenter profile used by
                // authorization, not an advisory tracer-local name table.
                "risk_source:security_center.canonical_tool_risk",
            ],
            permanence: "bounded_trace",
            risk: risk,
            errorClass: ok ? nil : errorClass,
            errorDetail: ok ? nil : errorDetail,
            tracePath: "data/traces/events.jsonl"
        )
    }
}

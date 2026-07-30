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
        payload["errorClass"] = errorClass.map { .string($0) } ?? .null
        return .object(payload)
    }

    static func toolDispatch(
        tool: String,
        surface: String,
        status: String,
        durationMs: Int,
        argKeyCount: Int
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
            ],
            permanence: "unknown",
            risk: "unclassified",
            errorClass: ok ? nil : "tool_failed",
            tracePath: "data/traces/events.jsonl"
        )
    }
}

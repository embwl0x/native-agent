import Foundation
import PersistenceCore

extension SecurityToolEnvelope {
    func toJSONValue() -> JSONValue {
        .object([
            "id": .string(id),
            "created_at": .string(createdAt),
            "tool": .string(tool),
            "surface": .string(surface),
            "origin": .object(origin.toJSONValue()),
            "origin_trusted": .bool(originTrusted),
            "origin_trust_reason": .string(originTrustReason),
            "capabilities": .array(capabilities.map { .string($0) }),
            "risk": .string(risk),
            "autonomy_level": .string(autonomyLevel),
            "signed_tool_known": .bool(signedToolKnown),
            "rollback_required": .bool(rollbackRequired),
            "decision": .string(decision.rawValue),
            "allowed": .bool(allowed),
            "requires_approval": .bool(requiresApproval),
            "reasons": .array(reasons.map { .string($0) }),
            "untrusted_input_keys": .array(untrustedInputKeys.map { .string($0) }),
            "input_preview": redactedInputPreview,
        ])
    }
}

extension SecurityOriginContext {
    func toJSONValue() -> [String: JSONValue] {
        var out: [String: JSONValue] = ["surface": .string(surface)]
        if let sessionId { out["session_id"] = .string(sessionId) }
        if let userId { out["user_id"] = .string(userId) }
        if let chatId { out["chat_id"] = .string(chatId) }
        if let deviceId { out["device_id"] = .string(deviceId) }
        if let source { out["source"] = .string(source) }
        if let isRemote { out["is_remote"] = .bool(isRemote) }
        return out
    }
}

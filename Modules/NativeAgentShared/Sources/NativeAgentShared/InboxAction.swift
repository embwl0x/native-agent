import Foundation
// Blueprint: | `InboxAction.swift` | Shared signed iPhone-to-Mac inbox envelope; Codable wire schema for both transports and platforms |

/// The device signature and inner HMAC travel in this same envelope on both platforms.
public struct InboxAction: Codable, Sendable {
    /// Normalize historical string responses at the signed response boundary.
    public static func responseResultClass(_ response: [String: String]) -> String {
        if let verdict = response["result_class"] { return verdict }
        let status = (response["status"] ?? "").lowercased()
        if ["pending_approval", "approval_required", "pending", "queued", "running", "outcome_unknown"].contains(status) { return "unknown" }
        if response["ok"] == "false" || ["error", "failed", "orphaned"].contains(status)
            || !(response["error"] ?? response["code"] ?? "").isEmpty { return "failed" }
        if ["cancelled", "canceled", "stopped"].contains(status) { return "cancelled" }
        if ["timeout", "timed_out"].contains(status) { return "timeout" }
        if response["ok"] == "true" || ["ok", "completed", "success"].contains(status) { return "succeeded" }
        return "unknown"
    }

    public static func responseTransactionState(_ response: [String: String]) -> String {
        let status = (response["status"] ?? "").lowercased()
        if status == "orphaned" { return "orphaned" }
        if ["pending_approval", "approval_required"].contains(status) { return "pending_approval" }
        let verdict = responseResultClass(response)
        return verdict == "succeeded" ? "completed" : verdict == "unknown" ? "outcome_unknown" : "failed"
    }

    public var msgId: String
    public var clientId: String
    public var action: String
    public var payload: [String: String]
    public var createdAt: String
    public var protocolVersion: Int?
    public var transactionId: String?
    public var signature: String?
    public var devicePublicKey: String?
    public var deviceSignature: String?

    public init(msgId: String, clientId: String, action: String, payload: [String: String],
                createdAt: String, protocolVersion: Int?, transactionId: String?, signature: String?,
                devicePublicKey: String? = nil, deviceSignature: String? = nil) {
        self.msgId = msgId; self.clientId = clientId; self.action = action; self.payload = payload
        self.createdAt = createdAt; self.protocolVersion = protocolVersion; self.transactionId = transactionId
        self.signature = signature; self.devicePublicKey = devicePublicKey; self.deviceSignature = deviceSignature
    }
}

import Foundation
// Blueprint: | `ApprovalRequest.swift` | ApprovalRequest: shared consent outcomes, execution evidence and exact chat provenance; approval authority remains Mac-owned |

public struct ApprovalRequest: Identifiable, Codable, Hashable, Sendable {
    /// Consent is distinct from execution; unreadable decisions never offer consent.
    public enum Outcome: Sendable, Equatable {
        case pending, approved, denied, expired, unresolved

        public init(status: String, decision: String?) {
            let decision = decision?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch decision {
            case "approve", "approved": self = .approved
            case "deny", "denied", "reject", "rejected": self = .denied
            case "cancel", "canceled", "cancelled", "expired": self = .expired
            default:
                switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "pending": self = decision == nil ? .pending : .unresolved
                case "cancel", "canceled", "cancelled", "expired", "withdrawn", "orphaned": self = .expired
                default: self = .unresolved
                }
            }
        }
    }

    public var id: String
    public var title: String
    public var action: String
    public var risk: String
    public var reason: String?
    public var status: String
    public var createdAt: String?
    public var resolvedAt: String?
    public var decision: String?
    public var payloadPreview: String?
    public var localOnly: Bool?
    public var remoteResolvable: Bool?
    /// Canonical inbox `origin.sessionId` for `chat_tool_approval`; nil for other kinds.
    /// Surfaces match the current conversation without opening another approval store.
    public var chatOriginSessionId: String?
    /// The Mac turn projection's exact selected turn; nil without established provenance.
    public var chatOriginTurnId: String? = nil
    /// Latest ask time for a reused pending row, used instead of `createdAt` for visibility; nil if asked once.
    public var lastRequestedAt: String?
    public var executionOutcome: String?
    public var executionSummary: String?

    public var executionFailed: Bool {
        executionOutcome == "failed" || executionOutcome == "refused" || executionOutcome == "timeout"
    }
    public var outcome: Outcome { Outcome(status: status, decision: decision) }
    public var isExpired: Bool {
        outcome == .expired
    }
    public func expirationGuidance(agentName: String) -> String? {
        isExpired ? "Ask \(agentName) to raise this request again if you still want it." : nil
    }

    public var decisionSummary: String {
        let word: String
        switch outcome {
        case .pending: word = "Pending"
        case .approved: word = "Approved"
        case .denied: word = "Denied"
        case .expired: word = "Expired before a decision"
        case .unresolved: word = "Decision unavailable"
        }
        return executionFailed ? word + " · execution failed" : word
    }

    public init(
        id: String,
        title: String,
        action: String,
        risk: String,
        reason: String? = nil,
        status: String,
        createdAt: String? = nil,
        resolvedAt: String? = nil,
        decision: String? = nil,
        payloadPreview: String? = nil,
        localOnly: Bool? = nil,
        remoteResolvable: Bool? = nil,
        chatOriginSessionId: String? = nil,
        lastRequestedAt: String? = nil,
        executionOutcome: String? = nil,
        executionSummary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.risk = risk
        self.reason = reason
        self.status = status
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.decision = decision
        self.payloadPreview = payloadPreview
        self.localOnly = localOnly
        self.remoteResolvable = remoteResolvable
        self.chatOriginSessionId = chatOriginSessionId
        self.lastRequestedAt = lastRequestedAt
        self.executionOutcome = executionOutcome
        self.executionSummary = executionSummary
    }
}

import Foundation
import PersistenceCore

public enum SecurityToolDecision: String, Codable, Sendable, Equatable {
    case allow
    case ask
    case block
}

public struct SecurityOriginContext: Codable, Sendable, Equatable {
    public var surface: String
    public var sessionId: String?
    public var userId: String?
    public var chatId: String?
    public var deviceId: String?
    public var source: String?
    public var isRemote: Bool?
    public var commandSignatureVerified: Bool?

    public init(
        surface: String,
        sessionId: String? = nil,
        userId: String? = nil,
        chatId: String? = nil,
        deviceId: String? = nil,
        source: String? = nil,
        isRemote: Bool? = nil,
        commandSignatureVerified: Bool? = nil
    ) {
        self.surface = surface
        self.sessionId = sessionId
        self.userId = userId
        self.chatId = chatId
        self.deviceId = deviceId
        self.source = source
        self.isRemote = isRemote
        self.commandSignatureVerified = commandSignatureVerified
    }
}

public struct SecurityToolEnvelope: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createdAt: String
    public var tool: String
    public var surface: String
    public var origin: SecurityOriginContext
    public var originTrusted: Bool
    public var originTrustReason: String
    public var capabilities: [String]
    public var risk: String
    public var autonomyLevel: String
    public var signedToolKnown: Bool
    public var rollbackRequired: Bool
    public var decision: SecurityToolDecision
    public var allowed: Bool
    public var requiresApproval: Bool
    public var reasons: [String]
    public var untrustedInputKeys: [String]
    public var redactedInputPreview: JSONValue
    public var auditReceiptsEnabled: Bool
}

public struct SecurityStatusFlag: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var status: String
    public var detail: String
    public var enabled: Bool
}

public struct SecurityReceiptSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var at: String
    public var tool: String
    public var surface: String
    public var decision: String
    public var risk: String
    public var reason: String
}

/// The retention policy actually applied to `security/audit.jsonl`.
///
/// This is deliberately not a generic "row cap" label: the audit writer
/// avoids a full line-count scan until the byte trigger is crossed, so its
/// operative bound before rotation is bytes, not `rowCapWhenTriggered`.
public enum SecurityAuditRetentionBoundKind: String, Codable, Sendable, Equatable {
    case softByteTrimTrigger = "soft_byte_trim_trigger"
}

/// Whether the audit-retention observation is complete enough to rely on.
///
/// A byte-triggered line cap cannot honestly claim a 20k-row invariant below
/// its trigger. Damaged or unreadable evidence is distinct from a feed that is
/// merely waiting to reach its normal trim trigger.
public enum SecurityAuditRetentionState: String, Codable, Sendable, Equatable {
    case belowTrimTrigger = "below_trim_trigger"
    case trimTriggerExceeded = "trim_trigger_exceeded"
    case incompleteEvidence = "incomplete_evidence"
    case unavailable = "unavailable"
}

/// Read-only receipt for the real security-audit retention boundary.
///
/// `effectiveBoundBytes` is the 32 MiB soft trigger the writer actually checks
/// on every append. `rowCapWhenTriggered` is intentionally separate: it is
/// enforced only after that byte trigger, so consumers must not promote it to
/// an always-on row bound.
public struct SecurityAuditRetentionReport: Codable, Sendable, Equatable {
    public var state: SecurityAuditRetentionState
    public var effectiveBoundKind: SecurityAuditRetentionBoundKind
    public var effectiveBoundBytes: Int
    public var rowCapWhenTriggered: Int
    public var byteCount: Int?
    public var physicalLineCount: Int?
    public var evidenceIssue: String?

    public init(
        state: SecurityAuditRetentionState,
        effectiveBoundKind: SecurityAuditRetentionBoundKind = .softByteTrimTrigger,
        effectiveBoundBytes: Int,
        rowCapWhenTriggered: Int,
        byteCount: Int?,
        physicalLineCount: Int?,
        evidenceIssue: String? = nil
    ) {
        self.state = state
        self.effectiveBoundKind = effectiveBoundKind
        self.effectiveBoundBytes = effectiveBoundBytes
        self.rowCapWhenTriggered = rowCapWhenTriggered
        self.byteCount = byteCount
        self.physicalLineCount = physicalLineCount
        self.evidenceIssue = evidenceIssue
    }
}

public struct SecurityCenterStatus: Codable, Sendable, Equatable {
    public var status: String
    public var mode: String
    public var developerMode: Bool
    public var fullMac: Bool
    public var killSwitchEnabled: Bool
    public var trustedOrigins: Int
    public var auditReceiptsPath: String
    public var flags: [SecurityStatusFlag]
    public var recentReceipts: [SecurityReceiptSummary]
}

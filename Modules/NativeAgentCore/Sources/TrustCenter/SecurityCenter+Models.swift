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

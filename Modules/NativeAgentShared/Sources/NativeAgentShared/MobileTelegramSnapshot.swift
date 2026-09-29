import Foundation

/// The same trust-widening confirmation on Mac and phone.
public enum TelegramAccessConfirmation {
    public static let title = "Allow more Telegram replies?"
    public static let action = "Allow replies"
    public static let message = "Telegram can reply to allowed chats and users when enabled. If group mentions are not required, it can reply in allowed groups without being mentioned."
}

/// Credential-free readback of the Mac's Telegram settings and live loop state.
public struct MobileTelegramSnapshot: Codable, Equatable, Sendable {
    public var observedAt: Double
    public var tokenConfigured: Bool
    public var enabled: Bool
    public var requireMention: Bool
    public var allowedChatIDs: [String]
    public var allowedUserIDs: [String]
    public var model: String
    public var pollerRunning: Bool

    public init(observedAt: Double, tokenConfigured: Bool, enabled: Bool,
                requireMention: Bool, allowedChatIDs: [String], allowedUserIDs: [String],
                model: String, pollerRunning: Bool) {
        self.observedAt = observedAt
        self.tokenConfigured = tokenConfigured
        self.enabled = enabled
        self.requireMention = requireMention
        self.allowedChatIDs = allowedChatIDs
        self.allowedUserIDs = allowedUserIDs
        self.model = model
        self.pollerRunning = pollerRunning
    }
}

/// Deliberately has no credential or allowlist mutation field.
public enum MobileTelegramChange: Sendable {
    case enabled(Bool)
    case requireMention(Bool)
    case disconnect
}

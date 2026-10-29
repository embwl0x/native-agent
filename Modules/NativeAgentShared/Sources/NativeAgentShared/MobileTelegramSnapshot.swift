import Foundation
// Blueprint: | `MobileTelegramSnapshot.swift` | `MobileTelegramSnapshot` struct |

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
    public var pollStatusMessage: String?
    public var lastSuccessfulPollAt: String?

    public init(observedAt: Double, tokenConfigured: Bool, enabled: Bool,
                requireMention: Bool, allowedChatIDs: [String], allowedUserIDs: [String],
                model: String, pollerRunning: Bool,
                pollStatusMessage: String? = nil, lastSuccessfulPollAt: String? = nil) {
        self.observedAt = observedAt
        self.tokenConfigured = tokenConfigured
        self.enabled = enabled
        self.requireMention = requireMention
        self.allowedChatIDs = allowedChatIDs
        self.allowedUserIDs = allowedUserIDs
        self.model = model
        self.pollerRunning = pollerRunning
        self.pollStatusMessage = pollStatusMessage
        self.lastSuccessfulPollAt = lastSuccessfulPollAt
    }
}

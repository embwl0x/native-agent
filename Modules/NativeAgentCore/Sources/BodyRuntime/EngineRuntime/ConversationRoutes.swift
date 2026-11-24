// Blueprint: | `ConversationRoutes.swift` | Fixed provenance labels |

/// Never render raw origin strings; unknown origins cannot claim human authorship.
public struct MacChatMessageProvenance: Sendable, Equatable {
    /// Use fixed display text so recorded values cannot inject provenance labels.
    public let label: String
    /// Use a fixed symbol, never a recorded value.
    public let symbol: String
    /// Visual automation treatment is not cryptographic process identity.
    public let isAutomated: Bool

    public static func make(role: String, source: String?, envelope: ChatMessageOriginMetadata?) -> MacChatMessageProvenance? {
        guard let provenance = SessionMessageProvenance.make(
            role: role, source: source, hasEnvelope: envelope != nil,
            surface: envelope?.surface, agent: envelope?.agent
        ) else { return nil }
        switch provenance {
        case .telegram: return .init(label: "Telegram", symbol: "paperplane", isAutomated: false)
        case .slack: return .init(label: "Slack", symbol: "bubble.left.and.bubble.right", isAutomated: false)
        case .iPhone: return .init(label: "iPhone", symbol: "iphone", isAutomated: false)
        case .scheduled: return .init(label: "Scheduled", symbol: "clock.arrow.circlepath", isAutomated: true)
        case .automated: return .init(label: "Automated", symbol: "gearshape.arrow.triangle.2.circlepath", isAutomated: true)
        }
    }
}

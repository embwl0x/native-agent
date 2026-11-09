import ChatSessionWork
// Blueprint: | `ConversationRoutes.swift` | Sidebar routes, tab homes and fixed provenance labels |

public enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    case chat = "Chat"
    case bots = "Bots" // Injected by BotsShelfPreference; absent from unflagged destination lists.
    case activity = "Activity"
    case memories = "Memories"
    case desk = "Desk"
    case trust = "Trust"
    case providers = "Providers"
    case settings = "Settings"

    case personality = "Personality"
    case connectors = "Connectors"
    case capabilities = "Capabilities"
    case knowledge = "Knowledge Graph"
    case dreams = "Dreams"
    case cognition = "Cognition"
    case diagnostics = "Diagnostics"
    case inboxPolicy = "Inbox Policy"
    case inspector = "Inspector"

    /// A page of the agent's own (a part whose face is `{projection:true, page:"<id>"}`); the shell holds which one beside the selection.
    case ownPage = "Own page"

    public var id: String { rawValue }

    public static func shellHome(for item: SidebarItem) -> (parent: SidebarItem, tab: String)? {
        switch item {
        case .knowledge: (.memories, "knowledge")
        case .dreams: (.personality, "dreams")
        case .cognition: (.diagnostics, "Cognition")
        case .inspector: (.diagnostics, "Inspector")
        default: nil
        }
    }

    public var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .bots: "books.vertical"
        case .activity: "tray.full"
        case .memories: "brain"
        case .desk: "checklist"
        case .personality: "person.crop.circle"
        case .connectors: "point.3.connected.trianglepath.dotted"
        case .trust: "lock.shield"
        case .providers: "server.rack"
        case .settings: "gearshape"
        case .capabilities: "shippingbox"
        case .knowledge: "circle.hexagonpath"
        case .dreams: "moon.stars"
        case .cognition: "brain.head.profile"
        case .diagnostics: "stethoscope"
        case .inboxPolicy: "tray.and.arrow.down"
        case .inspector: "waveform.path.ecg"
        case .ownPage: "doc.richtext"
        }
    }

    public var displayName: String {
        switch self {
        case .inboxPolicy: "Notifications"
        case .bots: "Helpers"
        default: rawValue
        }
    }

    public var shellRailTitle: String {
        switch self {
        case .activity: "Today"
        case .inboxPolicy: "Notifications"
        case .bots: "Helpers"
        default: rawValue
        }
    }

}

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

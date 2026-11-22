// Blueprint: | `SidebarItem.swift` | Shell destinations, tab homes, door page names, labels and symbols shared by the app and the face |

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

    /// The door's name for the page the item draws. A page of the agent's own is named by the selection's id.
    public static func doorPage(_ item: SidebarItem) -> String? {
        switch shellHome(for: item)?.parent ?? item {
        case .chat: "chat"
        case .activity: "today"
        case .inboxPolicy: "inbox"
        case .bots: "bots"
        case .memories: "memories"
        case .desk: "desk"
        case .personality: "personality"
        case .providers: "providers"
        case .trust: "trust"
        case .connectors: "connectors"
        case .capabilities: "capabilities"
        case .settings: "settings"
        case .diagnostics: "diagnostics"
        case .ownPage, .knowledge, .dreams, .cognition, .inspector: nil
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

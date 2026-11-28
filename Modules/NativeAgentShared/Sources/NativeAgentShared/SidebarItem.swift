import Foundation
// Blueprint: | `SidebarItem.swift` | Shell places and their names, destinations, tab homes, door page names, labels and symbols |

public enum ShellSurface: String, CaseIterable, Identifiable, Sendable {
    case chat, desk, agent, control, diagnostics

    public var id: String { rawValue }

    public init(_ item: SidebarItem) {
        switch item {
        case .chat: self = .chat
        case .desk, .activity, .inboxPolicy, .bots: self = .desk
        case .memories, .knowledge, .personality, .dreams, .capabilities, .ownPage: self = .agent
        case .trust, .providers, .connectors, .settings: self = .control
        case .diagnostics, .cognition, .inspector: self = .diagnostics
        }
    }

    public var firstPage: SidebarItem {
        switch self {
        case .chat: .chat
        case .desk: .desk
        case .agent: .memories
        case .control: .trust
        case .diagnostics: .diagnostics
        }
    }

    public func title(agentName: String, simple: Bool = false) -> String {
        switch self {
        case .chat: simple ? "Together" : "Chat"
        case .desk: simple ? "Table" : "Desk"
        case .agent: NativeAgentIdentity.displayName(agentName, fallback: "Agent")
        case .control: "Control"
        case .diagnostics: "Diagnostics"
        }
    }

    public static func named(_ word: String, agentName: String = "") -> Self? {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ name: String) -> Bool { name.caseInsensitiveCompare(word) == .orderedSame }
        if let fixed = allCases.first(where: { matches($0.rawValue) || matches($0.title(agentName: "", simple: true)) }) {
            return fixed
        }
        return matches(Self.agent.title(agentName: agentName)) ? .agent : nil
    }
}

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

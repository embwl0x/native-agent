import EngineRuntime
import NativeAgentShared
// Blueprint: | `ShellPageContent.swift` | Rail-to-page names used by body-owned page reads and renderer navigation |

enum ShellPageContent {
    /// The door's name for the page `item` draws, so the agent reads what the person is looking at; nil for a page of the agent's own,
    /// which the selection names by its id.
    static func doorPage(_ item: SidebarItem) -> String? {
        switch SidebarItem.shellHome(for: item)?.parent ?? item {
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
}

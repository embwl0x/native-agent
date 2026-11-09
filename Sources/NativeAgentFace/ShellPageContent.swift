import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `ShellPageContent.swift` | Page drawing map and local rail/profile vocabulary |

/// Every place that draws a page draws it here: the window, the offscreen picture, the chat's page sheet and Simple's setup panel. A tab
/// item (Knowledge graph, Dreams, Cognition, Inspector) draws the page that holds it; the caller's stored tab picks the tab.
struct ShellPageContent: View {
    let item: SidebarItem
    /// The page of the agent's own `.ownPage` shows.
    var ownPage: String? = nil
    @Environment(AppModel.self) private var appModel

    private func reading(_ item: SidebarItem) -> Bool { appModel.panelIsReading(item) }

    var body: some View {
        switch SidebarItem.shellHome(for: item)?.parent ?? item {
        case .chat: ChatView()
        case .activity: TodayView()
        // The rail's Notifications row shows the Inbox: what needs the person now and the history folded below it.
        case .inboxPolicy: FacePageView(page: "inbox")
        case .bots: FacePageView(page: "bots", isReading: reading(.bots))
        case .memories: FacePageView(page: "memories").modifier(MemoriesFaceNavigation())
        case .desk: FacePageView(page: "desk").modifier(DeskFaceEditors())
        case .personality: FacePageView(page: "personality").personalityDestinations()
        case .providers: FacePageView(page: "providers", isReading: reading(.providers))
        case .trust: FacePageView(page: "trust")
        case .connectors: FacePageView(page: "connectors", isReading: reading(.connectors))
        case .capabilities: FacePageView(page: "capabilities", isReading: reading(.capabilities))
        case .settings: FacePageView(page: "settings")
        case .diagnostics: DiagnosticsRailPage()
        case .ownPage:
            if let ownPage { FacePageView(page: ownPage) }
        case .knowledge, .dreams, .cognition, .inspector:
            EmptyView()  // never reached: shellHome draws a tab's page
        }
    }

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

enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    case chat = "Chat"
    case bots = "Bots"
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

    var id: String { rawValue }

    static func shellHome(for item: SidebarItem) -> (parent: SidebarItem, tab: String)? {
        switch item {
        case .knowledge: (.memories, "knowledge")
        case .dreams: (.personality, "dreams")
        case .cognition: (.diagnostics, "Cognition")
        case .inspector: (.diagnostics, "Inspector")
        default: nil
        }
    }

    var systemImage: String {
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

    var displayName: String {
        switch self {
        case .inboxPolicy: "Notifications"
        case .bots: "Helpers"
        default: rawValue
        }
    }

    var shellRailTitle: String {
        switch self {
        case .activity: "Today"
        case .inboxPolicy: "Notifications"
        case .bots: "Helpers"
        default: rawValue
        }
    }

}


/// View profiles and preference words used by the window.
enum ShellViewMode {
    static let key = "nativeagent.viewMode"
    static let simple = "simple"
    static let advanced = "advanced"
    static let agent = "agent"
}

extension AppModel {
    var shellLayout: SurfaceLayoutAvailability? {
        face.slot(.layout).select("availability", as: LayoutFace.self) { $0?.availability }
    }
}

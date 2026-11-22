import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `ShellPageContent.swift` | Page drawing map and local rail/profile vocabulary |

/// Every place that draws a page draws it here: the window in Simple and Advanced, the offscreen picture and the chat's page sheet. A tab
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
        // The Desk's Notifications tab shows the Inbox: what needs the person now and the history folded below it.
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

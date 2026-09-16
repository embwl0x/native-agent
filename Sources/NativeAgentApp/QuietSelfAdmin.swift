import Foundation
import NativeAgentCore
import PersistenceCore

/// The agent administering NativeAgent itself, quietly.
///
/// QUIET IS A CONSTRUCTION, NOT A PROMISE. Nothing in this file or its two
/// siblings calls `NSApp.activate`, `makeKeyAndOrderFront`, `orderFront`,
/// `NSWindow.level`, `CGEvent`, `CGWarpMouseCursorPosition`, or any other
/// synthesized input. Reads render the page into an OFFSCREEN host that is
/// never ordered anywhere (`QuietSelfAdminRender.swift`), and writes call the
/// very same `AppModel` / `UserDefaults` entry points the visible control
/// calls when a person clicks it — so the live page updates the same way it
/// does for a click, and nothing comes forward, moves, or makes a sound.
///
/// HONEST IS ALSO A CONSTRUCTION. Every write returns the page, the setting,
/// the old value and the new one in its tool result, and a tool result is
/// exactly what `appendToolMessage` writes to the transcript — so the person
/// reads the change in the same receipt trail every other tool call leaves.
/// Nothing here writes a receipt of its own, because a second trail is a
/// trail that can disagree with the first.
@MainActor
final class QuietSelfAdmin {
    static let shared = QuietSelfAdmin()

    /// The live model the visible window is bound to — attached at launch
    /// (NativeAgentApp.swift), the same way DetachedChatWindowController gets
    /// it. Weak: the app owns it, this does not.
    private weak var attached: AppModel?

    private init() {}

    func attach(appModel: AppModel) {
        attached = appModel
    }

    /// nil on a headless or test process that never built a window. Every
    /// caller refuses plainly rather than inventing a second AppModel — a
    /// second one would read and write state the visible page never sees.
    var appModel: AppModel? { attached }
}

// MARK: - Pages

/// One rail page, by the plain name the agent uses for it.
///
/// The ids are the words a person sees on the rail (`SidebarItem.shellRailTitle`),
/// lowercased — "today", not "activity"; "notifications", not "inbox policy" —
/// because the model is describing the screen to the person, and the two must
/// use one vocabulary.
struct QuietPage: Sendable, Equatable {
    let id: String
    let title: String
    let item: SidebarItem
    /// One line for `app_page_read` and the catalog, so the model can choose a
    /// page without screenshotting all of them first.
    let summary: String
}

enum QuietPages {
    static let all: [QuietPage] = [
        QuietPage(id: "chat", title: "Chat", item: .chat,
                  summary: "Conversations, attachments, voice, sessions, and the agent's name and status."),
        QuietPage(id: "today", title: "Today", item: .activity,
                  summary: "Notifications, approvals, proposals, recent work, and what is waiting."),
        QuietPage(id: "memories", title: "Memories", item: .memories,
                  summary: "Saved facts, pending proposals, and the knowledge graph."),
        QuietPage(id: "desk", title: "Desk", item: .desk,
                  summary: "Projects, dependencies, schedules, pursuits, progress and outcomes."),
        QuietPage(id: "notifications", title: "Notifications", item: .inboxPolicy,
                  summary: "The proactive inbox, its triggers, watched folders, and history."),
        QuietPage(id: "bots", title: "Bots", item: .bots,
                  summary: "Standing briefs on a schedule or an event, and their dated replies."),
        QuietPage(id: "personality", title: "Personality", item: .personality,
                  summary: "Identity, expression, about-you, growth and working-guideline documents; minds and dreams."),
        QuietPage(id: "providers", title: "Providers", item: .providers,
                  summary: "Connected AI accounts and the model each activity group runs on."),
        QuietPage(id: "trust", title: "Trust", item: .trust,
                  summary: "Presets, feature permissions, approvals, and Mac integration access."),
        QuietPage(id: "connectors", title: "Connectors", item: .connectors,
                  summary: "Service connections, with MCP, Telegram and iPhone tabs."),
        QuietPage(id: "capabilities", title: "Capabilities", item: .capabilities,
                  summary: "What the agent can actually do, action by action."),
        QuietPage(id: "diagnostics", title: "Diagnostics", item: .diagnostics,
                  summary: "Doctor, Status, Runs log, Cognition, Inspector, Skills and Tools."),
        QuietPage(id: "settings", title: "Settings", item: .settings,
                  summary: "Appearance, shortcuts, updates, an inner life, and memory in every reply."),
    ]

    static var ids: [String] { all.map(\.id) }

    /// Forgiving on the way in: the rail word, the enum's raw value, and the
    /// obvious synonyms all resolve, because a model that has read the screen
    /// will call the page what the screen calls it.
    static func page(named raw: String) -> QuietPage? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let exact = all.first(where: { $0.id == key }) { return exact }
        switch key {
        case "activity": return page(named: "today")
        case "inbox", "inbox policy", "inbox_policy", "proactive": return page(named: "notifications")
        case "memory": return page(named: "memories")
        case "provider", "models": return page(named: "providers")
        case "trust center", "trust_center", "permissions": return page(named: "trust")
        case "setup", "preferences": return page(named: "settings")
        case "skills", "tools": return page(named: "diagnostics")
        default:
            return all.first { $0.title.lowercased() == key || $0.item.rawValue.lowercased() == key }
        }
    }
}

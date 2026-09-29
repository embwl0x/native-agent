import AppToolRuntime
import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

enum SkillsToolsSection: String, CaseIterable, Identifiable, Sendable {
    case skills = "Skills"
    case tools = "Tools"

    var id: String { rawValue }
}

// PATCH-2026-05-19: ui-pull-together — keep the primary Mac sidebar compact:
// Chat, Activity, Memories, Skills & Tools, Desk, Providers, Trust, Mac Integration, Settings. Feature-specific
// control rooms stay in Advanced and the command palette instead of competing
// as always-visible tabs.
// Legacy cases (memory, settingsHub, approvals, work, skillLifecycle) stay
// defined as routing aliases so existing @SceneStorage state restores cleanly
// to the new tabs via `.normalized`.
enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    // ── Primary (compact, always visible) ─────────────────────────────────
    case chat = "Chat"
    case bots = "Bots" // Default-on since 0.4.10 (the rail injects it; see BotsShelfPreference); not in the unflagged destination lists.
    case activity = "Activity"           // approvals + inbox + proposals
    case memories = "Memories"           // was: memory (hub); now: just the memory list
    case skills = "Skills"               // displayed as Skills & Tools; owns both subpages
    case desk = "Desk"                   // the agent's canonical planning and work surface
    case trust = "Trust"                 // policy, autonomy, Mac control
    case providers = "Providers"
    case macIntegration = "Mac Integration" // per-integration READ/WRITE permission toggles (Calendar, Mail, Messages, ...)
    case settings = "Settings"           // slim: voice + appearance + pairing + about

    // ── Advanced (disclosure-toggle reveal) ───────────────────────────────
    // personality + connectors are Advanced (set-once tabs) — they live in
    // `advancedItems`, not `primaryItems`; keep the case lines here to match.
    case personality = "Personality"     // agent identity and voice
    case connectors = "Connectors"
    case command = "Command Center"
    case capabilities = "Capabilities"
    case autoImprovement = "Self-Improvement"
    case knowledge = "Knowledge Graph"
    case dreams = "Dreams"               // dream diary + REM consolidation controls (identity-adjacent)
    case cognition = "Cognition"
    case diagnostics = "Diagnostics"     // Doctor + Status + Runs Log
    case inboxPolicy = "Inbox Policy"
    case panels = "Panels"
    case mcp = "MCP"                     // MCP server hub: registry, tools, consent, recent calls
    case inspector = "Inspector"         // Turn Inspector: live per-turn readout + replay (W3)

    // ── Routed child surfaces (not listed as sidebar rows) ────────────────
    case telegram = "Telegram"           // Settings child + command route
    case tools = "Tools"                 // Skills & Tools child page + command route

    // ── Legacy aliases (still parseable from saved state) ─────────────────
    case memory = "Memory"               // alias → .memories
    case settingsHub = "Settings (Hub)"  // alias → .settings
    case approvals = "Approvals"         // alias → .activity
    case workshop = "Workshop"           // retired presentation alias → .desk
    case legacyWorkshop = "Executions"   // compatibility route alias → .desk
    case work = "Work"                   // alias → .desk
    case skillLifecycle = "Skill Lifecycle" // alias → .skills
    // Retired tabs (2026-07-03 dead-weight sweep) — cases kept so saved
    // selections and command routes still parse:
    //   Self-Improvement folded into Activity (its drill-in was already there);
    //   Panels' dynamic layer could never work on the Swift build.

    var id: String { rawValue }

    /// Map legacy aliases to their current home so saved state still routes correctly.
    var normalized: SidebarItem {
        switch self {
        case .memory: .memories
        case .settingsHub: .settings
        case .approvals: .activity
        case .workshop, .legacyWorkshop, .work: .desk
        case .skillLifecycle, .tools: .skills
        case .autoImprovement: .activity   // tab retired 2026-07-03; SI lives in Activity
        case .panels: .diagnostics         // tab retired 2026-07-03; dynamic layer was dead
        case .command: .desk               // Command Center retired 2026-07-23 → its one
                                           // real control (Create Task) now lives on the Desk
        default: self
        }
    }

    // 2026-06-06: Executions promoted to primary (daily-use, was buried in
    // Advanced causing sidebar auto-scroll to pull it to top on click).
    // Personality + Connectors stay Advanced — set-once tabs.
    // 2026-07-22: Trust promoted to primary between Providers and Mac
    // Integration — it's one of the first pages a new user should see.
    // ui-simplify 2026-09-02 (Lane A): five places, not nine. Four of the old
    // nine primaries were SETUP, not use — they moved behind Settings ▸
    // Advanced, where a person goes once.
    // User, 2026-09-04: Advanced emptied onto the rail. Memories, Personality,
    // Trust, Connectors and Diagnostics carry tabs (ShellRailPages.swift);
    // Providers, Capabilities and Notifications stand alone. Settings stays
    // last, at the bottom.
    static let primaryItems: [SidebarItem] = [
        .chat, .activity, .memories, .desk, .inboxPolicy,
        .personality, .providers, .trust, .connectors, .capabilities, .diagnostics, .settings,
    ]

    /// The first tab of a rail page that carries tabs; nil for a plain page.
    static func shellFirstTab(for item: SidebarItem) -> String? {
        switch item.normalized {
        case .memories: "memories"
        case .personality: "personality"
        case .trust: "trust"
        case .connectors: "connectors"
        case .diagnostics: "Doctor"
        default: nil
        }
    }

    /// Where a former Advanced page lives in the new shell when it became a
    /// tab: the rail page that hosts it and the tab's persisted key.
    static func shellHome(for item: SidebarItem) -> (parent: SidebarItem, tab: String)? {
        switch item.normalized {
        case .knowledge: (.memories, "knowledge")
        case .dreams: (.personality, "dreams")
        case .macIntegration: (.trust, "mac")
        case .mcp: (.connectors, "mcp")
        case .telegram: (.connectors, "telegram")
        case .cognition: (.diagnostics, "Cognition")
        case .inspector: (.diagnostics, "Inspector")
        case .skills: (.diagnostics, "skills")
        default: nil
        }
    }

    // The pages that are tabs now. Still listed so the palette and deep links
    // reach them; each lands on its rail page with that tab open.
    static let advancedItems: [SidebarItem] = [
        .skills, .macIntegration, .knowledge, .dreams, .mcp, .cognition, .inspector,
    ]

    // Returns true for items shown in the Advanced disclosure section
    var isAdvanced: Bool {
        SidebarItem.advancedItems.contains(self)
    }

    var systemImage: String {
        switch self {
        // Primary
        case .chat: "bubble.left.and.bubble.right"
        case .bots: "books.vertical"
        case .activity: "tray.full"
        case .memories: "brain"
        case .skills: "puzzlepiece.extension"
        case .desk: "checklist"
        case .personality: "person.crop.circle"
        case .connectors: "point.3.connected.trianglepath.dotted"
        case .trust: "lock.shield"
        case .providers: "server.rack"
        case .macIntegration: "gearshape.2"
        case .settings: "gearshape"
        // Advanced
        case .command: "rectangle.3.group"
        case .capabilities: "shippingbox"
        case .autoImprovement: "wand.and.stars"
        case .knowledge: "circle.hexagonpath"
        case .dreams: "moon.stars"
        case .cognition: "brain.head.profile"
        case .diagnostics: "stethoscope"
        case .telegram: "paperplane"
        case .inboxPolicy: "tray.and.arrow.down"
        case .panels: "rectangle.grid.2x2"
        case .tools: "wrench.and.screwdriver"
        case .mcp: "network"
        case .inspector: "waveform.path.ecg"
        // Legacy aliases — use the normalized icon
        case .memory: "brain"
        case .settingsHub: "gearshape"
        case .approvals: "tray.full"
        case .workshop: "hammer"
        case .legacyWorkshop: "target"
        case .work: "hammer"
        case .skillLifecycle: "puzzlepiece.extension"
        }
    }

    var displayName: String {
        switch normalized {
        case .skills: "Skills & Tools"
        // User, 2026-09-04: they are notifications, everywhere they are named.
        case .inboxPolicy: "Notifications"
        // The page calls them helpers; the route id stays "Bots".
        case .bots: "Helpers"
        default: rawValue
        }
    }

    /// One plain sentence under a rail page's title, in the agent's own voice —
    /// the same line Today, Memories and the Desk carry. Nil means the page
    /// writes its own (or needs none).
    var shellPageSubtitle: String? {
        switch normalized {
        case .providers: "I think with the model accounts you connect here."
        case .capabilities: "This is what I can do, what's installed, and what needs a look."
        case .inboxPolicy: "I decide here what to bring you and what to keep quiet."
        case .bots: "I run small jobs on my own here, on a schedule you set."
        case .trust: "This is what I'm allowed to do on this Mac without asking you first."
        case .connectors: "I reach your other apps and services through what you connect here."
        case .diagnostics: "This is how I'm running, and what to check when something looks wrong."
        case .personality: "This is who I am here — my name, my voice, and the documents behind them."
        default: nil
        }
    }

    // ui-simplify 2026-09-02: the rail is icon-over-word, so it carries the
    // word a person would use rather than the internal tab name. Activity is
    // "Today" on the rail; the destination and every route are unchanged (Lane
    // C replaces the view behind it later). `displayName` stays as-is so the
    // command palette and deep links keep their existing vocabulary.
    var shellRailTitle: String {
        switch normalized {
        case .activity: "Today"
        case .skills: "Skills"
        // User, 2026-09-04: they are notifications, and more controls will join them.
        case .inboxPolicy: "Notifications"
        case .bots: "Helpers"
        default: rawValue
        }
    }

}

// ActivityEvent moved to NativeAgentShared.

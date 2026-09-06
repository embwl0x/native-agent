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
    // Advanced, where a person goes once. The previous nine survive as
    // `classicPrimaryItems` so the `uiClassicShell` kill switch restores the
    // old shell exactly.
    // User, 2026-09-04: Advanced emptied onto the rail. Memories, Personality,
    // Trust, Connectors and Diagnostics carry tabs (ShellRailPages.swift);
    // Providers, Capabilities and Notifications stand alone. Settings stays
    // last, at the bottom.
    static let shellPrimaryItems: [SidebarItem] = [
        .chat, .activity, .memories, .personality, .providers, .trust, .connectors,
        .diagnostics, .capabilities, .inboxPolicy, .desk, .settings,
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

    static let classicPrimaryItems: [SidebarItem] = [
        .chat, .activity, .memories, .desk, .skills, .providers, .trust, .macIntegration, .settings,
    ]

    static var primaryItems: [SidebarItem] {
        NativeAgentShellPreference.isClassic() ? classicPrimaryItems : shellPrimaryItems
    }

    // Authoritative full Advanced set — the single source of membership.
    // 2026-07-23: `.command` removed (Command Center retired; case survives as
    // a normalized alias → .desk). Consumer-facing set-once tabs come
    // first, developer/internal surfaces after.
    // 2026-09-02: the four setup pages (Skills & Tools, Providers, Trust, Mac
    // Integration) join the consumer half — same views, one door in.
    static let classicAdvancedItems: [SidebarItem] = [
        // B2.4/B2.6: .cognition and .inspector are route-only now — their
        // content renders as Diagnostics segments (see ContentView), so they
        // are not sidebar rows in ANY bucket. Diagnostics itself is
        // developer-gated, which keeps both behind the same gate.
        .personality, .connectors,
        .capabilities, .knowledge, .dreams, .diagnostics,
        .inboxPolicy, .mcp,
    ]

    // The pages that are tabs now. Still listed so the palette and deep links
    // reach them; each lands on its rail page with that tab open.
    static let shellAdvancedItems: [SidebarItem] = [
        .skills, .macIntegration, .knowledge, .dreams, .mcp, .cognition, .inspector,
    ]

    static var advancedItems: [SidebarItem] {
        NativeAgentShellPreference.isClassic() ? classicAdvancedItems : shellAdvancedItems
    }

    // 2026-07-23 (B2.2): developer/internal surfaces. A collapsed disclosure
    // is NOT a gate — these expose raw internals (Turn Inspector, MCP, the
    // Cognition observatory, Knowledge Graph) a stranger should never reach by
    // accident. They render only when the "showDeveloperSurfaces" UI-visibility
    // preference is on (see ContentView / CommandPalette / SlimSettingsView).
    // This is deliberately NOT coupled to Trust Center's developerMode policy
    // field, which is a security-domain object.
    static var developerItems: [SidebarItem] {
        // B2.4/B2.6: .cognition and .inspector no longer appear as sidebar
        // rows — their content lives as Diagnostics segments and their routes
        // render those segments directly (ContentView), so listing them here
        // would duplicate the Diagnostics row for developers. Deep links to
        // both still land on the segment content.
        // User, 2026-09-04: in the new shell Diagnostics, Capabilities and
        // Notifications sit on the rail for everyone, so the gate covers only
        // what is still filed under Advanced there.
        // User, 2026-09-04: and the new shell gates nothing at all.
        guard NativeAgentShellPreference.isClassic() else { return [] }
        return advancedItems.filter {
            [.capabilities, .knowledge, .dreams, .diagnostics, .inboxPolicy, .mcp].contains($0)
        }
    }

    // Advanced rows always visible to consumers (set-once config tabs):
    // the authoritative Advanced set minus the developer-gated surfaces.
    static var consumerAdvancedItems: [SidebarItem] {
        advancedItems.filter { !developerItems.contains($0) }
    }

    // The Advanced rows to render for a given developer-surfaces preference.
    // Off → consumer-only; on → the full authoritative set. Lossless:
    // consumerAdvancedItems and developerItems partition advancedItems, so no
    // item is ever dropped — a developer surface hidden here is still reachable
    // by deep link (the detail switch renders it regardless of row visibility).
    static func visibleAdvancedItems(developerSurfacesEnabled: Bool) -> [SidebarItem] {
        developerSurfacesEnabled ? advancedItems : consumerAdvancedItems
    }

    // Returns true for items shown in the Advanced disclosure section
    var isAdvanced: Bool {
        SidebarItem.advancedItems.contains(self)
    }

    // Returns true for developer/internal surfaces gated behind showDeveloperSurfaces.
    var isDeveloperSurface: Bool {
        SidebarItem.developerItems.contains(self)
    }

    var systemImage: String {
        switch self {
        // Primary
        case .chat: "bubble.left.and.bubble.right"
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
        default: rawValue
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
        default: rawValue
        }
    }

    /// Rail glyph. Falls back to the sidebar's own icon for anything the rail
    /// does not name explicitly.
    var shellSystemImage: String {
        switch normalized {
        case .chat: "bubble.left"
        case .activity: "waveform.path.ecg"
        case .memories: "book.closed"
        case .desk: "tablecells"
        case .settings: "gearshape"
        default: systemImage
        }
    }
}

// ActivityEvent moved to NativeAgentShared.

import ChatSessionWork
// Blueprint: | `ConversationRoutes.swift` | Saved SidebarItem route vocabulary and aliases, shell tab homes, SkillsToolsSection and fixed conversation provenance labels |

public enum SkillsToolsSection: String, CaseIterable, Identifiable, Sendable {
    case skills = "Skills"
    case tools = "Tools"

    public var id: String { rawValue }
}

public enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    // ── Page routes ─────────────────────────────────────────────────────
    case chat = "Chat"
    case bots = "Bots" // Injected by BotsShelfPreference; absent from unflagged destination lists.
    case activity = "Activity"           // approvals + inbox + proposals
    case memories = "Memories"           // memory list
    case skills = "Skills"               // displayed as Skills & Tools; owns both subpages
    case desk = "Desk"                   // the agent's canonical planning and work surface
    case trust = "Trust"                 // policy, autonomy, Mac control
    case providers = "Providers"
    case macIntegration = "Mac Integration" // per-integration READ/WRITE permission toggles (Calendar, Mail, Messages, ...)
    case settings = "Settings"           // slim: voice + appearance + pairing + about

    // ── Additional routes ───────────────────────────────────────────────
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
    case inspector = "Inspector"         // live per-turn readout and replay

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
    public var id: String { rawValue }

    /// Map legacy aliases to their current home so saved state still routes correctly.
    public var normalized: SidebarItem {
        switch self {
        case .memory: .memories
        case .settingsHub: .settings
        case .approvals: .activity
        case .workshop, .legacyWorkshop, .work: .desk
        case .skillLifecycle, .tools: .skills
        case .autoImprovement: .activity   // Self-Improvement lives in Activity
        case .panels: .diagnostics
        case .command: .desk               // Create Task lives on the Desk
        default: self
        }
    }

    /// The rail page hosting a routed tab and the tab's persisted key.
    public static func shellHome(for item: SidebarItem) -> (parent: SidebarItem, tab: String)? {
        switch item.normalized {
        case .knowledge: (.memories, "knowledge")
        case .dreams: (.personality, "dreams")
        case .macIntegration: (.trust, "mac")
        case .telegram: (.connectors, "telegram")
        case .cognition: (.diagnostics, "Cognition")
        case .inspector: (.diagnostics, "Inspector")
        case .skills: (.diagnostics, "skills")
        default: nil
        }
    }

    public var systemImage: String {
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

    public var displayName: String {
        switch normalized {
        case .skills: "Skills & Tools"
        case .inboxPolicy: "Notifications"
        // The page calls them helpers; the route id stays "Bots".
        case .bots: "Helpers"
        default: rawValue
        }
    }

    /// Rail wording; display names and deep-link vocabulary stay unchanged.
    public var shellRailTitle: String {
        switch normalized {
        case .activity: "Today"
        case .skills: "Skills"
        case .inboxPolicy: "Notifications"
        case .bots: "Helpers"
        default: rawValue
        }
    }

}

/// Fixed provenance labels never render raw recorded origin strings;
/// unknown origins are automated, never human-authored.
public struct MacChatMessageProvenance: Sendable, Equatable {
    /// Fixed display text. Always a compile-time constant from this file —
    /// never interpolated from a recorded value.
    public let label: String
    /// SF Symbol name. Also always a constant from this file.
    public let symbol: String
    /// True for automated/non-human ingress. This drives the stronger visual
    /// treatment; it is not a cryptographic claim about a named process.
    public let isAutomated: Bool

    public static func make(role: String, source: String?, origin: ChatMessageOriginMetadata?) -> MacChatMessageProvenance? {
        guard let provenance = SessionMessageProvenance.make(
            role: role, source: source, hasOrigin: origin != nil,
            surface: origin?.surface, agent: origin?.agent
        ) else { return nil }
        switch provenance {
        case .claude: return .init(label: "Claude - bridge", symbol: "arrow.triangle.branch", isAutomated: true)
        case .codex: return .init(label: "Codex - bridge", symbol: "arrow.triangle.branch", isAutomated: true)
        case .telegram: return .init(label: "Telegram", symbol: "paperplane", isAutomated: false)
        case .slack: return .init(label: "Slack", symbol: "bubble.left.and.bubble.right", isAutomated: false)
        case .iPhone: return .init(label: "iPhone", symbol: "iphone", isAutomated: false)
        case .scheduled: return .init(label: "Scheduled", symbol: "clock.arrow.circlepath", isAutomated: true)
        case .automated: return .init(label: "Automated", symbol: "gearshape.arrow.triangle.2.circlepath", isAutomated: true)
        }
    }
}

import Foundation

/// How each surface lays out its named blocks: their order, which are hidden,
/// whether a fold starts open, and per view (a profile: simple, advanced or
/// agent, the `nativeagent.viewMode` values) which blocks that view leaves
/// out. One document, ui/layout.json under the data root: written by the
/// Mac's `SurfaceLayoutStore`, drawn by the Mac's views and her home, and
/// carried to the phone in the core snapshot. Blocks, order, hidden,
/// expanded and profiles only: nothing here names a colour, a font, a
/// material or a size.
public struct SurfaceLayout: Codable, Sendable, Equatable {
    public struct Block: Codable, Sendable, Equatable {
        public var name: String
        public var hidden: Bool
        /// Only on a block that folds: whether it starts open.
        public var expanded: Bool?

        public init(name: String, hidden: Bool = false, expanded: Bool? = nil) {
            self.name = name; self.hidden = hidden; self.expanded = expanded
        }
    }

    public struct Profile: Codable, Sendable, Equatable {
        /// "surface.block" names this view leaves out.
        public var hidden: [String]
    }

    /// 1 as seeded; each write bumps it. A hand edit bumps nothing.
    public var layoutVersion: Int
    /// The app build whose seed this layout started from.
    public var seededFrom: String
    public var updatedAt: String
    /// What wrote this version: seed, her or person.
    public var source: String
    /// The layout's digest as this app last wrote it; a hand edit leaves it behind.
    public var digest: String
    public var surfaces: [String: [Block]]
    public var profiles: [String: Profile]
    /// The profile the phone shows.
    public var phone: String

    public static let path = "ui/layout.json"

    /// Home's PLACES rows: the places seed, and where a row breaks.
    public static let placeRows: [[String]] = [
        ["mail", "calendar", "desk", "files", "browser"],
        ["memory", "skills", "research", "messages", "reminders", "today", "replies", "create", "connections", "crews", "delegations", "code", "github"],
        ["gmail", "agentmail", "notes", "contacts", "music", "markets", "x", "slack", "notion", "gcal", "notify", "status", "activity", "app"],
    ]

    /// Every surface, what it is, and its blocks in seed order with what each
    /// shows (empty when the name says it). The seed and the vocabulary: a
    /// name not here is refused, and one a newer build adds is placed at its
    /// seed position in a layout that lacks it.
    public static let vocabulary: [(surface: String, about: String, blocks: [(name: String, shows: String)])] = [
        ("home", "Her home (app {} and the Agent view), top to bottom; people and helpers are also the Simple sidebar's Agents and Helpers, in this order", [
            ("notable", "NOTABLE TODAY"), ("changed", "CHANGED since she last looked"), ("waits", "what waits on the person"),
            ("queue", "MY QUEUE"), ("working", "WORKING: crews at work"), ("open", "OPEN: this chat's windows"),
            ("people", "PEOPLE: the agents she talks to"), ("helpers", "HELPERS"), ("senses", "MY SENSES"),
            ("elsewhere", "ELSEWHERE"), ("places", "PLACES, in the places order"), ("mac", "MAC"),
        ]),
        ("places", "Home's PLACES rows and the Agent view's rooms; a hidden place that names a page also leaves app {}'s page index", placeRows.joined().map { ($0, "") }),
        ("rail", "Advanced's rail, top to bottom, the last shown at its foot; a hidden page also leaves app {}'s page index", [
            ("chat", ""), ("today", ""), ("memories", ""), ("desk", ""), ("notifications", ""), ("bots", "Helpers"),
            ("divider", "the line between the rail's two groups"), ("personality", ""), ("providers", ""), ("trust", ""),
            ("connectors", ""), ("capabilities", ""), ("diagnostics", ""), ("settings", ""),
        ]),
        ("chat", "The chat's conversations column, top to bottom (Simple's profile hides it); expanded is whether a fold starts open", [
            ("rows", "the conversations"), ("briefs", "Briefs (folds)"), ("working", "Working: bridge and agent sessions (folds)"),
        ]),
        ("today", "The Today page, top to bottom", [
            ("waiting", "what waits on the person"), ("earlier", "notes from earlier days"), ("did", "What I did today"),
            ("ahead", "what's ahead"), ("queues", "the queue links"),
        ]),
        ("tabs.memories", "Memories' tabs, left to right", [("memories", ""), ("knowledge", "Knowledge graph")]),
        ("tabs.personality", "Personality's tabs, left to right", [("personality", ""), ("minds", "My minds"), ("dreams", "")]),
        ("tabs.trust", "Trust's tabs, left to right", [("trust", "Access"), ("features", ""), ("mac", ""), ("advanced", "")]),
        ("tabs.connectors", "Connectors' tabs, left to right", [("connectors", ""), ("agents", ""), ("mcp", ""), ("telegram", ""), ("iphone", "")]),
        ("tabs.capabilities", "Capabilities' tabs, left to right", [("capabilities", "What I can do"), ("installed", "What's installed"), ("senses", "")]),
        ("tabs.diagnostics", "Diagnostics' tabs, left to right", [
            ("Doctor", "Health checks"), ("Status", ""), ("Runs Log", "Run history"), ("Cognition", ""),
            ("Inspector", "Chat turn details"), ("skills", ""), ("tools", ""),
        ]),
        ("more", "The iPhone's More page, top to bottom", [("rooms", "Rooms"), ("setup", "Setup"), ("power", "Power user")]),
    ]

    /// Blocks that fold, and so carry `expanded`; each starts closed.
    public static let folds: Set<String> = ["chat.briefs", "chat.working"]

    public static let profilesAbout = "simple, advanced and agent are the window's views (settings.view_mode shows one); each hides surface.block names in that view only. phone is the profile the iPhone shows."

    /// Today's hardcoded orders. Simple shows no conversations column.
    public static func seed(from build: String, at: String, hidden: Set<String> = []) -> SurfaceLayout {
        var surfaces: [String: [Block]] = [:]
        for (surface, _, blocks) in vocabulary {
            surfaces[surface] = blocks.map { block in
                let key = surface + "." + block.name
                return Block(name: block.name, hidden: hidden.contains(key), expanded: folds.contains(key) ? false : nil)
            }
        }
        return SurfaceLayout(layoutVersion: 1, seededFrom: build, updatedAt: at, source: "seed", digest: "", surfaces: surfaces,
                             profiles: ["simple": Profile(hidden: ["chat.rows", "chat.briefs", "chat.working"]),
                                        "advanced": Profile(hidden: []), "agent": Profile(hidden: [])],
                             phone: "simple")
    }

    /// A surface, profile or block a newer build added, at its seed position:
    /// after the nearest block that comes before it in the seed.
    public mutating func addMissing() {
        let fresh = Self.seed(from: seededFrom, at: updatedAt)
        for (surface, seeded) in fresh.surfaces {
            var blocks = surfaces[surface] ?? []
            for (index, block) in seeded.enumerated() where !blocks.contains(where: { $0.name == block.name }) {
                let after = seeded[..<index].reversed().lazy.compactMap { prior in blocks.firstIndex { $0.name == prior.name } }.first
                blocks.insert(block, at: after.map { $0 + 1 } ?? 0)
            }
            surfaces[surface] = blocks
        }
        for (name, profile) in fresh.profiles where profiles[name] == nil { profiles[name] = profile }
    }

    /// A surface's blocks as `profile` shows them, in order.
    public func shown(_ surface: String, profile: String?) -> [Block] {
        let off = Set(profile.flatMap { profiles[$0]?.hidden } ?? [])
        return (surfaces[surface] ?? []).filter { !$0.hidden && !off.contains(surface + "." + $0.name) }
    }

    /// `items` in the surface's order as `profile` shows them; one the
    /// layout hides is left out.
    public func arranged<Item>(_ surface: String, profile: String?, _ items: [Item], name: (Item) -> String) -> [Item] {
        shown(surface, profile: profile).compactMap { block in items.first { name($0) == block.name } }
    }

    public func isShown(_ surface: String, _ name: String, profile: String?) -> Bool {
        shown(surface, profile: profile).contains { $0.name == name }
    }

    public func expanded(_ surface: String, _ name: String) -> Bool {
        surfaces[surface]?.first { $0.name == name }?.expanded ?? false
    }
}

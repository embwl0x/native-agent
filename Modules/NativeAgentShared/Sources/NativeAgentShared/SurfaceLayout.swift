import Foundation
// Blueprint: | `SurfaceLayout.swift` | `SurfaceLayout` struct: the layout document's shape, vocabulary and seed; `addMissing`, `shown`, `arranged` for the Mac and the phone; `QuietToolPage` owns the shared page definitions including inbox/unindexed reads; `AppDoorNames` shares page/item aliases, the door's page resolution (`step`, `place`: alias, `page/item` split, home rooms) and derives accepted part face pages from those definitions |

public struct QuietToolPage: Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public init(id: String, title: String, summary: String) {
        self.id = id; self.title = title; self.summary = summary
    }

    public static let all: [QuietToolPage] = [
        QuietToolPage(id: "chat", title: "Chat",
                  summary: "Conversations, attachments, voice, agent name and status. Background read: page:chat, item:<conversation id>, 8 messages (args {limit}: max 16). Resolve with chat.list; older history: chat.search {session_id, sort:newest, limit:12}, no query; follow next_call. chat.message expands clipped bodies. Screen controls are separate actions."),
        QuietToolPage(id: "today", title: "Today",
                  summary: "Notifications, approvals, proposals, recent work, and what is waiting."),
        QuietToolPage(id: "memories", title: "Memories",
                  summary: "Saved facts, pending proposals, and the knowledge graph."),
        QuietToolPage(id: "desk", title: "Desk",
                  summary: "Projects, dependencies, schedules, pursuits, progress and outcomes."),
        QuietToolPage(id: "notifications", title: "Notifications",
                  summary: "The proactive inbox, its triggers, watched folders, and history."),
        QuietToolPage(id: "bots", title: "Helpers",
                  summary: "Standing briefs on a schedule or an event, and their dated replies."),
        QuietToolPage(id: "personality", title: "Personality",
                  summary: "Identity, expression, about-you, growth and working-guideline documents; minds and dreams."),
        QuietToolPage(id: "providers", title: "Providers",
                  summary: "Connected AI accounts and the model each activity group runs on."),
        QuietToolPage(id: "trust", title: "Trust",
                  summary: "Presets, feature permissions, approvals, and Mac integration access."),
        QuietToolPage(id: "connectors", title: "Connectors",
                  summary: "Service connections, with Agents, Telegram and iPhone tabs."),
        QuietToolPage(id: "telegram", title: "Telegram",
                  summary: "Telegram on or off, who may reach the agent, mention-only, its model, test reply and logs."),
        QuietToolPage(id: "mac_integration", title: "Mac Integration",
                  summary: "Read and write access per Mac app: Calendar, Mail, Messages, Notes and the rest."),
        QuietToolPage(id: "pairing", title: "iPhone pairing",
                  summary: "Paired phones and the iCloud pairing status."),
        QuietToolPage(id: "agents", title: "Agents",
                  summary: "Agent contacts and coding helpers: message, read, connect, stop, recipes, bridge jobs, and Claude's worklog of what she has been doing and working on, newest first."),
        // Each Mac app and connector her actions reach is a page of its own:
        // its access or connection, and its actions. A Mac app's page is
        // where User sets its access (Trust → Mac integration).
        QuietToolPage(id: "mail", title: "Mail",
                  summary: "Apple Mail (every account added to Mail, Gmail included): read, search, triage, send and reply."),
        QuietToolPage(id: "calendar", title: "Calendar",
                  summary: "Calendar: events, free/busy, create, change and delete."),
        QuietToolPage(id: "reminders", title: "Reminders",
                  summary: "Reminders: due today, search, read, create, update, complete and delete."),
        QuietToolPage(id: "notes", title: "Notes", summary: "Apple Notes: search, create and update."),
        QuietToolPage(id: "contacts", title: "Contacts",
                  summary: "Contacts: search, create or update, and delete."),
        QuietToolPage(id: "messages", title: "Messages", summary: "Messages: recent threads, and send."),
        QuietToolPage(id: "slack", title: "Slack", summary: "Slack's connection and the model the agent answers Slack with."),
        // Her hands on the Mac and the web. Files, the shell and the browser
        // are Trust's to allow.
        QuietToolPage(id: "files", title: "Files",
                  summary: "Read, list, search, excerpt and write files; apply a patch; Spotlight."),
        QuietToolPage(id: "shell", title: "Shell",
                  summary: "Shell commands, git, Swift builds and tests, remote nodes, and restarting or installing the app."),
        QuietToolPage(id: "web", title: "Web",
                  summary: "Read a public page privately, and search the web."),
        QuietToolPage(id: "browser", title: "Browser",
                  summary: "The NativeAgent browser and your own Chrome tab: open, read, links, screenshots, clicks and forms."),
        // Her hands on the Mac itself: Full Mac's accessibility category is
        // Trust's to allow; Music's access is Mac integration's.
        QuietToolPage(id: "mac", title: "Mac",
                  summary: "The live screen: look, act by name, go to an app, file or URL, wait, read a document, menus, the clipboard, system info and app activity."),
        QuietToolPage(id: "music", title: "Music",
                  summary: "Apple Music: what's playing, play, pause or skip, search the library, tracks and playlists."),
        QuietToolPage(id: "capabilities", title: "Capabilities",
                  summary: "What the agent can actually do, action by action."),
        QuietToolPage(id: "diagnostics", title: "Diagnostics",
                  summary: "Doctor, Status, Runs log, Cognition and Inspector."),
        QuietToolPage(id: "skills", title: "Skills",
                  summary: "Built-in guidance from the persona, to read."),
        QuietToolPage(id: "tools", title: "Tools",
                  summary: "Available tools and their access, and the abilities the agent grew: read, save, keep and manage them."),
        QuietToolPage(id: "settings", title: "Settings",
                  summary: "Appearance, shortcuts, updates, and the switches for an inner life, dreams and memory."),
    ]


    public static let inbox = QuietToolPage(
        id: "inbox", title: "Inbox", summary: "Today's Inbox: the notes Today and the Desk count, by id and state.")
    public static let unindexed = [
        QuietToolPage(id: "context", title: "Context", summary: ""),
        QuietToolPage(id: "agent_view", title: "Agent view", summary: ""),
    ]

    public static var ids: [String] { all.map(\.id) }

    public static func page(named raw: String) -> QuietToolPage? {
        let key = AppDoorNames.resolve(raw)
        return all.first { $0.id == key }
    }
}

/// The door's read names. Layout block ids remain storage keys, never aliases on disk.
public enum AppDoorNames {
    public static let partPages = ([QuietToolPage.inbox] + QuietToolPage.all + QuietToolPage.unindexed).map(\.id)
    public static let places = ["desk": "ongoing", "mac": "computer", "memories": "memory", "bots": "helpers", "notifications": "notify"]

    public static let aliases: [String: String] = [
        "approvals": "today", "approval": "today", "pending approvals": "today",
        "inbox policy": "notifications", "inbox_policy": "notifications", "proactive": "notifications",
        "memory": "memories", "moments": "memories", "provider": "providers", "models": "providers",
        "trust center": "trust", "trust_center": "trust", "permissions": "trust",
        "setup": "settings", "preferences": "settings", "iphone": "pairing", "phone": "pairing",
        "pair": "pairing", "pairing devices": "pairing", "iphone pairing": "pairing", "chrome": "browser",
        "ongoing": "desk", "computer": "mac", "skill": "skills", "agent": "agents", "abilities": "tools", "ability": "tools",
        "bot": "bots", "helpers": "bots", "connector": "connectors", "mac integration": "mac_integration",
        "skills & tools": "skills",
        "health": "status", "doctor": "diagnostics/doctor",
    ]

    /// Places without a rail page keep their own room and all of its capabilities.
    public static let homeItems: Set<String> = [
        "research", "replies", "create", "connections", "crews", "delegations", "code",
        "notify", "status", "activity",
    ]

    public static func resolve(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return aliases[key] ?? key
    }

    /// One step of where the door takes a call's page before anything reads
    /// or acts (`AppToolExecutor.runAppDoor`): an alias resolves and a
    /// `page/item` path splits (`label` is the resolved page); with no action
    /// and no item, a home room named as a page becomes home's item and `app`
    /// is home (an empty `page` means none). Nil when the place is final.
    public static func step(page: String, item: String, action: Bool) -> (page: String, item: String?, label: String)? {
        let requested = page.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = resolve(requested)
        let parts = canonical.split(separator: "/", maxSplits: 1).map(String.init)
        if !requested.isEmpty, let first = parts.first, requested != canonical || parts.count == 2 {
            return (first, parts.count == 2 ? parts[1] : nil, canonical)
        }
        let named = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action, named.isEmpty, homeItems.contains(canonical) || canonical == "app" else { return nil }
        return canonical == "app" ? ("", nil, "home") : ("home", canonical, "home." + canonical)
    }

    /// The place the door's steps end at, for a call that names no action:
    /// a page and item that are home's (or no page and an item) open or do
    /// what home's item says; anything else reads.
    public static func place(page: String, item: String) -> (page: String, item: String) {
        var page = page.trimmingCharacters(in: .whitespacesAndNewlines)
        var item = item.trimmingCharacters(in: .whitespacesAndNewlines)
        // An alias resolves to a canonical page and a path splits once, so the
        // steps end within a few; the bound only guards a cycle in the table.
        for _ in 0..<8 {
            guard let next = step(page: page, item: item, action: false) else { break }
            page = next.page
            if let named = next.item { item = named }
        }
        return (AppDoorNames.resolve(page), item)
    }

    public static let items: [String: [String: String]] = [
        "chat": ["<conversation id>": "background read: page:chat, item:<conversation id>; composer, latest 8 messages (args {limit}: max 16), and chat.reply eligibility. "
                 + "Resolve with chat.list; older history: chat.search {session_id, sort:newest, limit:12}, no query; follow next_call. chat.message expands clipped bodies. Screen controls are separate actions."],
        "inbox": ["all": "compact notes newest first, archived and dismissed too, up to 200; read a note id for details and actions"],
        "desk": ["<exact title or handle>": "the matching Desk record; duplicate titles require the exact desk number"],
        "diagnostics": ["doctor": "Doctor's last report; run doctor.run for fresh checks"],
        "telegram": ["status": "the poller's health, config and log freshness; never tokens or ids"],
        "skills": ["<skill name>": "the built-in guidance, as ability.read reads it",
                   "census": "conversion progress and blockers, including preserved historical originals"],
        "tools": ["<ability id or name>": "what the ability declares, its status, versions and validation, and its code in pages",
                  "census": "Abilities, persona procedures, senses and built-in guidance: what you grew, active/retired status, retained/waiting versions, conversion counterparts and cutover blockers."],
    ]
}

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
        ["memory", "skills", "research", "messages", "reminders", "today", "replies", "create", "connections", "crews", "delegations", "code"],
        ["notes", "contacts", "music", "slack", "notify", "status", "activity", "app"],
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
        ("tabs.connectors", "Connectors' tabs, left to right", [("connectors", ""), ("agents", ""), ("telegram", ""), ("iphone", "")]),
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

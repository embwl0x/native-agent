import Foundation
// Blueprint: | `SurfaceLayout.swift` | `SurfaceLayout` owns the document shape, vocabulary and seed; `SurfaceLayoutAvailability` carries its checked value or `SurfaceLayoutFailure` path/detail/repair across Mac and phone, and exposes shipped content names through their shipped profiles without supplying a substitute layout. `addMissing`, `shown`, `arranged` project validated layouts; `QuietToolPage` owns shared page definitions including inbox/unindexed reads; `AppDoorNames` shares page/item aliases and door resolution (`step`, `place`, home rooms), deriving accepted part face pages from those definitions and the ids a page of the agent's own may have (`ownPageRefusal`); `ownPage` reads a `page:<id>` block on the surfaces that take one (rail, more) |

public enum SurfaceLayoutAvailability: Codable, Sendable, Equatable {
    case available(SurfaceLayout)
    case unavailable(SurfaceLayoutFailure)

    public func get() throws -> SurfaceLayout {
        switch self {
        case .available(let layout): return layout
        case .unavailable(let failure): throw failure
        }
    }

    public var value: SurfaceLayout? {
        if case .available(let layout) = self { return layout }
        return nil
    }

    public var failure: SurfaceLayoutFailure? {
        if case .unavailable(let failure) = self { return failure }
        return nil
    }

    /// Layout controls presentation, never whether shipped content exists. An unavailable document exposes the vocabulary with its failure; it supplies no
    /// saved layout, fold state or writable version. The shipped profile still determines which content belongs in this view.
    public func contentNames(_ surface: String, profile: String?) -> [String] {
        switch self {
        case .available(let layout): return layout.shown(surface, profile: profile).map(\.name)
        case .unavailable:
            let off = Set(profile.flatMap { SurfaceLayout.shippedProfiles[$0]?.hidden } ?? [])
            return (SurfaceLayout.vocabulary.first { $0.surface == surface }?.blocks ?? [])
                .filter { !off.contains(surface + "." + $0.name) }.map(\.name)
        }
    }

    public func arranged<Item>(_ surface: String, profile: String?, _ items: [Item], name: (Item) -> String) -> [Item] {
        contentNames(surface, profile: profile).compactMap { key in items.first { name($0) == key } }
    }
}

public struct SurfaceLayoutFailure: Codable, Sendable, Equatable, LocalizedError {
    public let path: String
    public let detail: String
    public let instruction: String

    public init(path: String, detail: String, instruction: String) {
        self.path = path; self.detail = detail; self.instruction = instruction
    }

    public var errorDescription: String? { "\(path): \(detail) \(instruction)" }
}

public struct QuietToolPage: Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public init(id: String, title: String, summary: String) {
        self.id = id; self.title = title; self.summary = summary
    }

    public static let all: [QuietToolPage] = [
        QuietToolPage(id: "chat", title: "Chat",
                  summary: """
                      Conversations, attachments, voice, agent name and status. Background read: page:chat, item:<conversation id>, 8 messages (args \
                      {limit}: max 16). Resolve with chat.list; older history: chat.search {session_id, sort:newest, limit:12}, no query; follow \
                      next_call. chat.message expands clipped bodies. Screen controls are separate actions.
                      """),
        QuietToolPage(id: "today", title: "Today",
                  summary: "Notifications, approvals, proposals, recent work, and what is waiting."),
        QuietToolPage(id: "memories", title: "Memories",
                  summary: "Saved facts, pending proposals, and the knowledge graph."),
        QuietToolPage(id: "desk", title: "Desk",
                  summary: "Projects, dependencies, schedules, pursuits, progress and outcomes."),
        QuietToolPage(id: "make", title: "Make",
                  summary: "Every made thing, newest first; follow next_call for more. item:<ref> reads its versions. The person sees Make beside chat."),
        // A group of the door's actions with no screen of its own reads as its summary, its actions and its settings; the summary names
        // the page where the person sees it.
        QuietToolPage(id: "notifications", title: "Notifications",
                  summary: """
                      Notifying the person on the Mac or the paired phone. The person sees what needs them on the Inbox (Notifications in the \
                      rail) and sets notifications on Settings.
                      """),
        QuietToolPage(id: "bots", title: "Helpers",
                  summary: "Standing briefs on a schedule or an event, and their dated replies."),
        QuietToolPage(id: "personality", title: "Personality",
                  summary: "Identity, expression, about-you, growth and working-guideline documents; minds and dreams."),
        QuietToolPage(id: "providers", title: "Providers",
                  summary: "Connected AI accounts and the model each activity group runs on."),
        QuietToolPage(id: "trust", title: "Trust",
                  summary: "Presets, feature permissions, approvals, read and write access per Mac app, macOS grants, and activity capture."),
        QuietToolPage(id: "connectors", title: "Connectors",
                  summary: "Service connections, Telegram, the paired iPhone and its senses, and agent contacts."),
        QuietToolPage(id: "telegram", title: "Telegram",
                  summary: """
                      Telegram's actions: a test reply, clearing its logs, repairing its admission index, removing the token. The person sees and \
                      sets Telegram on Connectors.
                      """),
        QuietToolPage(id: "pairing", title: "iPhone pairing",
                  summary: """
                      The paired iPhone's actions: remove a phone, ask for its location. item:phone-senses reads each phone sense's setup, \
                      missing steps and the Phone senses guide. The person sees pairing, the phone's notifications and its senses on Connectors.
                      """),
        QuietToolPage(id: "agents", title: "Agents",
                  summary: """
                      Agent contacts and coding helpers: message, read, connect, stop, recipes, bridge jobs, and Claude's worklog of what Claude has \
                      been doing and working on, newest first. The person sees agent contacts on Connectors.
                      """),
        // An app's actions live on its page; the person sets its read and write access on Trust.
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
        // Trust owns access to files, the shell and the browser.
        QuietToolPage(id: "files", title: "Files",
                  summary: "Read, list, search, excerpt and write files; apply a patch; Spotlight."),
        QuietToolPage(id: "shell", title: "Shell",
                  summary: "Shell commands, git, Swift builds and tests, remote nodes, and restarting or installing the app."),
        QuietToolPage(id: "web", title: "Web",
                  summary: "Read a public page privately, and search the web."),
        QuietToolPage(id: "browser", title: "Browser",
                  summary: "The NativeAgent browser and your own Chrome tab: open, read, links, screenshots, clicks and forms."),
        // Trust owns Full Mac accessibility and Music access.
        QuietToolPage(id: "mac", title: "Mac",
                  summary: """
                      The live screen: look, act by name, go to an app, file or URL, wait, read a document, menus, the clipboard, system info and app \
                      activity.
                      """),
        QuietToolPage(id: "music", title: "Music",
                  summary: "Apple Music: what's playing, play, pause or skip, search the library, tracks and playlists."),
        QuietToolPage(id: "capabilities", title: "Capabilities",
                  summary: """
                      What the agent can actually do, action by action: the senses, the chat tools and their access, the abilities the agent grew, \
                      and the built-in guidance.
                      """),
        QuietToolPage(id: "diagnostics", title: "Diagnostics",
                  summary: "Doctor, Status, Runs log, Cognition and Inspector."),
        QuietToolPage(id: "dreams", title: "Dreams", summary: "Dream diary entries, held reading and the person's cycle controls."),
        QuietToolPage(id: "knowledge", title: "Knowledge Graph", summary: "Entities, relationships and reviewed graph upkeep."),
        QuietToolPage(id: "cognition", title: "Cognition", summary: "The resident mind's reading, evidence and the person's controls."),
        QuietToolPage(id: "memory-upkeep", title: "Memory upkeep", summary: "Memory diagnostics and the person's upkeep controls."),
        QuietToolPage(id: "skills", title: "Skills",
                  summary: "Built-in guidance from the persona, to read. The person sees it on Capabilities."),
        QuietToolPage(id: "tools", title: "Tools",
                  summary: "The abilities the agent grew: read, save, keep and manage them. The person sees them on Capabilities."),
        QuietToolPage(id: "settings", title: "Settings",
                  summary: """
                      Appearance, shortcuts, updates, the switches for an inner life, dreams and memory, notifications, and the search server.
                      """),
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
        "phone senses": "pairing/phone-senses",
        "ongoing": "desk", "computer": "mac", "skill": "skills", "agent": "agents", "abilities": "tools", "ability": "tools",
        "bot": "bots", "helpers": "bots", "connector": "connectors",
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

    /// Names the door and the window already take for a place that is not a page: home and its rooms (`step` turns them into home's item),
    /// the door's own words (the senses door's page among them), and every page's tabs (page.show opens a tab by its name).
    static let placeNames: Set<String> = homeItems.union(["home", "app", "current", "visible", "senses"])
        .union(SurfaceLayout.vocabulary.filter { $0.surface.hasPrefix("tabs.") }.flatMap { $0.blocks.map { $0.name.lowercased() } })

    /// Why `page` cannot be a page of the agent's own, or nil when it can: a short lowercase id that names no page, alias, room or tab the app has.
    public static func ownPageRefusal(_ page: String) -> String? {
        guard page.range(of: "^[a-z][a-z0-9-]{1,31}$", options: .regularExpression) != nil else {
            return "A page of the agent's own is 2 to 32 lowercase letters, digits or hyphens, starting with a letter."
        }
        guard !partPages.contains(page), aliases[page] == nil, !placeNames.contains(page) else {
            return "\(page) is already one of the app's pages, rooms or tabs; name a page of the agent's own."
        }
        return nil
    }

    /// One step of where the door takes a call's page before anything reads or acts (`AppToolExecutor.runAppDoor`): an alias resolves and a `page/item`
    /// path splits (`label` is the resolved page); with no action and no item, a home room named as a page becomes home's item and `app` is home (an empty
    /// `page` means none). Nil when the place is final.
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

    /// The place the door's steps end at, for a call that names no action: a page and item that are home's (or no page and an item) open or do what home's
    /// item says; anything else reads.
    public static func place(page: String, item: String) -> (page: String, item: String) {
        var page = page.trimmingCharacters(in: .whitespacesAndNewlines)
        var item = item.trimmingCharacters(in: .whitespacesAndNewlines)
        // An alias resolves to a canonical page and a path splits once, so the steps end within a few; the bound only guards a cycle in the table.
        for _ in 0..<8 {
            guard let next = step(page: page, item: item, action: false) else { break }
            page = next.page
            if let named = next.item { item = named }
        }
        return (AppDoorNames.resolve(page), item)
    }

    public static let items: [String: [String: String]] = [
        "chat": ["<conversation id>":
            "background read: page:chat, item:<conversation id>; composer, latest 8 messages (args {limit}: max 16), and chat.reply eligibility. "
                 + """
                     Resolve with chat.list; older history: chat.search {session_id, sort:newest, limit:12}, no query; follow next_call. chat.message \
                     expands clipped bodies. Screen controls are separate actions.
                     """],
        "inbox": ["all": "compact notes newest first, archived and dismissed too, up to 200; read a note id for details and actions"],
        "desk": ["<exact title or handle>": "the matching Desk record; duplicate titles require the exact desk number"],
        "pairing": ["phone-senses": """
            Phone senses guide: last reported per-sense on/off, iOS permission, missing setup and exact phone Settings steps; observations with \
            source/time
            """],
        "diagnostics": ["doctor": "Doctor's last report; run doctor.run for fresh checks"],
        "capabilities": ["<row id>": "the document a row opens (page:capabilities/<row id>), as its owner answers it on the Mac's page too"],
        "telegram": ["status": "the poller's health, config and log freshness; never tokens or ids"],
        "skills": ["<skill name>": "the built-in guidance, as ability.read reads it",
                   "census": "conversion progress and blockers, including preserved historical originals"],
        "tools": ["<ability id or name>": "what the ability declares, its status, versions and validation, and its code in pages",
                  "census": """
                      Abilities, persona procedures, senses and built-in guidance: what you grew, active/retired status, retained/waiting versions, \
                      conversion counterparts and cutover blockers.
                      """],
    ]
}

/// How each surface lays out its named blocks: their order, which are hidden, whether a fold starts open, and per view (a profile: simple, advanced or
/// agent, the `nativeagent.viewMode` values) which blocks that view leaves out. One document, ui/layout.json under the data root: written by the Mac's
/// `SurfaceLayoutStore`, drawn by the Mac's views and the agent's home, and carried to the phone in the core snapshot. Blocks, order, hidden, expanded
/// and profiles only: nothing here names a colour, a font, a material or a size.
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
    public var seededFrom: String
    public var updatedAt: String
    public var source: String
    /// The layout's digest as this app last wrote it; a hand edit leaves it behind.
    public var digest: String
    public var surfaces: [String: [Block]]
    public var profiles: [String: Profile]
    public var phone: String

    public static let path = "ui/layout.json"

    public static let placeRows: [[String]] = [
        ["mail", "calendar", "desk", "files", "browser"],
        ["memory", "skills", "research", "messages", "reminders", "today", "replies", "create", "connections", "crews", "delegations", "code"],
        ["notes", "contacts", "music", "slack", "notify", "status", "activity", "app"],
    ]

    /// Every surface, what it is, and its blocks in seed order with what each shows (empty when the name says it). The seed and the vocabulary: a name not
    /// here is refused, and one a newer build adds is placed at its seed position in a layout that lacks it.
    public static let vocabulary: [(surface: String, about: String, blocks: [(name: String, shows: String)])] = [
        ("home", "Home (app {} and the Agent view), top to bottom; people and helpers are also the Simple sidebar's Agents and Helpers, in this order", [
            ("notable", "NOTABLE TODAY"), ("changed", "CHANGED since the agent last looked"), ("waits", "what waits on the person"),
            ("queue", "MY QUEUE"), ("working", "WORKING: the agent's jobs and lines at work"), ("open", "OPEN: this chat's windows"),
            ("people", "PEOPLE: the agents in conversation with this agent"), ("helpers", "HELPERS"), ("senses", "MY SENSES"),
            ("elsewhere", "ELSEWHERE"), ("places", "PLACES, in the places order"), ("mac", "MAC"),
        ]),
        ("places", "Home's PLACES rows and the Agent view's rooms; a hidden place that names a page also leaves app {}'s page index",
            placeRows.joined().map { ($0, "") }),
        ("rail", "Advanced's rail, top to bottom, the last shown at its foot; a hidden page also leaves app {}'s page index", [
            ("chat", ""), ("today", ""), ("memories", ""), ("desk", ""), ("notifications", ""), ("bots", "Helpers"),
            ("divider", "the line between the rail's two groups"), ("personality", ""), ("providers", ""), ("trust", ""),
            ("connectors", ""), ("capabilities", ""), ("diagnostics", ""), ("settings", ""),
        ]),
        ("chat", "The chat's conversations column, top to bottom (Simple's profile hides it); expanded is whether a fold starts open", [
            ("rows", "the conversations"), ("briefs", "Briefs (folds)"), ("working", "Working: bridge and agent sessions (folds)"),
        ]),
        ("tabs.memories", "Memories' tabs, left to right", [("memories", ""), ("knowledge", "Knowledge graph")]),
        ("tabs.personality", "Personality's tabs, left to right", [("personality", ""), ("dreams", "")]),
        ("tabs.diagnostics", "Diagnostics' tabs, left to right", [
            ("diagnostics", "Health checks, status and runs"), ("Cognition", ""), ("Inspector", "Chat turn details"),
        ]),
        ("more", "The iPhone's More page, top to bottom", [("rooms", "Rooms"), ("setup", "Setup"), ("power", "Power user")]),
    ]

    /// Blocks that fold, and so carry `expanded`; each starts closed.
    public static let folds: Set<String> = ["chat.briefs", "chat.working"]

    /// The surfaces that also take a page of the agent's own, as a block named `page:<id>`. No seed has one.
    public static let pageSurfaces: Set<String> = ["rail", "more"]
    public static let pagePrefix = "page:"
    public static let pageBlockAbout = """
        page:<id> places a page of the agent's own here: an active part whose face is {projection:true, page:"<id>"}, drawn from its \
        host.state notebook. Only a page of the agent's own now can be placed; a placed page that is not published draws nothing.
        """

    /// The page of the agent's own a `page:<id>` block places on `surface`, when the surface takes one and the id is one such a page may
    /// have. Whether that page exists now is the engine's to say.
    public static func ownPage(_ surface: String, _ block: String) -> String? {
        guard pageSurfaces.contains(surface), block.hasPrefix(pagePrefix) else { return nil }
        let page = String(block.dropFirst(pagePrefix.count))
        return AppDoorNames.ownPageRefusal(page) == nil ? page : nil
    }

    /// Whether a "surface.block" name is a page of the agent's own on a surface that takes one.
    public static func placesOwnPage(_ key: String) -> Bool {
        pageSurfaces.contains { key.hasPrefix($0 + ".") && ownPage($0, String(key.dropFirst($0.count + 1))) != nil }
    }

    public static let profilesAbout = """
        simple, advanced and agent are the window's views (settings.view_mode shows one); each hides surface.block names in that view only. phone is \
        the profile the iPhone shows.
        """

    public static let shippedProfiles: [String: Profile] = [
        "simple": Profile(hidden: ["chat.rows", "chat.briefs", "chat.working"]),
        "advanced": Profile(hidden: []), "agent": Profile(hidden: []),
    ]

    public static func seed(from build: String, at: String, hidden: Set<String> = []) -> SurfaceLayout {
        var surfaces: [String: [Block]] = [:]
        for (surface, _, blocks) in vocabulary {
            surfaces[surface] = blocks.map { block in
                let key = surface + "." + block.name
                return Block(name: block.name, hidden: hidden.contains(key), expanded: folds.contains(key) ? false : nil)
            }
        }
        return SurfaceLayout(layoutVersion: 1, seededFrom: build, updatedAt: at, source: "seed", digest: "", surfaces: surfaces,
                             profiles: shippedProfiles,
                             phone: "simple")
    }

    /// A surface, profile or block a newer build added, at its seed position: after the nearest block that comes before it in the seed.
    /// A saved layout reads in the current vocabulary: a surface or block the vocabulary no longer has leaves, and what the person chose
    /// about every other block stands. A `page:<id>` block stays where its surface takes one and its id is one a page of the agent's own may have.
    public mutating func dropRemoved() {
        let known = Dictionary(uniqueKeysWithValues: Self.vocabulary.map { ($0.surface, Set($0.blocks.map(\.name))) })
        surfaces = Dictionary(uniqueKeysWithValues: surfaces.compactMap { surface, blocks in
            known[surface].map { names in (surface, blocks.filter { names.contains($0.name) || Self.ownPage(surface, $0.name) != nil }) }
        })
        let named = Set(known.flatMap { surface, names in names.map { surface + "." + $0 } })
        for name in profiles.keys { profiles[name]?.hidden.removeAll { !named.contains($0) && !Self.placesOwnPage($0) } }
    }

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

    public func shown(_ surface: String, profile: String?) -> [Block] {
        let off = Set(profile.flatMap { profiles[$0]?.hidden } ?? [])
        return (surfaces[surface] ?? []).filter { !$0.hidden && !off.contains(surface + "." + $0.name) }
    }

    /// `items` in the surface's order as `profile` shows them; one the layout hides is left out.
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

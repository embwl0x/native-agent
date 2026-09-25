import AppKit
import CoreGraphics
import Foundation
import ApprovalInbox
import MacControl
import MemoryV2
import PersistenceCore
import StandingBots
import WorkshopExecution

/// Her home screen (2026-09-23, her-screen plan Phase 1): the agent's own
/// world as one laid-out text page, the way a desktop is a picture for a
/// person. Fixed sections in a fixed order, one line per thing, a state on
/// every line. Everything is read from the owners' own files on demand: no
/// watcher, no network, no transcript, never the chat she is in.
enum HerScreen {
    enum Target { case action(AgentWorkspaceAction), page(String) }

    // MARK: - Stable names (data/her_screen/names.json)

    /// Names minted from each owner's own stable id and kept across turns and
    /// restarts. Numbers only ever go up, so one is never reused. Desk items
    /// use the Desk's own alias (already stable, never renumbered).
    struct NameBook: Codable, Equatable {
        struct Slug: Codable, Equatable { var id: String; var name: String }
        var slugs: [String: Slug] = [:]
        var numbers: [String: [String: Int]] = [:]
        var next: [String: Int] = [:]

        mutating func slug(id: String, name: String) -> String {
            // A built-in lane's name is its id, always; a peer holding it moves.
            if HerScreen.builtIns.contains(id) {
                slugs = slugs.filter { $0.value.id != id && $0.key != id }
                slugs[id] = .init(id: id, name: name)
                return id
            }
            if let (key, entry) = slugs.first(where: { $0.value.id == id }) {
                if entry.name != name { slugs[key]?.name = name }
                return key
            }
            var base = String(name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
            while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
            base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if base.isEmpty { base = "agent" }
            var candidate = base, suffix = 2
            while slugs[candidate] != nil || HerScreen.reserved.contains(candidate) || HerScreen.builtIns.contains(candidate) {
                candidate = base + "-\(suffix)"; suffix += 1
            }
            slugs[candidate] = .init(id: id, name: name)
            return candidate
        }

        /// `existing` is read only when the book grows past 200 of a kind;
        /// then ids whose items are gone are dropped, never a live one.
        mutating func number(_ kind: String, id: String, existing: () -> Set<String>) -> Int {
            if let n = numbers[kind]?[id] { return n }
            let n = next[kind] ?? 1
            numbers[kind, default: [:]][id] = n
            next[kind] = n + 1
            if let row = numbers[kind], row.count > 200 {
                let keep = existing().union([id])
                numbers[kind] = row.filter { keep.contains($0.key) }
            }
            return n
        }

        func id(_ kind: String, _ n: Int) -> String? { numbers[kind]?.first { $0.value == n }?.key }
    }

    private static let namesLock = NSLock()

    /// User's Agent view renders under this: names show as they would, and
    /// nothing is written (names.json, remembered verbs and item pages).
    @TaskLocal static var previewing = false

    static func withNames<T>(_ dataRoot: URL, _ body: (inout NameBook) -> T) -> T {
        let url = dataRoot.appendingPathComponent("her_screen/names.json")
        namesLock.lock(); defer { namesLock.unlock() }
        let old = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(NameBook.self, from: $0) } ?? NameBook()
        var book = old
        let result = body(&book)
        if book != old, !previewing {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try? encoder.encode(book).write(to: url, options: .atomic)
        }
        return result
    }

    /// Places by the name the screen shows them under, then their own ids.
    static let placeNames: [String: String] = ["desk": "ongoing", "mac": "computer"]
    static let views: [String: AgentWorkspaceLocation] = [
        "home": .home, "people": .people(page: 0), "conversations": .conversations(page: 0),
        "windows": .openPlaces, "arrivals": .arrivals, "work": .workOverview
    ]
    static let builtIns: Set<String> = ["claude", "codex", "omp"]
    static var reserved: Set<String> {
        Set(placeNames.keys).union(views.keys).union(AgentWorkspaceEnvironment.destinations.map(\.id)).union(["crew", "crews", "delegations"])
    }

    /// Verbs a room offers after its name: `sideways.run`, `desk.751.note`.
    static let verbs: Set<String> = ["say", "run", "settings", "note", "done", "status", "add", "go", "click", "fill", "more"]

    /// A name from the screen, or nil so the caller keeps its old handling.
    /// Opening goes beside home (path Home › X) and reuses a window already
    /// open on the same thing instead of making a second one.
    static func resolve(_ raw: String, dataRoot: URL, browserPages: [AgentWorkspaceLocation],
                        openPlaces: [AgentWorkspaceLocation] = []) async -> Target? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The mac room's verbs: `mac.look Calculator`, or `mac.look` with the app as text.
        for (prefix, tool, field) in [("mac.look", "screen", "app"), ("mac.go", "go", "name")]
            where name == prefix || name.hasPrefix(prefix + " ") {
            let app = raw.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let title = tool == "go" ? "Bring an app forward" : app.isEmpty ? "Look at an app" : app
            return .action(.perform(tool: tool, input: app.isEmpty ? [:] : [field: .string(app)], title: title,
                                    textField: app.isEmpty ? field : nil, isEffect: tool == "go"))
        }
        if let target = buildTarget(name, dataRoot: dataRoot) { return target }
        // A text room's row or verb: `today.3`, `mail.find`, `arrivals.2.dismiss`.
        if let page = HerItemPages.shared.page(dataRoot, name) { return .page(page) }
        if let action = namedAction(name, dataRoot: dataRoot) {
            if case .open(let place) = action, case .record = place { return open(place) }
            return .action(action)
        }
        if let target = await agentsTarget(name, dataRoot: dataRoot) { return target }
        if let comms = commsTarget(name, dataRoot: dataRoot) { return comms }
        var verb: String?
        if let dot = name.lastIndex(of: "."), verbs.contains(String(name[name.index(after: dot)...])) {
            verb = String(name[name.index(after: dot)...]); name = String(name[..<dot])
        }
        func open(_ place: AgentWorkspaceLocation) -> Target {
            let existing = openPlaces.last { AgentWorkspaceNavigation.placeIdentity($0) == AgentWorkspaceNavigation.placeIdentity(place)
                || sameConversation($0, place) }
            return .action(.window(AgentWorkspaceNavigation.windowAction(existing ?? place)))
        }
        if let web = webTarget(name, verb: verb, dataRoot: dataRoot) { return web }
        if name == "desk", verb == "add" { return .action(.configure(tool: "desk_add_item", input: [:], title: "Add work")) }
        if name.hasPrefix("desk."), let state = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState() {
            let alias = String(name.dropFirst(5))
            guard let item = state.items.first(where: { $0.alias == alias }) else { return nil }
            let handle: [String: JSONValue] = ["handle": .string(item.handle)]
            switch verb {
            case nil: return open(.record(tool: "desk_read", input: handle, title: item.title))
            case "note": return .action(.perform(tool: "desk_note", input: handle, title: "Note on " + name, textField: "text", isEffect: true))
            case "done": return .action(.perform(tool: "desk_set_status", input: handle.merging(["status": .string("done")]) { a, _ in a },
                                                 title: name + " done", textField: nil, isEffect: true))
            // With the new status as text, in one call; never a form left open.
            case "status": return .action(.perform(tool: "desk_set_status", input: handle, title: "Status of " + name, textField: "status", isEffect: true))
            default: return nil
            }
        }
        if verb == nil, name.hasPrefix("crew."), let n = Int(name.dropFirst(5)),
           let id = withNames(dataRoot, { $0.id("crew", n) }) {
            return crewPage(id: id, name: name, dataRoot: dataRoot).map(Target.page)
        }
        if verb == nil, name.hasPrefix("chat."), let n = Int(name.dropFirst(5)),
           let id = withNames(dataRoot, { $0.id("chat", n) }) {
            let title = bridgeChats(dataRoot: dataRoot).first { $0.id == id }?.title ?? "Conversation"
            return open(.record(tool: "chat_conversations", input: ["conversation_session_id": .string(id)], title: title))
        }
        if verb == nil, name.hasPrefix("browser.tab"), let n = Int(name.dropFirst(11)),
           let id = withNames(dataRoot, { $0.id("browser.tab", n) }),
           let page = browserPages.first(where: { AgentWorkspaceNavigation.placeIdentity($0) == id }) {
            return .action(.window(AgentWorkspaceNavigation.windowAction(page)))
        }
        // A slug, or a contact's or helper's display name ("Grok Bot"): the room.
        if let slug = withNames(dataRoot, { book in
            book.slugs[name] ?? book.slugs.values.first { $0.name.caseInsensitiveCompare(raw.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
        }) {
            let bot = slug.id.lowercased().hasPrefix("bot:") ? String(slug.id.dropFirst(4)) : nil
            switch (verb, bot) {
            case (nil, _): return open(.record(tool: "agent_read", input: ["agent": .string(slug.id)], title: slug.name))
            case ("say", _): return .action(.message(agent: slug.id, conversation: nil, name: slug.name))
            case ("run", let id?): return .action(.perform(tool: "bot_run_once", input: ["id": .string(id)], title: "Run " + slug.name, textField: nil, isEffect: true))
            case ("settings", let id?): return .action(.configure(tool: "bot_update", input: ["id": .string(id)], title: slug.name + " settings"))
            default: return nil
            }
        }
        guard verb == nil else { return nil }
        if let view = views[name] { return name == "home" ? .action(.open(.home)) : open(view) }
        let area = placeNames[name] ?? name
        if AgentWorkspaceEnvironment.destinations.contains(where: { $0.id == area }) { return open(.area(area)) }
        return nil
    }

    /// The same contact's conversation, whatever case its id was saved in.
    /// Opening a named thread (`b`) matches only that thread; opening the
    /// contact by name matches whichever of its threads is already open.
    private static func sameConversation(_ a: AgentWorkspaceLocation, _ b: AgentWorkspaceLocation) -> Bool {
        guard case .record("agent_read", let x, _) = a, case .record("agent_read", let y, _) = b,
              case .string(let one)? = x["agent"], case .string(let two)? = y["agent"],
              one.caseInsensitiveCompare(two) == .orderedSame,
              Set(x.keys).isSubset(of: ["agent", "conversation"]), Set(y.keys).isSubset(of: ["agent", "conversation"]) else { return false }
        guard case .string(let wanted)? = y["conversation"] else { return true }
        guard case .string(let open)? = x["conversation"] else { return false }
        return open.caseInsensitiveCompare(wanted) == .orderedSame
    }

    // MARK: - Home

    /// Home reads the shared world, shows what changed since she last looked
    /// (CHANGED, newest first), and her looking advances that. `markSeen:
    /// false` is User's Agent view reading the same page without looking.
    static func home(dataRoot: URL, scope: String, browserPages: [AgentWorkspaceLocation], now: Date = Date(),
                     markSeen: Bool = true) async -> String {
        let (agent, person) = names(dataRoot)
        let world = await readWorld(dataRoot, now: now)
        let seen = await lastSeen(dataRoot)
        let idle = idleSeconds()
        let connected = BrowserConnectionMirror.connected == true
        let page = ChromePageMirror.page(lease: nil, session: scope)
        var marks = worldMarks(world, dataRoot: dataRoot, person: person, now: now)
        // What only home shows (walk 3: all four of these changed and home
        // said "no changes"): presence, the Chrome link, the day's badges and
        // this chat's tabs. The glance carries them over, never speaks them.
        var shown: [String: Mark] = [:]
        if let idle {
            let word = idle < 300 ? " here" : " away"
            shown["home:presence"] = Mark(fp: word, line: person + word, at: now.timeIntervalSince1970)
        }
        shown["home:browser"] = Mark(fp: connected ? "on" : "off",
            line: "browser: " + (connected ? person + "'s Chrome connected" : "Chrome not connected"), at: now.timeIntervalSince1970)
        for name in ["calendar", "reminders"] {
            let words = HerLifePulse.shared.latest(name).flatMap { Calendar.current.isDate($0.at, inSameDayAs: now) ? $0.words : nil } ?? ""
            shown["home:" + name] = Mark(fp: words, line: words.isEmpty ? "" : name + ": " + words, at: now.timeIntervalSince1970)
        }
        let tabs: [(id: String, title: String)] = page.map { [("lease:" + $0.lease, tabTitle($0))] }
            ?? browserPages.compactMap { place in AgentWorkspaceNavigation.placeIdentity(place).map { ($0, place.title) } }
        // Tabs are per chat: another chat's saved tabs pass through untouched
        // (a day at most), so its home never calls them closed here.
        let ownTabs = "home:tab:" + scope + "\u{0}"
        for (name, mark) in seen?.marks ?? [:] where name.hasPrefix("home:tab:") && !name.hasPrefix(ownTabs)
            && now.timeIntervalSince1970 - mark.at < 86_400 { shown[name] = mark }
        for tab in tabs {
            shown[ownTabs + tab.id] = Mark(fp: "open", line: "", new: "browser tab opened: " + clip(tab.title, 40),
                                               gone: "browser tab closed: " + clip(tab.title, 40), at: now.timeIntervalSince1970)
        }
        // The first look with these sets their baseline rather than calling them all new.
        let baseline = seen?.marks.keys.contains { $0.hasPrefix("home:") } == true
        if baseline { marks.merge(shown) { a, _ in a } }
        let changed = changes(since: seen, now: marks, excluding: scope)
        if !baseline { marks.merge(shown) { a, _ in a } }
        if markSeen { Self.markSeen(dataRoot, marks: marks, now: now) }

        var header = [agent.uppercased(), clock(now)]
        if let idle { header.append(idle < 300 ? person + " here" : person + " away " + age(idle)) }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "uiClassicShell") { header.append("Advanced view") }
        else if let mode = defaults.string(forKey: "nativeagent.viewMode") { header.append(mode.capitalized + " view") }
        if let seen {
            header.append("since you looked \(age(now.timeIntervalSince1970 - seen.at)) ago: "
                + (changed.isEmpty ? "no changes" : "\(changed.count) change\(changed.count == 1 ? "" : "s")"))
        }

        let desk = deskRows(world, person: person, now: now)
        let (people, peopleNeeds, peopleMore) = peopleRows(world, dataRoot: dataRoot, now: now, scope: scope)
        let (helpers, helpersMore) = helperRows(world, dataRoot: dataRoot, person: person, now: now)
        let crews = crewRows(world, dataRoot: dataRoot, now: now)

        let rule = String(repeating: "─", count: 61)
        var lines = [header.joined(separator: " · "), rule]
        if !changed.isEmpty {
            lines += section("CHANGED", changed.prefix(5).map { "● " + clip($0, 70) } + (changed.count > 5 ? ["+\(changed.count - 5) more"] : []))
        }
        lines += section(person.uppercased() + " WAITS", desk.needs
            + (desk.more > 0 ? ["+\(desk.more) more waiting on \(person) · action \"desk\""] : []) + ownerRows(world, now: now))
        lines += section("MY QUEUE", (world.moments > 0 ? [pad("moments", 10) + "\(world.moments) waiting for my review · memory_moments_pending"] : [])
            + peopleNeeds)
        lines += section("WORKING", crews)
        if lines.count > 2 { lines.append(rule) }
        let fixed = lines.count
        lines += section("PEOPLE", columns(people) + (peopleMore > 0 ? ["+\(peopleMore) more · action \"people\""] : []))
        lines += section("HELPERS", columns(helpers) + (helpersMore > 0 ? ["+\(helpersMore) more · action \"helpers\""] : []))

        // Places always show: pulse where an owner has a cheap number, the bare
        // name otherwise (mail has no cached status; calendar and reminders
        // show their latest read today, HerLifePulse).
        // The Chrome link's state as its runtime last published it (nothing
        // published yet means it never connected); no tool call.
        var browser = connected ? "browser: \(person)'s Chrome connected" : "browser: not connected"
        if let tab = webTabCell(dataRoot: dataRoot, scope: scope, now: now) { browser += " · " + tab }
        else if !browserPages.isEmpty {
            // Only this chat's pages resolve as tabs here; they are its live set.
            let open = Set(browserPages.compactMap(AgentWorkspaceNavigation.placeIdentity))
            let tabs = withNames(dataRoot) { book in
                browserPages.prefix(3).compactMap { page -> String? in
                    guard let id = AgentWorkspaceNavigation.placeIdentity(page) else { return nil }
                    return "browser.tab\(book.number("browser.tab", id: id, existing: { open })) \"\(clip(page.title, 24))\""
                }
            }
            browser += " \(browserPages.count) tab\(browserPages.count == 1 ? "" : "s"): " + tabs.joined(separator: ", ")
        }
        let pulses = ["mail": mailPulse(now: now), "calendar": lifePulse("calendar", now: now), "desk": desk.pulse,
                      "browser": browser, "reminders": lifePulse("reminders", now: now)]
        lines += section("PLACES", placeRows.map { $0.map { pulses[$0] ?? $0 }.joined(separator: " · ") })
        let mine = touched(dataRoot: dataRoot, now: now)
        lines += section("MAC", [await macFront(person) + " · Mac apps I acted in: "
            + (mine.isEmpty ? "none" : mine.prefix(4).map { clip($0.app, 30) + ($0.readout.map { " · " + clip($0, 20) } ?? "") }
                .joined(separator: ", "))])
        // Home again within two minutes, nothing changed and these rows the
        // same but for ages: they are the ones she just read, so they are not
        // repeated (walk 3: 51 homes of ~750 tokens, nearly all identical).
        // Ages only where rows put them: after a state word ("✓ replied 5h",
        // "Manual only · 6h", "(8s ago)", a tab's `"title" 2m`) and before the
        // end of that cell. Titles and the MAC line compare as written.
        let before = ["✓ ", "replied ", "waiting ", "input ", "unconfirmed ", "no reply ", "sent ", "done ", "failed ",
                      "interrupted ", "approval ", "· ", "(", "\" ", person + " "].map(NSRegularExpression.escapedPattern(for:))
        let ages = try? NSRegularExpression(pattern: "(?<=" + before.joined(separator: "|") + #")\d+[smhd](?:\d+[smh])?(?= in chat| "| ago\)| ·|  |$)"#,
                                            options: .anchorsMatchLines)
        let aged = lines[fixed..<(lines.count - 1)].joined(separator: "\n")
        let rows = (ages?.stringByReplacingMatches(in: aged, range: NSRange(aged.startIndex..., in: aged), withTemplate: "·") ?? aged)
            + "\n" + (lines.last ?? "")
        if markSeen, changed.isEmpty,
           let whole = HerMemo.shared.shownHome(scope, rows: rows, now: now.timeIntervalSince1970, within: 120) {
            lines.removeSubrange(fixed...)
            lines.append(pad("SAME", 10) + "people, helpers, places and Mac as on the home you saw "
                + age(now.timeIntervalSince1970 - whole) + " ago")
        }
        lines.append(rule)
        lines.append("Open any name: workspace action \"desk.4\" / \"claude\" / \"mail\". Also: windows, people, conversations, arrivals, work, mac. Find: query.")
        return lines.joined(separator: "\n")
    }

    /// Home's PLACES rows by name, in order; mail, calendar, desk, browser
    /// and reminders show with their pulse.
    static let placeRows: [[String]] = [
        ["mail", "calendar", "desk", "files", "browser"],
        ["memory", "skills", "research", "messages", "reminders", "today", "replies", "create", "connections", "crews", "delegations", "code", "github"],
        ["gmail", "agentmail", "notes", "contacts"] + lifePlaces.components(separatedBy: " · ") + familyLine.components(separatedBy: " · "),
    ]

    static func section(_ label: String, _ rows: [String]) -> [String] {
        let width = max(10, label.count + 1)
        return rows.enumerated().map { ($0.offset == 0 ? pad(label, width) : String(repeating: " ", count: width)) + $0.element }
    }

    /// Name and state, names padded to one width; two cells a line with the
    /// second column aligned, or one a line when a cell is too wide for two.
    private static func columns(_ cells: [(name: String, state: String)]) -> [String] {
        let nameWidth = min(14, (cells.map(\.name.count).max() ?? 0) + 1)
        let text = cells.map { pad($0.name, nameWidth) + $0.state }
        let width = (text.map(\.count).max() ?? 0) + 3
        guard width <= 42 else { return text }
        return stride(from: 0, to: text.count, by: 2).map { i in
            i + 1 < text.count ? pad(text[i], width) + text[i + 1] : text[i]
        }
    }

    // MARK: Desk

    private struct DeskRows { var needs: [String] = []; var more = 0; var pulse = "desk" }

    /// NEEDS ME is the Today page's "Waiting on you", one rule: a live Desk
    /// item whose waitingOn names the owner (OwnerAttentionPolicy), a pending
    /// approval, a memory to review. In-progress work is "on my desk", a count
    /// in PLACES only.
    private static func deskRows(_ world: HerWorld, person: String, now: Date) -> DeskRows {
        guard let state = world.desk else { return .init() }
        let split = world.split
        let waiting = state.items.filter(OwnerAttentionPolicy.waitsOnOwner).sorted { $0.updatedAt > $1.updatedAt }
        var rows = DeskRows()
        rows.needs = waiting.prefix(3).map { item in
            pad("desk." + item.alias, 10) + clip(item.title, 46) + " · waits on " + person
                + (date(item.updatedAt).map { " " + age(now.timeIntervalSince($0)) } ?? "")
        }
        rows.more = max(0, waiting.count - 3)
        rows.pulse = "desk: \(split.active.count) active · \(split.parked.count) parked · \(split.open) open of \(split.total)"
        return rows
    }

    /// Open top-level work in the Desk page's groups: waiting on the owner,
    /// active, and parked by the shared DeskParking rule (last touch on the
    /// item or its parts; an execution still live for it keeps it active).
    struct DeskSplit { var waiting: [DeskItem] = []; var active: [DeskItem] = []; var parked: [DeskItem] = []; var open = 0; var total = 0; var quietDays: Int? }

    static func deskSplit(_ state: DeskState, dataRoot: URL, now: Date) async -> DeskSplit {
        let plan = DeskSequencing.compute(state, now: now)
        let live = Set(await SwiftNativeWorkshopRunner(root: dataRoot).listAll()
            .filter { DeskParking.executionIsLive(status: $0.status) }.compactMap(\.deskHandle))
        let open = state.topLevel.filter { !$0.status.isTerminal }.sorted { $0.updatedAt > $1.updatedAt }
        var split = DeskSplit(open: open.count, total: state.topLevel.count)
        for item in open {
            if OwnerAttentionPolicy.waitsOnOwner(item) { split.waiting.append(item); continue }
            let running = ([item.handle] + state.children(of: item.handle).map(\.handle)).contains(where: live.contains)
            if DeskParking.isParked(item, in: state, plan: plan, live: running, now: now) { split.parked.append(item) }
            else { split.active.append(item) }
        }
        split.quietDays = split.parked.compactMap { DeskParking.lastTouch($0, in: state) }.max()
            .map { Int(now.timeIntervalSince($0) / 86_400) }
        return split
    }

    /// Approvals and memory proposals: his to decide (the Today page's
    /// "Waiting on you"); home says what and how many, nothing to act on here.
    private static func ownerRows(_ world: HerWorld, now: Date) -> [String] {
        var rows: [String] = []
        let approvals = world.approvals
        rows += approvals.prefix(2).map { approval in
            pad("approval", 10) + clip(ApprovalWords.title(action: approval.action, title: approval.title, reason: approval.reason), 60) + " · asked"
                + (date(approval.lastRequestedAt ?? approval.createdAt).map { " " + age(now.timeIntervalSince($0)) } ?? "")
        }
        if approvals.count > 2 { rows.append("+\(approvals.count - 2) more approvals") }
        if world.reviews.count > 0 { rows.append(pad("memories", 10) + "\(world.reviews.count)\(world.reviews.capped ? "+" : "") to review") }
        return rows
    }

    // MARK: People

    struct Contact { let id: String; let name: String; let builtIn: Bool; let kind: String? }

    /// A chat another agent opened with her over the bridge, from the session
    /// index alone: the bridge titles it "[from: X, via bridge] …". Newest first.
    /// `heard` is the other side's newest message: `at` also moves for hers.
    /// `answered`: her message is the newest in the chat, so what they said there she has seen.
    struct BridgeChat { let id: String; let who: String; let title: String; let at: Date; var heard: Date? = nil; var answered = false }

    static func bridgeChats(dataRoot: URL) -> [BridgeChat] {
        var chats: [BridgeChat] = ((try? HumanConversationReader.rows(dataRoot: dataRoot)) ?? []).compactMap { row in
            guard let id = HumanConversationReader.string(row["id"]),
                  let raw = HumanConversationReader.string(row["title"]), raw.hasPrefix("[from: "),
                  let at = HumanConversationReader.string(row["updatedAt"]).flatMap(date) else { return nil }
            let named = humanTitle(raw, agentName: nil)
            guard let who = named.who?.lowercased() else { return nil }
            // The index keeps a title's first 60 characters; its last word may be cut.
            var title = named.title
            if raw.count >= 60, let space = title.lastIndex(of: " ") { title = String(title[..<space]) + "…" }
            if let summary = HumanConversationReader.string(row["summary"]) { title = clip(summary, 56) }
            return .init(id: id, who: who, title: title, at: at)
        }
        // When the other side last spoke, from the log's last 32 KB, for each
        // sender's two newest chats (the one she may be in, and the one before).
        var looked: [String: Int] = [:]
        for index in chats.indices where looked[chats[index].who, default: 0] < 2 {
            looked[chats[index].who, default: 0] += 1
            let tail = chatTail(chats[index].id, dataRoot: dataRoot, bytes: 32_768)
            chats[index].heard = tail.last { !$0.mine }?.at
            chats[index].answered = tail.last?.mine == true
        }
        return chats
    }

    /// Everyone she can reach: saved contacts (not disconnected), then the
    /// built-in lanes she has talked with either way.
    static func contacts(dataRoot: URL, records: [AgentConversationRecord], chats: [BridgeChat]) -> [Contact] {
        var contacts: [Contact] = []
        if let data = try? Data(contentsOf: dataRoot.appendingPathComponent("agents/peers.json")),
           let peers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for peer in peers where peer["grokSetup"] as? String != "disconnected" && peer["unavailableAt"] == nil {
                guard let id = peer["id"] as? String, let name = peer["name"] as? String else { continue }
                // Two routes can share a name: the Grok Mac app and the Grok routine.
                let kind: String? = switch peer["transport"] as? String {
                case "desktop", "desktopChat": "desktop app"
                case "grokBot": "routine"
                default: nil
                }
                contacts.append(.init(id: "peer:" + id, name: name, builtIn: false, kind: kind))
            }
        }
        for (id, name) in [("claude", "Claude"), ("codex", "Codex"), ("omp", "Omp")]
            where records.contains(where: { $0.agent == id }) || chats.contains(where: { $0.who == id }) {
            contacts.append(.init(id: id, name: name, builtIn: true, kind: nil))
        }
        return contacts
    }

    /// Its newest record; a contact connected again gets a new id and its
    /// older records keep its name.
    static func latest(_ contact: Contact, records: [AgentConversationRecord], contacts: [Contact], label: String? = nil) -> AgentConversationRecord? {
        records.filter { label == nil || $0.label == label }.sorted { $0.updatedAt > $1.updatedAt }.first { record in
            record.agent.caseInsensitiveCompare(contact.id) == .orderedSame
                || (record.agent.hasPrefix("peer:") && !contacts.contains { $0.id == record.agent }
                    && record.name.caseInsensitiveCompare(contact.name) == .orderedSame)
        }
    }

    /// One state from the contact's own latest exchange: its conversation
    /// record, or for anyone who talks to her over the bridge, that chat when
    /// it is newer.
    static func state(_ contact: Contact, record: AgentConversationRecord?, chat: BridgeChat?,
                      answered: [String: Date], now: Date) -> (text: String, asks: Bool) {
        var text: String, asks = false
        if let heard = chat?.heard, heard > (record?.updatedAt ?? .distantPast) {
            text = "✓ " + age(now.timeIntervalSince(heard)) + " in chat"
        } else if let record {
            let receipt = unwrap(record.receipt)
            let ago = age(now.timeIntervalSince(record.updatedAt))
            let message: String? = if case .string(let id)? = record.readInput?["message_id"] { id } else { nil }
            if ["sending", "waiting"].contains(record.phase) {
                if let message, let at = answered[message] { text = "✓ replied " + age(now.timeIntervalSince(at)) }
                else if record.phase == "waiting", AgentConversationSession.liveHandOff(record) { text = "✓ delivered " + ago }
                else { text = "… waiting " + age(now.timeIntervalSince(record.operationStartedAt ?? record.updatedAt)) }
            } else if receipt["needs_input"] == .bool(true) || receipt["needs_authentication"] == .bool(true) {
                text = "? asks for input " + ago; asks = true
            } else if (receipt["run_status"] ?? receipt["status"]) == .string("delivered_live") {
                // Handed into the agent's live session; it answers in a chat of its own.
                text = "✓ delivered " + ago
            } else if record.phase == "attention" {
                if receipt["status"] == .string("outcome_unknown") { text = "? send unconfirmed " + ago }
                else if let reason = sendFailure(contact, receipt: receipt, now: now) { text = "✗ sends failing: " + reason }
                else if receipt["sent"] == .bool(false) { text = "✗ not sent " + ago }
                else { text = "✗ no reply " + ago }
            } else if let reply = replyText(receipt) ?? record.exchanges?.last?.reply {
                // Peer text is untrusted remote data: its words open in the
                // conversation, never on home. Built-in lanes are quoted.
                // A peer's age is its exchange's, the one the room shows: a look
                // before 09-24 moved updatedAt ("replied 9h" over a 2d exchange).
                let at = record.exchanges?.last?.sentAt ?? record.operationStartedAt ?? record.updatedAt
                text = contact.builtIn ? "✓ " + ago + " \"" + clip(firstLine(reply), 22) + "\"" : "✓ replied " + age(now.timeIntervalSince(at))
            } else { text = "sent " + ago }
        } else { text = "idle" }
        if let kind = contact.kind { text += " · " + kind }
        return (text, asks)
    }

    static func peopleRows(_ world: HerWorld, dataRoot: URL, now: Date, scope: String? = nil, limit: Int = 8) -> (cells: [(name: String, state: String)], needs: [String], more: Int) {
        let (records, chats, contacts, answered) = (world.records, world.chats, world.contacts, world.answered)
        let rows = contacts.map { contact -> (Contact, (text: String, asks: Bool), Date) in
            let record = latest(contact, records: records, contacts: contacts)
            // The chat she is in is in front of her, not news about them.
            let chat = chats.first { $0.id != scope && ($0.who == contact.id || $0.who == contact.name.lowercased()) }
            return (contact, state(contact, record: record, chat: chat, answered: answered, now: now),
                    max(record?.updatedAt ?? .distantPast, chat?.at ?? .distantPast))
        }.sorted { $0.2 > $1.2 }
        var cells: [(name: String, state: String)] = [], needs: [String] = []
        withNames(dataRoot) { book in
            for (contact, state, _) in rows {
                let slug = book.slug(id: contact.id, name: contact.name)
                if state.asks { needs.append(pad(slug, 10) + "asks for input") }
                if cells.count < limit { cells.append((slug, state.text)) }
            }
        }
        return (cells, needs, max(0, rows.count - limit))
    }

    /// Grok Bot's answers arrive as their own chat turn; its request file
    /// says answered, and its write time is when.
    static func grokAnswers(dataRoot: URL) -> [String: Date] {
        let dir = dataRoot.appendingPathComponent("agents/grok-requests", isDirectory: true)
        var found: [String: Date] = [:]
        // The newest 20 by write time: older answers are long settled.
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }.prefix(20)
        for (url, _) in files {
            guard let data = try? Data(contentsOf: url),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  row["state"] as? String == "answered", let message = row["messageID"] as? String else { continue }
            found[message] = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        }
        return found
    }

    // MARK: Helpers

    static func helperRows(_ world: HerWorld, dataRoot: URL, person: String, now: Date) -> (cells: [(name: String, state: String)], more: Int) {
        let (bots, latest, running) = (world.bots, world.latest, world.running)
        let ordered = bots.sorted {
            (running.contains($0.id) ? 1 : 0, latest[$0.id]?.runAt ?? .distantPast)
                > (running.contains($1.id) ? 1 : 0, latest[$1.id]?.runAt ?? .distantPast)
        }
        let cells: [(name: String, state: String)] = withNames(dataRoot) { book in
            ordered.prefix(8).map { bot in
                (book.slug(id: "bot:" + bot.id.uuidString, name: bot.name),
                 helperState(bot, entry: latest[bot.id], running: running.contains(bot.id), person: person, now: now))
            }
        }
        return (cells, max(0, bots.count - 8))
    }

    static func helperState(_ bot: BotDefinition, entry: ShelfEntry?, running: Bool, person: String, now: Date) -> String {
        var state: String
        if running { state = "⟳ running" }
        else if let entry {
            let ago = age(now.timeIntervalSince(entry.runAt))
            switch entry.runtimeStatus {
            case .completed: state = now.timeIntervalSince(entry.runAt) < 3600 ? "✓ done " + ago : StandingBotSchedule.words(bot.cadence) + " · " + ago
            case .failed: state = "✗ failed " + ago
            case .interrupted: state = "✗ interrupted " + ago
            case .waitingForApproval: state = "waiting approval " + ago
            case .waitingOnPerson: state = "waiting on " + person + " " + ago
            }
        } else { state = StandingBotSchedule.words(bot.cadence) + " · never run" }
        return bot.paused ? state + " · paused" : state
    }

    // MARK: Crews

    private static func crewRows(_ world: HerWorld, dataRoot: URL, now: Date) -> [String] {
        let live = world.crews
        return withNames(dataRoot) { book in
            live.compactMap { row -> String? in
                guard let id = row["id"] as? String else { return nil }
                let workers = row["workers"] as? [[String: Any]] ?? []
                let working = workers.filter { ($0["status"] as? String ?? "working") == "working" }.count
                let started = (row["createdAt"] as? String).flatMap(date)
                let n = book.number("crew", id: id) {
                    Set((rows(dataRoot.appendingPathComponent("swarms/live.json"))
                        + rows(dataRoot.appendingPathComponent("swarms/runs.json"))).compactMap { $0["id"] as? String })
                }
                return pad("crew.\(n)", 10) + clip(firstLine(row["objective"] as? String ?? "A task"), 40)
                    + " · \(working) of \(workers.count) working" + (started.map { " · " + age(now.timeIntervalSince($0)) } ?? "")
            }
        }
    }

    /// A finished crew's state, honest about workers whose words were cut at
    /// the output cap: "completed" over two truncated reports read as whole (desk walk 4).
    static func crewState(_ row: [String: Any], fallback: String) -> String {
        let status = row["status"] as? String ?? fallback
        let workers = row["workers"] as? [[String: Any]] ?? []
        let cut = workers.filter { $0["outputTruncated"] as? Bool == true }.count
        guard status == "completed", cut > 0 else { return clip(status, 20) }
        return "finished with truncated workers (\(cut) of \(workers.count) cut off)"
    }

    /// Opening a crew: its task, each worker's state and first line.
    static func crewPage(id: String, name: String, dataRoot: URL) -> String? {
        let row = rows(dataRoot.appendingPathComponent("swarms/live.json")).first { $0["id"] as? String == id }
            ?? rows(dataRoot.appendingPathComponent("swarms/runs.json")).first { $0["id"] as? String == id }
        guard let row else { return nil }
        let workers = row["workers"] as? [[String: Any]] ?? []
        var lines = [name + " · " + clip(firstLine(row["objective"] as? String ?? "A task"), 80) + " · "
            + crewState(row, fallback: "running") + " · \(workers.count) workers"]
        // Read-only workers get the brief and nothing else (SwarmExecutor's worker prompt).
        if row["access"] as? String == "read_only" { lines.append("  read-only: workers answered from the brief alone, with no app, screen, files or tools") }
        for (index, worker) in workers.enumerated() {
            let role = nonEmpty(worker["role"] as? String) ?? nonEmpty(worker["name"] as? String) ?? "worker \(index + 1)"
            let said = nonEmpty(worker["output"] as? String) ?? nonEmpty(worker["error"] as? String) ?? ""
            var status = worker["status"] as? String ?? "working"
            if status == "completed", worker["outputTruncated"] as? Bool == true { status = "cut off" }
            lines.append("  \(index + 1) " + pad(clip(role, 16), 18) + pad(clip(status, 12), 11) + clip(firstLine(said), 90))
        }
        let synthesis = (row["synthesis"] as? [String: Any])?["output"] as? String ?? row["synthesis"] as? String
        if let synthesis = nonEmpty(synthesis) { lines.append("synthesis: " + clip(synthesis.replacingOccurrences(of: "\n", with: " "), 400)) }
        lines.append("Full record: agent_swarm results. Back to home: workspace with no arguments.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Small readers

    static func rows(_ url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    static func unwrap(_ receipt: JSONValue?) -> [String: JSONValue] {
        guard case .object(let root)? = receipt else { return [:] }
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { return job }
        return root
    }

    static func replyText(_ receipt: [String: JSONValue]) -> String? {
        for key in ["reply", "answer", "agent_reply_text", "agent_reply_text_head", "completion_text_head"] {
            if case .string(let text)? = receipt[key], !text.isEmpty { return text }
        }
        return nil
    }

    /// Why the last send failed, in a few words, when it ran and failed (omp's
    /// 403s). A built-in lane's record may keep only "failed"; its job keeps
    /// the error, looked up once per message and kept.
    static func sendFailure(_ contact: Contact, receipt: [String: JSONValue], now: Date) -> String? {
        for key in ["execution_error", "error"] { if case .string(let text)? = receipt[key], !text.isEmpty { return failureReason(text) } }
        guard contact.builtIn, (receipt["run_status"] ?? receipt["status"]) == .string("failed"),
              case .string(let id)? = receipt["matched_message_id"] ?? receipt["id"] else { return nil }
        let key = "sendFailure\u{0}" + id
        if let kept: String = HerMemo.shared.peek(key, stamp: [])?.value { return kept.isEmpty ? nil : kept }
        let error = DelegationStatusProjector().readSnapshot(now: now, agent: contact.id, messageID: id).jobs
            .first { $0.acceptedMessageIDs.contains(id) }?.executionError
        let reason = error.map(failureReason) ?? ""
        HerMemo.shared.put(key, reason)
        return reason.isEmpty ? nil : reason
    }

    /// An error as a person reads it: an HTTP body's own message after its
    /// code ("403: Your current subscription does not have access…"), else its first line.
    static func failureReason(_ error: String) -> String {
        let code = error.range(of: #"^\d{3}\b"#, options: .regularExpression).map { String(error[$0]) + ": " } ?? ""
        if let found = error.range(of: #""message"\s*:\s*"[^"]+"#, options: .regularExpression),
           let colon = error[found].firstIndex(of: ":") {
            let message = error[error.index(after: colon)..<found.upperBound].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            return code + clip(firstLine(message), 70)
        }
        return clip(firstLine(error), 70)
    }

    private static func idleSeconds() -> Double? {
        guard let any = CGEventType(rawValue: ~0) else { return nil }
        let value = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
        return value.isFinite ? value : nil
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: date)
    }

    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 3 * 3600 { return "\(s / 3600)h\((s % 3600) / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func firstLine(_ text: String) -> String {
        (plainLines(text).first ?? "").replacingOccurrences(of: "\"", with: "'")
    }

    /// Chat text as words: code blocks, headings, quote marks, list bullets,
    /// emphasis, inline code and link syntax come off; one line per non-empty
    /// source line; a fenced code block stands as "code: <its first line>".
    /// Each line is defused on its own, before any caller joins them.
    static func plainLines(_ text: String) -> [String] {
        var body = text
        while let fence = body.range(of: #"```[^\n]*\n[\s\S]*?(```|$)"#, options: .regularExpression) {
            let first = body[fence].split(whereSeparator: \.isNewline).dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("```") }
            // Inline code marks inside it are spent here, so the line reads as written.
            body.replaceSubrange(fence, with: "\n" + (first.map { "code: " + clip($0.replacingOccurrences(of: "`", with: "'"), 60) } ?? "code") + "\n")
        }
        return body.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            var line = String(raw)
            for (pattern, template) in [
                (#"^\s*(#{1,6}|>+)\s*"#, ""),                          // heading, quote
                (#"^\s*([-*+•]|\d{1,3}[.)])\s+"#, ""),                  // list bullet
                (#"^\s*([-*_|:]\s*){3,}$"#, ""),                        // rule, table rule
                (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),                    // link, image
                (#"(\*\*|__|~~|`+)"#, ""),                              // bold, strike, code
                (#"(?<![\w*])[*_](?=\S)([^*_\n]*?\S)[*_](?![\w*])"#, "$1"), // italic
                (#"^\s*([-*+•]|\d{1,3}[.)])\s+"#, ""),                  // a bullet under bold
            ] { line = line.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
            line = UntrustedText.neutralized(line.trimmingCharacters(in: .whitespaces))
            return line.contains(where: { $0.isLetter || $0.isNumber }) ? line : nil
        }
    }

    /// The first meaningful sentence of chat text, markdown off: a sentence
    /// shorter than 16 characters ("Done.") takes the next one along.
    static func sentence(_ text: String) -> String {
        let flat = plainLines(text).joined(separator: " ")
        var said = "", rest = Substring(flat)
        while said.count < 16, !rest.isEmpty {
            let end = rest.range(of: #"[.!?:](\s|$)"#, options: .regularExpression)
            said += (said.isEmpty ? "" : " ") + (end.map { rest[..<$0.upperBound] } ?? rest).trimmingCharacters(in: .whitespaces)
            rest = end.map { rest[$0.upperBound...] } ?? ""
        }
        if said.isEmpty { return text }
        return said.hasSuffix(":") ? String(said.dropLast()) : said
    }

    /// Everything shown on home goes through here: one line, tool markup
    /// made inert, clipped. Titles and replies come from outside.
    static func clip(_ text: String, _ limit: Int) -> String {
        // Each line defused before the lines join: a result header at a line's
        // start is caught there, not after it has moved mid-line.
        let flat = text.split(whereSeparator: \.isNewline).map { UntrustedText.neutralized(String($0)) }.joined(separator: " ")
        guard flat.count > limit else { return flat }
        // At a word boundary when one is near, never mid-word.
        var cut = String(flat.prefix(limit - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) < 16 { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Human titles

    /// A session title from its content: the bridge's "[from: X, via bridge]"
    /// and a greeting to the agent come off; who opened it comes back as `who`.
    static func humanTitle(_ raw: String, agentName: String?) -> (title: String, who: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines), who: String?
        if text.hasPrefix("[from: "), let end = text.range(of: ", via bridge]") {
            let label = String(text[text.index(text.startIndex, offsetBy: 7)..<end.lowerBound])
            who = label.prefix(1).uppercased() + label.dropFirst()
            text = String(text[end.upperBound...])
        }
        let greeting = (agentName ?? "").lowercased()
        var words = text.split(whereSeparator: \.isWhitespace)[...]
        // "Agent — …": a greeting to the agent is not what the chat is about.
        if words.count > 2, ["—", "-", "–"].contains(words[words.startIndex + 1]) { words = words.dropFirst(2) }
        words = words.drop { !greeting.isEmpty && ($0.lowercased().hasPrefix(greeting) || ["—", "-", "–"].contains($0)) }
        var title = ""
        for word in words {
            let next = title.isEmpty ? String(word) : title + " " + word
            if next.count > 56 { break }
            title = next
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;—-"))
        return (title.isEmpty ? "Conversation" + (who.map { " with " + $0 } ?? "") : title, who)
    }

    /// "today 6pm", "Tue 6pm", "Sep 22 6pm": enough to tell two apart.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let calendar = Calendar.current
        formatter.dateFormat = "ha"
        let hour = formatter.string(from: date).lowercased()
        if calendar.isDate(date, inSameDayAs: now) { return "today " + hour }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday " + hour }
        formatter.dateFormat = now.timeIntervalSince(date) < 6 * 86400 ? "EEE" : "MMM d"
        return formatter.string(from: date) + " " + hour
    }

    /// Same-titled rows get " · who · when"; distinct titles stay as they are.
    static func disambiguate(_ titles: [String], who: [String?], at: [Date?]) -> [String] {
        let counts = Dictionary(titles.map { ($0, 1) }, uniquingKeysWith: +)
        var result = titles.indices.map { i in
            counts[titles[i], default: 0] < 2 ? titles[i]
                : ([titles[i]] + [who[i], at[i].map { when($0) }].compactMap { $0 }).joined(separator: " · ")
        }
        // Still equal (same who, same hour): number them in list order.
        let still = Dictionary(result.map { ($0, 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        for i in result.indices where still[result[i], default: 0] > 1 {
            let title = result[i]
            let n = (seen[title] ?? 0) + 1
            seen[title] = n
            result[i] = title + " (\(n))"
        }
        return result
    }
}

/// Text from outside (a page title, a peer's or worker's words, a raw tool
/// result) reads the same but cannot pose as a tool call or as another result
/// block: tool-markup openers get a visible "‹" and a line opening with the
/// result header gets a "│ " in front.
public enum UntrustedText {
    public static func neutralized(_ text: String) -> String {
        text.replacingOccurrences(of: #"<(/?)(invoke|tool_use|tool_result|function_calls|function_results|parameter|antml:)"#,
                                  with: "‹$1$2", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?m)^([ \t]*)(NativeAgent tool result)"#, with: "$1│ $2",
                                  options: [.regularExpression, .caseInsensitive])
    }
}

import Experiences
import AuthoredCapabilities
import AppKit
import Foundation
import NativeAgentCore
import ApprovalInbox
import MacControl
import MemoryV2
import PersistenceCore
import ChromeControl
import Desk
import StandingBots
import WorkshopExecution
import Senses
import SwarmRuns
import NativeAgentShared
// Blueprint: | `HerScreen.swift` | `HerScreen` enum; `withNames`, `resolve`, compact Senses home projection and readable full senses item from registry/news and owner-reported live watches, with scoped sense changes and named corners, sharing the live built-ability line with turn context; shared home/room crew rows and worker details preserve canonical SwarmCrew liveness. Name counters and retained mappings validate; checked allocation reports exhaustion through rendering and resolution. Only a missing name book bootstraps; damaged bytes are preserved and cached executable aliases share the checked read. Home acknowledges displayed identities only, retaining hidden and capped changes. Invalid saved observation timestamps remain visible and preserved; age conversion is checked. |

/// Home renders retained owner state in layout order without reading another domain.
package enum HerScreen {
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
            if let (key, entry) = slugs.first(where: { $0.value.id == id }) {
                if entry.name != name { slugs[key]?.name = name }
                return key
            }
            var base = String(name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
            while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
            base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if base.isEmpty { base = "agent" }
            var candidate = base, suffix = 2
            while slugs[candidate] != nil || HerScreen.reserved.contains(candidate) {
                candidate = base + "-\(suffix)"; suffix += 1
            }
            slugs[candidate] = .init(id: id, name: name)
            return candidate
        }

        /// `existing` is read only when the book grows past 200 of a kind;
        /// then ids whose items are gone are dropped, never a live one.
        /// A retained counter must lead every issued number. Exhaustion is a
        /// read failure for new names, never a wrap or reuse of an old name.
        func validate() throws {
            for (kind, counter) in next where counter < 1 {
                throw NameFailure("Invalid next counter for \(kind): \(counter)")
            }
            for (kind, row) in numbers {
                guard let counter = next[kind], row.values.allSatisfy({ $0 > 0 && $0 < counter }),
                      Set(row.values).count == row.count else {
                    throw NameFailure("Invalid or duplicate retained numbers for \(kind)")
                }
            }
            guard Set(slugs.values.map(\.id)).count == slugs.count,
                  slugs.allSatisfy({ !$0.key.isEmpty && !$0.value.id.isEmpty }) else {
                throw NameFailure("Invalid or duplicate retained contact names")
            }
        }

        mutating func number(_ kind: String, id: String, existing: () -> Set<String>) throws -> Int {
            if let n = numbers[kind]?[id] { return n }
            let n = next[kind] ?? 1
            let (following, overflow) = n.addingReportingOverflow(1)
            guard n > 0, !overflow else { throw NameFailure("The \(kind) name counter is exhausted") }
            numbers[kind, default: [:]][id] = n
            next[kind] = following
            if let row = numbers[kind], row.count > 200 {
                let keep = existing().union([id])
                numbers[kind] = row.filter { keep.contains($0.key) }
            }
            return n
        }

        func id(_ kind: String, _ n: Int) -> String? { numbers[kind]?.first { $0.value == n }?.key }
    }

    private static let namesLock = NSLock()

    struct NameFailure: LocalizedError {
        let errorDescription: String?
        init(_ detail: String) { errorDescription = detail }
    }

    static func nameFailure(_ error: Error) -> String {
        "Workspace names unavailable: " + error.localizedDescription + ". Saved bytes are preserved; repair her_screen/names.json before using names."
    }

    /// User's Agent view renders under this: names show as they would, and
    /// nothing is written (names.json, remembered verbs and item pages).
    @TaskLocal static var previewing = false

    static func withNames<T>(_ dataRoot: URL, _ body: (inout NameBook) throws -> T) throws -> T {
        let url = dataRoot.appendingPathComponent("her_screen/names.json")
        namesLock.lock(); defer { namesLock.unlock() }
        let key = dataRoot.standardizedFileURL.path + "\u{0}names"
        // Only absence creates a book. Every present unreadable or invalid
        // book stays byte-for-byte intact and its failure reaches the caller.
        let old = try HerMemo.shared.cached(key, stamp: [stamp(url)]) {
            do { return try JSONDecoder().decode(NameBook.self, from: Data(contentsOf: url)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return NameBook() }
        }
        try old.validate()
        var book = old
        let result = try body(&book)
        if book != old, !previewing {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(book), to: url)
                HerMemo.shared.put(key, book, stamp: [stamp(url)])
            } catch { nativeLog("Workspace names could not be saved: %@", error.localizedDescription); throw error }
        }
        return result
    }

    /// Places by the name the screen shows them under, then their own ids.
    static let placeNames = AppDoorNames.places
    package enum NameKind { case unknown, read, effect }
    package static func classify(_ name: String, dataRoot: URL, scope: String) async -> NameKind {
        switch await resolve(name, dataRoot: dataRoot, scope: scope, browserPages: []) {
        case nil: .unknown
        case .page, .action(.open), .action(.window(.open)), .action(.openArrival): .read
        case .action(.perform(_, _, _, _, let isEffect)): isEffect ? .effect : .read
        default: .effect
        }
    }
    static let views: [String: AgentWorkspaceLocation] = [
        "home": .home, "people": .people(page: 0), "conversations": .conversations(page: 0),
        "windows": .openPlaces, "arrivals": .arrivals, "work": .workOverview
    ]
    static let reserved: Set<String> =
        Set(placeNames.keys).union(views.keys).union(AgentWorkspaceEnvironment.destinations.map(\.id)).union(["crew", "crews", "delegations", "elsewhere"])

    /// Verbs a room offers after its name: `sideways.run`, `desk.751.note`.
    static let verbs: Set<String> = ["say", "run", "settings", "note", "done", "drop", "status", "add", "go", "click", "fill", "more"]

    /// A name from the screen, or nil so the caller keeps its old handling.
    /// Opening goes beside home (path Home › X) and reuses a window already
    /// open on the same thing instead of making a second one.
    static func resolve(_ raw: String, dataRoot: URL, scope: String, browserPages: [AgentWorkspaceLocation],
                        openPlaces: [AgentWorkspaceLocation] = [], currentPlace: AgentWorkspaceLocation? = nil) async -> Target? {
        do {
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if name == "senses" {
                return .page("MY SENSES\n" + (await sensesRows(dataRoot: dataRoot, now: Date(), full: true)).joined(separator: "\n"))
            }
            // The mac room's verbs: `mac.look Calculator`, or `mac.look` with the app as text.
            for (prefix, tool, field) in [("mac.look", "screen", "app"), ("mac.go", "go", "name")]
                where name == prefix || name.hasPrefix(prefix + " ") {
                let app = raw.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                let title = tool == "go" ? "Open an app" : app.isEmpty ? "Look at an app" : app
                return .action(.perform(tool: tool, input: app.isEmpty ? [:] : [field: .string(app)], title: title,
                                        textField: app.isEmpty ? field : nil, isEffect: tool == "go"))
            }
            if let target = buildTarget(name, dataRoot: dataRoot) { return target }
            // A text room's row or verb: `today.3`, `mail.find`, `arrivals.2.dismiss`.
            if name.hasPrefix("elsewhere."), !MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) {
                return .page(elsewhereRoom(dataRoot: dataRoot, scope: scope))
            }
            let cachedName = name.hasPrefix("windows.") || name.hasPrefix("elsewhere.") ? scope + "\u{0}" + name : name
            if let page = HerItemPages.shared.page(dataRoot, cachedName) { return .page(page) }
            if name == "elsewhere" { return .page(elsewhereRoom(dataRoot: dataRoot, scope: scope)) }
            if let action = try namedAction(name, dataRoot: dataRoot, scope: scope) {
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
            if let web = webTarget(name, verb: verb, dataRoot: dataRoot, scope: scope) { return web }
            if name == "desk", verb == "add" { return .action(.configure(tool: "desk_add_item", input: [:], title: "Add work")) }
            if name.hasPrefix("desk."), let state = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState() {
                let alias = String(name.dropFirst(5))
                guard let item = state.items.first(where: { $0.alias == alias }) else { return nil }
                let handle: [String: JSONValue] = ["handle": .string(item.handle)]
                switch verb {
                case nil: return open(.record(tool: "desk_read", input: handle, title: item.title))
                case "more": return .action(.open(.record(tool: "desk_read",
                    input: handle.merging(["detail_offset": .int(0)]) { a, _ in a }, title: item.title)))
                case "note": return .action(.perform(tool: "desk_note", input: handle, title: "Note on " + name, textField: "text", isEffect: true))
                case "done": return .action(.perform(tool: "desk_set_status", input: handle.merging(["status": .string("done")]) { a, _ in a },
                                                     title: name + " done", textField: nil, isEffect: true))
                // Closed as dropped: her queue's false hit goes in one call.
                case "drop": return .action(.perform(tool: "desk_close", input: handle.merging(["canceled": .bool(true),
                    "summary": .string("dropped")]) { a, _ in a }, title: name + " dropped", textField: nil, isEffect: true))
                // With the new status as text, in one call; never a form left open.
                case "status": return .action(.perform(tool: "desk_set_status", input: handle, title: "Status of " + name, textField: "status", isEffect: true))
                default: return nil
                }
            }
            if verb == nil, name.hasPrefix("crew."), let n = Int(name.dropFirst(5)),
               let id = try withNames(dataRoot, { $0.id("crew", n) }) {
                return crewPage(id: id, name: name, dataRoot: dataRoot).map(Target.page)
            }
            if verb == nil, name.hasPrefix("chat.") || UUID(uuidString: name) != nil || name == scope.lowercased() {
                let id = name.hasPrefix("chat.") ? try Int(name.dropFirst(5)).flatMap { n in try withNames(dataRoot, { $0.id("chat", n) }) } : raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id, let row = try? HumanConversationIndex.rows(dataRoot: dataRoot).first(where: {
                    $0["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })?.caseInsensitiveCompare(id) == .orderedSame
                }), let session = row["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) {
                    return open(.record(tool: "chat_conversations", input: ["conversation_session_id": .string(session)],
                                        title: row["title"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "Conversation"))
                }
            }
            if verb == nil, name.hasPrefix("browser.tab"), let n = Int(name.dropFirst(11)),
               let id = try withNames(dataRoot, { $0.id("browser.tab", n) }),
               let page = browserPages.first(where: { AgentWorkspaceNavigation.placeIdentity($0) == id }) {
                return .action(.window(AgentWorkspaceNavigation.windowAction(page)))
            }
            // A slug, or a contact's or helper's display name ("Grok Bot"): the room.
            if let slug = try withNames(dataRoot, { book in
                book.slugs[name] ?? book.slugs.values.first { $0.name.caseInsensitiveCompare(raw.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
            }) {
                let bot = slug.id.lowercased().hasPrefix("bot:") ? String(slug.id.dropFirst(4)) : nil
                switch (verb, bot) {
                case (nil, _): return open(.record(tool: "agent_read", input: ["agent": .string(slug.id)], title: slug.name))
                case ("say", _):
                    if case .record("agent_read", let input, _)? = currentPlace,
                       case .string(let agent)? = input["agent"], agent.caseInsensitiveCompare(slug.id) == .orderedSame {
                        let conversation: String? = if case .string(let label)? = input["conversation"] { label } else { nil }
                        return .action(.message(agent: agent, conversation: conversation, name: slug.name))
                    }
                    return .action(.message(agent: slug.id, conversation: nil, name: slug.name))
                case ("run", let id?): return .action(.perform(tool: "bot_run_once", input: ["id": .string(id)], title: "Run " + slug.name, textField: nil, isEffect: true))
                case ("settings", let id?): return .action(.configure(tool: "bot_update", input: ["id": .string(id)], title: slug.name + " settings"))
                default: return nil
                }
            }
            guard verb == nil else { return nil }
            name = AppDoorNames.resolve(name)
            if let view = views[name] { return name == "home" ? .action(.open(.home)) : open(view) }
            let area = placeNames[name] ?? name
            if AgentWorkspaceEnvironment.destinations.contains(where: { $0.id == area }) { return open(.area(area)) }
            return nil
        } catch { return .page(nameFailure(error)) }
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
    static func home(dataRoot: URL, scope: String, browserPages: [AgentWorkspaceLocation], windows: [String] = [],
                     now: Date = Date(), markSeen: Bool = true) async -> String {
        do {
            let (agent, person) = names(dataRoot)
            let world = await readWorld(dataRoot, now: now)
            let seen = await lastSeen(dataRoot)
            let presence = MacPersonInput.presence()
            let connected = BrowserConnectionMirror.connected == true
            let page = ChromePageMirror.page(tab: nil, dataRoot: dataRoot, session: scope)
            var marks = try worldMarks(world, dataRoot: dataRoot, person: person, now: now)
            // Home alone acknowledges presence, Chrome, day badges and this chat's tabs.
            var shown: [String: Mark] = [:]
            if let presence {
                let word = presence.here ? " here" : " away"
                shown["home:presence"] = Mark(fp: word, line: person + word, at: now.timeIntervalSince1970)
            }
            shown["home:browser"] = Mark(fp: connected ? "on" : "off",
                line: "browser: " + (connected ? person + "'s Chrome connected" : "Chrome not connected"), at: now.timeIntervalSince1970)
            for name in ["calendar", "reminders"] {
                let words = HerReadBadges.shared.latest(name, dataRoot: dataRoot).flatMap { Calendar.current.isDate($0.at, inSameDayAs: now) ? $0.words : nil } ?? ""
                shown["home:" + name] = Mark(fp: words, line: words.isEmpty ? "" : name + ": " + words, at: now.timeIntervalSince1970)
            }
            let tabs: [(id: String, title: String)] = page.map { [("tab:" + String($0.tab), tabTitle($0))] }
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

            var header = [agent.uppercased(), "Snapshot as of " + now.formatted(.iso8601), freshness(world, now: now)]
            header.append(presence.map { $0.here ? person + " here" : person + " away " + age($0.seconds) }
                ?? person + " presence unknown" + (MacPersonInput.idle() == nil ? ": needs Input Monitoring" : ""))
            let defaults = UserDefaults.standard
            if let mode = defaults.string(forKey: "nativeagent.viewMode") { header.append(mode.capitalized + " view") }
            if let problem = seen?.problem { header.append(problem) }
            else if let seen {
                header.append("since you looked \(age(now.timeIntervalSince1970 - seen.at)) ago: "
                    + (changed.isEmpty ? "no changes" : "\(changed.count) change\(changed.count == 1 ? "" : "s")"))
            }

            let desk = deskRows(world, person: person, now: now)
            let owed = await owedRows(dataRoot, person: person, now: now)
            let (people, peopleNeeds, peopleMore, peopleHealth) = peopleRows(world, dataRoot: dataRoot, now: now, scope: scope)
            let (helpers, helpersMore) = helperRows(world, dataRoot: dataRoot, person: person, now: now)

            // Her home's sections in the layout's order, as the window's view
            // shows them (ui/layout.json); a hidden one is not read.
            let layout = SurfaceLayoutStore.layout(dataRoot: dataRoot), profile = SurfaceLayoutStore.profile
            let blocks = layout.shown("home", profile: profile).map(\.name)
            var rows: [String: [String]] = [:]
            var acknowledged: Set<String> = presence == nil ? [] : ["home:presence"]
            for name in blocks {
                switch name {
                case "notable": rows[name] = HerReadBadges.shared.notable(dataRoot: dataRoot, now: now).map { section("LAST MAIL READ", [$0]) } ?? []
                case "changed":
                    for change in changed.prefix(5) { acknowledged.formUnion(change.names) }
                    rows[name] = section("CHANGED", ["Tracked home records since last look; not all activity."] + changed.prefix(5).map { "● " + clip($0.line, 70) } + (changed.count > 5 ? ["+\(changed.count - 5) more"] : []))
                case "waits":
                    rows[name] = section(person.uppercased() + " WAITS", ["Desk, approvals and inbox asks; calendar, reminders and mail not read here."] + desk.needs
                        + (desk.more > 0 ? ["+\(desk.more) more waiting on \(person) · item \"desk\""] : []) + ownerRows(world, now: now) + owed.his)
                case "queue":
                    rows[name] = section("MY QUEUE", ["Queued Desk steps, reviews, arrivals to accept and handoffs; not all autonomous activity."] + (await queueRows(world, dataRoot: dataRoot, person: person, now: now))
                        + (world.arrivalsToAccept > 0 ? [pad("arrivals", 10) + "\(world.arrivalsToAccept) waiting for me to accept · item \"arrivals\" · app home.accept"] : [])
                        + (world.reviews.count > 0 ? [pad("memories", 10) + "\(world.reviews.count)\(world.reviews.capped ? "+" : "") to review · app memory.proposals"] : [])
                        + harnessRow(world)
                        + owed.hers
                        + peopleNeeds)
                case "working": rows[name] = section("WORKING", ["Crew run records; not all background work."] + crewRows(world.crews, dataRoot: dataRoot, now: now, liveOnly: true))
                case "open":
                    // Where she left off in this chat: its open windows, unfinished first.
                    rows[name] = section("OPEN", ["This chat's retained places; not Mac windows."] + (windows.isEmpty ? [] : [windows.prefix(3).map { clip($0, 40) }.joined(separator: " · ")
                        + (windows.count > 3 ? " +\(windows.count - 3)" : "") + " · item \"windows\""]))
                case "people": rows[name] = section("PEOPLE", ["Contacts, recorded exchanges and helper health; no full Doctor check."] + columns(people) + (peopleMore > 0 ? ["+\(peopleMore) more · item \"people\""] : []) + world.found)
                case "helpers": rows[name] = section("HELPERS", ["Definitions, latest shelf results and run queue; not full run history."] + columns(helpers) + (helpersMore > 0 ? ["+\(helpersMore) more · item \"helpers\""] : []))
                case "senses": rows[name] = section("MY SENSES", ["Registered abilities and recent changes; no sensory observation."] + world.senses)
                case "elsewhere": rows[name] = section("ELSEWHERE", ["Latest speakers across recent transcripts; not a complete activity log."] + elsewhereRows(world, dataRoot: dataRoot, scope: scope, person: person, now: now))
                case "places":
                    // Places show prior read badges; calendar and reminders expire each day.
                    // The Chrome link's state as its runtime last published it (nothing
                    // published yet means it never connected); no tool call.
                    var browser = connected ? "browser: \(person)'s Chrome connected" : "browser: not connected"
                    if let tab = webTabCell(dataRoot: dataRoot, scope: scope, now: now) { browser += " · " + tab }
                    else if !browserPages.isEmpty {
                        // Only this chat's pages resolve as tabs here; they are its live set.
                        let open = Set(browserPages.compactMap(AgentWorkspaceNavigation.placeIdentity))
                        let tabs = try withNames(dataRoot) { book in
                            try browserPages.prefix(3).compactMap { page -> String? in
                                guard let id = AgentWorkspaceNavigation.placeIdentity(page) else { return nil }
                                return "browser.tab\(try book.number("browser.tab", id: id, existing: { open })) \"\(clip(page.title, 24))\""
                            }
                        }
                        browser += " \(browserPages.count) tab\(browserPages.count == 1 ? "" : "s"): " + tabs.joined(separator: ", ")
                    }
                    let pulses = ["mail": mailPulse(dataRoot: dataRoot, now: now), "calendar": lifePulse("calendar", dataRoot: dataRoot, now: now), "desk": desk.pulse,
                                  "browser": browser, "reminders": lifePulse("reminders", dataRoot: dataRoot, now: now)]
                    let places = layout.shown("places", profile: profile).map { AppDoorNames.resolve($0.name) }
                    rows[name] = section("PLACES", ["Navigation, Chrome mirror and prior read badges; calendar, reminders and mail not read here."] + placeLines(places).map { $0.map { pulses[$0] ?? $0 }.joined(separator: " · ") })
                case "mac":
                    let mine = touched(dataRoot: dataRoot, now: now)
                    rows[name] = section("MAC", ["Front app/lock; recorded app reads/actions over \(Int(touchedHours))h; no fresh window content.", await macFront(person) + " · Mac apps my mac verbs read or acted in: "
                        + (mine.isEmpty ? "none" : mine.prefix(4).map { clip($0.app, 30) + ($0.readout.map { " · " + clip($0, 20) } ?? "") }
                            .joined(separator: ", "))])
                default: break
                }
            }
            // Her world (people to Mac) is parted from what is happening now by a rule.
            let outside: Set<String> = ["people", "helpers", "senses", "elsewhere", "places", "mac"]
            // Home suppresses unchanged rows for two minutes, comparing them
            // without ages.
            // Ages only where rows put them: after a state word ("✓ replied 5h",
            // "Manual only · 6h", "(8s ago)", a tab's `"title" 2m`) and before the
            // end of that cell. Titles and the MAC line compare as written.
            let before = ["✓ ", "replied ", "waiting ", "input ", "unconfirmed ", "no reply ", "sent ", "done ", "failed ",
                          "interrupted ", "approval ", "· ", "(", "\" ", person + " "].map(NSRegularExpression.escapedPattern(for:))
            let ages = try? NSRegularExpression(pattern: "(?<=" + before.joined(separator: "|") + #")\d+[smhd](?:\d+[smh])?(?= in chat| "| ago\)| ·|  |$)"#,
                                                options: .anchorsMatchLines)
            let aged = blocks.filter { outside.contains($0) && $0 != "mac" }.flatMap { rows[$0] ?? [] }.joined(separator: "\n")
            let compared = (ages?.stringByReplacingMatches(in: aged, range: NSRange(aged.startIndex..., in: aged), withTemplate: "·") ?? aged)
                + "\n" + (rows["mac"] ?? []).joined(separator: "\n")
            if markSeen, changed.isEmpty, let first = blocks.first(where: outside.contains),
               let whole = HerMemo.shared.shownHome(dataRoot.standardizedFileURL.path + "\u{0}" + scope, rows: compared, now: now.timeIntervalSince1970, within: 120) {
                for name in outside { rows[name] = [] }
                rows[first] = [pad("SAME", 10) + "people, helpers, places and Mac as on the home you saw "
                    + age(now.timeIntervalSince1970 - whole) + " ago"]
            }

            let rule = String(repeating: "─", count: 61)
            var lines = [header.joined(separator: " · "), rule]
            var inWorld: Bool?
            for name in blocks {
                guard let block = rows[name], !block.isEmpty else { continue }
                if let was = inWorld, was != outside.contains(name) { lines.append(rule) }
                inWorld = outside.contains(name)
                lines += block
            }
            lines.append(rule)
            lines.append("Open: app {item:\"desk.4\"} or {item:\"mail\"}; text/fields: args. Also: windows, people, conversations, arrivals, work, mac. Find: app {page:\"home\", find:\"…\"}.")
            // Only rows still present after layout and SAME suppression count.
            if rows["people"]?.isEmpty == false {
                acknowledged.formUnion(people.map(\.name))
                acknowledged.formUnion(peopleHealth.map { "health:" + $0 })
            }
            if rows["helpers"]?.isEmpty == false { acknowledged.formUnion(helpers.map(\.name)) }
            if rows["places"]?.isEmpty == false {
                let places = Set(layout.shown("places", profile: profile).map { AppDoorNames.resolve($0.name) })
                for place in ["browser", "calendar", "reminders"] where places.contains(place) {
                    acknowledged.insert("home:" + place)
                }
                // A tab's exact identity is shown only by the live page cell.
                if places.contains("browser"), let page { acknowledged.insert(ownTabs + "tab:" + String(page.tab)) }
            }
            if markSeen, world.pending.isEmpty {
                Self.markSeen(dataRoot, marks: marks, only: acknowledged, now: now)
            }
            return lines.joined(separator: "\n")
        } catch { return nameFailure(error) }
    }

    /// Home's PLACES rows: the places shown, in order, a row breaking where
    /// the seed's rows break (`SurfaceLayout.placeRows`).
    static func placeLines(_ names: [String]) -> [[String]] {
        let row = Dictionary(SurfaceLayout.placeRows.enumerated().flatMap { index, names in names.map { (AppDoorNames.resolve($0), index) } }, uniquingKeysWith: { first, _ in first })
        return names.reduce(into: [[String]]()) { lines, name in
            if let last = lines.last?.last, row[last] == row[name] { lines[lines.count - 1].append(name) } else { lines.append([name]) }
        }
    }

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

    /// <OWNER> WAITS is the Desk's Needs you, one rule (OwnerAttentionPolicy):
    /// a live Desk item whose waitingOn names the owner, a pending approval, an
    /// inbox card asking him. In-progress work is "on my desk", a count in
    /// PLACES only.
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
        rows.pulse = "desk: \(split.active.count) active · \(split.parked.count) parked · \(split.waiting.count) waiting on \(person) · " + state.boardCountSummary
        return rows
    }

    /// What the app filed for itself (HarnessQueue): the open count and the newest.
    private static func harnessRow(_ world: HerWorld) -> [String] {
        let open = world.desk.map(HarnessQueue.open) ?? []
        guard let newest = open.first else { return [] }
        return [pad("harness", 10) + "\(open.count) open, newest \"\(clip(newest.title, 46))\""
            + (newest.assignee.map { " for the " + $0 } ?? "") + " · item \"desk\""]
    }

    /// Open top-level work in the Desk page's groups: waiting on the owner,
    /// active, and parked by the shared DeskParking rule (last touch on the
    /// item or its parts; an execution still live for it keeps it active).
    struct DeskSplit { var waiting: [DeskItem] = []; var active: [DeskItem] = []; var parked: [DeskItem] = []; var quietDays: Int? }

    static func deskSplit(_ state: DeskState, live: Set<String>, now: Date) -> DeskSplit {
        let plan = DeskSequencing.compute(state, now: now)
        let open = state.board.topLevel.filter { !$0.status.isTerminal }.sorted { $0.updatedAt > $1.updatedAt }
        var split = DeskSplit()
        for item in open {
            if OwnerAttentionPolicy.waitsOnOwner(item) { split.waiting.append(item); continue }
            let running = !DeskParking.subtreeHandles(item.handle, in: plan.children).isDisjoint(with: live)
            if DeskParking.parking(item, in: state, plan: plan, live: running, now: now).parked { split.parked.append(item) }
            else { split.active.append(item) }
        }
        split.quietDays = split.parked.compactMap { DeskParking.lastTouch($0, in: plan.children) }.max()
            .map { Int(now.timeIntervalSince($0) / 86_400) }
        return split
    }

    /// Repair owed (User 10-18: never "I can't fix it"): each no that named its
    /// owner stays here, with its lever, until that operation works again or
    /// she lets it go. Hers in MY QUEUE; the person's, with his exact control, in his waits.
    static func owedRows(_ dataRoot: URL, person: String, now: Date) async -> (hers: [String], his: [String]) {
        let open: [Experience]
        do { open = try await ExperienceStore.at(dataRoot).projection() }
        catch {
            let file = dataRoot.appendingPathComponent("experiences/experiences.sqlite")
            return ([readFailure(error, reason: "repairs_unavailable", remedy: Repair.remedy(owner: file.path,
                nextCall: nil, tap: nil, instruction: ToolFailureError.fileRepairInstruction(file,
                    shape: "The repair ledger could not be read: \(error.localizedDescription). Preserve its records and SQLite journals.")))], [])
        }
        var hers: [String] = [], his: [String] = []
        for act in open.sorted(by: { $0.at > $1.at }) {
            guard RepairOwed.isOwed(act), let owed = act.owes["repair"] else { continue }
            func claim(_ name: String) -> String? {
                act.claims.first { $0.claim.hasPrefix(name + ": ") }.map { String($0.claim.dropFirst(name.count + 2)) }
            }
            let when = NativeTimestampFormat.parseISO8601FractionalFirst(act.at).map { " " + age(now.timeIntervalSince($0)) } ?? ""
            let what = failureReason(claim("operation") ?? "a call") + " " + (act.outcome?.status ?? "outcome not recorded")
                + when + " by " + failureReason(claim("owner") ?? "owner not recorded")
            let release = " · or let go: app {action:\"repair.let_go\", args:{id:\"\(act.id)\", reason}}"
            if owed.to == "person" {
                his.append(pad("repair", 10) + what + " · ask \(person): " + (claim("tap") ?? "?")
                    + " · " + failureReason(act.face?.words ?? "")
                    + (claim("next_call").map { " · " + failureReason($0) } ?? "") + release)
            } else {
                hers.append(pad("repair", 10) + what + " · " + failureReason(act.face?.words ?? "") + " · " + failureReason(claim("next_call") ?? "read the act")
                    + (claim("tap").map { " · " + failureReason($0) } ?? "")
                    + release)
            }
        }
        let cap = 4
        return (Array(hers.prefix(cap)) + (hers.count > cap ? ["+\(hers.count - cap) more repairs owed"] : []),
                Array(his.prefix(cap)) + (his.count > cap ? ["+\(his.count - cap) more for \(person)"] : []))
    }

    /// Approvals and inbox cards asking him: his to decide (the Desk's Needs
    /// you); home says what and how many, nothing to act on here. Memory
    /// proposals are hers (MY QUEUE).
    private static func ownerRows(_ world: HerWorld, now: Date) -> [String] {
        var rows: [String] = []
        let approvals = world.approvals
        rows += approvals.prefix(2).map { approval in
            pad("approval", 10) + clip(ApprovalWords.title(action: approval.action, title: approval.title, reason: approval.reason), 60) + " · asked"
                + (date(approval.lastRequestedAt ?? approval.createdAt).map { " " + age(now.timeIntervalSince($0)) } ?? "")
        }
        if approvals.count > 2 { rows.append("+\(approvals.count - 2) more approvals") }
        if world.asks > 0 { rows.append(pad("inbox", 10) + "\(world.asks) asking for an answer") }
        return rows
    }

    // MARK: People

    struct Contact { let id: String; let name: String; let kind: String?; var agents: [String] = [] }

    /// A chat another agent opened with her over the bridge, from the session
    /// index and persisted bridge identity. Its title is display only. Newest first.
    /// `heard` is the other side's newest message: `at` also moves for hers.
    /// `answered`: her message is the newest in the chat, so what they said there she has seen.
    package struct BridgeChat { package let id: String; package let who: String; package let title: String; package let at: Date; package var heard: Date? = nil; package var answered = false }

    package static func bridgeChats(dataRoot: URL) -> [BridgeChat] {
        var chats: [BridgeChat] = AgentWorkSession.verified(dataRoot: dataRoot).compactMap { session in
            let row = session.row
            guard let at = row["updatedAt"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }).flatMap(date) else { return nil }
            let raw = row["title"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? session.topic
            let named = humanTitle(raw, agentName: nil)
            // The index keeps a title's first 60 characters; its last word may be cut.
            var title = named.title
            if raw.count >= 60, let space = title.lastIndex(of: " ") { title = String(title[..<space]) + "…" }
            if let summary = row["summary"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) { title = clip(summary, 56) }
            return .init(id: session.id, who: session.sender, title: title, at: at)
        }
        // When the other side last spoke, from the log's last 32 KB, for each
        // sender's two newest chats (the one she may be in, and the one before).
        var looked: [String: Int] = [:]
        for index in chats.indices where looked[chats[index].who, default: 0] < 2 {
            looked[chats[index].who, default: 0] += 1
            let tail = chatTail(chats[index].id, dataRoot: dataRoot, bytes: 32_768)
            chats[index].heard = tail.last { !$0.mine }?.date
            chats[index].answered = tail.last?.mine == true
        }
        return chats
    }

    /// Saved contacts, grouped only by their explicit identities.
    static func contacts(identity: AgentContactIdentity, mergeIdentities: Bool = true) -> [Contact] {
        var contacts: [Contact] = []
        for peer in identity.peers {
            guard let id = peer["id"], let name = peer["name"] else { continue }
            if let who = peer["who"], identity.peers.contains(where: { $0["id"] == who }) { continue }
            // Two routes can share a name: the Grok Mac app and the Grok routine.
            let kind: String? = switch peer["transport"] {
            case "desktop", "desktopChat": "desktop app"
            case "grokBot": "routine"
            default: nil
            }
            contacts.append(.init(id: "peer:" + id, name: name, kind: kind))
        }
        guard mergeIdentities else { return contacts }
        var seen: Set<String> = []
        return contacts.compactMap { contact in
            let brain = identity.canonical(contact.id)
            guard seen.insert(brain).inserted else { return nil }
            return Contact(id: contact.id, name: contact.name,
                           kind: contact.kind, agents: identity.members(contact.id))
        }
    }

    /// Its newest record, by its own id.
    static func latest(_ contact: Contact, records: [AgentConversationRecord], label: String? = nil) -> AgentConversationRecord? {
        var newest: AgentConversationRecord?
        for record in records where label == nil || record.label == label {
            guard record.agent.caseInsensitiveCompare(contact.id) == .orderedSame || contact.agents.contains(record.agent) else { continue }
            if let newest, record.updatedAt <= newest.updatedAt { continue }
            newest = record
        }
        return newest
    }

    /// The contact's latest live exchange, from the supplied transcript inventory.
    static func thread(_ contact: Contact, dataRoot: URL, identity: AgentContactIdentity, transcripts: [(String, URL)]) -> BridgeChat? {
        let owner = String(contact.id.dropFirst(5))
        guard let tail = try? ContactThread.mergedLines(dataRoot: dataRoot, owner: owner, tailBytes: 65_536, identity: identity, transcripts: transcripts) else { return nil }
        guard let last = tail.last else { return nil }
        return BridgeChat(id: ContactThread.session(owner: owner), who: contact.id, title: "", at: last.at,
                          heard: tail.last { !$0.mine }?.at, answered: last.mine)
    }

    /// One state from the contact's own latest exchange: its conversation
    /// record, or for anyone who talks to her over the bridge, that chat when
    /// it is newer.
    static func state(_ contact: Contact, record: AgentConversationRecord?, chat: BridgeChat?,
                      answered: [String: Date], now: Date, health: AgentLocalHealth? = nil) -> (text: String, asks: Bool, change: String) {
        if let record, record.phase != "sending", record.sendFailed {
            let at = record.exchanges?.last(where: { $0.id == record.operationID })?.settledAt ?? record.updatedAt
            return ("✗ failed " + age(now.timeIntervalSince(at)), false, "did not reply")
        }
        if let problem = health?.problemWord { return (problem, false, "") }
        if let record, health?.resolves(record) == true { return ("Ready", false, "") }
        var text: String, asks = false, change = ""
        if let heard = chat?.heard, heard > (record?.updatedAt ?? .distantPast) {
            text = "✓ " + age(now.timeIntervalSince(heard)) + " in chat"; change = "replied"
        } else if let record {
            let receipt = record.sendEvidence
            let ago = age(now.timeIntervalSince(record.exchanges?.last?.settledAt ?? record.operationStartedAt ?? record.updatedAt))
            let message: String? = if case .string(let id)? = record.readInput?["message_id"] { id } else { nil }
            if ["sending", "waiting"].contains(record.phase) {
                if let message, let at = answered[message] { text = "✓ replied " + age(now.timeIntervalSince(at)); change = "replied" }
                else if record.phase == "waiting", AgentWorkspacePorts.current.conversations.liveHandOff(record) { text = "… awaiting acceptance " + ago }
                else { text = "… waiting " + age(now.timeIntervalSince(record.operationStartedAt ?? record.updatedAt)) }
            } else if receipt["needs_input"] == .bool(true) || receipt["needs_authentication"] == .bool(true) {
                text = "? asks for input " + ago; asks = true; change = "asks for input"
            } else if (receipt["run_status"] ?? receipt["status"]) == .string("delivered_live") {
                let delivered = receipt["read"] == .bool(true) || receipt["delivered"] == .bool(true)
                text = (delivered ? "✓ delivered " : "? send unconfirmed ") + ago
                change = delivered ? "" : "send unconfirmed"
            } else if record.phase == "attention" {
                if receipt["status"] == .string("outcome_unknown") { text = "? send unconfirmed " + ago; change = "send unconfirmed" }
                else if let reason = sendFailure(contact, receipt: receipt) { text = "✗ sends failing: " + reason; change = "send failed" }
                else if receipt["sent"] == .bool(false) { text = "✗ not sent " + ago; change = "not sent" }
                else { text = "✗ no reply " + ago; change = "did not reply" }
            } else if record.retainedReply?.text ?? record.exchanges?.last?.reply != nil {
                // Reply text stays in the conversation; its age is the exchange's.
                let at = record.exchanges?.last?.settledAt ?? record.exchanges?.last?.sentAt ?? record.operationStartedAt ?? record.updatedAt
                text = "✓ replied " + age(now.timeIntervalSince(at)); change = "replied"
            } else { text = "sent " + ago }
        } else { text = "idle" }
        if let word = health?.word { text = word + " · " + text }
        if let kind = contact.kind { text += " · " + kind }
        return (text, asks, change)
    }

    static func peopleRows(_ world: HerWorld, dataRoot: URL, now: Date, scope: String? = nil, limit: Int = 8) -> (cells: [(name: String, state: String)], needs: [String], more: Int, health: Set<String>) {
        do {
            let (records, contacts, answered) = (world.records, world.contacts, world.answered)
            let rows = contacts.map { contact -> (Contact, (text: String, asks: Bool, change: String), Date, String?) in
                let record = latest(contact, records: records)
                let owner = String(contact.id.dropFirst(5))
                let inFront = world.identity.owners(owner).contains { scope?.hasPrefix(ContactThread.prefix(owner: $0)) == true }
                let chat = inFront ? nil : world.threads[contact.id]
                let healthID = world.healthID(for: contact, record: record), health = world.health[healthID]
                let exchangeAt = record?.exchanges?.last?.settledAt ?? record?.operationStartedAt ?? record?.updatedAt ?? .distantPast
                if record?.sendFailed != true, health?.problem == nil,
                   let job = world.jobs.first(where: { $0.agent == contact.id || contact.agents.contains($0.agent) }),
                   let at = (job.completedAt ?? job.startedAt ?? job.createdAt).flatMap(date),
                   at > max(exchangeAt, chat?.at ?? .distantPast) {
                    return (contact, (jobState(job, now: now), false, ""), at, nil)
                }
                return (contact, state(contact, record: record, chat: chat, answered: answered, now: now,
                                       health: health),
                        max(record?.updatedAt ?? .distantPast, chat?.at ?? .distantPast), healthID)
            }.sorted { $0.2 > $1.2 }
            var cells: [(name: String, state: String)] = [], needs: [String] = []
            var health: Set<String> = []
            try withNames(dataRoot) { book in
                for (contact, state, _, healthID) in rows {
                    let slug = book.slug(id: contact.id, name: contact.name)
                    if state.asks { needs.append(pad(slug, 10) + "asks for input") }
                    if cells.count < limit {
                        cells.append((slug, state.text))
                        if let healthID { health.insert(healthID) }
                    }
                }
            }
            return (cells, needs, max(0, rows.count - limit), health)
        } catch { return ([("unavailable", nameFailure(error))], [], 0, []) }
    }

    // MARK: Helpers

    static func helperRows(_ world: HerWorld, dataRoot: URL, person: String, now: Date) -> (cells: [(name: String, state: String)], more: Int) {
        do {
            let (bots, latest, running) = (world.bots, world.latest, world.running)
            let ordered = bots.sorted {
                (running.contains($0.id) ? 1 : 0, latest[$0.id]?.runAt ?? .distantPast)
                    > (running.contains($1.id) ? 1 : 0, latest[$1.id]?.runAt ?? .distantPast)
            }
            let cells: [(name: String, state: String)] = try withNames(dataRoot) { book in
                ordered.prefix(8).map { bot in
                    (book.slug(id: "bot:" + bot.id.uuidString, name: bot.name),
                     helperState(bot, entry: latest[bot.id], running: running.contains(bot.id), person: person, now: now))
                }
            }
            return (cells, max(0, bots.count - 8))
        } catch { return ([("unavailable", nameFailure(error))], 0) }
    }

    static func helperState(_ bot: BotDefinition, entry: ShelfEntry?, running: Bool, person: String, now: Date) -> String {
        var state: String
        if running { state = "⟳ running" }
        else if let entry {
            let ago = age(now.timeIntervalSince(entry.runAt))
            switch entry.runtimeStatus {
            case .completed: state = now.timeIntervalSince(entry.runAt) < 3600 ? "✓ done " + ago : StandingBotSchedule.words(bot.cadence) + " · " + ago
            case .failed: state = "✗ failed " + ago
            case .stopped: state = "✗ stopped " + ago
            case .interrupted: state = "✗ interrupted " + ago
            case .waitingForApproval: state = "waiting approval " + ago
            case .waitingOnPerson: state = "waiting on " + person + " " + ago
            }
        } else { state = StandingBotSchedule.words(bot.cadence) + " · never run" }
        return bot.paused ? state + " · paused" : state
    }

    // MARK: Crews

    static func crewRows(_ all: [[String: Any]], dataRoot: URL, now: Date, liveOnly: Bool = false) -> [String] {
        do {
            let rows = liveOnly ? all.filter { SwarmCrew.liveness(of: $0) != .settled } : Array(all.prefix(10))
            return try withNames(dataRoot) { book in
                try rows.compactMap { row -> String? in
                    guard let id = row["id"] as? String else { return nil }
                    let workers = row["workers"] as? [[String: Any]] ?? []
                    let working = workers.filter { ($0["status"] as? String ?? "working") == "working" }.count
                    let status = SwarmCrew.liveness(of: row) == .running ? "\(working) of \(workers.count) working"
                        : crewState(row, fallback: "done") + " · \(workers.count) workers"
                    let at = (liveOnly ? row["createdAt"] as? String
                        : row["completedAt"] as? String ?? (row["status"] as? String == "interrupted" ? nil : row["createdAt"] as? String)).flatMap(date)
                    let n = try book.number("crew", id: id) { Set(all.compactMap { $0["id"] as? String }) }
                    return pad("crew.\(n)", 10) + clip(firstLine(row["objective"] as? String ?? "A task"), liveOnly ? 40 : 44)
                        + " · " + status + (at.map { " · " + age(now.timeIntervalSince($0)) } ?? "")
                }
            }
        } catch { return [nameFailure(error)] }
    }

    /// A completed crew's status must disclose workers truncated at the output cap.
    static func crewState(_ row: [String: Any], fallback: String) -> String {
        let status = row["status"] as? String ?? fallback
        if status == "interrupted", row["completedAt"] == nil { return "interrupted · completion time unknown" }
        let workers = row["workers"] as? [[String: Any]] ?? []
        let cut = workers.filter { $0["outputTruncated"] as? Bool == true }.count
        guard status == "completed", cut > 0 else { return clip(status, 20) }
        return "finished with truncated workers (\(cut) of \(workers.count) cut off)"
    }

    /// Opening a crew: its task, each worker's state and first line.
    static func crewPage(id: String, name: String, dataRoot: URL) -> String? {
        let all: [[String: Any]]
        do { all = try SwiftNativeSwarmRunsReader(runsPath: dataRoot.appendingPathComponent("swarms/runs.json")).readCrews() }
        catch { return readFailure(error, reason: "crew_records_unavailable", remedy: crewStoreRemedy) }
        let row = all.first { $0["id"] as? String == id }
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
            if status == "working", SwarmCrew.liveness(of: row) == .unknown { status = "unknown" }
            if status == "completed", worker["outputTruncated"] as? Bool == true { status = "cut off" }
            lines.append("  \(index + 1) " + pad(clip(role, 16), 18) + pad(clip(status, 12), 11) + clip(firstLine(said), 90))
            if let error = nonEmpty(worker["error"] as? String) {
                lines.append(failureFace(.object(["status": .string(status), "reason": .string("crew_worker_error"),
                    "detail": .string(error), "effects": .string("unknown"), "remedy": Repair.reconcile(instruction: "Read the crew's retained evidence; repair the reported cause without discarding worker results or repeating the work.",
                        nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("agent.jobs"), "args": .object(["agent": .string("swarm"), "run_id": .string(id)])])]))])))
            }
        }
        let synthesis = (row["synthesis"] as? [String: Any])?["output"] as? String ?? row["synthesis"] as? String
        if let synthesis = nonEmpty(synthesis) { lines.append("synthesis: " + clip(synthesis.replacingOccurrences(of: "\n", with: " "), 400)) }
        let read = ToolFailureError.call("app", ["action": .string("agent.jobs"), "args": .object(["agent": .string("swarm"), "run_id": .string(id)])])
        lines.append("Full record: " + read + ". Back: app {}.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Small readers

    /// Adapt read errors to the existing failure envelope, keeping owner evidence.
    static func readFailure(_ error: any Error, reason: String, remedy: JSONValue) -> String {
        let typed = error as? ToolFailureError, sense = error as? SenseFailure
        let cancelled = error is CancellationError || typed?.status == .cancelled || sense?.code == "cancelled"
        var fields: [String: JSONValue] = [
            "status": .string(cancelled ? "cancelled" : "failed"),
            "reason": .string(reason),
            "detail": .string(typed?.message ?? sense?.message ?? error.localizedDescription),
            "effects": .string(typed?.effects.rawValue ?? "unknown"), "remedy": remedy,
        ]
        if let typed {
            fields.merge(typed.failureEvidence(defaultCode: reason)) { prior, owned in owned == .null ? prior : owned }
        }
        if let sense {
            fields.merge(sense.failureEvidence()) { prior, owned in owned == .null ? prior : owned }
        }
        if cancelled, typed?.nextCall == nil, typed?.tap == nil, sense?.remedy == nil {
            fields["remedy"] = Repair.terminal(instruction: "Do not repeat the cancelled read automatically.")
        }
        if let hint = (error as? LocalizedError)?.recoverySuggestion { fields["hint"] = .string(hint) }
        return failureFace(.object(fields))
    }

    static func fileReadFailure(_ error: any Error, reason: String, file: URL, shape: String) -> String {
        return readFailure(error, reason: reason, remedy: Repair.remedy(owner: file.path,
            nextCall: nil, tap: nil, instruction: ToolFailureError.fileRepairInstruction(file,
                shape: shape)
                + " Restore access or repair the reported file damage, preserving its original bytes and records."))
    }

    static func sensesRows(dataRoot: URL, now: Date, full: Bool = false) async -> [String] {
        let abilities = await AgentWorkspacePorts.current.tools.builtAbilities(dataRoot: dataRoot, now: now)
        guard let registry = SensesHub.shared.registry else {
            return [abilities, failureFace(.object(["status": .string("unavailable"), "reason": .string("sense_registry_unattached"),
                "detail": .string("The runtime has no sense registry attached."), "effects": .string("none"),
                "remedy": Repair.reconcile(instruction: "The app's runtime wiring needs repair; open doctor to inspect it.",
                    nextCall: .object(["tool": .string("app"), "input": .object(["item": .string("doctor")])]))]))]
        }
        async let records = registry.all()
        async let news = SenseNewsBoard.shared.latest(limit: SenseNewsBoard.capacity)
        let all: [SenseRecord]
        do { all = try await records }
        catch { return [abilities, readFailure(error, reason: "sense_registry_unavailable", remedy: Repair.reconcile(
            instruction: "Inspect the sense registry's reported cause before repairing it.",
            nextCall: .object(["tool": .string("app"), "input": .object(["item": .string("doctor")])])))] }
        let active = all.filter { $0.status == .on }.sorted { $0.corner.key < $1.corner.key }
        let corners = active.prefix(full ? active.count : 5).map { full ? $0.corner.surfaceName : clip($0.corner.surfaceName, 36) }.joined(separator: ", ")
        var rows = [abilities, "have: " + (active.isEmpty ? "none yet" : corners)
            + (!full && active.count > 5 ? " +\(active.count - 5) more" : "")]
        let grown = all.filter { $0.origin == .grown && $0.status == .on && $0.createdAt.map { now.timeIntervalSince($0) < 86_400 } == true }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }.prefix(full ? all.count : 2)
        let changes = grown.map { (full ? $0.corner.surfaceName : clip($0.corner.surfaceName, 32)) + " v\($0.version) grew" }
            + (await news).filter { now.timeIntervalSince($0.at) < 86_400 }
                .prefix(full ? Int.max : 2).map { full ? $0.summary : clip($0.summary, 60) }
        rows.append("senses: " + (changes.isEmpty ? "nothing changed recently" : changes.joined(separator: " · ")))
        let watches = await SensesHub.shared.liveWatches()
        rows.append("live watches: " + (watches.isEmpty ? "none" : watches.prefix(full ? watches.count : 5).map {
            let address = ContextSecretContentPolicy.redactedFragment($0.address)
            return (full ? address : clip(address, 60)) + " → \($0.senseID) v\($0.version) (\($0.corner.surfaceName))"
        }.joined(separator: " · ")) + (!full && watches.count > 5 ? " +\(watches.count - 5) more" : ""))
        rows += all.filter { $0.status == .unavailable }.prefix(full ? all.count : 2).map {
            failureFace(.object(["status": .string("unavailable"), "reason": .string("sense_unavailable"),
                "detail": .string($0.unavailableReason ?? "The sense is marked unavailable; no cause was retained."),
                "owner": .string($0.corner.key), "effects": .string("unknown"),
                "remedy": Repair.reconcile(instruction: "Read this sense's retained evidence before repairing or enabling it.",
                    nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("sense.versions"), "args": .object(["sense_id": .string($0.id)])])]))]))
        }
        if full {
            do {
                let files = try AbilityStore(dataRoot: dataRoot).files(kind: .sense)
                rows += files.map(\.partLine)
                for record in all where !files.contains(where: { $0.id == record.id }) {
                    rows.append(try AbilityStore.File(id: record.id, kind: .sense,
                        metadata: ["record": try .fromEncodable(record)], body: "", pathExtension: "js").partLine)
                }
            } catch { rows.append(readFailure(error, reason: "sense_files_unavailable", remedy: Repair.reconcile(
                instruction: "Inspect the reported ability-file failure before changing the files.",
                nextCall: .object(["tool": .string("app"), "input": .object(["item": .string("doctor")])])))) }
        }
        return rows
    }

    /// The last send's own failure evidence and recovery action.
    static func sendFailure(_ contact: Contact, receipt: [String: JSONValue]) -> String? {
        for key in ["execution_error", "error"] {
            if let evidence = receipt[key], evidence != .null, evidence != .string("") {
                var fields = receipt
                if fields["detail"] == nil { fields["detail"] = evidence }
                if fields["reason"] == nil { fields["reason"] = .string("agent_execution_error") }
                if fields["effects"] == nil { fields["effects"] = .string("unknown") }
                if fields["remedy"] == nil {
                    fields["remedy"] = Repair.reconcile(instruction: "Read execution and delivery evidence before sending another message.",
                        nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("agent.read"),
                            "args": .object(["agent": .string(contact.id)])])]))
                }
                return failureFace(.object(fields))
            }
        }
        return nil
    }

    /// Keep the owner's evidence intact, including fixes and executable levers.
    static func failureFace(_ value: JSONValue) -> String {
        let evidence: JSONValue
        if case .object(let fields) = value {
            let keys: Set<String> = ["status", "reason", "failure_code", "error_code", "code", "detail", "message", "error",
                "effects", "remedy", "fix", "hint", "owner", "next_call", "tap", "not_run_status", "provenance", "input_excerpt",
                "recovery_hint", "argument_path", "accepted", "connected", "needs", "needs_input", "needs_authentication"]
            evidence = .object(fields.filter { keys.contains($0.key) && $0.value != .null })
        } else { evidence = value }
        return UntrustedText.neutralized((try? evidence.serialize(pretty: false)) ?? String(describing: evidence))
    }

    /// Legacy text can contain a complete owner remedy; never take only its first line.
    static func failureReason(_ error: String) -> String {
        UntrustedText.neutralized(error)
    }

    static func age(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, let whole = Int(exactly: seconds.rounded(.towardZero)) else { return "invalid age" }
        let s = max(0, whole)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 3 * 3600 { return "\(s / 3600)h\((s % 3600) / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    static func date(_ text: String) -> Date? {
        NativeTimestampFormat.parseISO8601FractionalFirst(text)
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
    package static func clip(_ text: String, _ limit: Int) -> String {
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

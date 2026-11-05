import Experiences
import AuthoredCapabilities
import AppKit
import Foundation
import os
import NativeAgentCore
import ApprovalInbox
import MacControl
import MemoryV2
import PersistenceCore
import ChromeControl
import Desk
import StandingBots
import Senses
import NativeAgentShared
// Blueprint: | `AgentScreen.swift` | `AgentScreen`, `withNames`, `resolve`: stable names and checked owner projections |
// Home acknowledges displayed identities only; retain hidden/capped changes and unreadable observation timestamps.
// Home and turn context share registry/news sense changes and live ability state.

/// Home renders retained owner state in layout order without reading another domain.
package enum AgentScreen {
    enum Target { case action(AgentWorkspaceAction), page(String) }

    // MARK: - Stable names (data/her_screen/names.json)

    /// Issued numbers are never reused across turns or restarts; Desk aliases already supply stable identity.
    struct NameBook: Codable, Equatable {
        struct Slug: Codable, Equatable { var id: String; var name: String }
        var slugs: [String: Slug] = [:]
        var numbers: [String: [String: Int]] = [:]
        var next: [String: Int] = [:]
        /// Display metadata, keyed by issued room/number; never an identity.
        var titles: [String: String]? = nil

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
            while slugs[candidate] != nil || AgentScreen.reserved.contains(candidate) {
                candidate = base + "-\(suffix)"; suffix += 1
            }
            slugs[candidate] = .init(id: id, name: name)
            return candidate
        }

        /// Prune only missing items after 200 names of a kind; retained counters must lead issued numbers, and exhaustion must fail without reuse.
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

        mutating func number(_ kind: String, id: String, title: String? = nil, existing: () -> Set<String>) throws -> Int {
            func retainedNumber() -> Int? {
                if let n = numbers[kind]?[id] { return n }
                // Preserve issued numbers by owner locator despite display-title changes; duplicate bindings cannot be reassigned.
                guard kind.hasPrefix("item."), let locator = AgentScreen.recordIdentity(id) else { return nil }
                return numbers[kind]?.filter { AgentScreen.recordIdentity($0.key) == locator }.map(\.value).min()
            }
            if let n = retainedNumber() {
                if let title {
                    titles = titles ?? [:]
                    titles?[kind + ":" + String(n)] = title
                    if let locator = AgentScreen.recordIdentity(id) {
                        for (key, alias) in numbers[kind] ?? [:] where AgentScreen.recordIdentity(key) == locator {
                            titles?[kind + ":" + String(alias)] = title
                        }
                    }
                }
                return n
            }
            let n = next[kind] ?? 1
            let (following, overflow) = n.addingReportingOverflow(1)
            guard n > 0, !overflow else { throw NameFailure("The \(kind) name counter is exhausted") }
            numbers[kind, default: [:]][id] = n
            next[kind] = following
            if let title { titles = titles ?? [:]; titles?[kind + ":" + String(n)] = title }
            if let row = numbers[kind], row.count > 200 {
                let keep = existing().union([id])
                numbers[kind] = row.filter { entry in
                    keep.contains(entry.key) || (AgentScreen.recordIdentity(entry.key).map { keep.contains($0) } == true)
                }
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
        let typed = error as? ToolFailureError
        return readFailure(error, reason: "workspace_source_unavailable", remedy: Repair.remedy(owner: typed?.owner ?? "Workspace source",
            nextCall: nil, tap: typed?.tap,
            instruction: typed?.instruction
                ?? "Preserve saved bytes and repair the reported source's read/write access before continuing; do not repeat completed work."))
    }

    static func withNames<T>(workspace: WorkspaceOperation, _ dataRoot: URL, _ body: (inout NameBook) throws -> T) throws -> T {
        let url = dataRoot.appendingPathComponent("her_screen/names.json")
        namesLock.lock(); defer { namesLock.unlock() }
        let key = dataRoot.standardizedFileURL.path + "\u{0}names"
        // Only absence creates a book. Every present unreadable or invalid book stays byte-for-byte intact and its failure reaches the caller.
        let old = try AgentMemo.shared.cached(key, stamp: [stamp(url)]) {
            do { return try JSONDecoder().decode(NameBook.self, from: Data(contentsOf: url)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return NameBook() }
        }
        try old.validate()
        var book = old
        let result = try body(&book)
        if book != old, !workspace.previewing {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(book), to: url)
                AgentMemo.shared.put(key, book, stamp: [stamp(url)])
            } catch { nativeLog("Workspace names could not be saved: %@", error.localizedDescription); throw error }
        }
        return result
    }

    static let placeNames = AppDoorNames.places
    package enum NameKind { case unknown, read, effect }
    package static func classify(workspace: WorkspaceOperation, _ name: String, dataRoot: URL, scope: String) async -> NameKind {
        switch await resolve(workspace: workspace, name, dataRoot: dataRoot, scope: scope, browserPages: []) {
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
        Set(placeNames.keys).union(views.keys).union(AgentWorkspaceEnvironment.destinations.map(\.id)).union(["crews", "delegations", "elsewhere"])

    static let verbs: Set<String> = ["say", "run", "settings", "note", "done", "drop", "status", "add", "go", "click", "fill", "more"]

    /// Reuse an existing window for the same item instead of duplicating it.
    static func resolve(workspace: WorkspaceOperation, _ raw: String, dataRoot: URL, scope: String, browserPages: [AgentWorkspaceLocation],
                        openPlaces: [AgentWorkspaceLocation] = [], currentPlace: AgentWorkspaceLocation? = nil) async -> Target? {
        do {
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if name.hasPrefix("agent/") {
                let id = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("agent/".count))
                guard id.hasPrefix("peer:") || id.hasPrefix("bot:") else { return nil }
                return .action(.open(.record(tool: "agent_read", input: ["agent": .string(id)], title: id)))
            }
            if name == "senses" {
                return .page("MY SENSES\n" + (await sensesRows(workspace: workspace, dataRoot: dataRoot, now: Date(), full: true)).joined(separator: "\n"))
            }
            for (prefix, tool, field) in [("mac.look", "screen", "app"), ("mac.go", "go", "name")]
                where name == prefix || name.hasPrefix(prefix + " ") {
                let app = raw.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                let title = tool == "go" ? "Open an app" : app.isEmpty ? "Look at an app" : app
                return .action(.perform(tool: tool, input: app.isEmpty ? [:] : [field: .string(app)], title: title,
                                        textField: app.isEmpty ? field : nil, isEffect: tool == "go"))
            }
            if let target = buildTarget(workspace: workspace, name, dataRoot: dataRoot) { return target }
            if name.hasPrefix("elsewhere."), try !MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) {
                return .page(elsewhereRoom(workspace: workspace, dataRoot: dataRoot, scope: scope))
            }
            let cachedName = name.hasPrefix("windows.") || name.hasPrefix("elsewhere.") ? scope + "\u{0}" + name : name
            if let page = AgentItemPages.shared.page(workspace: workspace, dataRoot, cachedName) { return .page(page) }
            if name == "elsewhere" { return .page(elsewhereRoom(workspace: workspace, dataRoot: dataRoot, scope: scope)) }
            if let action = try namedAction(workspace: workspace, name, dataRoot: dataRoot, scope: scope) {
                if case .open(let place) = action, case .record = place { return open(place) }
                return .action(action)
            }
            if let target = await agentsTarget(workspace: workspace, name, dataRoot: dataRoot) { return target }
            if let comms = commsTarget(workspace: workspace, name, dataRoot: dataRoot) { return comms }
            var verb: String?
            if let dot = name.lastIndex(of: "."), verbs.contains(String(name[name.index(after: dot)...])) {
                verb = String(name[name.index(after: dot)...]); name = String(name[..<dot])
            }
            func open(_ place: AgentWorkspaceLocation) -> Target {
                let existing = openPlaces.last { AgentWorkspaceNavigation.placeIdentity($0) == AgentWorkspaceNavigation.placeIdentity(place)
                    || sameConversation($0, place) }
                return .action(.window(AgentWorkspaceNavigation.windowAction(existing ?? place)))
            }
            if let web = webTarget(workspace: workspace, name, verb: verb, dataRoot: dataRoot, scope: scope) { return web }
            if name == "desk", verb == "add" { return .action(.configure(tool: "desk_add_item", input: [:], title: "Add work")) }
            if name.hasPrefix("desk.") {
                let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
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
                case "drop": return .action(.perform(tool: "desk_close", input: handle.merging(["canceled": .bool(true),
                    "reason": .string("dropped")]) { a, _ in a }, title: name + " dropped", textField: nil, isEffect: true))
                // A supplied status executes in one call without leaving a form open.
                case "status": return .action(.perform(tool: "desk_set_status", input: handle, title: "Status of " + name, textField: "status", isEffect: true))
                default: return nil
                }
            }
            if verb == nil, name.hasPrefix("chat.") || UUID(uuidString: name) != nil || name == scope.lowercased() {
                let id = name.hasPrefix("chat.") ? try Int(name.dropFirst(5)).flatMap { n in try withNames(workspace: workspace, dataRoot, { $0.id("chat",
                    n) }) } : raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let id, let row = try HumanConversationIndex.rows(dataRoot: dataRoot).first(where: {
                    $0["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })?.caseInsensitiveCompare(id) == .orderedSame
                }), let session = row["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) {
                    return open(.record(tool: "chat_conversations", input: ["conversation_session_id": .string(session)],
                                        title: row["title"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "Conversation"))
                }
            }
            if verb == nil, name.hasPrefix("browser.tab"), let n = Int(name.dropFirst(11)),
               let id = try withNames(workspace: workspace, dataRoot, { $0.id("browser.tab", n) }),
               let page = browserPages.first(where: { AgentWorkspaceNavigation.placeIdentity($0) == id }) {
                return .action(.window(AgentWorkspaceNavigation.windowAction(page)))
            }
            // Resolve names to their room without requiring protocol handles.
            if let slug = try withNames(workspace: workspace, dataRoot, { book in
                book.slugs[name] ?? book.slugs.values.first { $0.name.caseInsensitiveCompare(raw.trimmingCharacters(
                    in: .whitespacesAndNewlines)) == .orderedSame }
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
                case ("run", let id?): return .action(.perform(tool: "bot_run_once", input: ["id": .string(id)], title: "Run " + slug.name, textField: nil,
                    isEffect: true))
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

    /// Match contact IDs case-insensitively; an explicit thread matches only itself, while a contact name can reuse any open thread.
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

    private static let homeFooter = [
        "Open: app {item:\"desk.4\"} or {item:\"mail\"}; text/fields: args. Also: windows, people, conversations, arrivals, work, mac.",
        "Face links page:home/<item> open with app {page:\"home\", item:\"<item>\"}; "
            + "page:desk/<handle> with app {page:\"desk\", item:<handle>}.",
        "Job rows: agent.read {job:<row id without job:>}. Queue: queue.done / queue.drop {id:<row id>}.",
        "Blocked steps: desk.wait {handle:<page:desk handle>, on:<card, message or debt id>}. Peer elevation: Trust > Connected agents.",
        "Arrival rows: home.accept {id:<row id without arrival:>}. Repair: repair.let_go {id:<row id>, reason}.",
        "Find: app {page:\"home\", find:\"…\"}.",
    ]

    /// Only `markSeen: true` advances Home's observation; the user's Agent view must not mark seen.
    static func home(workspace: WorkspaceOperation, dataRoot: URL, scope: String, browserPages: [AgentWorkspaceLocation], windows: [String] = [],
                     now: Date = Date(), markSeen: Bool = true) async -> String {
        var sharedFace: PartFace?
        do {
            let layout = SurfaceLayoutStore.layout(dataRoot: dataRoot)
            let (agent, person) = names(dataRoot)
            let world = await readWorld(workspace: workspace, dataRoot, now: now)
            let face = try await HomeFace.door(dataRoot: dataRoot)
            sharedFace = face
            let seen = await lastSeen(dataRoot)
            let presence = PersonPresence.read(dataRoot: dataRoot, now: now)
            let connected = BrowserConnectionMirror.connected == true
            let page = ChromePageMirror.page(tab: nil, dataRoot: dataRoot, session: scope)
            var marks = try worldMarks(workspace: workspace, world, dataRoot: dataRoot, person: person, now: now)
            try preserveUnreadMarks(&marks, seen: seen, world: world, workspace: workspace, dataRoot: dataRoot)
            // Home alone acknowledges presence, Chrome, day badges and this chat's tabs.
            var shown: [String: Mark] = [:]
            if let transition = presence.transition {
                let word = transition.here ? " here" : " away"
                shown["home:presence"] = Mark(fp: word, line: person + word, at: now.timeIntervalSince1970)
            }
            shown["home:browser"] = Mark(fp: connected ? "on" : "off",
                line: "browser: " + (connected ? person + "'s Chrome connected" : "Chrome not connected"), at: now.timeIntervalSince1970)
            for name in ["calendar", "reminders"] {
                let words = AgentReadBadges.shared.latest(name, dataRoot: dataRoot)
                    .flatMap { Calendar.current.isDate($0.at, inSameDayAs: now) ? $0.words : nil }
                    ?? ""
                shown["home:" + name] = Mark(fp: words, line: words.isEmpty ? "" : name + ": " + words, at: now.timeIntervalSince1970)
            }
            let tabs: [(id: String, title: String)] = page.map { [("tab:" + String($0.tab), tabTitle($0))] }
                ?? browserPages.compactMap { place in AgentWorkspaceNavigation.placeIdentity(place).map { ($0, place.title) } }
            // Tabs are per chat: another chat's saved tabs pass through untouched (a day at most), so its home never calls them closed here.
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
            if let failure = layout.failure { header.append(failure.localizedDescription) }
            header.append(person + ": " + presence.line)
            let defaults = UserDefaults.standard
            if let mode = defaults.string(forKey: "nativeagent.viewMode") { header.append(mode.capitalized + " view") }
            if let problem = seen?.problem { header.append(problem) }
            else if let seen {
                header.append("since you looked \(age(now.timeIntervalSince1970 - seen.at)) ago: "
                    + (changed.isEmpty ? "no changes" : "\(changed.count) change\(changed.count == 1 ? "" : "s")"))
            }

            let outside: Set<String> = ["people", "helpers", "senses", "elsewhere", "places", "mac"]
            var visible = face.sections.filter { $0.id != "changed" }
            var acknowledged: Set<String> = presence.transition == nil ? [] : ["home:presence"]
            if face.sections.contains(where: { $0.id == "changed" }) {
                for change in changed.prefix(5) { acknowledged.formUnion(change.names) }
            }
            let compared = PartFace(sections: visible.filter { outside.contains($0.id) }).text()
            var same: String?
            let outsideUnsettled = visible.filter { outside.contains($0.id) }.flatMap(\.rows).contains {
                $0.tone == .failed || $0.tone == .attention
            }
            if markSeen, changed.isEmpty, !outsideUnsettled, let whole = AgentMemo.shared.shownHome(
                dataRoot.standardizedFileURL.path + "\u{0}" + scope, rows: compared, now: now.timeIntervalSince1970, within: 120) {
                visible.removeAll { outside.contains($0.id) }
                same = "SAME · people, helpers, places and Mac as on the home you saw " + age(now.timeIntervalSince1970 - whole) + " ago"
            }
            let rule = String(repeating: "─", count: 61)
            var lines = [header.joined(separator: " · "), rule]
            if face.sections.contains(where: { $0.id == "changed" }) {
                lines += section("CHANGED", ["Tracked home records since last look; not all activity."]
                    + changed.prefix(5).map { "● " + clip($0.line, 70) }
                    + (changed.count > 5 ? ["+\(changed.count - 5) more"] : []))
            }
            if !windows.isEmpty {
                lines.append("This chat's OPEN · " + windows.prefix(3).map { clip($0, 40) }.joined(separator: " · ")
                    + (windows.count > 3 ? " +\(windows.count - 3)" : "") + " · item \"windows\"")
            }
            if let tab = webTabCell(workspace: workspace, dataRoot: dataRoot, scope: scope, now: now) {
                lines.append("This chat's browser · " + tab)
            } else if !browserPages.isEmpty {
                let open = Set(browserPages.compactMap(AgentWorkspaceNavigation.placeIdentity))
                let tabs = try withNames(workspace: workspace, dataRoot) { book in
                    try browserPages.prefix(3).compactMap { page -> String? in
                        guard let id = AgentWorkspaceNavigation.placeIdentity(page) else { return nil }
                        return "browser.tab\(try book.number("browser.tab", id: id, existing: { open })) \"\(clip(page.title, 24))\""
                    }
                }
                lines.append("This chat's browser · " + tabs.joined(separator: ", "))
            }
            lines.append("This Mac · " + (await macFront(person)) + " · item \"mac\"")
            lines.append(PartFace(sections: visible).text(door: true))
            if let same { lines.append(same) }
            lines.append(rule)
            lines += homeFooter
            let book = try withNames(workspace: workspace, dataRoot) { $0 }
            if visible.contains(where: { $0.id == "people" }) {
                for contact in world.contacts {
                    if let slug = book.slugs.first(where: { $0.value.id == contact.id })?.key { acknowledged.insert(slug) }
                    acknowledged.insert("health:" + world.healthID(for: contact, record: latest(contact, records: world.records)))
                }
            }
            if visible.contains(where: { $0.id == "helpers" }) {
                for bot in world.bots {
                    if let slug = book.slugs.first(where: { $0.value.id == "bot:" + bot.id.uuidString })?.key { acknowledged.insert(slug) }
                }
            }
            if visible.contains(where: { $0.id == "places" }) {
                let places = Set(layout.contentNames("places", profile: SurfaceLayoutStore.profile).map(AppDoorNames.resolve))
                for place in ["browser", "calendar", "reminders"] where places.contains(place) { acknowledged.insert("home:" + place) }
                if places.contains("browser"), let page { acknowledged.insert(ownTabs + "tab:" + String(page.tab)) }
            }
            if markSeen, world.pending.isEmpty, world.failures.isEmpty {
                Self.markSeen(dataRoot, marks: marks, only: acknowledged, now: now)
            }
            return lines.joined(separator: "\n")
        } catch {
            guard let face = sharedFace else { return nameFailure(error) }
            let failedLook = PartFace.Section(id: "changed", title: "Changed", rows: [
                .init(id: "changed.failed", title: "This Home look is incomplete", detail: nameFailure(error), tone: .failed),
            ])
            return PartFace(title: face.title, line: face.line,
                sections: [failedLook] + face.sections.filter { $0.id != "changed" }).text(door: true)
                + "\nNothing was marked seen.\n" + homeFooter.joined(separator: "\n")
        }
    }

    static func section(_ label: String, _ rows: [String]) -> [String] {
        let width = max(10, label.count + 1)
        return rows.enumerated().map { ($0.offset == 0 ? pad(label, width) : String(repeating: " ", count: width)) + $0.element }
    }

    // MARK: Desk

    /// Use DeskParking's shared last-touch rule; a live execution keeps work active.
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

    /// Keep repair owed until its operation succeeds or is released; agent-owned repairs stay in MY QUEUE, person-owned ones in owner waits.
    static func owedRows(_ dataRoot: URL, person: String, now: Date) async -> (agent: [String], person: [String]) {
        let open: [Experience]
        do { open = try await ExperienceStore.at(dataRoot).projection() }
        catch {
            let file = dataRoot.appendingPathComponent("experiences/experiences.sqlite")
            return ([readFailure(error, reason: "repairs_unavailable", remedy: Repair.remedy(owner: file.path,
                nextCall: nil, tap: nil, instruction: ToolFailureError.fileRepairInstruction(file,
                    shape: "The repair ledger could not be read: \(error.localizedDescription). Preserve its records and SQLite journals.")))], [])
        }
        var agentRows: [String] = [], personRows: [String] = []
        for act in open.sorted(by: { $0.at > $1.at }) {
            guard RepairOwed.isOwed(act), let owed = act.owes["repair"] else { continue }
            let debt = RepairDebt(act)
            let when = NativeTimestampFormat.parseISO8601FractionalFirst(act.at).map { " " + age(now.timeIntervalSince($0)) } ?? ""
            let what = failureReason(debt.operation ?? "a call") + " " + (act.outcome?.status ?? "outcome not recorded")
                + when + " by " + failureReason(debt.owner ?? "owner not recorded")
            let release = " · or let go: app {action:\"repair.let_go\", args:{id:\"\(act.id)\", reason}}"
            if owed.to == "person" {
                personRows.append(pad("repair", 10) + what + " · ask \(person): " + (debt.tap ?? "?")
                    + " · " + failureReason(act.face?.words ?? "")
                    + (debt.nextCall.map { " · " + failureReason($0) } ?? "") + release)
            } else {
                agentRows.append(pad("repair", 10) + what + " · " + failureReason(act.face?.words ?? "") + " · " + failureReason(debt.nextCall
                    ?? "read the act")
                    + (debt.tap.map { " · " + failureReason($0) } ?? "")
                    + release)
            }
        }
        let cap = 4
        return (Array(agentRows.prefix(cap)) + (agentRows.count > cap ? ["+\(agentRows.count - cap) more repairs owed"] : []),
                Array(personRows.prefix(cap)) + (personRows.count > cap ? ["+\(personRows.count - cap) more for \(person)"] : []))
    }

    // MARK: People

    struct Contact { let id: String; let name: String; let kind: String?; var agents: [String] = [] }

    /// Only persisted bridge identity establishes a sender; `heard` tracks their message and `answered` tracks the newest local reply.
    package struct BridgeChat { package let id: String; package let who: String; package let title: String; package let at: Date;
        package var heard: Date? = nil; package var answered = false }

    package static func bridgeChats(dataRoot: URL) throws -> [BridgeChat] {
        var chats: [BridgeChat] = try AgentWorkSession.verified(dataRoot: dataRoot).compactMap { session in
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
        // Bound sender history to the two newest chats and the last 32 KB of each.
        var looked: [String: Int] = [:]
        for index in chats.indices where looked[chats[index].who, default: 0] < 2 {
            looked[chats[index].who, default: 0] += 1
            let tail = try chatTail(chats[index].id, dataRoot: dataRoot, bytes: 32_768)
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
            // Shared display names do not make two routes one.
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

    static func latest(_ contact: Contact, records: [AgentConversationRecord], label: String? = nil) -> AgentConversationRecord? {
        var newest: AgentConversationRecord?
        for record in records where label == nil || record.label == label {
            guard record.agent.caseInsensitiveCompare(contact.id) == .orderedSame || contact.agents.contains(record.agent) else { continue }
            if let newest, record.updatedAt <= newest.updatedAt { continue }
            newest = record
        }
        return newest
    }

    static func thread(_ contact: Contact, dataRoot: URL, identity: AgentContactIdentity, transcripts: [(String, URL)]) throws -> BridgeChat? {
        let owner = String(contact.id.dropFirst(5))
        let tail = try ContactThread.mergedLines(dataRoot: dataRoot, owner: owner, tailBytes: 65_536, identity: identity, transcripts: transcripts)
        guard let last = tail.last else { return nil }
        return BridgeChat(id: ContactThread.session(owner: owner), who: contact.id, title: "", at: last.at,
                          heard: tail.last { !$0.mine }?.at, answered: last.mine)
    }

    /// Use the contact's latest exchange, including a newer bridge chat when it is the answering route.
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
                else { text = "… waiting " + age(now.timeIntervalSince(record.operationStartedAt ?? record.updatedAt)) }
            } else if receipt["needs_input"] == .bool(true) || receipt["needs_authentication"] == .bool(true) {
                text = "? asks for input " + ago; asks = true; change = "asks for input"
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

    static func peopleRows(workspace: WorkspaceOperation, _ world: AgentWorld, dataRoot: URL, now: Date, scope: String? = nil,
        limit: Int = 8) -> (cells: [(name: String, state: String)],
        needs: [String], more: Int, health: Set<String>) {
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
            try withNames(workspace: workspace, dataRoot) { book in
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

    // MARK: Working and crews

    /// One job as home shows it: another agent's or a line of the agent's own.
    package struct JobGlance: Sendable {
        package let id: String
        package let agent: String
        package let name: String
        package let own: Bool
        package let state: String
        package let working: Bool
        package let brief: String
        /// The Desk item the job carries, as the agent bound it.
        package let desk: String?
        package let at: Date
        package init(id: String, agent: String, name: String, own: Bool, state: String, working: Bool, brief: String, desk: String?, at: Date) {
            self.id = id; self.agent = agent; self.name = name; self.own = own; self.state = state; self.working = working; self.brief = brief
            self.desk = desk; self.at = at
        }
    }

    /// The agent's jobs as their owner (AgentJobs) reads them, newest first; it installs this reader at launch.
    package static let jobGlances = OSAllocatedUnfairLock<(@Sendable (URL) throws -> [JobGlance])?>(initialState: nil)

    static func jobRows(dataRoot: URL, now: Date, _ keep: (JobGlance) -> Bool, empty: String) -> [String] {
        guard let read = jobGlances.withLock({ $0 }) else { return ["your jobs are not readable in this app yet"] }
        do {
            let rows = try read(dataRoot).filter(keep).prefix(10)
            return rows.isEmpty ? [empty] : rows.map { job in
                pad(job.own ? "line" : clip(job.name, 8), 10) + clip(firstLine(job.brief), 44) + " · " + job.state + " · "
                    + age(now.timeIntervalSince(job.at)) + " · agent.read {agent:\"\(job.agent)\", job:\"\(job.id)\"}"
            }
        } catch { return ["your jobs could not be read: " + error.localizedDescription] }
    }

    /// The agent's lines are its crews: each a turn in its own work conversation, several at once side by side.
    static func crewsRoom(dataRoot: URL, now: Date = Date()) -> String {
        screen(["CREWS", "your own lines"], [jobRows(dataRoot: dataRoot, now: now, { $0.own }, empty: "no lines yet")],
            verbs: [("agent.job {agent:\"self\", brief, instructions?}", "start a line of your own"), ("agent.jobs {agent:\"self\"}", "list them")])
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

    static func sensesRows(workspace: WorkspaceOperation, dataRoot: URL, now: Date, full: Bool = false) async -> [String] {
        let reading = await sensesReading(workspace: workspace, dataRoot: dataRoot, now: now, full: full)
        return reading.rows + reading.failures
    }

    struct SenseReading: Sendable { var rows: [String]; var failures: [String] }

    static func sensesReading(workspace: WorkspaceOperation, dataRoot: URL, now: Date, full: Bool = false) async -> SenseReading {
        var abilities: [String] = [], failures: [String] = []
        do { abilities = [try await workspace.ports.tools.builtAbilities(dataRoot: dataRoot, now: now)] }
        catch {
            failures.append(readFailure(error, reason: "abilities_unavailable", remedy: Repair.reconcile(
                instruction: "Inspect the reported ability inventory failure before changing its files.",
                nextCall: .object(["tool": .string("app"), "input": .object(["item": .string("doctor")])]))))
        }
        let presenceRows = full ? [names(dataRoot).person + ": " + PersonPresence.read(dataRoot: dataRoot, now: now).line] : []
        guard let registry = SensesHub.shared.registry else {
            return .init(rows: presenceRows + abilities, failures: failures + [failureFace(.object([
                "status": .string("unavailable"), "reason": .string("sense_registry_unattached"),
                "detail": .string("The runtime has no sense registry attached."), "effects": .string("none"),
                "remedy": Repair.reconcile(instruction: "The app's runtime wiring needs repair; open doctor to inspect it.",
                    nextCall: .object(["tool": .string("app"), "input": .object(["item": .string("doctor")])]))]))])
        }
        async let records = registry.all()
        async let news = SenseNewsBoard.shared.latest(limit: SenseNewsBoard.capacity)
        let all: [SenseRecord]
        do { all = try await records }
        catch { return .init(rows: presenceRows + abilities, failures: failures + [readFailure(error,
            reason: "sense_registry_unavailable", remedy: Repair.reconcile(
            instruction: "Inspect the sense registry's reported cause before repairing it.",
            nextCall: .object(["tool": .string("app"), "input": .object(["item": .string("doctor")])])))]) }
        let active = all.filter { $0.status == .on }.sorted { $0.corner.key < $1.corner.key }
        let corners = active.prefix(full ? active.count : 5).map { full ? $0.corner.surfaceName : clip($0.corner.surfaceName, 36) }.joined(separator: ", ")
        var rows = presenceRows + abilities + ["have: " + (active.isEmpty ? "none yet" : corners)
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
        failures += all.filter { $0.status == .unavailable }.prefix(full ? all.count : 2).map {
            failureFace(.object(["status": .string("unavailable"), "reason": .string("sense_unavailable"),
                "detail": .string($0.unavailableReason ?? "The sense is marked unavailable; no cause was retained."),
                "owner": .string($0.corner.key), "effects": .string("unknown"),
                "remedy": Repair.reconcile(instruction: "Read this sense's retained evidence before repairing or enabling it.",
                    nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("sense.versions"), "args": .object(["sense_id": .string($0
                        .id)])])]))]))
        }
        if full {
            do {
                let files = try AbilityStore(dataRoot: dataRoot).files(kind: .sense)
                rows += files.map(\.partLine)
                for record in all where !files.contains(where: { $0.id == record.id }) {
                    rows.append(try AbilityStore.File(id: record.id, kind: .sense,
                        metadata: ["record": try .fromEncodable(record)], body: "", pathExtension: "js").partLine)
                }
            } catch { failures.append(readFailure(error, reason: "sense_files_unavailable", remedy: Repair.reconcile(
                instruction: "Inspect the reported ability-file failure before changing the files.",
                nextCall: .object(["tool": .string("app"), "input": .object(["item": .string("doctor")])])))) }
        }
        return .init(rows: rows, failures: failures)
    }

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
                "recovery_hint", "argument_path", "accepted", "connected", "needs", "needs_input", "needs_authentication",
                "gaps", "unresponsive_engines", "total_is_complete"]
            evidence = .object(fields.filter { keys.contains($0.key) && $0.value != .null })
        } else { evidence = value }
        return UntrustedText.neutralized((try? evidence.serialize(pretty: false)) ?? String(describing: evidence))
    }

    /// Keep complete owner remedies, even when supplied as text.
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

    /// Defuse every non-empty source line before joining it; fenced code contributes only its first line as a code excerpt.
    static func plainLines(_ text: String) -> [String] {
        var body = text
        while let fence = body.range(of: #"```[^\n]*\n[\s\S]*?(```|$)"#, options: .regularExpression) {
            let first = body[fence].split(whereSeparator: \.isNewline).dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("```") }
            body.replaceSubrange(fence, with: "\n" + (first.map { "code: " + clip($0.replacingOccurrences(of: "`", with: "'"), 60) } ?? "code") + "\n")
        }
        return body.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            var line = String(raw)
            for (pattern, template) in [
                (#"^\s*(#{1,6}|>+)\s*"#, ""),
                (#"^\s*([-*+•]|\d{1,3}[.)])\s+"#, ""),
                (#"^\s*([-*_|:]\s*){3,}$"#, ""),
                (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
                (#"(\*\*|__|~~|`+)"#, ""),
                (#"(?<![\w*])[*_](?=\S)([^*_\n]*?\S)[*_](?![\w*])"#, "$1"),
                (#"^\s*([-*+•]|\d{1,3}[.)])\s+"#, ""),
            ] { line = line.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
            line = UntrustedText.neutralized(line.trimmingCharacters(in: .whitespaces))
            return line.contains(where: { $0.isLetter || $0.isNumber }) ? line : nil
        }
    }

    /// Include a second sentence when the first is under 16 characters so terse acknowledgements retain useful context.
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

    /// Outside titles and replies must become inert bounded text before Home displays them.
    package static func clip(_ text: String, _ limit: Int) -> String {
        // Defuse each line before joining so a leading result header cannot move past detection.
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

    /// Content titles exclude transport prefixes and greetings; retain the sender separately for disambiguation.
    static func humanTitle(_ raw: String, agentName: String?) -> (title: String, who: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines), who: String?
        if text.hasPrefix("[from: "), let end = text.range(of: ", via bridge]") {
            let label = String(text[text.index(text.startIndex, offsetBy: 7)..<end.lowerBound])
            who = label.prefix(1).uppercased() + label.dropFirst()
            text = String(text[end.upperBound...])
        }
        let greeting = (agentName ?? "").lowercased()
        var words = text.split(whereSeparator: \.isWhitespace)[...]
        // A greeting to the agent is not the topic of the chat.
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

    /// Use short civil times to distinguish otherwise matching chats.
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

    /// Append sender and time only when titles collide.
    static func disambiguate(_ titles: [String], who: [String?], at: [Date?]) -> [String] {
        let counts = Dictionary(titles.map { ($0, 1) }, uniquingKeysWith: +)
        var result = titles.indices.map { i in
            counts[titles[i], default: 0] < 2 ? titles[i]
                : ([titles[i]] + [who[i], at[i].map { when($0) }].compactMap { $0 }).joined(separator: " · ")
        }
        // Number remaining collisions in list order.
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

/// Defuse tool openers and leading result headers so outside text cannot impersonate calls or result blocks.
public enum UntrustedText {
    public static func neutralized(_ text: String) -> String {
        text.replacingOccurrences(of: #"<(/?)(invoke|tool_use|tool_result|function_calls|function_results|parameter|antml:)"#,
                                  with: "‹$1$2", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?m)^([ \t]*)(NativeAgent tool result)"#, with: "$1│ $2",
                                  options: [.regularExpression, .caseInsensitive])
    }
}

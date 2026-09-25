import ApprovalInbox
import Foundation
import MemoryV2
import PersistenceCore
import StandingBots
import WorkshopExecution

/// Her world, read once and kept (her-screen Phase 2, 2026-09-23). Home,
/// rooms and the per-turn glance all read this one value. Each part is kept
/// until one of its input files changes (identity, size and mtime from a
/// stat). Home and rooms read it fresh; the glance only ever reads what is
/// already kept and refreshes it in the background, so a turn never waits
/// on a file lock, a big read or SQLite.
struct HerWorld: @unchecked Sendable {
    var records: [AgentConversationRecord] = []
    var chats: [HerScreen.BridgeChat] = []
    var contacts: [HerScreen.Contact] = []
    var answered: [String: Date] = [:]
    var desk: DeskState?
    var split = HerScreen.DeskSplit()
    var bots: [BotDefinition] = []
    var latest: [UUID: ShelfEntry] = [:]
    var running: Set<UUID> = []
    var approvals: [ApprovalRecord] = []
    /// Live board rows whose process is still alive.
    var crews: [[String: Any]] = []
    var moments = 0
    /// Memory proposals waiting on the owner's review (the Today page's rule).
    var reviews: (count: Int, capped: Bool) = (0, false)
    /// Some part is older than its files, or missing.
    var stale = false
    var complete = true
}

/// Parts of the world by input stamp. A compute that started before another
/// one stored never overwrites it (a per-key generation), so an older read
/// cannot replace a newer one.
final class HerMemo: @unchecked Sendable {
    static let shared = HerMemo()
    private let lock = NSLock()
    private var store: [String: (stamp: [String], value: Any, generation: Int)] = [:]
    private var refreshing: Set<String> = []
    private var glances: [String: String?] = [:]
    private var glanceOrder: [String] = []

    func value<T>(_ key: String, stamp: [String], compute: () async -> T) async -> T {
        let (hit, generation): (T?, Int) = lock.withLock {
            (store[key].flatMap { $0.stamp == stamp ? $0.value as? T : nil }, store[key]?.generation ?? 0)
        }
        if let hit { return hit }
        let value = await compute()
        lock.withLock {
            if (store[key]?.generation ?? 0) == generation { store[key] = (stamp, value, generation + 1) }
        }
        return value
    }

    /// `value`, for a synchronous compute.
    func cached<T>(_ key: String, stamp: [String], compute: () -> T) -> T {
        let hit: T? = lock.withLock { store[key].flatMap { $0.stamp == stamp ? $0.value as? T : nil } }
        if let hit { return hit }
        let value = compute()
        lock.withLock { store[key] = (stamp, value, (store[key]?.generation ?? 0) + 1) }
        return value
    }

    /// Whatever is kept, and whether its stamp is still current.
    func peek<T>(_ key: String, stamp: [String]) -> (value: T, current: Bool)? {
        lock.withLock { store[key].flatMap { entry in (entry.value as? T).map { ($0, entry.stamp == stamp) } } }
    }

    func put(_ key: String, _ value: Any) {
        lock.withLock { store[key] = ([], value, (store[key]?.generation ?? 0) + 1) }
    }

    /// One inline glance read per data root at a time.
    func begin(_ root: String) -> Bool { lock.withLock { refreshing.insert(root).inserted } }
    func end(_ root: String) { lock.withLock { _ = refreshing.remove(root) } }

    /// The glance a turn already rendered, so every iteration of it is the same bytes.
    func glance(_ key: String) -> String?? { lock.withLock { glances[key] } }
    func keepGlance(_ key: String, _ text: String?) {
        lock.withLock {
            if glances.updateValue(text, forKey: key) == nil { glanceOrder.append(key) }
            if glanceOrder.count > 32 { glances.removeValue(forKey: glanceOrder.removeFirst()) }
        }
    }

    /// Read-merge-write of last_seen.json, one at a time.
    let seenLock = NSLock()

    /// The last full home each chat was shown (its rows, ages blanked) and
    /// when. The time it was shown whole when these rows match it within
    /// `within` seconds; otherwise these become the kept ones and nil.
    private var homes: [String: (rows: String, at: Double)] = [:]
    func shownHome(_ scope: String, rows: String, now: Double, within: Double) -> Double? {
        lock.withLock {
            if let last = homes[scope], last.rows == rows, now - last.at < within { return last.at }
            if homes.count > 64 { homes = [:] }
            homes[scope] = (rows, now)
            return nil
        }
    }
}

/// Resumes once: with the work's answer, or nil when the budget runs out first.
private final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
    func resume(_ value: T?) {
        let pending: CheckedContinuation<T?, Never>? = lock.withLock { defer { continuation = nil }; return continuation }
        pending?.resume(returning: value)
    }
}

extension HerScreen {
    /// A file's identity, size and modification time; "-" when absent.
    static func stamp(_ url: URL) -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return url.lastPathComponent + " -" }
        return "\(info.st_ino).\(info.st_size).\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    /// A folder and each entry in it (or `file` inside each entry).
    static func stamps(_ dir: URL, file: String? = nil) -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        return [stamp(dir)] + names.map { name in
            stamp(file.map { dir.appendingPathComponent(name).appendingPathComponent($0) } ?? dir.appendingPathComponent(name))
        }
    }

    /// How a read may reach the owners: `.fresh` (home, rooms) through their
    /// ordinary locked reads; `.unlocked` (the glance) recomputes only the
    /// parts whose files moved, read-only and without locks, and a read that
    /// fails keeps the last value; `.kept` never reads an owner at all.
    enum Reach { case fresh, unlocked, kept }

    static func readWorld(_ dataRoot: URL, now: Date = Date(), reach: Reach = .fresh) async -> HerWorld {
        let fresh = reach == .fresh, locked = reach == .fresh
        let root = dataRoot.standardizedFileURL.path + "\u{0}"
        func at(_ path: String) -> URL { dataRoot.appendingPathComponent(path) }
        let memo = HerMemo.shared
        var world = HerWorld()
        func part<T>(_ key: String, _ stamp: [String], _ compute: () async -> T?) async -> T? {
            if fresh { return await memo.value(root + key, stamp: stamp) { await compute() } ?? nil }
            let kept: (value: T?, current: Bool)? = memo.peek(root + key, stamp: stamp)
            if let kept, kept.current { return kept.value }
            if reach == .unlocked, let value = await compute() {
                return await memo.value(root + key, stamp: stamp) { value }
            }
            world.stale = true
            if kept == nil { world.complete = false }
            return kept?.value ?? nil
        }

        typealias People = (records: [AgentConversationRecord], chats: [BridgeChat], contacts: [Contact], answered: [String: Date])
        if let people: People = await part("people", [stamp(at("agents/peers.json")), stamp(at("agents/conversations.json")),
                stamp(at("chat/sessions.json"))] + stamps(at("agents/grok-requests")), {
            let store = AgentConversationStore(dataRoot: dataRoot)
            guard let all = try? (locked ? store.records() : store.recordsUnlocked()) else {
                if locked { return ([], [], [], [:]) }
                return nil
            }
            let records = all.filter { !$0.agent.hasPrefix("bot") }
            let chats = bridgeChats(dataRoot: dataRoot)
            return (records, chats, contacts(dataRoot: dataRoot, records: records, chats: chats), grokAnswers(dataRoot: dataRoot))
        }) {
            world.records = people.records; world.chats = people.chats; world.contacts = people.contacts; world.answered = people.answered
        }

        // Parking is by whole days, so the day is part of the desk's stamp.
        let day = String(Int(now.timeIntervalSince1970 / 86_400))
        if let desk: (DeskState?, DeskSplit) = await part("desk", [stamp(at("desk/desk_ops.jsonl")),
                stamp(at("desk/desk_ops_base.json")), day] + stamps(at("workshop/executions"), file: "execution.json"), {
            let store = SwiftNativeDeskStore(dataRoot: dataRoot)
            guard let state = try? await (locked ? store.liveState() : store.liveStateUnlocked()) else {
                if locked { return (nil, DeskSplit()) }
                return nil
            }
            return (state, await deskSplit(state, dataRoot: dataRoot, now: now))
        }) { (world.desk, world.split) = desk }

        if let bots: ([BotDefinition], [UUID: ShelfEntry]) = await part("bots",
                stamps(at("bots/definitions")) + [stamp(at("bots/shelf-index.json"))], {
            let definitions = BotDefinitionStore(dataRoot: dataRoot), shelf = ShelfStore(dataRoot: dataRoot)
            if locked {
                let bots = (try? definitions.list()) ?? []
                let entries = stride(from: 0, to: bots.count, by: 24).flatMap { start in
                    (try? shelf.latestEntries(botIDs: Set(bots[start..<min(start + 24, bots.count)].map(\.id)))) ?? []
                }
                return (bots, Dictionary(entries.map { ($0.botId, $0) }, uniquingKeysWith: { a, _ in a }))
            }
            guard let bots = try? definitions.listUnlocked(),
                  let entries = try? stride(from: 0, to: bots.count, by: 24).flatMap({ start in
                      try shelf.latestEntriesUnlocked(botIDs: Set(bots[start..<min(start + 24, bots.count)].map(\.id)))
                  }) else { return nil }
            return (bots, Dictionary(entries.map { ($0.botId, $0) }, uniquingKeysWith: { a, _ in a }))
        }) { (world.bots, world.latest) = bots }

        world.approvals = await part("approvals", [stamp(at("workflows/approvals/requests.json"))]) {
            let inbox = SwiftNativeApprovalInbox(root: dataRoot)
            let rows: [ApprovalRecord]? = locked ? ((try? await inbox.list(filter: .all)) ?? []) : (try? inbox.pendingUnlocked())
            guard let rows else { return nil }
            return rows.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status) }
                .sorted { ($0.lastRequestedAt ?? $0.createdAt) > ($1.lastRequestedAt ?? $1.createdAt) }
        } ?? []
        // Memory proposals for the owner's review, the Today page's rule, from
        // the shared store only; kept until the memory database changes.
        if SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot), let reviews: (count: Int, capped: Bool) = await part("reviews",
                [stamp(at("memory/memory.sqlite")), stamp(at("memory/memory.sqlite-wal"))], {
            guard let storage = try? await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot),
                  let pending = try? await storage.listProposals(status: "pending", limit: 100) else { return nil }
            return (pending.filter { SwiftNativeMemoryV2.awaitsReview(content: $0.content, source: $0.source, metadata: $0.metadata) }.count,
                    pending.count == 100)
        }) { world.reviews = reviews }
        let board: [[String: Any]] = await part("crews", [stamp(at("swarms/live.json"))]) { rows(at("swarms/live.json")) } ?? []
        world.crews = board.filter { row in
            guard let pid = row["pid"] as? Int else { return false }
            return kill(pid_t(pid), 0) == 0 || errno != ESRCH
        }
        // The run queue takes the helpers' store lock and moments are SQLite:
        // read fresh for home and rooms, the kept value for the glance.
        if reach != .kept {
            world.running = (try? BotRunQueue(dataRoot: dataRoot).activeOrQueuedIDs(locked: locked)) ?? []
            if SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot) {
                world.moments = await AdaptiveMemoryPromoter.shared.pendingMomentCount()
            }
            memo.put(root + "live", (world.running, world.moments))
        } else if let kept: ((Set<UUID>, Int), Bool) = memo.peek(root + "live", stamp: []) {
            (world.running, world.moments) = kept.0
            world.stale = true
        } else { world.complete = false; world.stale = true }
        return world
    }

    // MARK: - Since you looked

    /// One stable name's state. `line` says what changed when `fp` moves,
    /// `new` when the name first appears, `gone` when it leaves.
    struct Mark: Codable, Equatable {
        var fp: String
        var line: String
        var new: String = ""
        var gone: String = ""
        var at: Double
    }

    struct Seen: Codable { var at: Double; var marks: [String: Mark] }

    /// Full precision, so two updates in one second still differ.
    private static func fp(_ date: Date?) -> String { date.map { String($0.timeIntervalSince1970) } ?? "-" }

    /// Everything "since you looked" can speak about, by stable name. It does
    /// not depend on who is looking: bridge chats are marked per session
    /// (`chat:<id>`) by the other side's newest message, and the live chat is
    /// left out only when the changes are read (`changes(excluding:)`).
    static func worldMarks(_ world: HerWorld, dataRoot: URL, person: String, now: Date) -> [String: Mark] {
        var marks: [String: Mark] = [:]
        withNames(dataRoot) { book in
            for contact in world.contacts {
                let slug = book.slug(id: contact.id, name: contact.name)
                let record = latest(contact, records: world.records, contacts: world.contacts)
                let message: String? = if case .string(let id)? = record?.readInput?["message_id"] { id } else { nil }
                let answered = message.flatMap { world.answered[$0] }
                let bare = Contact(id: contact.id, name: contact.name, builtIn: contact.builtIn, kind: nil)
                let text = state(bare, record: record, chat: nil, answered: world.answered, now: now).text
                var line = ""
                // A live hand-off is her own send landing; its answer comes as a chat ("wrote").
                if text.hasPrefix("✓ delivered") {
                } else if text.hasPrefix("✓") {
                    line = slug + " replied"
                    if contact.builtIn, let record, let reply = replyText(unwrap(record.receipt)) ?? record.exchanges?.last?.reply {
                        line += " \"" + clip(firstLine(reply), 30) + "\""
                    }
                } else if text.hasPrefix("? asks") { line = slug + " asks for input" }
                else if text.hasPrefix("✗ sends failing") { line = slug + " send failed" }
                else if text.hasPrefix("✗ not sent") { line = slug + " not sent" }
                else if text.hasPrefix("✗") { line = slug + " did not reply" }
                else if text.hasPrefix("? send") { line = slug + " send unconfirmed" }
                marks[slug] = Mark(fp: [fp(record?.updatedAt), fp(answered), record?.phase ?? "-"].joined(separator: "|"),
                    line: line, at: ([record?.updatedAt, answered].compactMap { $0 }.max() ?? .distantPast).timeIntervalSince1970)
                // A chat she already answered is not news: she was there. (Every
                // bridge drive opens a new chat, so this said "claude replied"
                // on nearly every turn and sent her to look.)
                for chat in world.chats where chat.heard != nil && !chat.answered && (chat.who == contact.id || chat.who == contact.name.lowercased()) {
                    marks["chat:" + chat.id] = Mark(fp: fp(chat.heard), line: slug + " wrote", at: chat.heard!.timeIntervalSince1970)
                }
            }
            for bot in world.bots {
                let slug = book.slug(id: "bot:" + bot.id.uuidString, name: bot.name)
                let entry = world.latest[bot.id], running = world.running.contains(bot.id)
                var line = slug + " ran"
                if running { line = slug + " running" }
                else if let entry {
                    switch entry.runtimeStatus {
                    case .completed: line = slug + (entry.asked == true ? " answered" : " ran") + ": " + clip(entry.headline, 36)
                    case .failed, .interrupted: line = slug + " failed"
                    case .waitingForApproval, .waitingOnPerson: line = slug + " waiting on " + person
                    }
                }
                marks[slug] = Mark(fp: (entry?.id.uuidString ?? "-") + (running ? "|running" : ""), line: line,
                                   at: (running ? now : entry?.runAt ?? .distantPast).timeIntervalSince1970)
            }
            for row in world.crews {
                guard let id = row["id"] as? String else { continue }
                let name = "crew.\(book.number("crew", id: id) { Set(world.crews.compactMap { $0["id"] as? String }) })"
                let task = clip(firstLine(row["objective"] as? String ?? "A task"), 36)
                marks[name] = Mark(fp: "live", line: "", new: name + " started: " + task, gone: name + " finished: " + task,
                                   at: ((row["createdAt"] as? String).flatMap(date) ?? now).timeIntervalSince1970)
            }
        }
        if let desk = world.desk {
            for item in desk.items where item.parent == nil || OwnerAttentionPolicy.waitsOnOwner(item) {
                let name = "desk." + item.alias
                let label = OwnerAttentionPolicy.waitsOnOwner(item) ? "waiting on " + person
                    : item.status == .now ? "in progress" : item.status.displayLabel
                marks[name] = Mark(fp: label, line: name + " → " + label, new: name + " new: " + clip(item.title, 36),
                                   gone: name + " closed", at: (date(item.updatedAt) ?? now).timeIntervalSince1970)
            }
        }
        for approval in world.approvals {
            marks["approval:" + approval.id] = Mark(fp: "pending", line: "",
                new: "approval: " + clip(ApprovalWords.title(action: approval.action, title: approval.title, reason: approval.reason), 40),
                at: (date(approval.lastRequestedAt ?? approval.createdAt) ?? now).timeIntervalSince1970)
        }
        marks["moments"] = Mark(fp: String(world.moments), line: "", at: now.timeIntervalSince1970)
        return marks
    }

    /// What changed since the saved look, newest first. The chat she is in
    /// (`excluding`) is never news; moments speak only when more arrived.
    static func changes(since seen: Seen?, now marks: [String: Mark], excluding scope: String?) -> [String] {
        guard let seen else { return [] }
        var found: [(at: Double, line: String)] = []
        let live = scope.map { "chat:" + $0 }
        for (name, mark) in marks where name != live {
            guard let old = seen.marks[name] else {
                let new = name.hasPrefix("chat:") ? mark.line : mark.new
                if !new.isEmpty { found.append((mark.at, new)) }
                continue
            }
            if name == "moments" {
                if let was = Int(old.fp), let count = Int(mark.fp), count > was { found.append((mark.at, "moments +\(count - was)")) }
            } else if old.fp != mark.fp, !mark.line.isEmpty { found.append((mark.at, mark.line)) }
        }
        for (name, old) in seen.marks where marks[name] == nil && !old.gone.isEmpty { found.append((seen.at, old.gone)) }
        var lines: [String] = []
        for change in found.sorted(by: { $0.at > $1.at }) where !lines.contains(change.line) { lines.append(change.line) }
        return lines
    }

    private static func seenURL(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("her_screen/last_seen.json") }

    private static func readSeen(_ url: URL) -> Seen? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Seen.self, from: $0) }
    }

    static func lastSeen(_ dataRoot: URL) async -> Seen? {
        let url = seenURL(dataRoot)
        return await HerMemo.shared.value(dataRoot.standardizedFileURL.path + "\u{0}seen", stamp: [stamp(url)]) { readSeen(url) }
    }

    /// Her looking advances what she has seen: home all of it, a room only
    /// its own names (and only once home has set a baseline). One writer at
    /// a time: read, merge and write happen under one lock.
    static func markSeen(_ dataRoot: URL, marks: [String: Mark], only names: Set<String>? = nil, now: Date = Date()) {
        let url = seenURL(dataRoot)
        HerMemo.shared.seenLock.withLock {
            var seen: Seen
            if let names {
                guard var saved = readSeen(url) else { return }
                for name in names { saved.marks[name] = marks[name] }
                seen = saved
            } else { seen = Seen(at: now.timeIntervalSince1970, marks: marks) }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(seen).write(to: url, options: .atomic)
        }
    }

    /// A room's look: the names that room shows (a person's room includes
    /// their bridge chats).
    static func markRoomSeen(_ location: AgentWorkspaceLocation, dataRoot: URL, scope: String) async {
        let now = Date(), world = await readWorld(dataRoot, now: now)
        let marks = worldMarks(world, dataRoot: dataRoot, person: names(dataRoot).person, now: now)
        var names: Set<String> = []
        switch location {
        case .record("agent_read", let input, _):
            guard case .string(let agent)? = input["agent"] else { return }
            let id = agent.lowercased().hasPrefix("bot:") ? "bot:" + String(agent.dropFirst(4)).uppercased() : agent
            if let slug = withNames(dataRoot, { book in book.slugs.first { $0.value.id.caseInsensitiveCompare(id) == .orderedSame }?.key }) {
                names.insert(slug)
            }
            if let contact = world.contacts.first(where: { $0.id.caseInsensitiveCompare(agent) == .orderedSame }) {
                names.formUnion(world.chats.filter { $0.who == contact.id || $0.who == contact.name.lowercased() }.map { "chat:" + $0.id })
            }
        case .record("desk_read", let input, _):
            guard case .string(let handle)? = input["handle"],
                  let alias = world.desk?.items.first(where: { $0.handle == handle })?.alias else { return }
            names.insert("desk." + alias)
        case .record("chat_conversations", let input, _):
            guard case .string(let id)? = input["conversation_session_id"] else { return }
            names.insert("chat:" + id)
        case .area("ongoing"): names = Set(marks.keys.filter { $0.hasPrefix("desk.") })
        case .area("helpers"):
            names = withNames(dataRoot) { book in Set(world.bots.map { book.slug(id: "bot:" + $0.id.uuidString, name: $0.name) }) }
        case .people:
            names = withNames(dataRoot) { book in Set(world.contacts.map { book.slug(id: $0.id, name: $0.name) }) }
        default: return
        }
        markSeen(dataRoot, marks: marks, only: names, now: now)
    }

    // MARK: - The glance line

    /// Rides every turn in the dynamic segment: what changed since she last
    /// looked, and what needs her. Nil when neither.
    /// - Rendered once per turn (`turn` is the turn's pinned clock) and the
    ///   same string reused by every iteration of that turn.
    /// - Never blocks: kept values and stats only, under a 150 ms budget;
    ///   stale parts refresh in the background for a later turn.
    /// - Never advances what she has seen; never User's screen or activity data.
    static func glance(dataRoot: URL, scope: String?, turn: Date?) async -> String? {
        let key = (scope ?? "-") + "\u{0}" + (turn.map { String($0.timeIntervalSince1970) } ?? "-")
        if turn != nil, let kept = HerMemo.shared.glance(key) { return kept }
        let now = turn ?? Date()
        // Parts whose files moved are recomputed inline (read-only, no locks)
        // so the glance counts what home would. One such read per data root at
        // a time; past 150 ms the kept values speak and that read finishes in
        // the background for the next turn.
        let root = dataRoot.standardizedFileURL.path
        var text: String?
        if HerMemo.shared.begin(root) {
            let done: GlanceText? = await withCheckedContinuation { continuation in
                let once = OnceResume<GlanceText>(continuation)
                Task.detached(priority: .userInitiated) {
                    let said = await renderGlance(dataRoot: dataRoot, scope: scope, now: now, reach: .unlocked)
                    HerMemo.shared.end(root)
                    once.resume(GlanceText(text: said))
                }
                Task.detached { try? await Task.sleep(for: .milliseconds(150)); once.resume(nil) }
            }
            text = done?.text
            if done == nil { text = await renderGlance(dataRoot: dataRoot, scope: scope, now: now, reach: .kept) }
        } else { text = await renderGlance(dataRoot: dataRoot, scope: scope, now: now, reach: .kept) }
        if turn != nil { HerMemo.shared.keepGlance(key, text) }
        return text
    }

    private struct GlanceText: Sendable { let text: String? }

    static func renderGlance(dataRoot: URL, scope: String?, now: Date, reach: Reach) async -> String? {
        let world = await readWorld(dataRoot, now: now, reach: reach)
        guard world.complete else { return nil }
        let person = names(dataRoot).person
        let seen = await lastSeen(dataRoot)
        // Home's own names (presence, Chrome, badges, tabs) are not the glance's to speak.
        var marks = worldMarks(world, dataRoot: dataRoot, person: person, now: now)
        for (name, mark) in seen?.marks ?? [:] where name.hasPrefix("home:") { marks[name] = mark }
        let changed = changes(since: seen, now: marks, excluding: scope)
        // His to decide first, then hers: the same split as home.
        var waits: [String] = [], mine: [String] = []
        if let first = world.approvals.first {
            waits.append("approval \"" + clip(ApprovalWords.title(action: first.action, title: first.title, reason: first.reason), 28) + "\""
                + (world.approvals.count > 1 ? " +\(world.approvals.count - 1)" : ""))
        }
        if let desk = world.desk {
            let waiting = desk.items.filter(OwnerAttentionPolicy.waitsOnOwner).sorted { $0.updatedAt > $1.updatedAt }
            waits += waiting.prefix(2).map { "desk." + $0.alias } + (waiting.count > 2 ? ["+\(waiting.count - 2) desk"] : [])
        }
        if world.reviews.count > 0 { waits.append("memories \(world.reviews.count)\(world.reviews.capped ? "+" : "")") }
        if world.moments > 0 { mine.append("moments \(world.moments)") }
        withNames(dataRoot) { book in
            for contact in world.contacts where state(contact, record: latest(contact, records: world.records, contacts: world.contacts),
                                                      chat: nil, answered: world.answered, now: now).asks {
                mine.append(book.slug(id: contact.id, name: contact.name) + " asks")
            }
        }
        guard !changed.isEmpty || !waits.isEmpty || !mine.isEmpty else { return nil }
        var parts: [String] = []
        if let seen, !changed.isEmpty {
            let shown = changed.prefix(3).map { clip($0, 44) }
            parts.append("Since you looked (\(age(now.timeIntervalSince1970 - seen.at))): " + shown.joined(separator: " · ")
                + (changed.count > 3 ? " +\(changed.count - 3) more." : shown.last?.hasSuffix("…") == true ? "" : "."))
        }
        if !waits.isEmpty { parts.append(person + " waits on: " + waits.joined(separator: ", ") + ".") }
        if !mine.isEmpty { parts.append("Mine: " + mine.joined(separator: ", ") + ".") }
        return parts.joined(separator: " ") + " (workspace for home)"
    }
}

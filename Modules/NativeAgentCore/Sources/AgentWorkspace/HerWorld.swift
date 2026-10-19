import ApprovalInbox
import ChatSessionWork
import Foundation
import MemoryV2
import NotificationInbox
import PersistenceCore
import Desk
import StandingBots
import WorkshopExecution
import SwarmRuns
import NativeAgentShared

/// Home, rooms and the glance draw the same retained owner projections.
/// Owner invalidations refresh each part independently, outside page assembly.
struct HerWorld: @unchecked Sendable {
    var records: [AgentConversationRecord] = []
    /// Requested helper results already handed to her as a turn, by entry id.
    var handed: Set<String> = []
    var chats: [HerScreen.BridgeChat] = []
    var contacts: [HerScreen.Contact] = []
    var routes: [HerScreen.Contact] = []
    var threads: [String: HerScreen.BridgeChat] = [:]
    var jobs: [DelegationJobProjection] = []
    var doors: [HerScreen.DoorLine] = []
    var senses: [String] = []
    var identity = AgentContactIdentity(peers: [])
    var answered: [String: Date] = [:]
    var health: [String: AgentLocalHealth] = [:]
    var desk: DeskState?
    var split = HerScreen.DeskSplit()
    var bots: [BotDefinition] = []
    var latest: [UUID: ShelfEntry] = [:]
    var running: Set<UUID> = []
    var approvals: [ApprovalRecord] = []
    /// Shared live and retained crew projection; all identities keep their names.
    var crews: [[String: Any]] = []
    var moments = 0
    /// Memory proposals waiting for review: hers, not the owner's.
    var reviews: (count: Int, capped: Bool) = (0, false)
    /// Inbox cards asking the owner to choose (OwnerAttentionPolicy.inboxAsks);
    /// an approval's own card counts once, as the approval.
    var asks = 0
    var newestAsk: String?
    var phonePlaces: [PhonePlaceEvent] = []
    /// Arrivals no other home line names (a failed wake, a recovery).
    var arrivals: [ResidentWake.Item] = []
    /// Agents discovery found and offered, still unanswered: one PEOPLE line each.
    var found: [String] = []
    /// Parts with no value at all yet (never read), by key.
    var unread: [String] = []
    var pending: [String] = []
    var oldest: Date?

    func healthID(for contact: HerScreen.Contact, record: AgentConversationRecord?) -> String {
        let id = record?.agent ?? contact.id
        return health[id] == nil ? contact.id : id
    }
}

/// Parts of the world by input stamp. A compute that started before another
/// one stored never overwrites it (a per-key generation), so an older read
/// cannot replace a newer one.
final class HerMemo: @unchecked Sendable {
    static let shared = HerMemo()
    private let lock = NSLock()
    private var store: [String: (stamp: [String], value: Any, generation: Int, used: Date, at: Date)] = [:]
    private var generation = 0
    private var observations: [String: (id: UUID, revision: Int, task: Task<Void, Never>)] = [:]
    private var glances: [String: String?] = [:]
    private var glanceOrder: [String] = []

    /// Only the recent working window is retained, including transcript and send keys.
    private func prune(_ now: Date) {
        let previous = Set(store.keys)
        store = store.filter { now.timeIntervalSince($0.value.used) <= 1800 }
        while store.count > 128, let oldest = store.min(by: { $0.value.used < $1.value.used }) {
            store.removeValue(forKey: oldest.key)
        }
        for key in previous.subtracting(store.keys) { observations.removeValue(forKey: key)?.task.cancel() }
    }

    private func keep(_ key: String, stamp: [String], value: Any) {
        generation += 1
        let now = Date()
        store[key] = (stamp, value, generation, now, now)
        prune(now)
    }

    func value<T>(_ key: String, stamp: [String], compute: () async -> T) async -> T {
        let (hit, generation): (T?, Int) = lock.withLock {
            let now = Date()
            prune(now)
            store[key]?.used = now
            return (store[key].flatMap { $0.stamp == stamp ? $0.value as? T : nil }, store[key]?.generation ?? 0)
        }
        if let hit { return hit }
        let value = await compute()
        lock.withLock {
            if (store[key]?.generation ?? 0) == generation { keep(key, stamp: stamp, value: value) }
        }
        return value
    }

    /// `value`, for a synchronous compute.
    func cached<T>(_ key: String, stamp: [String], compute: () throws -> T) rethrows -> T {
        let hit: T? = lock.withLock {
            let now = Date()
            prune(now)
            store[key]?.used = now
            return store[key].flatMap { $0.stamp == stamp ? $0.value as? T : nil }
        }
        if let hit { return hit }
        let value = try compute()
        lock.withLock { keep(key, stamp: stamp, value: value) }
        return value
    }

    /// Whatever is kept, and whether its stamp is still current.
    func peek<T>(_ key: String, stamp: [String]? = nil) -> (value: T, current: Bool, at: Date)? {
        lock.withLock {
            let now = Date()
            prune(now)
            store[key]?.used = now
            let current = stamp ?? [String(observations[key]?.revision ?? 0)]
            return store[key].flatMap { entry in (entry.value as? T).map { ($0, entry.stamp == current, entry.at) } }
        }
    }

    func put(_ key: String, _ value: Any, stamp: [String] = []) {
        lock.withLock { keep(key, stamp: stamp, value: value) }
    }

    /// Owner events invalidate before reading; completions publish the retained picture.
    func observe<T>(_ key: String, paths: @escaping @Sendable () -> [URL], notifications: [Notification.Name],
                    compute: @escaping @Sendable () async -> T?) {
        let ports = AgentWorkspacePorts.current
        lock.withLock {
            prune(Date())
            store[key]?.used = Date()
            guard observations[key] == nil else { return }
            let id = UUID()
            let task = Task.detached(priority: .utility) { [self] in
                let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let invalidate: @Sendable () -> Void = { [self] in
                    lock.withLock { if observations[key]?.id == id { observations[key]?.revision += 1 } }
                    events.continuation.yield(())
                }
                let tokens = notifications.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in invalidate() }
                }
                defer { tokens.forEach(NotificationCenter.default.removeObserver); events.continuation.finish() }
                while !Task.isCancelled {
                    let watched = paths()
                    let watcher = FileChangeWatcher(paths: watched) { _ in invalidate() }
                    invalidate()
                    for await _ in events.stream {
                        guard paths() == watched else { break }
                        let revision = lock.withLock { observations[key]?.revision ?? 0 }
                        let value = await AgentWorkspacePorts.$binding.withValue(ports) { await compute() }
                        if let value, !Task.isCancelled {
                            lock.withLock {
                                if observations[key]?.id == id { keep(key, stamp: [String(revision)], value: value) }
                            }
                        }
                        if !Task.isCancelled { NotificationCenter.default.post(name: AgentWorkspaceScreenPreview.didChange, object: nil) }
                    }
                    watcher.cancel()
                }
            }
            observations[key] = (id, 0, task)
        }
    }

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

    static func readWorld(_ dataRoot: URL, now: Date = Date()) async -> HerWorld {
        let root = dataRoot.standardizedFileURL.path + "\u{0}"
        @Sendable func at(_ path: String) -> URL { dataRoot.appendingPathComponent(path) }
        @Sendable func files(_ dir: URL, file: String? = nil) -> [URL] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            return [dir] + names.map { name in
                file.map { dir.appendingPathComponent(name).appendingPathComponent($0) } ?? dir.appendingPathComponent(name)
            }
        }
        let memo = HerMemo.shared
        var world = HerWorld()
        func part<T>(_ key: String, _ paths: @autoclosure @escaping @Sendable () -> [URL], notifications: [Notification.Name] = [],
                     _ compute: @escaping @Sendable () async -> T?) -> T? {
            memo.observe(root + key, paths: paths, notifications: notifications, compute: compute)
            let kept: (value: T, current: Bool, at: Date)? = memo.peek(root + key)
            if let at = kept?.at { world.oldest = min(world.oldest ?? at, at) }
            if kept?.current != true { world.pending.append(key) }
            if kept == nil { world.unread.append(key) }
            return kept?.value
        }

        if let events: [PhonePlaceEvent] = part("phone places", [PhonePlaceHistory.url(dataRoot)], {
            try? PhonePlaceHistory.read(dataRoot)
        }) { world.phonePlaces = events }
        if let arrivals: [ResidentWake.Item] = part("arrivals", [ResidentWake.url(dataRoot)], {
            ResidentWake.homeItems(dataRoot)
        }) { world.arrivals = arrivals }
        if let found: [String] = part("found", [AgentDiscoveryOffer.url(dataRoot)], {
            (AgentDiscoveryOffer.read(dataRoot) ?? [:]).filter(\.value.open).map { AgentDiscoveryOffer.line(id: $0.key, name: $0.value.name) }.sorted()
        }) { world.found = found }

        typealias People = (records: [AgentConversationRecord], chats: [BridgeChat], answered: [String: Date],
                            handed: Set<String>)
        if let people: People = part("people", [at("agents/conversations.json"), at("chat/sessions.json")]
                + files(at("agents/grok-requests")), notifications: [.nativeAgentChatTranscriptDidChange], {
            guard let all = try? AgentWorkspacePorts.current.conversations.records(dataRoot: dataRoot, locked: false) else { return nil }
            let handed = Set(all.compactMap { row -> String? in
                guard row.agent.hasPrefix("bot-run:"), row.shownInline == row.operationID + ":" + row.phase,
                      case .string(let entry)? = row.readInput?["message_id"] else { return nil }
                return entry.uppercased()
            })
            let chats = bridgeChats(dataRoot: dataRoot)
            return (all, chats, grokAnswers(dataRoot: dataRoot), handed)
        }) {
            world.records = people.records; world.chats = people.chats; world.answered = people.answered
            world.handed = people.handed
        }
        let bridges = InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        if let people: (AgentContactIdentity, [Contact], [Contact], [String: BridgeChat]) = part("contacts", [at("agents/peers.json"), bridges,
                bridges.appendingPathComponent("codex-nativeagent-bridge"), bridges.appendingPathComponent("omp-bridge"),
                bridges.appendingPathComponent("claude-bridge"), bridges.appendingPathComponent("claude-bridge/bridge.json"),
                bridges.appendingPathComponent("claude-bridge/token"), at("chat/messages"), ContactReplyReads.url(dataRoot)],
                notifications: [.nativeAgentChatTranscriptDidChange], {
            let identity = AgentContactIdentity(dataRoot: dataRoot)
            let usable = AgentWorkspacePorts.current.tools.usableAgentLanes(dataRoot: dataRoot)
            let people = contacts(identity: identity, usable: usable)
            let threads = Dictionary(uniqueKeysWithValues: people.compactMap { contact in
                thread(contact, dataRoot: dataRoot, identity: identity).map { (contact.id, $0) }
            })
            return (identity, people, contacts(identity: identity, usable: usable, mergeIdentities: false), threads)
        }) {
            (world.identity, world.contacts, world.routes, world.threads) = people
        }
        let delegations = DelegationStatusProjector(configRoot: bridges, dataRoot: dataRoot)
        if let jobs: (jobs: [DelegationJobProjection], allStoresReadable: Bool) = part("delegations", delegations.watchedPaths, {
            delegations.allJobsWithAvailability(now: Date())
        }) {
            world.jobs = jobs.jobs
            if !jobs.allStoresReadable, !world.pending.contains("delegations") { world.pending.append("delegations") }
        }
        world.health = part("health", [AgentLocalHealth.url(dataRoot), at("agents/peers.json")]
                + [bridges.appendingPathComponent("claude-bridge/claude-live")], {
            AgentWorkspacePorts.current.conversations.liveHealth(dataRoot: dataRoot)
        }) ?? [:]

        // Parking is drawn from the owner's retained work and execution records.
        if let desk: (DeskState, Set<String>) = part("desk", [at("desk/desk_ops.jsonl"),
                at("desk/desk_ops_base.json")] + files(at("workshop/executions"), file: "execution.json"), {
            let store = SwiftNativeDeskStore(dataRoot: dataRoot)
            guard let state = try? await store.liveStateUnlocked() else { return nil }
            let live = Set(await SwiftNativeWorkshopRunner(root: dataRoot).listAll()
                .filter { DeskParking.executionIsLive(status: $0.status) }.compactMap(\.deskHandle))
            return (state, live)
        }) { world.desk = desk.0; world.split = deskSplit(desk.0, live: desk.1, now: now) }

        if let bots: ([BotDefinition], [UUID: ShelfEntry]) = part("bots",
                files(at("bots/definitions")) + [at("bots/shelf-index.json")], {
            let definitions = BotDefinitionStore(dataRoot: dataRoot), shelf = ShelfStore(dataRoot: dataRoot)
            guard let bots = try? definitions.listUnlocked(),
                  let entries = try? stride(from: 0, to: bots.count, by: 24).flatMap({ start in
                      try shelf.latestEntriesUnlocked(botIDs: Set(bots[start..<min(start + 24, bots.count)].map(\.id)))
                  }) else { return nil }
            return (bots, Dictionary(entries.map { ($0.botId, $0) }, uniquingKeysWith: { a, _ in a }))
        }) { (world.bots, world.latest) = bots }

        world.approvals = part("approvals", [at("workflows/approvals/requests.json")]) {
            let inbox = SwiftNativeApprovalInbox(root: dataRoot)
            guard let rows = try? inbox.pendingUnlocked() else { return nil }
            return rows.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status, agentOwned: $0.isAgentsOwnDecision) }
                .sorted { ($0.lastRequestedAt ?? $0.createdAt) > ($1.lastRequestedAt ?? $1.createdAt) }
        } ?? []
        // Memory proposals for the owner's review, the Today page's rule, from
        // the shared store only; kept until the memory database changes.
        if SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot), let reviews: (count: Int, capped: Bool) = part("reviews",
                [at("memory/memory.sqlite"), at("memory/memory.sqlite-wal")], {
            guard let storage = try? await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot),
                  let pending = try? await storage.listProposals(status: "pending", limit: 100) else { return nil }
            return (pending.filter { SwiftNativeMemoryV2.awaitsReview(content: $0.content, source: $0.source, metadata: $0.metadata) }.count,
                    pending.count == 100)
        }) { world.reviews = reviews }
        let inboxPath = LiveNotificationInbox.livePath(dataRoot: dataRoot)
        if let asks: (count: Int, newest: String?) = part("asks", [inboxPath], {
            let inbox = inboxPath == LiveNotificationInbox.livePath(dataRoot: PersistenceCore.defaultDataRoot()) ? LiveNotificationInbox.shared : LiveNotificationInbox(path: inboxPath)
            guard let rows = try? await inbox.rows() else { return nil }
            let asks = InboxItemRecord.latest(in: rows).filter { item in
                item.id != item.related_approval_id
                    && item.requiresOwnerInput
            }
            return (asks.count, asks.max { $0.created_at < $1.created_at }?.title)
        }) { world.asks = asks.count; world.newestAsk = asks.newest }
        if let crews: [[String: Any]] = part("crews", [at("swarms/live.json"), at("swarms/runs.json")], {
            try? SwiftNativeSwarmRunsReader(runsPath: at("swarms/runs.json")).readCrews(locked: false)
        }) { world.crews = crews }
        else if !world.unread.contains("crews") { world.unread.append("crews") }
        world.running = part("running helpers", [at("bots/run-queue.json")], notifications: [BotRunQueue.didChange]) {
            try? BotRunQueue(dataRoot: dataRoot).activeOrQueuedIDs(locked: false)
        } ?? []
        if SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot) {
            world.moments = part("moments", [at("memory/memory.sqlite"), at("memory/memory.sqlite-wal")]) {
                await AdaptiveMemoryPromoter.shared.pendingMomentCount()
            } ?? 0
        }
        world.doors = part("elsewhere", [at("chat/messages"), at("trust/policy.json")],
                notifications: [.nativeAgentChatTranscriptDidChange], {
            MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) ? doorLines(dataRoot: dataRoot, now: Date()) : []
        }) ?? []
        world.senses = part("senses", files(at("abilities")) + [at("senses/news/unread.json")]
                + files(at("senses"), file: "state.json") + files(at("tools"), file: "state.json")
                + files(at("skills"), file: "state.json"), {
            await sensesRows(dataRoot: dataRoot, now: Date())
        }) ?? []
        return world
    }

    static func freshness(_ world: HerWorld, now: Date = Date()) -> String {
        "Retained picture" + (world.oldest.map { "; oldest read " + age(now.timeIntervalSince($0)) + " ago" } ?? "; not read yet")
            + (world.pending.isEmpty ? "" : "; pending: " + world.pending.joined(separator: ", "))
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
    static func worldMarks(_ world: HerWorld, dataRoot: URL, person: String, now: Date, currentOnly: Bool = false) -> [String: Mark] {
        var marks: [String: Mark] = [:]
        func current(_ parts: String...) -> Bool { !currentOnly || parts.allSatisfy { !world.pending.contains($0) } }
        withNames(dataRoot) { book in
            for contact in world.contacts where current("contacts", "people") {
                let slug = book.slug(id: contact.id, name: contact.name)
                let record = latest(contact, records: world.records)
                let message: String? = if case .string(let id)? = record?.readInput?["message_id"] { id } else { nil }
                let answered = message.flatMap { world.answered[$0] }
                let bare = Contact(id: contact.id, name: contact.name, builtIn: contact.builtIn, kind: nil)
                let text = state(bare, record: record, chat: nil, answered: world.answered, now: now).text
                var line = ""
                // A live hand-off is her own send landing; its answer comes as a chat ("wrote").
                // Already in her hands (her call's result, or the turn that
                // brought it): not news again.
                if let record, record.shownInline == record.operationID + ":" + record.phase {
                } else if text.hasPrefix("✓ delivered") {
                } else if text.hasPrefix("✓") {
                    line = slug + " replied"
                } else if text.hasPrefix("? asks") { line = slug + " asks for input" }
                else if text.hasPrefix("✗ sends failing") { line = slug + " send failed" }
                else if text.hasPrefix("✗ not sent") { line = slug + " not sent" }
                else if text.hasPrefix("✗") { line = slug + " did not reply" }
                else if text.hasPrefix("? send") { line = slug + " send unconfirmed" }
                marks[slug] = Mark(fp: [fp(record?.updatedAt), fp(answered), record?.phase ?? "-"].joined(separator: "|"),
                    line: line, at: ([record?.updatedAt, answered].compactMap { $0 }.max() ?? .distantPast).timeIntervalSince1970)
                for id in Set([contact.id] + contact.agents) {
                    if let health = world.health[id], health.current, current("health") {
                        marks["health:" + id] = Mark(fp: health.status + ":" + health.detail,
                            line: health.problem.map { slug + ": " + $0 } ?? "", at: health.checkedAt.timeIntervalSince1970)
                    }
                }
                // A chat she already answered is not news: she was there. (Every
                // bridge drive opens a new chat, so this said "claude replied"
                // on nearly every turn and sent her to look.)
                for chat in world.chats where chat.heard != nil && !chat.answered && (chat.who == contact.id || chat.who == contact.name.lowercased()) {
                    marks["chat:" + chat.id] = Mark(fp: fp(chat.heard), line: slug + " wrote", at: chat.heard!.timeIntervalSince1970)
                }
            }
            for bot in world.bots where current("bots", "running helpers", "people") {
                let slug = book.slug(id: "bot:" + bot.id.uuidString, name: bot.name)
                let entry = world.latest[bot.id], running = world.running.contains(bot.id)
                var line = slug + " ran"
                if running { line = slug + " running" }
                else if let entry, world.handed.contains(entry.id.uuidString) { line = "" }
                else if let entry {
                    switch entry.runtimeStatus {
                    case .completed: line = slug + (entry.asked == true ? " answered" : " ran") + ": " + clip(entry.headline, 36)
                    case .failed, .interrupted: line = slug + " failed"
                    case .waitingForApproval, .waitingOnPerson: line = slug + " waiting on " + person
                    }
                }
                marks[slug] = Mark(fp: [entry?.id.uuidString ?? "-", entry?.runtimeStatus.rawValue ?? "-",
                                      entry?.statusDetail ?? "-", entry?.approvalID ?? "-", running ? "running" : "idle"].joined(separator: "|"), line: line,
                                   at: (running ? now : entry?.runAt ?? .distantPast).timeIntervalSince1970)
            }
            for row in world.crews where row["pid"] != nil && current("crews") {
                guard let id = row["id"] as? String else { continue }
                let name = "crew.\(book.number("crew", id: id) { Set(world.crews.compactMap { $0["id"] as? String }) })"
                let task = clip(firstLine(row["objective"] as? String ?? "A task"), 36)
                marks[name] = Mark(fp: "live", line: "", new: name + " started: " + task, gone: name + " finished: " + task,
                                   at: ((row["createdAt"] as? String).flatMap(date) ?? now).timeIntervalSince1970)
            }
        }
        if let desk = world.desk, current("desk") {
            for item in desk.items where item.parent == nil || OwnerAttentionPolicy.waitsOnOwner(item) {
                let name = "desk." + item.alias
                let label = OwnerAttentionPolicy.waitsOnOwner(item) ? "waiting on " + person
                    : item.status == .now ? "in progress" : item.status.displayLabel
                marks[name] = Mark(fp: label, line: name + " → " + label, new: name + " new: " + clip(item.title, 36),
                                   gone: name + " closed", at: (date(item.updatedAt) ?? now).timeIntervalSince1970)
            }
        }
        for approval in world.approvals where current("approvals") {
            marks["approval:" + approval.id] = Mark(fp: "pending", line: "",
                new: "approval: " + clip(ApprovalWords.title(action: approval.action, title: approval.title, reason: approval.reason), 40),
                at: (date(approval.lastRequestedAt ?? approval.createdAt) ?? now).timeIntervalSince1970)
        }
        let placeClock = DateFormatter()
        placeClock.locale = Locale(identifier: "en_US_POSIX")
        placeClock.dateFormat = "HH:mm"
        for event in world.phonePlaces where current("phone places") {
            let prefix = "Phone " + event.transition.rawValue + " "
            let when = " (" + placeClock.string(from: event.timestamp) + ", " + age(now.timeIntervalSince(event.timestamp)) + " ago)"
            // Keep the observation time inside the glance's 44-character line budget.
            let place = clip(String(reflecting: event.name), max(1, 44 - prefix.count - when.count))
            let line = prefix + place + when
            marks["phone-place:" + event.id] = Mark(fp: event.id, line: line, new: line,
                at: event.timestamp.timeIntervalSince1970)
        }
        for item in world.arrivals where current("arrivals") {
            marks["arrival:" + item.id] = Mark(fp: item.id, line: "", new: item.renderedLine, at: item.at.timeIntervalSince1970)
        }
        if current("moments") { marks["moments"] = Mark(fp: String(world.moments), line: "", at: now.timeIntervalSince1970) }
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
    static func markRoomSeen(_ location: AgentWorkspaceLocation, dataRoot: URL, scope: String,
                             observation: (world: HerWorld, at: Date, health: Set<String>)? = nil) async {
        if observation == nil, case .record("agent_read", let input, _) = location,
           case .string(let agent)? = input["agent"] {
            guard agent.lowercased().hasPrefix("bot:"),
                  UUID(uuidString: String(agent.dropFirst(4))) != nil else { return }
        }
        let now = observation?.at ?? Date()
        let world: HerWorld
        if let observation { world = observation.world }
        else { world = await readWorld(dataRoot, now: now) }
        let marks = worldMarks(world, dataRoot: dataRoot, person: names(dataRoot).person, now: now, currentOnly: true)
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
        names.formUnion((observation?.health ?? []).map { "health:" + $0 })
        markSeen(dataRoot, marks: marks, only: names.intersection(marks.keys), now: now)
    }

    // MARK: - The glance line

    /// Rides every turn in the dynamic segment: what changed since she last
    /// looked, what needs her, and her live built/recent abilities.
    /// - Home changes stay pinned to the turn; ability names are read from
    ///   their owners at assembly, outside that memo.
    /// - Never advances what she has seen; never User's screen or activity data.
    package static func glance(dataRoot: URL, scope: String?, turn: Date?, includingMoments: Bool = true) async -> String? {
        async let abilities = AgentWorkspacePorts.current.tools.builtAbilities(dataRoot: dataRoot, now: turn ?? Date())
        let home = await homeGlance(dataRoot: dataRoot, scope: scope, turn: turn, includingMoments: includingMoments)
        return await [home, abilities].compactMap { $0 }.joined(separator: "\n")
    }

    private static func homeGlance(dataRoot: URL, scope: String?, turn: Date?, includingMoments: Bool) async -> String? {
        let key = (scope ?? "-") + "\u{0}" + (turn.map { String($0.timeIntervalSince1970) } ?? "-")
            + "\u{0}" + String(includingMoments)
        if turn != nil, let kept = HerMemo.shared.glance(key) { return kept }
        let now = turn ?? Date()
        let text = await renderGlance(dataRoot: dataRoot, scope: scope, now: now, includingMoments: includingMoments)
        if turn != nil { HerMemo.shared.keepGlance(key, text) }
        return text
    }

    static func renderGlance(dataRoot: URL, scope: String?, now: Date, includingMoments: Bool = true) async -> String? {
        let world = await readWorld(dataRoot, now: now)
        let person = names(dataRoot).person
        let seen = await lastSeen(dataRoot)
        // Home's own names (presence, Chrome, badges, tabs) are not the glance's to speak.
        var marks = worldMarks(world, dataRoot: dataRoot, person: person, now: now)
        for (name, mark) in seen?.marks ?? [:] where name.hasPrefix("home:") { marks[name] = mark }
        // A part not read yet is named, never silently dropped (09-26: the
        // whole line vanished, which she reads as nothing new). Its names keep
        // their last-seen state, so an unread part reads as unchanged, not gone.
        // Only the desk and crews say "gone"; a helper's running state is the live part's.
        if !world.unread.isEmpty, let seen {
            let helpers = world.unread.contains("running helpers")
                ? withNames(dataRoot) { book in Set(world.bots.map { book.slug(id: "bot:" + $0.id.uuidString, name: $0.name) }) } : []
            for (name, mark) in seen.marks where helpers.contains(name)
                || marks[name] == nil && (world.unread.contains("desk") && name.hasPrefix("desk.")
                    || world.unread.contains("crews") && name.hasPrefix("crew.")) { marks[name] = mark }
        }
        let changed = changes(since: seen, now: marks, excluding: scope)
        // His to decide first, then hers: the same split as home.
        var waits: [String] = [], mine: [String] = []
        if let first = world.approvals.first {
            waits.append("approval \"" + clip(ApprovalWords.title(action: first.action, title: first.title, reason: first.reason), 28) + "\""
                + (world.approvals.count > 1 ? " +\(world.approvals.count - 1)" : ""))
        }
        if let desk = world.desk {
            let waiting = desk.items.filter(OwnerAttentionPolicy.waitsOnOwner).sorted { $0.updatedAt > $1.updatedAt }
            waits += waiting.prefix(2).map { "desk." + $0.alias + " — " + clip($0.title, 28) }
                + (waiting.count > 2 ? ["+\(waiting.count - 2) desk"] : [])
        }
        if world.asks > 0 { waits.append("inbox \(world.asks)" + (world.newestAsk.map { " — " + clip($0, 44) } ?? "")) }
        if includingMoments, world.moments > 0 { mine.append("moments \(world.moments)") }
        if world.reviews.count > 0 { mine.append("memories \(world.reviews.count)\(world.reviews.capped ? "+" : "")") }
        withNames(dataRoot) { book in
            for contact in world.contacts where state(contact, record: latest(contact, records: world.records),
                                                      chat: nil, answered: world.answered, now: now).asks {
                mine.append(book.slug(id: contact.id, name: contact.name) + " asks")
            }
        }
        let words = ["people": "people", "desk": "desk", "bots": "helpers", "approvals": "approvals",
                     "reviews": "memories to review", "crews": "crews"]
        let unread = world.unread.map { words[$0] ?? $0 }
        guard !changed.isEmpty || !waits.isEmpty || !mine.isEmpty || !unread.isEmpty else { return nil }
        var parts = ["Home glance — snapshot as of \(now.formatted(.iso8601)). \(freshness(world, now: now)). Desk, inbox, approvals, exchanges, helper/crew status, phone-place/wake records and reviews; no live calendar, reminders, mail, front app, full Doctor check or complete activity log."]
        if let seen, !changed.isEmpty {
            let shown = changed.prefix(3).map { clip($0, 44) }
            parts.append("Since you looked (\(age(now.timeIntervalSince1970 - seen.at))): " + shown.joined(separator: " · ")
                + (changed.count > 3 ? " +\(changed.count - 3) more." : shown.last?.hasSuffix("…") == true ? "" : "."))
        }
        if !waits.isEmpty { parts.append(person + " waits on: " + waits.joined(separator: ", ") + ".") }
        if !mine.isEmpty { parts.append("Mine: " + mine.joined(separator: ", ") + ".") }
        if !unread.isEmpty { parts.append("Not read yet: " + unread.joined(separator: ", ") + ", so there may be news there.") }
        return parts.joined(separator: " ") + " (app {} for home)"
    }
}

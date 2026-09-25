import SwiftUI
import NativeAgentCore
import ChatOrchestration
import PersistenceCore
import StandingBots
import os

// Simple view's window: one floating glass sidebar (the rail's plate) and the
// agent's ordinary chat, a contact's or helper's thread, or a crew's work beside it.
// Reads the stores the rest of the app already keeps; writes nothing.

/// A contact, keyed the way the agent's conversation records key it:
/// `peer:<id>` for a saved contact, `codex` / `claude` / `omp` for a
/// built-in lane.
struct SimpleContact: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let builtIn: Bool
    /// How the agent reaches it, in a line.
    let via: String
    /// The Mac app behind it, when there is one, for its avatar.
    var appBundleID: String? = nil
    /// How it is connected, when two contacts share one app ("Grok" the
    /// desktop app and "Grok Bot" the routine).
    var link: Link? = nil
    /// Its initials tint: a palette slot three on from the row above (SimpleAvatar).
    var tintSlot: Int? = nil
    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    enum Link: Equatable, Sendable {
        case desktopApp, routine
        var words: String { self == .desktopApp ? "Desktop app" : "Routine · replies come back" }
    }
}

/// One thing said between the agent and a contact.
struct SimpleThreadLine: Identifiable, Equatable, Sendable {
    let id: String
    let fromAgent: Bool
    let text: String
    let at: Date
    /// Typed by the person in this thread rather than sent by the agent.
    var byPerson = false
}

/// A crew the agent sent out (`agent_swarm`): a few workers on one task, for
/// as long as it runs, then its finished receipt. Read straight from the two
/// files the executor writes (SwarmRuns is not linked into the app).
struct SimpleCrew: Identifiable, Equatable, Sendable {
    let id: String
    /// The task, in its first line.
    let task: String
    /// Still working (swarms/live.json); otherwise finished (swarms/runs.json).
    let live: Bool
    /// The run's own status word: running, completed, partial, failed, cancelled.
    let status: String
    let at: Date
    let workers: [Worker]
    /// The workers' findings pulled together, when the run asked for it.
    let synthesis: String?

    struct Worker: Identifiable, Equatable, Sendable {
        let id: Int
        let name: String
        /// working, completed, failed, cancelled.
        let status: String
        let text: String
    }

    var settled: Bool { workers.allSatisfy { $0.status != "working" } }

    /// Crews at work now, newest first, then the three most recently finished.
    nonisolated static func read(root: URL) -> [SimpleCrew] {
        func rows(_ path: String) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(path)) else { return [] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        }
        let finished = rows("swarms/runs.json").compactMap { crew($0, live: false) }
        let done = Set(finished.map(\.id))
        // A crew whose process ended mid-run never finishes; it is not working.
        let live = rows("swarms/live.json").filter { row in
            guard let pid = row["pid"] as? Int else { return false }
            return kill(pid_t(pid), 0) == 0 || errno != ESRCH
        }.compactMap { crew($0, live: true) }.filter { !done.contains($0.id) }
        return live.sorted { $0.at > $1.at } + finished.sorted { $0.at > $1.at }.prefix(3)
    }

    nonisolated private static func crew(_ row: [String: Any], live: Bool) -> SimpleCrew? {
        guard let id = row["id"] as? String, let objective = row["objective"] as? String else { return nil }
        let dates = ISO8601DateFormatter(), whole = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let at = (row["completedAt"] as? String ?? row["createdAt"] as? String)
            .flatMap { dates.date(from: $0) ?? whole.date(from: $0) } ?? .distantPast
        let workers = (row["workers"] as? [[String: Any]] ?? []).enumerated().map { index, worker in
            let role = (worker["role"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? worker["name"] as? String ?? "Worker \(index + 1)"
            let output = (worker["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Worker(id: index, name: role.prefix(1).uppercased() + role.dropFirst(),
                          status: worker["status"] as? String ?? "working",
                          text: output.isEmpty ? worker["error"] as? String ?? "" : output)
        }
        let synthesis = ((row["synthesis"] as? [String: Any])?["output"] as? String ?? row["synthesis"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let task = String(SimpleViewStore.firstLine(objective).prefix(120))
        return SimpleCrew(id: id, task: task.isEmpty ? "A task" : task, live: live,
                          status: row["status"] as? String ?? "running", at: at, workers: workers, synthesis: synthesis)
    }
}

@MainActor @Observable
final class SimpleViewStore {
    /// Most recent exchange first; contacts never talked to keep their order
    /// after them.
    var contacts: [SimpleContact] = []
    /// Per contact id, oldest first.
    var lines: [String: [SimpleThreadLine]] = [:]
    /// Contacts with a message still on its way or awaiting a reply.
    var waiting: Set<String> = []
    /// Contacts whose latest message ended with no reply coming back.
    var unanswered: Set<String> = []
    var helpers: [BotsShelfRecord] = []
    /// False until the first read lands, so an empty list isn't claimed early.
    var loaded = false
    /// Helpers with a run queued or under way now.
    var running: Set<UUID> = []
    /// Crews at work now, then the few most recently finished.
    var crews: [SimpleCrew] = []

    private struct Snapshot: Sendable {
        var contacts: [SimpleContact]
        var lines: [String: [SimpleThreadLine]]
        var waiting: Set<String>
        var unanswered: Set<String>
        var helpers: [BotsShelfRecord]
        var running: Set<UUID>
    }

    /// What a read changed, worked out off the main actor; nil is unchanged.
    private struct Delta: Sendable {
        var contacts: [SimpleContact]?
        var lines: [String: [SimpleThreadLine]]?
        var waiting: Set<String>?
        var unanswered: Set<String>?
        var helpers: [BotsShelfRecord]?
        var running: Set<UUID>?
    }

    nonisolated private static func changes(from old: Snapshot, to new: Snapshot) -> Delta? {
        let delta = Delta(contacts: old.contacts == new.contacts ? nil : new.contacts,
                          lines: old.lines == new.lines ? nil : new.lines,
                          waiting: old.waiting == new.waiting ? nil : new.waiting,
                          unanswered: old.unanswered == new.unanswered ? nil : new.unanswered,
                          helpers: old.helpers == new.helpers ? nil : new.helpers,
                          running: old.running == new.running ? nil : new.running)
        let unchanged = delta.contacts == nil && delta.lines == nil && delta.waiting == nil
            && delta.unanswered == nil && delta.helpers == nil && delta.running == nil
        return unchanged ? nil : delta
    }

    /// The reachable contacts with their icons and tints, kept until what
    /// they are made of can have changed: peers.json, the usable built-in
    /// lanes, or an approved ACP program (each check re-hashes the program
    /// and reads Keychain, so it is not redone on every message).
    private struct ContactList: Sendable {
        var stamp: [String]
        var programs: [String]
        var contacts: [SimpleContact]
    }

    /// A file's identity, size, times and mode; any change re-checks.
    nonisolated private static func stamp(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return path + " -" }
        return "\(path) \(info.st_ino) \(info.st_size) \(info.st_mode) "
            + "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    /// A helper's conversation key in `lines` / `waiting`: how the agent
    /// messages it (`agent_message` to `bot:<id>`).
    nonisolated static func key(_ helper: UUID) -> String { "bot:" + helper.uuidString }

    /// Reload whenever the contact list, the conversation records, a Grok Bot
    /// answer or the helpers' shelf change on disk, a helper's run takes its
    /// claim (`run.lock`), or one ends (in memory, so the queue says so).
    func watch(root: URL, helpers ids: [UUID]) async {
        let paths = ["agents/peers.json", "agents/conversations.json", "agents/grok-requests", "bots/definitions",
                     "bots/shelf-index.json", "bots/run-queue.json"] + ids.map { "bots/\($0.uuidString)/run.lock" }
        let events = FileChangeEvents(paths: paths.map { root.appendingPathComponent($0) }, emitInitial: true)
        let (ticks, tick) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // Set by every change, cleared just before a read: a tick buffered
        // while that read's burst settled finds it clear and is skipped.
        let pending = OSAllocatedUnfairLock(initialState: false)
        let files = Task { for await _ in events.stream { pending.withLock { $0 = true }; tick.yield() } }
        let ended = NotificationCenter.default.addObserver(forName: BotRunQueue.didChange, object: nil, queue: nil) { _ in
            pending.withLock { $0 = true }
            tick.yield()
        }
        var last = Snapshot(contacts: contacts, lines: lines, waiting: waiting, unanswered: unanswered,
                            helpers: helpers, running: running)
        var list: ContactList?
        await withTaskCancellationHandler {
            for await _ in ticks {
                guard !Task.isCancelled else { break }
                guard pending.withLock({ $0 }) else { continue }
                // One message writes several files; let the burst land first.
                if loaded { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled else { break }
                pending.withLock { $0 = false }
                let (next, contactList, delta) = await Task.detached(priority: .userInitiated) { [last, list] in
                    let (next, contactList) = Self.read(root: root, cached: list)
                    return (next, contactList, Self.changes(from: last, to: next))
                }.value
                last = next
                list = contactList
                if let delta {
                    if let value = delta.contacts { contacts = value }
                    if let value = delta.lines { lines = value }
                    if let value = delta.waiting { waiting = value }
                    if let value = delta.unanswered { unanswered = value }
                    if let value = delta.helpers { helpers = value }
                    if let value = delta.running { running = value }
                }
                if !loaded { loaded = true }
            }
        } onCancel: { events.cancel(); tick.finish() }
        files.cancel()
        NotificationCenter.default.removeObserver(ended)
    }

    /// Crews on their own watch: runs.json keeps every finished run whole, so
    /// it is read only when a crew changes, never on a contact's message.
    func watchCrews(root: URL) async {
        let paths = ["swarms/live.json", "swarms/runs.json"].map { root.appendingPathComponent($0) }
        // The watcher arms on the folder, so the first crew is seen even
        // before one has ever run. An empty folder; nothing else is written.
        try? FileManager.default.createDirectory(at: paths[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        let events = FileChangeEvents(paths: paths, emitInitial: true)
        await withTaskCancellationHandler {
            for await _ in events.stream {
                guard !Task.isCancelled else { break }
                let next = await Task.detached(priority: .utility) { SimpleCrew.read(root: root) }.value
                if crews != next { crews = next }
            }
        } onCancel: { events.cancel() }
    }

    /// The contact's own app when it is on this Mac: its desktop address, else
    /// its known-agent row. None for a routine, so Grok Bot does not wear the
    /// icon of the Grok desktop app it runs through.
    nonisolated private static func appBundleID(_ row: AgentContactRow) -> String? {
        guard row.contact?.transport != .grokBot else { return nil }
        let host = row.builtIn ? String(row.id.dropFirst("builtin:".count))
            : row.contact.flatMap { AgentPeerStore.hostRowID($0.endpoint) } ?? row.id
        let bundle = row.contact.flatMap { AgentPeerStore.desktopBundleID($0.endpoint) }
            ?? AgentHostDirectory.rows.first { $0.id == host }?.bundleIDs.first
        return bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil ? nil : $0 }
    }

    /// Listed only while the agent can reach it now: connected, set up to
    /// take a message, or a desktop app it can send to. One that drops out
    /// keeps its records and comes back once it is reachable again.
    nonisolated private static func reachable(_ row: AgentContactRow) -> Bool {
        guard let contact = row.contact else { return true }
        // Cheapest first: `state` reads Keychain and, like `canStartTurn`,
        // re-hashes an ACP program.
        return contact.unavailableAt == nil && contact.canStartTurn && [.connected, .setUp, .sendOnly].contains(row.state)
    }

    nonisolated private static func contactList(root: URL, cached: ContactList?) -> ContactList {
        let peersFile = root.appendingPathComponent("agents/peers.json").path
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
        let usable = Set(["codex", "claude", "omp"].filter { dispatcher.builtInAgentLaneUsable($0) })
        let head = [stamp(peersFile), usable.sorted().joined(separator: ",")]
        if let cached, cached.stamp == head + cached.programs.map(stamp) { return cached }
        // The same contact list the Agents page shows, minus apps that are
        // merely installed: saved contacts, then the usable built-in lanes.
        let peers = (try? AgentPeerStore(dataRoot: root).list()) ?? []
        let programs = peers.filter { $0.transport == .acp }.compactMap { $0.approvedACPExecutable?.path }
        // Stamped before the checks, so a change during them re-checks next time.
        let stamps = head + programs.map(stamp)
        var contacts = AgentContactRow.rows(peers: peers, candidates: [], usable: usable).filter(reachable).map { row in
            SimpleContact(id: row.builtIn ? String(row.id.dropFirst("builtin:".count)) : row.id,
                          name: row.name, builtIn: row.builtIn, via: via(row), appBundleID: appBundleID(row),
                          link: link(row))
        }
        // A tint is who a contact is, so it follows the contact, not its row:
        // in stable id order each initials avatar sits three hues of the eight
        // on from the one before, so up to eight never share a tint and a new
        // message never recolours anyone.
        let tinted = contacts.indices.filter { contacts[$0].appBundleID == nil }.sorted { contacts[$0].id < contacts[$1].id }
        for (step, index) in tinted.enumerated() {
            contacts[index].tintSlot = step * 3 % SimpleAvatar.slotCount
        }
        return ContactList(stamp: stamps, programs: programs, contacts: contacts)
    }

    nonisolated private static func read(root: URL, cached: ContactList?) -> (Snapshot, ContactList) {
        let list = contactList(root: root, cached: cached)
        let contacts = list.contacts
        let ids = Set(contacts.map(\.id))
        // A contact removed and connected again gets a new id while its
        // earlier records keep the old one; they still carry its name. "Grok"
        // and "Grok Bot" are two names, so each keeps its own replies.
        func owner(_ agent: String, name: String) -> String? {
            if ids.contains(agent) { return agent }
            // A helper's thread, keyed by the helper whatever case its id came in.
            if agent.hasPrefix("bot:") { return UUID(uuidString: String(agent.dropFirst(4))).map(key) }
            guard agent.hasPrefix("peer:") else { return nil }
            return contacts.first { !$0.builtIn && $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        }
        /// Peer uuid → contact id, old ids included.
        var alias: [String: String] = [:]
        for contact in contacts where contact.id.hasPrefix("peer:") { alias[String(contact.id.dropFirst(5))] = contact.id }

        let requests = grokRequests(root: root)
        let records = (try? AgentConversationStore(dataRoot: root).records()) ?? []
        var lines: [String: [SimpleThreadLine]] = [:]
        var replies: [String: [SimpleThreadLine]] = [:]
        var latest: [String: AgentConversationRecord] = [:]
        var lastActive: [String: Date] = [:]
        var sessions: [String: Set<String>] = [:]
        for record in records {
            guard let id = owner(record.agent, name: record.name) else { continue }
            if record.agent.hasPrefix("peer:") { alias[String(record.agent.dropFirst(5))] = id }
            // A helper answers in its receipt, never over the bridge.
            if !id.hasPrefix("bot:") {
                sessions[id, default: []].insert(record.scopeSessionID)
                if let conversation = record.conversationID { sessions[id, default: []].insert(conversation) }
            }
            lastActive[id] = max(lastActive[id] ?? .distantPast, record.updatedAt)
            if record.updatedAt >= (latest[id]?.updatedAt ?? .distantPast) { latest[id] = record }
            let history = record.exchanges ?? []
            for exchange in history {
                if let prompt = exchange.prompt, !prompt.isEmpty {
                    lines[id, default: []].append(.init(id: exchange.id + ":sent", fromAgent: true,
                        text: prompt, at: exchange.sentAt, byPerson: exchange.byPerson == true))
                }
                // The newest exchange's answer sits in the record's receipt
                // until the next send folds it into the history.
                var reply = exchange.reply
                if reply == nil, exchange.id == record.operationID, record.phase != "sending" {
                    reply = receiptReply(record.receipt)
                }
                if let reply, !reply.isEmpty {
                    replies[id, default: []].append(.init(id: exchange.id + ":reply", fromAgent: false,
                        text: reply, at: exchange.sentAt.addingTimeInterval(0.001)))
                }
            }
            if history.isEmpty, let reply = receiptReply(record.receipt) {
                replies[id, default: []].append(.init(id: record.id + ":reply", fromAgent: false,
                    text: reply, at: record.updatedAt))
            }
        }
        for request in requests {
            if let id = alias[request.peer] { sessions[id, default: []].insert(request.conversation) }
        }
        // Answers that came back as their own turn in the agent's chat (Grok
        // Bot's, and any peer's bridged answer), from the sessions where the
        // agent talked to that contact.
        for (id, line) in bridgedTurns(root: root, sessions: sessions, alias: alias) {
            lines[id, default: []].append(line)
        }
        // A receipt can keep a copy of a bridged answer; show it once.
        for (id, said) in replies {
            let heard = Set((lines[id] ?? []).filter { !$0.fromAgent }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
            lines[id, default: []] += said.filter { !heard.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        for key in lines.keys {
            lines[key]?.sort { $0.at < $1.at }
            if let last = lines[key]?.last { lastActive[key] = max(lastActive[key] ?? .distantPast, last.at) }
        }

        let answered = Set(requests.filter { $0.state == "answered" }.map(\.message))
        var waiting: Set<String> = []
        var unanswered: Set<String> = []
        for (id, record) in latest {
            let message: String? = if case .string(let value)? = record.readInput?["message_id"] { value } else { nil }
            if ["sending", "waiting"].contains(record.phase), !(message.map(answered.contains) ?? false) {
                waiting.insert(id)
            } else if record.phase == "attention", lines[id]?.last?.fromAgent ?? true {
                unanswered.insert(id)
            }
        }
        let ordered = contacts.enumerated().sorted { a, b in
            switch (lastActive[a.element.id], lastActive[b.element.id]) {
            case let (x?, y?): return x != y ? x > y : a.offset < b.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
        let helpers = (try? BotsShelfView.readRecords(root: root)) ?? []
        // Queued, or claimed by a runner in this app: the shelf's own "Running".
        let running = (try? BotRunQueue(dataRoot: root).activeOrQueuedIDs()) ?? []
        return (Snapshot(contacts: ordered, lines: lines, waiting: waiting, unanswered: unanswered, helpers: helpers,
                         running: running), list)
    }

    /// How a contact is reached, in words a person uses.
    nonisolated private static func via(_ row: AgentContactRow) -> String {
        if row.builtIn { return "Built-in connection on this Mac" }
        guard let contact = row.contact else { return "On this Mac" }
        switch contact.transport {
        case .grokBot: return "Routine · replies come back here"
        case .acp: return "Runs on this Mac"
        case .a2a: return "Over the network (A2A)"
        case .nativeAgent: return "Another NativeAgent"
        case .desktop: return "Desktop app on this Mac"
        case .desktopChat: return "Desktop app · through its chat window"
        case .mcpHost: return "Through its settings on this Mac (MCP)"
        }
    }

    nonisolated private static func link(_ row: AgentContactRow) -> SimpleContact.Link? {
        switch row.contact?.transport {
        case .grokBot?: return .routine
        case .desktop?, .desktopChat?: return .desktopApp
        default: return nil
        }
    }

    private struct GrokRequest: Sendable { var peer, conversation, message, state: String }

    /// Grok Bot's sent messages: which chat session each answer arrives in.
    nonisolated private static func grokRequests(root: URL) -> [GrokRequest] {
        let dir = root.appendingPathComponent("agents/grok-requests", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let peer = object["peerID"] as? String, let conversation = object["conversationID"] as? String
            else { return nil }
            return GrokRequest(peer: peer, conversation: conversation,
                               message: object["messageID"] as? String ?? "", state: object["state"] as? String ?? "")
        }
    }

    /// Turns a contact sent into the agent's chat over the bridge, from the
    /// sessions where the agent talked to it: the live log and the copies kept
    /// at each compaction, once each by message id.
    nonisolated private static func bridgedTurns(root: URL, sessions: [String: Set<String>],
                                                 alias: [String: String]) -> [(String, SimpleThreadLine)] {
        let chat = root.appendingPathComponent("chat", isDirectory: true)
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var seen: Set<String> = []
        var found: [(String, SimpleThreadLine)] = []
        let all = Set(sessions.values.flatMap { $0 }).filter { !$0.isEmpty && !$0.contains("/") && !$0.contains("..") }
        for session in all {
            let folder = chat.appendingPathComponent("sessions/\(session)", isDirectory: true)
            let backups = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix("messages.compact.") && $0.hasSuffix(".jsonl") }
                .map { folder.appendingPathComponent($0) }
            for file in backups + [chat.appendingPathComponent("messages/\(session).jsonl")] {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for row in text.split(separator: "\n") where row.contains("\"agent-bridge\"") {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
                          object["role"] as? String == "user",
                          let id = object["id"] as? String, !seen.contains(id),
                          let metadata = object["metadata"] as? [String: Any],
                          let envelope = metadata["envelope"] as? [String: Any],
                          let peer = envelope["userId"] as? String,
                          let contact = alias[peer], sessions[contact]?.contains(session) == true,
                          let content = object["content"] as? String
                    else { continue }
                    seen.insert(id)
                    let said = bridgedText(content)
                    guard !said.isEmpty else { continue }
                    let at = (object["createdAt"] as? String).flatMap { dates.date(from: $0) } ?? .distantPast
                    found.append((contact, SimpleThreadLine(id: id, fromAgent: false, text: said, at: at)))
                }
            }
        }
        return found
    }

    /// A bridged turn without the bracketed notes the bridge puts on top.
    nonisolated static func bridgedText(_ content: String) -> String {
        var rows = content.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let first = rows.first?.trimmingCharacters(in: .whitespaces),
              first.isEmpty || (first.hasPrefix("[") && first.hasSuffix("]")) {
            rows = rows.dropFirst()
        }
        return rows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func receiptReply(_ receipt: JSONValue?) -> String? {
        guard case .object(let root)? = receipt else { return nil }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        for key in ["reply", "answer", "agent_reply_text", "agent_reply_text_head", "completion_text_head"] {
            if case .string(let text)? = value[key], !text.isEmpty { return text }
        }
        return nil
    }

    /// The first line of some text with its markdown marks gone, for a row.
    nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>-* "))
    }
}

extension EnvironmentValues {
    /// app_page_screenshot's "simple_settings_menu": the settings menu drawn
    /// open in place, since a popover is its own window and never draws offscreen.
    @Entry var simpleSettingsMenuDrawnOpen = false
}

struct SimpleShellView: View {
    enum Pane: Hashable { case agent, contact(String), helper(UUID), crew(String) }
    private struct Watch: Equatable { let root: URL; let helpers: [UUID] }

    @Environment(AppModel.self) private var appModel
    @State private var store = SimpleViewStore()
    @State private var pane: Pane = .agent

    private var root: URL { appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    /// The open contact, helper or crew left the lists (unreachable, deleted,
    /// or a finished crew past the newest three): back to the agent's chat,
    /// not a blank pane.
    private var gone: some View {
        Color.clear.onAppear { pane = .agent }
    }

    var body: some View {
        ShellFrame(classic: false) {
            SimpleSidebar(store: store, pane: $pane)
        } detail: {
            let showingChat = pane == .agent
            ZStack {
                // The agent's chat, whole, as Advanced has it — only the
                // conversation list is gone. Mounted for the life of the view
                // like ContentView's, so a thread visit never rebuilds it.
                ChatView()
                    .environment(\.chatHidesConversationList, true)
                    .environment(\.chatPageIsVisible, showingChat)
                    .opacity(showingChat ? 1 : 0)
                    .allowsHitTesting(showingChat)
                    .disabled(!showingChat)
                    .accessibilityHidden(!showingChat)
                    .accessibilityElement(children: showingChat ? .contain : .ignore)
                switch pane {
                case .agent:
                    EmptyView()
                case .contact(let id):
                    if let contact = store.contacts.first(where: { $0.id == id }) {
                        SimpleContactThread(contact: contact, store: store) { pane = .agent }
                            .id(contact.id)
                    } else { gone }
                case .helper(let id):
                    if let helper = store.helpers.first(where: { $0.id == id }) {
                        SimpleHelperRuns(record: helper, store: store) { pane = .agent }
                            .id(helper.id)
                    } else { gone }
                case .crew(let id):
                    if let crew = store.crews.first(where: { $0.id == id }) {
                        SimpleCrewThread(crew: crew)
                            .id(crew.id)
                    } else { gone }
                }
            }
        }
        // Restarted when the helpers change, so each one's run.lock is watched.
        .task(id: Watch(root: root, helpers: store.helpers.map(\.id))) {
            await store.watch(root: root, helpers: store.helpers.map(\.id))
        }
        .task(id: root) { await store.watchCrews(root: root) }
        // An offscreen drawing waits for the first read, so the lists are there.
        .quietReadTask(live: false) {
            while !store.loaded, !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
    }
}

/// The menu the person row opens, upward from the plate's foot: a waiting
/// update, the haze colour, the warmth switch, and the way to all settings.
/// Rows in the composer card's recipe; the same keys Advanced writes.
private struct SimpleSettingsMenu: View {
    let close: () -> Void
    @AppStorage(MoodTintPreference.key) private var warmth = true
    @AppStorage(SimpleViewMode.key) private var viewMode = ""
    @Environment(\.colorScheme) private var scheme
    @State private var updates = UpdateController.shared
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let version = updates.status.availableVersion {
                button("update", icon: "arrow.down.circle", "Version \(version) is ready", fill: NativeAgentShell.quietFill) {
                    close()
                    updates.checkForUpdates()
                } trailing: {
                    Text("Install").font(ShellType.labelMedium).foregroundStyle(NativeAgentShell.text)
                }
                hairline
            }
            VStack(alignment: .leading, spacing: 6) {
                label("paintpalette", "Colour")
                HazeSwatches().padding(.leading, 16)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            // The warmth only lands in dark mode (MoodTintGate); in light the
            // switch would change nothing, so it isn't offered.
            if scheme == .dark {
                Toggle(isOn: $warmth) { label("sun.max", "Warmth in the glass") }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .hazeTinted()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            hairline
            button("more", icon: "gearshape", "More settings") {
                close()
                viewMode = SimpleViewMode.advanced
                _ = NativeAgentAppCoordinator.shared.request(.sidebar(.settings))
            } trailing: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        }
        .padding(NativeAgentSpacing.md)
        .frame(width: 264, alignment: .leading)
    }

    private var hairline: some View {
        Rectangle().fill(NativeAgentShell.hairline).frame(height: 1).padding(.vertical, 6)
    }

    private func label(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(NativeAgentShell.secondary)
                .frame(width: 16)
            Text(title)
                .font(ShellType.labelMedium)
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
        }
    }

    private func button<Trailing: View>(_ id: String, icon: String, _ title: String, fill: Color? = nil,
                                        action: @escaping () -> Void,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label(icon, title)
                Spacer(minLength: 4)
                trailing()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if hovered == id || fill != nil {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovered == id ? NativeAgentShell.softFill : fill ?? .clear)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
    }
}

/// The floating plate: the agent, then Agents, then Helpers.
private struct SimpleSidebar: View {
    let store: SimpleViewStore
    @Binding var pane: SimpleShellView.Pane
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.simpleSettingsMenuDrawnOpen) private var drawMenuOpen
    @Namespace private var bar
    @State private var showQuiet = false
    @State private var showCrews = false
    @State private var showSettings = false
    /// "last ran … ago" is measured from this, re-stamped when the plate
    /// appears, the window comes forward, a helper changes or the pointer
    /// arrives; no timer.
    @State private var now = Date()

    static let width: CGFloat = 280
    static let sectionGap: CGFloat = 22
    static let rowName = Font.system(size: 14, weight: .medium)
    static let rowLine = Font.system(size: 12)
    private var agentName: String { AgentVoice(name: appModel.agentDisplayName).name }
    private var plate: RoundedRectangle {
        RoundedRectangle(cornerRadius: NativeAgentShellLayout.railPlateRadius, style: .continuous)
    }

    var body: some View {
        // Talked to, newest first; the rest fold at the end.
        let talked = store.contacts.filter { !isQuiet($0) }
        let unheard = store.contacts.filter(isQuiet)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SimpleAgentCard(selected: pane == .agent, bar: bar) { pane = .agent }
                    .padding(.bottom, Self.sectionGap)
                sectionTitle("Agents", "Other AIs I work with.")
                if store.loaded && store.contacts.isEmpty {
                    quiet("None connected yet. Ask \(agentName) to connect one.")
                }
                ForEach(talked) { contactRow($0) }
                if !unheard.isEmpty {
                    fold("Not talked to yet", count: unheard.count, open: $showQuiet)
                    if showQuiet {
                        ForEach(unheard) { contactRow($0) }
                    }
                }
                sectionTitle("Helpers", "Bots I made that can do real work for you. Talk to any of them here.").padding(.top, Self.sectionGap)
                // Crews at work lead the section, and leave it when they finish.
                ForEach(store.crews.filter(\.live)) { crewRow($0) }
                if store.loaded && store.helpers.isEmpty {
                    quiet("None yet. Ask \(agentName) to make one.")
                }
                ForEach(store.helpers) { helper in
                    let selected = pane == .helper(helper.id)
                    let timing = Self.timing(helper, now: now)
                    let working = store.running.contains(helper.id) || store.waiting.contains(SimpleViewStore.key(helper.id))
                    row(selected: selected, action: { pane = .helper(helper.id) }) {
                        HStack(spacing: 10) {
                            SimpleClockTile(size: 30, working: working)
                            rowText(helper.definition.name, timing, selected: selected)
                        }
                    }
                    .accessibilityLabel("\(helper.definition.name), \(working ? "working now, " : "")\(timing)")
                }
                let finished = store.crews.filter { !$0.live }
                if !finished.isEmpty {
                    fold("Recent crews", count: finished.count, open: $showCrews)
                    if showCrews {
                        ForEach(finished) { crewRow($0) }
                    }
                }
            }
            // Below the traffic lights, which sit on the plate's top edge.
            .padding(.top, 30)
            .padding(.bottom, 14)
            .animation(NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion), value: pane)
        }
        .scrollIndicators(.never)
        // Settings stays on the plate's foot: under the lists while there is
        // room, and in a short window the lists scroll beneath it, its own
        // coat keeping it legible, not a second glass on the plate's glass
        // (User, 09-24). An inset, not safeAreaBar: that pinned the main thread
        // at 100% in this window on 09-23 (f24194bb0).
        .safeAreaInset(edge: .bottom, spacing: 0) { settingsRow }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .clipShape(plate)
        // The rail's plate, exactly: the same glass, radius and inset, and the
        // same shimmer while the agent thinks.
        .background { ThinkingGlow(kind: .shimmer, cornerRadius: NativeAgentShellLayout.railPlateRadius) }
        .glassEffect(reduceTransparency ? .identity : ShellSidebarRail.plateGlass, in: plate)
        // A window in the background loses the glass's own rim, and the plate
        // read as a flat slab; the hairline keeps its rounded edge there.
        .overlay {
            if activeState == .inactive || reduceTransparency {
                plate.strokeBorder(NativeAgentShell.hairline, lineWidth: 1).allowsHitTesting(false)
            }
        }
        .padding([.top, .bottom, .leading], NativeAgentShellLayout.railPlateInset)
        .padding(.trailing, 6)
        .overlay(alignment: .bottomLeading) {
            if drawMenuOpen {
                let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
                SimpleSettingsMenu {}
                    .background(card.fill(TodayPalette.cardFill))
                    .overlay(card.strokeBorder(TodayPalette.cardStroke, lineWidth: 1))
                    .padding(.leading, NativeAgentShellLayout.railPlateInset + 12)
                    .padding(.bottom, NativeAgentShellLayout.railPlateInset + 46)
            }
        }
        .onAppear { now = Date() }
        .onChange(of: activeState) { now = Date() }
        .onChange(of: store.helpers) { now = Date() }
        .onHover { if $0 { now = Date() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agentName), agents and helpers")
    }

    /// A little gear and the word, at the plate's foot (User, 09-24: "just a
    /// settings thing"); it opens the settings menu upward.
    private var settingsRow: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                Text("Settings")
                    .font(Self.rowLine)
            }
            .foregroundStyle(NativeAgentShell.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, NativeAgentShellLayout.railWordInset)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSettings, arrowEdge: .top) {
            SimpleSettingsMenu { showSettings = false }
        }
        .padding(.bottom, 8)
        // A flat coat of the room, fading in over 16pt, so rows sliding under
        // it are gone before they reach the word (the edge effect alone left
        // text on text at 600pt). Inside the bar, so the last row still
        // scrolls clear of it; paint, not a second glass.
        .padding(.top, 16)
        .background {
            VStack(spacing: 0) {
                LinearGradient(colors: [NativeAgentShell.room.opacity(0), NativeAgentShell.room.opacity(1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                NativeAgentShell.room.opacity(1)
            }
            .allowsHitTesting(false)
        }
    }

    private func fold(_ title: String, count: Int, open: Binding<Bool>) -> some View {
        Button {
            withAnimation(NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion)) {
                open.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                Text("\(title) (\(count))")
                    .font(Self.rowLine)
            }
            .foregroundStyle(NativeAgentShell.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, NativeAgentShellLayout.railWordInset)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(open.wrappedValue ? "Expanded" : "Collapsed")
    }

    /// "Working now · <task> · 3 workers" while it runs; the task and how it
    /// went once it has finished.
    private func crewRow(_ crew: SimpleCrew) -> some View {
        let selected = pane == .crew(crew.id)
        let workers = crew.workers.count == 1 ? "1 worker" : "\(crew.workers.count) workers"
        let name = crew.live ? "Working now" : crew.task
        let line = crew.live ? "\(crew.task) · \(workers)" : "\(SimpleCrewThread.outcome(crew)) · \(workers)"
        return row(selected: selected, action: { pane = .crew(crew.id) }) {
            HStack(spacing: 10) {
                SimpleClockTile(size: 30, symbol: "person.3", working: crew.live)
                rowText(name, line, selected: selected)
            }
        }
        .accessibilityLabel("\(name), \(line)")
    }

    private func isQuiet(_ contact: SimpleContact) -> Bool {
        (store.lines[contact.id] ?? []).isEmpty && !store.waiting.contains(contact.id)
            && !store.unanswered.contains(contact.id)
    }

    private func contactRow(_ contact: SimpleContact) -> some View {
        let selected = pane == .contact(contact.id)
        // Lead with how it is connected, so two contacts behind one app's
        // icon ("Grok", "Grok Bot") read as the two things they are.
        let line = [contact.link?.words, lastLine(contact)].compactMap { $0 }.joined(separator: " · ")
        return row(selected: selected, action: { pane = .contact(contact.id) }) {
            HStack(spacing: 10) {
                SimpleAvatar(contact: contact, size: 30)
                    .overlay { if store.waiting.contains(contact.id) { WorkingRim(cornerRadius: 15) } }
                rowText(contact.name, line, selected: selected)
            }
        }
        .accessibilityLabel("\(contact.name), \(line)")
    }

    private func rowText(_ name: String, _ line: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(Self.rowName)
                .foregroundStyle(selected ? NativeAgentShell.text : NativeAgentShell.text.opacity(0.88))
            Text(line)
                .font(Self.rowLine)
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .lineLimit(1)
    }

    /// "Daily at 09:00 · last ran 2 hr. ago", or "Paused".
    static func timing(_ helper: BotsShelfRecord, now: Date = Date()) -> String {
        if helper.definition.paused { return "Paused" }
        guard let last = helper.entries.map(\.runAt).max() else { return helper.cadence }
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .short
        return helper.cadence + " · last ran " + ago.localizedString(for: last, relativeTo: max(now, last))
    }

    private func lastLine(_ contact: SimpleContact) -> String {
        if store.waiting.contains(contact.id) { return "Waiting for a reply" }
        guard let last = store.lines[contact.id]?.last else {
            return store.unanswered.contains(contact.id) ? "No reply came back" : "No messages yet"
        }
        let text = SimpleViewStore.firstLine(last.text)
        return last.fromAgent ? "\(agentName): \(text)" : text
    }

    /// A section's word, and one line saying what lives there, so a stranger
    /// can tell agents from helpers (Agent's crew review, User 09-23).
    private func sectionTitle(_ title: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(ShellType.captionSemibold)
                .foregroundStyle(NativeAgentShell.tertiary)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, NativeAgentShellLayout.railWordInset)
        .padding(.bottom, 6)
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(Self.rowLine)
            .foregroundStyle(NativeAgentShell.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, NativeAgentShellLayout.railWordInset)
            .padding(.vertical, 4)
    }

    private func row<Content: View>(selected: Bool, action: @escaping () -> Void,
                                    @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, NativeAgentShellLayout.railWordInset)
                .padding(.trailing, 12)
                .frame(height: 44)
                .overlay(alignment: .leading) { SimpleSelectionBar(selected: selected, bar: bar) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// "A bar means here" (house rule 2): 2pt by 20, 4pt in, travelling between rows.
private struct SimpleSelectionBar: View {
    let selected: Bool
    let bar: Namespace.ID

    var body: some View {
        if selected {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(NativeAgentShell.text)
                .frame(width: 2, height: 20)
                .padding(.leading, NativeAgentShellLayout.barInset)
                .matchedGeometryEffect(id: "simple.sidebar.bar", in: bar)
        }
    }
}

/// The agent at the top of the plate: name, a breathing orb in the haze
/// colour, and what the agent is doing now, never a quote of what it said.
/// Its own view so the turn-state reads stay out of the rest of the sidebar.
private struct SimpleAgentCard: View {
    let selected: Bool
    let bar: Namespace.ID
    let open: () -> Void
    @Environment(AppModel.self) private var appModel

    /// The mockup's serif title: the one name in the window with presence.
    static let nameFont = Font.system(size: 28, weight: .semibold, design: .serif)

    /// "Thinking…" / "Replying…" while a turn runs; "Waiting on you" (the
    /// teal, its one job) while an approval waits; otherwise "Here".
    private var doing: (text: String, waiting: Bool) {
        if appModel.isThinkingBeforeReply { return ("Thinking…", false) }
        if appModel.isBusy || appModel.isChatStreaming { return ("Replying…", false) }
        let waiting = appModel.approvals.contains {
            $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pending"
        }
        return waiting ? ("Waiting on you", true) : ("Here", false)
    }

    var body: some View {
        let name = AgentVoice(name: appModel.agentDisplayName).name
        let line = doing
        // The rim while the reply streams; before it, the plate shimmers.
        let replying = (appModel.isBusy || appModel.isChatStreaming) && !appModel.isThinkingBeforeReply
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    SimpleBreathingOrb(replying: replying)
                    Text(name)
                        .font(Self.nameFont)
                        .foregroundStyle(NativeAgentShell.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                // The selection bar marks the name's line, as on every row.
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    SimpleSelectionBar(selected: selected, bar: bar)
                        .padding(.leading, -NativeAgentShellLayout.railWordInset)
                }
                HStack(spacing: 6) {
                    if line.waiting {
                        Circle().fill(NativeAgentShell.needsYou).frame(width: 7, height: 7)
                    }
                    Text(line.text)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, NativeAgentShellLayout.railWordInset)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name). \(line.text)")
        .accessibilityHint("Opens the chat with \(name)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A small disc in the haze colour that breathes. Still under Reduce Motion.
/// Core Animation, not a SwiftUI repeatForever: a SwiftUI loop wakes the main
/// thread every frame and re-evaluates the window's tree, which pinned Simple
/// view at 12% idle and 100% while a long reply streamed (2026-09-23 soak).
private struct SimpleBreathingOrb: View {
    var replying = false
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BreathingOrbLayer(haze: HazeColor(stored: colorRaw), still: reduceMotion)
            .frame(width: 22, height: 22)
            // Round the 14pt disc with a 2pt gap.
            .overlay { if replying { WorkingRim(cornerRadius: 8).frame(width: 16, height: 16) } }
            .padding(-4)
            .accessibilityHidden(true)
    }
}

private struct BreathingOrbLayer: NSViewRepresentable {
    var haze: HazeColor
    var still: Bool

    func makeNSView(context: Context) -> OrbView { OrbView() }
    func updateNSView(_ view: OrbView, context: Context) { view.apply(haze: haze, still: still) }

    final class OrbView: NSView {
        private let disc = CAGradientLayer()
        private var applied: (HazeColor, Bool)?

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            disc.type = .radial
            disc.startPoint = CGPoint(x: 0.35, y: 0.7)
            disc.endPoint = CGPoint(x: 1.1, y: -0.1)
            disc.shadowRadius = 5
            disc.shadowOffset = .zero
            layer?.addSublayer(disc)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let side: CGFloat = 14
            disc.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            disc.cornerRadius = side / 2
            CATransaction.commit()
        }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

        func apply(haze: HazeColor, still: Bool) {
            if let applied, applied.0 == haze, applied.1 == still { return }
            applied = (haze, still)
            let base = NSColor(haze.base), light = NSColor(haze.edgeLight)
            disc.colors = [light.cgColor, base.cgColor]
            disc.shadowColor = base.cgColor
            disc.removeAllAnimations()
            disc.shadowOpacity = 0.45
            guard !still else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.92; scale.toValue = 1.08
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.35; glow.toValue = 0.7
            let group = CAAnimationGroup()
            group.animations = [scale, glow]
            group.duration = 2.8
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24)
            disc.add(group, forKey: "breathe")
        }
    }
}

/// The contact's app icon in a circle, or its initial on a tint of its own.
struct SimpleAvatar: View {
    let contact: SimpleContact
    var size: CGFloat = 30

    /// Resolved once per bundle id; nil when the app is not on this Mac.
    @MainActor private static var icons: [String: NSImage?] = [:]
    /// Eight hues 45° apart (OKLCH h 25…340, L 0.53, C 0.075): one muted
    /// lightness, so no slot is louder than another, each ≥5.09:1 under a
    /// white initial. Adjacent slots are a full eighth of the wheel apart.
    nonisolated private static let tints: [UInt32] = [0x925A56, 0x886439, 0x6A713C, 0x42795D, 0x2B7880, 0x496F96, 0x6F6393, 0x895A79]
    nonisolated static var slotCount: Int { tints.count }

    @MainActor private static func icon(_ bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleID] = icon
        return icon
    }

    private static func tint(_ contact: SimpleContact) -> Color {
        let rgb = tints[contact.tintSlot ?? 0]
        return Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    var body: some View {
        Group {
            if let icon = contact.appBundleID.flatMap(Self.icon) {
                // The icon's squircle fills the circle; its transparent margin falls outside.
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().scaleEffect(1.24)
            } else {
                Self.tint(contact).overlay {
                    Text(contact.initial)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(NativeAgentShell.hairline, lineWidth: 0.5) }
        // A small window on the desktop app's corner: this contact is the app itself.
        .overlay(alignment: .bottomTrailing) {
            if contact.link == .desktopApp {
                Image(systemName: "macwindow")
                    .font(.system(size: size * 0.24, weight: .semibold))
                    .foregroundStyle(NativeAgentShell.text)
                    .frame(width: size * 0.44, height: size * 0.44)
                    .background(Circle().fill(NativeAgentShell.room))
                    .overlay { Circle().strokeBorder(NativeAgentShell.hairline, lineWidth: 0.5) }
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
        .accessibilityHidden(true)
    }
}

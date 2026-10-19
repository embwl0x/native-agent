import AppKit
import Agents
import ChatOrchestration
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import StandingBots
import Transcripts
import Darwin
import Experiences

/// A contact, keyed the way the agent's conversation records key it:
/// `peer:<id>` for a saved contact, `codex` / `claude` / `omp` for a
/// built-in lane.
public struct AgentContactPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let builtIn: Bool
    /// How the agent reaches it, in a line.
    public let via: String
    /// A saved connection stays visible even when it cannot initiate a turn.
    public var sendRestriction: String? = nil
    /// Proven traffic counts even when its transcript is no longer retained.
    public var lastActivityAt: Date? = nil
    /// The Mac app behind it, when there is one, for its avatar.
    public var appBundleID: String? = nil
    /// How it is connected, when two contacts share one app ("Grok" the
    /// desktop app and "Grok Bot" the routine).
    public var link: Link? = nil
    /// Its initials tint: a palette slot three on from the row above (SimpleAvatar).
    public var tintSlot: Int? = nil
    /// Claude — the Claude Code bridge (Claude here) or Claude Desktop —
    /// wears Clawd instead of an app icon (User 09-28).
    public var clawd = false
    /// ChatGPT Dot: his conversation is Agent's Dot chat session, not a conversation record.
    public var dot = false
    public var health: AgentLocalHealth? = nil
    public var recoveredFailure = false
    public var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    public enum Link: Equatable, Sendable {
        case desktopApp, routine
        public var words: String { self == .desktopApp ? "Desktop app" : "Routine" }
    }
}

/// One thing said between the agent and a contact.
public struct AgentContactThreadLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let fromAgent: Bool
    public let text: String
    public let at: Date
    /// Typed by the person in this thread rather than sent by the agent.
    public var byPerson = false
    public var door: String? = nil
    public var fetched = false
}

/// What is moving on a contact's thread now: the other agent's live progress
/// on the send in flight, follow-ups queued behind it, and a stop asked for
/// on it. Nil when none of that is there.
public struct AgentContactFlight: Equatable, Sendable {
    public let recordID: String
    /// How agent_cancel names the contact and its conversation.
    public let agent: String
    public let label: String
    public let scope: String
    /// The send is still going or its reply is still coming.
    public let inFlight: Bool
    public var live: AgentConversationLive?
    public var queued: [Queued]
    /// Only the stop asked for on this send.
    public var stop: AgentConversationStop?

    public struct Queued: Identifiable, Equatable, Sendable {
        public enum State: Equatable, Sendable { case queued, sending, held(String) }
        public let id: String
        public let text: String
        public let at: Date
        public let byPerson: Bool
        public let state: State
    }

    public init?(_ record: AgentConversationRecord, live: AgentConversationLive?) {
        let queued = (record.queued ?? []).map { item in
            Queued(id: item.id, text: item.text, at: item.queuedAt, byPerson: item.byPerson == true,
                   state: item.held.map { .held($0) } ?? (item.id == record.queueReservation ? .sending : .queued))
        }
        let stop = record.stop?.operationID == record.operationID ? record.stop : nil
        let inFlight = ["sending", "waiting"].contains(record.phase)
        guard live != nil || !queued.isEmpty || stop != nil else { return nil }
        (recordID, agent, label, scope) = (record.id, record.agent, record.label, record.scopeSessionID)
        (self.inFlight, self.live, self.queued, self.stop) = (inFlight, live, queued, stop)
    }

    /// The other agent is on it right now (not just handed off).
    public var working: Bool { inFlight && live?.state == "working" }
    /// Streamed words so far, when its lane streams them.
    public var partial: String? {
        guard working, live?.streams == true, let text = live?.partial?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return live?.partialTruncated == true ? "…" + text : text
    }
}

/// Root-scoped contact reads and live reply projections shared by desktop and phone.
public enum AgentContactThreads {
    public struct Snapshot: Sendable {
        public var contacts: [AgentContactPresentation]
        public var lines: [String: [AgentContactThreadLine]]
        public var waiting: Set<String>
        public var status: [String: AgentConversationDelivery]
        public var flights: [String: AgentContactFlight]
        public var helpers: [BotsShelfRecord]
        public var running: Set<UUID>
        /// Not compared: which record each contact's flight comes from, and the
        /// records file as last read, so a live-only tick re-reads just flights.
        public var flightRecords: [String: String] = [:]
        public var recordsStamp = ""
        public init(contacts: [AgentContactPresentation], lines: [String: [AgentContactThreadLine]],
                    waiting: Set<String>, status: [String: AgentConversationDelivery],
                    flights: [String: AgentContactFlight], helpers: [BotsShelfRecord], running: Set<UUID>,
                    flightRecords: [String: String] = [:], recordsStamp: String = "") {
            (self.contacts, self.lines, self.waiting, self.status, self.flights) = (contacts, lines, waiting, status, flights)
            (self.helpers, self.running, self.flightRecords, self.recordsStamp) = (helpers, running, flightRecords, recordsStamp)
        }
    }

    /// What a read changed, worked out off the main actor; nil is unchanged.
    public struct Delta: Sendable {
        public var contacts: [AgentContactPresentation]?
        public var lines: [String: [AgentContactThreadLine]]?
        public var waiting: Set<String>?
        public var status: [String: AgentConversationDelivery]?
        public var flights: [String: AgentContactFlight]?
        public var helpers: [BotsShelfRecord]?
        public var running: Set<UUID>?
    }

    public static func changes(from old: Snapshot, to new: Snapshot) -> Delta? {
        let delta = Delta(contacts: old.contacts == new.contacts ? nil : new.contacts,
                          lines: old.lines == new.lines ? nil : new.lines,
                          waiting: old.waiting == new.waiting ? nil : new.waiting,
                          status: old.status == new.status ? nil : new.status,
                          flights: old.flights == new.flights ? nil : new.flights,
                          helpers: old.helpers == new.helpers ? nil : new.helpers,
                          running: old.running == new.running ? nil : new.running)
        let unchanged = delta.contacts == nil && delta.lines == nil && delta.waiting == nil
            && delta.status == nil && delta.flights == nil && delta.helpers == nil && delta.running == nil
        return unchanged ? nil : delta
    }

    /// The saved contacts with their app identities, kept until what
    /// they are made of can have changed: peers.json, the usable built-in
    /// lanes, or an approved ACP program (each check re-hashes the program
    /// and reads Keychain, so it is not redone on every message).
    public struct ContactList: Sendable {
        public var stamp: [String]
        public var programs: [String]
        public var contacts: [AgentContactPresentation]
    }

    /// A file's identity, size, times and mode; any change re-checks.
    private static func stamp(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return path + " -" }
        return "\(path) \(info.st_ino) \(info.st_size) \(info.st_mode) "
            + "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    /// A helper's conversation key in `lines` / `waiting`: how the agent
    /// messages it (`agent_message` to `bot:<id>`).
    public static func key(_ helper: UUID) -> String { "bot:" + helper.uuidString }

    /// The contact's own app when it is on this Mac: its desktop address, else
    /// its known-agent row. Grok Bot wears the Grok app's icon (User 09-27);
    /// only a desktop-app contact carries the small window badge.
    private static func appBundleID(_ row: AgentContactRow) -> String? {
        if row.contact?.transport == .grokBot {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: GrokBotRoute.bundleID) == nil
                ? nil : GrokBotRoute.bundleID
        }
        let host = row.contact.flatMap { AgentPeerStore.hostRowID($0.endpoint) } ?? row.id
        let bundle = row.contact.flatMap { AgentPeerStore.desktopBundleID($0.endpoint) }
            ?? AgentHostDirectory.rows.first { $0.id == host }?.bundleIDs.first
        return bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil ? nil : $0 }
    }

    private static func isClaude(_ row: AgentContactRow) -> Bool {
        row.contact?.endpoint.absoluteString == "mcp://claude-desktop"
    }

    private static func sendRestriction(_ row: AgentContactRow) -> String? {
        guard let contact = row.contact else { return nil }
        if ChatGPTDotIPCTransport.owns(contact), !contact.canStartTurn { return ChatGPTDotIPCTransport.detail }
        if !contact.canStartTurn {
            return contact.transport == .mcpHost ? "Replies only"
                : "Reconnect to approve its program before sending a message."
        }
        return contact.unavailableAt != nil || !row.credentialAvailable ? "This connection is unavailable for sending." : nil
    }

    private static func contactList(root: URL, cached: ContactList?) throws -> ContactList {
        let peersFile = root.appendingPathComponent("agents/peers.json").path
        let peers = try AgentPeerStore(dataRoot: root).list()
        let inboxes = peers.flatMap { $0.handles ?? [] }.compactMap {
            AgentConversationDelivery.inbox(agent: $0, bridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: root))
        }
        let head = [stamp(peersFile), ChatGPTDotIPCTransport.detail] + inboxes.map { stamp($0.path) }
        if let cached, cached.stamp == head + cached.programs.map(stamp) { return cached }
        // The same contact list the Agents page shows, minus apps that are
        // merely installed: saved contacts, then the usable built-in lanes.
        let programs = peers.filter { $0.transport == .acp }.compactMap { $0.approvedACPExecutable?.path }
        // Stamped before the checks, so a change during them re-checks next time.
        let stamps = head + programs.map(stamp)
        let dates = ISO8601DateFormatter()
        let identity = AgentContactIdentity(dataRoot: root)
        let rows = AgentContactRow.rows(peers: peers, candidates: [], usable: [])
        var seen: Set<String> = []
        // Once per row: the restriction reads Keychain and the program's file.
        let restrictions = rows.map { row in
            AgentConversationDelivery.lane(for: row.key, dataRoot: root) != nil ? nil : sendRestriction(row)
        }
        let grouped = rows.indices.sorted { a, b in
            return restrictions[a] == nil && restrictions[b] != nil
        }.filter { seen.insert(identity.canonical(rows[$0].key)).inserted }
        let contacts = grouped.map { index in
            let row = rows[index]
            return AgentContactPresentation(id: row.id,
                                 name: row.name,
                                 builtIn: row.builtIn, via: via(row),
                                 sendRestriction: restrictions[index],
                                 lastActivityAt: [row.contact?.provenInboundAt, row.contact?.provenOutboundAt]
                                   .compactMap { $0.flatMap { dates.date(from: $0) } }.max(),
                                 appBundleID: appBundleID(row),
                                 link: link(row),
                                 clawd: isClaude(row),
                                 dot: row.contact.map(ChatGPTDotIPCTransport.owns) ?? false)
        }
        return ContactList(stamp: stamps, programs: programs, contacts: contacts)
    }

    public static func mobileThreads(root: URL) async throws -> [MobileAgentThread] {
        Task.detached(priority: .utility) { await AgentContactHealth.shared.refresh(dataRoot: root) }
        let snapshot = try read(root: root, cached: nil, includeHelpers: false).0
        let experiences = try await ExperienceStore.at(root).projection()
        let identity = AgentContactIdentity(dataRoot: root)
        return snapshot.contacts.map { contact in
            let lines = snapshot.lines[contact.id] ?? []
            let owed = experiences.filter { experience in
                experience.isOpen && experience.addressedTo.contains {
                    $0.hasPrefix("agent:") && identity.canonical(String($0.dropFirst(6))) == identity.canonical(contact.id)
                }
            }.map(\.mobile)
            let status: String
            if !owed.isEmpty {
                status = "\(owed.count) \(owed.count == 1 ? "message" : "messages") still owed"
            } else if let problem = contact.health?.problem { status = problem }
            else if snapshot.waiting.contains(contact.id) { status = "Waiting for reply" }
            else if contact.recoveredFailure, snapshot.status[contact.id] == nil { status = "Ready" }
            else {
                switch snapshot.status[contact.id] {
                case .sending?, .waiting?: status = "Waiting for reply"
                case .delivered?: status = "Delivered"
                case .read?: status = "Read"
                case .answered?: status = "Replied"
                case .failed?: status = "No reply"
                case .notDelivered?: status = "Not delivered"
                case nil: status = ""
                }
            }
            let last = lines.last { !contact.recoveredFailure || !AgentLocalHealth.authenticationFailure(.string($0.text)) }
            var row = MobileAgentRow(id: contact.id, name: contact.name, via: contact.via,
                                     lastExchange: String((last?.text ?? "").prefix(240)), status: status,
                                     sendRestriction: contact.sendRestriction)
            row.experiences = owed
            let tail = lines.suffix(32)
            return MobileAgentThread(agent: row, lines: tail.map {
                MobileAgentLine(id: $0.id, speaker: $0.byPerson ? "You" : $0.fromAgent ? "Agent" : contact.name,
                                text: String($0.text.prefix(2_000)), at: $0.at.timeIntervalSince1970)
            }, truncated: lines.count > tail.count || tail.contains { $0.text.count > 2_000 })
        }
    }

    public static func read(root: URL, cached: ContactList?, includeHelpers: Bool = true) throws -> (Snapshot, ContactList) {
        let list = try contactList(root: root, cached: cached)
        var contacts = list.contacts
        let identity = AgentContactIdentity(dataRoot: root)
        let displayed = Dictionary(contacts.map { (identity.canonical($0.id), $0.id) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(contacts.map(\.id))
        let dots = Set(contacts.filter(\.dot).map(\.id))
        func owner(_ agent: String) -> String? {
            if ids.contains(agent) { return agent }
            if let id = displayed[identity.canonical(agent)] { return id }
            // A helper's thread, keyed by the helper whatever case its id came in.
            if agent.hasPrefix("bot:") { return UUID(uuidString: String(agent.dropFirst(4))).map(key) }
            return nil
        }

        let recordsStamp = threadStamp(root: root)
        let records = try AgentConversationStore(dataRoot: root).records()
        var lines: [String: [AgentContactThreadLine]] = [:]
        var replies: [String: [AgentContactThreadLine]] = [:]
        var latest: [String: AgentConversationRecord] = [:]
        var lastActive = Dictionary(contacts.compactMap { contact in
            contact.lastActivityAt.map { (contact.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        for record in records {
            // Dot sends straight through; his old record is no part of his thread.
            guard let id = owner(record.agent), !dots.contains(id) else { continue }
            lastActive[id] = max(lastActive[id] ?? .distantPast, record.updatedAt)
            if record.updatedAt >= (latest[id]?.updatedAt ?? .distantPast) { latest[id] = record }
            // A contact's thread is its own session (below); its record says
            // only where the current send stands. A helper's is its record.
            guard id.hasPrefix("bot:") else { continue }
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
        // Everything a contact and the agent said to each other, from its own session.
        let transcripts = contacts.isEmpty ? [] : try ChatSessionRetention.transcriptFiles(dataRoot: root,
            archived: ChatSessionRetention.archivedTranscripts(dataRoot: root))
        for contact in contacts {
            let said = try ContactThread.mergedLines(dataRoot: root, owner: contact.builtIn ? contact.id : String(contact.id.dropFirst(5)),
                                                    identity: identity, transcripts: transcripts)
            if !said.isEmpty {
                lines[contact.id] = said.map { AgentContactThreadLine(id: $0.id, fromAgent: $0.mine, text: $0.text, at: $0.at, byPerson: $0.byPerson,
                                                             door: $0.door, fetched: $0.fetched) }
            }
        }
        for (id, said) in replies { lines[id, default: []] += said }
        for key in lines.keys {
            lines[key]?.sort { $0.at < $1.at }
            if let last = lines[key]?.last { lastActive[key] = max(lastActive[key] ?? .distantPast, last.at) }
        }

        var waiting: Set<String> = []
        var status: [String: AgentConversationDelivery] = [:]
        let health = AgentContactHealth.read(dataRoot: root)
        for index in contacts.indices {
            contacts[index].health = health[contacts[index].id]
        }
        for (id, record) in latest {
            if let index = contacts.firstIndex(where: { $0.id == id }),
               health[record.agent]?.resolves(record) == true {
                contacts[index].recoveredFailure = true
                if lines[id]?.last?.fetched == true { status[id] = .read }
                continue
            }
            // A failed outbound attempt says nothing about a newer inbound turn's answer.
            if let last = lines[id]?.last, last.at > record.updatedAt {
                if last.fromAgent, last.fetched { status[id] = .read }
                continue
            }
            // A contact that has spoken since the send answered it, whatever its record says.
            if record.phase != "attention", !id.hasPrefix("bot:"), lines[id]?.last.map({ !$0.fromAgent }) == true { continue }
            switch AgentConversationDelivery.of(record, read: false) {
            case .sending, .waiting: waiting.insert(id)
            case .answered: break
            case let state: status[id] = state
            }
        }
        for contact in contacts where latest[contact.id] == nil && lines[contact.id]?.last?.fetched == true {
            status[contact.id] = .read
        }
        // Dot's thread owns its wait; every view uses the same reply projection.
        // Inbound only, no reply is awaited: his thread carries his contact's state.
        for id in dots where ChatGPTDotIPCTransport.available {
            guard let last = lines[id]?.last, last.fromAgent else { continue }
            if case .object(let reply) = AgentConversationView.dotReply(.object([:]), sentAt: last.at), reply["terminal"] == .bool(true) {
                status[id] = .failed
            } else { waiting.insert(id) }
        }
        let live = latest.values.contains { ["sending", "waiting"].contains($0.phase) }
            ? AgentConversationLiveStore(dataRoot: root).all() : [:]
        var flights: [String: AgentContactFlight] = [:]
        for (id, record) in latest { flights[id] = AgentContactFlight(record, live: AgentConversationLiveStore.current(for: record, in: live)) }
        let ordered = contacts.enumerated().sorted { a, b in
            switch (lastActive[a.element.id], lastActive[b.element.id]) {
            case let (x?, y?): return x != y ? x > y : a.offset < b.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
        let helpers = includeHelpers ? (try? BotsShelfRecord.read(root: root)) ?? [] : []
        // Queued, or claimed by a runner in this app: the shelf's own "Running".
        let running = (try? BotRunQueue(dataRoot: root).activeOrQueuedIDs()) ?? []
        return (Snapshot(contacts: ordered, lines: lines, waiting: waiting, status: status, flights: flights,
                         helpers: helpers, running: running, flightRecords: latest.mapValues(\.id),
                         recordsStamp: recordsStamp), list)
    }

    private static func threadStamp(root: URL) -> String {
        stamp(root.appendingPathComponent("agents/conversations.json").path)
            + stamp(root.appendingPathComponent("chat/sessions.json").path)
    }

    /// Only the flights, for a tick of the live file alone. Nil when the
    /// records or chat index moved since the last full read.
    public static func readFlights(root: URL, last: Snapshot) -> [String: AgentContactFlight]? {
        guard threadStamp(root: root) == last.recordsStamp,
              let records = try? AgentConversationStore(dataRoot: root).records() else { return nil }
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = last.flightRecords.values.contains { byID[$0].map { ["sending", "waiting"].contains($0.phase) } == true }
            ? AgentConversationLiveStore(dataRoot: root).all() : [:]
        var flights: [String: AgentContactFlight] = [:]
        for (contact, id) in last.flightRecords {
            if let record = byID[id] { flights[contact] = AgentContactFlight(record, live: AgentConversationLiveStore.current(for: record, in: live)) }
        }
        return flights
    }

    /// How a contact is reached, in words a person uses.
    private static func via(_ row: AgentContactRow) -> String {
        guard let contact = row.contact else { return "On this Mac" }
        if ChatGPTDotIPCTransport.owns(contact) { return ChatGPTDotIPCTransport.detail }
        switch contact.transport {
        case .grokBot: return "Routine · replies come back here"
        case .acp: return "Runs on this Mac"
        case .a2a: return "Over the network (A2A)"
        case .nativeAgent: return "Another NativeAgent"
        case .desktop: return "Desktop app on this Mac"
        case .desktopChat: return "Desktop app · through its chat window"
        case .mcpHost: return contact.canStartTurn ? "Through its settings on this Mac (MCP)" : "Replies only · Through its settings on this Mac (MCP)"
        }
    }

    private static func link(_ row: AgentContactRow) -> AgentContactPresentation.Link? {
        switch row.contact?.transport {
        case .grokBot?: return .routine
        case .desktop?, .desktopChat?: return .desktopApp
        default: return nil
        }
    }

    private static func receiptReply(_ receipt: JSONValue?) -> String? {
        guard case .object(let root)? = receipt else { return nil }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        for key in ["reply", "answer", "agent_reply_text", "agent_reply_text_head", "completion_text_head"] {
            if case .string(let text)? = value[key], !text.isEmpty { return text }
        }
        return nil
    }
}

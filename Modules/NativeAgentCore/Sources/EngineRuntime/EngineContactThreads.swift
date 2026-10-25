import AppKit
import Agents
import ChatToolRuntime
import AgentWorkspace
import AgentConversations
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import StandingBots
import Transcripts
import Darwin
import Experiences
import Observation
import SwarmRuns
import AppToolRuntime
import os
// Blueprint: | `EngineContactThreads.swift` | ContactListFacade owns checked doors through LatestRead; shared contact/helper/crew projections and HerScreen's other-room timeline refresh on the same contact signals |

/// The engine's address book: one checked row per door, including its grant
/// and effective elevation verdict. Agents, Trust and contact threads read it.
@MainActor @Observable
public final class ContactListFacade {
    public nonisolated let dataRoot: URL
    public private(set) var doors: [AgentContactRow] = []
    public private(set) var loaded = false
    public private(set) var loadError: String?
    public var rows: [AgentContactRow] { doors.filter(\.primary) }
    @ObservationIgnored private lazy var latest = LatestRead()
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    public nonisolated init(dataRoot: URL) { self.dataRoot = dataRoot }
    deinit { watchTask?.cancel() }

    @discardableResult
    public func refresh() async throws -> [AgentContactRow] {
        try await refreshDoors().filter(\.primary)
    }

    /// Return this read's doors even when a newer read owns publication.
    func refreshDoors() async throws -> [AgentContactRow] {
        let root = dataRoot
        let result: Result<[AgentContactRow], Error> = await latest.read({
            do {
                return .success(try await Task.detached(priority: .utility) {
                    let discovery = await AgentDiscoverySession.shared.candidates(dataRoot: root)
                    let peers = try AgentPeerStore(dataRoot: root).list()
                    let lasts = AgentConversationStore.lastExchanges(peers: peers,
                        records: (try? AgentConversationStore(dataRoot: root).records()) ?? [], dataRoot: root).mapValues(\.summary)
                    return AgentContactRow.rows(peers: peers, candidates: discovery, usable: [], dataRoot: root, everyDoor: true).map { row in
                        var row = row
                        row.lastExchange = row.contact.flatMap { lasts[$0.id] }
                        return row
                    }
                }.value)
            } catch {
                return .failure(error)
            }
        }, publish: { result in
            loaded = true
            switch result {
            case .success(let next):
                doors = next
                loadError = nil
            case .failure(let error):
                loadError = error.localizedDescription
            }
        })
        return try result.get()
    }

    /// The former mounted address-book watchers belong to this engine now.
    public func watch() {
        guard watchTask == nil else { return }
        let root = dataRoot
        watchTask = Task { [weak self] in
            let events = FileChangeEvents(paths: ["agents/peers.json", "agents/conversations.json",
                "agents/discovery.json", "chat/sessions.json"].map { root.appendingPathComponent($0) }
                + [AgentLocalHealth.url(root), InstallPaths.current.bridgeConfigRoot(dataRoot: root)
                    .appendingPathComponent("claude-bridge/claude-live")], emitInitial: true)
            let dot = NotificationCenter.default.addObserver(forName: ChatGPTDotIPCTransport.didChange,
                object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in _ = try? await self?.refresh() }
            }
            var askedDot = false
            await withTaskCancellationHandler {
                for await _ in events.stream {
                    if Task.isCancelled { break }
                    _ = try? await self?.refresh()
                    if !askedDot, self?.doors.contains(where: { $0.contact.map(ChatGPTDotIPCTransport.owns) == true }) == true {
                        askedDot = true
                        await Task.detached(priority: .userInitiated) {
                            _ = await SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false).chatGPTDotReadiness()
                        }.value
                        _ = try? await self?.refresh()
                    }
                }
            } onCancel: { events.cancel() }
            NotificationCenter.default.removeObserver(dot)
        }
    }
}

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
    /// Claude — the Claude Code bridge (Claude here) or Claude Desktop —
    /// wears Clawd instead of an app icon (User 09-28).
    public var clawd = false
    /// ChatGPT Dot: his conversation is Agent's Dot chat session, not a conversation record.
    public var dot = false
    public var health: AgentLocalHealth? = nil
    public var recoveredFailure = false
    public var owedExperiences: [Experience] = []
    public var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    /// One precedence for every door; dates and clipping belong to the renderer.
    public func status(flight: AgentContactFlight?, waiting: Bool, delivery: AgentConversationDelivery?) -> String? {
        if !owedExperiences.isEmpty { return "\(owedExperiences.count) \(owedExperiences.count == 1 ? "message" : "messages") still owed" }
        if let problem = health?.problem { return problem }
        if let flight {
            if flight.stop?.state == "stopping" { return "Stopping…" }
            if flight.stop?.state == "stopped", !flight.inFlight { return "Stopped" }
            if flight.working { return flight.partial != nil ? "Typing…" : "Working…" }
            if flight.queued.contains(where: { $0.state == .sending }) { return "Sending…" }
            if !flight.inFlight {
                if flight.queued.contains(where: { $0.state == .queued }) { return "Queued" }
                if flight.queued.contains(where: { if case .held = $0.state { true } else { false } }) { return "Not sent" }
            }
        }
        if waiting { return "Waiting for reply" }
        if recoveredFailure, delivery == nil { return "Ready" }
        switch delivery {
        case .sending?, .waiting?: return "Waiting for reply"
        case .delivered?: return "Delivered"
        case .read?: return "Read"
        case .answered?: return "Replied"
        case .failed?: return "No reply"
        case .notDelivered?: return "Not delivered"
        case nil: return health?.word
        }
    }

    public func latestLine(in lines: [AgentContactThreadLine]) -> AgentContactThreadLine? {
        lines.last { !recoveredFailure || !AgentLocalHealth.authenticationFailure(.string($0.text)) }
    }

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
    public var resultID: UUID? = nil
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
    public struct HelperResult: Identifiable, Equatable, Sendable {
        public let entry: ShelfEntry
        public let preview: String?
        public var id: UUID { entry.id }
        public var line: String {
            switch entry.runtimeStatus {
            case .completed: return preview ?? "Result unavailable"
            case .waitingForApproval: return "Waiting for approval"
            case .waitingOnPerson: return entry.statusDetail.map { "Waiting on you — \($0)" } ?? "Waiting on you"
            case .failed: return "Failed: " + (entry.statusDetail ?? "cause not recorded")
            case .stopped: return "Stopped" + (entry.statusDetail.map { ": " + $0 }
                ?? preview.map { ": " + ContactThreadsProjection.firstLine($0) } ?? "")
            case .interrupted: return "Interrupted" + (entry.statusDetail.map { ": " + $0 }
                ?? preview.map { ": " + ContactThreadsProjection.firstLine($0) } ?? "")
            }
        }
    }

    public struct HelperResults: Equatable, Sendable {
        public let history: [HelperResult]
        public let latestCompleted: HelperResult?
    }

    /// Shelf identity selects results; Experience owns the words on every door.
    public static func helperResults(_ helper: BotsShelfRecord, root: URL, historyLimit: Int = 40,
                                     representedResults: Set<UUID> = []) async throws -> HelperResults {
        let history = Array(helper.sortedEntries.filter { !representedResults.contains($0.id) }.prefix(historyLimit))
        let latest = helper.sortedEntries.first { $0.runtimeStatus == .completed }
        var results: [UUID: HelperResult] = [:]
        for entry in history + (latest.map { [$0] } ?? []) where results[entry.id] == nil {
            results[entry.id] = HelperResult(entry: entry,
                preview: try await ExperienceStore.at(root).experience(entry.id.uuidString)?.face?.words)
        }
        return HelperResults(history: history.compactMap { results[$0.id] }, latestCompleted: latest.flatMap { results[$0.id] })
    }

    public struct Snapshot: Sendable {
        public var otherRooms: [OtherRoomExchange] = []
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
                    flightRecords: [String: String] = [:], recordsStamp: String = "", otherRooms: [OtherRoomExchange] = []) {
            self.otherRooms = otherRooms
            (self.contacts, self.lines, self.waiting, self.status, self.flights) = (contacts, lines, waiting, status, flights)
            (self.helpers, self.running, self.flightRecords, self.recordsStamp) = (helpers, running, flightRecords, recordsStamp)
        }
    }

    /// What a read changed, worked out off the main actor; nil is unchanged.
    public struct Delta: Sendable {
        public var otherRooms: [OtherRoomExchange]?
        public var contacts: [AgentContactPresentation]?
        public var lines: [String: [AgentContactThreadLine]]?
        public var waiting: Set<String>?
        public var status: [String: AgentConversationDelivery]?
        public var flights: [String: AgentContactFlight]?
        public var helpers: [BotsShelfRecord]?
        public var running: Set<UUID>?
    }

    public static func changes(from old: Snapshot, to new: Snapshot) -> Delta? {
        let delta = Delta(otherRooms: old.otherRooms == new.otherRooms ? nil : new.otherRooms,
                          contacts: old.contacts == new.contacts ? nil : new.contacts,
                          lines: old.lines == new.lines ? nil : new.lines,
                          waiting: old.waiting == new.waiting ? nil : new.waiting,
                          status: old.status == new.status ? nil : new.status,
                          flights: old.flights == new.flights ? nil : new.flights,
                          helpers: old.helpers == new.helpers ? nil : new.helpers,
                          running: old.running == new.running ? nil : new.running)
        let unchanged = delta.otherRooms == nil && delta.contacts == nil && delta.lines == nil && delta.waiting == nil
            && delta.status == nil && delta.flights == nil && delta.helpers == nil && delta.running == nil
        return unchanged ? nil : delta
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

    private static func contactList(root: URL, owner: ContactListFacade) async throws -> [AgentContactPresentation] {
        let rows = try await owner.refresh().filter { $0.contact != nil }
        let dates = ISO8601DateFormatter()
        // The contact owner has already selected canonical rows and checked credentials.
        let restrictions = rows.map { row in
            AgentConversationDelivery.lane(for: row.key, dataRoot: root) != nil ? nil : sendRestriction(row)
        }
        let grouped = rows.indices.sorted { a, b in
            return restrictions[a] == nil && restrictions[b] != nil
        }
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
                                 dot: row.contact.map(ChatGPTDotIPCTransport.owns) ?? false,
                                 health: row.health)
        }
        return contacts
    }

    public static func mobileThreads(root: URL, contacts: ContactListFacade) async throws -> [MobileAgentThread] {
        let snapshot = try await read(root: root, contacts: contacts, includeHelpers: false)
        return snapshot.contacts.map { contact in
            let lines = snapshot.lines[contact.id] ?? []
            let status = contact.status(flight: snapshot.flights[contact.id],
                waiting: snapshot.waiting.contains(contact.id), delivery: snapshot.status[contact.id]) ?? ""
            let last = contact.latestLine(in: lines)
            var row = MobileAgentRow(id: contact.id, name: contact.name, via: contact.via,
                                     lastExchange: String((last?.text ?? "").prefix(240)), status: status,
                                     sendRestriction: contact.sendRestriction)
            row.experiences = contact.owedExperiences.map(\.mobile)
            let tail = lines.suffix(32)
            return MobileAgentThread(agent: row, lines: tail.map {
                MobileAgentLine(id: $0.id, speaker: $0.byPerson ? "You" : $0.fromAgent ? "Agent" : contact.name,
                                text: String($0.text.prefix(2_000)), at: $0.at.timeIntervalSince1970)
            }, truncated: lines.count > tail.count || tail.contains { $0.text.count > 2_000 })
        }
    }

    public static func read(root: URL, contacts contactOwner: ContactListFacade, includeHelpers: Bool = true) async throws -> Snapshot {
        var contacts = try await contactList(root: root, owner: contactOwner)
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
            let receipt = receiptReply(record.receipt)
            for exchange in history {
                if let prompt = exchange.prompt, !prompt.isEmpty {
                    lines[id, default: []].append(.init(id: exchange.id + ":sent", fromAgent: true,
                        text: prompt, at: exchange.sentAt, byPerson: exchange.byPerson == true))
                }
                // The newest exchange's answer sits in the record's receipt
                // until the next send folds it into the history.
                var reply = exchange.reply
                if reply == nil, exchange.id == record.operationID, record.phase != "sending" {
                    reply = receipt?.text
                }
                if let reply, !reply.isEmpty {
                    replies[id, default: []].append(.init(id: exchange.id + ":reply", fromAgent: false,
                        text: reply, at: exchange.sentAt.addingTimeInterval(0.001),
                        resultID: exchange.id == record.operationID ? receipt?.resultID : exchange.resultID))
                }
            }
            if history.isEmpty, let receipt {
                replies[id, default: []].append(.init(id: record.id + ":reply", fromAgent: false,
                    text: receipt.text, at: record.updatedAt, resultID: receipt.resultID))
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
        let experiences = try await ExperienceStore.at(root).projection()
        for index in contacts.indices {
            contacts[index].owedExperiences = experiences.filter { experience in
                experience.isOpen && experience.addressedTo.contains {
                    $0.hasPrefix("agent:") && identity.canonical(String($0.dropFirst(6))) == identity.canonical(contacts[index].id)
                }
            }
        }
        for (id, record) in latest {
            if let index = contacts.firstIndex(where: { $0.id == id }),
               contacts[index].health?.resolves(record) == true {
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
        let helpers = includeHelpers ? (try? await NativeAgentEngine.forRoot(root).botsShelfRead()) ?? [] : []
        // Queued, or claimed by a runner in this app: the shelf's own "Running".
        let running = (try? BotRunQueue(dataRoot: root).activeOrQueuedIDs()) ?? []
        return Snapshot(contacts: ordered, lines: lines, waiting: waiting, status: status, flights: flights,
                         helpers: helpers, running: running, flightRecords: latest.mapValues(\.id),
                         recordsStamp: recordsStamp, otherRooms: HerScreen.otherRoomExchanges(dataRoot: root, since: .distantPast).map {
                             var event = $0
                             event.contactID = owner(event.contactID) ?? event.contactID
                             return event
                         })
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

    private static func receiptReply(_ receipt: JSONValue?) -> (text: String, resultID: UUID?)? {
        guard case .object(let root)? = receipt else { return nil }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        for key in ["reply", "answer", "agent_reply_text", "agent_reply_text_head", "completion_text_head"] {
            if case .string(let text)? = value[key], !text.isEmpty {
                let id: UUID? = if case .string(let id)? = value["entry_id"] ?? value["message_id"] { UUID(uuidString: id) } else { nil }
                return (text, id)
            }
        }
        return nil
    }
}

@MainActor @Observable
final class ContactFlightProjection {
    @ObservationIgnored var flight: AgentContactFlight?
    var structure: AgentContactFlight?
    var partial: String?
    var hasPartial = false

    func update(_ value: AgentContactFlight?) {
        flight = value
        let text = value?.partial
        if partial != text { partial = text }
        if hasPartial != (text != nil) { hasPartial = text != nil }
        var shape = value
        if var live = shape?.live {
            live.partial = nil
            live.partialChars = 0
            live.partialTruncated = false
            live.lastActivityAt = live.startedAt
            live.firstActivityAt = nil
            shape?.live = live
        }
        if structure != shape { structure = shape }
    }
}

@MainActor @Observable
public final class ContactThreadsProjection {
    public nonisolated let dataRoot: URL
    @ObservationIgnored private var contactsWatch: Task<Void, Never>?
    @ObservationIgnored private var crewsWatch: Task<Void, Never>?
    @ObservationIgnored private let contactRead = LatestRead()
    @ObservationIgnored private let crewRead = LatestRead()

    private nonisolated let contactOwner: ContactListFacade

    public nonisolated init(dataRoot: URL, contacts: ContactListFacade) {
        self.dataRoot = dataRoot
        self.contactOwner = contacts
    }

    /// Both shells observe this engine's existing projection and watches.
    public func start() {
        if contactsWatch == nil { restartContacts() }
        if crewsWatch == nil {
            let root = dataRoot
            crewsWatch = Task { [weak self] in
                await Self.watchCrews(root: root) { [weak self] in self }
            }
        }
    }

    private func restartContacts() {
        contactsWatch?.cancel()
        let root = dataRoot, ids = helpers.map(\.id)
        contactsWatch = Task { [weak self] in
            await Self.watch(root: root, helpers: ids) { [weak self] in self }
        }
    }

    deinit { contactsWatch?.cancel(); crewsWatch?.cancel() }

    /// Most recent exchange first; contacts never talked to keep their order
    /// after them.
    public private(set) var contacts: [AgentContactPresentation] = []
    /// Per contact id, oldest first.
    public private(set) var lines: [String: [AgentContactThreadLine]] = [:]
    public private(set) var otherRooms: [OtherRoomExchange] = []
    /// Contacts with a message still on its way or awaiting a reply.
    public private(set) var waiting: Set<String> = []
    /// Where each contact's latest send stands when no reply is owed or
    /// none came: delivered, read, failed, not delivered.
    public private(set) var status: [String: AgentConversationDelivery] = [:]
    /// Per contact id: its live reply, queue and stop, while there are any.
    @ObservationIgnored private var flights: [String: AgentContactFlight] = [:]
    @ObservationIgnored private var flightSlots: [String: ContactFlightProjection] = [:]
    public private(set) var helpers: [BotsShelfRecord] = [] {
        didSet {
            if oldValue.map(\.id) != helpers.map(\.id) { restartContacts() }
        }
    }
    public private(set) var helperRuns: [UUID: AgentContactThreads.HelperResults] = [:]
    /// False until the first read lands, so an empty list isn't claimed early.
    public private(set) var loaded = false
    /// A failed refresh keeps the last proven conversation snapshot visible.
    public private(set) var refreshError: String?
    /// Helpers with a run queued or under way now.
    public private(set) var running: Set<UUID> = []
    /// Crews at work now, then the few most recently finished.
    public private(set) var crews: [SwarmCrew] = []

    private typealias Snapshot = AgentContactThreads.Snapshot
    private typealias ContactRead = (Snapshot, AgentContactThreads.Delta?, [UUID: AgentContactThreads.HelperResults]?)

    public nonisolated static func key(_ helper: UUID) -> String { AgentContactThreads.key(helper) }

    private func slot(_ id: String) -> ContactFlightProjection {
        if let slot = flightSlots[id] { return slot }
        let slot = ContactFlightProjection()
        flightSlots[id] = slot
        return slot
    }

    public func flight(for id: String) -> AgentContactFlight? {
        let slot = slot(id)
        _ = slot.structure
        _ = slot.hasPartial
        return slot.flight
    }

    public func partial(for id: String) -> String? { slot(id).partial }

    /// Reload whenever the contact list, the conversation records, a chat
    /// (any append rewrites the chat index) or the helpers' shelf change on disk, a helper's run takes its
    /// claim (`run.lock`), or one ends (in memory, so the queue says so), or
    /// a built-in lane's inbox marks a message read. The live hub's partials
    /// (a few writes a second while a reply streams) re-read only the flights.
    private static func watch(root: URL, helpers ids: [UUID], projection: @MainActor () -> ContactThreadsProjection?) async {
        let paths = ["agents/peers.json", "agents/conversations.json", "chat/sessions.json", "bots/definitions",
                     "bots/shelf-index.json", "bots/run-queue.json", "agents/conversation-live.json",
                     "agents/local-health.json", "agents/reply-reads.json"]
            + ids.map { "bots/\($0.uuidString)/run.lock" }
        let liveFile = root.appendingPathComponent("agents/conversation-live.json").standardizedFileURL
        let bridges = InstallPaths.current.bridgeConfigRoot(dataRoot: root)
        let inboxes = ["claude", "codex", "omp"].compactMap { AgentConversationDelivery.inbox(agent: $0, bridgeConfigRoot: bridges) }
        let events = FileChangeEvents(paths: paths.map { root.appendingPathComponent($0) } + inboxes
            + [bridges.appendingPathComponent("claude-bridge/claude-live")], emitInitial: true)
        let (ticks, tick) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // Set by every change, cleared just before a read: a tick buffered
        // while that read's burst settled finds it clear and is skipped.
        // `full` for anything but the live file, which sets only `live`.
        let pending = OSAllocatedUnfairLock(initialState: (full: false, live: false))
        let files = Task {
            for await url in events.stream {
                pending.withLock { if url == liveFile { $0.live = true } else { $0.full = true } }
                tick.yield()
            }
        }
        let experienceChanges = Task {
            for await _ in await ExperienceStore.at(root).changes() {
                pending.withLock { $0.full = true }
                tick.yield()
            }
        }
        let ended = NotificationCenter.default.addObserver(forName: BotRunQueue.didChange, object: nil, queue: nil) { _ in
            pending.withLock { $0.full = true }
            tick.yield()
        }
        let dotChanged = NotificationCenter.default.addObserver(forName: ChatGPTDotIPCTransport.didChange, object: nil, queue: nil) { _ in
            pending.withLock { $0.full = true }
            tick.yield()
        }
        var last: Snapshot
        do {
            guard let owner = projection() else { return }
            last = Snapshot(contacts: owner.contacts, lines: owner.lines, waiting: owner.waiting, status: owner.status,
                            flights: owner.flights, helpers: owner.helpers, running: owner.running, otherRooms: owner.otherRooms)
        }
        await withTaskCancellationHandler {
            for await _ in ticks {
                guard let owner = projection() else { break }
                guard !Task.isCancelled else { break }
                guard pending.withLock({ $0.full || $0.live }) else { continue }
                // One message writes several files; let the burst land first.
                if owner.loaded { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled else { break }
                let first = !owner.loaded
                let retry = owner.refreshError != nil
                let full = pending.withLock { state in
                    defer { state = (false, false) }
                    return state.full || first || retry
                }
                let result = await owner.contactRead.read {
                    do { return Result<ContactRead, Error>.success(try await Task.detached(priority: .userInitiated) { [last, contactOwner = owner.contactOwner] in
                        // A records change that rode in on the live file's tick still gets its full read.
                        if !full, let flights = AgentContactThreads.readFlights(root: root, last: last) {
                            var next = last
                            next.flights = flights
                            return (next, AgentContactThreads.changes(from: last, to: next), Optional<[UUID: AgentContactThreads.HelperResults]>.none)
                        }
                        if try AgentPeerStore(dataRoot: root).list().contains(where: ChatGPTDotIPCTransport.owns) {
                            _ = await SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false).chatGPTDotReadiness()
                        }
                        let snapshot = try await AgentContactThreads.read(root: root, contacts: contactOwner)
                        let next = snapshot
                        let delta = AgentContactThreads.changes(from: last, to: next)
                        var runs: [UUID: AgentContactThreads.HelperResults] = [:]
                        for helper in next.helpers {
                            runs[helper.id] = try await AgentContactThreads.helperResults(helper, root: root,
                                representedResults: Set((next.lines[Self.key(helper.id)] ?? []).compactMap(\.resultID)))
                        }
                        return (next, delta, runs)
                    }.value) }
                    catch { return .failure(error) }
                } publish: { result in
                    switch result {
                    case .success(let (next, delta, runs)):
                    if let delta {
                        if let value = delta.otherRooms { owner.otherRooms = value }
                        if let value = delta.contacts { owner.contacts = value }
                        if let value = delta.lines { owner.lines = value }
                        if let value = delta.waiting { owner.waiting = value }
                        if let value = delta.status { owner.status = value }
                        if let value = delta.flights {
                            for id in Set(owner.flights.keys).union(value.keys) where owner.flights[id] != value[id] {
                                owner.slot(id).update(value[id])
                            }
                            owner.flights = value
                        }
                        if let value = delta.helpers { owner.helpers = value }
                        if let value = delta.running { owner.running = value }
                    }
                    if let runs, owner.helperRuns != runs { owner.helperRuns = runs }
                    if !owner.loaded { owner.loaded = true }
                    owner.refreshError = nil
                    case .failure(let error):
                        owner.refreshError = UserFacingError.message(error, action: "refresh conversations")
                    }
                }
                if case .success(let (next, _, _)) = result {
                    last = next
                }
            }
        } onCancel: { events.cancel(); tick.finish() }
        files.cancel()
        experienceChanges.cancel()
        NotificationCenter.default.removeObserver(ended)
        NotificationCenter.default.removeObserver(dotChanged)
    }

    /// Crews on their own watch: runs.json keeps every finished run whole, so
    /// it is read only when a crew changes, never on a contact's message.
    private static func watchCrews(root: URL, projection: @MainActor () -> ContactThreadsProjection?) async {
        let paths = ["swarms/live.json", "swarms/runs.json"].map { root.appendingPathComponent($0) }
        // The watcher arms on the folder, so the first crew is seen even
        // before one has ever run. An empty folder; nothing else is written.
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: paths[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        }.value
        let events = FileChangeEvents(paths: paths, emitInitial: true)
        await withTaskCancellationHandler {
            for await _ in events.stream {
                guard let owner = projection() else { break }
                guard !Task.isCancelled else { break }
                _ = await owner.crewRead.read { () async -> Result<[SwarmCrew], Error> in
                    do { return .success(try await Task.detached(priority: .utility) { try SwarmCrew.read(root: root) }.value) }
                    catch { return Result<[SwarmCrew], Error>.failure(error) }
                } publish: { result in
                    switch result {
                    case .success(let next): if owner.crews != next { owner.crews = next }
                    case .failure(let error): owner.refreshError = UserFacingError.message(error, action: "refresh crews")
                    }
                }
            }
        } onCancel: { events.cancel() }
    }

    /// A bridged turn without the bracketed notes the bridge puts on top (and
    /// the bare contact-metadata line replies carried before 09-25).
    public nonisolated static func bridgedText(_ content: String) -> String { ContactThread.bridgedText(content) }

    /// The first line of some text with its markdown marks gone, for a row.
    public nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>-* "))
    }
}

import AppKit
import AgentConversations
import AgentWorkspace
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import StandingBots
import Transcripts
import Darwin
import Experiences
// Blueprint: | `ContactConversationReads.swift` | AgentContactThreads and shared contact values read canonical contact conversations, helper results and isolated live flights for desktop and phone |

/// A saved contact, keyed `peer:<id>` like the agent's conversation records.
public struct AgentContactPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// How the agent reaches it, in a line.
    public let via: String
    /// A saved connection stays visible even when it cannot initiate a turn.
    public var sendRestriction: String? = nil
    /// Proven traffic counts even when its transcript is no longer retained.
    public var lastActivityAt: Date? = nil
    /// The Mac app behind it, when there is one, for its avatar.
    public var appBundleID: String? = nil
    /// Distinguishes desktop-app and routine connections sharing one app.
    public var link: Link? = nil
    /// Claude contacts wear Clawd instead of an app icon.
    public var clawd = false
    /// ChatGPT Dot uses its chat session rather than a conversation record.
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

/// Live progress, queued follow-ups and the stop on this send; nil when none is present.
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
                ?? preview.map { ": " + ContactThreadReadouts.firstLine($0) } ?? "")
            case .interrupted: return "Interrupted" + (entry.statusDetail.map { ": " + $0 }
                ?? preview.map { ": " + ContactThreadReadouts.firstLine($0) } ?? "")
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
        /// Uncompared record identities and stamp let live-only ticks re-read just flights.
        public var flightRecords: [String: String] = [:]
        public var recordsStamp: [SnapshotTailOpLog.FileStamp?] = []
        public init(contacts: [AgentContactPresentation], lines: [String: [AgentContactThreadLine]],
                    waiting: Set<String>, status: [String: AgentConversationDelivery],
                    flights: [String: AgentContactFlight], helpers: [BotsShelfRecord], running: Set<UUID>,
                    flightRecords: [String: String] = [:], recordsStamp: [SnapshotTailOpLog.FileStamp?] = [], otherRooms: [OtherRoomExchange] = []) {
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

    /// A file's identity, size and times; status changes include mode changes.
    private static func stamp(_ path: String) -> SnapshotTailOpLog.FileStamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : nil }
        return SnapshotTailOpLog.FileStamp(info)
    }

    /// The helper's `bot:<id>` key in conversation lines and waiting state.
    public static func key(_ helper: UUID) -> String { "bot:" + helper.uuidString }

    /// Resolve installed app icons from the contact's desktop address or known-agent row.
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
        let recordsStamp = threadStamp(root: root)
        let (doors, recordRead) = try await contactOwner.refreshDoors()
        let rows = doors.filter { $0.primary && $0.contact != nil }
        let dates = ISO8601DateFormatter()
        // The contact owner has already selected canonical rows and checked credentials.
        let restrictions = rows.map { row in
            AgentConversationDelivery.lane(for: row.key, dataRoot: root) != nil ? nil : sendRestriction(row)
        }
        let grouped = rows.indices.sorted { a, b in
            return restrictions[a] == nil && restrictions[b] != nil
        }
        var contacts = grouped.map { index in
            let row = rows[index]
            return AgentContactPresentation(id: row.id,
                                 name: row.name,
                                 via: via(row),
                                 sendRestriction: restrictions[index],
                                 lastActivityAt: [row.contact?.provenInboundAt, row.contact?.provenOutboundAt]
                                   .compactMap { $0.flatMap { dates.date(from: $0) } }.max(),
                                 appBundleID: appBundleID(row),
                                 link: link(row),
                                 clawd: isClaude(row),
                                 dot: row.contact.map(ChatGPTDotIPCTransport.owns) ?? false,
                                 health: row.health)
        }
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

        let records = try recordRead.get()
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
            let receipt = record.retainedReply
            for exchange in history {
                if let prompt = exchange.prompt, !prompt.isEmpty {
                    lines[id, default: []].append(.init(id: exchange.id + ":sent", fromAgent: true,
                        text: prompt, at: exchange.sentAt, byPerson: exchange.byPerson == true))
                }
                // The newest reply stays in the receipt until the next send folds it into history.
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
            let said = try ContactThread.mergedLines(dataRoot: root, owner: String(contact.id.dropFirst(5)),
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
                         recordsStamp: recordsStamp, otherRooms: HerScreen.otherRoomExchanges(dataRoot: root, identity: identity, since: .distantPast).map {
                             var event = $0
                             event.contactID = owner(event.contactID) ?? event.contactID
                             return event
                         })
    }

    private static func threadStamp(root: URL) -> [SnapshotTailOpLog.FileStamp?] {
        [stamp(root.appendingPathComponent("agents/conversations.json").path),
         stamp(root.appendingPathComponent("chat/sessions.json").path)]
    }

    /// Only the flights, for a tick of the live file alone. Nil when the
    /// records or chat index moved since the last full read.
    public static func readFlights(root: URL, last: Snapshot) -> [String: AgentContactFlight]? {
        let stamp = threadStamp(root: root)
        guard !stamp.contains(nil), stamp == last.recordsStamp,
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

}

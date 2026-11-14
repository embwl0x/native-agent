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
// Blueprint: | `ContactConversationReads.swift` | Canonical contact history, helper results and isolated live flights |

/// Use the same `peer:<id>` identity as conversation records.
public struct AgentContactPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let via: String
    /// A saved connection stays visible even when it cannot initiate a turn.
    public var sendRestriction: String? = nil
    /// The connection's program waits on the person's approval before it can start a turn.
    public var needsYou = false
    /// Retain proven traffic counts independently of transcript retention.
    public var lastActivityAt: Date? = nil
    public var appBundleID: String? = nil
    /// Distinguish desktop and routine connections that share one app.
    public var link: Link? = nil
    public var clawd = false
    /// Use the chat session for direct chat contacts.
    public var dot = false
    public var health: AgentLocalHealth? = nil
    public var recoveredFailure = false
    public var owedExperiences: [Experience] = []
    public var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    /// Share precedence across doors; leave dates and clipping to renderers.
    public func status(flight: AgentContactFlight?, waiting: Bool, delivery: AgentConversationDelivery?) -> String? {
        if let flight, !flight.inFlight, flight.queued.contains(where: { $0.waitingForMac }) {
            return "Waiting for the Mac to be free"
        }
        // These are sends of mine the contact has not answered: said that way round, so nobody reads them as messages I owe.
        if !owedExperiences.isEmpty {
            return owedExperiences.count == 1 ? "1 of my messages is unanswered" : "\(owedExperiences.count) of my messages are unanswered"
        }
        if let problem = health?.problem { return problem }
        if let flight {
            if flight.stop?.state == "stopping" { return "Stopping…" }
            if flight.stop?.state == "stopped", !flight.inFlight { return "Stopped" }
            if flight.working { return flight.partial != nil ? "Typing…" : "Working…" }
            if flight.queued.contains(where: { $0.state == .sending }) { return "Sending…" }
            if !flight.inFlight {
                if flight.queued.contains(where: { $0.state == .queued }) { return "Queued" }
                if flight.queued.contains(where: { if case .notSent = $0.state { true } else { false } }) { return "Not sent" }
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
        case .unanswered?: return "No reply"
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

public struct AgentContactThreadLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let fromAgent: Bool
    public let text: String
    /// Nil when this retained helper reply has no recorded completion time.
    public let at: Date?
    /// Distinguish the person’s typed message from the agent’s send.
    public var byPerson = false
    public var door: String? = nil
    public var fetched = false
    public var resultID: UUID? = nil
}

public struct AgentContactFlight: Equatable, Sendable {
    public let recordID: String
    public let agent: String
    public let label: String
    public let scope: String
    public let inFlight: Bool
    public var live: AgentConversationLive?
    public var queued: [Queued]
    /// Stop applies only to this send.
    public var stop: AgentConversationStop?

    public struct Queued: Identifiable, Equatable, Sendable {
        public enum State: Equatable, Sendable { case queued, sending, held(String), notSent(String) }
        public let id: String
        public let text: String
        public let at: Date
        public let byPerson: Bool
        public let state: State
        public var waitingForMac = false
        public var isPending: Bool { if case .notSent = state { false } else { true } }
    }

    public init?(_ record: AgentConversationRecord, live: AgentConversationLive?) {
        let queued = (record.queued ?? []).map { item in
            Queued(id: item.id, text: item.text, at: item.queuedAt, byPerson: item.byPerson == true,
                   state: item.notSentReason.map { .notSent($0) }
                       ?? item.held.map { .held($0) } ?? (item.id == record.queueReservation ? .sending : .queued),
                   waitingForMac: item.waitingForMac == true)
        }
        let stop = record.stop?.operationID == record.operationID ? record.stop : nil
        let inFlight = ["sending", "waiting"].contains(record.phase)
        guard live != nil || !queued.isEmpty || stop != nil else { return nil }
        (recordID, agent, label, scope) = (record.id, record.agent, record.label, record.scopeSessionID)
        (self.inFlight, self.live, self.queued, self.stop) = (inFlight, live, queued, stop)
    }

    public var working: Bool { inFlight && live?.state == "working" }
    public var partial: String? {
        guard working, live?.streams == true, let text = live?.partial?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return live?.partialTruncated == true ? "…" + text : text
    }
}

/// Scope shared desktop and phone reads to one root.
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

    /// Select by shelf identity; share Experience wording across doors.
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
        /// Retain uncompared identities so live-only ticks can skip unchanged records.
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

    /// Compute changes off the main actor; nil means unchanged.
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

    /// Include mode changes when comparing file status.
    private static func stamp(_ path: String) throws -> SnapshotTailOpLog.FileStamp {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return .absent }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
        }
        return SnapshotTailOpLog.FileStamp(info)
    }

    /// Use the same `bot:<id>` identity in conversation lines and waiting state.
    public static func key(_ helper: UUID) -> String { "bot:" + helper.uuidString }

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
        if needsApproval(row) { return "Reconnect to approve its program before sending a message." }
        if !contact.canStartTurn { return "Replies only" }
        return contact.unavailableAt != nil || !row.credentialAvailable ? "This connection is unavailable for sending." : nil
    }

    /// A connection that cannot start a turn until the person approves its program: neither Dot, whose readiness is its own, nor an MCP
    /// host, which only replies.
    private static func needsApproval(_ row: AgentContactRow) -> Bool {
        guard let contact = row.contact else { return false }
        return contact.transport != .mcpHost && !ChatGPTDotIPCTransport.owns(contact) && !contact.canStartTurn
    }

    public static func mobileThreads(root: URL, contacts: ContactListFacade) async throws -> [MobileAgentThread] {
        let snapshot = try await read(root: root, contacts: contacts, includeHelpers: false)
        return try snapshot.contacts.map { contact in
            let lines = snapshot.lines[contact.id] ?? []
            let status = contact.status(flight: snapshot.flights[contact.id],
                waiting: snapshot.waiting.contains(contact.id), delivery: snapshot.status[contact.id]) ?? ""
            let last = contact.latestLine(in: lines)
            var row = MobileAgentRow(id: contact.id, name: contact.name, via: contact.via,
                                     lastExchange: String((last?.text ?? "").prefix(240)), status: status,
                                     sendRestriction: contact.sendRestriction)
            row.experiences = contact.owedExperiences.map(\.mobile)
            row.lastActivityAt = [contact.lastActivityAt, last?.at].compactMap { $0 }.max()?.timeIntervalSince1970
            let flight = snapshot.flights[contact.id]
            let delivery = snapshot.status[contact.id]
            if flight?.inFlight == true || flight?.queued.contains(where: \.isPending) == true
                || snapshot.waiting.contains(contact.id) || !contact.owedExperiences.isEmpty {
                row.stateLine = "Waiting"
            } else if flight?.queued.contains(where: { !$0.isPending }) == true {
                row.stateLine = "Not sent"
            } else if contact.health?.problem != nil {
                row.stateLine = "Connection needs attention"
            } else {
                switch delivery {
                case .sending?, .waiting?: row.stateLine = "Waiting"
                case .failed?, .notDelivered?: row.stateLine = "Couldn’t reach"
                case .unanswered?: row.stateLine = "No reply yet"
                case .answered?: row.stateLine = "Replied"
                case .delivered?: row.stateLine = "Delivered"
                case .read?: row.stateLine = "Read"
                case nil:
                    row.stateLine = last.map { $0.fromAgent ? "Last message sent" : "Replied" }
                        ?? (contact.lastActivityAt == nil ? "No exchanges recorded" : "Last active")
                }
            }
            let tail = lines.suffix(32)
            return MobileAgentThread(agent: row, lines: try tail.map {
                // Publish canonical contact times only; optional helper times must not invent a date or drop a line.
                guard let at = $0.at else {
                    throw ToolFailureError("This contact message has no recorded time; preserve and repair its transcript.", effects: .none)
                }
                return MobileAgentLine(id: $0.id, speaker: $0.byPerson ? "You" : $0.fromAgent ? "Agent" : contact.name,
                                text: String($0.text.prefix(2_000)), at: at.timeIntervalSince1970)
            }, truncated: lines.count > tail.count || tail.contains { $0.text.count > 2_000 })
        }
    }

    public static func read(root: URL, contacts contactOwner: ContactListFacade, includeHelpers: Bool = true) async throws -> Snapshot {
        let recordsStamp = try threadStamp(root: root)
        let (doors, recordRead) = try await contactOwner.refreshDoors()
        let rows = doors.filter { $0.primary && $0.contact != nil }
        let restrictions = rows.map(sendRestriction)
        let grouped = rows.indices.sorted { a, b in
            return restrictions[a] == nil && restrictions[b] != nil
        }
        var contacts = grouped.map { index in
            let row = rows[index]
            return AgentContactPresentation(id: row.id,
                                 name: row.name,
                                 via: via(row),
                                 sendRestriction: restrictions[index],
                                 needsYou: needsApproval(row),
                                 lastActivityAt: [row.contact?.provenInboundAt, row.contact?.provenOutboundAt]
                                   .compactMap { $0.flatMap(NativeTimestampFormat.parseISO8601) }.max(),
                                 appBundleID: appBundleID(row),
                                 link: link(row),
                                 clawd: isClaude(row),
                                 dot: row.contact.map(ChatGPTDotIPCTransport.owns) ?? false,
                                 health: row.health)
        }
        let identity = try AgentContactIdentity(dataRoot: root)
        let displayed = Dictionary(contacts.map { (identity.canonical($0.id), $0.id) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(contacts.map(\.id))
        let dots = Set(contacts.filter(\.dot).map(\.id))
        func owner(_ agent: String) -> String? {
            if ids.contains(agent) { return agent }
            if let id = displayed[identity.canonical(agent)] { return id }
            // Helper thread identity is case-insensitive.
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
            // Direct chat contacts use their session rather than conversation records.
            guard let id = owner(record.agent), !dots.contains(id) else { continue }
            lastActive[id] = max(lastActive[id] ?? .distantPast, record.updatedAt)
            if record.updatedAt >= (latest[id]?.updatedAt ?? .distantPast) { latest[id] = record }
            // Contact records describe the current send; contact sessions own history, while helper records own theirs.
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
                        text: reply, at: exchange.settledAt,
                        resultID: exchange.id == record.operationID ? receipt?.resultID : exchange.resultID))
                }
            }
            if history.isEmpty, let receipt {
                replies[id, default: []].append(.init(id: record.id + ":reply", fromAgent: false,
                    text: receipt.text, at: record.sendEvidence["replied_at"]?.stringValue.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst),
                    resultID: receipt.resultID))
            }
        }
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
            // Sort dated messages chronologically; retain source order for unknown-time replies and show time unavailable.
            lines[key] = lines[key]?.enumerated().sorted { lhs, rhs in
                switch (lhs.element.at, rhs.element.at) {
                case let (a?, b?): return a == b ? lhs.offset < rhs.offset : a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }.map(\.element)
            if let at = lines[key]?.compactMap(\.at).max() { lastActive[key] = max(lastActive[key] ?? .distantPast, at) }
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
            if let last = lines[id]?.last, let at = last.at, at > record.updatedAt {
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
        // The direct chat session owns its wait; inbound-only contacts retain contact state without an owed reply.
        for id in dots where ChatGPTDotIPCTransport.available {
            guard let last = lines[id]?.last, last.fromAgent, let at = last.at else { continue }
            if case .object(let reply) = AgentConversationView.dotReply(.object([:]), sentAt: at), reply["terminal"] == .bool(true) {
                status[id] = .failed
            } else { waiting.insert(id) }
        }
        let live = latest.values.contains { ["sending", "waiting"].contains($0.phase) }
            ? try AgentConversationLiveStore(dataRoot: root).all() : [:]
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
        let helpers = includeHelpers ? try await NativeAgentEngine.forRoot(root).botsShelfRead() : []
        let running = try BotRunQueue(dataRoot: root).activeOrQueuedIDs()
        return Snapshot(contacts: ordered, lines: lines, waiting: waiting, status: status, flights: flights,
                         helpers: helpers, running: running, flightRecords: latest.mapValues(\.id),
                         recordsStamp: recordsStamp,
                         otherRooms: try AgentScreen.otherRoomExchanges(dataRoot: root, identity: identity, since: .distantPast).map {
                             var event = $0
                             event.contactID = owner(event.contactID) ?? event.contactID
                             return event
                         })
    }

    private static func threadStamp(root: URL) throws -> [SnapshotTailOpLog.FileStamp?] {
        [try stamp(root.appendingPathComponent("agents/conversations.json").path),
         try stamp(root.appendingPathComponent("chat/sessions.json").path)]
    }

    /// Live-only reads require unchanged records and chat index; nil requests a full read.
    public static func readFlights(root: URL, last: Snapshot) throws -> [String: AgentContactFlight]? {
        let stamp = try threadStamp(root: root)
        guard stamp == last.recordsStamp else { return nil }
        let records = try AgentConversationStore(dataRoot: root).records()
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = last.flightRecords.values.contains { byID[$0].map { ["sending", "waiting"].contains($0.phase) } == true }
            ? try AgentConversationLiveStore(dataRoot: root).all() : [:]
        var flights: [String: AgentContactFlight] = [:]
        for (contact, id) in last.flightRecords {
            if let record = byID[id] { flights[contact] = AgentContactFlight(record, live: AgentConversationLiveStore.current(for: record, in: live)) }
        }
        return flights
    }

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

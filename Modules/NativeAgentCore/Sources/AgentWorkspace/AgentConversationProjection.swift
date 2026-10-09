import Foundation
import NativeAgentCore
import os
import PersistenceCore
import Transcripts

/// App-owned routing bookmarks, not another transcript or authority store.
/// The last receipt is a bounded cache; the adapter remains the evidence owner.
public struct AgentConversationRecord: Codable, Sendable {
    public var id: String
    public var scopeSessionID: String
    public var agent: String
    public var name: String
    public var label: String
    public var conversationID: String?
    public var readInput: [String: JSONValue]?
    public var receipt: JSONValue?
    public var phase: String
    public var operationID: String
    public var updatedAt: Date
    public var sourceSurface: String
    public var operationStartedAt: Date?
    public var automaticRead: Bool = false
    public var deliveryState: String?
    public var deliveryRunID: String?
    public var nextReadAt: Date?
    public var peerRouteFingerprint: String?
    public var replyRoute: [String: String]?
    public var selected: Bool = false
    public var exchanges: [AgentConversationExchange]?
    /// The current send was typed by the person in the contact's thread, so
    /// its answer settles here and never starts an agent turn.
    public var personInitiated: Bool?
    /// The current send wants an answer (a question or a request), fixed at
    /// send time. False for an FYI, a report or a receipt: once delivered it
    /// is done, never "waiting". Nil on records saved before 2026-09-25.
    public var expectsReply: Bool?
    /// Follow-ups written while a reply was still in flight, oldest first.
    /// Each goes by itself, in order, once the reply ahead of it settles.
    public var queued: [AgentConversationQueued]?
    /// A stop asked for on the in-flight reply (`agent_cancel`).
    public var stop: AgentConversationStop?
    /// The queued message taken to be sent next: the thread is its alone
    /// until that send begins.
    public var queueReservation: String?
    /// "<operation>:<phase>" whose settled result her own call already
    /// returned to her (a blocking lane's reply, an immediate failure), so it
    /// is no arrival. A later change on that send (a late reply) still is.
    public var shownInline: String?
    /// A built-in delegate's stall or bad outcome on the current send, held
    /// until the continuation tells her in this chat (once per event).
    public var notice: AgentConversationNotice?
    package init(id: String,
                 scopeSessionID: String,
                 agent: String,
                 name: String,
                 label: String,
                 conversationID: String? = nil,
                 readInput: [String: JSONValue]? = nil,
                 receipt: JSONValue? = nil,
                 phase: String,
                 operationID: String,
                 updatedAt: Date,
                 sourceSurface: String,
                 operationStartedAt: Date? = nil,
                 automaticRead: Bool = false,
                 deliveryState: String? = nil,
                 deliveryRunID: String? = nil,
                 nextReadAt: Date? = nil,
                 peerRouteFingerprint: String? = nil,
                 replyRoute: [String: String]? = nil,
                 selected: Bool = false,
                 exchanges: [AgentConversationExchange]? = nil,
                 personInitiated: Bool? = nil,
                 expectsReply: Bool? = nil,
                 queued: [AgentConversationQueued]? = nil,
                 stop: AgentConversationStop? = nil,
                 queueReservation: String? = nil,
                 shownInline: String? = nil,
                 notice: AgentConversationNotice? = nil) {
        self.id = id
        self.scopeSessionID = scopeSessionID
        self.agent = agent
        self.name = name
        self.label = label
        self.conversationID = conversationID
        self.readInput = readInput
        self.receipt = receipt
        self.phase = phase
        self.operationID = operationID
        self.updatedAt = updatedAt
        self.sourceSurface = sourceSurface
        self.operationStartedAt = operationStartedAt
        self.automaticRead = automaticRead
        self.deliveryState = deliveryState
        self.deliveryRunID = deliveryRunID
        self.nextReadAt = nextReadAt
        self.peerRouteFingerprint = peerRouteFingerprint
        self.replyRoute = replyRoute
        self.selected = selected
        self.exchanges = exchanges
        self.personInitiated = personInitiated
        self.expectsReply = expectsReply
        self.queued = queued
        self.stop = stop
        self.queueReservation = queueReservation
        self.shownInline = shownInline
        self.notice = notice
    }

}

/// One delegation event for her, in the chat the send came from.
public struct AgentConversationNotice: Codable, Sendable, Equatable {
    public var event: String
    public var text: String
    public init(event: String, text: String) { self.event = event; self.text = text }
}

/// A message waiting on its thread behind the reply in progress (09-25: a
/// second message used to be refused). Never dropped: it goes, or it stays
/// here `held` with the reason, and is never resent by itself after that.
public struct AgentConversationQueued: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var queuedAt: Date
    public var byPerson: Bool?
    public var held: String?
    package init(id: String,
                 text: String,
                 queuedAt: Date,
                 byPerson: Bool? = nil,
                 held: String? = nil) {
        self.id = id
        self.text = text
        self.queuedAt = queuedAt
        self.byPerson = byPerson
        self.held = held
    }

}

/// The thread's stop state for one operation: "stopping" (asked, the lane has
/// not confirmed), "stopped" (the reply ended because of it), "finished" (it
/// answered first), "released" (no stop exists, but its answer comes back on its
/// own, so the thread stops waiting), or "cannot_stop"
/// (this lane has no stop; the reply keeps coming).
public struct AgentConversationStop: Codable, Sendable, Equatable {
    public var state: String
    public var operationID: String
    public var at: Date
    public var detail: String
    package init(state: String,
                 operationID: String,
                 at: Date,
                 detail: String) {
        self.state = state
        self.operationID = operationID
        self.at = at
        self.detail = detail
    }

}


/// Bounded display history inside the routing bookmark. Never provider context,
/// replay input, settlement authority, or a replacement for the reply's owner.
public struct AgentConversationExchange: Codable, Sendable {
    public var id: String
    public var sentAt: Date
    public var prompt: String?
    public var reply: String?
    public var promptTruncated: Bool
    public var replyTruncated: Bool
    public var phase: String
    public var status: String
    /// Typed by the person in the contact's thread, not sent by the agent.
    public var byPerson: Bool?
    /// When the reply landed, or (with no reply) when the send settled. Nil
    /// on exchanges saved before 2026-09-25 and while it is still in flight.
    public var settledAt: Date?
    /// The agent's first sign of work on this send (text, a tool, bytes), if any.
    public var firstActivityAt: Date?

    package init(id: String,
                 sentAt: Date,
                 prompt: String? = nil,
                 reply: String? = nil,
                 promptTruncated: Bool,
                 replyTruncated: Bool,
                 phase: String,
                 status: String,
                 byPerson: Bool? = nil,
                 settledAt: Date? = nil,
                 firstActivityAt: Date? = nil) {
        self.id = id
        self.sentAt = sentAt
        self.prompt = prompt
        self.reply = reply
        self.promptTruncated = promptTruncated
        self.replyTruncated = replyTruncated
        self.phase = phase
        self.status = status
        self.byPerson = byPerson
        self.settledAt = settledAt
        self.firstActivityAt = firstActivityAt
    }

}

/// One contact's conversation with her lives in one chat session the contact
/// owns (User 10-01, "one brain, many doors"): what she sends it, what it says
/// to her, and the turns either one starts. Every view of the contact reads it.
public enum ContactThread {
    /// Every session a contact owns starts with this: its id, hashed.
    public static func prefix(owner: String) -> String { ChatSessionRetention.contactSessionPrefix(owner: owner) }

    /// The contact's own conversation (a peer's id, or a built-in lane's
    /// name); for a peer, the one its MCP door opens.
    public static func session(owner: String) -> String { prefix(owner: owner) + "mcp-" + owner }

    /// One thing said: hers (`mine`; the person's when `byPerson`) or the contact's.
    public struct Line: Sendable, Equatable {
        public let id: String
        public let mine: Bool
        public let text: String
        public let at: Date
        public let byPerson: Bool
        public var door: String? = nil
        public var fetched = false
    }

    /// Presentation-only union for Simple and home rows. Route readers use lines.
    /// Everything said between her and the contact, oldest first, from its
    /// sessions: the live logs and the copies each compaction kept, once each
    /// by message id (`tailBytes`: only the newest bytes of each live log).
    /// The contact's lines are the turns it sent and its saved replies; hers
    /// are her sends (each carries its send id) and her answers to turns it
    /// started. Her turn on one of its replies is her own: it went nowhere.
    public static func mergedLines(dataRoot: URL, owner: String, tailBytes: Int? = nil) throws -> [Line] {
        let identity = AgentContactIdentity(dataRoot: dataRoot)
        let owners = identity.owners(owner)
        var seen: Set<String> = []
        return try owners.flatMap { door -> [Line] in
            try lines(dataRoot: dataRoot, owner: door, tailBytes: tailBytes).map { line in
                var line = line
                if owners.count > 1 { line.door = identity.doors[identity.aliases["peer:" + door] == nil ? door : "peer:" + door] }
                return line
            }
        }.sorted { $0.at < $1.at }.filter { seen.insert($0.id).inserted }
    }

    /// Exact route history; directory counts must not include another door.
    public static func lines(dataRoot: URL, owner: String, tailBytes: Int? = nil) throws -> [Line] {
        let archived = tailBytes == nil ? try ChatSessionRetention.archivedTranscripts(dataRoot: dataRoot) : [:]
        let plan = try ChatSessionRetention.transcriptFiles(dataRoot: dataRoot, prefix: prefix(owner: owner), archived: archived)
        let key = "\(dataRoot.path)|\(owner)|\(tailBytes.map(String.init) ?? "")"
        let stamp = (plan.map(\.1) + [ContactReplyReads.url(dataRoot)]).map { fileStamp($0.path) }
        if let hit = cache.withLock({ $0[key] }), hit.stamp == stamp { return hit.lines }
        let fetched = ContactReplyReads.read(dataRoot)
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var seen: Set<String> = [], started: Set<String> = [], found: [(line: Line, run: String?)] = []
        for (session, file) in plan {
            guard let text = read(file, tailBytes: tailBytes) else { continue }
            for row in text.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
                      let role = object["role"] as? String, let id = object["id"] as? String, !seen.contains(id),
                      let content = object["content"] as? String else { continue }
                let metadata = object["metadata"] as? [String: Any]
                let origin = metadata?["origin"] as? [String: Any]
                let envelope = metadata?["envelope"] as? [String: Any]
                let run = object["runId"] as? String
                var said = content
                if role == "user" {
                    // A peer's turns come over the agent bridge; a built-in lane's carry its name.
                    guard envelope?["surface"] as? String == "agent-bridge" || origin?["agent"] as? String == owner else { continue }
                    // A reply handed to her, or a pull of Dot's room: her answer stays hers.
                    let handed = (origin?["replyTo"] as? String)?.hasPrefix("agent-conversation:") == true
                        || (envelope?["correlationId"] as? String)?.hasPrefix("dot-room:") == true
                    if !handed, let run { started.insert(run) }
                    said = bridgedText(content)
                    // The note under Dot's turn is for her, not his words.
                    if let note = said.range(of: "(Dot sees your answer only if", options: .backwards) {
                        said = said[..<note.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } else if role != "assistant" || !(metadata?["dotClientUserMessageID"] is String || run != nil) {
                    continue
                }
                seen.insert(id)
                guard !said.isEmpty else { continue }
                let at = (object["createdAt"] as? String).flatMap { dates.date(from: $0) } ?? .distantPast
                found.append((Line(id: id, mine: role == "assistant", text: said, at: at,
                                   byPerson: metadata?["byPerson"] as? Bool == true,
                                   fetched: role == "assistant" && fetched.contains { $0.session == session && $0.run == run }),
                              metadata?["dotClientUserMessageID"] is String ? nil : run))
            }
        }
        // A live reply's starting turn may now live only in compaction originals.
        let result = found.filter { !$0.line.mine || ($0.run.map(started.contains) ?? true) }
            .map(\.line).sorted { $0.at < $1.at }
        cache.withLock { $0[key] = (stamp, result) }
        return result
    }

    /// `lines` re-parsed every session file a contact owns on each Simple
    /// refresh, and a Codex state write alone asks for one (perf sweep
    /// 2026-10-05). Kept per owner until a file it read, or the reply reads,
    /// changes on disk.
    private static let cache = OSAllocatedUnfairLock<[String: (stamp: [String], lines: [Line])]>(initialState: [:])

    /// A file's identity, size and times; any write moves it.
    private static func fileStamp(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return path + " -" }
        return "\(path) \(info.st_ino) \(info.st_size) "
            + "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    /// A bridged turn without the bracketed notes the bridge puts on top (and
    /// the bare contact-metadata line replies carried before 09-25).
    public static func bridgedText(_ content: String) -> String {
        let text = BridgeRoutingPrefix.stripping(content)
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let first = rows.first?.trimmingCharacters(in: .whitespaces),
              first.isEmpty || (first.hasPrefix("[") && first.hasSuffix("]")) || (first.hasPrefix("{\"agent\"") && first.hasSuffix("}")) {
            rows = rows.dropFirst()
        }
        return rows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func read(_ file: URL, tailBytes: Int?) -> String? {
        guard let tailBytes else { return try? String(contentsOf: file, encoding: .utf8) }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard var data = try? handle.readToEnd() else { return nil }
        // The first line of a cut window is partial.
        if size > UInt64(tailBytes), let end = data.firstIndex(of: 0x0A) { data = data[data.index(after: end)...] }
        return String(data: data, encoding: .utf8)
    }

    public enum Entry: Sendable {
        /// A message to the contact: hers, or the person's from its thread.
        case send(owner: String, text: String, sendID: String, byPerson: Bool)
        /// The contact's answer to a send, when no turn of hers carries it there.
        case reply(owner: String, name: String, text: String, replyID: String, at: Date)

        var owner: String {
            switch self {
            case .send(let owner, _, _, _), .reply(let owner, _, _, _, _): owner
            }
        }
    }

    public typealias Writer = @Sendable (URL, Entry) async throws -> Void
    private static let writer = OSAllocatedUnfairLock<Writer?>(initialState: nil)

    /// The engine root, which owns the chat client that appends to a session.
    public static func installWriter(_ write: @escaping Writer) { writer.withLock { $0 = write } }

    /// Appends the entry to the contact's session. The thread's own record
    /// keeps the send either way; a failed append is logged, never retried.
    public static func write(_ entry: Entry, dataRoot: URL) async {
        guard let write = writer.withLock({ $0 }) else {
            nativeLog("ContactThread: no writer installed; a message with \(entry.owner) was not saved to its session")
            return
        }
        do { try await write(dataRoot, entry) }
        catch { nativeLog("ContactThread: a message with \(entry.owner) was not saved to its session: \(error)") }
    }
}

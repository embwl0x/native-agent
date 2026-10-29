import Foundation
import Darwin
import ChatToolParsing
import NativeAgentCore
import NativeAgentShared
import os
import PersistenceCore
import Transcripts
// Blueprint: | `AgentConversationProjection.swift` | `AgentConversationRecord`: `sendEvidence`, `sendStatus`, `sendFailed` and `sendReceipt` project one send outcome from its receipt, with failed dispatch above stale executor progress; reply expectation defaults true; `nextReadAt` schedules reads/delivery, not reply lifetime. Associated-door history projects through Transcripts' `ContactThread.project`; resumable work retains DataRootLife; other-life work reads stopped/restored. Selected history read and UTF-8 failures propagate as unavailable. |

/// App-owned routing bookmarks, not another transcript or authority store.
/// The last receipt is a bounded cache; the adapter remains the evidence owner.
public struct AgentConversationRecord: Codable, Sendable {
    /// A retained answer, unwrapping only a single job and preserving reply-key precedence.
    public var retainedReply: (text: String, resultID: UUID?)? {
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

    /// The send's receipt owns its outcome. A failed dispatch outranks stale
    /// executor progress carried beside it, including on older saved records.
    public var sendEvidence: [String: JSONValue] { Self.sendEvidence(receipt) }

    public static func sendEvidence(_ receipt: JSONValue?) -> [String: JSONValue] {
        guard case .object(let root)? = receipt else { return [:] }
        if Self.failedSend(root) { return root }
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { return job }
        return root
    }

    public var sendFailed: Bool { Self.failedSend(sendEvidence) }

    public var sendStatus: String {
        let evidence = sendEvidence
        if sendFailed { return "failed" }
        if case .string(let status)? = evidence["run_status"] ?? evidence["status"] ?? evidence["state"] { return status }
        return phase
    }

    public static func approvalWaits(_ status: String) -> Bool {
        ["waiting_approval", "waiting_for_approval", "waiting for approval", "approval_filed", "approval_required"].contains(status)
    }

    private static func failedSend(_ fields: [String: JSONValue]) -> Bool {
        let status = fields["status"]?.stringValue ?? ""
        // An approval or a held message has not failed dispatch.
        if ["held", "delivering"].contains(status) || approvalWaits(status) { return false }
        return fields["sent"] == .bool(false) || [.failed, .refused].contains(ChatToolOutcome.exactResultClass(.object(fields.filter { $0.key != "result" })))
            || fields["execution_error"]?.stringValue?.isEmpty == false
            || ["invalid_arguments", "no_reply_expired"].contains(status)
            || ["failed", "error"].contains(fields["run_status"]?.stringValue ?? "")
    }

    /// Receipt detail uses the same state word as home and history, while
    /// retaining the adapter's failure cause and other evidence.
    public var sendReceipt: JSONValue? {
        guard phase != "sending", sendFailed, case .object(var fields)? = receipt else { return receipt }
        fields["status"] = .string("failed")
        fields["delivery"] = .string("failed")
        if fields["sent"] == .bool(false) { fields["delivered"] = .bool(false) }
        if fields["run_status"] != nil { fields["run_status"] = .string("failed") }
        return .object(fields)
    }

    public var lifeID: String?
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
    /// Deadline for an eligible automatic read or delivery, not a reply lifetime.
    public var nextReadAt: Date?
    public var peerRouteFingerprint: String?
    public var replyRoute: [String: String]?
    public var selected: Bool = false
    public var exchanges: [AgentConversationExchange]?
    /// Sends the bounded ledger let go whose last state is not yet on their
    /// own transcript row: the evidence stays here until it is (`Entry.state`).
    public var releasing: [AgentConversationExchange]?
    /// The current send was typed by the person in the contact's thread, so
    /// its answer settles here and never starts an agent turn.
    public var personInitiated: Bool?
    /// Fixed at send time: explicit sender choice, otherwise true; saved records may omit it.
    public var expectsReply: Bool?
    /// Follow-ups written while a reply was still in flight, oldest first.
    /// Each goes by itself, in order, once the reply ahead of it settles.
    public var queued: [AgentConversationQueued]?
    /// Exact terminal transitions, committed with the conversation that removed them.
    public var settledObligations: [String: [String: Experience.Obligation]]?
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
    /// Who said the reply its receipt caches, as the writer stamped it: the
    /// answering turn's door and steering when one wrote it there
    /// (`reply_from`, `reply_steered_by`), else the route this record's
    /// transport read, which is what the app wrote the receipt from.
    public var cachedReplyStamp: TranscriptRowStamp {
        guard case .object(let receipt)? = receipt, case .string(let from)? = receipt["reply_from"] else { return .init(source: agent, steeredBy: [], contact: true) }
        let steering: [String] = if case .array(let values)? = receipt["reply_steered_by"] {
            values.compactMap { if case .string(let peer) = $0 { peer } else { nil } }
        } else { [] }
        return .init(source: from, steeredBy: steering, contact: true)
    }

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
    public var lifeID: String?
    public var id: String
    public var text: String
    public var queuedAt: Date
    public var byPerson: Bool?
    public var arguments: [String: JSONValue]?
    public var held: String?
    package init(id: String,
                 text: String,
                 queuedAt: Date,
                 byPerson: Bool? = nil,
                 arguments: [String: JSONValue]? = nil,
                 held: String? = nil) {
        self.id = id
        self.text = text
        self.queuedAt = queuedAt
        self.byPerson = byPerson
        self.arguments = arguments
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
    public var lifeID: String?
    public var id: String
    public var sentAt: Date
    public var prompt: String?
    public var reply: String?
    /// The shelf result this reply belongs to, retained when the next send starts.
    public var resultID: UUID?
    public var partialReply: String?
    public var promptTruncated: Bool
    public var replyTruncated: Bool
    public var phase: String
    public var status: String
    /// Typed by the person in the contact's thread, not sent by the agent.
    public var byPerson: Bool?
    /// Reply arrival or send settlement time; nil while in flight or when unrecorded.
    public var settledAt: Date?
    /// The agent's first sign of work on this send (text, a tool, bytes), if any.
    public var firstActivityAt: Date?
    /// The card this send waits on, kept so a decision made after the record
    /// moved on to a newer send still settles this one.
    public var approvalId: String?

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
/// owns: what she sends it, what it says to her, and the turns either one starts.
/// Every view of the contact reads it.
public typealias ContactThread = Transcripts.ContactThread

extension ContactThread {
    /// Every session a contact owns starts with this: its id, hashed.
    public static func prefix(owner: String) -> String { ChatSessionRetention.contactSessionPrefix(owner: owner) }

    /// A transcript message id a history page or selection may name: bounded,
    /// letters, digits and hyphens (a row's UUID, or an imported `<UUID>-sent`).
    /// Which message it is resolves by exact membership in the contact's lines.
    public static func isMessageID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// The contact's own conversation (a peer's id, or a built-in lane's
    /// name); for a peer, the one its MCP door opens.
    public static func session(owner: String) -> String { prefix(owner: owner) + "mcp-" + owner }

    /// Presentation-only union for Simple and home rows. Route readers use lines.
    /// Everything said between her and the contact, oldest first, from its
    /// sessions: the live logs and the copies each compaction kept, once each
    /// by message id (`tailBytes`: only the newest bytes of each live log).
    /// The contact's lines are the turns it sent and its saved replies; hers
    /// are her sends (each carries its send id) and her answers to turns it
    /// started. Her turn on one of its replies is her own: it went nowhere.
    public static func mergedLines(dataRoot: URL, owner: String, tailBytes: Int? = nil, identity: AgentContactIdentity,
                                   transcripts: [(String, URL)]? = nil) throws -> [Line] {
        let owners = identity.owners(owner)
        var seen: Set<String> = []
        return try owners.flatMap { door -> [Line] in
            try lines(dataRoot: dataRoot, owner: door, tailBytes: tailBytes, transcripts: transcripts).map { line in
                var line = line
                // The door a contact's line came through is the one its own row attests.
                if owners.count > 1 { line.door = line.source.flatMap { identity.doors[$0] } }
                return line
            }
        }.sorted { $0.at < $1.at }.filter { seen.insert($0.id).inserted }
    }

    /// Exact route history; directory counts must not include another door.
    public static func lines(dataRoot: URL, owner: String, tailBytes: Int? = nil, transcripts: [(String, URL)]? = nil) throws -> [Line] {
        let ownerPrefix = prefix(owner: owner)
        let plan = try transcripts?.filter { $0.0.hasPrefix(ownerPrefix) }
            ?? ChatSessionRetention.transcriptFiles(dataRoot: dataRoot, prefix: ownerPrefix,
                archived: tailBytes == nil ? ChatSessionRetention.archivedTranscripts(dataRoot: dataRoot) : [:])
        let key = "\(dataRoot.path)|\(owner)|\(tailBytes.map(String.init) ?? "")"
        let paths = plan.map(\.1) + [ContactReplyReads.url(dataRoot)]
        let stamp = paths.map { fileStamp($0.path) }
        if !stamp.contains(nil), let hit = cache.withLock({ $0[key] }), hit.paths == paths, hit.stamp == stamp { return hit.lines }
        let fetched = ContactReplyReads.read(dataRoot)
        var rows: [Line] = []
        for (session, file) in plan {
            let text = try read(file, tailBytes: tailBytes)
            for raw in text.split(separator: "\n") {
                guard case .object(let object)? = try? JSONValue.parse(Data(raw.utf8)),
                      case .string? = object["id"], case .string? = object["content"],
                      case .string(let role)? = object["role"], role == "user" || role == "assistant" else { continue }
                var line = Line(object, role: role)
                line.fetched = line.mine && fetched.contains { $0.session == session && $0.run == line.run }
                rows.append(line)
            }
        }
        let result = project(rows, style: .thread, thread: owner).sorted { $0.at < $1.at }
        cache.withLock { $0[key] = (paths, stamp, result) }
        return result
    }

    /// Cache each owner's transcript lines until a session or reply file changes.
    private static let cache = OSAllocatedUnfairLock<[String: (paths: [URL], stamp: [SnapshotTailOpLog.FileStamp?], lines: [Line])]>(initialState: [:])

    /// A file's identity, size and times; any write moves it.
    private static func fileStamp(_ path: String) -> SnapshotTailOpLog.FileStamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : nil }
        return SnapshotTailOpLog.FileStamp(info)
    }

    /// Unreadable or undecodable selected history is unavailable, never empty.
    private static func read(_ file: URL, tailBytes: Int?) throws -> String {
        guard let tailBytes else { return try String(contentsOf: file, encoding: .utf8) }
        guard tailBytes > 0 else {
            throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: file.path])
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        var data = try handle.readToEnd() ?? Data()
        // The first line of a cut window is partial.
        if size > UInt64(tailBytes), let end = data.firstIndex(of: 0x0A) { data = data[data.index(after: end)...] }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: file.path])
        }
        return text
    }

    public enum Entry: Sendable {
        /// A message to the contact: hers, or the person's from its thread.
        case send(owner: String, text: String, sendID: String, byPerson: Bool)
        /// The contact's answer to a send, when no turn of hers carries it there.
        /// `from` and `steeredBy` are the stamp of whoever said it, as its own
        /// transport attested it (the route a read went to, or the door whose
        /// turn carried it); `owner` only places it.
        case reply(owner: String, name: String, text: String, replyID: String, at: Date, from: String, steeredBy: [String])
        /// A send's last state, kept on its own row when the record's bounded
        /// ledger lets the send go: the evidence stays with the send.
        case state(owner: String, sendID: String, status: String)

        var owner: String {
            switch self {
            case .send(let owner, _, _, _), .reply(let owner, _, _, _, _, _, _), .state(let owner, _, _): owner
            }
        }
    }

    public typealias Writer = @Sendable (URL, Entry) async throws -> Void
    private static let writer = OSAllocatedUnfairLock<Writer?>(initialState: nil)

    /// The engine root, which owns the chat client that appends to a session.
    public static func installWriter(_ write: @escaping Writer) { writer.withLock { $0 = write } }

    /// Appends the entry to the contact's session. The thread's own record
    /// keeps the send either way; a failed append is logged.
    public static func write(_ entry: Entry, dataRoot: URL) async {
        do { try await attempt(entry, dataRoot: dataRoot) }
        catch { nativeLog("ContactThread: a message with \(entry.owner) was not saved to its session: \(error)") }
    }

    /// The same write, its failure the caller's to report.
    public static func attempt(_ entry: Entry, dataRoot: URL) async throws {
        guard let write = writer.withLock({ $0 }) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "no conversation writer is installed yet"])
        }
        try await SessionConversation.declare(session(owner: entry.owner), kind: .agent,
            title: entry.owner, source: "agent-bridge", dataRoot: dataRoot, createIfMissing: false)
        try await write(dataRoot, entry)
    }
}

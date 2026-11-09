import Foundation
import Darwin
import ChatToolParsing
import NativeAgentCore
import NativeAgentShared
import os
import PersistenceCore
import Transcripts
// Blueprint: | `AgentConversationProjection.swift` | `AgentConversationRecord`, `sendEvidence`, `sendStatus`, `sendFailed`, `sendReceipt`, `AgentConversationExchange.messageID`, `nextReadAt`, `ContactThread.project` |
// nextReadAt bounds eligible read/delivery scheduling, never reply lifetime.
// Resumable work retains DataRootLife; other-life work reads stopped/restored, and selected history failures stay unavailable.

/// App-owned routing bookmarks, not another transcript or authority store. The last receipt is a bounded cache; the adapter remains the evidence owner.
public struct AgentConversationRecord: Codable, Sendable, Equatable {
    public var retainedReply: (text: String, resultID: UUID?)? {
        guard case .object(let value)? = receipt else { return nil }
        for key in ["reply", "answer"] {
            if case .string(let text)? = value[key], !text.isEmpty {
                let id: UUID? = if case .string(let id)? = value["entry_id"] ?? value["message_id"] { UUID(uuidString: id) } else { nil }
                return (text, id)
            }
        }
        return nil
    }

    /// The receipt owns send outcome; failed dispatch outranks cached executor progress.
    public var sendEvidence: [String: JSONValue] { Self.sendEvidence(receipt) }

    public static func sendEvidence(_ receipt: JSONValue?) -> [String: JSONValue] {
        guard case .object(let root)? = receipt else { return [:] }
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
        if fields["run_status"] == .string("observation_unavailable")
            || status == "observation_unavailable" { return false }
        // An approval or a held message has not failed dispatch.
        if ["held", "delivering"].contains(status) || approvalWaits(status) { return false }
        let reply = ToolResult(.object(fields.filter { $0.key != "result" }))
        return fields["sent"] == .bool(false) || [.failed, .refused].contains(reply.outcome)
            || fields["execution_error"]?.stringValue?.isEmpty == false
            || status == "invalid_arguments"
            || ["failed", "error"].contains(fields["run_status"]?.stringValue ?? "")
    }

    /// Receipt detail uses the same state word as home and history, while retaining the adapter's failure cause and other evidence.
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
    /// Retain unsettled transcript states until the send's own row carries the evidence (`Entry.state`).
    public var releasing: [AgentConversationExchange]?
    /// The current send was typed by the person in the contact's thread, so its answer settles here and never starts an agent turn.
    public var personInitiated: Bool?
    /// Fix reply expectation at send time; an omitted sender choice means true.
    public var expectsReply: Bool?
    /// Follow-ups wait in order for the preceding reply to settle.
    public var queued: [AgentConversationQueued]?
    /// Commit terminal transitions with the conversation that removes them.
    public var settledObligations: [String: [String: Experience.Obligation]]?
    public var stop: AgentConversationStop?
    /// The queued message owns the thread until its send begins.
    public var queueReservation: String?
    /// Already-returned settlements are not arrivals; a later change on the same send still is.
    public var shownInline: String?
    /// A built-in delegate's stall or bad outcome on the current send, held until the continuation tells the agent in this chat (once per event).
    public var notice: AgentConversationNotice?
    /// Reply attribution comes from the answering turn's stamp or the exact transport that supplied its receipt.
    public var cachedReplyStamp: TranscriptRowStamp {
        guard case .object(let receipt)? = receipt, case .string(let from)? = receipt["reply_from"] else { return .init(source: agent, steeredBy: [],
            contact: true) }
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

public struct AgentConversationNotice: Codable, Sendable, Equatable {
    public var event: String
    public var text: String
    public init(event: String, text: String) { self.event = event; self.text = text }
}

/// Only a pre-Return Mac hold can resume; a saved refusal is terminal evidence that this message was not sent.
public struct AgentConversationQueued: Codable, Sendable, Equatable {
    public var lifeID: String?
    public var id: String
    /// This send's caller, independent of the conversation's active exchange.
    public var scopeSessionID: String?
    public var text: String
    public var queuedAt: Date
    public var byPerson: Bool?
    public var arguments: [String: JSONValue]?
    public var held: String?
    public var notSentReason: String? { waitingForMac == true ? nil : held }
    /// No Return was emitted. The conversation's release drain can unhold this send.
    public var waitingForMac: Bool?
    package init(id: String,
                 scopeSessionID: String,
                 text: String,
                 queuedAt: Date,
                 byPerson: Bool? = nil,
                 arguments: [String: JSONValue]? = nil,
                 held: String? = nil) {
        self.id = id
        self.scopeSessionID = scopeSessionID
        self.text = text
        self.queuedAt = queuedAt
        self.byPerson = byPerson
        self.arguments = arguments
        self.held = held
    }

}

/// Stop remains unconfirmed until the route reports stopped or finished; releasing a wait does not stop its reply.
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


/// Bounded display history inside the routing bookmark. Never provider context, replay input or a replacement for the reply's owner. Experience settlement
/// reads its retained reply/status as evidence; eviction supplies no acceptance.
public struct AgentConversationExchange: Codable, Sendable, Equatable {
    public var lifeID: String?
    public var id: String
    /// Bind the protocol's opaque message identity once; it is independent of the operation UUID.
    public var messageID: String?
    public var sentAt: Date
    public var prompt: String?
    public var reply: String?
    /// Keep the shelf binding across subsequent sends.
    public var resultID: UUID?
    public var partialReply: String?
    public var promptTruncated: Bool
    public var replyTruncated: Bool
    public var phase: String
    public var status: String
    /// Person-typed sends must not start an agent turn on reply.
    public var byPerson: Bool?
    public var settledAt: Date?
    public var firstActivityAt: Date?
    /// The card this send waits on, kept so a decision made after the record moved on to a newer send still settles this one.
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

/// Every contact view reads the same contact-owned chat session.
public typealias ContactThread = Transcripts.ContactThread

extension ContactThread {
    public static func prefix(owner: String) -> String { ChatSessionRetention.contactSessionPrefix(owner: owner) }

    /// Resolve a bounded message selector by exact membership, never by its spelling alone.
    public static func isMessageID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// The contact's own conversation's session.
    public static func session(owner: String) -> String { session(owner: owner, conversation: nil) }

    /// One session per conversation the contact opened by calling in (its own, or one caller's); every other conversation with it lives in the
    /// contact's own session.
    public static func session(owner: String, conversation: String?) -> String {
        prefix(owner: owner) + (ContactCaller.held(conversation, peer: owner) ?? ContactCaller.shared(peer: owner))
    }

    /// Presentation-only union for Simple and home rows. Route readers use lines. Everything said between the agent and the contact, oldest first, from its
    /// sessions: the live and archived logs, once each by message id (`tailBytes`: only the newest bytes of each live log). The contact's lines
    /// are the turns it sent and its saved replies; the agent's are its sends (each carries its send id) and its answers to turns the contact started. The
    /// agent's turn on one of its replies is its own: it went nowhere.
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
        let fetched = try ContactReplyReads.read(dataRoot)
        var rows: [Line] = []
        for (session, file) in plan {
            let text = try read(file, tailBytes: tailBytes)
            for raw in text.split(separator: "\n") {
                guard case .object(let object) = try JSONValue.parse(Data(raw.utf8)) else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
                }
                guard case .string(let role)? = object["role"], role == "user" || role == "assistant" else { continue }
                guard case .string? = object["id"], case .string? = object["content"] else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
                }
                var line = Line(object, role: role)
                guard line.date != nil else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path]) }
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

    private static func fileStamp(_ path: String) -> SnapshotTailOpLog.FileStamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : nil }
        return SnapshotTailOpLog.FileStamp(info)
    }

    /// Unreadable or undecodable selected history is unavailable, never empty.
    private static func read(_ file: URL, tailBytes: Int?) throws -> String {
        guard tailBytes.map({ $0 > 0 }) ?? true else {
            throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: file.path])
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = tailBytes.map { size > UInt64($0) ? size - UInt64($0) : 0 } ?? 0
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()
        // The cut window may start mid-line.
        if offset > 0, let end = data.firstIndex(of: 0x0A) { data = data[data.index(after: end)...] }
        if let end = data.lastIndex(of: 0x0A) { data = data[..<data.index(after: end)] }
        else { data = Data() } // The writer has not completed a physical row yet.
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: file.path])
        }
        return text
    }

    /// Each entry names the conversation it belongs to (its record's `conversationID`); `session` places it in that conversation's session.
    public enum Entry: Sendable {
        case send(owner: String, conversation: String?, text: String, sendID: String, byPerson: Bool, turn: Turn)
        /// Reply attribution follows its transport stamp; `owner` and `conversation` only place the line.
        case reply(owner: String, conversation: String?, name: String, text: String, replyID: String, at: Date, from: String, steeredBy: [String])
        /// A send's last state, kept on its own row when the record's bounded ledger lets the send go: the evidence stays with the send.
        case state(owner: String, conversation: String?, sendID: String, status: String)

        var owner: String {
            switch self {
            case .send(let owner, _, _, _, _, _), .reply(let owner, _, _, _, _, _, _, _), .state(let owner, _, _, _): owner
            }
        }

        public var session: String {
            switch self {
            case .send(let owner, let conversation, _, _, _, _), .reply(let owner, let conversation, _, _, _, _, _, _),
                 .state(let owner, let conversation, _, _): ContactThread.session(owner: owner, conversation: conversation)
            }
        }
    }

    public typealias Writer = @Sendable (URL, Entry) async throws -> Void
    private static let writer = OSAllocatedUnfairLock<Writer?>(initialState: nil)

    /// The engine root, which owns the chat client that appends to a session.
    public static func installWriter(_ write: @escaping Writer) { writer.withLock { $0 = write } }

    /// Keep the send record even when transcript append fails; log that failure.
    public static func write(_ entry: Entry, dataRoot: URL) async {
        do { try await attempt(entry, dataRoot: dataRoot) }
        catch { nativeLog("ContactThread: a message with \(entry.owner) was not saved to its session: \(error)") }
    }

    /// The caller must report append failure.
    public static func attempt(_ entry: Entry, dataRoot: URL) async throws {
        guard let write = writer.withLock({ $0 }) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "no conversation writer is installed yet"])
        }
        try await SessionConversation.declare(entry.session, kind: .agent,
            title: entry.owner, source: "agent-bridge", dataRoot: dataRoot, createIfMissing: false)
        try await write(dataRoot, entry)
    }
}

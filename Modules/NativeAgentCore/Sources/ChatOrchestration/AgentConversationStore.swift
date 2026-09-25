import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

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
}

public enum AgentConversationContext {
    /// Suppresses only the conversational facade for an owner recovery read.
    /// The complete original tool permission chain still executes.
    @TaskLocal public static var isInternalRead = false
}

public struct AgentConversationStore: Sendable {
    public let fileURL: URL
    public init(dataRoot: URL) { fileURL = dataRoot.appendingPathComponent("agents/conversations.json") }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public func records() throws -> [AgentConversationRecord] {
        try locked { try load() }
    }

    /// Read-only and without the lock, for a glance that must not wait; a
    /// file caught mid-write fails to decode and throws.
    public func recordsUnlocked() throws -> [AgentConversationRecord] { try load() }

    public func find(scopeSessionID: String, agent: String, label: String?) throws -> AgentConversationRecord? {
        let rows = try records()
        return try select(rows, scope: scopeSessionID, agent: agent, label: label)
            ?? Self.continuing(rows, agent: agent, label: label)
    }

    /// A contact's conversation is the agent's, not one chat's (User 09-22):
    /// when this chat has none, the newest main thread from any chat is the
    /// one to continue, so "pull up Codex" lands on the real discussion.
    static func continuing(_ rows: [AgentConversationRecord], agent: String, label: String?) -> AgentConversationRecord? {
        rows.filter { row in
            guard row.agent == agent else { return false }
            if let label { return row.label.caseInsensitiveCompare(label) == .orderedSame }
            return row.label == "Main" || row.selected
        }.max { $0.updatedAt < $1.updatedAt }
    }

    /// Reserve before dispatch. Never run two messages against one bookmark.
    /// A crash leaves a visible uncertain send, never permission to replay it.
    public func begin(scopeSessionID: String, agent: String, name: String, label: String?,
                      fresh: Bool, sourceSurface: String, fingerprint: String?,
                      replyRoute: [String: String]?, message: String? = nil,
                      legacyFingerprint: String? = nil, personInitiated: Bool = false,
                      supersedeWaiting: Bool = false) throws -> AgentConversationRecord {
        guard !scopeSessionID.isEmpty, scopeSessionID.utf8.count <= 256,
              label == nil || (label!.count <= 120 && !label!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            throw Failure(message: "Choose a short conversation name.")
        }
        return try locked {
            var rows = try load()
            let old = try select(rows, scope: scopeSessionID, agent: agent, label: label)
                ?? (fresh ? nil : Self.continuing(rows, agent: agent, label: label))
            // An accepted ask its peer never answered (Grok Bot) may be superseded;
            // an unsettled send never is.
            if !fresh, let old, old.phase == "sending" || (old.phase == "waiting" && !supersedeWaiting) {
                throw Failure(message: "This conversation is still waiting for its previous message. Open it to see the current state; do not send that message again.")
            }
            if !fresh, let old, old.peerRouteFingerprint != fingerprint,
               legacyFingerprint == nil || old.peerRouteFingerprint != legacyFingerprint {
                throw Failure(message: "This contact's connection changed. Start a separate conversation explicitly; the existing conversation has been preserved.")
            }
            if fresh, label != nil, old != nil {
                throw Failure(message: "That conversation name is already in use. Choose a different name for a separate conversation.")
            }
            var row: AgentConversationRecord
            if !fresh, let old {
                row = old
                // Continuing from another chat moves the thread here, like
                // dragging a window onto the desktop that is in front.
                row.scopeSessionID = scopeSessionID
            } else {
                guard rows.count < 512 else { throw Failure(message: "The saved conversation limit has been reached.") }
                let id = UUID().uuidString.lowercased()
                row = AgentConversationRecord(id: id, scopeSessionID: scopeSessionID, agent: agent, name: name,
                    label: label ?? (fresh ? "Conversation " + String(id.prefix(8)) : "Main"),
                    phase: "ready", operationID: id, updatedAt: Date(), sourceSurface: sourceSurface)
            }
            try Self.absorbExchange(into: &row)
            row.operationID = UUID().uuidString.lowercased()
            row.phase = "sending"
            row.updatedAt = Date()
            row.operationStartedAt = row.updatedAt
            row.exchanges = try AgentConversationExchange.bounded((row.exchanges ?? []) + [
                .started(operationID: row.operationID, at: row.updatedAt, message: message, byPerson: personInitiated)
            ])
            row.personInitiated = personInitiated ? true : nil
            row.sourceSurface = sourceSurface
            row.peerRouteFingerprint = fingerprint
            row.replyRoute = replyRoute
            row.automaticRead = false
            row.readInput = nil
            row.deliveryState = nil
            row.deliveryRunID = nil
            row.nextReadAt = nil
            if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i] = row }
            else { rows.append(row) }
            try save(rows)
            return row
        }
    }

    /// `touch: false` (a read) moves updatedAt only when the phase or the
    /// newest reply changed, so opening a conversation never reads as news.
    @discardableResult public func update(id: String, operationID: String, touch: Bool = true,
        edit: (inout AgentConversationRecord) throws -> Void) throws -> AgentConversationRecord {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id && $0.operationID == operationID }) else {
                throw Failure(message: "This conversation has moved on; the older result was not applied.")
            }
            let identity = rows[i]
            try edit(&rows[i])
            guard rows[i].id == identity.id, rows[i].agent == identity.agent,
                  rows[i].scopeSessionID == identity.scopeSessionID,
                  rows[i].operationID == operationID else { throw Failure(message: "Conversation identity cannot change.") }
            try Self.absorbExchange(into: &rows[i])
            if touch || rows[i].phase != identity.phase || rows[i].exchanges?.last?.reply != identity.exchanges?.last?.reply {
                rows[i].updatedAt = Date()
            }
            if rows[i].selected {
                for j in rows.indices where j != i && rows[j].scopeSessionID == rows[i].scopeSessionID && rows[j].agent == rows[i].agent {
                    rows[j].selected = false
                }
            }
            try save(rows)
            return rows[i]
        }
    }

    /// Project already-read terminal owner evidence into waiting bookmarks.
    /// The existing delegation event runner supplies one complete snapshot;
    /// this never reads another store, sends, selects, or creates a conversation.
    @discardableResult public func reconcileDelegationReplies(_ jobs: [DelegationJobProjection]) throws -> Int {
        try locked {
            var rows = try load()
            var changed = 0
            for index in rows.indices {
                let row = rows[index]
                guard ["waiting", "attention"].contains(row.phase), !row.automaticRead,
                      ["codex", "claude", "omp"].contains(row.agent),
                      row.readInput?["agent"] == .string(row.agent),
                      case .string(let messageID)? = row.readInput?["message_id"],
                      !messageID.isEmpty else { continue }
                // Match the accepted message, never an internal job ID, topic
                // or newest record. Ambiguous retained/delivery evidence stays
                // with its owner for an explicit read.
                let matches = jobs.filter { $0.agent == row.agent && $0.acceptedMessageIDs.contains(messageID) }
                guard matches.count == 1, let job = matches.first,
                      job.stallBasis == .terminal,
                      case .object(var result) = job.toJSON(includeReplyText: true) else { continue }
                result["matched_message_id"] = .string(messageID)
                let receipt = JSONValue.object(["status": .string("ok"), "jobs": .array([.object(result)])])
                var next = row
                AgentConversationSession.absorb(receipt, into: &next)
                // Only terminal transitions are written. In particular an
                // unchanged/in-progress snapshot cannot self-trigger this
                // file-watched runner, and a later read retains its full receipt.
                // A live hand-off stays waiting (its answer is a chat); its receipt is written once.
                guard (next.phase != "waiting" && next.phase != row.phase)
                        || (AgentConversationSession.liveHandOff(next) && !AgentConversationSession.liveHandOff(row)) else { continue }
                next.updatedAt = Date()
                try Self.absorbExchange(into: &next)
                rows[index] = next
                changed += 1
            }
            if changed > 0 { try save(rows) }
            return changed
        }
    }

    // 2026-09-22 WHY: the program path is not the route. An auto-updated
    // Hermes/Cursor/Goose reconnects at a new path and keeps its threads;
    // the reconnect itself still pins and verifies the new program.
    public static func routeFingerprint(_ peer: AgentPeerContact) -> String {
        fingerprint(peer, program: "")
    }

    /// Rows saved before 2026-09-22 also hashed the program path.
    public static func sameRoute(_ saved: String?, _ peer: AgentPeerContact?) -> Bool {
        guard let peer else { return saved == nil }
        return saved == routeFingerprint(peer) || saved == legacyRouteFingerprint(peer)
    }

    static func legacyRouteFingerprint(_ peer: AgentPeerContact) -> String {
        fingerprint(peer, program: peer.approvedExecutablePath ?? "")
    }

    private static func fingerprint(_ peer: AgentPeerContact, program: String) -> String {
        let fields = [peer.transport.rawValue, peer.endpoint.absoluteString, peer.acpWorkingDirectory ?? "", program]
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func cacheReceipt(_ value: JSONValue) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value), data.count <= 96 * 1024 else {
            return .object(["status": .string("receipt_too_large"),
                "detail": .string("The full result remains with its original owner. Open the conversation to recover it.")])
        }
        return value
    }

    private static func absorbExchange(into row: inout AgentConversationRecord) throws {
        guard row.phase != "sending", var history = row.exchanges,
              let index = history.firstIndex(where: { $0.id == row.operationID }) else { return }
        history[index].absorb(row)
        row.exchanges = try AgentConversationExchange.bounded(history)
    }

    private func select(_ rows: [AgentConversationRecord], scope: String, agent: String, label: String?) throws -> AgentConversationRecord? {
        let matches = rows.filter { $0.scopeSessionID == scope && $0.agent == agent }
        if let label { return matches.first { $0.label.caseInsensitiveCompare(label) == .orderedSame } }
        if let selected = matches.first(where: { $0.selected }) { return selected }
        guard matches.count <= 1 else {
            throw Failure(message: "Choose a conversation: " + matches.map(\.label).joined(separator: ", "))
        }
        return matches.first
    }

    private func locked<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return try CredentialFileLock.withLock(fileURL, work)
    }
    private func load() throws -> [AgentConversationRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 50 * 1024 * 1024 else { throw Failure(message: "Saved conversations are too large to read safely.") }
        let rows = try JSONDecoder().decode([AgentConversationRecord].self, from: data)
        guard rows.count <= 512, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ UUID(uuidString: $0.id) != nil && UUID(uuidString: $0.operationID) != nil && !$0.scopeSessionID.isEmpty }) else {
            throw Failure(message: "Saved conversations are unavailable; existing records were preserved.")
        }
        for row in rows { try AgentConversationExchange.validate(row.exchanges) }
        return rows
    }
    private func save(_ rows: [AgentConversationRecord]) throws {
        for row in rows { try AgentConversationExchange.validate(row.exchanges) }
        let data = try JSONEncoder().encode(rows)
        guard data.count <= 50 * 1024 * 1024 else {
            throw Failure(message: "Saved conversations exceed their storage limit; existing records were preserved.")
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: fileURL)
    }
}

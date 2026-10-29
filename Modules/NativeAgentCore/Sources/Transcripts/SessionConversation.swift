import Foundation
import os
import NativeAgentShared
import PersistenceCore

// Blueprint: | `SessionConversation.swift` | `SessionConversation`: row-backed conversation kind for a session or id; creator source keys apply current declarations to historical transport rows on read; one index read can serve a whole batch, and one-id reads reuse each index parsed once per file stamp |

/// A session's row says whose conversation it is. IDs are locators only.
/// Reuse a loaded index for batch reads; this value owns no storage or cache.
public struct SessionConversation: Sendable {
    private let kinds: [String: ChatThreadKind]
    private let helperSessions: Set<String>

    public init(sessions: [ChatSession]) {
        kinds = sessions.reduce(into: [:]) { $0[$1.id] = Self.kind($1) }
        helperSessions = Set(sessions.filter { $0.helperID != nil || $0.source == "bot" }.map(\.id))
    }

    public init(dataRoot: URL, includingArchived: Bool = false) throws {
        let hot = try ChatSessionIndexFile.loadObjectRowsForMutation(at: dataRoot.appendingPathComponent("chat/sessions.json"))
        let cold = includingArchived ? try ChatSessionRetention.archiveIndexRows(dataRoot: dataRoot) : []
        self.init(rows: cold + hot)
    }

    /// Reuse a raw index already read by a transcript transaction.
    public init(rows: [[String: JSONValue]]) {
        let helpers = rows.reduce(into: [String: Bool]()) { result, row in
            guard case .string(let id)? = row["id"] else { return }
            let hasOwner: Bool = if case .string? = row["helperID"] { true } else { false }
            result[id] = hasOwner || row["source"] == .string("bot")
        }
        helperSessions = Set(helpers.filter { $0.value }.keys)
        kinds = rows.reduce(into: [:]) { result, row in
            guard case .string(let id)? = row["id"] else { return }
            func string(_ key: String) -> String? {
                if case .string(let value)? = row[key] { return value }
                return nil
            }
            result[id] = Self.kind(threadKind: string("threadKind"), source: string("source"), sourceKey: string("sourceKey"))
        }
    }

    public func kind(_ sessionID: String?) -> ChatThreadKind? {
        sessionID.flatMap { kinds[$0] }
    }

    /// Helper-only policies need the specific owner, beyond the common agent
    /// kind. The helper creator's recorded owner (or older bot provenance) identifies it; no ID
    /// shape or new conversation kind is involved.
    public func isHelper(_ sessionID: String?) -> Bool {
        sessionID.map { helperSessions.contains($0) } ?? false
    }

    public static func isHelper(_ sessionID: String?, dataRoot: URL = defaultDataRoot(), includingArchived: Bool = false) -> Bool {
        guard let sessionID, let hot = hotIndex(dataRoot) else { return false }
        if hot.kind(sessionID) != nil { return hot.isHelper(sessionID) }
        guard includingArchived, let cold = archivedIndex(dataRoot) else { return false }
        return cold.isHelper(sessionID)
    }

    public static func kind(_ session: ChatSession) -> ChatThreadKind {
        kind(threadKind: session.threadKind, source: session.source, sourceKey: session.sourceKey)
    }

    /// The creator's current declaration decides when its key proves one.
    /// Otherwise a recorded kind decides; `legacy` and a
    /// row with none read the kind their source proves, so an older agent
    /// thread recorded `legacy` is still a peer's (Trust and authorship).
    public static func kind(threadKind: String?, source: String?, sourceKey: String? = nil) -> ChatThreadKind {
        if let declared = ChatThreadKind.creatorDeclaration(source: source, sourceKey: sourceKey) { return declared }
        if let recorded = ChatThreadKind.parse(threadKind), recorded != .legacy { return recorded }
        return source.map(ChatThreadKind.inferred(fromSource:)) ?? .legacy
    }

    /// No row or an unreadable index proves no kind. Never guess from the ID.
    public static func kind(_ sessionID: String?, dataRoot: URL = defaultDataRoot(), includingArchived: Bool = false) -> ChatThreadKind? {
        guard let sessionID else { return nil }
        guard let hot = hotIndex(dataRoot) else { return nil }
        if let kind = hot.kind(sessionID) { return kind }
        guard includingArchived, let cold = archivedIndex(dataRoot) else { return nil }
        return cold.kind(sessionID)
    }

    // One-id questions run on every turn and every care event: each index is
    // parsed once per write, keyed by its file stamp (any write moves it).
    private static let parsed = OSAllocatedUnfairLock<[String: (stamp: SnapshotTailOpLog.FileStamp, value: SessionConversation)]>(initialState: [:])

    private static func hotIndex(_ dataRoot: URL) -> SessionConversation? {
        cached(dataRoot.appendingPathComponent("chat/sessions.json")) {
            Self(rows: try ChatSessionIndexFile.loadObjectRowsForMutation(at: $0))
        }
    }

    private static func archivedIndex(_ dataRoot: URL) -> SessionConversation? {
        cached(dataRoot.appendingPathComponent("chat/archive/sessions.jsonl")) { _ in
            Self(rows: try ChatSessionRetention.archiveIndexRows(dataRoot: dataRoot))
        }
    }

    private static func cached(_ file: URL, _ load: (URL) throws -> SessionConversation) -> SessionConversation? {
        guard let stamp = SnapshotTailOpLog.fileStamp(file) else { return nil }
        if let hit = parsed.withLock({ $0[file.path] }), hit.stamp == stamp { return hit.value }
        guard let value = try? load(file) else { return nil }
        parsed.withLock { $0[file.path] = (stamp, value) }
        return value
    }

    /// Only the session's owner calls this: declare a new row, or correct the
    /// kind its older writer recorded. All other row fields stay with the index.
    public static func declare(_ sessionID: String, kind: ChatThreadKind, title: String, source: String,
                               dataRoot: URL, createIfMissing: Bool = true) async throws {
        let path = dataRoot.appendingPathComponent("chat/sessions.json")
        try await ChatSessionIndexFile.mutate(at: path) { rows in
            if let index = rows.firstIndex(where: { $0["id"] == .string(sessionID) }) {
                rows[index]["threadKind"] = .string(kind.rawValue)
            } else if createIfMissing {
                rows.append(["id": .string(sessionID), "title": .string(title), "source": .string(source),
                             "threadKind": .string(kind.rawValue),
                             "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
                             "archived": .bool(false), "messageCount": .int(0)])
            }
        }
    }
}

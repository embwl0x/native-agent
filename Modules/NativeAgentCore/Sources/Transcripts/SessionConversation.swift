import Foundation
import os
import NativeAgentShared
import PersistenceCore

// Blueprint: | `SessionConversation.swift` | `SessionConversation`: Row-backed kind and stamped index reads |

/// A session's row says whose conversation it is. IDs are locators only. Reuse a loaded index for batch reads; this value owns no storage or cache.
public struct SessionConversation: Sendable {
    private let kinds: [String: ChatThreadKind]
    private let helperSessions: Set<String>

    public init(sessions: [ChatSession]) {
        kinds = sessions.reduce(into: [:]) { $0[$1.id] = Self.kind($1) }
        helperSessions = Set(sessions.filter { $0.helperID != nil }.map(\.id))
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
            result[id] = hasOwner
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

    /// Read the helper creator's recorded owner; conversation kind alone cannot identify which helper owns it.
    public func isHelper(_ sessionID: String?) -> Bool {
        sessionID.map { helperSessions.contains($0) } ?? false
    }

    /// Admission must distinguish a checked missing row from unavailable ownership.
    public static func checkedIsHelper(_ sessionID: String?, dataRoot: URL = defaultDataRoot(), includingArchived: Bool = false) throws -> Bool {
        guard let sessionID else { return false }
        let hot = try Self(dataRoot: dataRoot)
        if hot.kind(sessionID) != nil { return hot.isHelper(sessionID) }
        guard includingArchived else { return false }
        return try Self(rows: ChatSessionRetention.archiveIndexRows(dataRoot: dataRoot)).isHelper(sessionID)
    }

    public static func checkedKind(_ sessionID: String?, dataRoot: URL = defaultDataRoot(), includingArchived: Bool = false) throws -> ChatThreadKind? {
        guard let sessionID else { return nil }
        let hot = try Self(dataRoot: dataRoot)
        if let kind = hot.kind(sessionID) { return kind }
        guard includingArchived else { return nil }
        return try Self(rows: ChatSessionRetention.archiveIndexRows(dataRoot: dataRoot)).kind(sessionID)
    }

    /// An exact locator reads the row that owns it, hot before archived; a name resolves only when one current row has that title.
    package static func checkedRow(_ id: String, dataRoot: URL, matchingTitle: Bool = false) throws -> [String: JSONValue]? {
        let hot = try ChatSessionIndexFile.loadObjectRowsForMutation(at: dataRoot.appendingPathComponent("chat/sessions.json"))
        if let row = hot.first(where: { $0["id"] == .string(id) }) { return row }
        if let row = try ChatSessionRetention.archiveIndexRows(dataRoot: dataRoot).last(where: { $0["id"] == .string(id) }) { return row }
        guard matchingTitle else { return nil }
        let named = hot.filter { $0["title"]?.stringValue?.caseInsensitiveCompare(id) == .orderedSame }
        return named.count == 1 ? named[0] : nil
    }

    public static func kind(_ session: ChatSession) -> ChatThreadKind {
        kind(threadKind: session.threadKind, source: session.source, sourceKey: session.sourceKey)
    }

    /// Creator declarations outrank saved kind; unclassified rows require source evidence to preserve Trust and authorship.
    public static func kind(threadKind: String?, source: String?, sourceKey: String? = nil) -> ChatThreadKind {
        if let declared = ChatThreadKind.creatorDeclaration(source: source, sourceKey: sourceKey) { return declared }
        if let recorded = ChatThreadKind.parse(threadKind), recorded != .unclassified { return recorded }
        return source.map(ChatThreadKind.inferred(fromSource:)) ?? .unclassified
    }

    /// No row or an unreadable index proves no kind. Never guess from the ID.
    public static func kind(_ sessionID: String?, dataRoot: URL = defaultDataRoot(), includingArchived: Bool = false) -> ChatThreadKind? {
        guard let sessionID else { return nil }
        guard let hot = hotIndex(dataRoot) else { return nil }
        if let kind = hot.kind(sessionID) { return kind }
        guard includingArchived, let cold = archivedIndex(dataRoot) else { return nil }
        return cold.kind(sessionID)
    }

    // One-id questions run on every turn and every care event: each index is parsed once per write, keyed by its file stamp (any write moves it).
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

    /// Only the session owner declares or corrects kind; all unrelated fields stay with the index.
    public static func declare(_ sessionID: String, kind: ChatThreadKind, title: String, source: String,
                               dataRoot: URL, createIfMissing: Bool = true) async throws {
        let path = dataRoot.appendingPathComponent("chat/sessions.json")
        try await ChatSessionIndexFile.mutate(at: path) { rows in
            if let index = rows.firstIndex(where: { $0["id"] == .string(sessionID) }) {
                rows[index]["threadKind"] = .string(kind.rawValue)
                // The session's owner (the one that mints it) names its source; another declarer only reads it.
                if createIfMissing { rows[index]["source"] = .string(source) }
            } else if createIfMissing {
                rows.append(["id": .string(sessionID), "title": .string(title), "source": .string(source),
                             "threadKind": .string(kind.rawValue),
                             "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
                             "archived": .bool(false), "messageCount": .int(0),
                             ChatSessionIndexFile.transcriptGenerationKey: .int(0)])
            }
        }
    }
}

import FeedPolicy
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts

public struct TelegramSessionStatus: Sendable, Equatable {
    public let chatId: Int
    public let sessionId: String
    public let persona: String
    public let messageCount: Int

    public init(chatId: Int, sessionId: String, persona: String, messageCount: Int) {
        self.chatId = chatId
        self.sessionId = sessionId
        self.persona = persona
        self.messageCount = messageCount
    }
}

public struct TelegramRecentSession: Sendable, Equatable {
    public let id: String
    public let title: String
    public let source: String
    public let updatedAt: String?
    public let messageCount: Int

    public init(
        id: String,
        title: String,
        source: String,
        updatedAt: String?,
        messageCount: Int
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }
}

public enum TelegramSessionStoreError: LocalizedError, Sendable, Equatable {
    case missingSessionId
    case sessionNotFound(String)
    case ambiguousSessionPrefix(String, [String])
    case sessionStorageUnavailable

    public var errorDescription: String? {
        switch self {
        case .sessionStorageUnavailable:
            return "Telegram conversation storage is unavailable. Repair or restore session_map.json before retrying; existing bindings have been preserved."
        case .missingSessionId:
            return "/resume requires a session id."
        case .sessionNotFound(let id):
            return "No chat session matched '\(id)'."
        case .ambiguousSessionPrefix(let prefix, let matches):
            return "Session prefix '\(prefix)' is ambiguous: \(matches.prefix(5).joined(separator: ", "))."
        }
    }
}

public struct TelegramSessionStore: Sendable {
    public let dataRoot: URL

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    public func activeSessionId(chatId: Int) async throws -> String {
        try await activeSessionId(destination: .chat(chatId))
    }

    public func activeSessionId(destination: TelegramDestination) async throws -> String {
        let chatKey = Self.chatKey(destination)
        if let mapped = try await mappedSessionId(chatKey: chatKey), !mapped.isEmpty {
            try await ensureSessionRow(id: mapped, destination: destination, title: Self.sessionTitle(destination))
            await publishAnchor(sessionId: mapped, destination: destination)
            emitIdentityTrace(sessionId: mapped, destination: destination, resolvedBy: .mapped)
            return mapped
        }
        // MINT-OR-ADOPT UNDER ONE LOCK.
        //
        // What stood here was: unlocked read above (miss) → ensure row → patch
        // the map. Two concurrent first messages for the same chat both saw the
        // miss, both wrote, and the second patch clobbered the first — orphaning
        // that turn's session context. Slack fixed exactly this on 2026-07-21
        // (SlackSessionStore.activeSessionId); Telegram still had the bug.
        //
        // This is that fix, lifted verbatim in shape: re-check INSIDE the flock
        // and ADOPT whatever a concurrent patch already wrote. The mutation
        // closure is the only place that decides, and only one caller can be
        // inside it.
        let legacy = Self.legacySessionId(destination)
        // The closure runs inside the flock on another executor, so it reports
        // BOTH facts through its return value rather than mutating a capture.
        let outcome = try await patchChatMap(chatKey: chatKey) { entry -> (id: String, adopted: Bool) in
            if case .string(let existing)? = entry["activeSessionId"] {
                let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return (trimmed, true) }
            }
            let now = Self.nowString()
            if entry["createdAt"] == nil { entry["createdAt"] = .string(now) }
            entry["activeSessionId"] = .string(legacy)
            entry["updatedAt"] = .string(now)
            return (legacy, false)
        }
        let resolved = outcome.id
        let adopted = outcome.adopted
        // Row creation moved AFTER the resolution so the id it creates is the
        // one that won, not one this task minted and then lost.
        try await ensureSessionRow(id: resolved, destination: destination, title: Self.sessionTitle(destination))
        await publishAnchor(sessionId: resolved, destination: destination)
        emitIdentityTrace(
            sessionId: resolved,
            destination: destination,
            resolvedBy: adopted ? .adopted : .minted
        )
        return resolved
    }

    public func startNewSession(chatId: Int) async throws -> String {
        try await startNewSession(destination: .chat(chatId))
    }

    public func startNewSession(destination: TelegramDestination) async throws -> String {
        let sessionId = UUID().uuidString
        try await ensureSessionRow(id: sessionId, destination: destination, title: Self.sessionTitle(destination)) {
            try await patchChatMap(chatKey: Self.chatKey(destination)) { entry in
                if entry["createdAt"] == nil { entry["createdAt"] = .string(Self.nowString()) }
                entry["activeSessionId"] = .string(sessionId)
                entry["updatedAt"] = .string(Self.nowString())
            }
        }
        // `/new` is a REAL new session — User uses it to clear her head — and
        // the new one becomes the anchor. The previous session is untouched and
        // stays reachable (`/resume`, the Mac sidebar, session search).
        await publishAnchor(sessionId: sessionId, destination: destination)
        emitIdentityTrace(sessionId: sessionId, destination: destination, resolvedBy: .minted)
        return sessionId
    }

    // MARK: - Anchor + identity instrumentation
    //
    // This store is a PUBLISHER of the surface-agnostic anchor
    // (`ConversationAnchor`), not its owner. It says "the human is now active
    // in this direct conversation"; the Mac and the phone decide what to do
    // with that, and neither knows the word "telegram". A Signal or WhatsApp
    // adapter added later makes the same two calls and needs no other change.

    private func publishAnchor(sessionId: String, destination: TelegramDestination) async {
        // Only private chats may move the shared anchor; groups and channels
        // have negative IDs, and forum topics are separate conversations.
        guard destination.chatId > 0, destination.threadId == nil else { return }
        // Best-effort: an anchor that fails to publish must never fail User's
        // message. Worst case the pin lags by one turn.
        _ = try? await ConversationAnchor.publish(
            sessionId: sessionId,
            source: Self.anchorSource,
            conversationKind: .direct,
            dataRoot: dataRoot
        )
    }

    private func emitIdentityTrace(
        sessionId: String,
        destination: TelegramDestination,
        resolvedBy: SessionIdentityTrace.Resolution
    ) {
        SessionIdentityTrace.emit(
            threadKey: Self.legacySessionId(destination),
            sessionId: sessionId,
            surface: Self.anchorSource,
            mintSite: .telegramSessionStore,
            resolvedBy: resolvedBy
        )
    }

    /// Display/diagnostic attribution only. No consumer of the anchor may
    /// branch on this value — see `ConversationAnchor`.
    private static let anchorSource = "telegram"

    public func persona(destination: TelegramDestination) async throws -> String? {
        let chatKey = Self.chatKey(destination)
        if let entry = try await chatMapEntry(chatKey: chatKey),
           case .string(let persona)? = entry["persona"] {
            let trimmed = persona.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    public func setPersona(destination: TelegramDestination, persona: String) async throws -> String {
        let trimmed = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TelegramBotError.invalidRequest
        }
        try await patchChatMap(chatKey: Self.chatKey(destination)) { entry in
            if entry["createdAt"] == nil { entry["createdAt"] = .string(Self.nowString()) }
            entry["persona"] = .string(trimmed)
            entry["updatedAt"] = .string(Self.nowString())
        }
        return trimmed
    }

    public func status(chatId: Int) async throws -> TelegramSessionStatus {
        try await status(destination: .chat(chatId))
    }

    public func status(destination: TelegramDestination) async throws -> TelegramSessionStatus {
        let sessionId = try await activeSessionId(destination: destination)
        let persona = try await persona(destination: destination) ?? "NativeAgent"
        let messages = (try? await SwiftNativePersistenceCore().readJSONL(messagesPath(sessionId: sessionId))) ?? []
        return TelegramSessionStatus(
            chatId: destination.chatId,
            sessionId: sessionId,
            persona: persona,
            messageCount: messages.count
        )
    }

    /// 2026-09-22: the assistant reply already saved for a lost turn, if any.
    /// A turn can finish and persist its reply, then die before the send.
    /// Rows carry no Telegram update id, so the user row must be the newest
    /// one, match the text, and postdate the claim; the reply must share its
    /// runId and not be a mechanical (failure) row.
    public func savedReply(
        destination: TelegramDestination,
        after userText: String,
        claimedAt: String
    ) async -> String? {
        let needle = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
              let claimed = Self.parseTimestamp(claimedAt),
              let sessionId = try? await mappedSessionId(chatKey: Self.chatKey(destination)),
              !sessionId.isEmpty,
              let rows = try? await SwiftNativePersistenceCore().readJSONL(messagesPath(sessionId: sessionId))
        else { return nil }
        var replies: [(content: String, runId: String?)] = []
        for row in rows.reversed() {
            guard case .object(let obj) = row,
                  case .string(let role)? = obj["role"],
                  case .string(let content)? = obj["content"] else { continue }
            var runId: String?
            if case .string(let id)? = obj["runId"] { runId = id }
            if role == "user" {
                guard content.contains(needle),
                      case .string(let createdAt)? = obj["createdAt"],
                      let created = Self.parseTimestamp(createdAt),
                      created >= claimed else { return nil }
                return replies.first { $0.runId == runId }?.content
            }
            if role == "assistant",
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if case .object(let metadata)? = obj["metadata"],
                   metadata["mechanicalKind"] != nil { continue }
                replies.append((content, runId))
            }
        }
        return nil
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func canAccessAllSessions(destination: TelegramDestination, fromUserId: Int?) -> Bool {
        guard destination.chatId > 0, destination.threadId == nil,
              fromUserId == destination.chatId,
              let owners = TelegramConfig.loadFromDisk(dataRoot: dataRoot)?.allowedUserIds,
              owners.count == 1, owners.contains(Int64(destination.chatId)) else { return false }
        return true
    }

    private func isAccessibleSession(_ value: JSONValue, destination: TelegramDestination, ownerAccess: Bool) -> Bool {
        if ownerAccess { return true }
        guard case .object(let row) = value,
              row["source"] == .string("telegram"),
              row["sourceKey"] == .string(Self.legacySessionId(destination)) else { return false }
        return true
    }

    public func recentSessions(destination: TelegramDestination, fromUserId: Int?, limit: Int = 8) async throws -> [TelegramRecentSession] {
        let cappedLimit = max(1, min(limit, 25))
        let rows = try await SwiftNativePersistenceCore().readJSON(sessionsPath, ifMissing: .array([]))
        guard case .array(let array) = rows else { return [] }
        let ownerAccess = canAccessAllSessions(destination: destination, fromUserId: fromUserId)
        let sessions = array
            .filter { isAccessibleSession($0, destination: destination, ownerAccess: ownerAccess) }
            .compactMap(Self.recentSession(from:))
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                (lhs.updatedAt ?? "") > (rhs.updatedAt ?? "")
            }
        return Array(sessions.prefix(cappedLimit))
    }

    public func bindSession(chatId: Int, requestedSessionId rawSessionId: String, fromUserId: Int? = nil) async throws -> TelegramSessionStatus {
        try await bindSession(destination: .chat(chatId), requestedSessionId: rawSessionId, fromUserId: fromUserId)
    }

    public func bindSession(
        destination: TelegramDestination,
        requestedSessionId rawSessionId: String,
        fromUserId: Int? = nil
    ) async throws -> TelegramSessionStatus {
        let sessionId = try await resolveExistingSessionId(rawSessionId, destination: destination, fromUserId: fromUserId)
        try await patchChatMap(chatKey: Self.chatKey(destination)) { entry in
            if entry["createdAt"] == nil { entry["createdAt"] = .string(Self.nowString()) }
            entry["activeSessionId"] = .string(sessionId)
            entry["updatedAt"] = .string(Self.nowString())
        }
        // `/resume` moves the conversation User is in, so it moves the anchor —
        // same fact, same hook. Without this the Mac and phone would keep
        // pinning the session he just left.
        await publishAnchor(sessionId: sessionId, destination: destination)
        emitIdentityTrace(sessionId: sessionId, destination: destination, resolvedBy: .requested)
        return try await status(destination: destination)
    }

    public func writeScratch(destination: TelegramDestination, key: String, value: String) async throws -> String {
        let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty, !cleanedValue.isEmpty else {
            throw TelegramBotError.invalidRequest
        }
        let sessionId = try await activeSessionId(destination: destination)
        let path = sessionDir(sessionId: sessionId).appendingPathComponent("scratch.json")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let current = try await persistence.readJSON(path, ifMissing: .object([:]))
            var root: [String: JSONValue]
            if case .object(let obj) = current { root = obj } else { root = [:] }
            root[cleanedKey] = .string(cleanedValue)
            try await persistence.writeJSON(.object(root), to: path)
        }
        return sessionId
    }

    public func appendNote(text: String, kind: String, source: String, persona: String = "NativeAgent") async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TelegramBotError.invalidRequest
        }
        let noteId = UUID().uuidString.lowercased()
        let notesPath = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(persona, isDirectory: true)
            .appendingPathComponent("notes.jsonl")
        let record: JSONValue = .object([
            "id": .string(noteId),
            "ts": .string(Self.nowString()),
            "persona": .string(persona),
            "kind": .string(kind.isEmpty ? "note" : kind),
            "text": .string(trimmed),
            "tags": .array([.string("telegram")]),
            "source_run": .string(source),
            "confidence": .double(0.8),
            "importance": .double(0.5),
        ])
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(notesPath) {
            // P-L4 (tightness round 2): bare append grew notes.jsonl unbounded —
            // route through the shared capped appender under the same flock.
            try await appendJSONLCapped(
                record,
                to: notesPath,
                using: persistence,
                maxLines: JSONLLineCaps.telegramNotes,
                logLabel: "TelegramSessionStore.notes",
                takeLock: false
            )
        }
        return noteId
    }

    /// The conversation a private chat is in now, or nil.
    public func boundSessionId(chatId: Int) async -> String? {
        try? await mappedSessionId(chatKey: String(chatId))
    }

    private func mappedSessionId(chatKey: String) async throws -> String? {
        guard let entry = try await chatMapEntry(chatKey: chatKey),
              case .string(let id)? = entry["activeSessionId"] else {
            return nil
        }
        return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chatMapEntry(chatKey: String) async throws -> [String: JSONValue]? {
        try await SwiftNativePersistenceCore().withFileLock(sessionMapPath) {
            let root = try loadSessionMap()
            guard case .object(let chats)? = root["chats"],
                  case .object(let entry)? = chats[chatKey] else {
                return nil
            }
            return entry
        }
    }

    /// Called under the map lock. Only absence may bootstrap; damaged bytes
    /// stay in place so every subsequent access continues to report the error.
    private func loadSessionMap() throws -> [String: JSONValue] {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: sessionMapPath)
        } catch CocoaError.fileReadNoSuchFile {
            return ["chats": .object([:])]
        } catch {
            throw TelegramSessionStoreError.sessionStorageUnavailable
        }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
            guard case .object(let root) = value,
                  case .object(let chats)? = root["chats"] else {
                throw TelegramSessionStoreError.sessionStorageUnavailable
            }
            for (key, value) in chats {
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      case .object(let entry) = value,
                      entry["activeSessionId"] != nil || entry["persona"] != nil else {
                    throw TelegramSessionStoreError.sessionStorageUnavailable
                }
                // A persona can be configured before a session is selected.
                for field in ["activeSessionId", "persona", "createdAt", "updatedAt"] {
                    if let value = entry[field] {
                        guard case .string(let text) = value,
                              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw TelegramSessionStoreError.sessionStorageUnavailable
                        }
                    }
                }
            }
            return root
        } catch {
            throw TelegramSessionStoreError.sessionStorageUnavailable
        }
    }

    /// Locked read-modify-write of one chat's map entry.
    ///
    /// The generic return is what makes mint-or-adopt possible: the mutation
    /// closure both DECIDES the session id and reports it, inside the flock, so
    /// no caller can act on a value it read before the lock.
    @discardableResult
    private func patchChatMap<T: Sendable>(
        chatKey: String,
        mutate: @escaping @Sendable (inout [String: JSONValue]) -> T
    ) async throws -> T {
        let path = sessionMapPath
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(path) {
            var root = try loadSessionMap()
            guard case .object(var chats)? = root["chats"] else {
                throw TelegramSessionStoreError.sessionStorageUnavailable
            }
            var entry: [String: JSONValue]
            if case .object(let obj)? = chats[chatKey] { entry = obj } else { entry = [:] }
            let result = mutate(&entry)
            chats[chatKey] = .object(entry)
            root["chats"] = .object(chats)
            try await persistence.writeJSON(.object(root), to: path)
            return result
        }
    }

    private func ensureSessionRow(
        id: String, destination: TelegramDestination, title: String,
        commitBinding: @Sendable () async throws -> Void = {}
    ) async throws {
        let sessionsPath = self.sessionsPath
        let dataRoot = self.dataRoot
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(sessionsPath) {
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            if rows.contains(where: { row in
                guard case .string(let rowId)? = row["id"] else { return false }
                return rowId == id
            }) {
                try await commitBinding()
                return
            }
            let now = Self.nowString()
            // A chat still bound to a session retention archived picks its
            // conversation back up instead of starting an empty one.
            let row: [String: JSONValue] = try await ChatSessionRetention.restoreArchivedRow(
                sessionId: id, dataRoot: dataRoot
            ) ?? [
                "id": .string(id),
                "title": .string(title),
                "source": .string("telegram"),
                "sourceKey": .string(Self.legacySessionId(destination)),
                "createdAt": .string(now),
                "updatedAt": .string(now),
                "archived": .bool(false),
                "messageCount": .int(0),
            ]
            rows.insert(row, at: 0)
            try await persistence.writeJSON(.array(rows.map(JSONValue.object)), to: sessionsPath)
            do {
                try await commitBinding()
            } catch {
                // Keep the index lock through map publication and rollback so
                // another index writer cannot adopt or modify the unused row.
                rows.removeFirst()
                try await persistence.writeJSON(.array(rows.map(JSONValue.object)), to: sessionsPath)
                throw error
            }
            ChatSessionRetention.enforceBestEffort(
                dataRoot: dataRoot,
                now: Date(),
                context: "TelegramSessionStore.ensureSessionRow"
            )
        }
    }

    private func resolveExistingSessionId(_ raw: String, destination: TelegramDestination, fromUserId: Int?) async throws -> String {
        let requested = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            throw TelegramSessionStoreError.missingSessionId
        }
        let rows = try await SwiftNativePersistenceCore().readJSON(sessionsPath, ifMissing: .array([]))
        guard case .array(let array) = rows else {
            throw TelegramSessionStoreError.sessionNotFound(requested)
        }
        let ownerAccess = canAccessAllSessions(destination: destination, fromUserId: fromUserId)
        let ids = array.filter { isAccessibleSession($0, destination: destination, ownerAccess: ownerAccess) }.compactMap { value -> String? in
            guard case .object(let obj) = value,
                  case .string(let id)? = obj["id"] else {
                return nil
            }
            return id.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if ids.contains(requested) {
            return requested
        }
        let matches = ids.filter { $0.hasPrefix(requested) }
        if matches.count == 1, let match = matches.first {
            return match
        }
        if matches.count > 1 {
            throw TelegramSessionStoreError.ambiguousSessionPrefix(requested, matches)
        }
        throw TelegramSessionStoreError.sessionNotFound(requested)
    }

    private var sessionMapPath: URL {
        dataRoot
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("session_map.json")
    }

    private var sessionsPath: URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    private func messagesPath(sessionId: String) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    private func sessionDir(sessionId: String) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }

    private static func chatKey(_ destination: TelegramDestination) -> String {
        guard let threadId = destination.threadId else { return String(destination.chatId) }
        return "\(destination.chatId):\(threadId)"
    }

    public static func legacySessionId(_ chatId: Int) -> String {
        "telegram:\(chatId)"
    }

    /// 2026-09-06: the per-conversation source key. A forum topic is its own
    /// conversation, so it gets its own key; a DM, an ordinary group and a
    /// forum's General topic keep the historical `telegram:<chatId>` form so
    /// every session already on disk still resolves.
    public static func legacySessionId(_ destination: TelegramDestination) -> String {
        guard let threadId = destination.threadId else {
            return legacySessionId(destination.chatId)
        }
        return "telegram:\(destination.chatId):\(threadId)"
    }

    private static func sessionTitle(_ destination: TelegramDestination) -> String {
        guard let threadId = destination.threadId else {
            return "Telegram \(destination.chatId)"
        }
        return "Telegram \(destination.chatId) topic \(threadId)"
    }

    private static func recentSession(from value: JSONValue) -> TelegramRecentSession? {
        guard case .object(let obj) = value,
              case .string(let id)? = obj["id"] else {
            return nil
        }
        let title: String = {
            if case .string(let value)? = obj["title"] {
                return value
            }
            return id
        }()
        let source: String = {
            if case .string(let value)? = obj["source"] {
                return value
            }
            return "chat"
        }()
        let updatedAt: String? = {
            if case .string(let value)? = obj["updatedAt"] {
                return value
            }
            return nil
        }()
        let messageCount: Int = {
            switch obj["messageCount"] {
            case .int(let value)?: return Int(value)
            case .double(let value)?: return Int(exactly: value.rounded(.towardZero)) ?? 0
            case .string(let value)?: return Int(value) ?? 0
            default: return 0
            }
        }()
        return TelegramRecentSession(
            id: id,
            title: title,
            source: source,
            updatedAt: updatedAt,
            messageCount: messageCount
        )
    }

    private static func nowString(_ date: Date = Date()) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }
}

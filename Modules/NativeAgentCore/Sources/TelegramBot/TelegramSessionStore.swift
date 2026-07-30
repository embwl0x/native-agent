import Foundation
import PersistenceCore

public struct TelegramSessionCommandResult: Sendable, Equatable {
    public let sessionId: String
    public let messagesBefore: Int
    public let messagesAfter: Int

    public init(sessionId: String, messagesBefore: Int, messagesAfter: Int) {
        self.sessionId = sessionId
        self.messagesBefore = messagesBefore
        self.messagesAfter = messagesAfter
    }
}

public struct TelegramSessionCompactionResult: Sendable, Equatable {
    public let sessionId: String
    public let compacted: Bool
    public let messagesBefore: Int
    public let messagesAfter: Int
    public let messagesReplaced: Int
    public let reason: String

    public init(
        sessionId: String,
        compacted: Bool,
        messagesBefore: Int,
        messagesAfter: Int,
        messagesReplaced: Int,
        reason: String
    ) {
        self.sessionId = sessionId
        self.compacted = compacted
        self.messagesBefore = messagesBefore
        self.messagesAfter = messagesAfter
        self.messagesReplaced = messagesReplaced
        self.reason = reason
    }
}

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

    public var errorDescription: String? {
        switch self {
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
        let chatKey = Self.chatKey(chatId)
        if let mapped = await mappedSessionId(chatKey: chatKey), !mapped.isEmpty {
            try await ensureSessionRow(id: mapped, chatId: chatId, title: "Telegram \(chatId)")
            return mapped
        }
        let legacy = Self.legacySessionId(chatId)
        try await ensureSessionRow(id: legacy, chatId: chatId, title: "Telegram \(chatId)")
        try await patchChatMap(chatKey: chatKey) { entry in
            if entry["createdAt"] == nil { entry["createdAt"] = .string(Self.nowString()) }
            entry["activeSessionId"] = .string(legacy)
            entry["updatedAt"] = .string(Self.nowString())
        }
        return legacy
    }

    public func startNewSession(chatId: Int) async throws -> String {
        let sessionId = UUID().uuidString
        try await ensureSessionRow(id: sessionId, chatId: chatId, title: "Telegram \(chatId)")
        try await patchChatMap(chatKey: Self.chatKey(chatId)) { entry in
            if entry["createdAt"] == nil { entry["createdAt"] = .string(Self.nowString()) }
            entry["activeSessionId"] = .string(sessionId)
            entry["updatedAt"] = .string(Self.nowString())
        }
        return sessionId
    }

    public func resetSession(chatId: Int) async throws -> TelegramSessionCommandResult {
        let sessionId = try await activeSessionId(chatId: chatId)
        return try await clearSession(sessionId: sessionId)
    }

    public func clearSession(chatId: Int) async throws -> TelegramSessionCommandResult {
        let sessionId = try await activeSessionId(chatId: chatId)
        return try await clearSession(sessionId: sessionId)
    }

    public func compactSession(chatId: Int, force: Bool = false) async throws -> TelegramSessionCompactionResult {
        let sessionId = try await activeSessionId(chatId: chatId)
        let messagesPath = self.messagesPath(sessionId: sessionId)
        let sessionDir = self.sessionDir(sessionId: sessionId)
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(messagesPath) {
            let rows = (try? await persistence.readJSONL(messagesPath)) ?? []
            let before = rows.count
            // Match the shared chat compaction policy: Telegram keeps the last
            // 20 rows hot so reply/continuation turns retain nearby referents.
            let keepCount = 20
            guard before > keepCount || force else {
                return TelegramSessionCompactionResult(
                    sessionId: sessionId,
                    compacted: false,
                    messagesBefore: before,
                    messagesAfter: before,
                    messagesReplaced: 0,
                    reason: "not enough messages to compact"
                )
            }
            let replaceCount = max(0, before - keepCount)
            guard replaceCount > 0 else {
                return TelegramSessionCompactionResult(
                    sessionId: sessionId,
                    compacted: false,
                    messagesBefore: before,
                    messagesAfter: before,
                    messagesReplaced: 0,
                    reason: "nothing to compact"
                )
            }
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: messagesPath.path) {
                let backup = sessionDir.appendingPathComponent(
                    "messages.compact.\(Self.fileSafeTimestamp()).jsonl"
                )
                try? FileManager.default.copyItem(at: messagesPath, to: backup)
                // P-L4 (tightness round 2): these pre-compaction backups were
                // written every compaction and never pruned. Retain the newest 3
                // (timestamped filenames sort lexicographically), delete older.
                Self.pruneCompactBackups(in: sessionDir, keep: 3)
            }
            let replaced = Array(rows.prefix(replaceCount))
            let kept = Array(rows.suffix(keepCount))
            let summary = Self.compactionSummary(for: replaced)
            let now = Self.nowString()
            let summaryRow: JSONValue = .object([
                "id": .string("compact-\(UUID().uuidString.lowercased())"),
                "sessionId": .string(sessionId),
                "role": .string("system"),
                "content": .string(summary),
                "createdAt": .string(now),
                "source": .string("telegram_native_compaction"),
                "metadata": .object([
                    "kind": .string("compaction_summary"),
                    "messages_replaced": .int(Int64(replaceCount)),
                    "surface": .string("telegram"),
                ]),
            ])
            let nextRows = [summaryRow] + kept
            var payload = Data()
            for row in nextRows {
                payload.append(Data((try row.serialize(pretty: false)).utf8))
                payload.append(0x0A)
            }
            try FileManager.default.createDirectory(
                at: messagesPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: messagesPath, options: .atomic)
            let context: JSONValue = .object([
                "session_id": .string(sessionId),
                "message_count": .int(Int64(nextRows.count)),
                "compactable": .bool(nextRows.count > keepCount),
                "model": .string("swift-native-telegram-compactor"),
                "context_loaded": .bool(true),
                "context_mode": .string("compacted"),
                "context_prompt_chars": .int(Int64(summary.count)),
            ])
            try await persistence.writeJSON(context, to: sessionDir.appendingPathComponent("context.json"))
            try await patchSessionRow(id: sessionId, messageCount: nextRows.count, preview: "Conversation compacted")
            return TelegramSessionCompactionResult(
                sessionId: sessionId,
                compacted: true,
                messagesBefore: before,
                messagesAfter: nextRows.count,
                messagesReplaced: replaceCount,
                reason: "swift-native-compaction"
            )
        }
    }

    public func persona(chatId: Int) async throws -> String? {
        let chatKey = Self.chatKey(chatId)
        if let entry = await chatMapEntry(chatKey: chatKey),
           case .string(let persona)? = entry["persona"] {
            let trimmed = persona.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    public func setPersona(chatId: Int, persona: String) async throws -> String {
        let trimmed = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TelegramBotError.invalidRequest
        }
        try await patchChatMap(chatKey: Self.chatKey(chatId)) { entry in
            if entry["createdAt"] == nil { entry["createdAt"] = .string(Self.nowString()) }
            entry["persona"] = .string(trimmed)
            entry["updatedAt"] = .string(Self.nowString())
        }
        return trimmed
    }

    public func status(chatId: Int) async throws -> TelegramSessionStatus {
        let sessionId = try await activeSessionId(chatId: chatId)
        let persona = try await persona(chatId: chatId) ?? "NativeAgent"
        let messages = (try? await SwiftNativePersistenceCore().readJSONL(messagesPath(sessionId: sessionId))) ?? []
        return TelegramSessionStatus(
            chatId: chatId,
            sessionId: sessionId,
            persona: persona,
            messageCount: messages.count
        )
    }

    public func recentSessions(limit: Int = 8) async throws -> [TelegramRecentSession] {
        let cappedLimit = max(1, min(limit, 25))
        let rows = await SwiftNativePersistenceCore().readJSON(sessionsPath, defaultValue: .array([]))
        guard case .array(let array) = rows else { return [] }
        let sessions = array
            .compactMap(Self.recentSession(from:))
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                (lhs.updatedAt ?? "") > (rhs.updatedAt ?? "")
            }
        return Array(sessions.prefix(cappedLimit))
    }

    public func bindSession(chatId: Int, requestedSessionId rawSessionId: String) async throws -> TelegramSessionStatus {
        let sessionId = try await resolveExistingSessionId(rawSessionId)
        try await patchChatMap(chatKey: Self.chatKey(chatId)) { entry in
            if entry["createdAt"] == nil { entry["createdAt"] = .string(Self.nowString()) }
            entry["activeSessionId"] = .string(sessionId)
            entry["updatedAt"] = .string(Self.nowString())
        }
        return try await status(chatId: chatId)
    }

    public func writeScratch(chatId: Int, key: String, value: String) async throws -> String {
        let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty, !cleanedValue.isEmpty else {
            throw TelegramBotError.invalidRequest
        }
        let sessionId = try await activeSessionId(chatId: chatId)
        let path = sessionDir(sessionId: sessionId).appendingPathComponent("scratch.json")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let current = await persistence.readJSON(path, defaultValue: .object([:]))
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

    private func clearSession(sessionId: String) async throws -> TelegramSessionCommandResult {
        let path = messagesPath(sessionId: sessionId)
        let staleNestedPath = sessionDir(sessionId: sessionId).appendingPathComponent("messages.jsonl")
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(path) {
            let before = ((try? await persistence.readJSONL(path)) ?? []).count
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: path, options: .atomic)
            if FileManager.default.fileExists(atPath: staleNestedPath.path) {
                try? FileManager.default.removeItem(at: staleNestedPath)
            }
            try await patchSessionRow(id: sessionId, messageCount: 0, preview: "")
            return TelegramSessionCommandResult(sessionId: sessionId, messagesBefore: before, messagesAfter: 0)
        }
    }

    private func mappedSessionId(chatKey: String) async -> String? {
        guard let entry = await chatMapEntry(chatKey: chatKey),
              case .string(let id)? = entry["activeSessionId"] else {
            return nil
        }
        return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chatMapEntry(chatKey: String) async -> [String: JSONValue]? {
        let current = await SwiftNativePersistenceCore().readJSON(sessionMapPath, defaultValue: .object([:]))
        guard case .object(let root) = current,
              case .object(let chats)? = root["chats"],
              case .object(let entry)? = chats[chatKey] else {
            return nil
        }
        return entry
    }

    private func patchChatMap(
        chatKey: String,
        mutate: @escaping @Sendable (inout [String: JSONValue]) -> Void
    ) async throws {
        let path = sessionMapPath
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let current = await persistence.readJSON(path, defaultValue: .object([:]))
            var root: [String: JSONValue]
            if case .object(let obj) = current { root = obj } else { root = [:] }
            var chats: [String: JSONValue]
            if case .object(let obj)? = root["chats"] { chats = obj } else { chats = [:] }
            var entry: [String: JSONValue]
            if case .object(let obj)? = chats[chatKey] { entry = obj } else { entry = [:] }
            mutate(&entry)
            chats[chatKey] = .object(entry)
            root["chats"] = .object(chats)
            try await persistence.writeJSON(.object(root), to: path)
        }
    }

    private func ensureSessionRow(id: String, chatId: Int, title: String) async throws {
        let sessionsPath = self.sessionsPath
        let dataRoot = self.dataRoot
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(sessionsPath) {
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            if rows.contains(where: { row in
                guard case .string(let rowId)? = row["id"] else { return false }
                return rowId == id
            }) {
                return
            }
            let now = Self.nowString()
            let row: [String: JSONValue] = [
                "id": .string(id),
                "title": .string(title),
                "source": .string("telegram"),
                "sourceKey": .string(Self.legacySessionId(chatId)),
                "createdAt": .string(now),
                "updatedAt": .string(now),
                "archived": .bool(false),
                "messageCount": .int(0),
            ]
            rows.insert(row, at: 0)
            try await persistence.writeJSON(.array(rows.map(JSONValue.object)), to: sessionsPath)
            _ = try? ChatSessionRetention.enforce(dataRoot: dataRoot, now: Date())
        }
    }

    private func patchSessionRow(id: String, messageCount: Int, preview: String) async throws {
        let sessionsPath = self.sessionsPath
        let dataRoot = self.dataRoot
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(sessionsPath) {
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            guard let index = rows.firstIndex(where: { row in
                guard case .string(let rowId)? = row["id"] else { return false }
                return rowId == id
            }) else {
                return
            }
            let original = rows[index]
            var updated = original
            guard case .string(let rowId)? = updated["id"],
                      rowId == id else {
                return
            }
            updated["updatedAt"] = .string(Self.nowString())
            updated["messageCount"] = .int(Int64(messageCount))
            updated["lastMessagePreview"] = preview.isEmpty ? .null : .string(preview)
            guard updated != original else { return }
            rows[index] = updated
            try await persistence.writeJSON(.array(rows.map(JSONValue.object)), to: sessionsPath)
            _ = try? ChatSessionRetention.enforce(dataRoot: dataRoot, now: Date())
        }
    }

    private func resolveExistingSessionId(_ raw: String) async throws -> String {
        let requested = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            throw TelegramSessionStoreError.missingSessionId
        }
        let rows = await SwiftNativePersistenceCore().readJSON(sessionsPath, defaultValue: .array([]))
        guard case .array(let array) = rows else {
            throw TelegramSessionStoreError.sessionNotFound(requested)
        }
        let ids = array.compactMap { value -> String? in
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

    private static func chatKey(_ chatId: Int) -> String {
        String(chatId)
    }

    public static func legacySessionId(_ chatId: Int) -> String {
        "telegram:\(chatId)"
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
            case .double(let value)?: return Int(value)
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Retain the newest `keep` `messages.compact.<ts>.jsonl` backups in
    /// `dir`, deleting the rest. Filenames carry a lexicographically-sortable
    /// `yyyyMMdd-HHmmss` stamp, so a reverse name sort is newest-first.
    /// Best-effort — a delete failure leaves the backup rather than throwing.
    static func pruneCompactBackups(in dir: URL, keep: Int) {
        guard keep >= 0 else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        let backups = entries
            .filter {
                $0.lastPathComponent.hasPrefix("messages.compact.")
                    && $0.pathExtension == "jsonl"
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard backups.count > keep else { return }
        for stale in backups.dropFirst(keep) {
            try? fm.removeItem(at: stale)
        }
    }

    private static func fileSafeTimestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func compactionSummary(for rows: [JSONValue]) -> String {
        var lines: [String] = []
        lines.append("[NativeAgent compacted \(rows.count) earlier message(s).]")
        for row in rows {
            guard case .object(let obj) = row else { continue }
            let role: String = {
                if case .string(let s)? = obj["role"] { return s }
                return "message"
            }()
            let content: String = {
                if case .string(let s)? = obj["content"] { return s }
                return ""
            }()
            let normalized = content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            lines.append("\(role): \(String(normalized.prefix(500)))")
            if lines.joined(separator: "\n").count > 12_000 { break }
        }
        return String(lines.joined(separator: "\n").prefix(12_000))
    }
}

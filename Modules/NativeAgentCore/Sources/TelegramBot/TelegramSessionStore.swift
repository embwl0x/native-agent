import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import TurnTrace
import Transcripts

// Blueprint: | `TelegramSessionStore.swift` | `TelegramSessionStore`: locked session mint/adoption and delivery mapping with exact resolution traces; the shared anchor selects the owner's ordinary conversation; owner resume/list admission requires a live direct row before binding |

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
    case sessionNotResumable(String)
    case ambiguousSessionPrefix(String, [String])
    case sessionStorageUnavailable
    case anchorSelectionRefused(String)

    public var errorDescription: String? {
        switch self {
        case .anchorSelectionRefused(let reason):
            return "telegram_conversation_selection_failed: The shared conversation selection was refused (\(reason)). Read /session before trying another selection."
        case .sessionStorageUnavailable:
            return "telegram_conversation_store_unavailable: Conversation bindings cannot be read. Repair telegram/session_map.json before using /resume; inspect the conversation list before changing bindings."
        case .missingSessionId:
            return "telegram_conversation_id_required: Send /sessions, then /resume <id> with a conversation ID."
        case .sessionNotFound(let id):
            return "telegram_conversation_not_found: No conversation matches '\(id)'. Send /sessions, then /resume <id> with a listed ID."
        case .sessionNotResumable(let id):
            return "telegram_conversation_not_resumable: '\(id)' is not a live direct conversation. Send /sessions for resumable conversations."
        case .ambiguousSessionPrefix(let prefix, let matches):
            return "telegram_conversation_ambiguous: '\(prefix)' matches \(matches.prefix(5).joined(separator: ", ")). Send /resume with a longer conversation ID."
        }
    }
}

public struct TelegramSessionStore: Sendable {
    public let dataRoot: URL

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    public func activeSessionId(destination: TelegramDestination) async throws -> String {
        let activityAt = Date()
        let chatKey = Self.chatKey(destination)
        if isOwnerDestination(destination) {
            // The map records the session used for delivery recovery; only the
            // shared anchor selects the owner's ordinary direct conversation.
            let resolved = try await patchChatMap(chatKey: chatKey) { entry -> (id: String, resolution: SessionIdentityTrace.Resolution) in
                let initialSession: String?
                // The map can hold a thread an invalid anchor once named; it
                // stands only while it may still be his conversation.
                if case .string(let id)? = entry["activeSessionId"],
                   ConversationAnchor.mayAnchor(id, dataRoot: dataRoot) { initialSession = id }
                else { initialSession = nil }
                let sessionId: String
                let resolution: SessionIdentityTrace.Resolution
                if let anchor = ConversationAnchor.currentSessionId(dataRoot: dataRoot) {
                    sessionId = anchor
                    resolution = initialSession == anchor ? .mapped : .adopted
                } else if let initialSession {
                    sessionId = initialSession
                    resolution = .mapped
                } else {
                    sessionId = UUID().uuidString
                    resolution = .minted
                }
                if entry["createdAt"] == nil { entry["createdAt"] = .string(Self.nowString()) }
                entry["activeSessionId"] = .string(sessionId)
                entry["updatedAt"] = .string(Self.nowString())
                return (sessionId, resolution)
            }
            try await ensureSessionRow(id: resolved.id, destination: destination, title: Self.sessionTitle(destination))
            if ConversationAnchor.currentSessionId(dataRoot: dataRoot) == nil {
                try? await publishAnchor(sessionId: resolved.id, destination: destination, activityAt: activityAt)
            }
            emitIdentityTrace(sessionId: resolved.id, destination: destination, resolvedBy: resolved.resolution)
            return resolved.id
        }
        if let mapped = try await mappedSessionId(chatKey: chatKey), !mapped.isEmpty {
            try await ensureSessionRow(id: mapped, destination: destination, title: Self.sessionTitle(destination))
            try? await publishAnchor(sessionId: mapped, destination: destination, activityAt: activityAt)
            emitIdentityTrace(sessionId: mapped, destination: destination, resolvedBy: .mapped)
            return mapped
        }
        // Mint or adopt the session inside the chat-map lock so concurrent first messages agree.
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
        // Create the row for the session selected under the lock.
        try await ensureSessionRow(id: resolved, destination: destination, title: Self.sessionTitle(destination))
        try? await publishAnchor(sessionId: resolved, destination: destination, activityAt: activityAt)
        emitIdentityTrace(
            sessionId: resolved,
            destination: destination,
            resolvedBy: adopted ? .adopted : .minted
        )
        return resolved
    }

    public func startNewSession(destination: TelegramDestination) async throws -> String {
        let activityAt = Date()
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
        try await publishAnchor(sessionId: sessionId, destination: destination, activityAt: activityAt)
        emitIdentityTrace(sessionId: sessionId, destination: destination, resolvedBy: .minted)
        return sessionId
    }

    // MARK: - Anchor + identity instrumentation
    //
    // The owner's DM consumes the shared anchor. Explicit session selection
    // publishes it; groups and other people's conversations cannot move it.

    private func publishAnchor(sessionId: String, destination: TelegramDestination, activityAt: Date) async throws {
        // Only the authenticated owner's private chat may move the anchor.
        guard isOwnerDestination(destination) else { return }
        // Explicit selections require this owner's committed outcome. Ordinary
        // message admission may proceed if its activity publication fails.
        let outcome = try await ConversationAnchor.publish(
            sessionId: sessionId,
            source: Self.anchorSource,
            conversationKind: .direct,
            dataRoot: dataRoot, now: activityAt
        )
        if case .refused(let reason) = outcome {
            throw TelegramSessionStoreError.anchorSelectionRefused(reason.rawValue)
        }
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

    private func isOwnerDestination(_ destination: TelegramDestination) -> Bool {
        guard destination.chatId > 0, destination.threadId == nil,
              let owner = TelegramConfig.loadFromDisk(dataRoot: dataRoot)?.ownerUserId else { return false }
        return owner == Int64(destination.chatId)
    }

    public func persona(destination: TelegramDestination) async throws -> String? {
        PersonaSelection.current()
    }

    public func setPersona(destination: TelegramDestination, persona: String) async throws -> String {
        let trimmed = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isOwnerDestination(destination) else {
            throw TelegramBotError.invalidRequest
        }
        PersonaSelection.select(trimmed)
        return trimmed
    }

    public func status(destination: TelegramDestination) async throws -> TelegramSessionStatus {
        let sessionId = try await activeSessionId(destination: destination)
        return try await status(destination: destination, sessionId: sessionId)
    }

    private func status(destination: TelegramDestination, sessionId: String) async throws -> TelegramSessionStatus {
        let persona = try await persona(destination: destination) ?? "NativeAgent"
        let messages = (try? await SwiftNativePersistenceCore.readJSONL(messagesPath(sessionId: sessionId))) ?? []
        return TelegramSessionStatus(
            chatId: destination.chatId,
            sessionId: sessionId,
            persona: persona,
            messageCount: messages.count
        )
    }

    private func isAccessibleSession(_ value: JSONValue, destination: TelegramDestination, ownerAccess: Bool) -> Bool {
        if ownerAccess { return true }
        guard case .object(let row) = value,
              row["source"] == .string("telegram"),
              row["sourceKey"] == .string(Self.legacySessionId(destination)) else { return false }
        return true
    }

    private func isResumableSession(_ value: JSONValue, destination: TelegramDestination, ownerAccess: Bool, ownerDestination: Bool) -> Bool {
        guard isAccessibleSession(value, destination: destination, ownerAccess: ownerAccess),
              case .object(let row) = value, row["archived"] != .bool(true) else { return false }
        guard ownerDestination else { return true }
        guard case .string(let id)? = row["id"] else { return false }
        return SessionConversation(rows: [row]).kind(id)?.isHisConversation == true
    }

    public func recentSessions(destination: TelegramDestination, fromUserId: Int?, limit: Int = 8) async throws -> [TelegramRecentSession] {
        let cappedLimit = max(1, min(limit, 25))
        let rows = try await SwiftNativePersistenceCore.readJSON(sessionsPath, ifMissing: .array([]))
        guard case .array(let array) = rows else { return [] }
        let ownerDestination = isOwnerDestination(destination)
        let ownerAccess = fromUserId == destination.chatId && ownerDestination
        let sessions = array
            .filter { isResumableSession($0, destination: destination, ownerAccess: ownerAccess, ownerDestination: ownerDestination) }
            .compactMap(Self.recentSession(from:))
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                (lhs.updatedAt ?? "") > (rhs.updatedAt ?? "")
            }
        return Array(sessions.prefix(cappedLimit))
    }

    public func bindSession(
        destination: TelegramDestination,
        requestedSessionId rawSessionId: String,
        fromUserId: Int? = nil
    ) async throws -> TelegramSessionStatus {
        let activityAt = Date()
        let sessionId = try await resolveExistingSessionId(rawSessionId, destination: destination, fromUserId: fromUserId)
        try await ChatSessionIndexFile.mutate(at: sessionsPath) { rows in
            let ownerDestination = isOwnerDestination(destination)
            guard let row = rows.first(where: { $0["id"] == .string(sessionId) }),
                  isResumableSession(.object(row), destination: destination,
                    ownerAccess: fromUserId == destination.chatId && ownerDestination, ownerDestination: ownerDestination) else {
                throw TelegramSessionStoreError.sessionNotResumable(sessionId)
            }
            try await patchChatMap(chatKey: Self.chatKey(destination)) { entry in
                if entry["createdAt"] == nil { entry["createdAt"] = .string(Self.nowString()) }
                entry["activeSessionId"] = .string(sessionId)
                entry["updatedAt"] = .string(Self.nowString())
            }
        }
        // `/resume` moves the conversation User is in, so it moves the anchor —
        // same fact, same hook. Without this the Mac and phone would keep
        // pinning the session he just left.
        try await publishAnchor(sessionId: sessionId, destination: destination, activityAt: activityAt)
        emitIdentityTrace(sessionId: sessionId, destination: destination, resolvedBy: .requested)
        return try await status(destination: destination, sessionId: sessionId)
    }

    public func writeScratch(destination: TelegramDestination, key: String, value: String) async throws -> String {
        let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty, !cleanedValue.isEmpty else {
            throw TelegramBotError.invalidRequest
        }
        let sessionId = try await activeSessionId(destination: destination)
        try await ChatSessionScratch.write(dataRoot: dataRoot, sessionID: sessionId, key: cleanedKey, value: cleanedValue)
        return sessionId
    }

    /// The conversation a private chat is in now, or nil.
    public func boundSessionId(chatId: Int) async -> String? {
        if isOwnerDestination(.chat(chatId)) {
            return ConversationAnchor.currentSessionId(dataRoot: dataRoot)
        }
        return try? await mappedSessionId(chatKey: String(chatId))
    }

    public func outboundDestination(sessionId: String) async throws -> TelegramDestination? {
        guard let config = try TelegramConfig.loadSavedConfiguration(dataRoot: dataRoot), config.enabled else { return nil }
        if let owner = config.ownerUserId, let chatId = Int(exactly: owner),
           ConversationAnchor.currentSessionId(dataRoot: dataRoot) == sessionId,
           TelegramPollLoop.inboundAuthorizationDecision(
            allowedChatIds: config.allowedChatIds, allowedUserIds: config.allowedUserIds,
            chatId: chatId, fromUserId: chatId) == .allowed {
            return .chat(chatId)
        }
        return try await SwiftNativePersistenceCore.withFileLock(sessionMapPath) {
            guard case .object(let chats)? = try loadSessionMap()["chats"] else { return nil }
            for (key, value) in chats {
                guard case .object(let entry) = value, entry["activeSessionId"] == .string(sessionId) else { continue }
                let parts = key.split(separator: ":", maxSplits: 1)
                guard let first = parts.first, let chatId = Int(first) else { continue }
                let threadId = parts.count > 1 ? Int(parts[1]) : nil
                guard parts.count == 1 || threadId != nil else { continue }
                let destination = TelegramDestination(chatId: chatId, threadId: threadId)
                if threadId != nil || config.ownerUserId != Int64(chatId) { return destination }
            }
            return nil
        }
    }

    private func mappedSessionId(chatKey: String) async throws -> String? {
        guard let entry = try await chatMapEntry(chatKey: chatKey),
              case .string(let id)? = entry["activeSessionId"] else {
            return nil
        }
        return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chatMapEntry(chatKey: String) async throws -> [String: JSONValue]? {
        try await SwiftNativePersistenceCore.withFileLock(sessionMapPath) {
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
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            var root = try loadSessionMap()
            guard case .object(var chats)? = root["chats"] else {
                throw TelegramSessionStoreError.sessionStorageUnavailable
            }
            var entry: [String: JSONValue]
            if case .object(let obj)? = chats[chatKey] { entry = obj } else { entry = [:] }
            let result = mutate(&entry)
            chats[chatKey] = .object(entry)
            root["chats"] = .object(chats)
            try await SwiftNativePersistenceCore.writeJSON(.object(root), to: path)
            return result
        }
    }

    private func ensureSessionRow(
        id: String, destination: TelegramDestination, title: String,
        commitBinding: @Sendable () async throws -> Void = {}
    ) async throws {
        try await ChatSessionIndexFile.ensureSession(
            id: id, title: title, source: "telegram", sourceKey: Self.legacySessionId(destination),
            kind: destination.chatId > 0 && destination.threadId == nil ? .direct : .channel,
            dataRoot: dataRoot, context: "TelegramSessionStore.ensureSessionRow", commitBinding: commitBinding
        )
    }

    private func resolveExistingSessionId(_ raw: String, destination: TelegramDestination, fromUserId: Int?) async throws -> String {
        let requested = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            throw TelegramSessionStoreError.missingSessionId
        }
        let rows = try await SwiftNativePersistenceCore.readJSON(sessionsPath, ifMissing: .array([]))
        guard case .array(let array) = rows else {
            throw TelegramSessionStoreError.sessionNotFound(requested)
        }
        let ownerAccess = fromUserId == destination.chatId && isOwnerDestination(destination)
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

    private static func chatKey(_ destination: TelegramDestination) -> String {
        guard let threadId = destination.threadId else { return String(destination.chatId) }
        return "\(destination.chatId):\(threadId)"
    }

    public static func legacySessionId(_ chatId: Int) -> String {
        "telegram:\(chatId)"
    }

    /// Source keys are `telegram:<chatId>` or `telegram:<chatId>:<threadId>` for forum topics.
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

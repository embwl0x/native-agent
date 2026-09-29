import Transcripts
import Foundation
import Observation
import Darwin
import ChatOrchestration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

public enum ChatMessageClearError: Error, LocalizedError, Sendable {
    case transcriptClearedMetadataNotSaved(String)
    case transcriptVersionExhausted

    public var errorDescription: String? {
        switch self {
        case .transcriptClearedMetadataNotSaved(let reason):
            return "Messages were cleared, but conversation metadata could not be saved: \(reason)"
        case .transcriptVersionExhausted:
            return "This conversation's transcript version cannot advance any further, so clearing it could not be published to your other devices. Nothing was deleted."
        }
    }
}

/// One transcript, projected for the UI: the messages a view renders and
/// the recollections the same rows carry, read together.
public struct ChatTranscriptProjection: Sendable {
    public let messages: [ChatMessage]
    /// Oldest first, exactly as `ChatSessionRecollections.recollections`
    /// returns them — this is that parser, over rows already decoded.
    public let recollections: [ChatSessionRecollection]

    public static let empty = ChatTranscriptProjection(messages: [], recollections: [])
    public init(messages: [ChatMessage], recollections: [ChatSessionRecollection]) {
        self.messages = messages
        self.recollections = recollections
    }

}

/// `NativeAgentEngine.transcripts` (S10): the chat session index
/// (`chat/sessions.json`) and the transcripts (`chat/messages/<id>.jsonl`) for
/// one data root, in core types. The session list and the loaded transcripts
/// are observable state the chat window, the sidebar, Simple view, detached
/// panels, Status and Today render; the reads and writes are nonisolated so
/// the phone lanes use the same owner.
@MainActor
@Observable
public final class TranscriptsFacade {
    public nonisolated let dataRoot: URL

    /// The session index as of the last read.
    public var sessions: [NativeAgentShared.ChatSession] = []

    // 2026-06-08 detached-chat-windows W0.2: per-session transcript storage,
    // so detached panels bind to any session without going through the main
    // window's selection.
    //
    // 2026-09-06: the transcript's mutation counter. The message-list grouper
    // used to detect "same list" with count + tail row + total content bytes;
    // an interior row replaced with the same byte count, or changed only in
    // its metadata, passed all three and the view kept stale groups. Every
    // write to the transcript goes through the computed `messagesBySession`
    // below, so the counter cannot be forgotten by a new writer.
    // `structureVersion` is the cache key: it skips the streaming delta, which
    // rewrites only the final row and which the list patches in place rather
    // than re-walking the whole transcript.
    /// 2026-09-14 (snappiness): the transcript's rows are not an observed
    /// STORED property. Structure — appends, removals, wholesale replaces —
    /// publishes through the computed `messagesBySession` below, which does
    /// the `access`/`withMutation` by hand. The streaming delta rewrites the
    /// final row's content straight in this storage and publishes to that
    /// row's own `ChatStreamingTailBox` instead, so a token invalidates one
    /// leaf bubble rather than every view that reads the transcript. Readers
    /// still see current bytes on their next read; what they no longer get is
    /// a re-render 14 times a second.
    @ObservationIgnored private var storage: [String: [ChatMessage]] = [:]
    @ObservationIgnored private var tailOnlyWrite = false
    public private(set) var structureVersion: UInt64 = 0
    public var messagesBySession: [String: [ChatMessage]] {
        get {
            access(keyPath: \.messagesBySession)
            return storage
        }
        set {
            withMutation(keyPath: \.messagesBySession) {
                storage = newValue
                if !tailOnlyWrite { structureVersion &+= 1 }
                tailOnlyWrite = false
            }
        }
    }

    /// The live content of one streaming row, observed by that row's bubble
    /// and by nothing else.
    ///
    /// Boxes are handed out per message id and created on demand, so the
    /// bubble can take one before the first chunk exists and a placeholder
    /// that migrates to a confirmed session id keeps the box it already has.
    @ObservationIgnored private var streamingTailBoxes: [String: ChatStreamingTailBox] = [:]
    @ObservationIgnored private var streamingTailBoxOrder: [String] = []

    /// Keeps the converted disk projection separate from optimistic/streaming
    /// UI rows, for the window's own reads.
    public nonisolated let cache = ChatTranscriptCache()

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    // MARK: - Loaded transcripts

    /// One session's loaded messages; empty when none are loaded.
    public func messages(for sessionId: String) -> [ChatMessage] {
        messagesBySession[sessionId] ?? []
    }

    public func setMessages(_ messages: [ChatMessage], for sessionId: String) {
        messagesBySession[sessionId] = messages
    }

    /// The box for `messageId`, created if this is the first ask. Cheap enough
    /// to call from a view body: one dictionary lookup, no observation.
    public func streamingTailBox(forMessage messageId: String) -> ChatStreamingTailBox {
        if let existing = streamingTailBoxes[messageId] { return existing }
        let box = ChatStreamingTailBox()
        streamingTailBoxes[messageId] = box
        streamingTailBoxOrder.append(messageId)
        // A handful of live tails at once (the main window, detached panels,
        // parallel sessions) is the whole working set; older rows are settled
        // and render from the transcript.
        while streamingTailBoxOrder.count > 8 {
            streamingTailBoxes.removeValue(forKey: streamingTailBoxOrder.removeFirst())
        }
        return box
    }

    /// Write `messages` knowing that only the FINAL row differs from what is
    /// there now. The one caller is the streaming delta (2026-09-06).
    public func setMessagesTailOnly(_ messages: [ChatMessage], for sessionId: String) {
        tailOnlyWrite = true
        messagesBySession[sessionId] = messages
    }

    /// Rewrite the content of the FINAL row in place, without extracting the
    /// transcript, searching it, and writing a whole mutated copy back.
    ///
    /// 2026-09-13 (snappiness): this is the streaming delta's write — ~14 a
    /// second for the length of a reply, on the main actor. The old route
    /// (`messagesBySession[sessionId]` → `firstIndex(where: id ==)` → mutate
    /// the copy → write the dictionary back) did a linear pass of string
    /// comparisons over the whole transcript and a dictionary copy per chunk,
    /// so a long conversation paid for its own length on every chunk. Going
    /// straight at the storage through the `_modify` accessors is the same
    /// observation with none of that. Returns false when the tail is not
    /// `messageId` — the caller falls back to the general path, which is where
    /// an interior rewrite belongs.
    public func setTailMessageContent(_ content: String, id messageId: String, in sessionId: String) -> Bool {
        guard let count = storage[sessionId]?.count, count > 0,
              storage[sessionId]?[count - 1].id == messageId
        else { return false }
        // Straight at the storage: the computed `messagesBySession` setter is
        // what bumps `structureVersion`, and a tail content rewrite must not
        // bump it (that is exactly what `setMessagesTailOnly` exists to
        // suppress).
        storage[sessionId]?[count - 1].content = content
        // The one publication a streamed chunk makes: the leaf bubble for this
        // exact row. Nothing else observes it, so the parent list keeps its
        // structural snapshot and its layout.
        streamingTailBox(forMessage: messageId).content = content
        return true
    }

    // MARK: - Paths

    nonisolated private var chatRoot: URL {
        dataRoot.appendingPathComponent("chat", isDirectory: true)
    }

    nonisolated private var sessionsPath: URL {
        chatRoot.appendingPathComponent("sessions.json")
    }

    // MARK: - Reads

    /// The session index, after retention has run under the same lock.
    /// Missing file → `[]`.
    public nonisolated func list() async throws -> [NativeAgentShared.ChatSession] {
        let dataRoot = self.dataRoot
        let url = sessionsPath
        let rows = try await SwiftNativePersistenceCore().withFileLock(url) {
            _ = try ChatSessionRetention.enforce(
                dataRoot: dataRoot,
                now: Date()
            )
            return try ChatSessionIndexFile.loadObjectRowsForMutation(at: url)
        }
        return try rows.map(NativeAgentShared.ChatSession.init(row:))
    }

    public nonisolated func loadMessages(sessionId: String, cached: Bool = false) async throws -> [ChatMessage] {
        try await loadTranscript(sessionId: sessionId, cached: cached).messages
    }

    /// Messages AND recollections from one read of one transcript.
    ///
    /// User, 2026-09-13 (speed): Today used to take its eight transcripts
    /// through the cache for messages and then have its snapshot read and
    /// parse the same eight JSONL files again for recollections. Both answers
    /// come from the same decoded rows, so they are decoded once. `cached`
    /// reads go through the window's projection cache.
    public nonisolated func loadTranscript(sessionId: String, cached: Bool = false) async throws -> ChatTranscriptProjection {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return .empty
        }
        guard cached else { return try await readTranscript(safeSessionId: safeSessionId) }
        let path = dataRoot.appendingPathComponent("chat/messages/\(safeSessionId).jsonl")
        return try await cache.projection(at: path) {
            try await self.readTranscript(safeSessionId: safeSessionId)
        }
    }

    nonisolated private func readTranscript(safeSessionId: String) async throws -> ChatTranscriptProjection {
        // The native SessionHistoryReader reads `chat/messages/<id>.jsonl` and
        // resolves legacy text/timestamp aliases; each row's `extras` is the
        // raw transcript row, which carries id, runId, source and the tool-pill
        // metadata (kind/toolName/inputJSON/resultSummary) the streaming
        // tool-loop persists.
        let reader = ChatOrchestration.SessionHistoryReader(dataRoot: dataRoot)
        let history = try await reader.messagesWithStats(forSessionId: safeSessionId)
        // Prompt history intentionally tolerates damaged rows, but an empty
        // result caused by a failed read is not a successfully loaded UI
        // transcript. Propagate that failure to transactional session selection
        // so it keeps the previous conversation instead of replacing it.
        guard history.stats.mode != "read_failed" else {
            throw NSError(
                domain: "NativeClient.ChatHistory", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The saved conversation could not be read. Its data was left unchanged."]
            )
        }
        let rejectedRows = history.stats.malformedRowCount + history.stats.invalidShapeRowCount
        guard !history.messages.isEmpty || rejectedRows == 0 else {
            throw NSError(
                domain: "NativeClient.ChatHistory", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The saved conversation has no readable messages (\(rejectedRows) damaged rows). Its data was left unchanged."]
            )
        }
        // Missing/empty new sessions remain valid, and mixed transcripts keep
        // their readable rows under the existing tolerant reader contract.
        let coMessages = history.messages
        // The canonical recollection parser, over the rows this read already
        // decoded. `extras` is the raw transcript row, which is exactly what
        // `ChatSessionRecollections.recollections` parses per line — so this
        // is the same answer without a second pass over the file.
        let recollections = coMessages.compactMap { co -> ChatSessionRecollection? in
            guard let extras = co.extras else { return nil }
            return ChatSessionRecollections.recollection(
                fromTranscriptRow: extras,
                sessionId: safeSessionId
            )
        }
        let messages = coMessages.map { co -> ChatMessage in
            guard case .object(let row)? = co.extras else {
                return ChatMessage(
                    sessionId: safeSessionId,
                    role: co.role,
                    content: co.content,
                    createdAt: co.timestamp
                )
            }
            var message = ChatMessage(row: row)
            // A fork keeps its source rows byte-for-byte, including their
            // original session IDs. This UI projection belongs to the
            // requested transcript; actions on an inherited row must not
            // jump back to the source conversation. Recorded metadata and
            // on-disk provenance remain untouched.
            message.sessionId = safeSessionId
            // The history reader already resolves legacy text/timestamp
            // aliases; the row's own fields must not replace them with defaults.
            message.content = co.content
            if !co.timestamp.isEmpty { message.createdAt = co.timestamp }
            return message
        }
        return ChatTranscriptProjection(messages: messages, recollections: recollections)
    }

    // MARK: - Writes

    /// A new session row at the top of the index.
    public nonisolated func create(title: String, sourceKey: String? = nil) async throws -> NativeAgentShared.ChatSession {
        let dataRoot = self.dataRoot
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        var sessionRow: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "source": .string("app"),
            "createdAt": .string(now),
            "updatedAt": .string(now),
            "archived": .bool(false),
            "messageCount": .int(0),
        ]
        if let sourceKey, !sourceKey.isEmpty { sessionRow["sourceKey"] = .string(sourceKey) }
        let rowToInsert = sessionRow
        let sessionsPath = self.sessionsPath
        try await SwiftNativePersistenceCore().withFileLock(sessionsPath) {
            let parent = sessionsPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var sessions = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            sessions.insert(rowToInsert, at: 0)
            let out = try ChatSessionIndexFile.serializedData(for: sessions)
            try out.write(to: sessionsPath, options: .atomic)
            ChatSessionRetention.enforceBestEffort(
                dataRoot: dataRoot,
                now: Date(),
                context: "TranscriptsFacade.create"
            )
        }
        return try NativeAgentShared.ChatSession(row: sessionRow)
    }

    /// Patch a session's title (rename) and/or archived flag.
    public nonisolated func update(id: String, title: String?, archived: Bool?) async throws -> NativeAgentShared.ChatSession {
        let sessionsPath = self.sessionsPath
        let nowIso = ISO8601DateFormatter().string(from: Date())
        let updated: [String: JSONValue]? = try await SwiftNativePersistenceCore().withFileLock(sessionsPath) {
            var sessions = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            guard let idx = sessions.firstIndex(where: { $0["id"] == .string(id) }) else { return nil }
            var row = sessions[idx]
            if let title { row["title"] = .string(title) }
            if let archived { row["archived"] = .bool(archived) }
            // A rename is not a conversation event: the row's time is
            // when someone last spoke, so only an archive flip bumps it.
            if archived != nil { row["updatedAt"] = .string(nowIso) }
            sessions[idx] = row
            let out = try ChatSessionIndexFile.serializedData(for: sessions)
            try out.write(to: sessionsPath, options: .atomic)
            return row
        }
        guard let updated else {
            throw NSError(domain: "NativeAgent", code: -404,
                          userInfo: [NSLocalizedDescriptionKey: "chat session \(id) not found"])
        }
        return try NativeAgentShared.ChatSession(row: updated)
    }

    /// A user-initiated archive leaves the hot index immediately. Retention
    /// later bounds the archive tier, but it must not be responsible for the
    /// visible archive action: an archived chat may never linger in
    /// `sessions.json` or be appended twice to the archive tail.
    public nonisolated func archive(
        id: String,
        afterArchiveTailWrite: (@Sendable () throws -> Void)? = nil
    ) async throws -> NativeAgentShared.ChatSession? {
        guard NativeAgentChatSessionID.normalizedPathComponent(id) != nil else { return nil }
        let sessionsPath = self.sessionsPath
        let archivePath = chatRoot
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("sessions.jsonl")
        return try await SwiftNativePersistenceCore().withFileLock(sessionsPath) {
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            guard let index = rows.firstIndex(where: { $0["id"] == .string(id) }) else { return nil }

            var archived = rows[index]
            archived["archived"] = .bool(true)
            archived["archivedBy"] = .string("mac_chat")
            archived["archivedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
            let archivedData = try JSONValue.object(archived).serializedData(pretty: false)

            try FileManager.default.createDirectory(
                at: archivePath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let existingTail: Data
            if FileManager.default.fileExists(atPath: archivePath.path) {
                existingTail = try Data(contentsOf: archivePath)
            } else {
                existingTail = Data()
            }
            var archivedIDs = Set<String>()
            for line in existingTail.split(separator: 10) {
                guard let value = try? JSONValue.parse(Data(line)),
                      case .object(let row) = value,
                      case .string(let archivedID)? = row["id"] else {
                    throw NSError(domain: "NativeAgent", code: -422, userInfo: [
                        NSLocalizedDescriptionKey: "chat archive tail is unreadable; refusing to overwrite it"
                    ])
                }
                archivedIDs.insert(archivedID)
            }
            let alreadyArchived = archivedIDs.contains(id)
            if !alreadyArchived {
                var nextTail = existingTail
                if !nextTail.isEmpty, nextTail.last != 10 { nextTail.append(10) }
                nextTail.append(archivedData)
                // Retention appends JSONL records with FileHandle; terminate
                // this record so its next append cannot concatenate objects.
                nextTail.append(10)
                try nextTail.write(to: archivePath, options: .atomic)
            }

            // The tail is the durable claim. If the index commit faults after
            // it lands, a retry sees this same id in the tail and only removes
            // the live row; it never appends another archival record.
            try afterArchiveTailWrite?()
            rows.remove(at: index)

            if rows.isEmpty {
                try FileManager.default.removeItem(at: sessionsPath)
            } else {
                try ChatSessionIndexFile.serializedData(for: rows)
                    .write(to: sessionsPath, options: .atomic)
            }
            return try NativeAgentShared.ChatSession(row: archived)
        }
    }

    /// Empty one transcript (`chat/messages/<id>.jsonl`) under its lock and
    /// publish the empty on the index row. Every live writer
    /// (ChatOrchestrationClient.appendMessage / persistPartialIfNeeded /
    /// SessionHistoryReader / iOS-bridge forward) uses this FLAT path; any
    /// stale nested file left over from the earlier
    /// `chat/sessions/<id>/messages.jsonl` shape is removed too.
    public nonisolated func clear(
        sessionId: String,
        afterTranscriptClear: (@Sendable () async throws -> Void)? = nil
    ) async throws {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw NSError(
                domain: "NativeAgentChatSession",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Cannot clear chat messages: invalid chat session id"]
            )
        }
        let messagesPath = chatRoot
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let staleNestedPath = chatRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(safeSessionId, isDirectory: true)
            .appendingPathComponent("messages.jsonl")
        let persistence = SwiftNativePersistenceCore()
        let sessionsPath = self.sessionsPath
        // Refuse known index corruption before deleting any transcript bytes.
        // Keep locks separate: other writers have their own transcript/index
        // ordering, so clear must not add a nested cross-file lock dependency.
        _ = try await persistence.withFileLock(sessionsPath) {
            let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            // 2026-09-06: a row whose transcript counter has hit the ceiling
            // can never prove the empty this clear is about to publish is the
            // newest state, so the phone would refuse it and keep showing the
            // conversation the Mac just deleted. Refuse here, before any
            // transcript byte is gone, rather than half-clear the pair.
            if let row = rows.first(where: { $0["id"] == .string(safeSessionId) }),
               ChatSessionIndexFile.isTranscriptGenerationExhausted(in: row) {
                NSLog("TranscriptsFacade.clear: refusing to clear \(safeSessionId) — its transcript version is at Int64.max and cannot advance")
                throw ChatMessageClearError.transcriptVersionExhausted
            }
            return rows
        }
        try await persistence.withFileLock(messagesPath) {
            let parent = messagesPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data().write(to: messagesPath, options: .atomic)
            if FileManager.default.fileExists(atPath: staleNestedPath.path) {
                try? FileManager.default.removeItem(at: staleNestedPath)
            }
        }
        do {
            try await afterTranscriptClear?()
            try await persistence.withFileLock(sessionsPath) {
                var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
                // A real append after clear owns the new index projection. Its
                // normal writer will synchronize it; never zero its preview.
                guard try messagesPath.resourceValues(forKeys: [.fileSizeKey]).fileSize == 0,
                      let index = rows.firstIndex(where: { $0["id"] == .string(safeSessionId) })
                else { return }
                rows[index]["messageCount"] = .int(0)
                rows[index]["lastMessagePreview"] = .null
                rows[index]["updatedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
                // 2026-09-06: the clear is what makes the published transcript
                // EMPTY, and an empty transcript is the one publication a
                // remote reader is allowed to wipe a chat for. It may only do
                // that when it can prove the empty is newer than what it
                // shows, and this counter is that proof — the wall clock above
                // is not, since it can step back and it moves for reasons that
                // are not transcript writes.
                ChatSessionIndexFile.bumpTranscriptGeneration(in: &rows[index])
                try await persistence.writeJSON(.array(rows.map(JSONValue.object)), to: sessionsPath)
            }
        } catch {
            throw ChatMessageClearError.transcriptClearedMetadataNotSaved(error.localizedDescription)
        }
    }
}

/// Keeps the converted disk projection separate from optimistic/streaming
/// UI rows. A hit still passes through the existing selection lifecycle and
/// synthetic-row merge, and context receipts are independently refreshed.
public actor ChatTranscriptCache {
    private struct Entry {
        let identity: String
        let projection: ChatTranscriptProjection
    }

    private var entries: [String: Entry] = [:]
    private var recentPaths: [String] = []
    private let maximumSessions = 8

    public func projection(
        at path: URL,
        load: @Sendable () async throws -> ChatTranscriptProjection
    ) async throws -> ChatTranscriptProjection {
        let key = path.path
        let before = Self.identity(at: path)
        if let before, let entry = entries[key], entry.identity == before {
            touch(key)
            return entry.projection
        }
        entries[key] = nil
        recentPaths.removeAll { $0 == key }
        let projection = try await load()
        // A writer can advance the file while the asynchronous loader is
        // running. Return that read under the existing selection semantics,
        // but never certify it as the projection of a different revision.
        if let before, Self.identity(at: path) == before {
            entries[key] = Entry(identity: before, projection: projection)
            touch(key)
            while recentPaths.count > maximumSessions {
                entries[recentPaths.removeFirst()] = nil
            }
        }
        return projection
    }

    private func touch(_ key: String) {
        recentPaths.removeAll { $0 == key }
        recentPaths.append(key)
    }

    private static func identity(at path: URL) -> String? {
        var info = stat()
        // Do not cache missing paths, symlinks, nonregular entries or failed
        // inspections. ctime catches same-size rewrites with restored mtime
        // as well as permission changes; inode catches atomic replacement.
        guard lstat(path.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }
}

// Session transactions use the same canonical read/write owner as every surface.
extension TranscriptsFacade: MacChatSessionStore {}

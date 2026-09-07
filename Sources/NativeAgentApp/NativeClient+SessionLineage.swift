import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

enum SessionLineageError: Error, LocalizedError, Equatable {
    case invalidSessionID
    case sourceNotFound
    case forkPointNotFound
    case targetCollision
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .invalidSessionID: "The conversation identifier is invalid."
        case .sourceNotFound: "The source conversation no longer exists."
        case .forkPointNotFound: "The selected fork point is no longer in the source transcript."
        case .targetCollision: "A new conversation could not be allocated safely."
        case .sessionNotFound: "The conversation no longer exists."
        }
    }
}

extension NativeClient {
    func forkChatSession(
        sourceSessionId: String,
        throughMessageId: String? = nil,
        title: String? = nil
    ) async throws -> ChatSession {
        // 2026-09-06: fork the selected client's store, never another install's transcript.
        try await Self.forkChatSession(
            sourceSessionId: sourceSessionId,
            throughMessageId: throughMessageId,
            title: title,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    static func forkChatSession(
        sourceSessionId: String,
        throughMessageId: String? = nil,
        title: String? = nil,
        dataRoot: URL
    ) async throws -> ChatSession {
        guard let safeSourceID = NativeAgentChatSessionID.normalizedPathComponent(sourceSessionId) else {
            throw SessionLineageError.invalidSessionID
        }
        let root = dataRoot.standardizedFileURL
        let chatRoot = root.appendingPathComponent("chat", isDirectory: true)
        let sessionsPath = chatRoot.appendingPathComponent("sessions.json")
        let messagesRoot = chatRoot.appendingPathComponent("messages", isDirectory: true)
        let sourcePath = messagesRoot.appendingPathComponent("\(safeSourceID).jsonl")
        let persistence = SwiftNativePersistenceCore()

        let sourceSession: ChatSession = try await persistence.withFileLock(sessionsPath) {
            let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            guard let row = rows.first(where: {
                if case .string(let id)? = $0["id"] { return id == safeSourceID }
                return false
            }) else { throw SessionLineageError.sourceNotFound }
            let data = try JSONValue.object(row).serializedData(pretty: false)
            return try JSONDecoder.nativeAgent.decode(ChatSession.self, from: data)
        }

        let newID = UUID().uuidString
        guard let safeNewID = NativeAgentChatSessionID.normalizedPathComponent(newID) else {
            throw SessionLineageError.targetCollision
        }

        let transcript: (data: Data, count: Int, preview: String?) = try await persistence.withFileLock(sourcePath) {
            guard FileManager.default.fileExists(atPath: sourcePath.path) else {
                if throughMessageId != nil { throw SessionLineageError.forkPointNotFound }
                return (Data(), 0, nil)
            }
            let sourceData = try Data(contentsOf: sourcePath)
            let lines = sourceData.split(separator: 0x0A, omittingEmptySubsequences: true)
            var kept: [Data] = []
            var found = throughMessageId == nil
            var preview: String?
            for raw in lines {
                let line = Data(raw)
                var emitted = line
                var reachedForkPoint = false
                if let value = try? JSONValue.parse(line), case .object(var object) = value {
                    if case .string(let content)? = object["content"], !content.isEmpty {
                        preview = String(content.replacingOccurrences(of: "\n", with: " ").prefix(160))
                    }
                    if let throughMessageId,
                       case .string(let id)? = object["id"],
                       id == throughMessageId {
                        reachedForkPoint = true
                    }
                    // 2026-09-06: the copy used to keep the SOURCE session's id
                    // on every row, so the fork's transcript claimed to belong
                    // to another session. Orphan recovery reads that as
                    // corruption and refuses to rebuild the index row
                    // (ChatSessionIndexReconciler), and every reader that
                    // selects a session's rows by `sessionId` — the outcome
                    // stores, the conversation anchor — matched none of them.
                    // Lineage lives on the index row (parentSessionId /
                    // rootSessionId / forkedAtMessageId), not here.
                    // 2026-09-06: stamp rows that carry NO `sessionId` too. Only
                    // rewriting the key where it already existed left a copied
                    // row with no session at all — an orphan in the fork's own
                    // transcript, invisible to every reader that selects by
                    // sessionId, exactly the outcome this restamp exists to
                    // prevent.
                    object["sessionId"] = .string(safeNewID)
                    if let restamped = try? JSONValue.object(object).serializedData(pretty: false) {
                        emitted = restamped
                    }
                }
                kept.append(emitted)
                if reachedForkPoint {
                    found = true
                    break
                }
            }
            guard found else { throw SessionLineageError.forkPointNotFound }
            var out = Data()
            for line in kept {
                out.append(line)
                out.append(0x0A)
            }
            return (out, kept.count, preview)
        }

        let targetPath = messagesRoot.appendingPathComponent("\(safeNewID).jsonl")
        guard !FileManager.default.fileExists(atPath: targetPath.path) else {
            throw SessionLineageError.targetCollision
        }
        try FileManager.default.createDirectory(at: messagesRoot, withIntermediateDirectories: true)
        if !transcript.data.isEmpty {
            try transcript.data.write(to: targetPath, options: [.atomic])
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let rootSessionID = sourceSession.rootSessionId ?? sourceSession.parentSessionId ?? sourceSession.id
        var row: [String: JSONValue] = [
            "id": .string(safeNewID),
            "title": .string(normalizedForkTitle(title, sourceTitle: sourceSession.displayTitle)),
            // 2026-09-06: a fork is the same conversation continued, so it
            // inherits what the parent IS. Hardcoding "app" made a forked
            // Telegram or iPhone thread read as a Mac chat, and made the
            // mixed-source diagnostic disagree with the transcript it copied.
            "source": .string(sourceSession.source ?? "app"),
            "createdAt": .string(now),
            "updatedAt": .string(now),
            "archived": .bool(false),
            "messageCount": .int(Int64(transcript.count)),
            // 2026-09-06: a fork writes a transcript for a session that has
            // never had one, so its transcript version starts at 1. Every
            // later write to it bumps from here; the counter is what lets a
            // remote reader order this session's published transcripts.
            ChatSessionIndexFile.transcriptGenerationKey: .int(1),
            "parentSessionId": .string(sourceSession.id),
            "rootSessionId": .string(rootSessionID),
        ]
        if let throughMessageId { row["forkedAtMessageId"] = .string(throughMessageId) }
        if let sourceKey = sourceSession.sourceKey { row["sourceKey"] = .string(sourceKey) }
        if let preview = transcript.preview { row["lastMessagePreview"] = .string(preview) }
        if let project = sourceSession.projectSpaceId { row["projectSpaceId"] = .string(project) }
        if let worktree = sourceSession.worktreePath { row["worktreePath"] = .string(worktree) }
        if let provider = sourceSession.providerId { row["providerId"] = .string(provider) }
        if let model = sourceSession.modelId { row["modelId"] = .string(model) }
        let insertedRow = row

        do {
            try await persistence.withFileLock(sessionsPath) {
                var sessions = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
                guard sessions.contains(where: {
                    if case .string(let id)? = $0["id"] { return id == safeSourceID }
                    return false
                }) else { throw SessionLineageError.sourceNotFound }
                guard !sessions.contains(where: {
                    if case .string(let id)? = $0["id"] { return id == safeNewID }
                    return false
                }) else { throw SessionLineageError.targetCollision }
                sessions.insert(insertedRow, at: 0)
                let out = try ChatSessionIndexFile.serializedData(for: sessions)
                try out.write(to: sessionsPath, options: .atomic)
            }
        } catch {
            if FileManager.default.fileExists(atPath: targetPath.path) {
                try? FileManager.default.removeItem(at: targetPath)
            }
            throw error
        }

        let data = try JSONValue.object(row).serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(ChatSession.self, from: data)
    }

    private static func normalizedForkTitle(_ requested: String?, sourceTitle: String) -> String {
        let clean = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !clean.isEmpty { return String(clean.prefix(160)) }
        return String("\(sourceTitle) — branch".prefix(160))
    }
}

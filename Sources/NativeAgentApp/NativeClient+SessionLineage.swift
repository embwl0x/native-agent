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
        try await Self.forkChatSession(
            sourceSessionId: sourceSessionId,
            throughMessageId: throughMessageId,
            title: title,
            dataRoot: PersistenceCore.defaultDataRoot()
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
                kept.append(line)
                if let value = try? JSONValue.parse(line), case .object(let object) = value {
                    if case .string(let content)? = object["content"], !content.isEmpty {
                        preview = String(content.replacingOccurrences(of: "\n", with: " ").prefix(160))
                    }
                    if let throughMessageId,
                       case .string(let id)? = object["id"],
                       id == throughMessageId {
                        found = true
                        break
                    }
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

        let newID = UUID().uuidString
        guard let safeNewID = NativeAgentChatSessionID.normalizedPathComponent(newID) else {
            throw SessionLineageError.targetCollision
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
            "source": .string("app"),
            "createdAt": .string(now),
            "updatedAt": .string(now),
            "archived": .bool(false),
            "messageCount": .int(Int64(transcript.count)),
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

    func associateChatSession(
        id: String,
        projectSpaceId: String?,
        worktreePath: String?
    ) async throws -> ChatSession {
        try await Self.updateSessionExperienceMetadata(
            id: id,
            patch: [
                "projectSpaceId": projectSpaceId.map(JSONValue.string) ?? .null,
                "worktreePath": worktreePath.map(JSONValue.string) ?? .null,
            ],
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    func stampChatSessionRoute(id: String, providerId: String, modelId: String) async throws -> ChatSession {
        try await Self.updateSessionExperienceMetadata(
            id: id,
            patch: ["providerId": .string(providerId), "modelId": .string(modelId)],
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    private static func updateSessionExperienceMetadata(
        id: String,
        patch: [String: JSONValue],
        dataRoot: URL
    ) async throws -> ChatSession {
        guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(id) else {
            throw SessionLineageError.invalidSessionID
        }
        let allowed = Set(["projectSpaceId", "worktreePath", "providerId", "modelId"])
        let sanitized = patch.filter { allowed.contains($0.key) }
        let path = dataRoot.appendingPathComponent("chat/sessions.json")
        let persistence = SwiftNativePersistenceCore()
        let now = ISO8601DateFormatter().string(from: Date())
        let updated: [String: JSONValue] = try await persistence.withFileLock(path) {
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: path)
            guard let index = rows.firstIndex(where: {
                if case .string(let rowID)? = $0["id"] { return rowID == safeID }
                return false
            }) else { throw SessionLineageError.sessionNotFound }
            var row = rows[index]
            for (key, value) in sanitized {
                if value == .null { row.removeValue(forKey: key) }
                else { row[key] = value }
            }
            row["updatedAt"] = .string(now)
            rows[index] = row
            let out = try ChatSessionIndexFile.serializedData(for: rows)
            try out.write(to: path, options: .atomic)
            return row
        }
        let data = try JSONValue.object(updated).serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(ChatSession.self, from: data)
    }

    func compareChatSessions(left: String, right: String) async throws -> ExperienceSessionComparison {
        let leftMessages = try await getChatMessages(sessionId: left)
        let rightMessages = try await getChatMessages(sessionId: right)
        var common = 0
        for pair in zip(leftMessages, rightMessages) {
            let sameID = pair.0.id == pair.1.id
            let sameContent = pair.0.role == pair.1.role
                && pair.0.content == pair.1.content
                && pair.0.createdAt == pair.1.createdAt
            guard sameID || sameContent else { break }
            common += 1
        }
        return ExperienceSessionComparison(
            leftSessionId: left,
            rightSessionId: right,
            commonMessageCount: common,
            leftOnly: Array(leftMessages.dropFirst(common)),
            rightOnly: Array(rightMessages.dropFirst(common))
        )
    }

    private static func normalizedForkTitle(_ requested: String?, sourceTitle: String) -> String {
        let clean = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !clean.isEmpty { return String(clean.prefix(160)) }
        return String("\(sourceTitle) — branch".prefix(160))
    }
}

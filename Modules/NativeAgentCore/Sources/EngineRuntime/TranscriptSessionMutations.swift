import AppToolRuntime
import Transcripts
import ApprovalTransactions
import Foundation
import Observation
import ChatTurnRuntime
import AgentWorkspace
import ChatSessionWork
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Cognition
import StandingBots
import MemoryV2
import AuthoredCapabilities
import AttentionRouting
import TurnTrace
import Privacy
import MacControl
import Darwin
import ChatTurnContracts
import ChatToolParsing
// Blueprint: | `TranscriptSessionMutations.swift` | TranscriptsFacade session creation, rename/archive and canonical transcript clear with unchanged lock ordering |
extension TranscriptsFacade {
    /// A new session row at the top of the index.
    public nonisolated func create(title: String, sourceKey: String? = nil) async throws -> NativeAgentShared.ChatSession {
        let dataRoot = self.dataRoot
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        var sessionRow: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "source": .string("app"),
            "threadKind": .string(ChatThreadKind.direct.rawValue),
            "createdAt": .string(now),
            "updatedAt": .string(now),
            "archived": .bool(false),
            "messageCount": .int(0),
        ]
        if let sourceKey, !sourceKey.isEmpty { sessionRow["sourceKey"] = .string(sourceKey) }
        let rowToInsert = sessionRow
        let sessionsPath = self.sessionsPath
        try await SwiftNativePersistenceCore.withFileLock(sessionsPath) {
            var sessions = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            sessions.insert(rowToInsert, at: 0)
            try ChatSessionIndexFile.write(sessions, to: sessionsPath)
            ChatSessionRetention.enforceBestEffort(
                dataRoot: dataRoot,
                rows: sessions,
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
        let updated: [String: JSONValue]? = try await ChatSessionIndexFile.mutate(at: sessionsPath) { sessions in
            guard let idx = sessions.firstIndex(where: { $0["id"] == .string(id) }) else { return nil }
            var row = sessions[idx]
            if let title { row["title"] = .string(title) }
            if let archived { row["archived"] = .bool(archived) }
            // A rename is not a conversation event: the row's time is
            // when someone last spoke, so only an archive flip bumps it.
            if archived != nil { row["updatedAt"] = .string(nowIso) }
            sessions[idx] = row
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
    /// `sessions.json` or append duplicate retry records to the archive tail.
    public nonisolated func archive(id: String) async throws -> NativeAgentShared.ChatSession? {
        try await ChatSessionRetention.archiveSession(id: id, dataRoot: dataRoot)
            .map(NativeAgentShared.ChatSession.init(row:))
    }
    /// Clear the canonical flat transcript under its lock, remove any stale nested copy and publish the empty index row.
    public nonisolated func clear(sessionId: String) async throws {
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
        let sessionsPath = self.sessionsPath
        let usagePath = chatRoot
            .appendingPathComponent("session_state", isDirectory: true)
            .appendingPathComponent(safeSessionId, isDirectory: true)
            .appendingPathComponent("provider_usage.json")
        // Refuse known index corruption before deleting any transcript bytes.
        // Keep locks separate: other writers have their own transcript/index
        // ordering, so clear must not add a nested cross-file lock dependency.
        _ = try await SwiftNativePersistenceCore.withFileLock(sessionsPath) {
            let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            // Refuse an exhausted generation before deleting bytes: remote readers must prove the clear is newer.
            if let row = rows.first(where: { $0["id"] == .string(safeSessionId) }),
               ChatSessionIndexFile.isTranscriptGenerationExhausted(in: row) {
                nativeLog("TranscriptsFacade.clear: refusing to clear \(safeSessionId) — its transcript version is at Int64.max and cannot advance")
                throw ChatMessageClearError.transcriptVersionExhausted
            }
            return rows
        }
        let usageBeforeClear: Data? = try await SwiftNativePersistenceCore.withFileLock(messagesPath) {
            let usage: Data?
            do {
                usage = try Data(contentsOf: usagePath)
            } catch CocoaError.fileReadNoSuchFile {
                usage = nil
            }
            try ContactThread.replace(Data(), to: messagesPath)
            if FileManager.default.fileExists(atPath: staleNestedPath.path) {
                try? FileManager.default.removeItem(at: staleNestedPath)
            }
            return usage
        }
        await publishClearedTranscript(safeSessionId)
        do {
            if let usageBeforeClear {
                let invalidated = try await SwiftNativePersistenceCore.withFileLock(usagePath) {
                    let current: Data
                    do {
                        current = try Data(contentsOf: usagePath)
                    } catch CocoaError.fileReadNoSuchFile {
                        return false
                    }
                    // A concurrent provider call owns its replacement receipt.
                    guard current == usageBeforeClear else { return false }
                    try FileManager.default.removeItem(at: usagePath)
                    return true
                }
                if invalidated {
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .nativeAgentSessionProviderUsageDidChange,
                            object: safeSessionId
                        )
                    }
                }
            }
            try await ChatSessionIndexFile.mutate(at: sessionsPath) { rows in
                // A real append after clear owns the new index projection. Its
                // normal writer will synchronize it; never zero its preview.
                guard try messagesPath.resourceValues(forKeys: [.fileSizeKey]).fileSize == 0,
                      let index = rows.firstIndex(where: { $0["id"] == .string(safeSessionId) })
                else { return }
                rows[index]["messageCount"] = .int(0)
                rows[index]["firstMessageAt"] = .null
                rows[index]["lastMessageAt"] = .null
                rows[index]["lastMessagePreview"] = .null
                rows[index]["updatedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
                // A newer generation authorizes remote transcript clearing; a wall-clock timestamp cannot.
                ChatSessionIndexFile.bumpTranscriptGeneration(in: &rows[index])
            }
        } catch {
            throw ChatMessageClearError.transcriptClearedMetadataNotSaved(error.localizedDescription)
        }
    }
}

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
// Blueprint: | `TranscriptReading.swift` | TranscriptsFacade canonical file/index reads, retention and one-revision card/attachment preparation |
extension TranscriptsFacade {
    nonisolated internal var chatRoot: URL {
        dataRoot.appendingPathComponent("chat", isDirectory: true)
    }
    nonisolated internal var sessionsPath: URL {
        chatRoot.appendingPathComponent("sessions.json")
    }

    /// Selection checks identity without preparing sidebar speech from message files.
    public nonisolated func readSessionIdentity(_ id: String) async throws -> NativeAgentShared.ChatSession? {
        let path = sessionsPath
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: path)
            guard let row = rows.first(where: { $0["id"] == .string(id) }) else { return nil }
            return try NativeAgentShared.ChatSession(row: row)
        }
    }

    /// Read the session index after retention under the same lock; checked absence is empty.
    private nonisolated func sessionRows() async throws -> [[String: JSONValue]] {
        let dataRoot = self.dataRoot
        let url = sessionsPath
        return try await SwiftNativePersistenceCore.withFileLock(url) {
            return try ChatSessionRetention.enforce(
                dataRoot: dataRoot,
                rows: ChatSessionIndexFile.loadObjectRowsForMutation(at: url),
                now: Date()
            ).rows
        }
    }
    /// A present row without a counter differs from an absent session.
    public nonisolated func transcriptGenerations() async throws -> [String: Int?] {
        var generations: [String: Int?] = [:]
        for row in try await sessionRows() {
            guard case .string(let id)? = row["id"] else { continue }
            generations.updateValue(ChatSessionIndexFile.transcriptGeneration(in: row).map { Int(clamping: $0) }, forKey: id)
        }
        return generations
    }
    public nonisolated func list() async throws -> [NativeAgentShared.ChatSession] {
        let sessions = try await sessionRows().map(NativeAgentShared.ChatSession.init(row:))
        await refreshNavigationIdentity()
        let projections = try await openingLines.prepareProjections(sessions)
        try Task.checkCancellation()
        let sources = sessions.map { session in
            // The index title remains known when opening speech could not be read.
            if projections[session.id]?.issue != nil { return (id: session.id, source: (text: session.title, automated: false)) }
            return (id:session.id,source:ChatShellConversationRow.titleSource(for:session,openingLine:projections[session.id]?.line))
        }
        let automated = sources.filter { $0.source.automated }
        let face = await presentation.prepareSnapshot("conversations",input:.object(["kind":.string("conversations"),
            "rows":.array(automated.map { .object(["key":.string($0.id),"opening":.string($0.source.text)]) })]))
        try Task.checkCancellation()
        let projected = Dictionary((face.face?.sections.flatMap(\.rows) ?? []).map { ($0.id,$0.title) },uniquingKeysWith:{ first,_ in first })
        let titles = Dictionary(sources.map { row -> (String,String) in
            if !row.source.automated { return (row.id,row.source.text) }
            if face.status != .ready { return (row.id,"Conversation "+face.status.rawValue) }
            if let title=projected[row.id] {
                return (row.id,row.source.text.hasPrefix("Current standing instructions for ") ? ChatShellConversationRow.clamp(title) : title)
            }
            return (row.id,"Conversation unavailable: unbound title")
        },uniquingKeysWith:{ first,_ in first })
        return sessions.map { session in
            var resolved = session
            if let title = titles[session.id] { resolved.displayTitle = title }
            resolved.isWorkingConversation = ChatShellConversationRow.isWorking(session)
            return resolved
        }
    }
    /// Use the newest archived row per id, excluding sessions restored to the hot index; checked absence is empty.
    public nonisolated func listArchived() async throws -> [NativeAgentShared.ChatSession] {
        let url = sessionsPath
        return try await SwiftNativePersistenceCore.withFileLock(url) {
            let hot = Set(try ChatSessionIndexFile.loadObjectRowsForMutation(at: url).compactMap { row -> String? in
                guard case .string(let id)? = row["id"], row["archived"] != .bool(true) else { return nil }
                return id
            })
            var newest: [String: NativeAgentShared.ChatSession] = [:]
            for row in try ChatSessionRetention.archiveIndexRows(dataRoot: self.dataRoot) {
                let session = try NativeAgentShared.ChatSession(row: row)
                if !hot.contains(session.id) { newest[session.id] = session }
            }
            return Array(newest.values)
        }
    }
    public nonisolated func loadMessages(sessionId: String, cached: Bool = false) async throws -> [ChatMessage] {
        try await loadTranscript(sessionId: sessionId, cached: cached).messages
    }
    /// Messages and cards share one decoded revision.
    public nonisolated func loadTranscript(sessionId: String, cached: Bool = false) async throws -> TranscriptReadout {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return .empty
        }
        return try await readPublishedTranscript(safeSessionId: safeSessionId, cached: cached).projection
    }
    @concurrent nonisolated internal func readTranscriptProjection(safeSessionId: String, cached: Bool,
        limit: Int? = nil) async throws -> TranscriptReadout {
        _ = await readFirstConversationReceiptTitle()
        var projection = try await readTranscript(safeSessionId: safeSessionId, cached: cached, limit: limit)
        let cards = try await InlineCards.cardsByRow(
            projection.interactions, messages: projection.messages, sessionID: safeSessionId, dataRoot: dataRoot)
        for index in projection.messages.indices {
            projection.messages[index].inlineCards = cards.cardsByRow[projection.messages[index].id] ?? []
        }
        projection.cardsHeading = cards.heading
        return await projection.attachmentPreviews()
    }
    @concurrent nonisolated func readTranscript(safeSessionId: String, cached: Bool = true, limit: Int? = nil) async throws -> TranscriptReadout {
        // Use SessionHistoryReader’s resolved fields and retained raw metadata.
        let read = try await cache.history(at: dataRoot.appendingPathComponent("chat/messages/\(safeSessionId).jsonl"), cached: cached, limit: limit)
        let history = read.history
        if history.stats.mode == "missing" {
            let index = sessionsPath
            let declaredEmpty = try await SwiftNativePersistenceCore.withFileLock(index) {
                try ChatSessionIndexFile.loadObjectRowsForMutation(at: index).contains {
                    $0["id"] == .string(safeSessionId) && $0["messageCount"] == .int(0)
                }
            }
            guard declaredEmpty else {
                throw NSError(domain: "NativeAgent.ChatHistory", code: 404, userInfo: [
                    NSLocalizedDescriptionKey: "The conversation's message file is missing and its index does not declare an empty chat. Restore the file."
                ])
            }
        }
        // UI selection must propagate read failures rather than replace the conversation with prompt history’s tolerated empty subset.
        guard history.stats.mode != "read_failed" else {
            throw NSError(
                domain: "NativeClient.ChatHistory", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The saved conversation could not be read. Its data was left unchanged."]
            )
        }
        let rejectedRows = history.stats.malformedRowCount + history.stats.invalidShapeRowCount
        guard rejectedRows == 0 else {
            throw NSError(
                domain: "NativeClient.ChatHistory", code: 2,
                userInfo: [NSLocalizedDescriptionKey: """
                    The saved conversation is unavailable (\(rejectedRows) damaged rows). Its data was left unchanged; repair the rejected rows before \
                    displaying a complete history.
                    """]
            )
        }
        // New empty sessions are valid; damaged subsets cannot replace a complete published transcript.
        let coMessages = try history.checkedMessages()
        let messages = try coMessages.map { co -> ChatMessage in
            guard case .object(let row)? = co.extras else {
                throw NSError(domain: "NativeAgent.ChatHistory", code: 422, userInfo: [
                    NSLocalizedDescriptionKey: "A saved message has no source row. Repair the transcript before displaying unverifiable history."
                ])
            }
            var message = try ChatMessage(row: row)
            // Project forked rows onto the requested session so actions cannot jump to their source; preserve on-disk ids and provenance.
            message.sessionId = safeSessionId
            // Keep the history reader’s resolved text and timestamps rather than replacing them with raw-field defaults.
            message.content = co.content
            if !co.timestamp.isEmpty { message.createdAt = co.timestamp }
            return message
        }
        var projection = TranscriptReadout(messages: messages)
        projection.isComplete = !history.stats.truncated
        ModuleLog.app("[transcript-read] session=%@ scope=%@ cache=%@ bytes=%lld source=%lld rows=%ld", safeSessionId,
            projection.isComplete ? "complete" : "tail", read.cacheHit ? "hit" : "miss",
            read.cacheHit ? Int64(0) : history.stats.bytesRead, history.stats.sourceBytes, messages.count)
        projection.interactions = InlineInteractionResolver.interactionsByRow(in: coMessages.compactMap(\.extras),
            lifeID: try DataRootLife.current(in: dataRoot))
        return projection
    }
}

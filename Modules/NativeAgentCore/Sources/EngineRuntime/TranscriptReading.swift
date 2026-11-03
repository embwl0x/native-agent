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

    /// The session index, after retention has run under the same lock.
    /// Missing file → `[]`.
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
            (id:session.id,source:ChatShellConversationRow.titleSource(for:session,openingLine:projections[session.id]?.line))
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
    /// The archive tier (`chat/archive/sessions.jsonl`), where Archive and
    /// retention move a conversation out of the index: the newest row per id,
    /// less any a door has since brought back into the index. Missing file → `[]`.
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
    /// Messages and recollections share one decoded transcript revision.
    public nonisolated func loadTranscript(sessionId: String, cached: Bool = false) async throws -> TranscriptReadout {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return .empty
        }
        return try await readPublishedTranscript(safeSessionId: safeSessionId, cached: cached).projection
    }
    nonisolated internal func readTranscriptProjection(safeSessionId: String, cached: Bool) async throws -> TranscriptReadout {
        var projection = try await readTranscript(safeSessionId: safeSessionId, cached: cached)
        let cards = try await InlineCards.cardsByRow(
            projection.interactions, messages: projection.messages, sessionID: safeSessionId, dataRoot: dataRoot)
        for index in projection.messages.indices {
            projection.messages[index].inlineCards = cards.cardsByRow[projection.messages[index].id] ?? []
        }
        projection.cardsHeading = cards.heading
        return await projection.attachmentPreviews()
    }
    nonisolated func readTranscript(safeSessionId: String, cached: Bool = true) async throws -> TranscriptReadout {
        // SessionHistoryReader resolves text/timestamp aliases and preserves raw row metadata in extras.
        let history = try await cache.history(at: dataRoot.appendingPathComponent("chat/messages/\(safeSessionId).jsonl"), cached: cached)
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
        guard rejectedRows == 0 else {
            throw NSError(
                domain: "NativeClient.ChatHistory", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The saved conversation is unavailable (\(rejectedRows) damaged rows). Its data was left unchanged; repair the rejected rows before displaying a complete history."]
            )
        }
        // Missing/empty new sessions remain valid. A surviving subset is not
        // a complete transcript; the facade retains its previous publication.
        let coMessages = history.messages
        // Parse recollections from the same decoded rows as the displayed messages.
        let recollections = coMessages.compactMap { co -> ChatSessionRecollection? in
            guard let extras = co.extras else { return nil }
            return ChatSessionRecollections.recollection(
                fromTranscriptRow: extras,
                sessionId: safeSessionId
            )
        }
        let messages = try coMessages.map { co -> ChatMessage in
            guard case .object(let row)? = co.extras else {
                throw NSError(domain: "NativeAgent.ChatHistory", code: 422, userInfo: [
                    NSLocalizedDescriptionKey: "A saved message has no source row. Repair the transcript before displaying unverifiable history."
                ])
            }
            var message = try ChatMessage(row: row)
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
        var projection = TranscriptReadout(messages: messages, recollections: recollections)
        projection.interactions = InlineInteractionResolver.interactionsByRow(in: coMessages.compactMap(\.extras),
            lifeID: try DataRootLife.current(in: dataRoot))
        return projection
    }
}

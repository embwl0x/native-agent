import Foundation
import NativeAgentShared
import CryptoKit
import AppIntents
import SwiftUI
import Observation
// Blueprint: | `iCloudSyncEngine+Transcripts.swift` | PublishedTranscript projection, generation-ordered reconciliation and history adoption; retained local rows, compatible fuller text and non-image attachment bytes share one owner |

extension iCloudSyncEngine {
    /// Rows and their Mac transcript version publish together, including version-only empty updates.
    struct PublishedTranscript: Equatable, Sendable {
        var records: [ChatMessageRecord]
        var publishedIDs: Set<UUID> { Set(records.compactMap { UUID(uuidString: $0.id) }) }
        var messages: [ChatMessage]
        var otherRooms: [OtherRoomExchange] = []
        /// The Mac increments this on every clear/write; nil means an empty transcript cannot clear local rows.
        var generation: Int?
        var hasOlder = false
        /// Mac history beyond the published window.
        var historyIDs: Set<UUID> = []
        var readError: String? = nil
    }

    /// Transcript versions and row/run identity own reconciliation for every reader.
    /// Unfinished handoffs remain separate durable requests; settled rows are not cached.
    func adoptChatTranscripts(_ incoming: [String: PublishedTranscript], completeSnapshot: Bool = true) {
        for (session, var published) in incoming {
            guard !published.messages.isEmpty || published.generation != nil else { continue }
            if let current = chatTranscripts[session] {
                if let applied = current.generation {
                    guard let generation = published.generation, generation >= applied else { continue }
                    if published.messages.isEmpty && generation == applied { continue }
                }
                let canonicalIDs = Set(published.messages.map(\.id))
                let canonicalUsers = Set(published.messages.filter { $0.role == .user }.compactMap(\.runId))
                let terminalRuns = Set(published.messages.filter {
                    $0.isTerminalReply
                }.compactMap(\.runId))
                let unfinished = ChatStore.shared.pendingExchanges.values.filter {
                    $0.sessionID == session && !$0.isExpired
                }
                let unfinishedIDs = Set(unfinished.flatMap {
                    [$0.placeholderID, $0.request?.appendedUserId].compactMap { $0 }
                }).union(ChatStore.shared.queuedSends.filter { $0.sessionID == session }.flatMap {
                    [$0.id, $0.placeholderID, $0.userMessageID].compactMap { $0 }
                })
                let kept = current.messages.filter { row in
                    guard !canonicalIDs.contains(row.id) else { return false }
                    if published.messages.isEmpty {
                        return unfinishedIDs.contains(row.id) || row.isStreaming || row.awaitingMacTranscript
                    }
                    if let run = row.runId {
                        if row.role == .user, canonicalUsers.contains(run) { return false }
                        if terminalRuns.contains(run) { return false }
                    }
                    return unfinishedIDs.contains(row.id) || row.isStreaming || row.awaitingMacTranscript
                }
                let overlaps = !Set(current.records.compactMap { UUID(uuidString: $0.id) }).isDisjoint(with: canonicalIDs)
                let history = published.messages.isEmpty || !overlaps ? [] : current.messages.filter {
                    current.historyIDs.contains($0.id) && !canonicalIDs.contains($0.id)
                }
                // Matched full text survives compatible truncation regardless of history membership.
                // Phone-local non-image bytes carry over; Mac previews own images.
                let truncationSuffix = "\n" + ChatStore.snapshotTruncationMarker
                var firstIdentity: [[String]: Int] = [:]
                for (index, row) in current.messages.enumerated().reversed() {
                    firstIdentity[[row.id.uuidString]] = index
                    if let run = row.runId { firstIdentity[[run, row.role.rawValue]] = index }
                }
                for index in published.messages.indices {
                    let row = published.messages[index]
                    let match = [firstIdentity[[row.id.uuidString]],
                        row.runId.flatMap { firstIdentity[[$0, row.role.rawValue]] }].compactMap { $0 }.min()
                    let local = match.map { current.messages[$0] }
                    let attachments = Dictionary((local?.attachments ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    if let local, row.text.hasSuffix(truncationSuffix) {
                        let prefix = String(row.text.dropLast(truncationSuffix.count))
                        if local.text.count > prefix.count, local.text.hasPrefix(prefix) {
                            published.messages[index].text = local.text
                        }
                    }
                    for attachment in published.messages[index].attachments.indices
                    where published.messages[index].attachments[attachment].type != "image"
                        && published.messages[index].attachments[attachment].base64 == nil {
                        let id = published.messages[index].attachments[attachment].id
                        published.messages[index].attachments[attachment].base64 =
                            attachments[id]?.base64
                    }
                }
                published.historyIDs = current.historyIDs.intersection(Set((history + published.messages).map(\.id)))
                published.messages = history + published.messages + kept
            }
            if chatTranscripts[session] != published { chatTranscripts[session] = published }
        }
        if completeSnapshot {
            let active = Set([ChatStore.shared.transcriptSessionKey]
                + ChatStore.shared.pendingExchanges.values.map { $0.sessionID ?? ChatStore.nilQueueSessionKey }
                + ChatStore.shared.queuedSends.map { $0.sessionID ?? ChatStore.nilQueueSessionKey })
            chatTranscripts = chatTranscripts.filter { incoming[$0.key] != nil || active.contains($0.key) }
        }
    }

    func transcriptRead(for sessionID: String?) -> MacTranscriptRead {
        guard let sessionID, let published = chatTranscripts[sessionID] else { return .unavailable }
        if published.readError != nil { return .unavailable }
        return .published(
            published.messages,
            generation: published.generation
        )
    }

    /// Publish rows with their transcript version; an unversioned empty transcript cannot clear local rows.
    nonisolated static func transcriptMap(
        _ rows: [ChatTranscriptSnapshot]
    ) async -> [String: PublishedTranscript] {
        await Task.detached(priority: .userInitiated) {
            var out: [String: PublishedTranscript] = [:]
            for row in rows {
                let clean = row.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                out[clean] = PublishedTranscript(
                    records: row.messages,
                    messages: ChatMessage.projectChatRecords(row.messages),
                    otherRooms: row.otherRooms ?? [],
                    generation: row.transcriptGeneration,
                    hasOlder: row.hasOlder ?? false,
                    readError: row.readError
                )
            }
            return out
        }.value
    }

    /// Saved rows the transcript snapshot leaves out: older history before
    /// `beforeID`, or one whole message through `throughID`.
    func chatHistoryPage(sessionID: String, beforeID: String? = nil, throughID: String? = nil,
                         limit: Int = 80) async throws -> (messages: [ChatMessage], hasOlder: Bool) {
        let lifecycle = lifecycleGeneration
        var payload = ["sessionId": sessionID, "limit": String(limit)]
        payload["beforeId"] = beforeID
        payload["throughId"] = throughID
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(
            .make(action: "chat_history_page", payload: payload)))
        guard let raw = result["messages"] else { throw SyncError.persistence("The Mac did not return the messages.") }
        let (records, messages) = try await Task.detached(priority: .userInitiated) {
            let records = try JSONDecoder().decode([ChatMessageRecord].self, from: Data(raw.utf8))
            return (records, ChatMessage.projectChatRecords(records))
        }.value
        guard lifecycle == lifecycleGeneration else { throw CancellationError() }
        let generation = result["transcriptGeneration"].flatMap(Int.init)
        if let current = chatTranscripts[sessionID]?.generation, let generation, generation < current {
            throw CancellationError()
        }
        if beforeID != nil || throughID != nil, var current = chatTranscripts[sessionID] {
            let firstIndex = Dictionary(current.messages.enumerated().map { ($0.element.id, $0.offset) },
                                        uniquingKeysWith: { first, _ in first })
            let insertion = beforeID.flatMap(UUID.init(uuidString:)).flatMap { firstIndex[$0] } ?? current.messages.endIndex
            if beforeID != nil {
                current.messages.insert(contentsOf: messages.filter { firstIndex[$0.id] == nil }, at: insertion)
            } else {
                for row in messages {
                    guard let index = firstIndex[row.id] else { continue }
                    current.messages[index] = row
                }
            }
            current.historyIDs.formUnion(messages.map(\.id))
            current.generation = generation
            chatTranscripts[sessionID] = current
        } else {
            adoptChatTranscripts([sessionID: .init(records: records, messages: messages,
                generation: generation, hasOlder: result["hasOlder"] == "true")], completeSnapshot: false)
        }
        return (messages, result["hasOlder"] == "true")
    }

}

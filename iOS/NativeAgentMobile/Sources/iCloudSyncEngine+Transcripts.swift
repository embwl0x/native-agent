import Foundation
import NativeAgentShared
import CryptoKit
import AppIntents
import SwiftUI
import Observation
// Blueprint: | `iCloudSyncEngine+Transcripts.swift` | Version-ordered transcript/history reconciliation; retained fuller text and attachment bytes |

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
        var historyIDs: Set<UUID> = []
        var readError: String? = nil
    }

    /// Versions and row/run IDs own reconciliation; unfinished handoffs remain durable requests rather than settled-row caches.
    func adoptChatTranscripts(_ incoming: [String: PublishedTranscript], completeSnapshot: Bool = true) {
        for (session, var published) in incoming {
            if let failure = published.readError {
                if var current = chatTranscripts[session] {
                    current.readError = failure
                    chatTranscripts[session] = current
                } else { chatTranscripts[session] = published }
                continue
            }
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
                    [$0.placeholderID, $0.request.appendedUserId].compactMap { $0 }
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
                // Keep compatible full text despite snapshot truncation; retain phone-local non-image bytes while Mac previews own images.
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
                let canonicalRecordIDs = Set(published.records.map { $0.id.lowercased() })
                let historyRecords = published.messages.isEmpty || !overlaps ? [] : current.records.filter {
                    UUID(uuidString: $0.id).map { current.historyIDs.contains($0) } == true
                        && !canonicalRecordIDs.contains($0.id.lowercased())
                }
                published.records = historyRecords + published.records
                published.historyIDs = current.historyIDs.intersection(published.publishedIDs)
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
                do {
                    let records = try row.messages.map(ChatMessageRecord.canonical)
                    out[clean] = PublishedTranscript(
                        records: records,
                        messages: try ChatMessage.projectChatRecords(records),
                        otherRooms: row.otherRooms ?? [],
                        generation: row.transcriptGeneration,
                        hasOlder: row.hasOlder ?? false,
                        readError: row.readError)
                } catch {
                    out[clean] = PublishedTranscript(records: [], messages: [],
                        generation: row.transcriptGeneration,
                        readError: "The Mac transcript projection could not be read: \(error.localizedDescription)")
                }
            }
            return out
        }.value
    }

    func chatHistoryPage(sessionID: String, beforeID: String? = nil, throughID: String? = nil,
                         limit: Int = 80) async throws -> (messages: [ChatMessage], hasOlder: Bool) {
        let lifecycle = lifecycleGeneration
        var payload = ["sessionId": sessionID, "limit": String(limit)]
        payload["beforeId"] = beforeID
        payload["throughId"] = throughID
        let result = try requireSuccessfulActionResponse(await sendActionAndWait(
            .make(action: "chat_history_page", payload: payload)))
        guard let raw = result["messages"] else { throw SyncError.persistence("The Mac did not return the messages.") }
        let (records, messages) = try await Task.detached(priority: .userInitiated) {
            let records = try JSONDecoder().decode([ChatMessageRecord].self, from: Data(raw.utf8)).map(ChatMessageRecord.canonical)
            return (records, try ChatMessage.projectChatRecords(records))
        }.value
        guard lifecycle == lifecycleGeneration else { throw CancellationError() }
        let generation = result["transcriptGeneration"].flatMap(Int.init)
        if let current = chatTranscripts[sessionID]?.generation, let generation, generation < current {
            throw CancellationError()
        }
        if beforeID != nil || throughID != nil, var current = chatTranscripts[sessionID] {
            // History contains rows the message projection deliberately leaves out (tools and their Mac faces).
            // Insert by the Mac's page order; identity replacement also refreshes a requested full row.
            let incomingRecordIDs = Set(records.map { $0.id.lowercased() })
            let recordInsertion = beforeID.flatMap { anchor in
                current.records.firstIndex { $0.id.lowercased() == anchor.lowercased() }
            } ?? current.records.firstIndex { incomingRecordIDs.contains($0.id.lowercased()) } ?? current.records.endIndex
            let preceding = current.records[..<recordInsertion].filter { !incomingRecordIDs.contains($0.id.lowercased()) }
            let following = current.records[recordInsertion...].filter { !incomingRecordIDs.contains($0.id.lowercased()) }
            current.records = preceding + records + following
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
            current.historyIDs.formUnion(records.compactMap { UUID(uuidString: $0.id) })
            current.generation = generation
            chatTranscripts[sessionID] = current
        } else {
            adoptChatTranscripts([sessionID: .init(records: records, messages: messages,
                generation: generation, hasOlder: result["hasOlder"] == "true")], completeSnapshot: false)
        }
        return (messages, result["hasOlder"] == "true")
    }

}

extension ChatMessageRecord {
    /// Sorted embedded JSON preserves equality across equivalent snapshot encodings.
    nonisolated static func canonical(_ record: ChatMessageRecord) throws -> ChatMessageRecord {
        var record = record
        record.interactionJSON = try canonicalJSON(record.interactionJSON)
        record.interactionDescriptorJSON = try canonicalJSON(record.interactionDescriptorJSON)
        if var metadata = record.metadata {
            metadata.inputJSON = try canonicalJSON(metadata.inputJSON)
            record.metadata = metadata
        }
        return record
    }

    private nonisolated static func canonicalJSON(_ text: String?) throws -> String? {
        guard let text else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

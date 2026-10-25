import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `MacSyncActionRouter+ChatHistory.swift` | `MacSyncActionRouter`: `chatHistoryPage`; history rows carry a session-index generation unchanged across the history read |

extension MacSyncActionRouter {
    static let historyPageByteBudget = 256 * 1024

    /// What the transcript snapshot leaves out, on demand: up to `limit` saved
    /// rows ending just before `beforeId` (older history), or through
    /// `throughId` (one message), in the snapshot's own row encoding.
    func chatHistoryPage(_ action: InboxAction) async throws -> [String: String] {
        let payload = action.payload
        guard let session = NativeAgentChatSessionID.normalizedPathComponent(payload["sessionId"]) else {
            return ["status": "error", "ok": "false", "message": "Name the chat session."]
        }
        let generation = try await sync.host.getChatSessions().first { $0.id == session }?.transcriptGeneration
        let messages = try await sync.host.getChatMessages(sessionId: session)
        guard let after = try await sync.host.getChatSessions().first(where: { $0.id == session }),
              after.transcriptGeneration == generation else {
            throw DeviceSyncError.underlying(message: "This chat changed while its history was being read. Refresh it.")
        }
        func position(_ key: String) -> Int? {
            guard let id = payload[key]?.lowercased(), !id.isEmpty else { return nil }
            return messages.firstIndex { $0.id.lowercased() == id }
        }
        let end: Int
        if payload["beforeId"] != nil {
            guard let index = position("beforeId") else {
                return ["status": "error", "ok": "false", "message": "That message is no longer in this chat on the Mac."]
            }
            end = index
        } else if payload["throughId"] != nil {
            guard let index = position("throughId") else {
                return ["status": "error", "ok": "false", "message": "That message is no longer in this chat on the Mac."]
            }
            end = index + 1
        } else {
            end = messages.count
        }
        let limit = min(max(Int(payload["limit"] ?? "") ?? 80, 1), 80)
        func response(_ rows: [DeviceSyncTranscriptRow], start: Int) throws -> [String: String] {
            let data = try MobileSnapshotBuilder.encoder().encode(rows)
            var result = ["status": "ok", "ok": "true", "messages": String(decoding: data, as: UTF8.self),
                          "hasOlder": String(messages[..<start].contains(where: \.isPersonVisible))]
            result["transcriptGeneration"] = generation.map(String.init)
            return result
        }
        func fits(_ response: [String: String]) throws -> Bool {
            let body = try sync.engine.actionResponse(response, for: action)
            let message = try sync.bridge.cloudKitActionResponseMessage(body, correlationID: action.msgId)
            do {
                return try NAChatMessageCodec.recordValueBytes(NAChatMessageCodec.encode(message)) <= Self.historyPageByteBudget
            } catch DeviceSyncError.payloadTooLarge { return false }
        }
        var start = end
        var rows: [DeviceSyncTranscriptRow] = []
        var taken = 0
        while start > 0, taken < limit {
            // A row that is hers alone is skipped, not counted: it still
            // anchors paging (an older phone may hold its id) but is not shown.
            guard messages[start - 1].isPersonVisible else { start -= 1; continue }
            var row = DeviceSyncTranscriptRow(message: messages[start - 1])
            var candidate = try response([row] + rows, start: start - 1)
            if try !fits(candidate) {
                // Preserve transcript words and rows before optional images.
                row.message.omitAttachmentPreviews()
                for index in rows.indices { rows[index].message.omitAttachmentPreviews() }
                candidate = try response([row] + rows, start: start - 1)
            }
            if try !fits(candidate) {
                guard rows.isEmpty else { break }
                var content = row.message.content
                repeat {
                    guard !content.isEmpty else {
                        throw DeviceSyncError.payloadTooLarge(actualBytes: try JSONEncoder().encode(candidate).count,
                            maximumBytes: Self.historyPageByteBudget)
                    }
                    content = String(content.prefix(content.count / 2))
                    row.message.content = content + "\n\nThe rest is on the Mac."
                    candidate = try response([row], start: start - 1)
                } while try !fits(candidate)
            }
            rows.insert(row, at: 0)
            start -= 1
            taken += 1
        }
        return try response(rows, start: start)
    }
}

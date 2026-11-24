import Foundation
import NativeAgentCore
import NativeAgentShared
import SenseCore
// Blueprint: | `MacSyncActionRouter+ChatHistory.swift` | `MacSyncActionRouter`, `chatHistoryPage`; Generation-bound history. |

extension MacSyncActionRouter {
    static let historyPageByteBudget = 256 * 1024

    /// Page within the snapshot's encoding so older rows and single-message reads retain the same wire shape.
    func chatHistoryPage(_ action: InboxAction) async throws -> [String: String] {
        let payload = action.payload
        guard let session = NativeAgentChatSessionID.normalizedPathComponent(payload["sessionId"]) else {
            return ["status": "error", "ok": "false", "message": "Name the chat session."]
        }
        let owner = try sync.owner
        let generation = try await owner.transcripts.transcriptGenerations()[session] ?? nil
        let limit = min(max(Int(payload["limit"] ?? "") ?? 80, 1), 80)
        let page = try await owner.mobileChatMessages(sessionId: session, limit: limit,
            beforeID: payload["beforeId"], throughID: payload["throughId"])
        guard let after = try await owner.transcripts.transcriptGenerations()[session], after == generation else {
            throw DeviceSyncError.underlying(message: "This chat changed while its history was being read. Refresh it.")
        }
        if let error = page.readError { return ["status": "error", "ok": "false", "message": error] }
        func response(_ rows: [ChatMessageRecord], start: Int) throws -> [String: String] {
            let data = try TurnSummaryComputer.makeEncoder().encode(rows)
            var result = ["status": "ok", "ok": "true", "messages": String(decoding: data, as: UTF8.self),
                          "hasOlder": String(start > 0 || page.hasOlder == true)]
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
        var start = page.messages.count
        var rows: [ChatMessageRecord] = []
        while start > 0 {
            var row = page.messages[start - 1]
            var candidate = try response([row] + rows, start: start - 1)
            if try !fits(candidate) {
                let oversized = candidate
                // Preserve transcript words and rows before optional images.
                row.omitAttachmentPreviews()
                for index in rows.indices { rows[index].omitAttachmentPreviews() }
                candidate = try response([row] + rows, start: start - 1)
                if try candidate == oversized || !fits(candidate) {
                    guard rows.isEmpty else { break }
                    var content = row.content
                    repeat {
                        guard !content.isEmpty else {
                            throw DeviceSyncError.payloadTooLarge(actualBytes: try JSONEncoder().encode(candidate).count,
                                maximumBytes: Self.historyPageByteBudget)
                        }
                        content = String(content.prefix(content.count / 2))
                        row.content = content + "\n\nThe rest is on the Mac."
                        candidate = try response([row], start: start - 1)
                    } while try !fits(candidate)
                }
            }
            rows.insert(row, at: 0)
            start -= 1
        }
        return try response(rows, start: start)
    }
}

import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeApprovalInbox {
    /// One receipt identity per approval, including a healed execution outcome.
    /// Presentation supplies the already-redacted envelope; the inbox owns IO.
    public func writeChatReceipt(
        approvalID: String, sessionID: String, toolName: String, surface: String,
        summary: String, resultClass: String, ok: Bool?, resultPreview: String?,
        recoveredAt: String? = nil
    ) async throws -> String? {
        guard !sessionID.isEmpty, sessionID != ".", sessionID != "..",
              !sessionID.contains("/"), !sessionID.contains("\\") else {
            throw ApprovalInboxError.malformedResponse("invalid receipt session")
        }
        let path = root.appendingPathComponent("chat/messages")
            .appendingPathComponent("\(sessionID).jsonl")
        return try await persistence.withFileLock(path) { [persistence] in
            let rows = try await persistence.readJSONL(path)
            let existingIndex = rows.firstIndex { row in
                guard case .object(let object) = row,
                      case .object(let metadata)? = object["metadata"],
                      case .string(let rowApprovalID)? = metadata["approvalId"]
                else { return false }
                return rowApprovalID == approvalID
            }
            let now = ISO8601DateFormatter().string(from: Date())
            let inputJSON = (try? JSONValue.object([
                "approvalId": .string(approvalID),
            ]).serialize(pretty: false)) ?? "{}"
            let priorObject: [String: JSONValue] = existingIndex.flatMap { index in
                guard case .object(let object) = rows[index] else { return nil }
                return object
            } ?? [:]
            var metadata: [String: JSONValue] = [
                "kind": .string("tool_use"),
                "toolName": .string(toolName),
                "inputJSON": .string(inputJSON),
                "resultSummary": .string(summary),
                "approvalId": .string(approvalID),
                "postApproval": .bool(true),
            ]
            let priorMetadata: [String: JSONValue] = {
                guard case .object(let value)? = priorObject["metadata"] else { return [:] }
                return value
            }()
            // Preserve the old claim until it has migrated to the approval.
            let legacyStarted = priorMetadata["approvalContinuationStarted"] == .bool(true)
            if legacyStarted {
                metadata["approvalContinuationStarted"] = .bool(true)
            }
            if let ok { metadata["ok"] = .bool(ok) }
            metadata["resultClass"] = .string(resultClass)
            // The envelope above is what the pill parses; its prose preamble
            // is longer than the history projection's head, so the result
            // body never survived into the model's next turn (it re-ran the
            // tool and asked for a second approval). Keep the already-
            // redacted body unwrapped too — `SessionHistoryPromptRenderer
            // .toolSummary` reads this key and projects it exactly like an
            // ordinary tool result.
            if let resultPreview, !resultPreview.isEmpty {
                metadata["resultBody"] = .string(resultPreview)
            }
            let row: JSONValue = .object([
                "id": priorObject["id"] ?? .string(UUID().uuidString.lowercased()),
                "sessionId": .string(sessionID),
                "role": .string("tool"),
                "content": .string(""),
                "createdAt": priorObject["createdAt"] ?? .string(recoveredAt ?? now),
                "source": .string(surface),
                "runId": .string("approval-\(approvalID)"),
                "metadata": .object(metadata),
            ])
            if let existingIndex {
                // A narrowly recoverable pre-dispatch failure can later
                // succeed. Keep one canonical receipt, but replace its
                // stale failure result so conversation continuity agrees
                // with the approval store's latest execution truth.
                if rows[existingIndex] != row {
                    var updated = rows
                    updated[existingIndex] = row
                    try await persistence.replaceJSONL(updated, to: path)
                }
            } else if let recoveredAt,
                      let recoveredDate = NativeTimestampFormat.parseISO8601FractionalFirst(recoveredAt),
                      let insertionIndex = rows.firstIndex(where: {
                          guard case .object(let object) = $0,
                                case .string(let stamp)? = object["createdAt"],
                                let date = NativeTimestampFormat.parseISO8601FractionalFirst(stamp)
                          else { return false }
                          return date > recoveredDate
                      }) {
                // History projection consumes file order. Heal an old receipt
                // before newer turns, under the same lock as ordinary appends.
                var updated = rows
                updated.insert(row, at: insertionIndex)
                try await persistence.replaceJSONL(updated, to: path)
            } else {
                try await persistence.appendJSONL(row, to: path)
            }
            guard legacyStarted else { return nil }
            if case .string(let date)? = priorObject["createdAt"] { return date }
            return now
        }
    }
}

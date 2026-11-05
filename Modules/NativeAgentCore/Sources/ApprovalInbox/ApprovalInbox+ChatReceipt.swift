import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Transcripts
// Blueprint: | `ApprovalInbox+ChatReceipt.swift` | Approval receipt rows and healing order; transcript bytes are written through ContactThread |

extension SwiftNativeApprovalInbox {
    /// One receipt identity per approval, including a healed execution outcome. Presentation supplies the already-redacted envelope; the inbox owns the receipt
    /// row and ContactThread owns its transcript bytes.
    public func writeChatReceipt(
        approvalID: String, sessionID: String, toolName: String, surface: String,
        summary: String, resultClass: String, resultStatus: String?, ok: Bool?, resultPreview: String?,
        returnedID: String? = nil, effects: String? = nil,
        recoveredAt: String? = nil
    ) async throws {
        guard !sessionID.isEmpty, sessionID != ".", sessionID != "..",
              !sessionID.contains("/"), !sessionID.contains("\\") else {
            throw ApprovalInboxError.malformedResponse("invalid receipt session")
        }
        let path = root.appendingPathComponent("chat/messages")
            .appendingPathComponent("\(sessionID).jsonl")
        try await SwiftNativePersistenceCore.withFileLock(path) {
            let rows = try await SwiftNativePersistenceCore.readJSONL(path)
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
            if let ok { metadata["ok"] = .bool(ok) }
            metadata["resultClass"] = .string(resultClass)
            if let resultStatus { metadata["resultStatus"] = .string(resultStatus) }
            if let returnedID { metadata["resultReturnedID"] = .string(returnedID) }
            if let effects { metadata["resultEffects"] = .string(effects) }
            // Project the redacted body unwrapped so history clipping cannot hide the result and provoke a repeat approval.
            if let resultPreview, !resultPreview.isEmpty {
                metadata["resultBody"] = .string(resultPreview)
            }
            let row: JSONValue = .object([
                "id": priorObject["id"] ?? .string(UUID().uuidString.lowercased()),
                "sessionId": .string(sessionID),
                "role": .string("tool"),
                "content": .string(""),
                "createdAt": priorObject["createdAt"] ?? .string(recoveredAt ?? now),
                "source": .string(ChatThreadKind.transcriptSource(surface: surface)),
                "runId": .string("approval-\(approvalID)"),
                "metadata": .object(metadata),
            ])
            if let existingIndex {
                // Replace a recoverable failure in the canonical receipt so history agrees with the latest execution outcome.
                if rows[existingIndex] != row {
                    var updated = rows
                    updated[existingIndex] = row
                    try ContactThread.replace(updated, to: path)
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
                // History consumes file order, so heal receipts before newer turns under the append lock.
                var updated = rows
                updated.insert(row, at: insertionIndex)
                try ContactThread.replace(updated, to: path)
            } else {
                try await ContactThread.append(row, to: path)
            }
        }
    }
}

import AgentConversations
import CognitiveSubstrate
import ChatSessionWork
import AgentWorkspace
import ToolRegistry
import Foundation
import NativeAgentShared
import Transcripts
import NativeAgentCore
import PersistenceCore
import MemoryV2
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution
// Blueprint: | `ChatHistoryMessage.swift` | Verbatim persisted messages, including boilerplate hidden by search, and bounded receipt pages |

extension SwiftToolDispatcher {
    /// Characters per page. A page is a bounded read, not a whole transcript.
    static let readChatMessageDefaultPageCharacters = 8_000
    static let readChatMessageMaximumPageCharacters = 16_000

    func impl_read_chat_message(input: [String: JSONValue], invokedAs: String) async throws -> JSONValue {
        let input = input.filter { $0.value != .string("") }
        let messageId = (input["message_id"]?.stringValue ?? input["id"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageId.isEmpty else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: read_chat_message needs the 'message_id' search_chat_history returned"
            )
        }
        let offset = max(0, Self.jsonInt(input["offset"]) ?? 0)
        let limit = max(
            1,
            min(
                Self.jsonInt(input["limit"]) ?? Self.readChatMessageDefaultPageCharacters,
                Self.readChatMessageMaximumPageCharacters
            )
        )
        let requestedSession = input["session_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The session ids to look in, most recently written first. An explicit id is the most specific instruction there is; without one this looks through the same file set search_chat_history searches.
        let files: [(String, URL)]
        var listingFailed = false
        let archived = try ChatSessionRetention.archivedTranscripts(dataRoot: dataRoot)
        if let requestedSession, !requestedSession.isEmpty {
            files = try ChatSessionRetention.transcriptFiles(
                dataRoot: dataRoot, sessionId: validatedChatSessionId(requestedSession), archived: archived)
        } else {
            do {
                files = try ChatSessionRetention.transcriptFiles(dataRoot: dataRoot, archived: archived)
            } catch {
                files = []
                listingFailed = true
            }
        }

        // The canonical transcript reader — the same one prompt assembly uses. No second JSONL parser lives here.
        let reader = SessionHistoryReader(dataRoot: dataRoot)
        // Shared message ids return the newest-written copy and list other sessions for explicit selection.
        var found: (sessionId: String, index: Int, message: ChatMessage, stats: SessionHistoryReadStats)?
        var alsoIn: [String] = []
        var unreadableSessionCount = 0
        var missingSessionCount = 0
        var malformedRowCount = 0
        var invalidShapeRowCount = 0
        let index = ChatHistoryIndex.shared(dataRoot: dataRoot)
        for (sessionId, file) in files {
            // The history index says which transcripts hold the id; only those are read whole.
            guard let rows = try? index.rows(at: file, receipts: false) else {
                if FileManager.default.fileExists(atPath: file.path) { unreadableSessionCount += 1 }
                else { missingSessionCount += 1 }
                continue
            }
            guard rows.contains(where: { $0.valid && $0.messageId == messageId }) else {
                // Counted as the canonical reader would have counted this transcript.
                malformedRowCount += rows.filter { $0.shape == 0 && !$0.identity.isEmpty }.count
                invalidShapeRowCount += rows.filter { $0.shape == 1 }.count
                continue
            }
            guard let read = try? await reader.messagesWithStats(forSessionId: sessionId, strictEvidence: true, transcriptURL: file) else {
                unreadableSessionCount += 1
                continue
            }
            if read.stats.mode == "missing" {
                missingSessionCount += 1
                continue
            }
            guard read.stats.mode == "full", !read.stats.truncated else {
                unreadableSessionCount += 1
                continue
            }
            malformedRowCount += read.stats.malformedRowCount
            invalidShapeRowCount += read.stats.invalidShapeRowCount
            let messages = read.messages
            guard let index = messages.firstIndex(where: { message in
                guard case .object(let row)? = message.extras,
                      case .string(let id)? = row["id"] else { return false }
                return id == messageId
            }) else { continue }
            if found == nil {
                found = (sessionId, index, messages[index], read.stats)
            } else if found?.sessionId != sessionId, !alsoIn.contains(sessionId) {
                alsoIn.append(sessionId)
            }
        }
        let complete = !listingFailed && unreadableSessionCount == 0
            && malformedRowCount == 0 && invalidShapeRowCount == 0
        let coverage: JSONValue = .object([
            "complete": .bool(complete),
            "scope": .string(requestedSession?.isEmpty == false ? "explicit_session" : "all_sessions"),
            "directory_listing_failed": .bool(listingFailed),
            "unreadable_session_count": .int(Int64(unreadableSessionCount)),
            "missing_session_count": .int(Int64(missingSessionCount)),
            "malformed_row_count": .int(Int64(malformedRowCount)),
            "invalid_shape_row_count": .int(Int64(invalidShapeRowCount)),
        ])
        guard let found else {
            return .object([
                "status": .string(complete ? "not_found" : "error"),
                "runtime": .string("swift-native"),
                "tool": .string(invokedAs),
                "message_id": .string(messageId),
                "searched_session_count": .int(Int64(Set(files.map { $0.0 }).count)),
                "coverage": coverage,
                "reason": .string(!complete
                    ? "History could not be read completely. This does not establish that the message is absent. Preserve the original locator; do not recreate or replay the original action."
                    : requestedSession?.isEmpty == false
                    ? "No message with that id in that session. Drop session_id to search every transcript."
                    : "No message with that id in any transcript. Ids come from search_chat_history hits."),
            ])
        }

        let isToolReceipt = found.message.role.lowercased() == "tool"
        let readText: String
        if isToolReceipt, case .object(let row)? = found.message.extras {
            readText = Self.persistedToolReceiptText(row: row, metadata: Self.persistedHistoryMetadata(row: row))
        } else {
            readText = found.message.content
        }
        let characters = Array(readText)
        let start = min(offset, characters.count)
        let end = min(start + limit, characters.count)
        let page = String(characters[start..<end])
        var response: [String: JSONValue] = [
            "status": .string("ok"),
            "runtime": .string("swift-native"),
            "tool": .string(invokedAs),
            "source": .string("chat_history_jsonl"),
            "message_id": .string(messageId),
            "session_id": .string(found.sessionId),
            "role": .string(found.message.role),
            "timestamp": .string(found.message.timestamp),
            "message_index": .int(Int64(found.index)),
            "coverage": coverage,
            "total_characters": .int(Int64(characters.count)),
            "offset": .int(Int64(start)),
            "returned_characters": .int(Int64(end - start)),
            "has_more": .bool(end < characters.count),
            "text": .string(page),
        ]
        if found.message.role.lowercased() == "user",
           case .object(let row)? = found.message.extras,
           let label = ChatTranscriptEvidenceRendering.recordedOriginLabel(row, role: "user"),
           case .object(let metadata)? = row["metadata"], let origin = metadata["origin"] {
            response["origin"] = origin
            response["authorship"] = .string(label)
        }
        if case .object(let row)? = found.message.extras {
            response.merge(Self.historyEvidence(Self.persistedHistoryPeer(role: found.message.role, row: row),
                                                words: page, dataRoot: dataRoot)) { _, new in new }
        }
        if found.stats.malformedRowCount > 0 || found.stats.invalidShapeRowCount > 0 {
            response["message_index"] = .null
            response["message_index_note"] = .string("Source row index unavailable because earlier rows may have been skipped. Use the exact message_id and session_id.")
        }
        if !complete {
            response["coverage_note"] = .string("The returned message was readable, but other history evidence was unavailable or malformed. Other copies or missing messages cannot be ruled out.")
        }
        if isToolReceipt {
            response["evidence_type"] = .string("persisted_tool_receipt")
            response["receipt_coverage"] = .string(Self.toolReceiptCoverage)
        }
        if end < characters.count {
            response["next_offset"] = .int(Int64(end))
        }
        if !alsoIn.isEmpty {
            response["also_in_sessions"] = .array(alsoIn.map { .string($0) })
            response["session_ambiguous"] = .bool(true)
            response["note"] = .string(
                "This id also exists in \(alsoIn.count) other session(s) — forks copy rows verbatim. "
                + "Returned the most recently written copy, from session_id '\(found.sessionId)'. "
                + "Pass session_id to read a named copy."
            )
        }
        if let title = readChatHistorySessionMetadata()[found.sessionId]?.title, !title.isEmpty {
            response["session_title"] = .string(title)
        }
        return .object(response)
    }
}

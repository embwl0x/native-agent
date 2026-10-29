import Foundation
import CryptoKit
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Transcripts
// Blueprint: | `ChatOrchestrationClient+AttachmentEvidence.swift` | `CodexCompletionTranscriptEvidence`: exact completion binding and saved attachment recovery; transcript/queue attachment writer and speech corrections |

public enum CodexCompletionTranscriptEvidence {
    public enum RecoveryError: Error, Equatable {
        case corruptBinding
        case ambiguousBinding
    }

    static func identityRow(for attachment: MultimodalAttachment) -> [String: JSONValue] {
        [
            "id": .string(attachment.id),
            "type": .string(attachment.type),
            "mime": .string(attachment.mime),
            "name": .string(attachment.name ?? ""),
            "byteSize": .int(Int64(attachment.byteSize)),
        ]
    }

    public static func responseDigest(
        sessionId: String,
        runId: String,
        content: String,
        attachments: [MultimodalAttachment]
    ) -> String {
        let attachmentRows: [JSONValue] = attachments.map { attachment in
            var row = identityRow(for: attachment)
            if let path = attachment.path, !path.isEmpty { row["path"] = .string(path) }
            return .object(row)
        }
        let payload: JSONValue = .object([
            "attachments": .array(attachmentRows),
            "content": .string(content),
            "runId": .string(runId),
            "sessionId": .string(sessionId),
        ])
        let bytes = (try? payload.serializedData(pretty: false)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func recoverRunId(
        from rows: [JSONValue],
        deliveryId: String,
        requestDigest: String?,
        sessionId: String
    ) throws -> String? {
        var matches: [String] = []
        for row in rows {
            guard case .object(let object) = row,
                  case .string(let role)? = object["role"], role == "assistant",
                  case .string(let rowSession)? = object["sessionId"], rowSession == sessionId,
                  case .string(let content)? = object["content"],
                  case .string(let runId)? = object["runId"],
                  case .object(let metadata)? = object["metadata"],
                  case .object(let binding)? = metadata["codexCompletion"],
                  case .string(let rowDelivery)? = binding["deliveryId"],
                  rowDelivery == deliveryId,
                  case .string(let rowRequestDigest)? = binding["requestDigest"],
                  requestDigest == nil || rowRequestDigest == requestDigest,
                  case .string? = binding["model"],
                  case .string(let storedResponseDigest)? = binding["responseDigest"]
            else { continue }
            let attachments = try decodeAttachments(metadata["attachments"])
            guard responseDigest(
                sessionId: sessionId,
                runId: runId,
                content: content,
                attachments: attachments
            ) == storedResponseDigest else {
                throw RecoveryError.corruptBinding
            }
            matches.append(runId)
        }
        guard matches.count <= 1 else { throw RecoveryError.ambiguousBinding }
        return matches.first
    }

    /// A saved user row as a restart recovers its turn.
    public struct SavedTurnInput: Sendable {
        public let runId: String
        public let content: String
        public let awaitingConsumption: Bool
        /// Its attachments with their saved bytes (read only for input still
        /// awaiting its turn), or why they cannot be read back whole.
        public let attachments: Result<[MultimodalAttachment], any Error>
    }

    /// Every run's saved user input in a session, in transcript order, from one
    /// strict read: a damaged transcript is an error, never empty history.
    public static func savedTurnInputs(dataRoot: URL, sessionId: String) async throws -> [SavedTurnInput] {
        guard let id = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw ChatOrchestrationError.underlying("invalid chat session id")
        }
        let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(
            dataRoot.appendingPathComponent("chat/messages/\(id).jsonl"))
        guard report.isClean else {
            throw ChatOrchestrationError.underlying("\(id)'s transcript has unreadable rows; repair it before its saved turns resume.")
        }
        return rows.compactMap { row in
            guard case .object(let fields) = row, fields["role"] == .string("user"),
                  case .string(let run)? = fields["runId"], case .string(let content)? = fields["content"] else { return nil }
            let metadata: [String: JSONValue] = if case .object(let value)? = fields["metadata"] { value } else { [:] }
            let awaiting = metadata["awaitingConsumption"] == .bool(true)
            return SavedTurnInput(runId: run, content: content, awaitingConsumption: awaiting,
                                  attachments: awaiting ? Result { try savedAttachments(metadata["attachments"]) } : .success([]))
        }
    }

    /// A saved user row's attachments as a resumed turn takes them: decoded,
    /// each with its saved file's bytes. Every restart recovery of saved input
    /// reads them here (a checkpointed turn, a contact message left queued).
    public static func savedAttachments(_ value: JSONValue?) throws -> [MultimodalAttachment] {
        var attachments = try decodeAttachments(value)
        for index in attachments.indices {
            if attachments[index].utterance?.audioReference != nil { continue }
            guard let path = attachments[index].path else {
                throw ChatOrchestrationError.underlying("The resumed turn's attachment has no saved file; restore it before resuming.")
            }
            attachments[index].base64 = try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()
        }
        return attachments
    }

    static func decodeAttachments(_ value: JSONValue?) throws -> [MultimodalAttachment] {
        guard let value else { return [] }
        guard case .array(let rows) = value else { throw RecoveryError.corruptBinding }
        return try rows.map { row in
            guard case .object(let object) = row,
                  case .string(let id)? = object["id"],
                  case .string(let type)? = object["type"],
                  case .string(let mime)? = object["mime"],
                  case .string(let name)? = object["name"],
                  case .int(let byteSize)? = object["byteSize"],
                  byteSize >= 0, byteSize <= Int64(Int.max)
            else { throw RecoveryError.corruptBinding }
            let path: String?
            if case .string(let value)? = object["path"], !value.isEmpty { path = value }
            else { path = nil }
            return MultimodalAttachment(
                id: id,
                type: type,
                base64: "",
                mime: mime,
                name: name.isEmpty ? nil : name,
                byteSize: Int(byteSize),
                path: path,
                utterance: try object["utterance"].map { try JSONDecoder().decode(SpeechUtterance.self, from: $0.serializedData(pretty: false)) }
            )
        }
    }
}

extension SwiftNativeChatOrchestrationClient {
    nonisolated static func attachmentURL(chatRoot: URL, runId: String, index: Int) -> URL {
        chatRoot.appendingPathComponent("attachments/\(runId)/\(index)")
    }

    nonisolated static func persistAttachment(_ bytes: Data, chatRoot: URL, runId: String, index: Int) async throws -> URL {
        let path = attachmentURL(chatRoot: chatRoot, runId: runId, index: index)
        try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(bytes, to: path)
        return path
    }

    /// Pre-owner restore already selected the exact referenced attachment path.
    nonisolated static func persistAttachment(_ bytes: Data, to path: URL) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: path)
    }

    /// Only an exact transport reference from the original speaker can replace
    /// a transcript face. The audio and every recognition hypothesis stay put.
    public func correctSpeechTranscript(sessionId: String, reference: String, text: String) async throws -> Bool {
        let sessionId = try Self.resolveSessionId(sessionId)
        let path = dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        ChatSessionIndexFile.beginTranscriptIndexSync(at: path)
        defer { ChatSessionIndexFile.endTranscriptIndexSync(at: path) }
        let changed = try await SwiftNativePersistenceCore.withFileLock(path) {
            var (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
            guard report.isClean else { throw ChatOrchestrationError.underlying("Repair the unreadable conversation before correcting its transcript.") }
            var changed = false
            for index in rows.indices {
                guard case .object(var row) = rows[index], row["role"] == .string("user"),
                      case .object(var metadata)? = row["metadata"],
                      case .array(var attachments)? = metadata["attachments"] else { continue }
                for item in attachments.indices {
                    guard case .object(var attachment) = attachments[item], let evidence = attachment["utterance"] else { continue }
                    var utterance = try JSONDecoder().decode(SpeechUtterance.self, from: evidence.serializedData(pretty: false))
                    guard utterance.correctionReferences?.contains(reference) == true else { continue }
                    let oldFace = utterance.face
                    utterance.correctedText = text
                    attachment["utterance"] = try JSONValue.parse(JSONEncoder().encode(utterance))
                    attachments[item] = .object(attachment)
                    if case .string(let content)? = row["content"], content.hasSuffix(oldFace) {
                        row["content"] = .string(String(content.dropLast(oldFace.count)) + utterance.face)
                    }
                    changed = true
                }
                metadata["attachments"] = .array(attachments)
                row["metadata"] = .object(metadata)
                rows[index] = .object(row)
            }
            if changed { try ContactThread.replace(rows, to: path) }
            return changed
        }
        if changed {
            await bumpSessionTranscriptGeneration(sessionId: sessionId)
            NotificationCenter.default.post(name: .nativeAgentChatTranscriptDidChange, object: sessionId)
        }
        return changed
    }
}

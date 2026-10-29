import Foundation
import NativeAgentShared
import Experiences
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import ProviderRouting
// Blueprint: | `ChatCompactionRowRendering.swift` | Canonical compaction reading of tool row metadata |
/// Compaction reads tool payloads from metadata, preserving their size and summary evidence.
enum ChatCompactionRowRendering {
    static func receiptSourceNote(_ rows: [JSONValue], sessionId: String) -> String {
        for row in rows.reversed() {
            guard case .object(let object) = row, case .object(let metadata)? = object["metadata"] else { continue }
            if case .string? = metadata["toolName"], case .string(let id)? = object["id"] {
                let read: JSONValue = .object(["action": .string("chat.message"), "args": .object([
                    "session_id": .string(sessionId), "message_id": .string(id),
                ])])
                if let call = try? read.serialize(pretty: false) {
                    return "[Source: recollection, not a receipt. Latest stored tool receipt: app \(call). Stored results may be bounded/redacted; result.page handles expire at turn end.]"
                }
            }
            if case .string(let note)? = metadata["receipt_source_note"] { return note }
        }
        return "[Source: recollection. Tool receipts record dispatches; assistant text records claims.]"
    }
    private static func contentValue(_ obj: [String: JSONValue]) -> JSONValue? {
        if case .string? = obj["content"] { return obj["content"] }
        if case .string? = obj["text"] { return obj["text"] }
        return obj["content"]
    }
    /// Characters this row contributes to the transcript size estimate. When
    /// `content` is empty the payload lives in `metadata`, so the serialized
    /// metadata length stands in for it.
    static func characterCount(_ obj: [String: JSONValue]) -> Int {
        // Delivery bytes count toward the model window, but summaryBody still
        // reads only what the person said. Context is never distilled as speech.
        if obj["role"] == .string("user"),
           case .object(let metadata)? = obj["metadata"],
           let sent = SentTurnContext(metadata: metadata) {
            let words = sent.userText ?? {
                if case .string(let text)? = contentValue(obj) { return text }
                return ""
            }()
            return words.utf8.count + sent.block.utf8.count
        }
        if let content = contentValue(obj) {
            if case .string(let text) = content {
                if !text.isEmpty { return text.count }
            } else {
                return ((try? content.serialize(pretty: false)) ?? "").count
            }
        }
        guard let metadata = obj["metadata"] else { return 0 }
        return ((try? metadata.serialize(pretty: false)) ?? "").count
    }
    /// The transcript line body for a row, or nil when the row carries nothing
    /// worth preserving. A tool row (empty `content`, a `toolName` in metadata)
    /// renders exactly as prompt history renders it — same status, projection,
    /// and secret redaction — so post-compaction continuity keeps a record of
    /// the tool activity.
    static func summaryBody(
        _ obj: [String: JSONValue],
        collapseNewlines: Bool,
        toolSummaryCap: Int? = nil
    ) -> String? {
        let content: String = {
            if case .string(let text)? = contentValue(obj) { return text }
            if let value = contentValue(obj) { return (try? value.serialize(pretty: false)) ?? "" }
            return ""
        }()
        let normalized = normalize(content, collapseNewlines: collapseNewlines)
        let metadata: [String: JSONValue]?
        if case .object(let value)? = obj["metadata"] { metadata = value } else { metadata = nil }
        var line = normalized
        if line.isEmpty, case .string(let toolName)? = metadata?["toolName"],
           !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            line = SessionHistoryPromptRenderer.toolSummary(content: "", metadata: metadata, resultCap: toolSummaryCap)
        }
        if case .string? = metadata?["toolName"], case .string(let id)? = obj["id"] {
            line = "[Recorded tool receipt; context.expand history:\(id)] " + line
        }
        let body = ChatTranscriptEvidenceRendering.contentIncludingAttachments(
            line, attachments: metadata?["attachments"])
        guard !body.isEmpty else { return nil }
        let role: String
        if case .string(let value)? = obj["role"] {
            role = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } else { role = "" }
        let isCompactionSummary: Bool
        if case .string("compaction_summary")? = metadata?["kind"] { isCompactionSummary = true }
        else { isCompactionSummary = false }
        return ChatTranscriptEvidenceRendering.displayContent(
            body,
            originLabel: role == "user" && !isCompactionSummary
                ? ChatTranscriptEvidenceRendering.recordedOriginLabel(obj, role: role) : nil,
            incompleteReplyLabel: role == "assistant" && !isCompactionSummary
                ? ChatTranscriptEvidenceRendering.recordedIncompleteReplyLabel(extras: obj, metadata: metadata) : nil)
    }
    /// True when this row is a consolidated recollection a PRIOR compaction
    /// wrote, rather than an ordinary turn. The one place that knows the shape
    /// for both compaction paths (see `ChatSessionRecollections.rowKind`).
    static func isRecollection(_ obj: [String: JSONValue]) -> Bool {
        guard case .object(let metadata)? = obj["metadata"],
              case .string(let kind)? = metadata["kind"]
        else { return false }
        return kind == ChatSessionRecollections.rowKind
    }
    /// Recollection source rows carry bounded tool-result evidence.
    static let distillerToolResultSummaryMaximumCharacters = 1_000
    private static func normalize(_ text: String, collapseNewlines: Bool) -> String {
        // Same redactor prompt history applies, so a compaction summary can
        // never carry a secret the live prompt would have masked.
        let redacted = ChatSecretRedactor.redactText(text)
        let flattened = collapseNewlines
            ? redacted.replacingOccurrences(of: "\n", with: " ")
            : redacted
        return flattened.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

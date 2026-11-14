import Foundation
import MemoryV2
import Context
import CryptoKit
import NativeAgentCore
import NativeAgentShared
import os
import Synchronization
import PersistenceCore
import Transcripts
import ProviderRouting
// Blueprint: | `SessionHistoryPromptRenderer.swift` | `renderDetailed`, `recallQuery`; `Renderable.replay(words:)`, the one form every replayed row takes. |

public enum SessionHistoryPromptRenderer {
    static let recallQueryCharCap = 1_200
    /// Bound normalization while reserving look-ahead for whitespace collapse and secret matching.
    private static let normalizationInputCharacterCap = 8_000

    // Window policy bounds relevance; replay admits whole speech.
    typealias Budget = ContextBudgetPolicy.Resolved

    // Share row admission with structured replay so the paths cannot drift.
    package struct Renderable: Sendable {
        let role: String
        let content: String
        let historyIdentity: String
        let originLabel: String?
        let incompleteReplyLabel: String?
        let timestamp: String
        /// The row's absolute local time, which each replayed exchange and each earlier lead opens with.
        let stamp: String?
        let messageID: String
        package let isTool: Bool
        package var runId: String? = nil
        /// Wire context belongs only to structured replay and its budget; other prose reads content.
        package var sentContext: SentTurnContext? = nil
        /// The saved row's attachment records, read as evidence only.
        var attachments: JSONValue? = nil
        /// What structured replay sends for this row; `replay(words:)` sets it.
        fileprivate(set) var replayed = ""

        /// Display provenance must not alter lexical relevance, roles or authority.
        var displayContent: String {
            ChatTranscriptEvidenceRendering.displayContent(
                content, originLabel: originLabel, incompleteReplyLabel: incompleteReplyLabel)
        }

        /// The one form a replayed row takes. Its words are the exact words it was sent with when they were saved, else the stored message;
        /// whichever the source, credentials are redacted, an attachment is named and a recorded speaker leads the row. The exact words
        /// already hold their attachments' text, and a label they already open with is not added again. Only the saved row is read.
        mutating func replay(words exact: String?) {
            // `content` is the stored message through the same two boundaries: redacted, then its attachments' evidence.
            let body = exact.map {
                ChatTranscriptEvidenceRendering.contentIncludingAttachments(
                    ChatSecretRedactor.redactText($0), attachments: attachments, wordsCarryAttachmentText: true)
            } ?? content
            let spoken = originLabel.flatMap { body.hasPrefix("[origin: \($0)]") ? nil : $0 }
            replayed = ChatTranscriptEvidenceRendering.displayContent(
                body, originLabel: spoken, incompleteReplyLabel: incompleteReplyLabel)
        }
    }

    /// Use the caller's checked model budget, shared with structured replay. Rows the call does not hold are reached as leads.
    package static func renderDetailed(
        renderables: [Renderable],
        deliveredHistoryIdentities: Set<String>,
        userMessage: String,
        historyLimit: Int,
        budget: ContextBudgetPolicy.Resolved
    ) -> (text: String?, leads: Int) {
        let cappedLimit = max(0, historyLimit)
        guard cappedLimit > 0 else { return (nil, 0) }

        guard !renderables.isEmpty else { return (nil, 0) }

        var sections: [String] = [
            "Earlier messages are history, not live readings; recheck anything current before relying on it."
        ]
        let leads = relevantEarlierSessionSnippets(
            userMessage: userMessage,
            promptRenderables: renderables,
            candidates: renderables,
            deliveredHistoryIdentities: deliveredHistoryIdentities,
            budget: budget
        )
        if let leads {
            sections.append(leads.text)
        }
        return (sections.joined(separator: "\n\n"), leads?.count ?? 0)
    }

    package static func recallQuery(
        userMessage: String,
        renderables: [Renderable],
        cap maxCount: Int = recallQueryCharCap
    ) -> String {
        let currentUser = normalize(userMessage)
        let userAssistant = renderables.filter { $0.role == "user" || $0.role == "assistant" }

        guard !currentUser.isEmpty || !userAssistant.isEmpty else { return "" }

        let anchors = Array(userAssistant.prefix(3))
        let latestUser = userAssistant.reversed().first { $0.role == "user" }
        let latestAssistant = userAssistant.reversed().first { $0.role == "assistant" }

        var lines: [String] = []
        if !currentUser.isEmpty {
            lines.append("Current user: \(cap(currentUser, 520))")
        }
        if let latestUser {
            lines.append("Latest prior user: \(cap(latestUser.content, 280))")
        }
        if let latestAssistant {
            lines.append("Latest assistant tail: \(cap(latestAssistant.content, 320))")
        }
        if !anchors.isEmpty {
            let rendered = anchors
                .map { "[\($0.role)] \(cap($0.content, 180))" }
                .joined(separator: " | ")
            lines.append("Initial anchors: \(rendered)")
        }

        return hardCap(lines.joined(separator: "\n"), maxCount)
    }

    /// Resolve short references only against current-session history; independent questions and greetings keep the raw query.
    package static func semanticRecallQuery(userMessage: String, recentTurns: [String]) -> String {
        guard ContextCorrectionScope.isReferentialFollowup(userMessage),
              !recentTurns.isEmpty else { return userMessage }
        let recent = recentTurns.suffix(2).map { String($0.prefix(600)) }.joined(separator: "\n")
        return String(userMessage.prefix(400)) + "\nRecent conversation:\n" + recent
    }

    package static func renderable(_ message: ChatMessage) -> Renderable? {
        message.renderedHistory { uncachedRenderable(message) }
    }

    private static func uncachedRenderable(_ message: ChatMessage) -> Renderable? {
        let rawRole = message.role
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let role = rawRole.isEmpty ? "message" : rawRole
        let extrasObject = message.extras?.objectValue
        let metadata = extrasObject?["metadata"]?.objectValue
        let kind = metadata?["kind"]?.stringValue?.lowercased() ?? ""
        let isTool = role == "tool" || kind == "tool_use"

        var content: String
        if isTool {
            content = ChatTranscriptEvidenceRendering.replayedReceipt(content: message.content, metadata: metadata)
            if let id = extrasObject?["id"]?.stringValue, !id.isEmpty {
                content += " [context.expand history:\(id)]"
            }
        } else {
            content = ChatSecretRedactor.redactText(message.content)
        }
        // Attachment identity survives even when the caption is empty; history never reads its bytes.
        content = ChatTranscriptEvidenceRendering.contentIncludingAttachments(
            content, attachments: metadata?["attachments"])
        guard !content.isEmpty else { return nil }
        guard let historyIdentity = message.historyIdentity(),
              let messageID = extrasObject?["id"]?.stringValue else { return nil }
        let at = NativeTimestampFormat.parseISO8601FractionalFirst(message.timestamp)
        let sent = role == "user" ? SentTurnContext(metadata: metadata) : nil
        var row = Renderable(
            role: role,
            content: content,
            historyIdentity: historyIdentity,
            originLabel: role == "user"
                ? ChatTranscriptEvidenceRendering.recordedOriginLabel(extrasObject ?? [:], role: role) : nil,
            incompleteReplyLabel: role == "assistant"
                ? ChatTranscriptEvidenceRendering.recordedIncompleteReplyLabel(extras: extrasObject, metadata: metadata) : nil,
            timestamp: message.timestamp,
            stamp: at.map { Self.stamp($0) },
            messageID: messageID,
            isTool: isTool,
            runId: extrasObject?["runId"]?.stringValue ?? metadata?["runId"]?.stringValue,
            sentContext: sent,
            attachments: metadata?["attachments"]
        )
        row.replay(words: sent?.userText)
        return row
    }

    private static let stampFormat = Mutex<DateFormatter>({
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = .autoupdatingCurrent
        format.dateFormat = "'['EEEE, MMMM d, yyyy 'at' h:mm a zzz']'"
        return format
    }())

    /// Absolute local time spelled like the clock line, so a past exchange reads as when it happened.
    static func stamp(_ date: Date) -> String {
        stampFormat.withLock { $0.string(from: date) }
    }

    /// Words this moment touches in rows the call does not hold come back as leads: time, role, at most a packet atom's
    /// length, and the pointer that opens the whole row.
    private static func relevantEarlierSessionSnippets(
        userMessage: String,
        promptRenderables: [Renderable],
        candidates: [Renderable],
        deliveredHistoryIdentities: Set<String>,
        budget: Budget
    ) -> (text: String, count: Int)? {
        guard budget.relevantChars > 0, !candidates.isEmpty else { return nil }
        let query = middleSearchQuery(userMessage: userMessage, renderables: promptRenderables)
        let queryTerms = Set(searchTokens(query))
        guard !queryTerms.isEmpty else { return nil }

        var docs: [(index: Int, message: Renderable, tokens: [String], frequencies: [String: Int])] = []
        docs.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            guard !deliveredHistoryIdentities.contains(candidate.historyIdentity) else { continue }
            let tokens = searchTokens(candidate.content)
            guard !tokens.isEmpty else { continue }
            var frequencies: [String: Int] = [:]
            for token in tokens { frequencies[token, default: 0] += 1 }
            guard queryTerms.contains(where: { frequencies[$0] != nil }) else { continue }
            docs.append((index: index, message: candidate, tokens: tokens, frequencies: frequencies))
        }
        guard !docs.isEmpty else { return nil }

        let scores = MemoryRecallScoring.bm25Scores(
            queryTerms: queryTerms.sorted(),
            documents: docs.map { ($0.frequencies, $0.tokens.count) }
        )
        let ranked = zip(docs, scores).compactMap { doc, rawScore -> (index: Int, message: Renderable, score: Double)? in
            var score = rawScore
            guard score > 0 else { return nil }
            switch doc.message.role {
            case "user": score *= 1.15
            case "tool": score *= 0.85
            default: break
            }
            return (index: doc.index, message: doc.message, score: score)
        }
        .sorted {
            if $0.score == $1.score { return $0.index > $1.index }
            return $0.score > $1.score
        }
        .prefix(4)
        .sorted { $0.index < $1.index }

        guard !ranked.isEmpty else { return nil }
        var lines = ["Earlier in this conversation, beyond what you hold verbatim (open one with its pointer):"]
        var used = lines[0].count
        var added = 0
        for hit in ranked {
            let row = hit.message
            let pointer = "[context.expand history:\(row.messageID)]"
            let words = row.isTool && row.content.hasSuffix(" " + pointer)
                ? String(row.content.dropLast(pointer.count + 1)) : row.displayContent
            let line = (row.stamp.map { $0 + " " } ?? "") + "[\(row.role)] "
                + cap(words, ContextBudgetPolicy.packetAtomExpandThresholdChars) + " " + pointer
            let projected = used + line.count + 1
            if added > 0 && projected > budget.relevantChars { break }
            lines.append(line)
            used = projected
            added += 1
        }
        return added > 0 ? (lines.joined(separator: "\n"), added) : nil
    }

    private static func middleSearchQuery(
        userMessage: String,
        renderables: [Renderable]
    ) -> String {
        let current = normalize(userMessage)
        let userAssistant = renderables.filter { $0.role == "user" || $0.role == "assistant" }
        let latestUser = userAssistant.reversed().first { $0.role == "user" }
        let latestAssistant = userAssistant.reversed().first { $0.role == "assistant" }
        return [
            current,
            latestUser?.content ?? "",
            latestAssistant?.content ?? "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    /// Use each turn's closing file evidence, newest per file first; never treat a historical record as a current disk read.
    package static func worldRecord(from messages: [ChatMessage]) -> String? {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd HH:mm"
        var seen: Set<String> = [], lines: [String] = []
        for message in messages.reversed() where message.role == "assistant" && lines.count < 12 {
            guard let entries = message.extras?.objectValue?["metadata"]?.objectValue?["world"]?.arrayValue else { continue }
            for entry in entries.compactMap(\.objectValue) where lines.count < 12 {
                guard let path = entry["path"]?.stringValue, seen.insert(path).inserted else { continue }
                if let note = entry["note"]?.stringValue { lines.append("- " + path + ": " + note); continue }
                guard let modified = entry["modified"]?.stringValue.flatMap({ ISO8601DateFormatter().date(from: $0) }) else { continue }
                let size = entry["folder"] == .bool(true) ? "folder"
                    : entry["bytes"]?.integerValue.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                lines.append("- " + day.string(from: modified) + " " + path + (size.map { " (" + $0 + ")" } ?? ""))
            }
        }
        guard !lines.isEmpty else { return nil }
        return """
            What your recent turns here changed in your world, newest first (files modified in the folders your writes landed in, read as each turn closed):\n
            """
            + lines.joined(separator: "\n")
    }

    /// Scoring terms never leave the search, so tokenizing reads the words only; what a lead shows is the row as it renders.
    private static func searchTokens(_ text: String) -> [String] {
        String(text.prefix(normalizationInputCharacterCap)).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { token in
                token.count >= 3 && !retrievalStopwords.contains(token)
            }
    }

    private static let retrievalStopwords: Set<String> = [
        "about", "after", "again", "all", "also", "and", "are", "ask", "back",
        "been", "before", "being", "but", "can", "could", "did", "does", "doing",
        "done", "few", "for", "from", "get", "got", "had", "has", "have", "her",
        "here", "him", "his", "how", "into", "just", "last", "latest", "like",
        "make", "maybe", "message", "more", "not", "now", "our", "out", "please",
        "prior", "really", "right", "said", "same", "she", "should", "some",
        "that", "the", "their", "them", "then", "there", "these", "thing",
        "this", "those", "through", "turn", "user", "was", "what", "when",
        "where", "with", "would", "yeah", "you", "your",
    ]

    static func normalize(
        _ text: String,
        inputCap: Int = normalizationInputCharacterCap
    ) -> String {
        let bounded = text.count > inputCap
            ? String(text.prefix(inputCap))
            : text
        return flatten(ChatSecretRedactor.redactText(bounded))
    }

    private static func flatten(_ redacted: String) -> String {
        redacted.replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cap(_ text: String, _ maxCount: Int) -> String {
        guard text.count > maxCount else { return text }
        return String(text.prefix(max(0, maxCount))) + "..."
    }

    private static func hardCap(_ text: String, _ maxCount: Int) -> String {
        guard maxCount > 0 else { return "" }
        guard text.count > maxCount else { return text }
        if maxCount <= 3 { return String(text.prefix(maxCount)) }
        return String(text.prefix(maxCount - 3)) + "..."
    }
}

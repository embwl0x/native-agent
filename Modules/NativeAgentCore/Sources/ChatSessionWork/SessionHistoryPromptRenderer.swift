import Foundation
import MemoryV2
import Context
import CryptoKit
import NativeAgentCore
import os
import PersistenceCore
import Transcripts
import ProviderRouting
// Blueprint: | `SessionHistoryPromptRenderer.swift` | `renderDetailed`, `recallQuery`. |

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
        package let isTool: Bool
        package var runId: String? = nil
        /// Wire context belongs only to structured replay and its budget; other prose reads content.
        package var sentContext: SentTurnContext? = nil

        // Request measurement can supply exact model-facing text without changing the saved row.
        var structuredContent: String = ""

        /// Display provenance must not alter lexical relevance, roles or authority.
        var displayContent: String {
            ChatTranscriptEvidenceRendering.displayContent(
                content, originLabel: originLabel, incompleteReplyLabel: incompleteReplyLabel)
        }

        var structuredDisplayContent: String {
            ChatTranscriptEvidenceRendering.displayContent(
                structuredContent.isEmpty ? content : structuredContent,
                originLabel: originLabel,
                incompleteReplyLabel: incompleteReplyLabel)
        }
    }

    /// Use the caller's checked model budget, shared with structured replay.
    package static func renderDetailed(
        renderables: [Renderable],
        middleCandidates: [Renderable],
        deliveredHistoryIdentities: Set<String>,
        userMessage: String,
        historyLimit: Int,
        budget: ContextBudgetPolicy.Resolved
    ) -> String? {
        let cappedLimit = max(0, historyLimit)
        guard cappedLimit > 0 else { return nil }

        guard !renderables.isEmpty else { return nil }

        var sections: [String] = [
            "Earlier messages are history, not live readings; recheck anything current before relying on it."
        ]
        let middleSnippet = relevantEarlierSessionSnippets(
            userMessage: userMessage,
            promptRenderables: renderables,
            candidates: middleCandidates,
            deliveredHistoryIdentities: deliveredHistoryIdentities,
            budget: budget
        )
        if let middle = middleSnippet {
            sections.append(middle)
        }
        return sections.joined(separator: "\n\n")
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
        var structured = ""
        if isTool {
            content = ChatTranscriptEvidenceRendering.historicalReceipt(content: message.content, metadata: metadata).text
            if let id = extrasObject?["id"]?.stringValue, !id.isEmpty {
                content += " [context.expand history:\(id)]"
            }
        } else {
            content = ChatSecretRedactor.redactText(message.content)
            structured = content
        }
        if structured == content { structured = "" }
        // Attachment identity survives even when the caption is empty; history never reads its bytes.
        content = ChatTranscriptEvidenceRendering.contentIncludingAttachments(
            content, attachments: metadata?["attachments"])
        if !structured.isEmpty {
            structured = ChatTranscriptEvidenceRendering.contentIncludingAttachments(
                structured, attachments: metadata?["attachments"])
        }
        guard !content.isEmpty else { return nil }
        guard let historyIdentity = message.historyIdentity() else { return nil }
        return Renderable(
            role: role,
            content: content,
            historyIdentity: historyIdentity,
            originLabel: role == "user"
                ? ChatTranscriptEvidenceRendering.recordedOriginLabel(extrasObject ?? [:], role: role) : nil,
            incompleteReplyLabel: role == "assistant"
                ? ChatTranscriptEvidenceRendering.recordedIncompleteReplyLabel(extras: extrasObject, metadata: metadata) : nil,
            timestamp: message.timestamp,
            isTool: isTool,
            runId: extrasObject?["runId"]?.stringValue ?? metadata?["runId"]?.stringValue,
            sentContext: role == "user" ? SentTurnContext(metadata: metadata) : nil,
            structuredContent: structured
        )
    }

    private static func relevantEarlierSessionSnippets(
        userMessage: String,
        promptRenderables: [Renderable],
        candidates: [Renderable],
        deliveredHistoryIdentities: Set<String>,
        budget: Budget
    ) -> String? {
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
            queryTerms: Array(queryTerms),
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
        var lines = ["Relevant earlier session snippets:"]
        var used = lines[0].count
        var added = 0
        for hit in ranked {
            let capValue = budget.relevantItemCap
            let line = "[\(hit.message.role)] \(cap(hit.message.displayContent, capValue))"
            let projected = used + line.count + 1
            if added > 0 && projected > budget.relevantChars { break }
            lines.append(line)
            used = projected
            added += 1
        }
        return added > 0 ? lines.joined(separator: "\n") : nil
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

    // Replay preserves whole speech; relevance has its own snippet allowance.
    static func projectedHistoryText(_ msg: Renderable, budget: Budget) -> String {
        msg.structuredDisplayContent
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

    static let toolResultHeadChars = 110
    /// Retain the result tail because errors and exit status often appear at the end.
    static let toolResultTailChars = 50
    /// Bound normalization and redaction per end so a short preview cannot scan an entire large receipt.
    private static let toolResultRedactionWindow = 512

    /// Preserve both result ends and report elided character count so a clipped preview cannot imply completeness.
    package static func toolEvidenceProjection(_ raw: String) -> String {
        let keep = toolResultHeadChars + toolResultTailChars
        if raw.count <= toolResultRedactionWindow {
            let normalized = normalize(raw)
            guard normalized.count > keep else { return normalized }
            return String(normalized.prefix(toolResultHeadChars))
                + toolResultElisionMarker(normalized.count - keep)
                + String(normalized.suffix(toolResultTailChars))
        }
        // Too large to normalize whole: redact a bounded window at each end.
        let head = normalize(String(raw.prefix(toolResultRedactionWindow)))
        let tail = normalize(String(raw.suffix(toolResultRedactionWindow)))
        guard head.count > keep || !tail.isEmpty else { return head }
        let kept = min(head.count, toolResultHeadChars) + min(tail.count, toolResultTailChars)
        return String(head.prefix(toolResultHeadChars))
            + toolResultElisionMarker(max(0, raw.count - kept))
            + String(tail.suffix(toolResultTailChars))
    }

    private static func toolResultElisionMarker(_ elided: Int) -> String {
        " [… \(elided) chars elided …] "
    }

    private static func searchTokens(_ text: String) -> [String] {
        let normalized = normalize(text).lowercased()
        return normalized
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

import Foundation
import MemoryV2
import Context
import CryptoKit
import NativeAgentCore
import os
import PersistenceCore
import Transcripts
import ProviderRouting
// Blueprint: | `SessionHistoryPromptRenderer.swift` | `renderDetailed`, `recallQuery`: message text retains bracketed headings; sent context metadata remains separate from speech/relevance and is read only by structured replay |

public enum SessionHistoryPromptRenderer {
    static let recallQueryCharCap = 1_200
    /// Bound ordinary-row normalization work, retaining look-ahead for
    /// whitespace collapsing and secret matching before render-time clipping.
    private static let normalizationInputCharacterCap = 8_000

    /// Compaction summaries need a larger normalization window so their
    /// distiller-sized render cap is not truncated before budgeting.
    private static let compactionNormalizationInputCharacterCap =
        ChatCompactionDistiller.maxSummaryChars + 4_000

    /// The canonical policy resolves model-window budgets. Per-role caps bound
    /// individual rows; historyChars bounds conversation output, and earlier
    /// snippets additionally honor relevantItemCap and relevantChars. Compaction
    /// summaries have their own cap without enlarging either aggregate budget.
    typealias Budget = ContextBudgetPolicy.Resolved

    // Shared with structured projection so both lanes admit the same rows.
    package struct Renderable: Sendable {
        let role: String
        let content: String
        let historyIdentity: String
        let originLabel: String?
        let incompleteReplyLabel: String?
        let timestamp: String
        package let isTool: Bool
        let isCompactionSummary: Bool
        /// True for the read-only recollection borrowed from the conversation
        /// anchor (`CarriedAnchorRecollection`). Changes only the LABEL the v2
        /// projection leads with — every cap, exemption and identity rule
        /// treats it exactly as the session's own recollection.
        var isCarriedRecollection: Bool = false
        /// Run id of the turn that produced this row, shared by history and recovery.
        package var runId: String? = nil
        /// Wire context belongs only to structured replay and its budget. All
        /// relevance, memory and compaction prose still reads `content`.
        package var sentContext: SentTurnContext? = nil

        /// How a recollection announces itself at the head of the replayed
        /// prefix. A borrowed one says so: the model must never read the main
        /// conversation's memory as something that happened in THIS session.
        var recollectionLabel: String {
            isCarriedRecollection
                ? CarriedAnchorRecollection.renderPrefix
                : "[session recollection]"
        }

        /// The same body as `content`, but with paragraph breaks, indentation
        /// and fenced code preserved. ONLY the v2 structured replay reads it —
        /// `content` stays whitespace-flattened so identity hashes, lexical
        /// scoring stay byte-identical. Empty means
        /// "no structured form" (tool rows, summaries); readers fall back to `content`.
        var structuredContent: String = ""

        /// Display provenance is not query text: origin labels must not affect
        /// lexical relevance, roles, or authority.
        var displayContent: String {
            ChatTranscriptEvidenceRendering.displayContent(
                content, originLabel: originLabel, incompleteReplyLabel: incompleteReplyLabel)
        }

        /// `displayContent` over the structure-preserving body.
        var structuredDisplayContent: String {
            ChatTranscriptEvidenceRendering.displayContent(
                structuredContent.isEmpty ? content : structuredContent,
                originLabel: originLabel,
                incompleteReplyLabel: incompleteReplyLabel)
        }
    }

    /// `windowTokens` is the model's context window for THIS turn (nil when the
    /// model is unknown or the caller has none). It selects the budget regime;
    /// see `ContextBudgetPolicy`.
    package static func renderDetailed(
        renderables: [Renderable],
        middleCandidates: [Renderable],
        deliveredHistoryIdentities: Set<String>,
        userMessage: String,
        historyLimit: Int,
        windowTokens: Int?
    ) -> String? {
        let cappedLimit = max(0, historyLimit)
        guard cappedLimit > 0 else { return nil }

        guard !renderables.isEmpty else { return nil }

        var sections: [String] = [
            "Earlier messages are history, not live readings; recheck anything current before relying on it."
        ]
        let middleSnippet = middleSnippetText(
            userMessage: userMessage,
            promptRenderables: renderables,
            candidates: middleCandidates,
            deliveredHistoryIdentities: deliveredHistoryIdentities,
            windowTokens: windowTokens
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

    /// Short references need their referent for semantic recall. Greetings,
    /// standalone questions, and empty attachment text keep the raw query.
    /// Only current-session history is consulted; no backlog is introduced.
    package static func semanticRecallQuery(userMessage: String, recentTurns: [String]) -> String {
        guard ContextCorrectionScope.isReferentialFollowup(userMessage),
              !recentTurns.isEmpty else { return userMessage }
        let recent = recentTurns.suffix(2).map { String($0.prefix(600)) }.joined(separator: "\n")
        return String(userMessage.prefix(400)) + "\nRecent conversation:\n" + recent
    }

    private static func middleSnippetText(
        userMessage: String,
        promptRenderables: [Renderable],
        candidates: [Renderable],
        deliveredHistoryIdentities: Set<String>,
        windowTokens: Int?
    ) -> String? {
        relevantEarlierSessionSnippets(
            userMessage: userMessage,
            promptRenderables: promptRenderables,
            candidates: candidates,
            deliveredHistoryIdentities: deliveredHistoryIdentities,
            budget: ContextBudgetPolicy.resolve(windowTokens: windowTokens)
        )
    }

    package static func renderable(_ message: ChatMessage) -> Renderable? {
        let rawRole = message.role
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let role = rawRole.isEmpty ? "message" : rawRole
        let extrasObject = message.extras?.objectValue
        let metadata = extrasObject?["metadata"]?.objectValue
        let kind = metadata?["kind"]?.stringValue?.lowercased() ?? ""
        let isTool = role == "tool" || kind == "tool_use"
        let isCompactionSummary = kind == "compaction_summary"
        guard !isCompactionSummary || metadata?["distill"]?.stringValue == "llm" else { return nil }

        var content: String
        var structured = ""
        if isTool {
            content = ChatTranscriptEvidenceRendering.historicalReceipt(content: message.content, metadata: metadata).text
            if let id = extrasObject?["id"]?.stringValue, !id.isEmpty {
                content += " [context.expand history:\(id)]"
            }
        } else if isCompactionSummary {
            content = normalize(
                message.content,
                inputCap: compactionNormalizationInputCharacterCap
            )
        } else {
            let cap = role == "assistant" ? Int.max : normalizationInputCharacterCap
            let bounded = message.content.count > cap ? String(message.content.prefix(cap)) : message.content
            let redacted = ChatSecretRedactor.redactText(bounded)
            content = flatten(redacted)
            structured = normalizePreservingStructure(redacted)
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
        if role == "assistant", isTransientAssistantFailure(content) {
            return nil
        }
        return Renderable(
            role: isCompactionSummary ? "summary" : role,
            content: content,
            historyIdentity: message.historyIdentity(
                renderedRole: isCompactionSummary ? "summary" : role, renderedContent: content),
            originLabel: role == "user" && !isCompactionSummary
                ? ChatTranscriptEvidenceRendering.recordedOriginLabel(extrasObject ?? [:], role: role) : nil,
            incompleteReplyLabel: role == "assistant" && !isCompactionSummary
                ? ChatTranscriptEvidenceRendering.recordedIncompleteReplyLabel(extras: extrasObject, metadata: metadata) : nil,
            timestamp: message.timestamp,
            isTool: isTool,
            isCompactionSummary: isCompactionSummary,
            isCarriedRecollection: isCompactionSummary
                && !(metadata?[CarriedAnchorRecollection.carriedFromKey]?.stringValue ?? "").isEmpty,
            runId: extrasObject?["runId"]?.stringValue ?? metadata?["runId"]?.stringValue,
            sentContext: role == "user" ? SentTurnContext(metadata: metadata) : nil,
            structuredContent: structured
        )
    }

    private static func isTransientAssistantFailure(_ content: String) -> Bool {
        let lower = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("chat error:")
            || lower.hasPrefix("(drafting stalled;")
            || lower.hasPrefix("(internal error while drafting")
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
            let capValue = min(capForRole(hit.message, budget: budget), budget.relevantItemCap)
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

    /// The capped row text the projection replays, and what admission budgets;
    /// the message role carries the role prefix.
    static func projectedHistoryText(_ msg: Renderable, budget: Budget) -> String {
        cap(msg.structuredDisplayContent, capForRole(msg, budget: budget))
    }

    static func capForRole(_ message: Renderable, budget: Budget) -> Int {
        // Receipt identifiers and the recovery pointer must survive intact.
        if message.isTool { return message.content.count }
        // Compaction summaries use their own cap.
        if message.isCompactionSummary { return budget.compactionSummaryCap }
        switch message.role {
        case "user": return budget.userCap
        // Her own words reach her whole; the history window drops whole rows, never part of one.
        case "assistant": return .max
        case "system", "summary": return budget.systemCap
        default: return 900
        }
    }

    /// Compaction still reads bounded result evidence before distilling it.
    static func toolSummary(
        content: String,
        metadata: [String: JSONValue]?,
        resultCap: Int? = nil
    ) -> String {
        let recordedStatus = ChatTranscriptEvidenceRendering.recordedToolStatus(metadata)
        let normalizedContent = normalize(content)
        if !normalizedContent.isEmpty {
            return recordedStatus.map { "\($0): \(normalizedContent)" } ?? normalizedContent
        }
        let name = metadata?["toolName"]?.stringValue ?? metadata?["tool_name"]?.stringValue ?? "tool"
        let ok: String = {
            if case .bool(let value)? = metadata?["ok"] { return value ? "ok" : "failed" }
            return "ran"
        }()
        let toolStatus = recordedStatus.map { "\($0): \(name)" } ?? "\(name) \(ok)"
        // Skill reads retain the name for continuity; the body is available on demand.
        if name == "read_skill" {
            let skillName = Self.readSkillName(fromInputJSON: metadata?["inputJSON"]?.stringValue)
            return skillName.isEmpty
                ? toolStatus
                : "\(toolStatus): \(skillName) (body elided — re-read if needed)"
        }
        // Project the unwrapped, redacted `resultBody` under the ordinary tool-result bound.
        let rawResult = metadata?["resultBody"]?.stringValue
            ?? metadata?["resultSummary"]?.stringValue ?? ""
        let result = resultCap.map { String(normalize(rawResult).prefix($0)) }
            ?? toolEvidenceProjection(rawResult)
        if result.isEmpty {
            return toolStatus
        }
        return "\(toolStatus): \(result)"
    }

    /// Her world as her recent turns here left it: each turn's closing record
    /// of what changed on disk (`ChatWrittenFileArtifacts.world`), the newest
    /// word on each file first. Read as each turn closed, not now.
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
        return "What your recent turns here changed in your world, newest first (files modified in the folders your writes landed in, read as each turn closed):\n"
            + lines.joined(separator: "\n")
    }

    // The memory promoter's fact evidence retains its existing head/tail view.
    /// Characters of the ORIGINAL kept from the head of a prior-turn tool result.
    static let toolResultHeadChars = 110
    /// Characters of the ORIGINAL kept from the tail. Tool FAILURES put the
    /// lines that matter (compiler errors, "N tests failed", exit status) at the
    /// END — the old head-only `cap(result, 180)` dropped every one of them and
    /// left a bare "..." that did not even say something had been cut.
    static let toolResultTailChars = 50
    /// Bound on how much raw text is normalized/redacted per end. Legacy
    /// 50–60 KB tool_catalog receipts must not be rescanned in full to produce
    /// a ~180-char preview.
    private static let toolResultRedactionWindow = 512

    /// Head+tail-preserving projection of a prior-turn tool result, mirroring
    /// the in-turn reference implementations (`ProviderToolResultPage`
    /// preview_head/preview_tail and `SubprocessSupport.headTailPreserve`):
    /// both ends survive and the elision is stated explicitly with a character
    /// count instead of a bare "...". Short results pass through untouched.
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

    /// Pull the `name` argument out of a persisted read_skill inputJSON blob.
    static func readSkillName(fromInputJSON raw: String?) -> String {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String
        else { return "" }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Preserve indentation and fenced code in already bounded, redacted text.
    private static func normalizePreservingStructure(_ text: String) -> String {
        let redacted = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var out: [String] = []
        var blankRun = false
        var fence: (marker: Character, count: Int)?
        for rawLine in redacted.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                out.append(String(rawLine))
                let markers = trimmed.prefix { $0 == active.marker }
                if markers.count >= active.count,
                   trimmed.dropFirst(markers.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if count >= 3 {
                    if blankRun { out.append(""); blankRun = false }
                    fence = (marker, count)
                    out.append(String(rawLine))
                    continue
                }
            }
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
            let body = rawLine
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            if body.isEmpty {
                if !out.isEmpty { blankRun = true }
                continue
            }
            if blankRun {
                out.append("")
                blankRun = false
            }
            out.append(String(indent) + body)
        }
        return out.joined(separator: "\n")
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

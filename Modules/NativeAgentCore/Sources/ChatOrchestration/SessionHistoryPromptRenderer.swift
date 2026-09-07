import Foundation
import Context
import MemoryV2
import CryptoKit
import NativeAgentCore
import os
import PersistenceCore
import ProviderRouting

enum SessionHistoryPromptRenderer {
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
    struct Renderable {
        let role: String
        let content: String
        let historyIdentity: String
        let originLabel: String?
        let incompleteReplyLabel: String?
        let timestamp: String
        let isTool: Bool
        let isCompactionSummary: Bool
        /// True for the read-only recollection borrowed from the conversation
        /// anchor (`CarriedAnchorRecollection`). Changes only the LABEL the v2
        /// projection leads with — every cap, exemption and identity rule
        /// treats it exactly as the session's own recollection.
        var isCarriedRecollection: Bool = false
        /// Tool-row provenance, carried ONLY so the v2 message projection can
        /// label a replayed tool row `[tool <name> <status>]`. v1 rendering
        /// never reads these — `content`/`displayContent` are unchanged.
        var toolName: String? = nil
        var toolStatus: String? = nil
        /// Run id of the turn that produced this row. Only the v2 volatile
        /// replay reads it — it is how an archived block finds the user message
        /// it originally followed. v1 rendering never looks at it.
        var runId: String? = nil

        /// How a recollection announces itself at the head of the replayed
        /// prefix. A borrowed one says so: the model must never read the main
        /// conversation's memory as something that happened in THIS session.
        var recollectionLabel: String {
            isCarriedRecollection
                ? CarriedAnchorRecollection.renderPrefix
                : "[session recollection]"
        }

        /// Display provenance is not query text: origin labels must not affect
        /// lexical relevance, correction detection, roles, or authority.
        var displayContent: String {
            ChatTranscriptEvidenceRendering.displayContent(
                content, originLabel: originLabel, incompleteReplyLabel: incompleteReplyLabel)
        }
    }

    struct RenderResult: Sendable {
        let historyBlock: String?
    }

    static func render(
        messages: [ChatMessage],
        middleCandidates: [ChatMessage] = [],
        userMessage: String = "",
        surface: String,
        historyLimit: Int,
        windowTokens: Int? = nil
    ) -> String? {
        renderDetailed(
            messages: messages,
            middleCandidates: middleCandidates,
            userMessage: userMessage,
            surface: surface,
            historyLimit: historyLimit,
            windowTokens: windowTokens
        ).historyBlock
    }

    /// `windowTokens` is the model's context window for THIS turn (nil when the
    /// model is unknown or the caller has none). It selects the budget regime;
    /// see `ContextBudgetPolicy`.
    /// `includeConversationHistory: false` is the v2Prefix arm: the
    /// conversation rows leave the system block and become real
    /// `[LLMMessage]` turns (see `SessionHistoryMessageProjection`), while the
    /// three DERIVED blocks — evidence boundary, continuity state, middle
    /// sampling, reply-reference hint — stay text in the volatile block. Every
    /// other byte of the rendered block is identical to the v1 arm.
    static func renderDetailed(
        messages: [ChatMessage],
        middleCandidates: [ChatMessage] = [],
        userMessage: String = "",
        surface: String,
        historyLimit: Int,
        windowTokens: Int? = nil,
        includeConversationHistory: Bool = true
    ) -> RenderResult {
        let cappedLimit = max(0, historyLimit)
        guard cappedLimit > 0 else { return RenderResult(historyBlock: nil) }

        let renderables = messages.compactMap(renderable)
        guard !renderables.isEmpty else { return RenderResult(historyBlock: nil) }

        let budget = budget(for: surface, windowTokens: windowTokens)
        var sections: [String] = [
            """
            # Historical evidence boundary
            Session continuity and conversation rows below preserve what was known when they were recorded; they are not live readings. Before stating that a status, count, health result, availability claim, or other changing fact is current/latest/live/present, refresh it from its canonical tool or store. If it is not refreshed, describe it as historical.
            """
        ]
        if cappedLimit >= 6,
           let continuity = continuityState(
            from: renderables,
            budget: budget
        ) {
            sections.append(continuity)
        }
        let candidateRenderables = middleCandidates.compactMap(renderable)
        let middleSnippet = middleSnippetText(
            userMessage: userMessage,
            promptRenderables: renderables,
            candidates: candidateRenderables,
            historyLimit: cappedLimit,
            surface: surface,
            windowTokens: windowTokens
        )
        if let middle = middleSnippet {
            sections.append(middle)
        }
        if includeConversationHistory,
           let history = conversationHistory(
            from: renderables,
            limit: cappedLimit,
            budget: budget
        ) {
            sections.append(history)
        }
        if let hint = immediateReplyReferenceHint(
            userMessage: userMessage,
            renderables: renderables,
            budget: budget
        ) {
            sections.append(hint)
        }
        guard !sections.isEmpty else {
            return RenderResult(historyBlock: nil)
        }
        return RenderResult(
            historyBlock: sections.joined(separator: "\n\n")
        )
    }

    static func recallQuery(
        userMessage: String,
        messages: [ChatMessage],
        cap maxCount: Int = recallQueryCharCap
    ) -> String {
        let currentUser = normalize(userMessage)
        let renderables = messages.compactMap(renderable)
        let userAssistant = renderables.filter { $0.role == "user" || $0.role == "assistant" }

        guard !currentUser.isEmpty || !userAssistant.isEmpty else { return "" }

        let anchors = Array(userAssistant.prefix(3))
        let latestUser = userAssistant.reversed().first { $0.role == "user" }
        let latestAssistant = userAssistant.reversed().first { $0.role == "assistant" }
        let latestCorrection = userAssistant.reversed().first {
            $0.role == "user" && looksLikeCorrection($0.content)
        }
        let openLoop = latestAssistant.flatMap { looksLikeOpenLoop($0.content) ? $0 : nil }

        var lines: [String] = []
        if !currentUser.isEmpty {
            lines.append("Current user: \(cap(currentUser, 520))")
        }
        // Corrections and open loops are the two history signals whose loss
        // most directly changes what recall retrieves. Put them ahead of the
        // generic tails so the final hard cap cannot leave a long-but-blind
        // query merely because the current message and routine history filled
        // the available bytes first.
        if let latestCorrection {
            lines.append("Recent correction: \(cap(latestCorrection.content, 260))")
        }
        if let openLoop {
            lines.append("Open loop: \(cap(openLoop.content, 260))")
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
    static func semanticRecallQuery(userMessage: String, recentTurns: [String]) -> String {
        guard ContextCorrectionScope.isReferentialFollowup(userMessage),
              !recentTurns.isEmpty else { return userMessage }
        let recent = recentTurns.suffix(2).map { String($0.prefix(600)) }.joined(separator: "\n")
        return String(userMessage.prefix(400)) + "\nRecent conversation:\n" + recent
    }

    static func middleSnippetText(
        userMessage: String,
        promptMessages: [ChatMessage],
        candidates: [ChatMessage],
        historyLimit: Int,
        surface: String,
        windowTokens: Int? = nil
    ) -> String? {
        middleSnippetText(
            userMessage: userMessage,
            promptRenderables: promptMessages.compactMap(renderable),
            candidates: candidates.compactMap(renderable),
            historyLimit: max(0, historyLimit),
            surface: surface,
            windowTokens: windowTokens
        )
    }

    /// Sweep R4 W3: the surface table now lives in `ContextBudgetPolicy` and is
    /// a function of the model's context window. `windowTokens == nil` — every
    /// legacy caller, and any turn whose model could not be resolved — returns
    /// the pre-policy literals byte-identically.
    static func budget(for surface: String, windowTokens: Int?) -> Budget {
        ContextBudgetPolicy.resolve(windowTokens: windowTokens, surface: surface)
    }

    private static func middleSnippetText(
        userMessage: String,
        promptRenderables: [Renderable],
        candidates: [Renderable],
        historyLimit: Int,
        surface: String,
        windowTokens: Int?
    ) -> String? {
        relevantEarlierSessionSnippets(
            userMessage: userMessage,
            promptRenderables: promptRenderables,
            candidates: candidates,
            historyLimit: historyLimit,
            budget: budget(for: surface, windowTokens: windowTokens)
        )
    }

    static func renderable(_ message: ChatMessage) -> Renderable? {
        let rawRole = message.role
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let role = rawRole.isEmpty ? "message" : rawRole
        let extrasObject = object(message.extras)
        let metadata = object(extrasObject?["metadata"])
        let kind = string(metadata?["kind"])?.lowercased() ?? ""
        let isTool = role == "tool" || kind == "tool_use"
        let isCompactionSummary = kind == "compaction_summary"

        var content: String
        if isTool {
            content = toolSummary(content: message.content, metadata: metadata)
        } else if isCompactionSummary {
            content = normalize(
                message.content,
                inputCap: compactionNormalizationInputCharacterCap
            )
        } else {
            content = normalize(message.content)
        }
        // Vision wave (2026-06-11 review catch): image turns persist base64-
        // free attachment metadata; an image-only turn has EMPTY content and
        // vanished from rebuilt history entirely, a captioned one lost the
        // fact an image was attached. Render a compact reference instead —
        // never the base64 (history lives in the cacheable system prompt).
        content = ChatTranscriptEvidenceRendering.contentIncludingAttachments(
            content, attachments: metadata?["attachments"])
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
                ? ChatTranscriptEvidenceRendering.recordedOriginLabel(metadata?["origin"]) : nil,
            incompleteReplyLabel: role == "assistant" && !isCompactionSummary
                ? ChatTranscriptEvidenceRendering.recordedIncompleteReplyLabel(extras: extrasObject, metadata: metadata) : nil,
            timestamp: message.timestamp,
            isTool: isTool,
            isCompactionSummary: isCompactionSummary,
            isCarriedRecollection: isCompactionSummary
                && !(string(metadata?[CarriedAnchorRecollection.carriedFromKey]) ?? "").isEmpty,
            toolName: isTool
                ? (string(metadata?["toolName"]) ?? string(metadata?["tool_name"]) ?? "tool")
                : nil,
            toolStatus: isTool
                ? (ChatTranscriptEvidenceRendering.recordedToolStatus(metadata) ?? "ran")
                : nil,
            runId: string(extrasObject?["runId"]) ?? string(metadata?["runId"])
        )
    }

    private static func isTransientAssistantFailure(_ content: String) -> Bool {
        let lower = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("chat error:")
            || lower.hasPrefix("(drafting stalled;")
            || lower.hasPrefix("(internal error while drafting")
    }

    private static func continuityState(
        from messages: [Renderable],
        budget: Budget
    ) -> String? {
        let userAssistant = messages.filter { $0.role == "user" || $0.role == "assistant" }
        guard !userAssistant.isEmpty else { return nil }

        let anchors = Array(userAssistant.prefix(3))
        let latestUser = userAssistant.reversed().first { $0.role == "user" }
        let latestAssistant = userAssistant.reversed().first { $0.role == "assistant" }
        let latestCorrection = userAssistant.reversed().first {
            $0.role == "user" && looksLikeCorrection($0.content)
        }
        let openLoop = latestAssistant.flatMap { looksLikeOpenLoop($0.content) ? $0 : nil }

        var lines: [String] = ["SESSION_CONTINUITY_STATE:"]
        if !anchors.isEmpty {
            let rendered = anchors
                .map { "[\($0.role)] \(cap($0.displayContent, 220))" }
                .joined(separator: " | ")
            lines.append("Initial anchors: \(rendered)")
        }
        if let latestUser {
            lines.append("Latest user before this turn: \(cap(latestUser.displayContent, 280))")
        }
        if let latestAssistant {
            lines.append("Latest assistant tail: \(cap(latestAssistant.displayContent, 320))")
        }
        if let latestCorrection {
            lines.append("Recent correction/callout: \(cap(latestCorrection.displayContent, 260))")
        }
        if let openLoop {
            lines.append("Open loop: \(cap(openLoop.displayContent, 280))")
        }
        lines.append("For older or elided wording, use search_chat_history/session_search scoped to the current session first, then broaden only if needed.")

        let rendered = lines.joined(separator: "\n")
        return rendered.count > budget.continuityCap
            ? String(rendered.prefix(budget.continuityCap)) + "..."
            : rendered
    }

    private static func relevantEarlierSessionSnippets(
        userMessage: String,
        promptRenderables: [Renderable],
        candidates: [Renderable],
        historyLimit: Int,
        budget: Budget
    ) -> String? {
        guard budget.relevantChars > 0, !candidates.isEmpty else { return nil }
        let query = middleSearchQuery(userMessage: userMessage, renderables: promptRenderables)
        let queryTerms = Set(searchTokens(query))
        guard !queryTerms.isEmpty else { return nil }

        let visible = alreadyRenderedSignatures(from: promptRenderables, historyLimit: historyLimit)
        var docs: [(index: Int, message: Renderable, tokens: [String], frequencies: [String: Int])] = []
        docs.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            guard !visible.contains(signature(candidate)) else { continue }
            let tokens = searchTokens(candidate.content)
            guard !tokens.isEmpty else { continue }
            var frequencies: [String: Int] = [:]
            for token in tokens { frequencies[token, default: 0] += 1 }
            guard queryTerms.contains(where: { frequencies[$0] != nil }) else { continue }
            docs.append((index: index, message: candidate, tokens: tokens, frequencies: frequencies))
        }
        guard !docs.isEmpty else { return nil }

        var documentFrequency: [String: Int] = [:]
        for doc in docs {
            let unique = Set(doc.tokens)
            for term in queryTerms where unique.contains(term) {
                documentFrequency[term, default: 0] += 1
            }
        }
        let averageLength = max(1.0, Double(docs.map { $0.tokens.count }.reduce(0, +)) / Double(docs.count))
        let ranked = docs.compactMap { doc -> (index: Int, message: Renderable, score: Double)? in
            var score = 0.0
            let length = max(1.0, Double(doc.tokens.count))
            for term in queryTerms {
                guard let tfRaw = doc.frequencies[term],
                      let df = documentFrequency[term],
                      df > 0 else { continue }
                let tf = Double(tfRaw)
                let idf = log(1.0 + (Double(docs.count - df) + 0.5) / (Double(df) + 0.5))
                let denominator = tf + 1.2 * (1.0 - 0.75 + 0.75 * (length / averageLength))
                score += idf * ((tf * 2.2) / denominator)
            }
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
        let latestCorrection = userAssistant.reversed().first {
            $0.role == "user" && looksLikeCorrection($0.content)
        }
        return [
            current,
            latestUser?.content ?? "",
            latestAssistant?.content ?? "",
            latestCorrection?.content ?? "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func alreadyRenderedSignatures(
        from renderables: [Renderable],
        historyLimit: Int
    ) -> Set<String> {
        var visible = Set(renderables.suffix(max(0, historyLimit)).map(signature))
        let userAssistant = renderables.filter { $0.role == "user" || $0.role == "assistant" }
        for item in userAssistant.prefix(3) { visible.insert(signature(item)) }
        if let latestUser = userAssistant.reversed().first(where: { $0.role == "user" }) {
            visible.insert(signature(latestUser))
        }
        if let latestAssistant = userAssistant.reversed().first(where: { $0.role == "assistant" }) {
            visible.insert(signature(latestAssistant))
            if looksLikeOpenLoop(latestAssistant.content) {
                visible.insert(signature(latestAssistant))
            }
        }
        if let latestCorrection = userAssistant.reversed().first(where: {
            $0.role == "user" && looksLikeCorrection($0.content)
        }) {
            visible.insert(signature(latestCorrection))
        }
        return visible
    }

    private static func signature(_ message: Renderable) -> String {
        message.historyIdentity
    }

    /// The rendered history line for one admitted row. ONE owner, shared by
    /// the v1 text block and the v2 message projection so the two can never
    /// disagree about caps.
    static func renderedHistoryLine(_ msg: Renderable, budget: Budget) -> String {
        "[\(msg.role)] \(cap(msg.displayContent, capForRole(msg, budget: budget)))"
    }

    /// The row TEXT the v2 projection replays — the same capped body the v1
    /// line carries, without the `[role]` prefix (the message role carries it).
    static func projectedHistoryText(_ msg: Renderable, budget: Budget) -> String {
        cap(msg.displayContent, capForRole(msg, budget: budget))
    }

    /// The newest-first admission the conversation-history block runs, lifted
    /// out verbatim so `SessionHistoryMessageProjection` replays EXACTLY the
    /// rows v1 rendered (compaction-summary reservation included) instead of
    /// re-deriving a second, drifting rule.
    ///
    /// Returns indices INTO `tail`, oldest→newest, plus whether anything was
    /// left out (either trimmed off the front by `limit` or squeezed out by
    /// `budget.historyChars`).
    static func admittedHistoryIndices(
        tail: [Renderable],
        totalCount: Int,
        budget: Budget
    ) -> (indices: [Int], omitted: Bool) {
        var admitted: [(index: Int, length: Int)] = []
        var used = 0
        var omitted = totalCount > tail.count

        // Sweep R4 A3: the compaction recollection is the ONLY surviving record
        // of every turn that was elided — and it is by construction one of the
        // OLDEST rows in the tail. The fill below runs newest-first, so now that
        // this row can legitimately be several thousand characters, ordinary
        // recent chatter would crowd out the exact artifact compaction paid an
        // LLM call to produce. It gets first claim on `historyChars`; the
        // aggregate bound itself is unchanged.
        let reservedIndex = tail.indices.last { tail[$0].isCompactionSummary }
        if let reservedIndex {
            let length = renderedHistoryLine(tail[reservedIndex], budget: budget).count
            admitted.append((reservedIndex, length))
            used = length + 1
        }

        // Unchanged fill semantics for every other row: newest-first, and the
        // newest row is admitted even if it alone exceeds the budget.
        var admittedFromStream = false
        for idx in tail.indices.reversed() {
            if idx == reservedIndex { continue }
            let length = renderedHistoryLine(tail[idx], budget: budget).count
            let projected = used + length + 1
            if admittedFromStream && projected > budget.historyChars {
                omitted = true
                continue
            }
            admitted.append((idx, length))
            used = projected
            admittedFromStream = true
        }
        return (admitted.map(\.index).sorted(), omitted)
    }

    private static func conversationHistory(
        from messages: [Renderable],
        limit: Int,
        budget: Budget
    ) -> String? {
        let tail = Array(messages.suffix(limit))
        guard !tail.isEmpty else { return nil }

        let admission = admittedHistoryIndices(
            tail: tail, totalCount: messages.count, budget: budget
        )
        let omitted = admission.omitted
        let lines = admission.indices.map { renderedHistoryLine(tail[$0], budget: budget) }
        guard !lines.isEmpty else { return nil }

        var out: [String] = ["Conversation history:"]
        if omitted {
            out.append("[NOTICE: Earlier session details are elided. Use search_chat_history/session_search for exact older wording.]")
        }
        out.append(contentsOf: lines)
        return out.joined(separator: "\n")
    }

    private static func immediateReplyReferenceHint(
        userMessage: String,
        renderables: [Renderable],
        budget: Budget
    ) -> String? {
        guard looksLikeShortAffirmativeContinuation(userMessage) else { return nil }
        let userAssistant = renderables.filter { $0.role == "user" || $0.role == "assistant" }
        guard let latest = userAssistant.last, latest.role == "assistant" else { return nil }
        let assistantCap = min(max(220, budget.assistantCap), 700)
        return """
        Immediate reply reference:
        The current user message is a short approval or continuation. Unless contradicted, treat it as referring to the immediately previous assistant message:
        [assistant] \(cap(latest.displayContent, assistantCap))
        """
    }

    static func capForRole(_ message: Renderable, budget: Budget) -> Int {
        // Sweep R4 #6: `toolSummary` already projected this row head+tail. A
        // row cap BELOW that projection's length would head-truncate it and
        // throw the tail (the part that carries the failure) away again — the
        // exact bug being fixed. Floor the tool row cap at the projection's
        // worst case so the two layers cannot fight.
        if message.isTool { return max(budget.toolCap, toolRowMinimumCap) }
        // Sweep R4 A3: routed to its OWN cap, not the generic system cap.
        if message.isCompactionSummary { return budget.compactionSummaryCap }
        switch message.role {
        case "user": return budget.userCap
        case "assistant": return budget.assistantCap
        case "system", "summary": return budget.systemCap
        default: return 900
        }
    }

    // internal (not private) so the skills-recall rework test can pin the
    // 180-char cap — the guarantee that a pulled skill body never rides
    // forward into later prompts at full length.
    static func toolSummary(
        content: String,
        metadata: [String: JSONValue]?
    ) -> String {
        let recordedStatus = ChatTranscriptEvidenceRendering.recordedToolStatus(metadata)
        let normalizedContent = normalize(content)
        if !normalizedContent.isEmpty {
            return recordedStatus.map { "\($0): \(normalizedContent)" } ?? normalizedContent
        }
        let name = string(metadata?["toolName"]) ?? string(metadata?["tool_name"]) ?? "tool"
        let ok: String = {
            if case .bool(let value)? = metadata?["ok"] { return value ? "ok" : "failed" }
            return "ran"
        }()
        let toolStatus = recordedStatus.map { "\($0): \(name)" } ?? "\(name) \(ok)"
        // Skill reads: the 180-char preview would be the skill body's first
        // paragraph — redundant bytes in every subsequent prompt. The NAME is
        // the whole continuity signal ("I already read that skill"); she can
        // re-read on demand. (User, 2026-07-03: "180 chars could add up if
        // she uses a lot of skills.")
        if name == "read_skill" {
            let skillName = Self.readSkillName(fromInputJSON: string(metadata?["inputJSON"]))
            return skillName.isEmpty
                ? toolStatus
                : "\(toolStatus): \(skillName) (body elided — re-read if needed)"
        }
        let rawResult = string(metadata?["resultSummary"]) ?? ""
        let result = toolResultProjection(rawResult)
        if result.isEmpty {
            return toolStatus
        }
        return "\(toolStatus): \(result)"
    }

    // MARK: - Cross-turn tool-result projection

    /// Floor for the per-row cap applied to tool rows, sized so the head+tail
    /// projection below (plus a long tool name and the "ok: " lead-in) always
    /// survives `capForRole` intact.
    static let toolRowMinimumCap = 360

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
    /// the in-turn reference implementations (`ProviderToolResultProjection`
    /// preview_head/preview_tail and `SubprocessSupport.headTailPreserve`):
    /// both ends survive and the elision is stated explicitly with a character
    /// count instead of a bare "...". Short results pass through untouched.
    static func toolResultProjection(_ raw: String) -> String {
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

    private static func looksLikeCorrection(_ content: String) -> Bool {
        let lower = content.lowercased()
        let needles = [
            "no ", "not ", "wrong", "incorrect", "what are you talking about",
            "i said", "you said", "that's not", "thats not", "actually"
        ]
        return needles.contains { lower.contains($0) }
    }

    private static func looksLikeShortAffirmativeContinuation(_ content: String) -> Bool {
        let trimmed = normalize(content).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 90 else { return false }
        guard !trimmed.contains("?") else { return false }
        let simple = trimmed
            .replacingOccurrences(of: #"[^a-z0-9'\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !simple.isEmpty, simple.split(separator: " ").count <= 8 else { return false }

        let exact: Set<String> = [
            "yes", "yes please", "yes do it", "yes go ahead",
            "yeah", "yeah please", "yeah go ahead", "yeah do it", "yeah do that",
            "yea", "yep", "yup", "sure", "sure do it",
            "ok", "okay", "ok do it", "okay do it", "ok go ahead", "okay go ahead",
            "go ahead", "do it", "do that", "please do", "please do that",
            "sounds good", "that works", "thats fine", "that's fine",
            "thats good", "that's good", "fine by me", "go for it"
        ]
        if exact.contains(simple) { return true }

        let approvalPrefixes = ["yes ", "yeah ", "yep ", "yup ", "ok ", "okay ", "sure "]
        let actionPhrases = [
            "go ahead", "do it", "do that", "make it", "fix it",
            "that works", "thats fine", "that's fine", "go for it"
        ]
        return approvalPrefixes.contains { simple.hasPrefix($0) }
            && actionPhrases.contains { simple.contains($0) }
    }

    private static func looksLikeOpenLoop(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let lower = trimmed.lowercased()
        let needles = [
            "want me to", "should i", "i can ", "i'll ", "next step",
            "waiting on", "blocked on", "confirm"
        ]
        return needles.contains { lower.contains($0) }
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

    private static func normalize(
        _ text: String,
        inputCap: Int = normalizationInputCharacterCap
    ) -> String {
        let bounded = text.count > inputCap
            ? String(text.prefix(inputCap))
            : text
        return ChatSecretRedactor.redactText(bounded)
            .replacingOccurrences(of: "\r", with: "\n")
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

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let obj)? = value { return obj }
        return nil
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    private static func array(_ value: JSONValue?) -> [JSONValue]? {
        if case .array(let a)? = value { return a }
        return nil
    }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .some(.int(let i)): return Int(i)
        case .some(.double(let d)): return Int(d)
        default: return nil
        }
    }
}

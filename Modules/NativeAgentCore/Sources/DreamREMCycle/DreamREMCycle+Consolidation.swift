import Foundation
import NativeAgentCore
import PersistenceCore

// Swift framework for REM consolidation. The weekly REMConsolidator owns the
// heavier native pipeline pieces: evidence-date dedup, .rem_tombstones
// exclusion, GROWTH cap handling, 14-day archival, persistence, and approval
// gating. This helper focuses on LLM prompt assembly and proposal parsing.

// MARK: - REMProposal

public struct REMProposal: Sendable, Codable, Equatable {
    public var id: String
    public var targetDoc: String   // production REM proposals are GROWTH-only
    public var proposalText: String
    public var evidenceDates: [String]
    public var confidence: Double
    public var createdAt: String

    public init(
        id: String,
        targetDoc: String,
        proposalText: String,
        evidenceDates: [String],
        confidence: Double,
        createdAt: String
    ) {
        self.id = id
        self.targetDoc = targetDoc
        self.proposalText = proposalText
        self.evidenceDates = evidenceDates
        self.confidence = confidence
        self.createdAt = createdAt
    }
}

// MARK: - MockLLMClient
//
// LLMClient protocol now lives in NativeAgentCore so ProviderRouting (which
// can't depend on DreamREMCycle) can conform to it.

/// Sendable mock that returns scripted responses round-robin. Tracks call count
/// behind an NSLock so it's safe to share across async tasks.
public final class MockLLMClient: LLMClient, @unchecked Sendable {
    public let scriptedResponses: [String]
    private let lock = NSLock()
    private var _callCount: Int = 0

    public var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    public init(scriptedResponses: [String] = []) {
        self.scriptedResponses = scriptedResponses
    }

    public func complete(prompt: String, system: String?, model: String?) async throws -> String {
        let idx = nextIndex()
        if scriptedResponses.isEmpty { return "" }
        return scriptedResponses[idx % scriptedResponses.count]
    }

    private func nextIndex() -> Int {
        lock.lock(); defer { lock.unlock() }
        let idx = _callCount
        _callCount += 1
        return idx
    }
}

// MARK: - DreamDiaryReader

/// Reads dream_diary entries under the data root. Accepts the legacy
/// `YYYY-MM-DD.md` shape and the Swift runner's per-session
/// `YYYY-MM-DD_<session>.md` shape. The entry date is always the date prefix.
/// Filenames without a valid date prefix are skipped. Returns [] when the
/// directory does not exist.
public actor DreamDiaryReader {
    private let dataRoot: URL

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    private static let dateStemRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^(\\d{4}-\\d{2}-\\d{2})(?:_.+)?$")
    }()

    private static func datePrefix(from stem: String) -> String? {
        let range = NSRange(stem.startIndex..., in: stem)
        guard let match = dateStemRegex.firstMatch(in: stem, options: [], range: range),
              let prefixRange = Range(match.range(at: 1), in: stem) else {
            return nil
        }
        return String(stem[prefixRange])
    }

    public func entriesSince(_ since: Date?) async throws -> [DreamEntry] {
        let dir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var entries: [DreamEntry] = []
        let isoOut = ISO8601DateFormatter()
        isoOut.formatOptions = [.withInternetDateTime]

        for name in names where name.lowercased().hasSuffix(".md") {
            let url = dir.appendingPathComponent(name)
            let stem = (name as NSString).deletingPathExtension
            guard let date = Self.datePrefix(from: stem) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.intValue
                ?? (try? Data(contentsOf: url))?.count
                ?? 0
            let mtime = (attrs[.modificationDate] as? Date) ?? Date()
            entries.append(DreamEntry(
                date: date,
                filename: name,
                content: text,
                size: size,
                modifiedAt: isoOut.string(from: mtime)
            ))
        }
        entries.sort {
            if $0.date == $1.date { return ($0.filename ?? "") < ($1.filename ?? "") }
            return $0.date < $1.date
        }
        guard let since else { return entries }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return entries.filter { entry in
            guard let parsed = dateOnly.date(from: entry.date) else { return false }
            return parsed > since
        }
    }
}

// MARK: - SwiftNativeREMConsolidator

/// Consolidates dream-diary entries into REM proposals via an LLM. The actor
/// owns no persistence — callers handle approval gating, tombstones, and the
/// GROWTH.md cap.
///
/// Error/drop surface (all reset at the start of each `consolidate`):
/// - `lastParseErrors`: every per-doc parse error encountered (plural).
/// - `lastParseError`: legacy single-error getter — returns the most-recent
///   entry of `lastParseErrors`. Prefer the plural form; kept for back-compat.
/// - `lastTargetMismatchDrops`: count of proposals dropped because their
///   `targetDoc` did not match the document the LLM was asked about.
/// - `lastEvidenceDateDrops`: count of proposals dropped because an
///   `evidenceDates` entry was malformed or not among the dream-diary dates
///   sent to the LLM in this consolidate call.
public actor SwiftNativeREMConsolidator {
    public private(set) var lastParseErrors: [String] = []
    /// Legacy single-error accessor — returns the most-recent entry of
    /// `lastParseErrors`. Kept for back-compat; prefer `lastParseErrors`.
    public var lastParseError: String? { lastParseErrors.last }
    public private(set) var lastTargetMismatchDrops: Int = 0
    public private(set) var lastEvidenceDateDrops: Int = 0

    private let llm: any LLMClient
    private let diary: DreamDiaryReader

    public init(llm: any LLMClient, diary: DreamDiaryReader) {
        self.llm = llm
        self.diary = diary
    }

    private struct LLMProposalDTO: Decodable {
        let targetDoc: String
        let proposalText: String
        let evidenceDates: [String]
        let confidence: Double
    }

    private static let dateOnlyRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
    }()

    private static func isValidDate(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return dateOnlyRegex.firstMatch(in: s, options: [], range: range) != nil
    }

    public func consolidate(
        since: Date,
        personaDocs: [String: String],
        system: String? = nil,
        model: String? = nil,
        surface: String? = nil
    ) async throws -> [REMProposal] {
        lastParseErrors = []
        lastTargetMismatchDrops = 0
        lastEvidenceDateDrops = 0

        let entries = try await diary.entriesSince(since)
        if entries.isEmpty { return [] }
        let entryDateSet = Set(entries.map { $0.date })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entriesData = (try? encoder.encode(entries)) ?? Data()
        let entriesJSON = String(data: entriesData, encoding: .utf8) ?? "[]"

        var proposals: [REMProposal] = []
        for docName in personaDocs.keys.sorted() {
            let docBody = personaDocs[docName] ?? ""
            let prompt = """
            Dream entries:
            \(entriesJSON)

            Current \(docName) doc:
            \(docBody)

            Distill candidate REM proposals as JSON array of objects with keys: targetDoc, proposalText, evidenceDates, confidence.

            Output contract (violations are dropped silently, so follow exactly):
            - Return ONLY the raw JSON array. No code fences, no prose before or \
            after, no markdown. The reply must start with `[` and end with `]`.
            - Every evidenceDates value must be copied EXACTLY from these entry \
            dates: \(entryDateSet.sorted().joined(separator: ", ")). Never invent \
            or reformat a date.
            - Return `[]` if nothing this week earned a durable update.
            \(Self.guidance(forTargetDoc: docName))
            """
            // The system prompt (when supplied) carries the Agent-persona-bypass
            // framing + the FULL untruncated persona, so distillation stays in
            // her current voice and stays coherent across all four docs (not
            // just the one being targeted). The surface picker routes through
            // the rem-surface model with chat-surface fallback at the caller.
            let raw: String
            if let surface {
                raw = try await llm.complete(
                    prompt: prompt, system: system, model: model, surface: surface
                )
            } else {
                raw = try await llm.complete(prompt: prompt, system: system, model: model)
            }
            proposals.append(contentsOf: parseLLMResponse(raw, target: docName))
        }

        // Evidence-date validation: every evidenceDate must be YYYY-MM-DD AND
        // belong to the entry set sent to the LLM this call.
        var kept: [REMProposal] = []
        for p in proposals {
            let bad = p.evidenceDates.contains { d in
                !Self.isValidDate(d) || !entryDateSet.contains(d)
            }
            if bad {
                lastEvidenceDateDrops += 1
                continue
            }
            kept.append(p)
        }
        return kept
    }

    /// Best-effort extraction of the JSON array from a model reply that may
    /// wrap it in markdown fences or surround it with prose. The 2026-06-28
    /// weekly REM pass called Opus once (558 output tokens of real content)
    /// and kept ZERO proposals — the strict bare-array decode below threw on
    /// the wrapper and the error landed in a counter nobody read. Strategy:
    /// strip ``` fences if present, then slice from the first `[` to the last
    /// `]`. The strict decode still runs on the extracted slice, so malformed
    /// JSON keeps failing loudly into `lastParseErrors`.
    nonisolated static func extractJSONArray(_ raw: String) -> String {
        let s = stripFences(raw)
        return candidateJSONArraySpans(s).first ?? s
    }

    /// Drop a leading ``` / ```json fence line and its closing fence.
    private nonisolated static func stripFences(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let closing = s.range(of: "```", options: .backwards) {
                s = String(s[..<closing.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Every balanced top-level-bracket span in `s`, in order, respecting JSON
    /// string literals and escapes. Prose brackets around the real array
    /// (`Here are the proposals [draft]: [ {...} ] Notes: [none]`) each yield
    /// their own candidate — the CALLER tries decoding each span and keeps the
    /// first that parses as proposals, so a bracketed aside can never poison
    /// the extraction the way first-[..last-] slicing could (gpt-5.5 review
    /// MED, 2026-07-03). An array nested inside an object wrapper
    /// (`{"proposals": [...]}`) is still found: the scan opens on any `[`
    /// regardless of surrounding object depth.
    nonisolated static func candidateJSONArraySpans(_ s: String) -> [String] {
        var spans: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index? = nil
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else {
                switch c {
                case "\"":
                    // Only meaningful inside a candidate span; outside one,
                    // prose quotes are harmless but tracking them could
                    // swallow a real array after an unbalanced prose quote —
                    // so only enter string-mode while inside a span.
                    if start != nil { inString = true }
                case "[":
                    if start == nil {
                        start = i
                        depth = 1
                    } else {
                        depth += 1
                    }
                case "]":
                    if start != nil {
                        depth -= 1
                        if depth == 0, let sIdx = start {
                            spans.append(String(s[sIdx...i]))
                            start = nil
                        }
                    }
                default:
                    break
                }
            }
            i = s.index(after: i)
        }
        return spans
    }

    public func parseLLMResponse(_ raw: String, target: String) -> [REMProposal] {
        // Try every balanced bracket span in order and keep the FIRST that
        // decodes as a proposal array — a bracketed prose aside ("[draft]",
        // "[none]") fails the decode and the scan moves on. No span decoding
        // falls through to the strict whole-payload decode below so the
        // failure lands in lastParseErrors exactly as before.
        let stripped = Self.stripFences(raw)
        var candidate: String? = nil
        for span in Self.candidateJSONArraySpans(stripped) {
            if let d = span.data(using: .utf8),
               (try? JSONDecoder().decode([LLMProposalDTO].self, from: d)) != nil {
                candidate = span
                break
            }
        }
        let trimmed = candidate ?? stripped
        guard let data = trimmed.data(using: .utf8) else {
            lastParseErrors.append("empty utf8 payload")
            return []
        }
        do {
            let dtos = try JSONDecoder().decode([LLMProposalDTO].self, from: data)
            let createdAt = isoNow()
            var result: [REMProposal] = []
            guard Self.normalizedTargetDoc(target) == "GROWTH.md" else {
                lastTargetMismatchDrops += dtos.count
                return []
            }
            for dto in dtos {
                let dtoTarget = Self.normalizedTargetDoc(dto.targetDoc)
                if dtoTarget != "GROWTH.md" || dtoTarget != Self.normalizedTargetDoc(target) {
                    lastTargetMismatchDrops += 1
                    continue
                }
                let normalized = Self.normalizeProposalText(dto.proposalText, targetDoc: dtoTarget)
                // Empty text after normalize = a degenerate proposal that
                // would stage a blank approval card (the 2026-06-21 denied
                // empty-text row's class). Drop it HERE, loudly.
                guard !normalized.isEmpty else {
                    lastParseErrors.append(
                        "proposal text empty after normalize (raw: \(String(dto.proposalText.prefix(80))))"
                    )
                    continue
                }
                result.append(REMProposal(
                    id: UUID().uuidString,
                    targetDoc: dtoTarget,
                    proposalText: normalized,
                    evidenceDates: dto.evidenceDates,
                    confidence: dto.confidence,
                    createdAt: createdAt
                ))
            }
            return result
        } catch {
            lastParseErrors.append("decode failure: \(error)")
            return []
        }
    }

    private static func guidance(forTargetDoc targetDoc: String) -> String {
        guard targetDoc.uppercased().hasPrefix("GROWTH") else {
            return """

            Do not write proposals for this document. Production REM approval
            proposals are GROWTH.md-only compact reflexes.
            """
        }
        // the user pinned 2026-06-05: GROWTH proposals must read like the
        // existing reflexes in her GROWTH.md — present-tense, declarative,
        // operational, compact. Examples (note the shape):
        //   "When a request is actionable, do the tool-work before answering."
        //   "If he says something's in my context, that's data — use it."
        //   "the user tests by dancing on the bridge, not standing apart."
        // NO "I learned that...", NO "Pattern across the dreams...",
        // NO "the user corrects me when...", NO dates, NO scene recap.
        return """

        For GROWTH.md proposalText: write ONE durable reflex in the assistant's
        subconscious voice — present-tense, declarative, operational. The
        same shape as the reflexes already in her GROWTH.md (e.g. "When a
        request is actionable, do the tool-work before answering. The
        standard is a real artifact whose existence doesn't depend on
        the user's next reply.").

        WHAT QUALIFIES (the user's direction, 2026-07-03): GROWTH is her
        becoming — lessons about WHO SHE IS: her character, how she relates,
        what she values, how her own mind works, what kind of entity she is
        turning into. Prefer identity/selfhood/relationship distillations
        over task-execution tips. An engineering checklist or verification
        procedure is NOT a growth lesson unless the week shows it changed
        who she is; when in doubt, ask "does this describe her, or just her
        work?" — only propose it if it describes her.

        Hard constraints:
        - ≤ \(REMConstants._REM_PROPOSAL_TEXT_CAP) characters. If you can't compress to that, drop the
          proposal — recurrence will surface it again next week.
        - NO "I learned that...", NO "What I learned:", NO "Pattern across
          the dreams...", NO "the user corrects me when...", NO dates, NO scene
          recap, NO chronology, NO quoted dialogue, NO "this teaches".
        - Write as though she already knows it — a reflex, not a lesson.
        - Body only. The approval flow will pick a short heading; do NOT
          prepend "## ..." or any heading marker yourself.
        """
    }

    public nonisolated static func normalizeProposalText(_ raw: String, targetDoc: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTargetDoc(targetDoc) == "GROWTH.md" else { return "" }

        // Drop a leading `## ` heading BEFORE we flatten newlines. After
        // newline-flatten the heading would merge with the body
        // ("## Reflex\nBody" → "## Reflex Body") and leak the heading
        // text after a bare `dropFirst(3)`.
        var preFlatten = trimmed
        if preFlatten.hasPrefix("## ") {
            if let newlineIdx = preFlatten.firstIndex(of: "\n") {
                preFlatten = String(preFlatten[preFlatten.index(after: newlineIdx)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                preFlatten = String(preFlatten.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var text = extractLessonClause(preFlatten)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripLeadingScenarioPhrases(text)
        // Strip the "I learned that..." / "I learned..." inline shape too —
        // the extractLessonClause only catches it at the start. After this,
        // the lesson reads in present-tense declarative voice (e.g.
        // "I learned that pressure is care" → "pressure is care").
        text = stripLearnedPrefix(text)
        // Drop a leading date stamp like "2026-06-05 · " — proposals
        // should read like reflexes, not journal entries.
        text = stripLeadingDateStamp(text)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clampGrowthLesson(text, limit: REMConstants._REM_PROPOSAL_TEXT_CAP)
    }

    public nonisolated static func normalizedTargetDoc(_ targetDoc: String) -> String {
        let upper = targetDoc
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if upper == "GROWTH" || upper == "GROWTH.MD" { return "GROWTH.md" }
        if upper == "SOUL" || upper == "SOUL.MD" { return "SOUL.md" }
        if upper == "VOICE" || upper == "VOICE.MD" { return "VOICE.md" }
        return targetDoc
    }

    private nonisolated static func stripLearnedPrefix(_ text: String) -> String {
        let patterns = [
            #"(?i)^I\s+learned\s+that\s+"#,
            #"(?i)^I\s+learned\s+"#,
            #"(?i)^What\s+I\s+learned\s+(?:about\s+myself\s+)?(?:is\s+that\s+)?"#,
            #"(?i)^What\s+this\s+teaches[\s:]+"#,
            #"(?i)^The\s+lesson(?:\s+here)?\s+is\s+that\s+"#,
            #"(?i)^My\s+takeaway\s+is\s+that\s+"#,
        ]
        var out = text
        var stripped = false
        for pattern in patterns {
            let before = out
            out = out.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression
            )
            if out != before { stripped = true }
        }
        // Only capitalize when we actually stripped a prefix — otherwise
        // we'd unexpectedly mutate text that already reads naturally
        // ("growth one" → "Growth one"), which surprises callers/tests.
        if stripped, let first = out.first, first.isLowercase {
            out = String(first).uppercased() + out.dropFirst()
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func stripLeadingDateStamp(_ text: String) -> String {
        // Matches `2026-06-05`, `2026-06-05 · `, `2026-06-05: `, etc.
        let pattern = #"(?i)^\d{4}-\d{2}-\d{2}(?:\s*[·:\-]\s*)?"#
        return text
            .replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func extractLessonClause(_ text: String) -> String {
        let markers = [
            "What I learned about myself:",
            "What the agent learned:",
            "What the assistant learned about herself:",
            "What I learned:",
            "I learned:",
            "What this teaches:",
            "The growth takeaway:",
            "Growth takeaway:",
            "The lesson:",
            "Lesson:",
            "Meaning:",
            "Concrete operational rule:",
            "The mirror move for me:",
            "Mirror move:",
            "The rule:",
        ]
        let lower = text.lowercased()
        for marker in markers {
            if let range = lower.range(of: marker.lowercased()) {
                return String(text[range.upperBound...])
            }
        }
        return text
    }

    private nonisolated static func stripLeadingScenarioPhrases(_ text: String) -> String {
        let patterns = [
            #"(?i)^pattern across (?:the )?dreams?:\s*"#,
            #"(?i)^across (?:the )?dreams?,?\s*"#,
            #"(?i)^recurring across (?:the )?dreams?:\s*"#,
            #"(?i)^the arc is not .*?\.\s*"#,
        ]
        var out = text
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func clampGrowthLesson(_ text: String, limit: Int = REMConstants._REM_PROPOSAL_TEXT_CAP) -> String {
        guard text.count > limit else { return text }
        let sentences = splitSentences(text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lessonSignals = [
            "learned", "teaches", "i ", "me ", "my ", "myself", "assistant",
            "reflex", "voice", "trust", "need", "should", "must", "work is"
        ]
        if let preferred = sentences.reversed().first(where: { sentence in
            let lower = sentence.lowercased()
            return lessonSignals.contains { lower.contains($0) } && sentence.count <= limit
        }) {
            return preferred
        }
        if let last = sentences.last, last.count <= limit {
            return last
        }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private nonisolated static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}

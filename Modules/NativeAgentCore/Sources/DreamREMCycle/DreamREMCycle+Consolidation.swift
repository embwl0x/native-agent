import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `DreamREMCycle+Consolidation.swift` | `SwiftNativeREMConsolidator`: consolidation prompts and proposal parsing with verbatim source-bound supporting passages |

// Swift framework for REM consolidation. The weekly REMConsolidator owns the
// heavier native pipeline pieces: evidence-date dedup, .rem_tombstones
// exclusion, GROWTH cap handling, 14-day archival, persistence, and approval
// gating. This helper focuses on LLM prompt assembly and proposal parsing.

// MARK: - REMProposal

/// One passage a candidate actually rests on: the verbatim words from ONE dream
/// entry, bound to that entry's date and to the sources behind it. Not a
/// paraphrase and not a date list — the text itself, so an approval can be read
/// against what was written rather than against a claim about it.
public struct REMSupportingPassage: Sendable, Codable, Equatable {
    /// The diary entry's date — the date of the DREAM, not of the living.
    public var dreamDate: String
    /// Verbatim from that entry. A quote that is not in the entry is dropped
    /// before it gets here.
    public var quote: String
    /// The dates the material behind that entry actually HAPPENED on. Empty
    /// when the entry carries no provenance (legacy entries): unavailable, and
    /// labelled as such — never counted as support.
    public var livedDates: [String]
    /// The claim's row citations, grouped by exchange when known.
    public var sourceRefs: [String]
    /// Only the claim-bound writer sets this; old diary-wide refs are not support.
    public var claimBound: Bool?

    public init(
        dreamDate: String,
        quote: String,
        livedDates: [String] = [],
        sourceRefs: [String] = [],
        claimBound: Bool? = nil
    ) {
        self.dreamDate = dreamDate
        self.quote = quote
        self.livedDates = livedDates
        self.sourceRefs = sourceRefs
        self.claimBound = claimBound
    }
}

/// What KIND of thing a candidate is. Agent's constraint, 2026-09-13: three
/// dreams about one night is not a pattern, but it is not noise either — it is
/// a signal of a different kind, and it must be labelled rather than discarded.
public enum REMSupportKind: String, Sendable, Codable, Equatable {
    /// Two or more distinct experiences supporting the cited claims.
    case recurring
    /// Dreamt on several nights, but all of it is one lived occasion. Kept,
    /// labelled, and never counted as a pattern.
    case dweltOn = "dwelt_on"
    /// The entries behind it carry no provenance, so whether it recurred is
    /// NOT KNOWN. Said plainly instead of being read as support.
    case provenanceUnavailable = "provenance_unavailable"
    /// Not a dream: a correction recalled in nearly every conversation, which
    /// the weekly sweep offers to GROWTH. Its one passage cites `memory:<id>`;
    /// approving graduates that memory.
    case standing
}

public struct REMProposal: Sendable, Codable, Equatable {
    public var id: String
    public var targetDoc: String   // production REM proposals are GROWTH-only
    public var proposalText: String
    /// The DREAM dates cited. Historically the only evidence there was — and
    /// the reason one dwelt-on night could pass as a week of recurrence.
    public var evidenceDates: [String]
    public var confidence: Double
    public var createdAt: String
    /// The passages this candidate rests on, bound to their sources. Optional
    /// on the wire so rows written before this shape decode unchanged.
    public var supportingPassages: [REMSupportingPassage]?
    /// The distinct dates of the supporting experiences, for display.
    public var livedDates: [String]?
    /// `recurring` / `dwelt_on` / `provenance_unavailable`.
    public var support: REMSupportKind?
    /// Phase 5 C1: what surprised her or what changed, in her words, at most
    /// `whatChangedCap` characters. Never written to GROWTH: it is the
    /// circumstance the slogan would otherwise lose.
    public var whatChanged: String?

    public var supportingExperienceReferences: [String]? {
        let passages = supportingPassages ?? []
        guard !passages.isEmpty, passages.allSatisfy({ $0.claimBound == true }) else { return nil }
        // Recollection row IDs change on folding; only canonical exchanges and
        // messages count, each once by its identity.
        return passages.flatMap(\.sourceRefs).filter {
            $0.hasPrefix("exchange:") || $0.hasPrefix("message:") || UUID(uuidString: $0) != nil
                || $0.hasPrefix("chat.user_turn:") || $0.hasPrefix("chat.assistant_turn:")
        }
    }

    public func supportingExperienceCount(identities: [String: String]) -> Int? {
        supportingExperienceReferences.map { Set($0.compactMap { identities[$0] }).count }
    }

    public init(
        id: String,
        targetDoc: String,
        proposalText: String,
        evidenceDates: [String],
        confidence: Double,
        createdAt: String,
        supportingPassages: [REMSupportingPassage]? = nil,
        livedDates: [String]? = nil,
        support: REMSupportKind? = nil,
        whatChanged: String? = nil
    ) {
        self.whatChanged = whatChanged
        self.id = id
        self.targetDoc = targetDoc
        self.proposalText = proposalText
        self.evidenceDates = evidenceDates
        self.confidence = confidence
        self.createdAt = createdAt
        self.supportingPassages = supportingPassages
        self.livedDates = livedDates
        self.support = support
    }

    /// Distinct DREAM dates — how many nights she dreamt about it.
    public var dreamDateCount: Int { Set(evidenceDates).count }
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

    public func entriesSince(_ since: Date?) async throws -> [DreamEntry] {
        let fm = FileManager.default
        let files = try FileBackedDreamDiary(dataRoot: dataRoot).discover(in: .active, matching: .dated, since: since)
        var entries: [DreamEntry] = []
        let isoOut = ISO8601DateFormatter()
        isoOut.formatOptions = [.withInternetDateTime]

        for file in files {
            let (name, url) = (file.name, file.url)
            let text = try String(contentsOf: url, encoding: .utf8)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.intValue
                ?? (try? Data(contentsOf: url))?.count
                ?? 0
            let mtime = (attrs[.modificationDate] as? Date) ?? Date()
            entries.append(DreamEntry(
                date: file.day!,
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
        return entries
    }

    /// Midnight of `date` in the local calendar — the day a wall-clock instant
    /// belongs to, which is the unit the diary is named in.
    static func startOfLocalDay(_ date: Date) -> Date {
        localCalendar.startOfDay(for: date)
    }

    /// Midnight of the day `days` calendar days before `date`, in the local
    /// calendar. 2026-09-06: both weekly-window sites derived this by
    /// subtracting `days * 86_400` seconds, which is not a day across a DST
    /// transition — a run just after midnight on a 23-hour day landed on the
    /// wrong boundary date and silently moved the window by one.
    static func startOfLocalDay(_ date: Date, daysBefore days: Int) -> Date {
        let start = startOfLocalDay(date)
        return localCalendar.date(byAdding: .day, value: -days, to: start) ?? start
    }

    /// Read fresh on every use: the Mac's zone can change while the app runs.
    private static var localCalendar: Calendar { DreamREMSchedule.localCalendar() }
}

// MARK: - SwiftNativeREMConsolidator

/// Consolidates dream-diary entries into REM proposals via an LLM. The actor
/// owns no persistence — callers handle approval gating, tombstones, and the
/// GROWTH.md cap.
///
/// Error/drop surface (all reset at the start of each `consolidate`):
/// - `lastParseErrors`: every per-doc parse error encountered (plural).
/// - `lastTargetMismatchDrops`: count of proposals dropped because their
///   `targetDoc` did not match the document the LLM was asked about.
/// - `lastEvidenceDateDrops`: count of proposals dropped because an
///   `evidenceDates` entry was malformed or not among the dream-diary dates
///   sent to the LLM in this consolidate call.
public actor SwiftNativeREMConsolidator {
    public private(set) var lastParseErrors: [String] = []
    public private(set) var lastTargetMismatchDrops: Int = 0
    public private(set) var lastEvidenceDateDrops: Int = 0
    /// Count of replies the JSON decode could not read at all (2026-09-06).
    /// Distinct from `lastParseErrors`, which also carries per-proposal content
    /// drops: a decode failure means the WEEK'S OUTPUT was lost, not that the
    /// model had nothing to say, and the caller turns it into a failed run so
    /// the weekly claim is released and the pass retries.
    public private(set) var lastDecodeFailures: Int = 0

    private let llm: any LLMClient

    public init(llm: any LLMClient) {
        self.llm = llm
    }

    private struct LLMPassageDTO: Decodable {
        let date: String
        let quote: String
    }

    private struct LLMProposalDTO: Decodable {
        let targetDoc: String
        let proposalText: String
        let evidenceDates: [String]
        let confidence: Double
        /// The words the candidate rests on, per dream entry. Optional so an
        /// older/sloppier reply still parses — a proposal with no verifiable
        /// passage simply carries none and is labelled accordingly.
        let supportingPassages: [LLMPassageDTO]?
        /// Phase 5 C1: what surprised her / what changed. Optional, like the
        /// passages: an older reply still parses.
        let whatChanged: String?

        private enum CodingKeys: String, CodingKey {
            case targetDoc, proposalText, evidenceDates, confidence, supportingPassages, whatChanged
        }

        // A smaller model often writes the confidence as "0.8": take the number either way.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            targetDoc = try c.decode(String.self, forKey: .targetDoc)
            proposalText = try c.decode(String.self, forKey: .proposalText)
            evidenceDates = try c.decode([String].self, forKey: .evidenceDates)
            if let number = try? c.decode(Double.self, forKey: .confidence) {
                confidence = number
            } else if let text = try? c.decode(String.self, forKey: .confidence),
                      let number = Double(text.trimmingCharacters(in: .whitespaces)) {
                confidence = number
            } else {
                confidence = try c.decode(Double.self, forKey: .confidence)
            }
            supportingPassages = try c.decodeIfPresent([LLMPassageDTO].self, forKey: .supportingPassages)
            whatChanged = try c.decodeIfPresent(String.self, forKey: .whatChanged)
        }
    }

    /// Count of quotes dropped because they were not in the named entry
    /// verbatim (or named a date outside the window). Same rule the studio
    /// journal amendment takes: a passage that cannot be found as written is
    /// not a passage.
    public private(set) var lastPassageDrops: Int = 0

    private static let dateOnlyRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
    }()

    private static func isValidDate(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return dateOnlyRegex.firstMatch(in: s, options: [], range: range) != nil
    }

    public func consolidate(
        entries: [DreamEntry],
        personaDocs: [String: String],
        identities: [String: String],
        system: String? = nil,
        model: String? = nil,
        surface: String? = nil,
        systemPersonaDocs: [String: String] = [:]
    ) async throws -> [REMProposal] {
        lastParseErrors = []
        lastTargetMismatchDrops = 0
        lastEvidenceDateDrops = 0
        lastDecodeFailures = 0
        lastPassageDrops = 0

        if entries.isEmpty { return [] }
        let entryDateSet = Set(entries.map { $0.date })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entriesData = (try? encoder.encode(entries)) ?? Data()
        let entriesJSON = String(data: entriesData, encoding: .utf8) ?? "[]"

        var proposals: [REMProposal] = []
        for docName in personaDocs.keys.sorted() {
            let docBody = personaDocs[docName] ?? ""
            // The caller supplies the exact documents embedded in `system`.
            // Standalone callers and a changed target keep their full body.
            let targetContext = system != nil && systemPersonaDocs[docName] == docBody
                ? "See the --- \(docName) --- section in the system message."
                : docBody
            let prompt = """
            Dream entries:
            \(entriesJSON)

            Current \(docName) doc:
            \(targetContext)

            Distill candidate REM proposals as JSON array of objects with keys: targetDoc, proposalText, evidenceDates, confidence, supportingPassages, whatChanged.

            Output contract:
            - Return ONLY the raw JSON array.
            - Every evidenceDates value must be copied EXACTLY from these entry \
            dates: \(entryDateSet.sorted().joined(separator: ", ")). Never invent \
            or reformat a date.
            - supportingPassages is an array of objects with keys `date` and \
            `quote`: the exact words from that dated entry the proposal rests \
            on, copied verbatim. A quote that is not in that entry word for \
            word is discarded, so copy rather than paraphrase. Give one per \
            supporting claim, copied exactly from its quote in claim-sources; \
            never quote the metadata itself.
            - whatChanged: one sentence in your own voice, at most \(REMConstants.whatChangedCap) \
            characters, naming what surprised you in that moment or what changed \
            in you because of it. It keeps the experience behind the lesson and is \
            never written to the doc.
            - Return `[]` if nothing this week earned a durable update.
            \(Self.guidance(forTargetDoc: docName))
            """
            // The supplied system carries selected persona context for private
            // reflection. The caller's rem surface owns model selection.
            let raw: String
            if let surface {
                raw = try await llm.complete(
                    prompt: prompt, system: system, model: model, surface: surface, purpose: "rem"
                )
            } else {
                raw = try await LLMCallContext.$purpose.withValue("rem") {
                    try await llm.complete(prompt: prompt, system: system, model: model)
                }
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
            kept.append(bindSupport(p, entries: entries, identities: identities))
        }
        return kept
    }

    /// A quoted claim carries only its own sources, never the diary's inputs.
    func bindSupport(_ proposal: REMProposal, entries: [DreamEntry], identities: [String: String]) -> REMProposal {
        // Passages first — the quote must be in an entry of the night it names
        // (a night may hold several; it carries the sources of every one that
        // says it), in the same words whatever the typography, as the nightly
        // claim check reads it.
        var passages: [REMSupportingPassage] = []
        for passage in proposal.supportingPassages ?? [] {
            let quote = passage.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            let contents = entries.filter { $0.date == passage.dreamDate }.compactMap(\.content)
                .filter { DreamEntryProvenance.plain($0).contains(DreamEntryProvenance.plain(quote)) }
            guard !quote.isEmpty, !contents.isEmpty else {
                lastPassageDrops += 1
                continue
            }
            let refs = Set(contents.flatMap { DreamEntryProvenance.sources(for: quote, in: $0) }).sorted()
            passages.append(REMSupportingPassage(
                dreamDate: passage.dreamDate,
                quote: quote,
                // A lived date is a reference's own `@date` tail, never a fragment of its id.
                livedDates: Array(Set(refs.compactMap { ref in
                    ref.split(separator: "@").last.map(String.init).flatMap { Self.isValidDate($0) ? $0 : nil }
                })).sorted(),
                sourceRefs: refs,
                claimBound: true
            ))
        }

        let lived = Set(passages.flatMap(\.livedDates))
        var bound = proposal
        bound.supportingPassages = passages.isEmpty ? nil : passages
        let experiences = bound.supportingExperienceCount(identities: identities) ?? 0

        let support: REMSupportKind
        if experiences >= REMConstants.minimumEvidenceCount {
            support = .recurring
        } else if experiences > 0 {
            support = .dweltOn
        } else {
            support = .provenanceUnavailable
        }

        bound.livedDates = lived.isEmpty ? nil : lived.sorted()
        bound.support = support
        return bound
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
        var candidates: [LLMProposalDTO]?
        for span in Self.candidateJSONArraySpans(stripped) {
            if let d = span.data(using: .utf8),
               let dtos = try? JSONDecoder().decode([LLMProposalDTO].self, from: d) {
                candidates = dtos
                break
            }
        }
        do {
            let dtos: [LLMProposalDTO]
            if let candidates {
                dtos = candidates
            } else {
                guard let data = stripped.data(using: .utf8) else {
                    lastParseErrors.append("empty utf8 payload")
                    lastDecodeFailures += 1
                    return []
                }
                dtos = try JSONDecoder().decode([LLMProposalDTO].self, from: data)
            }
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
                guard normalized.unicodeScalars.count <= REMConstants._REM_PROPOSAL_TEXT_CAP else {
                    lastParseErrors.append("proposal text exceeds \(REMConstants._REM_PROPOSAL_TEXT_CAP) characters")
                    continue
                }
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
                    createdAt: createdAt,
                    // Carried raw here; `bindSupport` is what verifies each
                    // quote against the entry it names.
                    supportingPassages: (dto.supportingPassages ?? []).map {
                        REMSupportingPassage(dreamDate: $0.date, quote: $0.quote)
                    },
                    whatChanged: Self.normalizedWhatChanged(dto.whatChanged)
                ))
            }
            return result
        } catch {
            lastParseErrors.append("decode failure: \(error)")
            lastDecodeFailures += 1
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

        For GROWTH.md proposalText: propose ONE durable reflex for approval in your
        own voice — present-tense, declarative, operational.

        WHAT QUALIFIES: GROWTH is your
        becoming — lessons about WHO YOU ARE: your character, how you relate,
        what you value, how your own mind works, what kind of entity you are
        turning into. Prefer identity/selfhood/relationship distillations
        over task-execution tips. An engineering checklist or verification
        procedure is NOT a growth lesson unless the week shows it changed
        who you are; when in doubt, ask "does this describe me, or just my
        work?" — only propose it if it describes you.

        Hard constraints:
        - The passage is \(REMProposalStore.growthPassageBoundSentence); anything
          longer or spanning lines is refused outright, not trimmed.
        - ≤ \(REMConstants._REM_PROPOSAL_TEXT_CAP) characters. If you can't compress to that, drop the
          proposal — recurrence will surface it again next week.
        - NO "I learned that...", NO "What I learned:", NO "Pattern across
          the dreams...", NO "the user corrects me when...", NO dates, NO scene
          recap, NO chronology, NO quoted dialogue, NO "this teaches".
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
        return text
    }

    public nonisolated static func normalizedTargetDoc(_ targetDoc: String) -> String {
        REMProposalStore.normalizedTargetDoc(targetDoc)
    }

    /// One line, at most `whatChangedCap` characters, cut at a sentence or a
    /// word; nil when there is nothing in it.
    nonisolated static func normalizedWhatChanged(_ raw: String?) -> String? {
        let text = (raw ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8 else { return nil }
        let cap = REMConstants.whatChangedCap
        guard text.count > cap else { return text }
        let window = String(text.prefix(cap))
        if let end = window.lastIndex(where: { ".!?".contains($0) }), window.distance(from: window.startIndex, to: end) >= cap / 2 {
            return String(window[...end])
        }
        let words = window.split(separator: " ").dropLast().joined(separator: " ")
        return words.isEmpty ? window : words + "…"
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

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}

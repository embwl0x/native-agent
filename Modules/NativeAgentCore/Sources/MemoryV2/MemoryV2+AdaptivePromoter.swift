import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - AdaptiveMemoryPromoter
//
// Swift port of the retired daemon — the realtime
// chat-fact promotion path. Observes user/assistant turns, extracts
// candidate durable facts, scores them, and (if score ≥ threshold and
// not tombstoned) stages them via SwiftNativeMemoryV2.propose(...).
//
// Phase A: rule-based extractor only (regex patterns over the user
// utterance — "my X is Y", "I work at Z", "my favorite W is V", etc.).
// Phase B will wire Apple Foundation Models (`import FoundationModels`)
// on macOS 26+ for LLM-driven extraction; the protocol shape is locked
// so the call site doesn't change.

public struct AdaptiveCandidate: Sendable, Equatable {
    public let content: String
    public let score: Double
    public let kind: String

    public init(content: String, score: Double, kind: String) {
        self.content = content
        self.score = score
        self.kind = kind
    }
}

public protocol AdaptiveFactExtractor: Sendable {
    func extract(userMessage: String, assistantMessage: String) async -> [AdaptiveCandidate]
}

public enum MemorySemanticExtractionStatus: String, Sendable {
    case unavailable, disabled, emptyInput, succeeded, failed, timedOut, unreported, skipped
}

/// Payload-free evidence, not a claim that an extracted candidate is true.
public struct AdaptiveExtractionReport: Sendable {
    public let candidates: [AdaptiveCandidate]
    public let semanticStatus: MemorySemanticExtractionStatus
    public let semanticCandidateCount: Int

    public init(candidates: [AdaptiveCandidate], semanticStatus: MemorySemanticExtractionStatus,
                semanticCandidateCount: Int = 0) {
        self.candidates = candidates
        self.semanticStatus = semanticStatus
        self.semanticCandidateCount = max(0, semanticCandidateCount)
    }
}

public protocol AdaptiveFactExtractionReporting: AdaptiveFactExtractor {
    func extractWithReport(userMessage: String, assistantMessage: String) async -> AdaptiveExtractionReport
}

public struct AdaptiveMemoryObservation: Sendable {
    public let proposals: [ProposalRecord]
    public let extraction: AdaptiveExtractionReport
    /// How many candidates this turn's TOOL EVIDENCE contributed, separate
    /// from the prose extractor's own report. `extraction` keeps describing
    /// the extractor and nothing else, so its `semanticStatus` stays honest.
    public let toolEvidenceCandidateCount: Int
    /// What the moment pass did this turn, one word, for the turn trace:
    /// disabled / noExtractor / capped / none / belowSalience / noQuote /
    /// gated / ungrounded / tombstoned / staged / failed; peer-seat turns
    /// never run the pass and report unreported. A moment that silently never stages is
    /// the drift this exists to make visible.
    public let momentOutcome: String
    /// Candidates the hygiene gate refused this turn (first person, about the
    /// assistant, assistant-sourced, ungrounded, run-on).
    public let hygieneRejectedCount: Int

    init(
        proposals: [ProposalRecord],
        extraction: AdaptiveExtractionReport,
        toolEvidenceCandidateCount: Int = 0,
        momentOutcome: String = "unreported",
        hygieneRejectedCount: Int = 0
    ) {
        self.proposals = proposals
        self.extraction = extraction
        self.toolEvidenceCandidateCount = max(0, toolEvidenceCandidateCount)
        self.momentOutcome = momentOutcome
        self.hygieneRejectedCount = max(0, hygieneRejectedCount)
    }
}

// MARK: - Tool evidence (sweep item 35)

/// What she DID in a turn, as already-projected lines.
///
/// The chat layer owns the projection: eligibility (only dispatches that
/// SUCCEEDED and carry a stable fact shape), the head+tail result shape
/// SessionHistory already renders for later turns, and secret redaction. This
/// type receives finished text and never sees a raw tool envelope, so MemoryV2
/// gains no dependency on the orchestration layer. The caps below are
/// re-asserted here anyway: a boundary that trusts its caller's bound is not
/// bounded.
///
/// NORTHSTAR clause 6: this adds NOTHING to her prompt. It only widens what
/// the after-turn promoter may PROPOSE, and every proposal it mints stays
/// pending for approval (see `scoreFloor` below).
public enum AdaptiveToolEvidence {
    /// At most this many evidence lines reach the promoter per turn.
    public static let maxLines = 6
    /// Per-line character ceiling.
    public static let maxLineChars = 240
    /// Shortest line worth proposing — below this there is no fact in it.
    static let minLineChars = 12
    /// Evidence candidates score ABOVE `defaultThreshold` (so they stage) and
    /// BELOW `defaultAutoAcceptThreshold` (so they never auto-accept). The
    /// `kind` below is also outside `shouldAutoAccept`'s allowlist, so the
    /// gate holds even if a caller lowers the auto-accept floor.
    public static let score = 0.65
    /// Kind stamped on every evidence proposal. Deliberately NOT one of the
    /// auto-acceptable kinds (identity/location/employment/schedule).
    public static let kind = "environment"
    /// User, 2026-09-02: a tool receipt is not a lasting fact. Every path-shaped
    /// dispatch was landing in Memory Proposals as
    /// "observed: go(name=/Users/…) ok: {…}" for a person to approve, and an
    /// approved one is junk in the store. The projection still feeds the
    /// procedural lane; it no longer mints proposals unless a caller opts in.
    nonisolated(unsafe) public static var proposalsEnabled = false

    /// Turn projected lines into promotion candidates. Bounded, de-duplicated,
    /// order-preserving. Empty input ⇒ empty output ⇒ prose-only behavior.
    public static func candidates(from lines: [String]) -> [AdaptiveCandidate] {
        guard !lines.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [AdaptiveCandidate] = []
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minLineChars else { continue }
            let bounded = trimmed.count > maxLineChars
                ? String(trimmed.prefix(maxLineChars))
                : trimmed
            let content = "observed: \(bounded)"
            guard seen.insert(content.lowercased()).inserted else { continue }
            out.append(AdaptiveCandidate(content: content, score: score, kind: kind))
            if out.count >= maxLines { break }
        }
        return out
    }
}

// MARK: - Candidate hygiene (User, 2026-09-02: "fixed, not avoided")

/// The one gate every extracted fact passes before it is staged, whatever
/// extractor produced it. Three live escapes drove it:
///   "user likes assistant's quirks and goofs cause I know its partly token
///   prediction"  — the user's sentence parroted, first person and all;
///   "user's personality is strongest when I demonstrate it with range…" —
///   HER sentence, re-attributed to the user;
///   "user likes assistant's quirks and goofs" — a feeling about the
///   assistant, which is relationship, not a fact about the user's life.
/// A lasting fact about the user is third person, about the user's own
/// world, and grounded in the user's words rather than the assistant's.
public enum AdaptiveCandidateHygiene {
    /// Names the assistant goes by, lowercased. The app adds the persona's
    /// display name at launch; "assistant" is always in.
    ///
    /// Written from MainActor (the app teaching the persona's name) and read
    /// from the memory pipeline off-main, so the set lives behind a lock and
    /// is only ever reached through `insertAssistantName` / `assistantNames`.
    private static let assistantNamesLock = NSLock()
    nonisolated(unsafe) private static var _assistantNames: Set<String> = ["assistant"]

    /// A locked snapshot; iterate this, never the storage.
    public static var assistantNames: Set<String> {
        assistantNamesLock.lock()
        defer { assistantNamesLock.unlock() }
        return _assistantNames
    }

    /// Teach hygiene one more name the assistant goes by.
    public static func insertAssistantName(_ name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        assistantNamesLock.lock()
        _assistantNames.insert(normalized)
        assistantNamesLock.unlock()
    }
    /// A fact is a clause, not a paragraph.
    public static let maxWords = 16

    private static let stopwords: Set<String> = [
        "user", "users", "user's", "the", "and", "that", "this", "with", "from", "into",
        "have", "has", "had", "was", "were", "been", "being", "are", "is", "its", "it's",
        "for", "not", "but", "they", "them", "their", "there", "when", "then", "than",
        "what", "which", "who", "how", "why", "about", "also", "just", "like", "likes",
        "very", "really", "some", "more", "most", "such", "over", "only", "still",
        "because", "cause", "does", "did", "will", "would", "could", "should",
    ]

    /// nil when the candidate may stage; otherwise one word saying why not.
    public static func rejectionReason(
        _ content: String,
        kind: String,
        userMessage: String,
        assistantMessage: String
    ) -> String? {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tool evidence is a projected receipt, not prose about the user.
        if kind == AdaptiveToolEvidence.kind { return nil }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        if words.count > maxWords { return "run-on" }
        // First person is quoted speech, whoever said it.
        if text.range(of: #"(?:^|[\s("'])(?:I|I'm|I’m|I've|I’ve|I'd|I’d|I'll|I’ll|me|my|mine|myself)(?=$|[\s.,;:!?)"'])"#,
                      options: .regularExpression) != nil {
            return "first-person"
        }
        // A feeling about the assistant is relationship, not a fact of the
        // user's life; the moments lane keeps those.
        let lowered = text.lowercased()
        for name in assistantNames where !name.isEmpty {
            if lowered.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"(?:'s|’s)?\b"#,
                             options: .regularExpression) != nil {
                return "about-assistant"
            }
        }
        if lowered.range(of: #"\byou(?:r|rs|'re|’re)?\b"#, options: .regularExpression) != nil {
            return "about-assistant"
        }
        // Grounding: the fact's content words must come from the user's own
        // words. If more of them come from the assistant's reply than from
        // the user's message, the extractor pulled from the wrong speaker.
        let content = contentStems(lowered)
        guard !content.isEmpty else { return nil }
        let userStems = contentStems(userMessage.lowercased())
        let assistantStems = contentStems(assistantMessage.lowercased())
        let inUser = content.filter { userStems.contains($0) }.count
        let inAssistantOnly = content.filter { assistantStems.contains($0) && !userStems.contains($0) }.count
        if inAssistantOnly > inUser { return "assistant-sourced" }
        if inUser < min(2, content.count) { return "ungrounded" }
        return nil
    }

    /// Lowercased word stems (letters, digits, apostrophes), stopwords out,
    /// short words out, common suffixes shaved so "works" grounds on "work".
    static func contentStems(_ text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }) {
            var word = String(raw).replacingOccurrences(of: "’", with: "'")
            if word.hasSuffix("'s") { word.removeLast(2) }
            guard word.count >= 4, !stopwords.contains(word) else { continue }
            for suffix in ["ing", "ies", "ed", "es", "s"] where word.count - suffix.count >= 4 && word.hasSuffix(suffix) {
                word.removeLast(suffix.count)
                break
            }
            out.insert(word)
        }
        return out
    }
}

/// Rule-based extractor. Matches a small set of high-precision patterns
/// over the *user* utterance — the assistant message is intentionally
/// ignored because models routinely echo facts that the user never
/// stated. Phase B will swap this for a Foundation Models classifier.
public struct RuleBasedFactExtractor: AdaptiveFactExtractor {
    public init() {}

    public func extract(userMessage: String, assistantMessage: String) async -> [AdaptiveCandidate] {
        let raw = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        // Normalise: collapse internal whitespace, strip trailing punctuation
        // so the regex anchors land cleanly on the last token of a value.
        let normalized = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        var out: [AdaptiveCandidate] = []
        var seen = Set<String>()

        func emit(_ content: String, score: Double, kind: String) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
            guard trimmed.count >= 3 else { return }
            let key = trimmed.lowercased()
            if seen.contains(key) { return }
            seen.insert(key)
            out.append(AdaptiveCandidate(content: trimmed, score: score, kind: kind))
        }

        // "my name is <Name>" — strongest signal.
        for m in Self.matches(normalized, pattern: #"\bmy name (?:is|'s)\s+([A-Z][A-Za-z'\-]{1,30}(?:\s+[A-Z][A-Za-z'\-]{1,30}){0,2})"#) {
            emit("user's name is \(m)", score: 0.95, kind: "identity")
        }
        // "I live in <place>"
        for m in Self.matches(normalized, pattern: #"\bI live (?:in|at)\s+([A-Z][A-Za-z'\-]{1,40}(?:[, ]+[A-Z][A-Za-z'\-]{1,40}){0,2})"#) {
            emit("user lives in \(m)", score: 0.85, kind: "location")
        }
        // "I work at <Company>" / "I work for <X>" / "I work as a <role>"
        for m in Self.matches(normalized, pattern: #"\bI work (?:at|for)\s+([A-Z][A-Za-z0-9'\-&]{1,40}(?:\s+[A-Z][A-Za-z0-9'\-&]{1,40}){0,2})"#) {
            emit("user works at \(m)", score: 0.85, kind: "employment")
        }
        for m in Self.matches(normalized, pattern: #"\bI work as (?:an?\s+)?([a-zA-Z][a-zA-Z\s\-]{2,\#(Self.valueCap)})"#) {
            emit("user works as \(m)", score: 0.80, kind: "employment")
        }
        // "my <attr> is <value>" — generic possessive pattern.
        for (attr, value) in Self.matchesPair(normalized, pattern: #"\bmy ([a-zA-Z][a-zA-Z\s\-]{1,30}?) (?:is|are|'s)\s+([A-Za-z0-9][A-Za-z0-9\s'\-]{1,\#(Self.valueCap)})"#) {
            let a = attr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Skip overly generic / pronouncey openers.
            if ["name"].contains(a) { continue }
            // 2026-08-16 (live escape: "my whole thing is I was just trying to
            // think of some other…" → staged as an "attribute"): an attribute
            // VALUE must be a noun phrase, not quoted first-person speech. A
            // value opening with a pronoun+clause is the user narrating, and
            // the capture cap then chops it mid-thought — parrot, not fact.
            let valueLower = value.lowercased()
            if valueLower.range(of: #"^(?:i|we|you|they|he|she|it)\b"#, options: .regularExpression) != nil {
                continue
            }
            // Discourse nouns ("my whole thing/point/deal is…") frame speech;
            // they are never stable user attributes.
            if a.hasSuffix("thing") || ["point", "deal", "take", "vibe"].contains(a) { continue }
            if a.hasPrefix("favorite") || a.hasPrefix("favourite") {
                emit("user's \(a) is \(value)", score: 0.80, kind: "preference")
            } else {
                emit("user's \(a) is \(value)", score: 0.70, kind: "attribute")
            }
        }
        // "I am a/an <X>" / "I'm a/an <X>"
        for m in Self.matches(normalized, pattern: #"\bI(?:'m| am) (?:an?\s+)([a-zA-Z][a-zA-Z\s\-]{2,\#(Self.valueCap)})"#) {
            emit("user is a \(m)", score: 0.65, kind: "identity")
        }
        return out
    }

    /// U3 wave-1 item 2: value-capture cap interpolated into the patterns
    /// above. The old caps ({2,40}/{1,60}) chopped values mid-phrase; the
    /// capture classes already exclude sentence/clause punctuation, so a
    /// generous cap lets a value run to its natural boundary. The shared
    /// `memoryExtractionCaptureCap` constant lives in MemoryV2+TextClip.swift;
    /// `MemoryTextClip.wordSafeCapture` below guarantees no candidate ever
    /// ends mid-word even when input exceeds this cap.
    static let valueCap = memoryExtractionCaptureCap

    private static func matches(_ s: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out: [String] = []
        re.enumerateMatches(in: s, options: [], range: range) { m, _, _ in
            guard let m, m.numberOfRanges >= 2 else { return }
            // wordSafeCapture trims a quantifier-capped match back to its
            // last whole word (or drops it) so no candidate ends mid-word.
            if let v = MemoryTextClip.wordSafeCapture(ns, range: m.range(at: 1)) {
                out.append(v)
            }
        }
        return out
    }

    private static func matchesPair(_ s: String, pattern: String) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out: [(String, String)] = []
        re.enumerateMatches(in: s, options: [], range: range) { m, _, _ in
            guard let m, m.numberOfRanges >= 3 else { return }
            guard let a = MemoryTextClip.wordSafeCapture(ns, range: m.range(at: 1)),
                  let b = MemoryTextClip.wordSafeCapture(ns, range: m.range(at: 2)) else { return }
            out.append((a, b))
        }
        return out
    }
}

// MARK: - AdaptiveMemoryPromoter

public actor AdaptiveMemoryPromoter {
    public static let shared = AdaptiveMemoryPromoter()

    public static let defaultThreshold: Double = 0.6
    /// Minimum confidence considered by the narrow structured-fact auto-accept
    /// lane. Preferences, relationships, goals, skills, and broad inferred
    /// facts remain proposals regardless of model confidence; a single small-
    /// model score is not corroboration.
    /// Closes the post-Swift-native-cutover seam where AdaptiveMemoryPromoter staged
    /// proposals (657 accumulated) but nothing was promoting them to
    /// memories — recall_memory had nothing to recall.
    public static let defaultAutoAcceptThreshold: Double = 0.8

    private var memory: SwiftNativeMemoryV2?
    private var extractor: any AdaptiveFactExtractor
    private var threshold: Double
    private var autoAcceptThreshold: Double
    /// The moments lane (2026-09-02). nil = off, and off is byte-identical to
    /// the pre-moments promoter. There is deliberately NO default conformer
    /// here: the fact lane falls back to regex when Apple Intelligence is
    /// missing, and a moment must never be invented by a pattern.
    private var momentExtractor: (any MomentExtracting)?
    /// The Setup page's "Moments she keeps" switch, injected as a closure so
    /// this module never reads UserDefaults. nil = no owner configured, which
    /// means ON — an embedder that never wires the switch keeps the lane's
    /// pre-switch behavior exactly.
    private var momentsEnabled: (@Sendable () -> Bool)?
    /// Settings ▸ "Memories that recur become facts", injected as a closure so
    /// this module never reads the trust policy itself. nil = no owner
    /// configured, which means ON — byte-identical to the pre-switch promoter.
    /// The moments lane above has its OWN switch and is not affected by this.
    private var adaptivePromotionEnabled: (@Sendable () -> Bool)?
    /// Daily-cap bookkeeping. Rebuilt from storage on the first moment of a
    /// new calendar day, then counted in memory — so the cap costs one scan a
    /// day, not one a turn. A restart re-scans, which is the honest direction.
    private var momentDayKey: String?
    /// Slots SPENT today. This is a reservation counter, not an observation:
    /// it is incremented before the model call and released if nothing stages.
    private var momentDayCount = 0
    /// True while the once-a-day storage scan is in flight. The day's quota is
    /// held at zero until it lands, so a burst of concurrent turns starts ONE
    /// scan and the losers skip the turn instead of racing a stale quota.
    private var momentDayScanInFlight = false
    /// Normalized content of every moment staged today. Her review turn
    /// quotes the moment back, and the extractor re-staged the same sentence
    /// from the quote (live, 2026-09-02, one turn after she accepted it).
    /// Same-shape repeats within the day never stage twice.
    private var momentDayContentKeys: Set<String> = []

    public init(
        memory: SwiftNativeMemoryV2? = nil,
        extractor: any AdaptiveFactExtractor = RuleBasedFactExtractor(),
        threshold: Double = AdaptiveMemoryPromoter.defaultThreshold,
        autoAcceptThreshold: Double = AdaptiveMemoryPromoter.defaultAutoAcceptThreshold,
        momentExtractor: (any MomentExtracting)? = nil,
        momentsEnabled: (@Sendable () -> Bool)? = nil,
        adaptivePromotionEnabled: (@Sendable () -> Bool)? = nil
    ) {
        self.memory = memory
        self.extractor = extractor
        self.threshold = threshold
        self.autoAcceptThreshold = autoAcceptThreshold
        self.momentExtractor = momentExtractor
        self.momentsEnabled = momentsEnabled
        self.adaptivePromotionEnabled = adaptivePromotionEnabled
    }

    public func configure(
        memory: SwiftNativeMemoryV2?,
        extractor: (any AdaptiveFactExtractor)? = nil,
        threshold: Double? = nil,
        autoAcceptThreshold: Double? = nil,
        momentExtractor: (any MomentExtracting)? = nil,
        momentsEnabled: (@Sendable () -> Bool)? = nil,
        adaptivePromotionEnabled: (@Sendable () -> Bool)? = nil
    ) {
        self.memory = memory
        if let extractor { self.extractor = extractor }
        if let threshold { self.threshold = threshold }
        if let autoAcceptThreshold { self.autoAcceptThreshold = autoAcceptThreshold }
        if let momentExtractor { self.momentExtractor = momentExtractor }
        if let momentsEnabled { self.momentsEnabled = momentsEnabled }
        if let adaptivePromotionEnabled {
            self.adaptivePromotionEnabled = adaptivePromotionEnabled
        }
    }

    /// Observe one (user, assistant) turn. Extract candidates, drop any
    /// below threshold or matching the tombstone denylist, and stage the
    /// survivors via `SwiftNativeMemoryV2.propose(...)`. Returns the
    /// proposals that were actually staged — empty if nothing crossed the
    /// gate (the common case).
    @discardableResult
    public func observeTurn(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String] = [],
        sessionId: String,
        surface: String = "chat"
    ) async -> [ProposalRecord] {
        await observeTurnWithReport(userMessage: userMessage, assistantMessage: assistantMessage,
                                    toolEvidence: toolEvidence, sessionId: sessionId,
                                    surface: surface).proposals
    }

    public func observeTurnWithReport(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String] = [],
        sessionId: String,
        surface: String = "chat"
    ) async -> AdaptiveMemoryObservation {
        let skipped = AdaptiveMemoryObservation(proposals: [], extraction: .init(
            candidates: [], semanticStatus: .skipped
        ))
        guard let memory else { return skipped }
        // 2026-08-14 proposal-hygiene fix: on bridge sessions the "user" seat
        // is another AGENT (claude/codex/wake runners), machine-tagged with
        // the "[from: <sender>, via bridge]" prefix that ClaudeBridge/
        // codex-bridge affix at their single entry points. Extracting "user
        // ..." facts from agent shop-talk minted proposals like "user is a
        // language model" about the human. Agent-seat turns never extract.
        //
        // Sweep item 35 EXTENDS this guard to the tool-evidence lane: an agent
        // driving her over the bridge runs tools too, and its file reads are
        // that agent's errand, not User's environment. One early return covers
        // BOTH lanes — evidence is only read below this line, never above it.
        //
        // MOMENTS ARE THE EXCEPTION, and deliberately so. A peer driving her
        // over the bridge states no facts ABOUT User, but something can still
        // happen between them — so the moment pass runs on both seats, tagged
        // `author: "peer"` when the seat was an agent. It runs BEFORE the fact
        // guard's early return for exactly that reason.
        let peerSeat = Self.isAgentSeatUserMessage(userMessage)
        // An agent in the user seat (bridge traffic) is not a moment with User.
        let momentProposal = peerSeat ? nil : await stageMomentIfAny(
            memory: memory,
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId,
            surface: surface,
            author: MemoryMoments.authorTag(forUserMessage: userMessage)
        )
        if peerSeat {
            return AdaptiveMemoryObservation(
                proposals: momentProposal.map { [$0] } ?? [],
                extraction: .init(candidates: [], semanticStatus: .skipped),
                momentOutcome: lastMomentOutcome
            )
        }
        // Settings ▸ "Memories that recur become facts": off stops the FACT
        // lane right here — no extraction, no recurrence tracking, no staging.
        // Read fresh per turn. The moments lane ran above under its OWN switch
        // and is deliberately untouched by this one.
        if let adaptivePromotionEnabled, !adaptivePromotionEnabled() {
            return AdaptiveMemoryObservation(
                proposals: momentProposal.map { [$0] } ?? [],
                extraction: .init(candidates: [], semanticStatus: .skipped),
                momentOutcome: lastMomentOutcome
            )
        }
        let evidenceCandidates = AdaptiveToolEvidence.proposalsEnabled
            ? AdaptiveToolEvidence.candidates(from: toolEvidence)
            : []
        let extraction: AdaptiveExtractionReport
        if let reporting = extractor as? any AdaptiveFactExtractionReporting {
            extraction = await reporting.extractWithReport(userMessage: userMessage, assistantMessage: assistantMessage)
        } else {
            extraction = AdaptiveExtractionReport(
                candidates: await extractor.extract(userMessage: userMessage, assistantMessage: assistantMessage),
                semanticStatus: .unreported
            )
        }
        var staged: [ProposalRecord] = momentProposal.map { [$0] } ?? []
        var hygieneRejected = 0
        for cand in extraction.candidates + evidenceCandidates where cand.score >= threshold {
            if AdaptiveCandidateHygiene.rejectionReason(
                cand.content, kind: cand.kind,
                userMessage: userMessage, assistantMessage: assistantMessage
            ) != nil {
                hygieneRejected += 1
                continue
            }
            do {
                if try await memory.isRejected(content: cand.content) { continue }
                let proposal = try await memory.propose(
                    content: cand.content,
                    source: "adaptive-promoter:\(sessionId)",
                    confidence: cand.score,
                    kind: cand.kind,
                    supportingSessionIDs: [sessionId],
                    recurrenceCount: 1
                )
                staged.append(proposal)
                // HOTFIX 2026-06-03 memory-seam: high-confidence candidates
                // auto-accept into `memories` so recall_memory sees them in
                // the same session. Below autoAcceptThreshold the proposal
                // remains pending for inbox review (existing review flow).
                // Best-effort: a failed accept leaves the proposal staged
                // for manual review, which is the SAFE failure mode.
                if Self.shouldAutoAccept(cand, confidenceFloor: autoAcceptThreshold) {
                    _ = try? await memory.acceptProposal(id: proposal.id)
                }
            } catch {
                // Best-effort: a single extraction failure must never break the
                // turn. The Python promoter swallowed proposal errors for the
                // same reason — staging is a side-channel, not the chat path.
                continue
            }
        }
        return AdaptiveMemoryObservation(
            proposals: staged,
            extraction: extraction,
            toolEvidenceCandidateCount: evidenceCandidates.count,
            momentOutcome: lastMomentOutcome,
            hygieneRejectedCount: hygieneRejected
        )
    }

    // MARK: - The moments lane

    /// The second extraction pass. Runs only when a moment extractor is
    /// configured (production: Apple Foundation Models), stages at most one
    /// proposal, and returns nil for every ordinary exchange — which is nearly
    /// all of them.
    ///
    /// ORDER MATTERS: the daily cap is checked BEFORE the model call, because
    /// the cheap gate belongs in front of the expensive one.
    /// Set by every exit of `stageMomentIfAny`; read once into the observation.
    private var lastMomentOutcome = "unreported"

    private func stageMomentIfAny(
        memory: SwiftNativeMemoryV2,
        userMessage: String,
        assistantMessage: String,
        sessionId: String,
        surface: String,
        author: String,
        now: Date = Date()
    ) async -> ProposalRecord? {
        // The switch comes FIRST, ahead of the extractor and the day-slot
        // reservation: off means nothing is read, nothing is reserved and no
        // model is called — the same "not installed" shape her hour uses.
        if let momentsEnabled, !momentsEnabled() {
            lastMomentOutcome = "disabled"
            return nil
        }
        lastMomentOutcome = "noExtractor"
        guard let momentExtractor else { return nil }
        // RESERVE FIRST. An actor is reentrant across `await`, so a
        // check-then-await-then-increment shape lets every concurrent turn read
        // the same stale quota and all of them stage — the cap would hold only
        // when turns happened to be serial. The slot is taken synchronously
        // here and released on every path that does not stage.
        lastMomentOutcome = "capped"
        guard await reserveMomentSlot(memory: memory, now: now) else { return nil }
        lastMomentOutcome = "none"
        var staged = false
        defer { if !staged { releaseMomentSlot() } }

        guard let candidate = await momentExtractor.extractMoment(
            userMessage: userMessage,
            assistantMessage: assistantMessage
        ) else { return nil }
        lastMomentOutcome = "belowSalience"
        guard candidate.salience >= MemoryMoments.salienceFloor else { return nil }
        // A quote the model did not actually copy is a fabricated line of
        // dialogue. Drop it and keep the moment.
        let quote = MemoryMoments.validatedQuote(
            candidate.quote,
            userMessage: userMessage,
            assistantMessage: assistantMessage
        )
        // User, 2026-09-03: no line of his, no moment. Eight of her own
        // sentences reached the review card as moments overnight; a moment
        // is what happened between them, and his words are the proof.
        lastMomentOutcome = "noQuote"
        guard let quote else { return nil }
        let content = MemoryMoments.composedContent(candidate.content, quote: quote)
        lastMomentOutcome = "duplicate"
        let contentKey = MemoryMoments.contentKey(candidate.content)
        guard !momentDayContentKeys.contains(contentKey) else { return nil }
        // The turn text reached an LLM and came back as prose that is about to
        // be written into durable memory. The prompt told the model that text
        // was data; this checks that what it handed back still looks like a
        // person narrating an hour, and not an instruction wearing one.
        lastMomentOutcome = "gated"
        guard MemoryMoments.contentRejectionReason(content) == nil else { return nil }
        lastMomentOutcome = "ungrounded"
        guard MemoryMoments.groundednessRejectionReason(
            candidate.content, userMessage: userMessage, assistantMessage: assistantMessage
        ) == nil else { return nil }
        lastMomentOutcome = "failed"
        do {
            if try await memory.isRejected(content: content) {
                lastMomentOutcome = "tombstoned"
                return nil
            }
            let proposal = try await memory.propose(
                content: content,
                source: "\(MemoryMoments.sourcePrefix):\(sessionId)",
                confidence: candidate.salience,
                kind: MemoryMoments.kind,
                supportingSessionIDs: [sessionId],
                recurrenceCount: 1,
                extraMetadata: MemoryMoments.metadata(
                    for: candidate,
                    quote: quote,
                    sessionId: sessionId,
                    surface: surface,
                    author: author
                )
            )
            // Kept whatever the dedup path did with it: a re-staged moment
            // still consumed a model call and a day slot.
            staged = true
            momentDayContentKeys.insert(contentKey)
            lastMomentOutcome = "staged"
            return proposal
        } catch {
            // Best-effort, same contract as the fact lane.
            return nil
        }
    }

    /// Take one of today's moment slots, or refuse. Everything after the
    /// (at most once a day) storage scan is synchronous, so the read of
    /// `momentDayCount` and its increment cannot be interleaved by another turn.
    ///
    /// Counts pending + accepted + rejected — what she did with a moment does
    /// not give the day another one.
    private func reserveMomentSlot(memory: SwiftNativeMemoryV2, now: Date) async -> Bool {
        let key = MemoryMoments.dayKey(now)
        if momentDayKey != key, !momentDayScanInFlight {
            // Claim the day and CLOSE the quota before yielding, so turns that
            // arrive during the scan refuse rather than stage on a zeroed
            // counter. Missing a moment is the safe direction; overshooting the
            // cap is not.
            momentDayKey = key
            momentDayCount = MemoryMoments.dailyCap
            momentDayScanInFlight = true
            let scanned = await Self.stagedMomentsToday(memory: memory, dayKey: key)
            momentDayScanInFlight = false
            // Another turn may have rolled the day over while the scan ran; only
            // apply the result if it still describes today.
            if momentDayKey == key {
                momentDayCount = scanned.count
                momentDayContentKeys = Set(scanned.map {
                    MemoryMoments.storedContentKey(content: $0.content, metadata: $0.metadata)
                })
            }
        }
        guard momentDayKey == key, momentDayCount < MemoryMoments.dailyCap else { return false }
        momentDayCount += 1
        return true
    }

    /// Give the slot back. Only ever called for a reservation this actor made,
    /// and floored at zero so a released-twice bug can never mint free quota.
    private func releaseMomentSlot() {
        momentDayCount = max(0, momentDayCount - 1)
    }

    static func stagedMomentsToday(memory: SwiftNativeMemoryV2, dayKey: String) async -> [ProposalRecord] {
        guard let all = try? await memory.listProposals(status: nil) else { return [] }
        return all.filter { proposal in
            guard MemoryMoments.isMoment(proposal.metadata) else { return false }
            guard let staged = MemoryMoments.parseTimestamp(proposal.createdAt) else { return false }
            return MemoryMoments.dayKey(staged) == dayKey
        }
    }

    static func stagedMomentCount(memory: SwiftNativeMemoryV2, dayKey: String) async -> Int {
        await stagedMomentsToday(memory: memory, dayKey: dayKey).count
    }

    /// How many moments are waiting on her. The nudge line's whole read, and it
    /// runs on the turn path — so it is a storage-level COUNT, never a listing.
    public func pendingMomentCount() async -> Int {
        guard let memory else { return 0 }
        return (try? await memory.countMomentProposals(status: "pending")) ?? 0
    }

    /// One-shot backfill for pending proposals that satisfy the same narrow
    /// structured-fact policy as live auto-accept. Preferences/goals and rows
    /// without typed confidence evidence remain pending for human review.
    @discardableResult
    public func runAutoAcceptSweep(maxToScan: Int = 500) async -> Int {
        guard let memory else { return 0 }
        guard let allPending = try? await memory.listProposals(status: "pending") else {
            return 0
        }
        // Slice to maxToScan (storage layer doesn't expose a limit yet).
        // 2026-07-21 audit fix: the pending list arrives NEWEST-first
        // (staged_at DESC), so prefix(maxToScan) over a >maxToScan backlog
        // starved the OLDEST pending rows forever — exactly the rows an
        // aging pass exists to clear. Sort oldest-first before slicing so
        // every sweep drains the tail of the queue; fresh arrivals are
        // handled by the live observeTurn auto-accept lane and later sweeps.
        let pending = Array(allPending.sorted { $0.createdAt < $1.createdAt }.prefix(maxToScan))
        var accepted = 0
        for p in pending {
            // Skip if content is empty (legacy daemon-era staging artifacts)
            // — these can't usefully recall and would pollute the well.
            let trimmed = p.content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let candidate = Self.autoAcceptCandidate(from: p),
                  Self.shouldAutoAccept(candidate, confidenceFloor: autoAcceptThreshold) else {
                continue
            }
            // Tombstone re-check at accept time (mirrors acceptProposal's
            // own gate — cheaper to skip here than throw inside).
            if (try? await memory.isRejected(content: trimmed)) == true { continue }
            do {
                _ = try await memory.acceptProposal(id: p.id)
                accepted += 1
            } catch {
                continue
            }
        }
        return accepted
    }

    /// True when the turn's user-seat text was machine-tagged as coming from
    /// another agent over a local bridge. The prefix is affixed at the single
    /// bridge entry points (ClaudeBridge / codex bridge), same convention
    /// StructuredChat's trusted-bridge-envelope detection relies on.
    static func isAgentSeatUserMessage(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.range(
            of: #"^\[from: [^\]]{1,64}, via bridge\]"#,
            options: .regularExpression
        ) != nil
    }

    /// Test/inspection hook: run the configured extractor without proposing
    /// anything. Lets the rule-based path stay unit-testable without booting
    /// a full storage stack.
    public func extractCandidates(
        userMessage: String,
        assistantMessage: String = ""
    ) async -> [AdaptiveCandidate] {
        return await extractor.extract(
            userMessage: userMessage,
            assistantMessage: assistantMessage
        )
    }

    public func currentThreshold() -> Double { threshold }

    static func shouldAutoAccept(
        _ candidate: AdaptiveCandidate,
        confidenceFloor: Double
    ) -> Bool {
        let kind = candidate.kind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch kind {
        case "identity":
            return candidate.score >= max(confidenceFloor, 0.90)
        case "location", "employment", "schedule":
            return candidate.score >= max(confidenceFloor, 0.85)
        default:
            return false
        }
    }

    private static func autoAcceptCandidate(from proposal: ProposalRecord) -> AdaptiveCandidate? {
        guard case .object(let metadata)? = proposal.metadata,
              case .string(let kind)? = metadata["kind"] else {
            return nil
        }
        let confidence: Double? = {
            switch metadata["confidence"] {
            case .double(let value)?: return value
            case .int(let value)?: return Double(value)
            case .string(let value)?: return Double(value)
            default: return nil
            }
        }()
        guard let confidence, confidence.isFinite else { return nil }
        return AdaptiveCandidate(
            content: proposal.content,
            score: min(1, max(0, confidence)),
            kind: kind
        )
    }
}

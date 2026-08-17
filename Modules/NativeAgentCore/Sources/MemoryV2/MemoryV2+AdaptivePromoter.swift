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

    public init(
        memory: SwiftNativeMemoryV2? = nil,
        extractor: any AdaptiveFactExtractor = RuleBasedFactExtractor(),
        threshold: Double = AdaptiveMemoryPromoter.defaultThreshold,
        autoAcceptThreshold: Double = AdaptiveMemoryPromoter.defaultAutoAcceptThreshold
    ) {
        self.memory = memory
        self.extractor = extractor
        self.threshold = threshold
        self.autoAcceptThreshold = autoAcceptThreshold
    }

    public func configure(
        memory: SwiftNativeMemoryV2?,
        extractor: (any AdaptiveFactExtractor)? = nil,
        threshold: Double? = nil,
        autoAcceptThreshold: Double? = nil
    ) {
        self.memory = memory
        if let extractor { self.extractor = extractor }
        if let threshold { self.threshold = threshold }
        if let autoAcceptThreshold { self.autoAcceptThreshold = autoAcceptThreshold }
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
        sessionId: String
    ) async -> [ProposalRecord] {
        guard let memory else { return [] }
        // 2026-08-14 proposal-hygiene fix: on bridge sessions the "user" seat
        // is another AGENT (claude/codex/wake runners), machine-tagged with
        // the "[from: <sender>, via bridge]" prefix that ClaudeBridge/
        // codex-bridge affix at their single entry points. Extracting "user
        // ..." facts from agent shop-talk minted proposals like "user is a
        // language model" about the human. Agent-seat turns never extract.
        if Self.isAgentSeatUserMessage(userMessage) { return [] }
        let candidates = await extractor.extract(
            userMessage: userMessage,
            assistantMessage: assistantMessage
        )
        var staged: [ProposalRecord] = []
        for cand in candidates where cand.score >= threshold {
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
        return staged
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

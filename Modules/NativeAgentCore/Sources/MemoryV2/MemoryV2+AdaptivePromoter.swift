import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - AdaptiveMemoryPromoter
//
// The after-turn promotion path: observe a (user, assistant) turn and stage
// what is worth keeping as a proposal for the person to approve.
//
// Two lanes run here, both on the agent's real model:
//   • THE FACT LANE is the memory manager (MemoryV2+MemoryManager.swift,
//     2026-09-11). It sees the exchange, the top-K memories already kept, and
//     what is already pending, and returns add/update/skip decisions. It
//     replaced a regex template extractor plus an on-device Foundation Models
//     pass plus a pile of rejection regexes — all deleted, because every fix to
//     that shape was one more regex.
//   • THE MOMENTS LANE (MemoryV2+Moments.swift) is unchanged.
//
// Neither lane has a rule-based fallback, deliberately: a memory invented by a
// pattern match is worse than a memory missed.

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

public struct AdaptiveMemoryObservation: Sendable {
    public let proposals: [ProposalRecord]
    public let extraction: AdaptiveExtractionReport
    /// How many candidates this turn's TOOL EVIDENCE contributed, separate
    /// from the fact lane's own report. `extraction` keeps describing the
    /// memory manager and nothing else, so its `semanticStatus` stays honest.
    public let toolEvidenceCandidateCount: Int
    /// What the moment pass did this turn, one word, for the turn trace:
    /// disabled / noExtractor / capped / abstained / extractionFailed /
    /// extractorUnavailable / cancelled / belowSalience / noQuote /
    /// gated / ungrounded / tombstoned / staged / failed; peer-seat turns
    /// never run the pass and report unreported. A moment that silently never stages is
    /// the drift this exists to make visible.
    public let momentOutcome: String
    /// Decisions the fact lane refused this turn: below the confidence floor,
    /// refused by `MemoryManagerLane.statementRejectionReason`, an embedding
    /// near-duplicate of something already kept or pending, tombstoned, or a
    /// staging error.
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

// MARK: - Shared candidate vocabulary

/// What the agent goes by, and the word-stem folding the lanes ground on.
///
/// This USED to hold the fact lane's rejection gate as well — first-person,
/// about-assistant and grounding regexes over regex-extracted captures. That
/// extractor is gone (2026-09-11: the memory manager replaced it) and so is the
/// gate; `MemoryManagerLane.statementRejectionReason` is the one shape check on
/// the manager's answer, and it reads the two members kept below.
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
    private static let stopwords: Set<String> = [
        "user", "users", "user's", "the", "and", "that", "this", "with", "from", "into",
        "have", "has", "had", "was", "were", "been", "being", "are", "is", "its", "it's",
        "for", "not", "but", "they", "them", "their", "there", "when", "then", "than",
        "what", "which", "who", "how", "why", "about", "also", "just", "like", "likes",
        "very", "really", "some", "more", "most", "such", "over", "only", "still",
        "because", "cause", "does", "did", "will", "would", "could", "should",
    ]

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
    /// The fact lane (2026-09-11). nil = off, and off stages no facts at all —
    /// there is no regex conformer to fall back to, by design.
    private var memoryManager: (any MemoryManaging)?
    /// The person's configured name, read fresh so a rename shows up.
    private var personName: (@Sendable () -> String?)? = nil
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
        memoryManager: (any MemoryManaging)? = nil,
        threshold: Double = AdaptiveMemoryPromoter.defaultThreshold,
        autoAcceptThreshold: Double = AdaptiveMemoryPromoter.defaultAutoAcceptThreshold,
        momentExtractor: (any MomentExtracting)? = nil,
        momentsEnabled: (@Sendable () -> Bool)? = nil,
        adaptivePromotionEnabled: (@Sendable () -> Bool)? = nil
    ) {
        self.memory = memory
        self.memoryManager = memoryManager
        self.threshold = threshold
        self.autoAcceptThreshold = autoAcceptThreshold
        self.momentExtractor = momentExtractor
        self.momentsEnabled = momentsEnabled
        self.adaptivePromotionEnabled = adaptivePromotionEnabled
    }

    public func configure(
        memory: SwiftNativeMemoryV2?,
        memoryManager: (any MemoryManaging)? = nil,
        threshold: Double? = nil,
        autoAcceptThreshold: Double? = nil,
        momentExtractor: (any MomentExtracting)? = nil,
        momentsEnabled: (@Sendable () -> Bool)? = nil,
        adaptivePromotionEnabled: (@Sendable () -> Bool)? = nil,
        personName: (@Sendable () -> String?)? = nil
    ) {
        self.memory = memory
        if let memoryManager { self.memoryManager = memoryManager }
        if let personName { self.personName = personName }
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
        // A bot's session has the agent's own brief in the user seat: no person
        // is there, nothing happens "between them", and its brief recurring on
        // every run minted "user values ..." about User (2026-09-10).
        if sessionId.hasPrefix("bot-") { return skipped }
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
        // 2026-09-11, User: "her having her memory with you is kind of
        // important." The blanket skip above was the regex era's fix; the memory
        // manager is a model that is TOLD who is speaking, so a bridge turn now
        // runs both lanes with the sender named (Claude, Codex, …) — a memory
        // it mints says "Claude …", never "user …" and never User.
        let peerSeat = Self.isAgentSeatUserMessage(userMessage)
        let peerSpeaker = peerSeat ? Self.bridgeSender(userMessage) : nil
        let momentAuthor = MemoryMoments.authorTag(forUserMessage: userMessage)
        let momentProposal = await stageMomentIfAny(
            memory: memory,
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId,
            surface: surface,
            author: momentAuthor
        )
        // THE DECLINE LEAVES A RECEIPT (Astra comb 3, lane2 finding 9,
        // 2026-09-12). `lastMomentOutcome` used to reach only the turn's
        // `memory.promotion` stage, so a missing moment had no explanation
        // anywhere the moment the stage itself went missing.
        await MemoryMoments.recordOutcomeReceipt(
            outcome: lastMomentOutcome,
            sessionId: sessionId,
            surface: surface,
            author: momentAuthor,
            slotsSpentToday: slotsSpentTodayIfKnown(),
            stagedProposalId: momentProposal?.id
        )
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
        var staged: [ProposalRecord] = momentProposal.map { [$0] } ?? []
        var hygieneRejected = 0
        let managerResult = await runMemoryManager(
            speaker: peerSpeaker,
            memory: memory,
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId,
            surface: surface
        )
        staged.append(contentsOf: managerResult.proposals)
        hygieneRejected += managerResult.rejectedCount
        let extraction = managerResult.report
        for cand in evidenceCandidates where cand.score >= threshold {
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

    // MARK: - The fact lane: the memory manager

    struct MemoryManagerOutcome {
        let proposals: [ProposalRecord]
        let report: AdaptiveExtractionReport
        let rejectedCount: Int
    }

    /// One manager pass over one turn.
    ///
    /// The shape, in order: show it what is already known (so it can say "already
    /// covered" instead of re-minting), ask once, then gate what came back on
    /// confidence, shape, embedding near-duplication and the tombstone list.
    /// Every survivor stages as a PENDING proposal — nothing here promotes itself
    /// except through the pre-existing narrow structured-fact allowlist.
    private func runMemoryManager(
        speaker: String? = nil,
        memory: SwiftNativeMemoryV2,
        userMessage: String,
        assistantMessage: String,
        sessionId: String,
        surface: String
    ) async -> MemoryManagerOutcome {
        func empty(_ status: MemorySemanticExtractionStatus) -> MemoryManagerOutcome {
            MemoryManagerOutcome(
                proposals: [],
                report: AdaptiveExtractionReport(candidates: [], semanticStatus: status),
                rejectedCount: 0
            )
        }
        guard let memoryManager else { return empty(.unavailable) }
        let user = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !assistant.isEmpty else { return empty(.emptyInput) }

        // What is already known about this exchange. `recordingUsage: false`:
        // reading the store to decide what to keep is not the agent USING a
        // memory, and use_count is the signal that vetoes eviction.
        let existing: [MemoryManagerExistingMemory] = await {
            guard let response = try? await memory.recall(
                MemoryV2RecallRequest(text: "\(user)\n\(assistant)", topK: MemoryManagerLane.recallTopK),
                recordingUsage: false
            ) else { return [] }
            return response.scored.map {
                MemoryManagerExistingMemory(id: $0.record.id, content: $0.record.text)
            }
        }()
        // What is already waiting on the person. Moments are a different lane
        // and a different card; they are not facts to dedupe against.
        // Shown WITH their ids (2026-09-11, found driving it: a correction of a
        // statement that was itself still pending stacked up as a second pending
        // row instead of replacing the first). An update naming a pending id
        // retires that row and stages the correction in its place.
        let pendingRows: [ProposalRecord] = await {
            guard let all = try? await memory.listProposals(status: "pending") else { return [] }
            return Array(all
                .filter { !MemoryMoments.isMoment($0.metadata) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(MemoryManagerLane.pendingCap))
        }()
        // The PROMPT sees ids; every COMPARISON sees content only (Astra comb
        // finding 2: "[id] text" was being screened against "text", so a
        // correction's own target never left its duplicate screen).
        let pendingPrompt: [String] = pendingRows.map { "[\($0.id)] \($0.content)" }
        let pending: [String] = pendingRows.map(\.content)

        guard let decisions = await memoryManager.review(MemoryManagerRequest(
            userMessage: user,
            assistantMessage: assistant,
            existing: existing,
            pending: pendingPrompt,
            personName: speaker ?? personName?()
        )) else { return empty(.failed) }

        var staged: [ProposalRecord] = []
        var accepted: [AdaptiveCandidate] = []
        var rejected = 0
        // Everything the statement must not merely repeat: what is kept, what is
        // pending, and what this same pass already minted this turn.
        var comparisons = existing.map(\.content) + pending
        for raw in decisions {
            // An `update` must name one of the memories the model was shown;
            // anything else degrades to `add` (MemoryManagerLane.reconciled).
            // A correction of a PENDING statement: retire that row now, then stage
            // the correction as an ordinary add (nothing kept is being replaced).
            let supersededPending: ProposalRecord? = (raw.action == .update)
                ? pendingRows.first(where: { $0.id == raw.updatesId }) : nil
            let (decision, updateTarget) = MemoryManagerLane.reconciled(raw, existing: existing)
            guard decision.action != .skip else { continue }
            guard decision.confidence >= MemoryManagerLane.confidenceFloor else {
                rejected += 1
                continue
            }
            if MemoryManagerLane.statementRejectionReason(
                decision.statement, userMessage: user, assistantMessage: assistant
            ) != nil {
                rejected += 1
                continue
            }
            // The row an update REPLACES is not competition for it: screening a
            // correction against the statement it corrects rejects exactly the
            // work the manager was asked to do (2026-09-11 audit, finding 4).
            // Everything else kept or pending still screens.
            let replacedContent = updateTarget?.content ?? supersededPending?.content
            let screened: [String] = replacedContent.map { target in
                comparisons.filter { $0 != target }
            } ?? comparisons
            if await Self.isNearDuplicate(
                decision.statement, of: screened, memory: memory
            ) {
                rejected += 1
                continue
            }
            do {
                if try await memory.isRejected(content: decision.statement) {
                    rejected += 1
                    continue
                }
                let proposal = try await memory.propose(
                    content: decision.statement,
                    source: "\(MemoryManagerLane.sourcePrefix):\(sessionId)",
                    confidence: decision.confidence,
                    kind: decision.kind,
                    supportingSessionIDs: [sessionId],
                    recurrenceCount: 1,
                    extraMetadata: MemoryManagerLane.metadata(
                        for: decision, sessionId: sessionId, surface: surface,
                        updateTarget: updateTarget
                    )
                )
                staged.append(proposal)
                comparisons.append(decision.statement)
                if let old = supersededPending {
                    _ = try? await memory.supersedeProposal(id: old.id, by: proposal.id)
                }
                let candidate = AdaptiveCandidate(
                    content: decision.statement,
                    score: decision.confidence,
                    kind: decision.kind
                )
                accepted.append(candidate)
                // The pre-existing narrow structured-fact allowlist, unchanged:
                // identity/location/employment/schedule only, at its own floor.
                if Self.shouldAutoAccept(candidate, confidenceFloor: autoAcceptThreshold) {
                    _ = try? await memory.acceptProposal(id: proposal.id)
                }
            } catch {
                // Best-effort: staging is a side-channel, never the turn path.
                rejected += 1
                continue
            }
        }
        return MemoryManagerOutcome(
            proposals: staged,
            report: AdaptiveExtractionReport(
                candidates: accepted,
                semanticStatus: .succeeded,
                semanticCandidateCount: decisions.count
            ),
            rejectedCount: rejected
        )
    }

    /// True when `statement` says what one of `others` already says, by embedding
    /// cosine. The store's own embedder answers, so "already in there" means the
    /// same thing here as it does at recall time. An embedder that cannot answer
    /// (cold, mock, fail-closed) degrades to exact normalized equality rather
    /// than dropping everything or keeping everything.
    static func isNearDuplicate(
        _ statement: String,
        of others: [String],
        memory: SwiftNativeMemoryV2
    ) async -> Bool {
        guard !others.isEmpty else { return false }
        let fold: (String) -> String = { MemoryMoments.wordFold($0) }
        let needle = fold(statement)
        if others.contains(where: { fold($0) == needle }) { return true }
        guard let vectors = try? await memory.embedForDerivedContext([statement] + others),
              vectors.count == others.count + 1,
              let query = vectors.first, !query.isEmpty else {
            return false
        }
        for vector in vectors.dropFirst() where vector.count == query.count {
            var dot: Float = 0
            for i in 0..<query.count { dot += query[i] * vector[i] }
            if Double(dot) >= MemoryManagerLane.duplicateSimilarity { return true }
        }
        return false
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
        // The outcome is now the EXTRACTOR'S word, not a placeholder set before
        // the call (lane5 finding 3): "abstained" means the model read the hour
        // and said there was no moment in it; "extractionFailed" means no answer
        // was obtained. The ledger could not tell those apart while both wrote
        // `none`.
        lastMomentOutcome = "unreported"
        var staged = false
        defer { if !staged { releaseMomentSlot() } }

        let outcome = await momentExtractor.extractMomentOutcome(
            userMessage: userMessage,
            assistantMessage: assistantMessage
        )
        guard let candidate = outcome.candidate else {
            lastMomentOutcome = outcome.receiptOutcome
            return nil
        }
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

    /// Today's slot spend, or nil when this actor has not initialized it yet
    /// (Astra comb 3, lane2 finding 10, 2026-09-12). `momentDayCount` only
    /// describes a day once `reserveMomentSlot` has claimed that day's key, and
    /// the `noExtractor` exit returns BEFORE the reservation — reporting the
    /// raw counter there published the initial zero, or yesterday's tally, as
    /// today's spend. The receipt omits the field instead.
    private func slotsSpentTodayIfKnown(now: Date = Date()) -> Int? {
        momentDayKey == MemoryMoments.dayKey(now) ? momentDayCount : nil
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

    /// The sender a bridge entry point stamped on the turn ("[from: claude,
    /// via bridge]" → "Claude"), so the memory manager can name who spoke.
    static func bridgeSender(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = t.range(of: #"^\[from: ([^\],]{1,64}), via bridge\]"#, options: .regularExpression) else { return nil }
        let inside = t[match].dropFirst("[from: ".count)
        let name = inside.prefix { $0 != "," }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = name.first else { return nil }
        return String(first).uppercased() + name.dropFirst()
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

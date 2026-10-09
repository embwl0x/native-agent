import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import CognitiveSubstrate
import ChatTurnContracts

// MARK: - AdaptiveMemoryPromoter
//
// The after-turn promotion path: observe a (user, assistant) turn and stage
// what is worth keeping as a proposal for the person to approve.
//
// One interpretation feeds the existing fact and moment lanes:
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
    public let failure: AfterTurnMemoryFailure?
    public var interpretationFailure: AfterTurnInterpretationFailure? { failure?.interpretationFailure }

    public init(candidates: [AdaptiveCandidate], semanticStatus: MemorySemanticExtractionStatus,
                semanticCandidateCount: Int = 0, failure: AfterTurnMemoryFailure? = nil) {
        self.candidates = candidates
        self.semanticStatus = semanticStatus
        self.semanticCandidateCount = max(0, semanticCandidateCount)
        self.failure = failure
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
    public let savedCorrectionCount: Int
    public let pendingCorrectionCount: Int
    public let failedCorrectionCount: Int
    /// Why the novelty gate skipped the memory call this turn, or nil when it
    /// ran (Phase 5A). Rides to the turn trace so the skip rate is measurable.
    public var noveltySkipReason: String?

    init(
        proposals: [ProposalRecord],
        extraction: AdaptiveExtractionReport,
        toolEvidenceCandidateCount: Int = 0,
        momentOutcome: String = "unreported",
        hygieneRejectedCount: Int = 0,
        savedCorrectionCount: Int = 0,
        pendingCorrectionCount: Int = 0,
        failedCorrectionCount: Int = 0
    ) {
        self.proposals = proposals
        self.extraction = extraction
        self.toolEvidenceCandidateCount = max(0, toolEvidenceCandidateCount)
        self.momentOutcome = momentOutcome
        self.hygieneRejectedCount = max(0, hygieneRejectedCount)
        self.savedCorrectionCount = savedCorrectionCount
        self.pendingCorrectionCount = pendingCorrectionCount
        self.failedCorrectionCount = failedCorrectionCount
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

    private var memory: SwiftNativeMemoryV2?
    /// The fact lane (2026-09-11). nil = off, and off stages no facts at all —
    /// there is no regex conformer to fall back to, by design.
    private var memoryManager: (any MemoryManaging)?
    /// The person's configured name, read fresh so a rename shows up.
    private var personName: (@Sendable () -> String?)? = nil
    private var prepareInterpretation: (@Sendable (AfterTurnOrigin) async -> AfterTurnContext?)?
    /// The Bool is true when the novelty gate skipped the call (Phase 5A).
    private var finishInterpretation: (@Sendable (AfterTurnContext, AfterTurnInterpretation?, Bool) async -> Void)?
    private var observationTail: Task<AdaptiveMemoryObservation, Never>?
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
        momentsEnabled: (@Sendable () -> Bool)? = nil,
        adaptivePromotionEnabled: (@Sendable () -> Bool)? = nil
    ) {
        self.memory = memory
        self.memoryManager = memoryManager
        self.momentsEnabled = momentsEnabled
        self.adaptivePromotionEnabled = adaptivePromotionEnabled
    }

    public func configure(
        memory: SwiftNativeMemoryV2?,
        memoryManager: (any MemoryManaging)? = nil,
        momentsEnabled: (@Sendable () -> Bool)? = nil,
        adaptivePromotionEnabled: (@Sendable () -> Bool)? = nil,
        personName: (@Sendable () -> String?)? = nil
    ) {
        self.memory = memory
        if let memoryManager { self.memoryManager = memoryManager }
        if let personName { self.personName = personName }
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
        surface: String = "chat",
        standingAgentName: String? = nil,
        turnId: String? = nil
    ) async -> [ProposalRecord] {
        await observeTurnWithReport(userMessage: userMessage, assistantMessage: assistantMessage,
                                    toolEvidence: toolEvidence, sessionId: sessionId,
                                    surface: surface, standingAgentName: standingAgentName, turnId: turnId).proposals
    }

    public func observeTurnWithReport(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String] = [],
        sessionId: String,
        surface: String = "chat",
        standingAgentName: String? = nil,
        turnId: String? = nil
    ) async -> AdaptiveMemoryObservation {
        let origin = AfterTurnSource.origin
        let previous = observationTail
        let operation = Task {
            _ = await previous?.value
            return await self.interpretAndObserve(userMessage: userMessage,
                assistantMessage: assistantMessage,
                sessionId: sessionId, surface: surface, origin: origin,
                standingAgentName: standingAgentName, turnId: turnId ?? origin?.runId)
        }
        observationTail = operation
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    public func configureInterpretation(
        prepare: @escaping @Sendable (AfterTurnOrigin) async -> AfterTurnContext?,
        finish: @escaping @Sendable (AfterTurnContext, AfterTurnInterpretation?, Bool) async -> Void
    ) {
        prepareInterpretation = prepare
        finishInterpretation = finish
    }

    public func relevantRecallIDs(query: String, candidates: [MemoryManagerExistingMemory], generation: String? = nil, topK: Int? = nil) async throws -> Set<String> {
        guard let memoryManager else {
            throw MemoryV2Error.underlying("Recall relevance is unavailable. Configure the selected memory model in Settings, then retry this query.")
        }
        switch await memoryManager.relevantRecallIDs(query: query, candidates: candidates, generation: generation, topK: topK) {
        case .success(let ids): return ids
        case .failure(let failure):
            throw MemoryV2Error.underlying("Recall relevance could not be checked (\(failure.reason.rawValue)). \(failure.recovery) Nothing was returned as a memory answer.")
        }
    }

    private func interpretAndObserve(userMessage: String, assistantMessage: String,
                                     sessionId: String,
                                     surface: String, origin: AfterTurnOrigin?,
                                     standingAgentName: String?, turnId: String?) async -> AdaptiveMemoryObservation {
        let skipped = AdaptiveMemoryObservation(proposals: [], extraction: .init(
            candidates: [], semanticStatus: .skipped
        ))
        guard !Task.isCancelled, let memory else { return skipped }
        // Source determines attribution, never whether the memory judge runs.
        let standingAgent = standingAgentName != nil
        let peerSeat = Self.isAgentSeatUserMessage(userMessage)
        let peerSpeaker = standingAgent ? (standingAgentName ?? "standing agent")
            : (peerSeat ? Self.bridgeSender(userMessage) : nil)
        let hasReply = !assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let requestedMoments = hasReply && (momentsEnabled?() ?? true)
        let requestedFacts = hasReply && (adaptivePromotionEnabled?() ?? true)
        // Give yesterday's quota-deferred exchanges their turn before spending
        // today's slots on new arrivals. Completed facts are never replayed.
        if requestedMoments { await askHeldMoments(memory: memory, quotaDeferredOnly: true) }
        let reservedMoment = requestedMoments ? await reserveMomentSlot(memory: memory, now: Date()) : false
        lastMomentOutcome = requestedMoments ? (reservedMoment ? "unreported" : "capped") : "disabled"
        let managerResult = await runMemoryManager(
            speaker: peerSpeaker, memory: memory, userMessage: userMessage,
            assistantMessage: assistantMessage, sessionId: sessionId, surface: surface,
            momentsAllowed: reservedMoment, origin: origin, standingAgent: standingAgent, factsAllowed: requestedFacts)
        let momentAuthor = standingAgent || managerResult.peerAuthority ? "peer" : "user"
        let momentProposal = await stageMomentIfAny(
            memory: memory,
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId,
            surface: surface,
            author: momentAuthor,
            outcome: managerResult.moment,
            reserved: reservedMoment,
            friction: AfterTurnNoveltyGate.frictionSignal(
                userMessage: userMessage, assistantMessage: assistantMessage)
                ?? (managerResult.savedCorrectionCount + managerResult.pendingCorrectionCount > 0
                    ? "correction" : nil),
            origin: origin, turnId: turnId
        )
        // THE DECLINE LEAVES A RECEIPT (Astra comb 3, lane2 finding 9,
        // 2026-09-12). `lastMomentOutcome` used to reach only the turn's
        // `memory.promotion` stage, so a missing moment had no explanation
        // anywhere the moment the stage itself went missing.
        if managerResult.noveltySkipReason != nil { lastMomentOutcome = "noveltySkipped" }
        // Preserve every requested lane even when the moment quota was full.
        if !Task.isCancelled, requestedFacts || requestedMoments,
           managerResult.noveltySkipReason == nil,
           managerResult.report.failure != nil || managerResult.stagingFailed || (requestedMoments && !reservedMoment) {
            lastMomentOutcome = holdMoment(HeldMoment(sessionId: sessionId, surface: surface, user: userMessage,
                asked: origin?.userMessage ?? userMessage, assistant: assistantMessage,
                turnId: turnId, runId: origin?.runId, messageId: origin?.messageId, occurredAt: origin?.occurredAt,
                speaker: peerSpeaker, standingAgent: standingAgent,
                factsEnabled: requestedFacts && (!managerResult.factsProcessed || managerResult.stagingFailed),
                momentsEnabled: requestedMoments && (managerResult.report.failure != nil || !reservedMoment
                    || lastMomentOutcome == "failed"), failure: managerResult.report.failure,
                humanName: managerResult.humanName, peerAuthority: managerResult.peerAuthority,
                momentDeferredDay: requestedMoments && !reservedMoment ? MemoryMoments.dayKey(Date()) : nil,
                envelope: TurnEnvelope.current(surface: surface).persistedMetadata(),
                sourceCheckpoint: MemoryDataProvenance.sources(in: MemoryDataProvenance.stamping(nil)),
                elevatedSources: PeerDataTaint.current?.elevatedSources ?? []))
        }
        await MemoryMoments.recordOutcomeReceipt(
            outcome: lastMomentOutcome,
            sessionId: sessionId,
            surface: surface,
            author: momentAuthor,
            slotsSpentToday: slotsSpentTodayIfKnown(),
            stagedProposalId: momentProposal?.id,
            turnId: turnId, occurredAt: origin?.occurredAt, failure: managerResult.report.failure
        )
        let staged = (momentProposal.map { [$0] } ?? []) + managerResult.proposals
        var observation = AdaptiveMemoryObservation(
            proposals: staged,
            extraction: adaptivePromotionEnabled?() == false && managerResult.report.failure == nil
                ? .init(candidates: [], semanticStatus: .skipped) : managerResult.report,
            momentOutcome: lastMomentOutcome,
            hygieneRejectedCount: managerResult.rejectedCount,
            savedCorrectionCount: managerResult.savedCorrectionCount,
            pendingCorrectionCount: managerResult.pendingCorrectionCount,
            failedCorrectionCount: managerResult.failedCorrectionCount
        )
        observation.noveltySkipReason = managerResult.noveltySkipReason
        // It answered: the same model is back, so what waited is asked now.
        if managerResult.report.semanticStatus == .succeeded { await askHeldMoments(memory: memory) }
        return observation
    }

    // MARK: - Held moments

    /// A turn whose enabled memory opportunities the model could not judge.
    struct HeldMoment: Codable {
        var at = Date()
        let sessionId, surface, user, asked, assistant: String
        var turnId, runId, messageId: String?
        var occurredAt: Date?
        var speaker: String?
        var standingAgent, factsEnabled, momentsEnabled: Bool?
        var failure: AfterTurnMemoryFailure?
        var humanName: String?
        var peerAuthority: Bool?
        var momentDeferredDay: String?
        var envelope: JSONValue?
        var sourceCheckpoint, elevatedSources: [String]?

        var origin: AfterTurnOrigin? {
            guard let messageId else { return nil }
            return AfterTurnOrigin(sessionId: sessionId, runId: runId, messageId: messageId,
                                   occurredAt: occurredAt, userMessage: asked)
        }
    }

    /// Held turns wait durably in `memory/moments_held.json` for the configured
    /// memory model, without discarding opportunities during an outage.
    static func heldPath(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        dataRoot.appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("moments_held.json")
    }

    static func readHeld(dataRoot: URL = PersistenceCore.defaultDataRoot()) throws -> [HeldMoment] {
        let path = heldPath(dataRoot: dataRoot)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try JSONDecoder().decode([HeldMoment].self, from: Data(contentsOf: path))
    }

    private func heldMoments() -> [HeldMoment]? {
        do { return try Self.readHeld() }
        catch {
            nativeLog("MemoryV2: held turns unreadable; preserved without mutation: %@", String(describing: error))
            return nil
        }
    }

    private func writeHeld(_ held: [HeldMoment]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: Self.heldPath().deletingLastPathComponent(), withIntermediateDirectories: true)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(held), to: Self.heldPath())
            return true
        } catch {
            nativeLog("MemoryV2 moments: held turns not written: %@", String(describing: error))
            return false
        }
    }

    /// The receipt word: "held" once it is on disk, and the failure's own
    /// word when it could not be written.
    private func holdMoment(_ turn: HeldMoment) -> String {
        guard let held = heldMoments() else { return MomentExtractionOutcome.failed.receiptOutcome }
        if let turnId = turn.turnId, held.contains(where: { $0.sessionId == turn.sessionId && $0.turnId == turnId }) { return "held" }
        return writeHeld(held + [turn]) ? "held" : MomentExtractionOutcome.failed.receiptOutcome
    }

    /// Reconsider held turns through the same manager and proposal gates.
    /// Disabled lanes stay held. Recovery never replays tools or doses affect.
    private func askHeldMoments(memory: SwiftNativeMemoryV2, quotaDeferredOnly: Bool = false) async {
        guard memoryManager != nil, var held = heldMoments(), !held.isEmpty else { return }
        let today = MemoryMoments.dayKey(Date())
        let batch = held.filter { !quotaDeferredOnly || ($0.momentDeferredDay != nil && $0.momentDeferredDay != today) }
        var reconsidered = 0
        for pending in batch {
            // At most one recovery interpretation before and one after a new
            // exchange. A busy day's backlog never becomes a provider burst.
            guard !Task.isCancelled, reconsidered < 1 else { return }
            guard let position = held.firstIndex(where: {
                $0.sessionId == pending.sessionId && $0.at == pending.at && $0.turnId == pending.turnId
            }) else { continue }
            var turn = held[position]
            let facts = (turn.factsEnabled ?? false) && (adaptivePromotionEnabled?() ?? true)
            let wantsMoment = (turn.momentsEnabled ?? true) && (momentsEnabled?() ?? true)
                && turn.momentDeferredDay != today
            let reserved = wantsMoment ? await reserveMomentSlot(memory: memory, now: Date()) : false
            if wantsMoment && !reserved {
                turn.momentDeferredDay = today
                held[position] = turn
                guard writeHeld(held) else { return }
            }
            guard facts || reserved else { continue }
            reconsidered += 1
            let isStandingAgent = turn.standingAgent == true
            let speaker = turn.speaker ?? (isStandingAgent ? "standing agent"
                : (Self.isAgentSeatUserMessage(turn.user) ? Self.bridgeSender(turn.user) : nil))
            let checkpoint = PeerDataTaint(restoring: turn.sourceCheckpoint ?? ["untrusted stored content"],
                                           elevated: turn.elevatedSources ?? [])
            let (result, proposal) = await PeerDataTaint.$current.withValue(checkpoint) {
                await ChatToolSessionContext.$envelope.withValue(TurnEnvelope.fromPersistedMetadata(turn.envelope)) {
                    let result = await runMemoryManager(speaker: speaker, memory: memory,
                        userMessage: turn.asked, assistantMessage: turn.assistant, sessionId: turn.sessionId,
                        surface: turn.surface, momentsAllowed: reserved, origin: turn.origin,
                        standingAgent: isStandingAgent,
                        factsAllowed: facts, recovery: true, humanName: turn.humanName, peerAuthority: turn.peerAuthority)
                    var proposal: ProposalRecord?
                    if result.report.semanticStatus == .succeeded, !Task.isCancelled {
                        lastMomentOutcome = reserved ? "unreported" : "disabled"
                        proposal = await stageMomentIfAny(
                            memory: memory, userMessage: turn.user, assistantMessage: turn.assistant,
                            sessionId: turn.sessionId, surface: turn.surface,
                            author: isStandingAgent || result.peerAuthority ? "peer" : "user",
                            outcome: result.moment, reserved: reserved,
                            friction: AfterTurnNoveltyGate.frictionSignal(userMessage: turn.user, assistantMessage: turn.assistant),
                            origin: turn.origin, turnId: turn.turnId)
                    }
                    return (result, proposal)
                }
            }
            let author = isStandingAgent || result.peerAuthority ? "peer" : "user"
            if let failure = result.report.failure {
                if reserved { releaseMomentSlot() }
                turn.failure = failure
                held.remove(at: position)
                held.append(turn)
                guard writeHeld(held) else { return }
                continue
            }
            guard !Task.isCancelled else {
                if reserved { releaseMomentSlot() }
                return
            }
            guard result.report.semanticStatus == .succeeded else {
                if reserved { releaseMomentSlot() }
                continue
            }
            if result.factsProcessed && !result.stagingFailed { turn.factsEnabled = false }
            if reserved && !["failed", "cancelled", "disabled"].contains(lastMomentOutcome) { turn.momentsEnabled = false }
            if turn.factsEnabled != true && turn.momentsEnabled == false { held.remove(at: position) }
            else {
                held.remove(at: position)
                held.append(turn)
            }
            guard writeHeld(held) else { return }
            await MemoryMoments.recordOutcomeReceipt(
                outcome: lastMomentOutcome == "disabled" ? "reconsidered" : lastMomentOutcome,
                sessionId: turn.sessionId, surface: turn.surface, author: author,
                slotsSpentToday: slotsSpentTodayIfKnown(), stagedProposalId: proposal?.id,
                turnId: turn.turnId, occurredAt: turn.occurredAt)
        }
    }

    // MARK: - The fact lane: the memory manager

    struct MemoryManagerOutcome {
        let proposals: [ProposalRecord]
        let report: AdaptiveExtractionReport
        let rejectedCount: Int
        var moment: MomentExtractionOutcome = .failed
        var noveltySkipReason: String?
        var savedCorrectionCount = 0
        var pendingCorrectionCount = 0
        var failedCorrectionCount = 0
        var stagingFailed = false
        var factsProcessed = false
        var peerAuthority = false
        var humanName: String?
    }

    /// One manager pass over one turn.
    ///
    /// The shape, in order: show it what is already known (so it can say "already
    /// covered" instead of re-minting), ask once, then gate what came back on
    /// confidence, shape, embedding near-duplication and the tombstone list.
    /// Every survivor stages for human review. Free-form model output cannot
    /// prove that an apparent fact or rule leaves identity untouched.
    private func runMemoryManager(
        speaker: String? = nil,
        memory: SwiftNativeMemoryV2,
        userMessage: String,
        assistantMessage: String,
        sessionId: String,
        surface: String,
        momentsAllowed: Bool,
        origin: AfterTurnOrigin?,
        standingAgent: Bool = false,
        factsAllowed: Bool = true,
        recovery: Bool = false,
        humanName: String? = nil,
        peerAuthority: Bool? = nil
    ) async -> MemoryManagerOutcome {
        func empty(_ status: MemorySemanticExtractionStatus) -> MemoryManagerOutcome {
            MemoryManagerOutcome(
                proposals: [],
                report: AdaptiveExtractionReport(candidates: [], semanticStatus: status),
                rejectedCount: 0,
                moment: status == .failed ? (Task.isCancelled ? .cancelled : .failed) : .unavailable
            )
        }
        guard let memoryManager else { return empty(.unavailable) }
        let user = origin?.userMessage ?? userMessage
        let assistant = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return empty(.emptyInput) }

        // What is already known about this exchange. `recordingUsage: false`:
        // reading the store to decide what to keep is not the agent USING a
        // memory, and use_count is the signal that vetoes eviction.
        let factsEnabled = factsAllowed && !assistant.isEmpty && (adaptivePromotionEnabled?() ?? true)
        let keepsMoments = momentsAllowed
        let context: AfterTurnContext?
        if !recovery, let origin, origin.sessionId == sessionId {
            context = await prepareInterpretation?(origin)
        } else { context = nil }
        let isPeer = peerAuthority ?? (speaker != nil || context?.event.sourceClass == .imported)
        let originalHumanName = humanName ?? personName?()
        guard factsEnabled || keepsMoments || context != nil else { return empty(.skipped) }
        // Phase 5A: nothing new worth keeping → no model call. The deferred
        // affect turn still closes, exactly as a failed call closes it.
        let priorUserTurns = context?.caring?.context.filter { $0.speaker == .person }.map(\.text) ?? []
        if !recovery, let reason = AfterTurnNoveltyGate.skipReason(userMessage: user, priorUserTurns: priorUserTurns) {
            if let context { await finishInterpretation?(context, nil, true) }
            var skipped = empty(.skipped)
            skipped.noveltySkipReason = reason
            return skipped
        }
        var existing: [MemoryManagerExistingMemory] = await {
            guard factsEnabled else { return [] }
            guard let response = try? await memory.recall(
                MemoryV2RecallRequest(text: "\(user)\n\(assistant)", topK: MemoryManagerLane.recallTopK),
                recordingUsage: false
            ) else { return [] }
            return response.scored.map {
                MemoryManagerExistingMemory(id: $0.record.id, content: $0.record.text,
                    correctionSubject: MemoryMoments.metadataString($0.record.extras, "correction_subject"),
                    kind: $0.record.memoryKind)
            }
        }()
        if factsEnabled, let corrections = try? await memory.listMemory(kind: "correction") {
            for record in corrections.filter({ ($0.status ?? "active") == "active" })
                .sorted(by: { ($0.createdAt ?? "") > ($1.createdAt ?? "") }).prefix(24) {
                let subject = MemoryMoments.metadataString(record.extras, "correction_subject")
                let known = MemoryManagerExistingMemory(id: record.id, content: record.text,
                                                        correctionSubject: subject, kind: record.memoryKind)
                if let index = existing.firstIndex(where: { $0.id == record.id }) { existing[index] = known }
                else { existing.append(known) }
            }
        }
        // What is already waiting on the person. Moments are a different lane
        // and a different card; they are not facts to dedupe against.
        // Shown WITH their ids (2026-09-11, found driving it: a correction of a
        // statement that was itself still pending stacked up as a second pending
        // row instead of replacing the first). An update naming a pending id
        // retires that row and stages the correction in its place.
        let pendingRows: [ProposalRecord] = await {
            guard factsEnabled else { return [] }
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

        let interpretation: AfterTurnInterpretation?
        do {
            interpretation = try await memoryManager.interpret(MemoryManagerRequest(
                userMessage: user,
                assistantMessage: assistant,
                existing: existing,
                pending: pendingPrompt,
                personName: speaker ?? originalHumanName, standingAgent: standingAgent
            ), context: context, factsEnabled: factsEnabled, momentsEnabled: keepsMoments)
        } catch {
            if let context { await finishInterpretation?(context, nil, false) }
            let reason: AfterTurnMemoryFailure.Reason
            if Task.isCancelled || error is CancellationError { reason = .cancelled }
            else {
                switch error as? AfterTurnInterpretationFailure {
                case .authentication: reason = .authExpired
                case .deadline: reason = .deadline
                case .cancellation: reason = .cancelled
                case .envelope: reason = .invalidJSON
                case .caring: reason = .invalidCaring
                case .affect: reason = .invalidAffect
                case .memories: reason = .invalidMemories
                case .moment: reason = .invalidMoment
                default: reason = .provider
                }
            }
            let failure = (error as? AfterTurnMemoryFailure) ?? AfterTurnMemoryFailure(
                reason: reason,
                recovery: "Check the selected memory model in Settings; held turns are reconsidered after its next successful answer.",
                model: nil, surface: surface)
            return MemoryManagerOutcome(proposals: [], report: .init(candidates: [],
                semanticStatus: failure.reason == .deadline ? .timedOut : .failed, failure: failure),
                rejectedCount: 0, moment: failure.reason == .cancelled ? .cancelled : .failed,
                peerAuthority: isPeer, humanName: originalHumanName)
        }
        if let context { await finishInterpretation?(context, Task.isCancelled ? nil : interpretation, false) }
        guard !Task.isCancelled, let interpretation else {
            let failure = AfterTurnMemoryFailure(reason: Task.isCancelled ? .cancelled : .missingSections,
                recovery: "Check the selected memory model in Settings; held turns are reconsidered after its next successful answer.",
                model: nil, surface: surface)
            return MemoryManagerOutcome(proposals: [], report: .init(candidates: [],
                semanticStatus: .failed, failure: failure), rejectedCount: 0,
                moment: Task.isCancelled ? .cancelled : .failed, peerAuthority: isPeer, humanName: originalHumanName)
        }
        let factsProcessed = factsEnabled && (adaptivePromotionEnabled?() ?? true)
        let decisions = factsProcessed ? interpretation.memories : []

        var staged: [ProposalRecord] = []
        var accepted: [AdaptiveCandidate] = []
        var rejected = 0
        var pendingCorrections = 0
        var failedCorrections = 0
        var stagingFailed = false
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
            let isCorrection = decision.kind == "correction"
            if isCorrection, origin?.occurredAt == nil || origin?.sessionId != sessionId {
                rejected += 1
                failedCorrections += 1
                nativeLog("MemoryV2: standing correction not saved: originating turn timestamp unavailable")
                continue
            }
            if isCorrection, let updateTarget,
               updateTarget.kind != "correction"
                || (updateTarget.correctionSubject != nil && updateTarget.correctionSubject != decision.correctionSubject) {
                rejected += 1
                continue
            }
            if isCorrection, let old = supersededPending {
                guard MemoryMoments.metadataString(old.metadata, "kind") == "correction",
                      MemoryMoments.metadataString(old.metadata, "correction_subject") == decision.correctionSubject,
                      let timestamp = MemoryMoments.metadataString(old.metadata, "observed_at"),
                      let priorDate = MemoryRecallScoring.parseTimestamp(timestamp),
                      let sourceDate = origin?.occurredAt, priorDate <= sourceDate else {
                    rejected += 1
                    failedCorrections += 1
                    nativeLog("MemoryV2: standing correction not saved: pending rule chronology or subject unavailable or newer")
                    continue
                }
            }
            let refusal = isCorrection
                ? MemoryManagerLane.correctionRejectionReason(decision, userMessage: user,
                    isPeer: isPeer, personName: originalHumanName)
                : MemoryManagerLane.statementRejectionReason(decision.statement, userMessage: user, assistantMessage: assistant)
            if refusal != nil {
                rejected += 1
                continue
            }
            if isCorrection, existing.contains(where: {
                $0.correctionSubject == decision.correctionSubject
                    && MemoryManagerLane.contentFingerprint($0.content) == MemoryManagerLane.contentFingerprint(decision.statement)
            }) { continue }
            // The row an update REPLACES is not competition for it: screening a
            // correction against the statement it corrects rejects exactly the
            // work the manager was asked to do (2026-09-11 audit, finding 4).
            // Everything else kept or pending still screens.
            let replacedContent = updateTarget?.content ?? supersededPending?.content
            let screened: [String] = replacedContent.map { target in
                comparisons.filter { $0 != target }
            } ?? comparisons
            if !isCorrection, await Self.isNearDuplicate(
                decision.statement, of: screened, memory: memory
            ) {
                rejected += 1
                continue
            }
            do {
                try Task.checkCancellation()
                if try await memory.isRejected(content: decision.statement) {
                    rejected += 1
                    continue
                }
                let proposal = try await memory.propose(
                    content: decision.statement,
                    source: "\(isCorrection ? "standing-correction" : MemoryManagerLane.sourcePrefix):\(sessionId)",
                    confidence: decision.confidence,
                    kind: decision.kind,
                    supportingSessionIDs: [sessionId],
                    recurrenceCount: 1,
                    extraMetadata: MemoryManagerLane.metadata(
                        for: decision, sessionId: sessionId, surface: surface,
                        updateTarget: updateTarget,
                        observedAt: origin?.occurredAt
                    )
                )
                staged.append(proposal)
                comparisons.append(decision.statement)
                if let old = supersededPending, old.id != proposal.id {
                    _ = try? await memory.supersedeProposal(id: old.id, by: proposal.id)
                }
                let candidate = AdaptiveCandidate(
                    content: decision.statement,
                    score: decision.confidence,
                    kind: decision.kind
                )
                accepted.append(candidate)
                if isCorrection {
                    pendingCorrections += 1
                }
            } catch {
                stagingFailed = true
                if isCorrection { failedCorrections += 1 }
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
            rejectedCount: rejected,
            moment: interpretation.moment.map(MomentExtractionOutcome.candidate) ?? .abstained,
            savedCorrectionCount: 0,
            pendingCorrectionCount: pendingCorrections,
            failedCorrectionCount: failedCorrections,
            stagingFailed: stagingFailed,
            factsProcessed: factsProcessed,
            peerAuthority: isPeer,
            humanName: originalHumanName
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
        if others.contains(where: {
            fold($0) == needle && MemorySemanticDuplicateGuard.sameQuantityAndNegation(statement, $0)
        }) { return true }
        guard let vectors = try? await memory.embedForDerivedContext([statement] + others),
              vectors.count == others.count + 1,
              let query = vectors.first, !query.isEmpty else {
            return false
        }
        for (other, vector) in zip(others, vectors.dropFirst()) {
            guard vector.count == query.count,
                  MemorySemanticDuplicateGuard.sameQuantityAndNegation(statement, other) else { continue }
            var dot: Float = 0
            for i in 0..<query.count { dot += query[i] * vector[i] }
            if Double(dot) >= MemoryManagerLane.duplicateSimilarity { return true }
        }
        return false
    }

    // MARK: - The moments lane

    /// The moment section of the shared interpretation stages at most one proposal.
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
        outcome: MomentExtractionOutcome,
        reserved: Bool,
        friction: String? = nil,
        origin: AfterTurnOrigin? = nil,
        turnId: String? = nil,
        now: Date = Date()
    ) async -> ProposalRecord? {
        guard reserved else { return nil }
        var staged = false
        defer { if !staged { releaseMomentSlot() } }
        guard !Task.isCancelled else { lastMomentOutcome = "cancelled"; return nil }
        // The switch comes FIRST, ahead of the extractor and the day-slot
        // reservation: off means nothing is read, nothing is reserved and no
        // model is called — the same "not installed" shape her hour uses.
        if let momentsEnabled, !momentsEnabled() {
            lastMomentOutcome = "disabled"
            return nil
        }
        // RESERVE FIRST. An actor is reentrant across `await`, so a
        // check-then-await-then-increment shape lets every concurrent turn read
        // the same stale quota and all of them stage — the cap would hold only
        // when turns happened to be serial. The slot is taken synchronously
        // here and released on every path that does not stage.
        // The outcome is now the EXTRACTOR'S word, not a placeholder set before
        // the call (lane5 finding 3): "abstained" means the model read the hour
        // and said there was no moment in it; "extractionFailed" means no answer
        // was obtained. The ledger could not tell those apart while both wrote
        // `none`.
        lastMomentOutcome = "unreported"

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
            try Task.checkCancellation()
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
                ).merging(friction.map { ["friction": .string($0)] } ?? [:]) { current, _ in current }
                    .merging((origin?.occurredAt).map { ["observed_at": .string($0.ISO8601Format())] } ?? [:]) { current, _ in current }
                    .merging(turnId.map { ["turn_id": .string($0)] } ?? [:]) { current, _ in current }
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

    /// True when the turn's user-seat text was machine-tagged as coming from
    /// another agent over a local bridge. The prefix is affixed at the single
    /// bridge entry points (ClaudeBridge / codex bridge), same convention
    /// StructuredChat's trusted-bridge-envelope detection relies on.
    static func isAgentSeatUserMessage(_ text: String) -> Bool {
        if PeerTurnEffectPolicy.peerName(inTurnHeader: text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            return true
        }
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
        if let peer = PeerTurnEffectPolicy.peerName(inTurnHeader: t) { return peer }
        guard let match = t.range(of: #"^\[from: ([^\],]{1,64}), via bridge\]"#, options: .regularExpression) else { return nil }
        let inside = t[match].dropFirst("[from: ".count)
        let name = inside.prefix { $0 != "," }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = name.first else { return nil }
        return String(first).uppercased() + name.dropFirst()
    }
}

import Transcripts
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
import CognitiveSubstrate
import ChatTurnContracts
import TurnTrace

// Blueprint: | `MemoryV2+AdaptivePromoter.swift` | `AdaptiveMemoryPromoter` actor and live interpretation; meaning before apply, trusted fact acceptance by operation identity, learned complete-no-op deferral and labels under the judging model |

// Only the shared interpretation judges facts and care movements from the exchange and known memories.
// Facts from the owner, trusted peers or her reply are kept; other facts await review.

/// The journal owns unfinished turns; the retired held file is import-only.
public actor AdaptiveMemoryPromoter {
    public static let shared = AdaptiveMemoryPromoter()

    var memory: SwiftNativeMemoryV2?
    /// A nil memory manager stages no facts.
    var memoryManager: (any MemoryManaging)?
    /// The person's configured name, read fresh so a rename shows up.
    var personName: (@Sendable () -> String?)? = nil
    /// The fold. The String identifies the recorded moment; true when every
    /// piece of her landed.
    var finishInterpretation: (@Sendable (AfterTurnContext, AfterTurnInterpretation?, String?) async -> Bool)?
    /// The door her lived moments come in by (`LivedMomentDoor`), installed by
    /// the cognition runtime. Without a recorded row nothing is applied.
    var door: LivedMomentDoor?
    /// Moments recorded by this process whose interpretation is queued or
    /// running on the live path; the owed-moment drain leaves them alone.
    var inFlightMoments: Set<String> = []
    /// Accepted transcript settlements, including ones still reaching the door.
    /// Sleep joins these recordings independently of the interpretation tail.
    private var owedRecordings: [UUID: Task<String?, Never>] = [:]
    /// The owed-row retry cursor: attempts, when the row is next due, and
    /// when it was last tried (RAM: a relaunch starts every row due).
    var owedRetry: [String: (attempts: Int, notBefore: Date, lastTried: Date)] = [:]
    /// The one scheduled idle drain pass.
    var owedDrainTimer: (id: UUID, deadline: Date, task: Task<Void, Never>)?
    /// Live observations waiting on or running under the shared tail.
    var pendingLiveObservations = 0
    var heldImported = false
    var observationTail: Task<AdaptiveMemoryObservation, Never>?
    /// Every observation or drain still running (the tail and the ones it waits
    /// on), so sleep can stop them all.
    var liveOperations: [UUID: Task<AdaptiveMemoryObservation, Never>] = [:]
    var observationID: UUID?
    var stopped = false
    var owedDrain: Task<AdaptiveMemoryObservation, Never>?
    var heldDrainIsIdle: (@Sendable () async -> Bool)?
    /// Injected fact-promotion policy; no configured owner means enabled.
    var adaptivePromotionEnabled: (@Sendable () -> Bool)?

    public init(
        memory: SwiftNativeMemoryV2? = nil,
        memoryManager: (any MemoryManaging)? = nil,
        adaptivePromotionEnabled: (@Sendable () -> Bool)? = nil
    ) {
        self.memory = memory
        self.memoryManager = memoryManager
        self.adaptivePromotionEnabled = adaptivePromotionEnabled
    }

    public func configure(
        memory: SwiftNativeMemoryV2?,
        memoryManager: (any MemoryManaging)? = nil,
        adaptivePromotionEnabled: (@Sendable () -> Bool)? = nil,
        personName: (@Sendable () -> String?)? = nil
    ) {
        guard !stopped else { return }
        self.memory = memory
        if let memoryManager { self.memoryManager = memoryManager }
        if let personName { self.personName = personName }
        if let adaptivePromotionEnabled {
            self.adaptivePromotionEnabled = adaptivePromotionEnabled
        }
    }

    public func observeTurnWithReport(
        userMessage: String,
        assistantMessage: String,
        sessionId: String,
        surface: String = "chat",
        standingAgentName: String? = nil,
        turnId: String? = nil
    ) async -> AdaptiveMemoryObservation {
        guard !stopped else {
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .skipped))
        }
        let origin = AfterTurnSource.origin
        let previous = observationTail
        let id = UUID()
        observationID = id
        // Live work waiting or running: recovery admits no next row meanwhile.
        pendingLiveObservations += 1
        let operation = Task {
            defer {
                self.pendingLiveObservations -= 1
                self.liveOperations[id] = nil
                if observationID == id { observationTail = nil; observationID = nil }
            }
            _ = await previous?.value
            return await self.interpretAndObserve(userMessage: userMessage,
                assistantMessage: assistantMessage,
                sessionId: sessionId, surface: surface, origin: origin,
                standingAgentName: standingAgentName, turnId: turnId ?? origin?.runId)
        }
        observationTail = operation
        liveOperations[id] = operation
        let observation = await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
        if !stopped, let heldDrainIsIdle { await drainHeldAtIdle(isIdle: heldDrainIsIdle) }
        return observation
    }

    /// Record accepted transcript settlements as owed under the turn's provenance,
    /// before earlier promotions finish, even during sleep. Her own work is not a moment.
    @discardableResult
    public func recordOwedTurn(
        userMessage: String,
        assistantMessage: String,
        sessionId: String,
        surface: String = "chat",
        standingAgentName: String? = nil,
        turnId: String? = nil
    ) async -> String? {
        guard let door else { return nil }
        let origin = AfterTurnSource.origin
        let turn = CognitiveMomentTurn(
            sessionId: sessionId, surface: surface, user: userMessage,
            asked: origin?.userMessage ?? userMessage, assistant: assistantMessage,
            turnId: turnId ?? origin?.runId, runId: origin?.runId, messageId: origin?.messageId,
            occurredAt: origin?.occurredAt, took: origin?.took, standingAgentName: standingAgentName,
            envelope: TurnEnvelope.current(surface: surface).persistedMetadata(),
            sourceCheckpoint: MemoryDataProvenance.sources(in: MemoryDataProvenance.stamping(nil)),
            elevatedSources: PeerDataTaint.current?.elevatedSources ?? [])
        let recordingID = UUID()
        let recording = Task<String?, Never> {
            defer { owedRecordings[recordingID] = nil }
            guard await conversationKind(sessionId)?.isOwnWork != true else { return nil }
            // Everything the door needs is in the captured turn; settlement
            // does not inherit task locals or the caller's cancellation.
            let id = await settle { await door.recordOwed(turn) }
            if let id, !stopped { inFlightMoments.insert(id) }
            return id
        }
        owedRecordings[recordingID] = recording
        return await recording.value
    }

    /// The recorded moment this live promotion is, when the door recorded it.
    private func liveMomentID(sessionId: String, origin: AfterTurnOrigin?) -> String? {
        guard door != nil, let origin else { return nil }
        let id = CognitiveLivedMoment.turnID(sessionId: sessionId, messageId: origin.messageId)
        return inFlightMoments.contains(id) ? id : nil
    }

    /// Stop producing and cancel interpretations, joining the fold in flight.
    /// Settled turns still record owed; returned judgments are already meant.
    public func sleep() async {
        stopped = true
        heldDrainIsIdle = nil
        owedDrainTimer?.task.cancel()
        owedDrainTimer = nil
        for operation in liveOperations.values { operation.cancel() }
        let recordings = Array(owedRecordings.values)
        for recording in recordings { _ = await recording.value }
        _ = await observationTail?.value
    }

    /// No new turns or passive recovery after stop. Already accepted turn
    /// interpretation and its canonical writes keep their original result.
    public func shutdown() async {
        stopped = true
        heldDrainIsIdle = nil
        let recordings = Array(owedRecordings.values)
        for recording in recordings { _ = await recording.value }
        _ = await observationTail?.value
    }

    public func configureInterpretation(
        isIdle: @escaping @Sendable () async -> Bool,
        finish: @escaping @Sendable (AfterTurnContext, AfterTurnInterpretation?, String?) async -> Bool,
        door: LivedMomentDoor? = nil
    ) {
        self.door = door
        heldDrainIsIdle = isIdle
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

    func conversationKind(_ sessionID: String) async -> ChatThreadKind? {
        guard let memory, let root = await memory.surpriseDataRoot() else { return nil }
        return SessionConversation.kind(sessionID, dataRoot: root, includingArchived: true)
    }

    private func interpretAndObserve(userMessage: String, assistantMessage: String,
                                     sessionId: String,
                                     surface: String, origin: AfterTurnOrigin?,
                                     standingAgentName: String?, turnId: String?) async -> AdaptiveMemoryObservation {
        let skipped = AdaptiveMemoryObservation(proposals: [], extraction: .init(
            candidates: [], semanticStatus: .skipped
        ))
        let momentID = liveMomentID(sessionId: sessionId, origin: origin)
        defer { if let momentID { inFlightMoments.remove(momentID) } }
        // ResidentWake's dedicated session carries app-authored arrivals.
        guard let momentID, await conversationKind(sessionId)?.isOwnWork != true,
              !Task.isCancelled, let memory else { return skipped }
        let standingAgent = standingAgentName != nil
        let peerSeat = Self.isAgentSeatUserMessage(userMessage)
        let peerSpeaker = standingAgent ? (standingAgentName ?? "standing agent")
            : (peerSeat ? Self.bridgeSender(userMessage) : nil)
        var observation = await runMemoryManager(
            speaker: peerSpeaker, memory: memory, userMessage: userMessage,
            assistantMessage: assistantMessage, sessionId: sessionId, surface: surface,
            origin: origin, turnId: turnId, standingAgent: standingAgent,
            momentID: momentID)
        if adaptivePromotionEnabled?() == false && observation.extraction.failure == nil {
            observation.extraction = .init(candidates: [], semanticStatus: .skipped)
        }
        return observation
    }

    /// The proposal metadata key carrying a fact decision's operation identity
    /// (life | moment | ordinal).
    static let momentOperationKey = "moment_op"

    public static func encodedMeaning(_ interpretation: AfterTurnInterpretation) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(interpretation) else { return nil }
        return try? JSONValue.parse(data)
    }

    public static func decodedMeaning(_ value: JSONValue) -> AfterTurnInterpretation? {
        guard let data = try? value.serializedData(pretty: false) else { return nil }
        return try? JSONDecoder().decode(AfterTurnInterpretation.self, from: data)
    }

    /// mind.why, the "interpretation" lane: what became of a turn's
    /// interpretation (deferred, judged in a batch, left owed), with
    /// the prediction and its standing.
    static func whyInterpretation(turn: String, session: String, surface: String,
                                  route: ChatToolSessionContext.ReplyRoute?, outcome: String,
                                  check: AfterTurnMemorySurprise?) {
        var fields: [String: JSONValue] = ["lane": .string("interpretation"), "outcome": .string(outcome)]
        if let check {
            fields["prediction"] = .string(check.verdict.rawValue)
            fields["evidence"] = .string(check.reason)
            fields["standing"] = .bool(check.standing == true)
            fields["lower"] = .double(check.lowerBound ?? 0)
            fields["bar"] = .double(check.costBar ?? 1)
            fields["tries"] = .int(Int64(check.tries ?? 0))
            fields["hits"] = .int(Int64(check.hits ?? 0))
        }
        TurnTraceBus.fire(TurnTraceEvent(turnId: turn, kind: "mind.why", sessionId: session, surface: surface,
            destinationId: route?.destinationId, threadId: route?.threadId, payload: .object(fields)))
    }
}

import Transcripts
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
import Experiences
import CognitiveSubstrate
import ChatTurnContracts
import TurnTrace
import Senses

// Blueprint: | `MemoryV2+AdaptivePromoter.swift` | `AdaptiveMemoryPromoter`: live interpretation and provenance-bound settlement |

// Only the shared interpretation judges facts and care movements from the exchange and known memories. Facts from the owner, trusted peers or the agent's
// reply are kept; other facts await review.

/// The journal owns unfinished turns.
public actor AdaptiveMemoryPromoter {
    public static let shared = AdaptiveMemoryPromoter()

    var memory: SwiftNativeMemoryV2?
    /// Without a configured manager, stage no facts.
    var memoryManager: (any MemoryManaging)?
    /// The person's configured name, read fresh so a rename shows up.
    var personName: (@Sendable () throws -> String?)? = nil
    /// Report fold success only when every piece of the recorded moment lands.
    var finishInterpretation: (@Sendable (AfterTurnContext, AfterTurnInterpretation?, String?) async -> Bool)?
    /// The door the agent's lived moments come in by (`LivedMomentDoor`), installed by the cognition runtime. Without a recorded row nothing is applied.
    var door: LivedMomentDoor?
    /// Moments recorded by this process whose interpretation is queued or running on the live path; the owed-moment drain leaves them alone.
    var inFlightMoments: Set<String> = []
    /// Accepted transcript settlements, including ones still reaching the door. Sleep joins these recordings independently of the interpretation tail.
    private var owedRecordings: [UUID: Task<String?, Never>] = [:]
    var recoveries: [String: RecoveryCheckpoint] = [:]
    var pendingLiveObservations = 0
    var observationTail: Task<AdaptiveMemoryObservation, Never>?
    /// Every observation or drain still running (the tail and the ones it waits on), so sleep can stop them all.
    var liveOperations: [UUID: Task<AdaptiveMemoryObservation, Never>] = [:]
    var observationID: UUID?
    var stopped = false
    var owedDrain: Task<AdaptiveMemoryObservation, Never>?
    var heldDrainIsIdle: (@Sendable () async -> Bool)?
    /// Injected fact-promotion policy; no configured owner means enabled.
    var adaptivePromotionEnabled: (@Sendable () throws -> Bool)?

    public init(
        memory: SwiftNativeMemoryV2? = nil,
        memoryManager: (any MemoryManaging)? = nil,
        adaptivePromotionEnabled: (@Sendable () throws -> Bool)? = nil
    ) {
        self.memory = memory
        self.memoryManager = memoryManager
        self.adaptivePromotionEnabled = adaptivePromotionEnabled
    }

    public func configure(
        memory: SwiftNativeMemoryV2?,
        memoryManager: (any MemoryManaging)? = nil,
        adaptivePromotionEnabled: (@Sendable () throws -> Bool)? = nil,
        personName: (@Sendable () throws -> String?)? = nil
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
        turn: Turn,
        senseReads: SenseTurnReads?
    ) async -> AdaptiveMemoryObservation {
        guard !stopped else {
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .skipped))
        }
        let origin = turn.afterTurnOrigin
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
                standingAgentName: standingAgentName, turnId: turn.id, turn: turn, senseReads: senseReads)
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

    /// Record accepted transcript settlements as owed under the turn's provenance, before earlier promotions finish, even during sleep. Only a care-bearing
    /// wake with a reply is a moment among the agent's own work.
    @discardableResult
    public func recordOwedTurn(
        userMessage: String,
        assistantMessage: String,
        sessionId: String,
        surface: String = "chat",
        standingAgentName: String? = nil,
        repliedAt: Date? = nil,
        turn: Turn
    ) async -> String? {
        guard let door else { return nil }
        let origin = turn.afterTurnOrigin
        let steer = PeerDataTaint.carried(turn: turn, peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: turn.envelope?.verifiedUserId)
        let momentTurn = CognitiveMomentTurn(
            sessionId: sessionId, surface: surface, user: userMessage,
            asked: origin?.userMessage ?? userMessage, assistant: assistantMessage,
            turnId: turn.id, runId: turn.run, messageId: origin?.messageId,
            occurredAt: origin?.occurredAt, repliedAt: repliedAt, took: origin?.took, standingAgentName: standingAgentName,
            envelope: TurnEnvelope.current(turn: turn, surface: surface).persistedMetadata(),
            elevatedSources: steer.elevated, originPrincipal: turn.originPrincipal,
            carriedSources: steer.sources, careWakes: origin?.careWakes)
        let recordingID = UUID()
        let recording = Task<String?, Never> {
            defer { owedRecordings[recordingID] = nil }
            let ownWork = await conversationKind(sessionId)?.isOwnWork == true
            guard !ownWork || momentTurn.isCareWake else { return nil }
            // Everything the door needs is in the captured turn; settlement does not inherit task locals or the caller's cancellation.
            let id = await settle { await door.recordOwed(momentTurn) }
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

    /// Stop producing and cancel interpretations, joining the fold in flight. Settled turns still record owed; returned judgments are already meant.
    public func sleep() async {
        stopped = true
        heldDrainIsIdle = nil
        for operation in liveOperations.values { operation.cancel() }
        let recordings = Array(owedRecordings.values)
        for recording in recordings { _ = await recording.value }
        _ = await observationTail?.value
    }

    /// No new turns or passive recovery after stop. Already accepted turn interpretation and its canonical writes keep their original result.
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

    public func relevantRecallIDs(query: String, candidates: [MemoryManagerExistingMemory], generation: String? = nil,
        topK: Int? = nil, turn: Turn? = nil) async throws -> Set<String> {
        guard let memoryManager else {
            throw MemoryV2Error.underlying("Recall relevance is unavailable. Configure the selected memory model in Settings, then retry this query.")
        }
        switch await memoryManager.relevantRecallIDs(query: query, candidates: candidates, generation: generation, topK: topK, turn: turn) {
        case .success(let ids): return ids
        case .failure(let failure):
            throw MemoryV2Error.underlying("""
                Recall relevance could not be checked (\(failure.reason.rawValue)). \(failure.recovery) Nothing was returned as a memory answer.
                """)
        }
    }

    func conversationKind(_ sessionID: String) async -> ChatThreadKind? {
        guard let memory, let root = await memory.surpriseDataRoot() else { return nil }
        return SessionConversation.kind(sessionID, dataRoot: root, includingArchived: true)
    }

    private func interpretAndObserve(userMessage: String, assistantMessage: String,
                                     sessionId: String,
                                     surface: String, origin: AfterTurnOrigin?,
                                     standingAgentName: String?, turnId: String?, turn: Turn,
                                     senseReads: SenseTurnReads?) async -> AdaptiveMemoryObservation {
        let skipped = AdaptiveMemoryObservation(proposals: [], extraction: .init(
            candidates: [], semanticStatus: .skipped
        ))
        let momentID = liveMomentID(sessionId: sessionId, origin: origin)
        defer { if let momentID { inFlightMoments.remove(momentID) } }
        guard let momentID,
              !Task.isCancelled, let memory else { return skipped }
        let standingAgent = standingAgentName != nil
        let peerSeat = Self.isAgentSeatUserMessage(userMessage)
        let peerSpeaker = standingAgent ? (standingAgentName ?? "standing agent")
            : (peerSeat ? Self.bridgeSender(userMessage) : nil)
        let observation = await runMemoryManager(
            speaker: peerSpeaker, memory: memory, userMessage: userMessage,
            assistantMessage: assistantMessage, sessionId: sessionId, surface: surface,
            origin: origin, turnId: turnId, standingAgent: standingAgent,
            momentID: momentID, turn: turn, senseReads: senseReads)
        // The fact owner checks authority before interpretation and commit. A later policy read cannot erase the result of effects already saved.
        return observation
    }

    func unavailablePromotionPolicy(_ error: Error, surface: String, momentID: String, basis: OwedBasis?) async -> AdaptiveMemoryObservation {
        let cause = error.localizedDescription
        if !Self.isCancellation(error) { await waitForChange(momentID, since: basis, cause: .trust, words: cause) }
        await RepairOwed.owe(door?.dataRoot ?? PersistenceCore.defaultDataRoot(),
            id: "trust-policy:adaptive-promotion", kind: .run,
            operation: "memory.promotion.authority", owner: "Trust policy", words: cause,
            nextCall: ToolFailureError.call("app", ["action": .string("doctor.run")])).value
        return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .failed,
            failure: AfterTurnMemoryFailure(reason: .trustUnavailable, recovery: cause, model: nil, surface: surface)))
    }

    func promotionPolicyEnabled() async throws -> Bool {
        guard let adaptivePromotionEnabled else { return true }
        let enabled = try adaptivePromotionEnabled()
        let root = door?.dataRoot ?? PersistenceCore.defaultDataRoot()
        await RepairOwed.settle(root, operation: "memory.promotion.authority",
            evidence: .init(source: "trust", id: SwiftNativeTrustCenter.policyURL(dataRoot: root).path)).value
        return enabled
    }

    /// Use life, moment and ordinal as the fact decision's operation identity.
    static let momentOperationKey = "moment_op"

    public static func encodedMeaning(_ interpretation: AfterTurnInterpretation) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(interpretation) else { return nil }
        return try? JSONValue.parse(data)
    }

    public static func decodedMeaning(_ value: JSONValue) -> AfterTurnInterpretation? {
        guard let data = try? value.serializedData(pretty: false) else { return nil }
        return try? JSONDecoder().decode(AfterTurnInterpretation.self, from: data)
    }

    /// Expose interpretation outcomes with their prediction and standing through mind.why.
    static func whyInterpretation(turn: String, session: String, surface: String,
                                  route: TurnEnvelope.DeliveryRoute?, outcome: String,
                                  check: AfterTurnMemorySurprise?, heldTurn: Turn?) {
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
            destinationId: route?.destinationId, threadId: route?.threadId, payload: .object(fields), turn: heldTurn))
    }
}

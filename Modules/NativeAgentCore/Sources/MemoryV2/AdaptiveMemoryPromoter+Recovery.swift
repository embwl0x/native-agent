import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import CognitiveSubstrate
import ChatTurnContracts
import TurnTrace
import Transcripts
import GRDB
import NativeAgentShared
// Blueprint: | `AdaptiveMemoryPromoter+Recovery.swift` | `AdaptiveMemoryPromoter`: bounded owed-turn recovery with recorded provenance |

extension AdaptiveMemoryPromoter {
    /// What an owed attempt depends on, read before the attempt starts: the judging route, turns held, and answers on that route.
    struct OwedBasis: Equatable, Sendable {
        let route: String?
        let held: Int
        let answered: Int
    }

    /// A failed row is retried only once its basis has changed since the attempt began.
    struct OwedDependence: Sendable {
        let basis: OwedBasis
        /// A failed call waits for the provider to answer on its route; any other failure waits for another held turn.
        let onAnswer: Bool
        let state: CognitiveMomentState

        func changed(to now: OwedBasis, state current: CognitiveMomentState) -> Bool {
            now.route != basis.route || current != state || (onAnswer ? now.answered != basis.answered : now.held != basis.held)
        }
    }

    struct OwedAttempt: Sendable {
        /// A batch reply skipped this row: its next judgment is a batch of one, and a second skip lets it go.
        var alone = false
        /// Nil while the row is due now.
        var failedUnder: OwedDependence?
        var lastTried = Date()
    }

    /// How many turns are owed to the agent (recorded, not yet lived) in this data root's journal; nil when its door or journal read is unavailable.
    public func owedMomentCount(dataRoot: URL) async -> Int? {
        guard let door, door.dataRoot.standardizedFileURL == dataRoot.standardizedFileURL else { return nil }
        return await door.unlived()?.count
    }

    public func drainHeldAtIdle(isIdle: @escaping @Sendable () async -> Bool) async {
        guard let door else { return }
        await drainOwedRows(door: door, isIdle: isIdle, passes: 1)
    }

    /// At wake, recover queued observations before unfinished moments; refold saved meanings without another model call and bound fresh judgments.
    public func drainOwedMomentsAtWake() async {
        guard let door else { return }
        await drainOwedRows(door: door, isIdle: nil, passes: 8)
    }

    /// Before the dream reads the day, drain due moments from this root in batches while yielding to live work.
    public func drainOwedAtNight(dataRoot: URL) async {
        guard let door, door.dataRoot.standardizedFileURL == dataRoot.standardizedFileURL else { return }
        await drainOwedRows(door: door, isIdle: heldDrainIsIdle, passes: .max, joining: true)
    }

    /// Recovery shares the live tail and yields between passes as soon as live work arrives. A pass folds one meaning or judges up to four rows.
    private func drainOwedRows(door: LivedMomentDoor, isIdle: (@Sendable () async -> Bool)?,
                               passes: Int, joining: Bool = false) async {
        // Night is a barrier before the dream reads the agent's day. Join a shared flight without taking its ownership, then continue through this owner.
        while let running = owedDrain {
            guard joining else { return }
            _ = await running.value
            guard !Task.isCancelled else { return }
        }
        guard !stopped, !Task.isCancelled else { return }
        let previous = observationTail
        let id = UUID()
        observationID = id
        let operation = Task {
            defer {
                self.owedDrain = nil
                self.liveOperations[id] = nil
                if observationID == id { observationTail = nil; observationID = nil }
            }
            _ = await previous?.value
            var nextDue: Date?
            for _ in 0..<passes {
                guard !stopped, !Task.isCancelled, let memory else { break }
                let idle = await isIdle?() ?? true
                guard idle, pendingLiveObservations == 0 else { nextDue = Date(); break }
                let pass = await askOwedMoments(memory: memory, door: door)
                nextDue = pass.nextDue
                if !pass.processed { break }
            }
            scheduleOwedDrain(nextDue: nextDue)
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .skipped))
        }
        observationTail = operation
        liveOperations[id] = operation
        owedDrain = operation
        // Only the caller that starts this flight cancels it. A night caller joining somebody else's flight above never cancels shared work.
        _ = await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Replay under recorded provenance: fold one meaning or judge one bounded batch. Meaning is saved before folding; already-lived pieces remain inert.
    @discardableResult
    private func askOwedMoments(memory: SwiftNativeMemoryV2, door: LivedMomentDoor) async -> (nextDue: Date?, processed: Bool) {
        guard let memoryManager else { return (nil, false) }
        // A failed row waits until what it depended on changes; the least recently tried due row goes first so one failure cannot starve its siblings.
        let now = Date()
        guard let unlived = await door.unlived() else { return (nil, false) }
        let rows = unlived.filter { !inFlightMoments.contains($0.id) }
        let route = await memoryManager.judgmentRouteKey()
        let basis = OwedBasis(route: route, held: heldTurns, answered: answeredCalls[route, default: 0])
        let due = rows.filter { row in
            guard let failed = owedRetry[row.id]?.failedUnder else { return true }
            return failed.changed(to: basis, state: row.state)
        }.sorted { (owedRetry[$0.id]?.lastTried ?? .distantPast) < (owedRetry[$1.id]?.lastTried ?? .distantPast) }
        var nextDue: Date?
        var owed: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn)] = []
        for moment in due {
            guard !Task.isCancelled, !stopped else { return (nextDue, false) }
            guard moment.kind == "turn", let turn = moment.input?.turn else { continue }
            // Never rejudge recorded meaning: refold owed parts using watermarks and finish facts with original ordinals. Only rows without meaning return to
            // the model.
            let stored = moment.meaning.flatMap(Self.decodedMeaning)
            if moment.meaning != nil, stored == nil {
                nativeLog("MemoryV2: moment %@ has an unreadable meaning; left as it is", moment.id)
                continue
            }
            if let stored {
                await foldOwed(moment, turn: turn, meaning: stored, memory: memory, door: door, basis: basis)
                if due.count > 1 { nextDue = now }
                return (nextDue, true)
            }
            owed.append((moment, turn))
        }
        guard !owed.isEmpty else { return (nextDue, false) }
        let deferred = await AfterTurnSurpriseLedger.shared.deferredTurns(dataRoot: door.dataRoot,
            among: owed.map { (session: $0.turn.sessionId, turn: Self.ledgerTurn($0.turn, moment: $0.moment.id)) })
        let batch = owed.filter { row in
            let key = row.turn.sessionId + "\u{0}" + Self.ledgerTurn(row.turn, moment: row.moment.id)
            let due = deferred.contains(key) ? row.moment.acceptedAt.addingTimeInterval(45 * 60) : now
            if due <= now { return true }
            nextDue = min(nextDue ?? due, due)
            return false
        }
        guard !batch.isEmpty else { return (nextDue, false) }
        // A row a batch reply skipped is judged alone, in a batch of one.
        let judged = batch.first { owedRetry[$0.moment.id]?.alone == true }.map { [$0] }
            ?? Array(batch.prefix(MemoryManagerLane.batchLimit))
        await judgeOwedBatch(judged, manager: memoryManager, memory: memory, door: door, basis: basis)
        return (now, true)
    }

    /// Use the same recorded-turn surprise key as the live memory manager.
    private static func ledgerTurn(_ turn: CognitiveMomentTurn, moment: String) -> String {
        turn.turnId ?? turn.runId ?? turn.messageId ?? moment
    }

    /// A failed attempt waits for its basis, read before it began, to change: the route, an answer on it (a failed call), a held turn, or its row state.
    private func waitForChange(_ id: String, since basis: OwedBasis, onAnswer: Bool = false, state: CognitiveMomentState) {
        var attempt = owedRetry[id] ?? OwedAttempt()
        attempt.failedUnder = OwedDependence(basis: basis, onAnswer: onAnswer, state: state)
        attempt.lastTried = Date()
        owedRetry[id] = attempt
    }

    /// Refold recorded meaning under its recorded provenance; an unsettled row waits for a change.
    private func foldOwed(_ moment: CognitiveLivedMoment, turn: CognitiveMomentTurn,
                          meaning: AfterTurnInterpretation,
                          memory: SwiftNativeMemoryV2, door: LivedMomentDoor, basis: OwedBasis) async {
        inFlightMoments.insert(moment.id)
        let result = await replayRecorded(moment, turn: turn, memory: memory, meaning: meaning)
        inFlightMoments.remove(moment.id)
        // Done means the ROW is settled: any share still owed (a save that failed, facts not staged) keeps the row waiting for a change.
        let after = await door.moment(moment.id)
        let unfinished = after.map { $0.state != .lived && $0.state != .refused } ?? false
        guard result.extraction.failure != nil || result.stagingFailed || unfinished else {
            owedRetry[moment.id] = nil
            return
        }
        waitForChange(moment.id, since: basis, state: moment.state)
    }

    /// Recovery must retain the recorded turn's provenance.
    func replayRecorded(_ moment: CognitiveLivedMoment, turn: CognitiveMomentTurn,
                                memory: SwiftNativeMemoryV2,
                                meaning: AfterTurnInterpretation? = nil) async -> AdaptiveMemoryObservation {
        // The durable moment owns recovery even when its exchange has no separate act or run identity.
        let id = turn.turnId.flatMap { $0.isEmpty ? nil : $0 } ?? moment.id
        let run = turn.runId.flatMap { $0.isEmpty ? nil : $0 } ?? moment.id
        let speaker = turn.standingAgentName
            ?? (Self.isAgentSeatUserMessage(turn.user) ? Self.bridgeSender(turn.user) : nil)
        let checkpoint = PeerDataTaint(restoring: turn.sourceCheckpoint ?? ["untrusted stored content"],
                                       elevated: turn.elevatedSources ?? [])
        // This recovery act is owned by the durable moment. Missing transport provenance stays absent;
        // missing steering retains an unknown source instead of attesting a clean turn.
        var held = Turn(id: id, run: run, session: turn.sessionId)
        held.peerSteering = checkpoint
        held.envelope = TurnEnvelope.fromPersistedMetadata(turn.envelope)
        held.afterTurnOrigin = turn.origin
        held.careWakes = turn.careWakes ?? []
        let recoveryTurn = held
        return await TurnTraceContext.$turnId.withValue(recoveryTurn.id) {
            await interpretMemoryManager(speaker: speaker, memory: memory,
                userMessage: turn.user, assistantMessage: turn.assistant,
                sessionId: turn.sessionId, surface: turn.surface, origin: turn.origin,
                turnId: turn.turnId, standingAgent: turn.standingAgentName != nil,
                momentID: moment.id, turn: recoveryTurn, senseReads: nil, storedMeaning: meaning, collect: meaning == nil)
        }
    }

    /// One call, one section per row; write each meaning before its fold. A skipped section is judged alone next; failed calls and writes wait for a change.
    private func judgeOwedBatch(_ rows: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn)],
                                manager: any MemoryManaging, memory: SwiftNativeMemoryV2,
                                door: LivedMomentDoor, basis: OwedBasis) async {
        var inputs: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn, input: MemoryBatchInput)] = []
        for (moment, turn) in rows {
            guard !Task.isCancelled, !stopped else { break }
            inFlightMoments.insert(moment.id)
            let prepared = await replayRecorded(moment, turn: turn, memory: memory)
            if let input = prepared.batchInput {
                inputs.append((moment, turn, input))
            } else {
                // A row this attempt did not settle (unreadable facts, unavailable context, an unreadable journal row) waits for a change.
                inFlightMoments.remove(moment.id)
                let after = await door.moment(moment.id)
                if after.map({ $0.state == .lived || $0.state == .refused }) != true { waitForChange(moment.id, since: basis, state: moment.state) }
            }
        }
        defer { for entry in inputs { inFlightMoments.remove(entry.moment.id) } }
        guard !inputs.isEmpty, !Task.isCancelled, !stopped else { return }
        let root = await memory.surpriseDataRoot()
        let started = ProcessInfo.processInfo.systemUptime
        var providerSeconds = 0.0
        var replies: [AfterTurnInterpretation?] = []
        var failure: String?
        do {
            replies = try await manager.interpretBatch(inputs.map(\.input))
            providerSeconds = max(0, ProcessInfo.processInfo.systemUptime - started)
        } catch {
            failure = (error as? AfterTurnMemoryFailure)?.reason.rawValue
                ?? (error as? AfterTurnInterpretationFailure)?.rawValue ?? "provider"
        }
        // The provider answered on the route this attempt was asked under: rows whose call failed there are due again.
        if failure == nil { answeredCalls[basis.route, default: 0] += 1 }
        let share = providerSeconds / Double(inputs.count)
        // A returned judgment is produced work. Validate its target contracts, write meaning and label it outside cancellation before releasing it.
        await settle { [inputs, replies, failure] in
            await self.recordBatchJudgments(inputs, replies: replies, failure: failure, share: share, root: root, door: door, basis: basis)
        }
    }

    /// Only a judgment writes a ledger row; an attempt that judged nothing shows once in `mind.why` and leaves the row owed.
    private func recordBatchJudgments(
        _ inputs: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn, input: MemoryBatchInput)],
        replies: [AfterTurnInterpretation?], failure: String?, share: Double, root: URL?,
        door: LivedMomentDoor, basis: OwedBasis
    ) async {
        for (index, entry) in inputs.enumerated() {
            let id = entry.moment.id
            let turnKey = Self.ledgerTurn(entry.turn, moment: id)
            let reply = (replies.indices.contains(index) ? replies[index] : nil)
                .map { MemoryManagerLane.resolvingTargets($0, request: entry.input.request) }
            let outcome: String
            var check: AfterTurnMemorySurprise?
            if let reply, let meaning = Self.encodedMeaning(reply), await door.meant(id, meaning) {
                owedRetry[id] = nil
                outcome = "judged in a batch of \(inputs.count)"
                if let root {
                    check = await AfterTurnSurpriseLedger.shared.label(dataRoot: root, session: entry.turn.sessionId,
                        turn: turnKey, surface: entry.turn.surface,
                        channels: AfterTurnChannelOutcome(interpretation: reply, factsAsked: entry.input.factsEnabled),
                        providerSeconds: share, judgedBy: reply.judgingKey).check
                }
            } else if reply != nil {
                outcome = "left owed: its judgment could not be written to the agent's journal"
                waitForChange(id, since: basis, state: entry.moment.state)
            } else if let failure, failure != AfterTurnMemoryFailure.Reason.refused.rawValue {
                // A transient failed call (cancelled, provider) judged nothing: owed, as alone or batched as it was, until its route answers.
                outcome = "left owed: the batch call failed (\(failure))"
                waitForChange(id, since: basis, onAnswer: true, state: entry.moment.state)
            } else {
                // A skipped section or a refused call is judged alone once; skipped or refused alone, the agent lets it go with that reason.
                let refused = failure != nil
                if owedRetry[id]?.alone == true {
                    outcome = await letGo(id, refused: refused, door: door, basis: basis)
                } else {
                    owedRetry[id] = OwedAttempt(alone: true, failedUnder: nil, lastTried: Date())
                    outcome = refused ? "left owed: the memory model refused the batch; it is judged alone next"
                        : "left owed: the batch reply had no usable section for it; it is judged alone next"
                }
            }
            Self.whyInterpretation(turn: turnKey, session: entry.turn.sessionId,
                surface: entry.turn.surface,
                route: TurnEnvelope.fromPersistedMetadata(entry.turn.envelope)?.replyRoute,
                outcome: outcome, check: check, heldTurn: nil)
        }
    }

    /// Skipped or refused in a batch and again alone: the agent lets the turn go with its reason and never judges it again.
    private func letGo(_ id: String, refused: Bool, door: LivedMomentDoor, basis: OwedBasis) async -> String {
        let why = refused ? "refused: the memory model refused to judge it, in a batch and alone"
            : "batch_section_missing: no usable judgment came back for it in a batch or alone"
        await door.refuse(id, why)
        guard await door.moment(id)?.state == .refused else {
            waitForChange(id, since: basis, state: .owed)
            return "left owed: \(why); letting it go could not be written to the agent's journal"
        }
        owedRetry[id] = nil
        return "let go: " + why
    }

    /// Idle recovery schedules at most one pass, one through thirty minutes away, for a row due by its own time (a deferral's wait, work left after a
    /// pass, live work in the way); a failed row never sets it.
    private func scheduleOwedDrain(nextDue: Date?) {
        guard let nextDue, !stopped, let isIdle = heldDrainIsIdle else { return }
        let delay = min(max(nextDue.timeIntervalSinceNow, 60), 30 * 60)
        let deadline = Date().addingTimeInterval(delay)
        if let current = owedDrainTimer, current.deadline <= deadline { return }
        owedDrainTimer?.task.cancel()
        let id = UUID()
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.runScheduledOwedDrain(id: id, isIdle: isIdle)
        }
        owedDrainTimer = (id, deadline, timer)
    }

    private func runScheduledOwedDrain(id: UUID, isIdle: @escaping @Sendable () async -> Bool) async {
        guard owedDrainTimer?.id == id else { return }
        owedDrainTimer = nil
        guard !stopped, !Task.isCancelled else { return }
        await drainHeldAtIdle(isIdle: isIdle)
    }
}

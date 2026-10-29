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
// Blueprint: | `AdaptiveMemoryPromoter+Recovery.swift` | `AdaptiveMemoryPromoter`: owed-turn recovery on the live observation tail; recorded-provenance replay, fair retries and bounded wake/idle/night batches with cancellation-safe judgment settlement |

extension AdaptiveMemoryPromoter {
    /// How many turns are owed to her (recorded, not yet lived) in this data
    /// root's journal; nil when its door or journal read is unavailable.
    public func owedMomentCount(dataRoot: URL) async -> Int? {
        guard let door, door.dataRoot.standardizedFileURL == dataRoot.standardizedFileURL else { return nil }
        return await door.unlived()?.count
    }

    /// One idle pass through the journal. The old held file is only imported.
    public func drainHeldAtIdle(isIdle: @escaping @Sendable () async -> Bool) async {
        guard let door else { return }
        await drainOwedRows(door: door, isIdle: isIdle, passes: 1)
    }

    /// At her wake: moments a quit, a crash or a failed call left owed or meant
    /// are lived now, after queued observations. Meant ones fold with their
    /// recorded meaning (no model call); owed ones are judged again, a few per
    /// wake, the rest at idle.
    public func drainOwedMomentsAtWake() async {
        guard let door else { return }
        await drainOwedRows(door: door, isIdle: nil, passes: 8)
    }

    /// AT NIGHT, before the dream reads her day: every owed moment that is
    /// due is judged in batches and lived, still yielding to live work. Only
    /// the journal of this data root.
    public func drainOwedAtNight(dataRoot: URL) async {
        guard let door, door.dataRoot.standardizedFileURL == dataRoot.standardizedFileURL else { return }
        await drainOwedRows(door: door, isIdle: heldDrainIsIdle, passes: .max, joining: true)
    }

    /// Recovery shares the live tail and yields between passes as soon as
    /// live work arrives. A pass folds one meaning or judges up to four rows.
    private func drainOwedRows(door: LivedMomentDoor, isIdle: (@Sendable () async -> Bool)?,
                               passes: Int, joining: Bool = false) async {
        // Night is a barrier before the dream reads her day. Join a shared
        // flight without taking its ownership, then continue through this owner.
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
        // Only the caller that starts this flight cancels it. A night caller
        // joining somebody else's flight above never cancels shared work.
        _ = await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Replay under recorded provenance: fold one meaning or judge one bounded batch.
    /// Meaning is saved before folding; already-lived pieces remain inert.
    @discardableResult
    private func askOwedMoments(memory: SwiftNativeMemoryV2, door: LivedMomentDoor) async -> (nextDue: Date?, processed: Bool) {
        guard let memoryManager else { return (nil, false) }
        if !heldImported {
            heldImported = true
            await importHeldTurns(door: door)
        }
        // A FAIR CURSOR: rows whose last attempt failed wait out their backoff,
        // and among the due ones the least recently tried goes first, so one
        // failing row never starves the rest.
        let now = Date()
        guard let unlived = await door.unlived() else { return (nil, false) }
        let rows = unlived.filter { !inFlightMoments.contains($0.id) }
        let due = rows.filter { (owedRetry[$0.id]?.notBefore ?? .distantPast) <= now }
            .sorted { (owedRetry[$0.id]?.lastTried ?? .distantPast) < (owedRetry[$1.id]?.lastTried ?? .distantPast) }
        var nextDue = rows.compactMap { owedRetry[$0.id]?.notBefore }.filter { $0 > now }.min()
        var owed: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn)] = []
        for moment in due {
            guard !Task.isCancelled, !stopped else { return (nextDue, false) }
            guard moment.kind == "turn", let turn = moment.input?.turn else { continue }
            // RECOVERY FROM THE RECORD. A row with a recorded meaning is never
            // judged again: every part still owed refolds from that meaning
            // (watermarks skip what already landed) and its facts finish the
            // recorded decisions with their original ordinals. Only a row with
            // no meaning goes to the model again.
            let stored = moment.meaning.flatMap(Self.decodedMeaning)
            if moment.meaning != nil, stored == nil {
                nativeLog("MemoryV2: moment %@ has an unreadable meaning; left as it is", moment.id)
                continue
            }
            if let stored {
                if let wait = await foldOwed(moment, turn: turn, meaning: stored, memory: memory, door: door) {
                    nextDue = min(nextDue ?? wait, wait)
                }
                // More may be due: the drain admits the next pass (or schedules it).
                if due.count > 1 { nextDue = min(nextDue ?? now, now) }
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
        if let wait = await judgeOwedBatch(Array(batch.prefix(MemoryManagerLane.batchLimit)),
                                           manager: memoryManager, memory: memory, door: door) {
            nextDue = min(nextDue ?? wait, wait)
        }
        // The rows just written meant fold in the next passes.
        return (min(nextDue ?? now, now), true)
    }

    /// The turn key the surprise record uses for a recorded turn (the same one
    /// `runMemoryManager` derives from the live turn).
    private static func ledgerTurn(_ turn: CognitiveMomentTurn, moment: String) -> String {
        turn.turnId ?? turn.runId ?? turn.messageId ?? moment
    }

    /// Retry unfinished rows after one minute, doubling to six hours.
    private func backOff(_ id: String) -> Date {
        let attempts = min(owedRetry[id]?.attempts ?? 0, 9) + 1
        let wait = min(60 * pow(2, Double(attempts - 1)), 6 * 3_600)
        let notBefore = Date().addingTimeInterval(wait)
        owedRetry[id] = (attempts: attempts, notBefore: notBefore, lastTried: Date())
        return notBefore
    }

    /// One meant row through the door: its recorded meaning folds under the
    /// turn's own recorded provenance. Returns the backoff when the row is not
    /// settled afterwards.
    private func foldOwed(_ moment: CognitiveLivedMoment, turn: CognitiveMomentTurn,
                          meaning: AfterTurnInterpretation,
                          memory: SwiftNativeMemoryV2, door: LivedMomentDoor) async -> Date? {
        inFlightMoments.insert(moment.id)
        let result = await replayRecorded(moment, turn: turn, memory: memory, meaning: meaning)
        inFlightMoments.remove(moment.id)
        // Done means the ROW is settled: any share still owed (a save that
        // failed, facts not staged) keeps the row backing off and scheduled.
        let after = await door.moment(moment.id)
        let unfinished = after.map { $0.state != .lived && $0.state != .refused } ?? false
        guard result.extraction.failure != nil || result.stagingFailed || unfinished else {
            owedRetry[moment.id] = nil
            return nil
        }
        return backOff(moment.id)
    }

    /// Rebuild a request or refold a meaning under the recorded turn's provenance.
    func replayRecorded(_ moment: CognitiveLivedMoment, turn: CognitiveMomentTurn,
                                memory: SwiftNativeMemoryV2,
                                meaning: AfterTurnInterpretation? = nil) async -> AdaptiveMemoryObservation {
        let speaker = turn.standingAgentName
            ?? (Self.isAgentSeatUserMessage(turn.user) ? Self.bridgeSender(turn.user) : nil)
        let checkpoint = PeerDataTaint(restoring: turn.sourceCheckpoint ?? ["untrusted stored content"],
                                       elevated: turn.elevatedSources ?? [])
        return await TurnTraceContext.$turnId.withValue(turn.turnId ?? moment.id) {
            await LLMCallContext.$sessionId.withValue(turn.sessionId) {
            await PeerDataTaint.$current.withValue(checkpoint) {
            await ChatToolSessionContext.$envelope.withValue(TurnEnvelope.fromPersistedMetadata(turn.envelope)) {
            await AfterTurnSource.$origin.withValue(turn.origin) {
                await interpretMemoryManager(speaker: speaker, memory: memory,
                    userMessage: turn.user, assistantMessage: turn.assistant,
                    sessionId: turn.sessionId, surface: turn.surface, origin: turn.origin,
                    turnId: turn.turnId, standingAgent: turn.standingAgentName != nil,
                    momentID: moment.id, storedMeaning: meaning, collect: meaning == nil)
            }
            }
            }
            }
        }
    }

    /// One call, one section per row; write each meaning before its fold.
    /// Missing/malformed sections and failed writes stay owed and back off.
    private func judgeOwedBatch(_ rows: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn)],
                                manager: any MemoryManaging, memory: SwiftNativeMemoryV2,
                                door: LivedMomentDoor) async -> Date? {
        var earliest: Date?
        func wait(_ id: String) {
            let next = backOff(id)
            earliest = min(earliest ?? next, next)
        }
        var inputs: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn, input: MemoryBatchInput)] = []
        for (moment, turn) in rows {
            guard !Task.isCancelled, !stopped else { break }
            inFlightMoments.insert(moment.id)
            let prepared = await replayRecorded(moment, turn: turn, memory: memory)
            if let input = prepared.batchInput {
                inputs.append((moment, turn, input))
            } else {
                // Settled on the way (nothing to interpret), or its facts
                // unreadable: the row is lived, refused, or owed and waits.
                inFlightMoments.remove(moment.id)
                let after = await door.moment(moment.id)
                if prepared.extraction.failure != nil || after.map({ $0.state == .owed }) == true { wait(moment.id) }
            }
        }
        defer { for entry in inputs { inFlightMoments.remove(entry.moment.id) } }
        guard !inputs.isEmpty, !Task.isCancelled, !stopped else { return earliest }
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
        let share = providerSeconds / Double(inputs.count)
        // A returned judgment is produced work. Validate its target contracts,
        // write meaning and label it outside cancellation before releasing it.
        return await settle { [inputs, replies, failure, earliest] in
            await self.recordBatchJudgments(inputs, replies: replies, failure: failure,
                share: share, root: root, door: door, earliest: earliest)
        }
    }

    private func recordBatchJudgments(
        _ inputs: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn, input: MemoryBatchInput)],
        replies: [AfterTurnInterpretation?], failure: String?, share: Double, root: URL?,
        door: LivedMomentDoor, earliest: Date?
    ) async -> Date? {
        var earliest = earliest
        func wait(_ id: String) {
            let next = backOff(id)
            earliest = min(earliest ?? next, next)
        }
        for (index, entry) in inputs.enumerated() {
            let id = entry.moment.id
            let turnKey = Self.ledgerTurn(entry.turn, moment: id)
            let reply = (replies.indices.contains(index) ? replies[index] : nil)
                .map { MemoryManagerLane.resolvingTargets($0, request: entry.input.request) }
            let outcome: String
            var labelled: AfterTurnChannelOutcome?
            var missing: String? = failure
            if let reply {
                if let meaning = Self.encodedMeaning(reply), await door.meant(id, meaning) {
                    owedRetry[id] = nil
                    labelled = AfterTurnChannelOutcome(interpretation: reply, factsAsked: entry.input.factsEnabled)
                    outcome = "judged in a batch of \(inputs.count)"
                } else {
                    missing = "meaning_unrecorded"
                    outcome = "left owed: its judgment could not be written to her journal"
                }
            } else {
                missing = missing ?? "batch_section_missing"
                outcome = failure == nil ? "left owed: the batch reply had no usable section for it"
                    : "left owed: the batch call failed (\(failure ?? "provider"))"
            }
            if labelled == nil { wait(id) }
            var check: AfterTurnMemorySurprise?
            if let root {
                check = await AfterTurnSurpriseLedger.shared.label(dataRoot: root, session: entry.turn.sessionId,
                    turn: turnKey, surface: entry.turn.surface, channels: labelled,
                    providerSeconds: labelled == nil ? 0 : share, failure: labelled == nil ? missing : nil,
                    judgedBy: reply?.judgingKey).check
            }
            Self.whyInterpretation(turn: turnKey, session: entry.turn.sessionId,
                surface: entry.turn.surface,
                route: TurnEnvelope.fromPersistedMetadata(entry.turn.envelope)?.replyRoute,
                outcome: outcome, check: check)
        }
        return earliest
    }

    /// While she is idle the owed rows keep draining, bounded: one pass is
    /// scheduled for when the next row is due (at least a minute away, at most
    /// thirty), never more than one at a time.
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

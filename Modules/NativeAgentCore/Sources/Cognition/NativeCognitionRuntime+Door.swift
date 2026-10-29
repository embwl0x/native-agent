import Foundation
import CognitiveSubstrate
import Experiences
import MemoryV2
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `NativeCognitionRuntime+Door.swift` | `NativeCognitionRuntime` opening and joined sleep settlement; the one lived-moment door records, prepares, folds, settles, prunes and imports held turns |

// HER LIFE HAS ONE DOOR (docs/SUBCONSCIOUS.md, "Lived moments").
//
// The runtime is the only owner that holds both her substrate and her body,
// so it is the door. A settled turn is recorded here, owed, before its
// interpretation is asked for: a quit, a crash or a failed model call then
// loses nothing, because the journal row is the durable record of what is
// still owed.

extension NativeCognitionRuntime {
    public func bootstrap() async {
        if bootstrapTask == nil {
            guard !isFlushedForTermination else { return }
            bootstrapTask = Task { await self.bootstrapBody() }
        }
        await bootstrapTask?.value
    }

    private func bootstrapBody() async {
        // Only the canonical-root runtime installs the process-wide journal sink.
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            // The sink is installed first so no entry is dropped, and every
            // entry waits for the opening below: nothing reaches her before
            // both owners have read her saved state.
            await StudioJournalCognitiveBus.install { [weak self, substrate] entry in
                await self?.bootstrap()
                await substrate.ingestStudioJournalEntry(entry)
            }
        }
        startPursuitObservationIfNeeded()
        await refreshConfiguration()
        // The restore, the body's restore and the refold of cut folds hold the
        // door: no fold, Clear or Reset runs inside the opening.
        await enterDoor()
        do {
            try await substrate.restorePersistentState()
        } catch {
            bootstrapFailure = "cognitive restore failed: \(error.localizedDescription)"
            await substrate.recordReceipt(
                kind: "lifecycle.restore_failed",
                payload: .object(["error": .string(String(describing: error))])
            )
        }
        await restoreOrganismContinuityIfAvailable()
        // Turns admitted from the opening on carry the body's restored epoch,
        // and relay judgment reads the doses the body kept.
        await syncBodyEpoch()
        await substrate.adoptRecentDoses(await organismKernel.recentDoses())
        // A fold a crash cut is finished before ordinary admission opens.
        await refoldCutMoments()
        leaveDoor()
        guard !isFlushedForTermination else { return }
        await restoreProviderVitalsSnapshot()
        await startApprovalLifecycleObservationIfNeeded()
        let wakeAt = now()
        let wakeStamp = String(format: "%.0f", wakeAt.timeIntervalSince1970.rounded(.towardZero) + 0)
        let wakeEvent = CognitiveEvent(
            id: "app-wake:\(wakeStamp)",
            kind: .appWake,
            subject: CognitiveSubjectReference(type: "app", id: "NativeAgent", label: "NativeAgent"),
            sourceClass: .observed,
            occurredAt: wakeAt,
            summary: "NativeAgent app launched or resumed",
            importance: 0.35
        )
        await substrate.observe(wakeEvent)
        await somaticSignalBus.observe(wakeEvent)
        scheduleDirtyMicrocycle(reason: "app_wake_reconciliation")
        // Bootstrap is her restored state, which every reader joins. The
        // launch chores publish into that state on their own; no turn waits
        // for a Desk replay, an inbox sweep or a trace read.
        bootstrapChoresTask = Task { await self.bootstrapChores() }
    }

    private func bootstrapChores() async {
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        await reconcilePendingApprovalExpectationsAtBootstrap()
        await restoreProviderLifecycleEvidence()
        await retireProviderVitalsNotices()
        await host.archiveSupersededMorningBriefs(dataRoot: dataRoot)
        await startPursuitRefresh()
        await refreshOrganismBodySchema(reason: "bootstrap")
        await persistOrganismContinuity(reason: "bootstrap")
        await rescheduleResidualRepairDeadline()
        await rescheduleCognitionMaintenanceDeadline()
        publishRuntimeChange(reason: "bootstrap")
        await readRecentLifeIntoCaresIfOwed()
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        await moveMomentsIntoCaresOnce()
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        await liveOwedMomentsAtWake()
    }

    /// SLEEP (docs/STOP.md, docs/SUBCONSCIOUS.md "Lived moments"): one
    /// joinable operation. Every caller (the async quit hold, the termination
    /// drain) joins the same settlement; it runs through `settle {}`, so a
    /// cancelled caller still waits for it, and its result says what landed.
    public func sleep() async -> NativeCognitionSleepOutcome {
        if let sleepTask { return await sleepTask.value }
        isFlushedForTermination = true
        let task = Task<NativeCognitionSleepOutcome, Never> { [self] in
            await settle { await self.sleepSettlement() }
        }
        sleepTask = task
        return await task.value
    }

    private func sleepSettlement() async -> NativeCognitionSleepOutcome {
        // Latch shutdown so a delayed wake re-anchor
        // cannot resurrect the deadline timers this flush is about to cancel.
        isFlushedForTermination = true
        // Restore may finish during sleep, but cannot open new producers.
        await bootstrapTask?.value
        sourceWakes.cancelObservations()
        let producers = [bootstrapChoresTask, recentLifeTask, studioWanderTask,
            reflectionEventTask, studioCanonTask, horizonRefreshTask, reachTask,
            pursuitRefreshTask, pursuitObservationTask, carriedExperienceObservationTask,
            approvalLifecycleObservationTask, replayRetryTask,
            sourceWakes.canonObservation, sourceWakes.horizonObservation,
            sourceWakes.reachObservation, sourceWakes.clockObservation, sourceWakes.careObservation]
        for producer in producers { producer?.cancel() }
        for producer in producers { await producer?.value }
        bootstrapChoresTask = nil
        recentLifeTask = nil
        studioCanonTask = nil
        horizonRefreshTask = nil
        reachTask = nil
        studioWanderTask = nil
        approvalLifecycleObservationTask = nil
        // Reject late advisory publication as well as draining its body.
        pursuitRead.write { pursuitReadRevision = nil }
        pursuitRefreshQueued = false
        pursuitObservationTask = nil
        carriedExperienceObservationTask = nil
        pursuitRefreshTask = nil
        residualDeadline.invalidate()
        cognitionDeadline.invalidate()
        // Quiesce the two remaining unstructured re-arm sources. A
        // 0.25s-debounced dirty microcycle or a pending replay retry could
        // otherwise commit — and re-arm a deadline this flush just cancelled —
        // AFTER the terminal snapshot below. The reschedule bodies also honor
        // `isFlushedForTermination` so any survivor no-ops instead of re-arming.
        microcycleTimer.cancel()
        replayRetryTask = nil
        reflectionEventTask = nil
        let sleepAt = now()
        let sleepStamp = String(format: "%.0f", sleepAt.timeIntervalSince1970.rounded(.towardZero) + 0)
        let sleepEvent = CognitiveEvent(
            id: "app-sleep:\(sleepStamp)",
            kind: .appSleep,
            subject: CognitiveSubjectReference(type: "app", id: "NativeAgent", label: "NativeAgent"),
            sourceClass: .observed,
            occurredAt: sleepAt,
            summary: "NativeAgent app is terminating",
            importance: 0.35
        )
        // Only an opened owner may save its state (docs/STOP.md).
        guard bootstrapTask != nil else {
            return NativeCognitionSleepOutcome(substrate: "not opened: nothing of hers was written",
                                               body: "not opened: nothing of hers was written", unlivedMoments: nil)
        }
        // appSleep is the terminal transition, lived once, after the folds.
        // Degraded open: a part whose restore failed saves nothing (its writes
        // stay blocked) and says so; the part that restored still saves.
        var substrateResult = "saved"
        if bootstrapFailure == nil {
            await substrate.observe(sleepEvent)
            await substrate.runMaintenance(reason: "app termination")
            // One checked final flush of affect AND nodes; the outcome is it.
            do { try await substrate.persistAffectAndNodes() } catch {
                substrateResult = "not saved: \(error)"
            }
        } else {
            substrateResult = "not saved: her substrate's restore failed this session"
        }
        await somaticSignalBus.observe(sleepEvent)
        let bodySaved = await persistOrganismContinuity(reason: "app termination")
        // Termination is the runtime-owned snapshot point for provider vitals.
        // It follows lifecycle settlement so the final observed row
        // cannot be excluded by an early snapshot.
        await persistProviderVitalsSnapshot()
        // What did not land is the journal's own unlived rows; the next wake
        // lives them.
        let unlived = try? await cognitiveStore?.unlivedMomentCount()
        let outcome = NativeCognitionSleepOutcome(
            substrate: substrateResult,
            body: bodySaved ? "saved" : (organismRestoreFailedHard ? "not saved: frozen after a failed restore" : "not saved"),
            unlivedMoments: unlived)
        await substrate.recordReceipt(kind: "lifecycle.sleep", payload: .object([
            "substrate": .string(outcome.substrate), "body": .string(outcome.body),
            "unlivedMoments": unlived.map { .int(Int64($0)) } ?? .null,
        ]))
        return outcome
    }

    /// The door as the interpretation owner reaches it.
    func livedMomentDoor() -> LivedMomentDoor {
        LivedMomentDoor(
            dataRoot: dataRoot,
            recordOwed: { [weak self] turn in await self?.recordOwedMoment(turn) },
            prepare: { [weak self] id, origin, reply in
                await self?.prepareMoment(id, origin: origin, reply: reply)
            },
            meant: { [weak self] id, meaning in await self?.markMomentMeant(id, meaning: meaning) ?? false },
            lived: { [weak self] id in await self?.settleMoment(id, as: .lived) },
            refuse: { [weak self] id, reason in await self?.settleMoment(id, as: .refused, reason: reason) },
            unlived: { [weak self] in await self?.unlivedMoments() },
            importHeld: { [weak self] turns in await self?.importHeldMoments(turns) ?? false },
            moment: { [weak self] id in
                await self?.readMoment(id)
            }
        )
    }

    /// Record a settled turn as owed. Its identity is its origin (session +
    /// incoming message), so a re-delivery records nothing new. Returns nil when
    /// the journal cannot record it; no unrecorded turn can fold into her.
    func recordOwedMoment(_ turn: CognitiveMomentTurn) async -> String? {
        await bootstrap()
        guard let messageId = turn.messageId, !messageId.isEmpty else { return nil }
        let id = CognitiveLivedMoment.turnID(sessionId: turn.sessionId, messageId: messageId)
        guard let cognitiveStore else {
            await noteMomentUnrecorded(id, why: "the cognition store is unavailable")
            return nil
        }
        let life: String
        do { life = try DataRootLife.current(in: dataRoot) } catch {
            await noteMomentUnrecorded(id, why: "the data root's life is unreadable: \(error.localizedDescription)")
            return nil
        }
        var deferred: CognitiveDeferredTurnRecord?
        if let origin = turn.origin { deferred = await substrate.deferredTurnRecord(origin: origin) }
        let current = await substrate.forgettingEpochs()
        let factsOnly = !(await substrate.configurationSnapshot()).enabled
        let livedAt = turn.occurredAt ?? deferred?.event.occurredAt ?? now()
        let moment = CognitiveLivedMoment(
            id: id, life: life, kind: "turn", livedAt: livedAt, acceptedAt: now(), state: .owed,
            mindEpoch: deferred?.mindEpoch ?? current.mind, bodyEpoch: deferred?.bodyEpoch ?? current.body,
            input: CognitiveMomentInput(turn: turn, deferred: deferred, factsOnly: factsOnly ? true : nil))
        do {
            try await cognitiveStore.recordMoment(moment)
            if let deferred { await substrate.releaseDeferredTurn(deferred) }
            return id
        } catch {
            await noteMomentUnrecorded(id, why: String(describing: error))
            return nil
        }
    }

    /// Read the recorded entry directly. Save the caring evidence the judgment
    /// sees with that entry; the fold needs no separate sealed-request record.
    func prepareMoment(_ id: String, origin: AfterTurnOrigin, reply: String) async -> AfterTurnContext? {
        await bootstrap()
        guard let cognitiveStore, var row = await readMoment(id),
              row.state == .owed || row.state == .meant else { return nil }
        if row.input?.factsOnly == true { return nil }
        guard let record = row.input?.deferred else {
            await noteMomentReadFailed(id, why: "ordinary turn context is unavailable")
            return nil
        }
        let context = await substrate.afterTurnContext(record: record,
            exchange: row.state == .owed ? origin.userMessage + "\n" + reply : nil)
        if row.state == .owed {
            row.input?.deferred?.caring = context.caring
            do { try await cognitiveStore.saveMoment(row) } catch {
                await noteMomentReadFailed(id, why: "caring request not saved: \(error)")
                return nil
            }
        }
        return context
    }

    /// The interpretation came back: written onto the row before any part of
    /// her applies it. A quit or crash from here folds it at the next wake
    /// without asking the model again.
    /// True only when the meaning is durable; a fold begins only then.
    func markMomentMeant(_ id: String, meaning: JSONValue) async -> Bool {
        guard let cognitiveStore, var row = await readMoment(id) else { return false }
        if row.state == .meant { return row.meaning == meaning }
        guard row.state == .owed, row.meaning == nil,
              row.input?.deferred != nil || row.input?.factsOnly == true else { return false }
        row.meaning = meaning
        row.state = .meant
        do {
            try await cognitiveStore.saveMoment(row)
            return true
        } catch {
            nativeLog("cognition: moment %@ meaning not recorded: %@", id, String(describing: error))
            return false
        }
    }

    /// Settle a moment lived or refused (payloads dropped, identity kept).
    func settleMoment(_ id: String, as state: CognitiveMomentState, reason: String? = nil) async {
        if state == .lived {
            guard let row = await readMoment(id), row.state == .meant,
                  row.input?.factsOnly == true || (row.input?.deferred != nil && row.foldSeq != nil
                    && row.input?.folded == row.foldSeq) else { return }
        }
        do { try await cognitiveStore?.settleMoment(id, as: state, reason: reason) } catch {
            nativeLog("cognition: moment %@ not settled %@: %@", id, state.rawValue, String(describing: error))
        }
    }

    /// Moments of this life still owed or meant. A row from another life (a
    /// backup restore began a new one) is refused on the way.
    func unlivedMoments() async -> [CognitiveLivedMoment]? {
        await bootstrap()
        let life: String
        do { life = try DataRootLife.current(in: dataRoot) } catch {
            await noteMomentReadFailed("journal.life", why: String(describing: error))
            return nil
        }
        guard let rows = await readMoments(states: [.owed, .meant]) else { return nil }
        var live: [CognitiveLivedMoment] = []
        for row in rows where row.kind == "turn" {
            if row.life == life { live.append(row) } else { await settleMoment(row.id, as: .refused, reason: "another life") }
        }
        return live
    }

    /// Held turns (the retired `memory/moments_held.json`) become owed moments,
    /// all in one transaction. They were held for their facts only: with no
    /// recorded deferred-turn entry they prepare no context and never fold.
    func importHeldMoments(_ turns: [CognitiveMomentTurn]) async -> Bool {
        await bootstrap()
        guard let cognitiveStore, let life = try? DataRootLife.current(in: dataRoot) else { return false }
        let epochs = await substrate.forgettingEpochs()
        let accepted = now()
        let moments = turns.map { turn -> CognitiveLivedMoment in
            let stamp = String(format: "%.0f", (turn.occurredAt ?? accepted).timeIntervalSince1970.rounded(.towardZero) + 0)
            let identity = CognitiveLivedMoment.turnID(
                sessionId: turn.sessionId,
                messageId: turn.messageId ?? "held:\(turn.turnId ?? "")@\(stamp)")
            return CognitiveLivedMoment(
                id: identity, life: life, kind: "turn", livedAt: turn.occurredAt ?? accepted,
                acceptedAt: accepted, state: .owed, mindEpoch: epochs.mind, bodyEpoch: epochs.body,
                input: CognitiveMomentInput(turn: turn, factsOnly: true))
        }
        do {
            try await cognitiveStore.recordMoments(moments)
            return true
        } catch {
            nativeLog("cognition: held turns not imported: %@", String(describing: error))
            return false
        }
    }

    /// THE FOLD (docs/SUBCONSCIOUS.md, "Lived moments"): one moment, once, in
    /// the order the door folds it. The moment's fold seq is assigned (once; a
    /// refold keeps it), the mind's share is lived by the substrate and the
    /// body's whole share by the kernel in one call, each piece stamped with
    /// the seq and saved. A refold leaves every piece already at the seq
    /// alone. True when every piece landed (a piece its owner refuses, her
    /// inner life or body off, lands as nothing); false leaves the row meant,
    /// folded again. An unrecorded turn has no fold.
    func foldTurnMoment(_ context: AfterTurnContext, interpretation: AfterTurnInterpretation?,
                        momentID: String?) async -> Bool {
        // Nothing changes her before she wakes.
        await bootstrap()
        // THE DOOR IS THE HOLD: one fold at a time, exclusive with Clear,
        // Reset Body and restore. The seq is allocated and every part applied
        // inside it, so no other producer's seq can overtake this one.
        await enterDoor()
        defer { leaveDoor() }
        return await foldInsideDoor(context, interpretation: interpretation,
                                    momentID: momentID)
    }

    /// Enter the door: wait while a fold, Clear, Reset Body or restore holds it.
    func enterDoor() async {
        while doorHeld {
            await withCheckedContinuation { doorWaiters.append($0) }
        }
        doorHeld = true
    }

    /// Leave the door; every waiter re-checks it.
    func leaveDoor() {
        doorHeld = false
        let waiters = doorWaiters
        doorWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// The fold itself, for a caller that already holds the door.
    func foldInsideDoor(_ context: AfterTurnContext, interpretation: AfterTurnInterpretation?,
                        momentID: String?) async -> Bool {
        guard let momentID, let cognitiveStore, let interpretation,
              var row = await readMoment(momentID), row.meaning != nil, row.state == .meant,
              let record = row.input?.deferred else { return false }
        let seq: UInt64
        do {
            guard let assigned = try await cognitiveStore.beginFold(momentID) else { return false }
            seq = assigned
        } catch {
            // The row stays meant until its once-only proof can be assigned.
            nativeLog("cognition: moment %@ fold not begun: %@", momentID, String(describing: error))
            return false
        }
        // The caring receipt is a projection of the first fold; a refold never
        // writes or relabels it.
        if row.foldSeq == nil, let request = context.caring {
            await CaringReceiptLog.shared.record(request, model: interpretation.model,
                surface: interpretation.surface, verdict: interpretation.caring)
        }
        let mind = await substrate.foldTurn(
            context, record: record, appraisal: interpretation.affect,
            caring: interpretation.caring, cares: interpretation.cares,
            appAuthored: interpretation.appAuthored, seq: seq, momentID: momentID)
        await caresSourceChanged()
        var reaction: SomaticSignal?
        if !mind.reaction.isEmpty {
            var enriched = mind.event
            enriched.metadata.merge(mind.reaction) { _, new in new }
            reaction = CognitiveSomaticSignals.signal(from: enriched, id: UUID())
        }
        // A retained correction from the person raises confidence according to
        // the recorded interpretation's correction decision.
        let corrected = context.event.sourceClass != .imported && interpretation.memories.contains(where: {
            $0.kind == "correction" && $0.action != .skip && $0.confidence >= MemoryManagerLane.confidenceFloor
        })
        let bodySaved = await foldBody(OrganismTurnFold(
            seq: seq, epoch: context.bodyEpoch, caring: mind.caring, caringWindow: mind.caringWindow,
            caringWhy: mind.caringWhy, reaction: reaction, correctionConfidence: corrected ? 0.03 : 0))
        guard mind.saved && bodySaved else { return false }
        row.input?.folded = seq
        do {
            try await cognitiveStore.saveMoment(row)
            return true
        } catch {
            await noteMomentReadFailed(momentID, why: "completed fold not saved: \(error)")
            return false
        }
    }

    /// The body's whole share in one kernel call, saved. The caring receipt
    /// learns what the body did; an already-lived share leaves it as the
    /// first fold wrote it. False only when its save failed.
    private func foldBody(_ fold: OrganismTurnFold) async -> Bool {
        guard !fold.isEmpty else { return true }
        let outcome = await organismKernel.foldTurn(fold)
        let tenderness = { await self.organismKernel.snapshot().chemicalState.tenderness }
        switch outcome {
        case .refused:
            if let reading = fold.caring {
                await CaringReceiptLog.shared.amendReceipt(session: reading.session, turn: reading.turn,
                                                       outcome: .refused, tendernessAfter: await tenderness())
            }
            return true
        case .forgotten:
            if let reading = fold.caring {
                await CaringReceiptLog.shared.amendReceipt(session: reading.session, turn: reading.turn,
                                                       outcome: .forgotten, tendernessAfter: await tenderness())
            }
            return true
        case .alreadyLived:
            break
        case .lived(let caring):
            if let caring, let reading = fold.caring {
                await CaringReceiptLog.shared.amendReceipt(session: reading.session, turn: reading.turn,
                                                       outcome: caring, tendernessAfter: await tenderness())
            }
        }
        cachedBodyRead = nil
        let saved = await persistOrganismContinuity(reason: "lived moment")
        await substrate.adoptRecentDoses(await organismKernel.recentDoses())
        publishRuntimeChange(reason: "after_turn_interpretation")
        return saved
    }

    /// At the opening, before ordinary admission (the caller holds the door):
    /// a fold that began and did not finish (a meant row with a fold seq) is
    /// folded again from its record and meaning, before any newer fold can
    /// stamp a piece past it. Pieces already at its seq are left alone; its
    /// facts and `lived` are the interpretation owner's drain after the opening.
    func refoldCutMoments() async {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL,
              let life = try? DataRootLife.current(in: dataRoot) else { return }
        guard let rows = await readMoments(states: [.meant]) else { return }
        for row in rows where row.life == life && row.kind == "turn" && row.foldSeq != nil {
            guard let record = row.input?.deferred,
                  let meaning = row.meaning.flatMap(AdaptiveMemoryPromoter.decodedMeaning) else { continue }
            let context = await substrate.afterTurnContext(record: record)
            _ = await foldInsideDoor(context, interpretation: meaning, momentID: row.id)
        }
    }

    /// How long a SETTLED moment's identity is kept: long past any
    /// re-delivery of the same message (a producer records at transcript
    /// settlement, within seconds; the held file is emptied once imported),
    /// so the journal never grows forever. An unsettled row is kept however old.
    static let settledMomentRetention: TimeInterval = 30 * 24 * 60 * 60

    /// At her wake, settled rows past retention are pruned, then what a quit,
    /// crash or failed call left owed or meant is lived.
    func liveOwedMomentsAtWake() async {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else { return }
        do {
            try await cognitiveStore?.pruneMoments(settledBefore: now().addingTimeInterval(-Self.settledMomentRetention))
        } catch {
            nativeLog("cognition: settled moments not pruned (next wake tries again): %@", String(describing: error))
        }
        await AdaptiveMemoryPromoter.shared.drainOwedMomentsAtWake()
    }

    /// A turn the journal could not record cannot change her: it owes repair
    /// (Doctor shows it, naming the turn and why), and the receipt is still
    /// attempted.
    func noteMomentUnrecorded(_ id: String, why: String) async {
        nativeLog("cognition: lived moment %@ not recorded, not folded: %@", id, why)
        RepairOwed.owe(dataRoot, id: "cognition.moment.unrecorded:" + id, kind: .run,
            evidence: [.init(source: "lived_moments", id: id)],
            operation: "cognition.moment.unrecorded", owner: "cognition",
            words: "A settled turn (\(id)) could not be recorded in her journal, so it has not changed her: \(String(why.prefix(240)))")
        await substrate.recordReceipt(kind: "lived_moment.unrecorded", payload: .object([
            "moment": .string(id), "why": .string(String(why.prefix(240))),
        ]))
    }

    /// A stored meaning must also decode as the interpretation owner's type.
    /// Valid JSON with the wrong shape is damage, never an invitation to judge again.
    private func checkedMeaning(_ row: CognitiveLivedMoment) async throws -> CognitiveLivedMoment? {
        if let meaning = row.meaning, AdaptiveMemoryPromoter.decodedMeaning(meaning) == nil {
            try await cognitiveStore?.refuseUnreadableMoment(row.id, why: "meaning_json: invalid interpretation shape")
            return nil
        }
        return row
    }

    private func readMoment(_ id: String) async -> CognitiveLivedMoment? {
        do {
            guard let cognitiveStore else { throw CognitivePersistenceError.storeUnavailable }
            guard let row = try await cognitiveStore.loadMoment(id) else { return nil }
            return try await checkedMeaning(row)
        } catch {
            await noteMomentReadFailed(id, why: String(describing: error))
            return nil
        }
    }

    private func readMoments(states: [CognitiveMomentState]) async -> [CognitiveLivedMoment]? {
        do {
            guard let cognitiveStore else { throw CognitivePersistenceError.storeUnavailable }
            var result: [CognitiveLivedMoment] = []
            for row in try await cognitiveStore.loadMoments(states: states) {
                if let checked = try await checkedMeaning(row) { result.append(checked) }
            }
            return result
        } catch {
            await noteMomentReadFailed("journal", why: String(describing: error))
            return nil
        }
    }

    private func noteMomentReadFailed(_ id: String, why: String) async {
        nativeLog("cognition: moment %@ unavailable, left unsettled: %@", id, why)
        RepairOwed.owe(dataRoot, id: "cognition.moment.read:" + id, kind: .run,
            evidence: [.init(source: "lived_moments", id: id)],
            operation: "cognition.moment.read:" + id, owner: "cognition",
            words: "Journal read or preparation failed for \(id); no mind settlement is proven: \(why)",
            tap: "Settings → Doctor")
    }
}

/// What her sleep settled: each part's final save, and how many moments the
/// journal still holds unlived for the next wake (nil when it could not say).
public struct NativeCognitionSleepOutcome: Sendable, Equatable {
    public let substrate: String
    public let body: String
    public let unlivedMoments: Int?

    public var summary: String {
        "substrate \(substrate); body \(body); unlived moments \(unlivedMoments.map(String.init) ?? "unknown")"
    }
}

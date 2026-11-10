import Foundation
import ChatTurnRuntime
import CognitiveSubstrate
import Experiences
import MemoryV2
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `NativeCognitionRuntime+Door.swift` | `NativeCognitionRuntime`. |

// The runtime owns both substrate and body, making it the sole lived-moment entry.
// Journal each settled turn as owed before interpretation so quit, crash or provider failure cannot lose it.

extension NativeCognitionRuntime {
    public func bootstrap() async {
        if bootstrapTask == nil {
            guard !isFlushedForTermination else { return }
            bootstrapTask = Task { await self.bootstrapBody() }
        }
        await bootstrapTask?.value
    }

    private func bootstrapBody() async {
        // Install this runtime's injected bus before restore; delivery joins this same bootstrap.
        await studioJournalBus.install { [weak self, substrate] entry in
            await self?.bootstrap()
            await substrate.ingestStudioJournalEntry(entry)
        }
        startPursuitObservationIfNeeded()
        await refreshConfiguration()
        // Restore and interrupted-fold recovery exclude folds, Clear and Reset until opening completes.
        await enterDoor()
        do {
            if let cognitiveStoreOpeningFailure {
                throw PersistenceCoreError.ioFailure(cognitiveStoreOpeningFailure)
            }
            try await substrate.restorePersistentState()
        } catch {
            bootstrapFailure = "cognitive restore failed: \(error.localizedDescription)"
            await substrate.recordReceipt(
                kind: "lifecycle.restore_failed",
                payload: .object(["error": .string(String(describing: error))])
            )
        }
        await restoreOrganismContinuityIfAvailable()
        // Admitted turns carry the restored body epoch; relay judgment reads retained doses.
        await syncBodyEpoch()
        await substrate.adoptRecentDoses(await organismKernel.recentDoses())
        // Finish interrupted folds before opening ordinary admission.
        await refoldCutMoments()
        await admitOwedMomentsAgain()
        leaveDoor()
        guard !isFlushedForTermination else { return }
        // Never gates admission on the experience store.
        Task { await self.settleReadRepairsAlreadyPaid() }
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
        // Readers join restored bootstrap state; independent launch chores must not block turns.
        bootstrapChoresTask = Task { await self.bootstrapChores() }
    }

    private func bootstrapChores() async {
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        await reconcilePendingApprovalExpectationsAtBootstrap()
        await restoreProviderLifecycleEvidence()
        await host.archiveSupersededMorningBriefs(dataRoot: dataRoot)
        await finishOwedCarriedSettlements()
        await startPursuitRefresh()
        await refreshOrganismBodySchema(reason: "bootstrap")
        await persistOrganismContinuity(reason: "bootstrap")
        await rescheduleResidualRepairDeadline()
        await rescheduleCognitionMaintenanceDeadline()
        publishRuntimeChange(reason: "bootstrap")
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        await liveOwedMomentsAtWake()
    }

    /// All sleep callers join one settlement through settle so cancellation cannot abandon it; the result records what landed.
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
        // Latch shutdown so a delayed wake cannot resurrect cancelled deadlines.
        isFlushedForTermination = true
        // Restore may finish during sleep but cannot open new producers.
        await bootstrapTask?.value
        sourceWakes.cancelObservations()
        let producers = [rhythm.observation, rhythm.refresh, bootstrapChoresTask,
            reflectionEventTask, studioCanonTask, horizonRefreshTask,
            pursuitRefreshTask, pursuitObservationTask, carriedExperienceObservationTask, turnIdleObservationTask,
            approvalLifecycleObservationTask,
            sourceWakes.canonObservation, sourceWakes.horizonObservation,
            sourceWakes.peopleObservation, sourceWakes.clockObservation, sourceWakes.careObservation]
        for producer in producers { producer?.cancel() }
        for producer in producers { await producer?.value }
        // Join durable replay without cancelling its commit.
        await eventReplayTask?.value
        await replayTask?.value
        settleRhythmForSleep()
        bootstrapChoresTask = nil
        studioCanonTask = nil
        horizonRefreshTask = nil
        approvalLifecycleObservationTask = nil
        // Reject late advisory publication as well as draining its body.
        pursuitRead.write { pursuitReadRevision = nil }
        pursuitRefreshQueued = false
        pursuitObservationTask = nil
        carriedExperienceObservationTask = nil
        turnIdleObservationTask = nil
        pursuitRefreshTask = nil
        residualDeadline.invalidate()
        cognitionDeadline.invalidate()
        await microcycleTask?.value
        microcycleTask = nil
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
        // Only a successfully opened owner may save its state.
        guard bootstrapTask != nil else {
            return NativeCognitionSleepOutcome(substrate: "not opened: nothing of the agent's was written",
                                               body: "not opened: nothing of the agent's was written", unlivedMoments: nil)
        }
        // Record appSleep once after folds; failed restores stay write-blocked while independently restored parts still save.
        var substrateResult = "saved"
        if bootstrapFailure == nil {
            await substrate.observe(sleepEvent)
            do { _ = try await substrate.runMaintenanceChecked(reason: "app termination") } catch {
                substrateResult = "maintenance not saved: \(error)"
            }
            // One checked final flush owns the affect and node outcome.
            do { try await substrate.persistAffectAndNodes() } catch {
                substrateResult += "; checkpoint not saved: \(error)"
            }
        } else {
            substrateResult = "not saved: the agent's substrate restore failed this session"
        }
        await somaticSignalBus.observe(sleepEvent)
        let bodySaved = await persistOrganismContinuity(reason: "app termination")
        // Snapshot provider vitals after lifecycle settlement so the final event cannot be omitted.
        await persistProviderVitalsSnapshot()
        // Unlived journal rows remain owed for the next wake.
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

    func livedMomentDoor() -> LivedMomentDoor {
        LivedMomentDoor(
            dataRoot: dataRoot,
            saveRecovery: { [weak self] id, value in
                guard let store = await self?.cognitiveStore else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The cognition store is unavailable."])
                }
                try await store.saveMomentRecovery(id, recovery: value)
            },
            routeAnswer: { [weak self] route in
                guard let store = await self?.cognitiveStore else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The cognition store is unavailable."])
                }
                return try await store.momentRouteAnswer(route)
            },
            recordAnswer: { [weak self] id, route in
                guard let store = await self?.cognitiveStore else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The cognition store is unavailable."])
                }
                try await store.recordMomentAnswer(id, route: route)
            },
            recordOwed: { [weak self] turn in await self?.recordOwedMoment(turn) },
            prepare: { [weak self] id, origin, reply in
                guard let self else { throw LivedMomentPreparationFailure.local("The cognition runtime is unavailable.") }
                return try await self.prepareMoment(id, origin: origin, reply: reply)
            },
            meant: { [weak self] id, meaning in await self?.markMomentMeant(id, meaning: meaning) ?? false },
            lived: { [weak self] id in await self?.settleMoment(id, as: .lived) },
            refuse: { [weak self] id, reason in await self?.settleMoment(id, as: .refused, reason: reason) },
            unlived: { [weak self] in await self?.unlivedMoments() },
            moment: { [weak self] id in
                await self?.readMoment(id)
            }
        )
    }

    /// Journal identity is the turn's `momentID`. A moment judged for settlement alone has no mind share: it is recorded facts-only, with no
    /// admission. Failure to record leaves repair owed; an unrecorded turn cannot fold.
    func recordOwedMoment(_ turn: CognitiveMomentTurn) async -> String? {
        await bootstrap()
        guard let id = turn.momentID else { return nil }
        guard let cognitiveStore else {
            await noteMomentUnrecorded(id, why: "the cognition store is unavailable")
            return nil
        }
        let life: String
        do { life = try DataRootLife.current(in: dataRoot) } catch {
            await noteMomentUnrecorded(id, why: "the data root's life is unreadable: \(error.localizedDescription)")
            return nil
        }
        let settlesOnly = turn.settlesOnly == true
        var deferred: CognitiveDeferredTurnRecord?
        let held: CognitiveDeferredTurnRecord?
        if !settlesOnly, let origin = turn.origin { held = await substrate.deferredTurnRecord(origin: origin) }
        else { held = nil }
        // A turn whose held entry is gone (a restart between its row and its reply) is admitted again from its saved row.
        let admission: CognitiveDeferredTurnRecord?
        if let held { admission = held } else if !settlesOnly, !turn.isCareWake { admission = await readmission(turn) } else { admission = nil }
        let current = await substrate.forgettingEpochs()
        if turn.isCareWake, let messageId = turn.messageId {
            // A care wake owes care reading from its captured arrival and reply, not an ordinary incoming-word appraisal.
            let event = CognitiveEvent(id: id, kind: .userMessageReceived,
                subject: CognitiveSubjectReference(type: "turn", id: messageId),
                sourceClass: .observed, occurredAt: turn.occurredAt ?? now(),
                summary: turn.asked,
                metadata: ["messageId": .string(messageId), "sessionId": .string(turn.sessionId)])
            deferred = CognitiveDeferredTurnRecord(event: event, caring: nil,
                mindEpoch: admission?.mindEpoch ?? current.mind, bodyEpoch: admission?.bodyEpoch ?? current.body)
        } else { deferred = admission }
        let enabled = await substrate.configurationSnapshot().enabled
        let factsOnly = settlesOnly || !enabled
        let livedAt = turn.occurredAt ?? deferred?.event.occurredAt ?? now()
        let moment = CognitiveLivedMoment(
            id: id, life: life, kind: "turn", livedAt: livedAt, acceptedAt: now(), state: .owed,
            mindEpoch: deferred?.mindEpoch ?? current.mind, bodyEpoch: deferred?.bodyEpoch ?? current.body,
            input: CognitiveMomentInput(turn: turn, deferred: deferred, factsOnly: factsOnly ? true : nil))
        do {
            try await cognitiveStore.recordMoment(moment)
            if let held { await substrate.releaseDeferredTurn(held) }
            return id
        } catch {
            await noteMomentUnrecorded(id, why: String(describing: error))
            return nil
        }
    }

    /// Keep the judgment's caring evidence on its journal entry so the fold needs no second sealed-request store.
    func prepareMoment(_ id: String, origin: AfterTurnOrigin, reply: String) async throws -> AfterTurnContext {
        await bootstrap()
        guard let cognitiveStore, var row = await readMoment(id),
              row.state == .owed || row.state == .meant else {
            if Task.isCancelled { throw CancellationError() }
            throw LivedMomentPreparationFailure.local("The recorded moment is unavailable for context preparation.")
        }
        if row.input?.factsOnly == true {
            throw LivedMomentPreparationFailure.record("A facts-only moment has no cognition context to prepare.")
        }
        do { try await admitAgain(&row, store: cognitiveStore) } catch {
            await noteMomentReadFailed(id, why: "re-read admission not saved: \(error)")
            throw LivedMomentPreparationFailure.local("The turn's admission could not be saved: \(error.localizedDescription)")
        }
        guard let record = row.input?.deferred else {
            if Task.isCancelled { throw CancellationError() }
            await noteMomentReadFailed(id, why: "ordinary turn context is unavailable")
            throw LivedMomentPreparationFailure.record("The recorded turn context is unavailable; repair its input.")
        }
        let context: AfterTurnContext
        do {
            context = try await substrate.afterTurnContext(record: record,
                exchange: row.state == .owed ? origin.userMessage + "\n" + reply : nil,
                careWakes: row.input?.turn?.isCareWake == true ? row.input?.turn?.careWakes ?? [] : [])
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            RepairOwed.owe(dataRoot, id: "moment-context:" + id, kind: .run,
                operation: "cognition.moment.context:" + id, owner: "memory/embedding",
                words: "This moment's care context is unavailable: \(error.localizedDescription)",
                tap: "Repair the embedding owner in Settings → Memory. The moment remains owed.")
            throw LivedMomentPreparationFailure.embedding(error.localizedDescription)
        }
        if row.state == .owed {
            row.input?.deferred?.caring = context.caring
            do { try await cognitiveStore.saveMoment(row) } catch {
                await noteMomentReadFailed(id, why: "caring request not saved: \(error)")
                throw LivedMomentPreparationFailure.local("The caring request could not be saved: \(error.localizedDescription)")
            }
        }
        // A prepared moment proves its journal read: any read repair it owed is paid.
        RepairOwed.settle(dataRoot, operation: "cognition.moment.read:" + id, evidence: .init(source: "lived_moments", id: id))
        return context
    }

    /// A moment recorded without its admission is admitted again from its saved row, stamped with the moment's own epochs.
    private func admitAgain(_ row: inout CognitiveLivedMoment, store: CognitiveSQLiteStore) async throws {
        guard row.input?.deferred == nil, row.input?.factsOnly != true, let turn = row.input?.turn, !turn.isCareWake,
              var record = await readmission(turn) else { return }
        record.mindEpoch = row.mindEpoch
        record.bodyEpoch = row.bodyEpoch
        row.input?.deferred = record
        try await store.saveMoment(row)
    }

    /// At opening, before ordinary admission: an owed moment waiting on its record gains its admission, and that changed input ends its wait.
    func admitOwedMomentsAgain() async {
        guard let cognitiveStore, let rows = await readMoments(states: [.owed]) else { return }
        for var row in rows {
            do { try await admitAgain(&row, store: cognitiveStore) }
            catch { await noteMomentReadFailed(row.id, why: "re-read admission not saved: \(error)") }
        }
    }

    /// A turn's admission read again from its saved user row, for a turn whose held entry the substrate no longer has.
    private func readmission(_ turn: CognitiveMomentTurn) async -> CognitiveDeferredTurnRecord? {
        guard let messageId = turn.messageId, !messageId.isEmpty,
              let event = await SwiftNativeChatOrchestrationClient.savedUserRowEvent(
                dataRoot: dataRoot, sessionId: turn.sessionId, messageId: messageId),
              turn.runId == nil || event.metadata["runId"] == turn.runId.map(JSONValue.string) else { return nil }
        return await substrate.admission(of: event)
    }

    /// Persist meaning before applying it so interrupted folds can resume without another model judgment.
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

    /// Drop settled payloads but retain identity for deduplication.
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

    /// Refuse moments from another life so backup restoration cannot replay old effects into a new one.
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

    /// Assign each fold one sequence and apply it to substrate and body under the door; refolds skip pieces already stamped.
    /// Only fully landed or owner-refused shares settle the row; incomplete shares remain meant for another fold.
    /// Unrecorded turns cannot fold.
    func foldTurnMoment(_ context: AfterTurnContext, interpretation: AfterTurnInterpretation?,
                        momentID: String?) async -> Bool {
        // Nothing mutates the agent before wake completes.
        await bootstrap()
        // Serialize folds with Clear, Reset and restore so another sequence cannot overtake a partially applied fold.
        await enterDoor()
        defer { leaveDoor() }
        return await foldInsideDoor(context, interpretation: interpretation,
                                    momentID: momentID)
    }

    /// Wait while a fold, Clear, Reset or restore owns the door.
    func enterDoor() async {
        while doorHeld {
            let done = doorDone
            await Task { await done.park() }.value
        }
        doorHeld = true
    }

    /// Waiters must recheck ownership after the door is released.
    func leaveDoor() {
        doorHeld = false
        doorDone.resume()
        doorDone = ScopedWaiter()
    }

    /// The caller must already hold the door.
    func foldInsideDoor(_ context: AfterTurnContext, interpretation: AfterTurnInterpretation?,
                        momentID: String?) async -> Bool {
        guard let momentID, let cognitiveStore, let interpretation,
              var row = await readMoment(momentID), row.meaning != nil, row.state == .meant,
              let record = row.input?.deferred else { return false }
        let seq: UInt64
        if row.foldSeq == nil, context.caring != nil, row.input?.turn?.turnId?.isEmpty != false {
            await noteMomentReadFailed(momentID, why: "The caring appraisal has no heard turn identity.")
            return false
        }
        do {
            guard let assigned = try await cognitiveStore.beginFold(momentID) else { return false }
            seq = assigned
        } catch {
            // Keep the row meant until its once-only proof can be assigned.
            nativeLog("cognition: moment %@ fold not begun: %@", momentID, String(describing: error))
            return false
        }
        // A caring receipt reflects the first fold; refolds cannot rewrite or relabel it.
        if row.foldSeq == nil, let request = context.caring, let heard = row.input?.turn?.turnId {
            await caringReceiptLog.record(request, heard: heard, model: interpretation.model,
                surface: interpretation.surface, verdict: interpretation.caring)
        }
        let mind = await substrate.foldTurn(
            context, record: record, incoming: row.input?.turn?.asked, appraisal: interpretation.affect,
            caring: interpretation.caring, cares: interpretation.cares,
            appAuthored: interpretation.appAuthored, seq: seq, momentID: momentID)
        await caresSourceChanged()
        var reaction: SomaticSignal?
        if !mind.reaction.isEmpty {
            var enriched = mind.event
            enriched.metadata.merge(mind.reaction) { _, new in new }
            reaction = CognitiveSomaticSignals.signal(from: enriched, id: UUID())
        }
        // Use only the retained interpretation's correction decision to raise confidence from a person's correction.
        let corrected = context.careWakes.isEmpty && context.event.sourceClass != .imported && interpretation.memories.contains(where: {
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

    /// Save the body's whole share in one call; preserve first-fold receipt evidence on replay and report failed saves as incomplete.
    private func foldBody(_ fold: OrganismTurnFold) async -> Bool {
        guard !fold.isEmpty else { return true }
        let outcome = await organismKernel.foldTurn(fold)
        let tenderness = { await self.organismKernel.snapshot().chemicalState.tenderness }
        switch outcome {
        case .refused:
            if let reading = fold.caring {
                await caringReceiptLog.amendReceipt(session: reading.session, turn: reading.turn,
                                                       outcome: .refused, tendernessAfter: await tenderness())
            }
            return true
        case .forgotten:
            if let reading = fold.caring {
                await caringReceiptLog.amendReceipt(session: reading.session, turn: reading.turn,
                                                       outcome: .forgotten, tendernessAfter: await tenderness())
            }
            return true
        case .alreadyLived:
            break
        case .lived(let caring):
            if let caring, let reading = fold.caring {
                await caringReceiptLog.amendReceipt(session: reading.session, turn: reading.turn,
                                                       outcome: caring, tendernessAfter: await tenderness())
            }
        }
        cachedBodyRead = nil
        let saved = await persistOrganismContinuity(reason: "lived moment")
        await substrate.adoptRecentDoses(await organismKernel.recentDoses())
        publishRuntimeChange(reason: "after_turn_interpretation")
        return saved
    }

    /// Recover interrupted sequenced folds before newer admission so later stamps cannot overtake unfinished pieces.
    /// Skip pieces already at the sequence; the interpretation owner drains facts and lived settlement after opening.
    func refoldCutMoments() async {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL,
              let life = try? DataRootLife.current(in: dataRoot) else { return }
        guard let rows = await readMoments(states: [.meant]) else { return }
        for row in rows where row.life == life && row.kind == "turn" && row.foldSeq != nil {
            guard let record = row.input?.deferred,
                  let meaning = row.meaning.flatMap(AdaptiveMemoryPromoter.decodedMeaning) else { continue }
            do {
                let context = try await substrate.afterTurnContext(record: record,
                    careWakes: row.input?.turn?.isCareWake == true ? row.input?.turn?.careWakes ?? [] : [])
                _ = await foldInsideDoor(context, interpretation: meaning, momentID: row.id)
            } catch {
                RepairOwed.owe(dataRoot, id: "moment-context:" + row.id, kind: .run,
                    operation: "cognition.moment.context:" + row.id, owner: "memory/embedding",
                    words: "This recorded moment's care context remains unavailable: \(error.localizedDescription)",
                    tap: "Repair the embedding owner in Settings → Memory. Its completed shares will not be repeated.")
            }
        }
    }

    /// Retain settled identity beyond redelivery while bounding journal growth; unsettled rows never expire.
    static let settledMomentRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Prune only settled expired rows; owed and meant moments survive for wake recovery.
    func liveOwedMomentsAtWake() async {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else { return }
        do {
            try await cognitiveStore?.pruneMoments(settledBefore: now().addingTimeInterval(-Self.settledMomentRetention))
        } catch {
            nativeLog("cognition: settled moments not pruned (next wake tries again): %@", String(describing: error))
        }
        await AdaptiveMemoryPromoter.shared.drainOwedMomentsAtWake()
    }

    /// An unrecorded turn cannot change the agent; retain a named repair obligation and still attempt its receipt.
    func noteMomentUnrecorded(_ id: String, why: String) async {
        nativeLog("cognition: lived moment %@ not recorded, not folded: %@", id, why)
        RepairOwed.owe(dataRoot, id: "cognition.moment.unrecorded:" + id, kind: .run,
            evidence: [.init(source: "lived_moments", id: id)],
            operation: "cognition.moment.unrecorded", owner: "cognition",
            words: "A settled turn (\(id)) could not be recorded in the agent's journal, so it has not changed the agent: \(String(why.prefix(240)))")
        await substrate.recordReceipt(kind: "lived_moment.unrecorded", payload: .object([
            "moment": .string(id), "why": .string(String(why.prefix(240))),
        ]))
    }

    /// Wrong-shaped stored meaning is damage, never permission to judge again.
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
            // A cancelled read failed nothing; the moment stays owed and owes no repair.
            if error is CancellationError || Task.isCancelled { return nil }
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
            if error is CancellationError || Task.isCancelled { return nil }
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

    /// A moment that lived was read, and a journal that reads has been read: neither owes a read repair.
    /// Paid at opening, because settlement is a queued write that a quit can lose.
    private func settleReadRepairsAlreadyPaid() async {
        guard let cognitiveStore, let open = try? await ExperienceStore.at(dataRoot).open() else { return }
        let prefix = "cognition.moment.read:"
        for operation in Set(open.filter(RepairOwed.isOwed).compactMap { RepairDebt($0).operation })
        where operation.hasPrefix(prefix) {
            let id = String(operation.dropFirst(prefix.count))
            let read: Bool
            if id == "journal" { read = await readMoments(states: [.owed, .meant]) != nil }
            else { read = (try? await cognitiveStore.loadMoment(id))?.state == .lived }
            if read { RepairOwed.settle(dataRoot, operation: operation, evidence: .init(source: "lived_moments", id: id)) }
        }
    }
}

/// Report final saves and unlived journal count; nil means the count could not be read.
public struct NativeCognitionSleepOutcome: Sendable, Equatable {
    public let substrate: String
    public let body: String
    public let unlivedMoments: Int?

    public var summary: String {
        "substrate \(substrate); body \(body); unlived moments \(unlivedMoments.map(String.init) ?? "unknown")"
    }
}

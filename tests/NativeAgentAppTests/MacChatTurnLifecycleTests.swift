import Foundation
import Testing
import ChatOrchestration
import NativeAgentCore
@testable import NativeAgentApp

@Suite("Mac Chat turn lifecycle", .serialized)
struct MacChatTurnLifecycleTests {
    @Test func reducerCoversActiveTransitionFamiliesAndMonotonicMovement() throws {
        let identity = route(session: "session-a", turn: "turn-a")
        var state = MacChatTurnLifecycleState(identity: identity, startedAt: time(0))

        #expect(state.presentation.phase == .acknowledged)
        #expect(state.presentation.startedAt == time(0))
        #expect(state.presentation.lastMovementAt == time(0))
        #expect(state.presentation.activities.isEmpty)
        #expect(state.terminalEvidence == nil)

        state = reduce(state, .working(action: "Preparing"), at: 1)
        #expect(state.presentation.phase == .working)
        #expect(state.presentation.currentAction == "Preparing")

        state = reduce(
            state,
            .activity(activity(identity: identity, phase: .tool, action: "Using tool: read_file", at: 2)),
            at: 99
        )
        #expect(state.presentation.phase == .tool)
        #expect(state.presentation.lastMovementAt == time(2))

        state = reduce(
            state,
            .activity(activity(
                identity: identity,
                phase: .delegation,
                action: "Waiting for a bounded worker result",
                delegate: "Codex",
                at: 3
            )),
            at: 99
        )
        #expect(state.presentation.phase == .delegation)
        #expect(state.presentation.delegateName == "Codex")

        state = reduce(state, .retrying(action: "Trying a narrower call"), at: 4)
        #expect(state.presentation.phase == .retrying)
        state = reduce(state, .waiting(action: "Waiting for approval"), at: 5)
        #expect(state.presentation.phase == .waiting)
        state = reduce(state, .blocked(reason: "Approval required"), at: 6)
        #expect(state.presentation.phase == .blocked)
        #expect(state.presentation.lastMovementAt == time(6))

        let olderEvent = reduce(state, .working(action: "Resumed"), at: 2)
        #expect(olderEvent.presentation.phase == .working)
        #expect(olderEvent.presentation.lastMovementAt == time(6))
        #expect(olderEvent.presentation.activities.last?.occurredAt == time(6))
        #expect(olderEvent.presentation.activities.map(\.phase) == [
            .working, .tool, .delegation, .retrying, .waiting, .blocked, .working,
        ])
    }

    @Test func streamProgressStoresOnlyLengthEvidenceAndCoalescesDuplicates() {
        let identity = route(session: "session-a", turn: "turn-a")
        let initial = MacChatTurnLifecycleState(identity: identity, startedAt: time(0))
        let working = reduce(initial, .working(action: "Generating"), at: 1)
        let first = reduce(working, .streamProgress(accumulatedUTF16Length: 17), at: 2)
        let duplicate = reduce(first, .streamProgress(accumulatedUTF16Length: 17), at: 50)
        let growth = reduce(first, .streamProgress(accumulatedUTF16Length: 31), at: 3)

        #expect(first.presentation.phase == .working)
        #expect(first.presentation.lastMovementAt == time(2))
        #expect(duplicate == first)
        #expect(growth.presentation.lastMovementAt == time(3))
        #expect(growth.presentation.activities.count == first.presentation.activities.count + 1)
        #expect(!String(reflecting: growth).contains("assistant output"))
    }

    @Test func stallIsDerivedWithoutMutationAndFreshMovementRecovers() {
        let identity = route(session: "session-a", turn: "turn-a")
        let initial = MacChatTurnLifecycleState(identity: identity, startedAt: time(0))
        let working = reduce(initial, .working(action: "Working"), at: 10)

        #expect(working.effectivePhase(at: time(99), stalledAfter: 90) == .working)
        #expect(working.effectivePhase(at: time(100), stalledAfter: 90) == .stalled)
        #expect(working.presentation.phase == .working)

        let recovered = reduce(
            working,
            .streamProgress(accumulatedUTF16Length: 1),
            at: 101
        )
        #expect(recovered.effectivePhase(at: time(102), stalledAfter: 90) == .working)
        #expect(recovered.presentation.lastMovementAt == time(101))

        let waiting = reduce(recovered, .waiting(action: "Waiting"), at: 103)
        let blocked = reduce(recovered, .blocked(reason: "Blocked"), at: 103)
        #expect(waiting.effectivePhase(at: time(1_000), stalledAfter: 90) == .waiting)
        #expect(blocked.effectivePhase(at: time(1_000), stalledAfter: 90) == .blocked)
    }

    @Test func cancellationRequestIsNotCancellationProof() {
        let identity = route(session: "session-a", turn: "turn-a")
        let working = reduce(
            MacChatTurnLifecycleState(identity: identity, startedAt: time(0)),
            .working(action: "Working"),
            at: 1
        )
        let requested = reduce(working, .cancellationRequested, at: 3)
        let requestedAgain = reduce(requested, .cancellationRequested, at: 5)

        #expect(requested.presentation.phase == .working)
        #expect(requested.presentation.isTerminal == false)
        #expect(requested.cancellationRequestedAt == time(3))
        #expect(requested.terminalEvidence == nil)
        #expect(requestedAgain.cancellationRequestedAt == time(3))

        let confirmed = reduce(requestedAgain, .cancellationConfirmed, at: 6)
        #expect(confirmed.presentation.phase == .canceled)
        #expect(confirmed.presentation.endedAt == time(6))
        #expect(confirmed.terminalEvidence == .cancellationAcknowledged)
    }

    @Test func terminalOutcomesCarryClosedEvidenceAndAreImmutable() {
        let identity = route(session: "session-a", turn: "turn-a")
        let initial = MacChatTurnLifecycleState(identity: identity, startedAt: time(0))
        let completed = reduce(initial, .completed, at: 1)
        let failed = reduce(initial, .failed(reason: "Typed provider failure"), at: 2)
        let unknown = reduce(initial, .outcomeUnknown(reason: "Transport closed"), at: 3)

        #expect(completed.presentation.phase == .completed)
        #expect(completed.terminalEvidence == .finalResponsePersisted)
        #expect(failed.presentation.phase == .failed)
        #expect(failed.terminalEvidence == .explicitTypedFailure)
        #expect(unknown.presentation.phase == .outcomeUnknown)
        #expect(unknown.terminalEvidence == .interruptedOutcomeUnknown)

        let injectedTerminal = reduce(
            initial,
            .activity(activity(
                identity: identity,
                phase: .completed,
                action: "untrusted terminal",
                at: 1
            )),
            at: 1
        )
        #expect(injectedTerminal == initial)

        #expect(reduce(completed, .failed(reason: "late"), at: 10) == completed)
        #expect(reduce(failed, .completed, at: 10) == failed)
        #expect(reduce(unknown, .cancellationConfirmed, at: 10) == unknown)
    }

    @Test func reducerRefusesWrongTurnAndWrongSessionIdentity() {
        let identity = route(session: "session-a", turn: "turn-a")
        let state = MacChatTurnLifecycleState(identity: identity, startedAt: time(0))
        let wrongTurn = MacChatTurnLifecycleInput(
            identity: route(session: "session-a", turn: "turn-b"),
            kind: .working(action: "wrong"),
            occurredAt: time(1)
        )
        let wrongSession = MacChatTurnLifecycleInput(
            identity: route(session: "session-b", turn: "turn-a"),
            kind: .working(action: "wrong"),
            occurredAt: time(1)
        )

        #expect(MacChatTurnLifecycleReducer.reduce(state, input: wrongTurn) == state)
        #expect(MacChatTurnLifecycleReducer.reduce(state, input: wrongSession) == state)
    }

    @Test func terminalResolverUsesCanonicalProofThenTypedSignals() {
        let typedFailure = MacChatTurnObservedTerminalSignal.explicitFailure("typed")

        #expect(MacChatTurnLifecycleTerminalResolver.resolve(
            transcriptProof: .completed,
            observedSignal: typedFailure
        ) == .completed)
        #expect(MacChatTurnLifecycleTerminalResolver.resolve(
            transcriptProof: .failed,
            observedSignal: .finalResponse
        ) == .failed(reason: nil))
        #expect(MacChatTurnLifecycleTerminalResolver.resolve(
            transcriptProof: .canceled,
            observedSignal: typedFailure
        ) == .cancellationConfirmed)
        #expect(MacChatTurnLifecycleTerminalResolver.resolve(
            transcriptProof: .absent,
            observedSignal: typedFailure
        ) == .failed(reason: "typed"))
        #expect(MacChatTurnLifecycleTerminalResolver.resolve(
            transcriptProof: .absent,
            observedSignal: .cancellationAcknowledged
        ) == .cancellationConfirmed)

        // An untyped, cancellation-shaped stream terminal is NOT proof. With a
        // canonical receipt the receipt decides; without one the turn must stay
        // outcome-unknown rather than present as a quiet cancel or a failure.
        #expect(MacChatTurnLifecycleTerminalResolver.resolve(
            transcriptProof: .canceled,
            observedSignal: .ambiguousTermination
        ) == .cancellationConfirmed)
        #expect(MacChatTurnLifecycleTerminalResolver.resolve(
            transcriptProof: .failed,
            observedSignal: .ambiguousTermination
        ) == .failed(reason: nil))
        #expect(MacChatTurnLifecycleTerminalResolver.resolve(
            transcriptProof: .absent,
            observedSignal: .ambiguousTermination
        ) == .outcomeUnknown(
            reason: "The turn stopped without a provable cancellation receipt."
        ))
        // Ambiguity survives a consumer-side stop: it still cannot be upgraded
        // into a confirmed cancellation.
        #expect(MacChatTurnLifecycleTerminalResolver.signalAfterConsumerCancellation(
            .ambiguousTermination
        ) == .ambiguousTermination)

        let finalWithoutProof = MacChatTurnLifecycleTerminalResolver.resolve(
            transcriptProof: .absent,
            observedSignal: .finalResponse
        )
        let noSignal = MacChatTurnLifecycleTerminalResolver.resolve(
            transcriptProof: .absent,
            observedSignal: .none
        )
        #expect(finalWithoutProof == .outcomeUnknown(
            reason: "The turn ended without a provable terminal outcome."
        ))
        #expect(noSignal == finalWithoutProof)
        #expect(MacChatTurnLifecycleTerminalResolver.resolve(
            transcriptProof: .unavailable,
            observedSignal: typedFailure
        ) == .outcomeUnknown(reason: "Canonical turn evidence could not be read safely."))
        #expect(MacChatTurnLifecycleTerminalResolver.signalAfterConsumerCancellation(
            typedFailure
        ) == typedFailure)
        #expect(MacChatTurnLifecycleTerminalResolver.signalAfterConsumerCancellation(
            .finalResponse
        ) == .none)
    }

    @Test func streamTerminalEvidenceIsTypedRedactedAndCancellationSpecific() throws {
        let secret = "sk-proj-" + String(repeating: "B", count: 36)
        let failed = NativeClient.MetaBox()
        failed.recordExplicitStreamError("Provider rejected \(secret) " + String(repeating: "detail ", count: 40))
        guard case .explicitFailure(let safeReason)? = failed.terminalEvidence() else {
            Issue.record("Expected typed failure evidence")
            return
        }
        #expect(!safeReason.contains(secret))
        #expect(safeReason.count <= TurnPresentationReducer.textLimit)

        // A cancellation-shaped stream STRING is ambiguous by construction: the
        // core emits it on cancel, and a provider failure whose whole message
        // is "cancelled" is byte-identical. It must never assert a cancel.
        for ambiguous in ["CancellationError()", "cancelled", "Canceled", "  CANCELLED "] {
            let box = NativeClient.MetaBox()
            box.recordExplicitStreamError(ambiguous)
            #expect(
                box.terminalEvidence() == .ambiguousTermination,
                "untyped \(ambiguous) must not claim a cancellation"
            )
        }

        // Only a TYPED cancellation observed at the adapter's own boundary may
        // claim cancellation acknowledgement.
        let typedCancel = NativeClient.MetaBox()
        typedCancel.recordCancellationAcknowledged()
        #expect(typedCancel.terminalEvidence() == .cancellationAcknowledged)

        let merelySimilar = NativeClient.MetaBox()
        merelySimilar.recordExplicitStreamError("provider cancelled upstream request")
        guard case .explicitFailure? = merelySimilar.terminalEvidence() else {
            Issue.record("Cancellation classification must remain closed")
            return
        }

        let final = NativeClient.MetaBox()
        final.recordFinalResponse()
        #expect(final.terminalEvidence() == .finalResponse)
    }

    @Test func producerCompletionJoinIsExplicitAndIdempotent() async {
        let box = NativeClient.MetaBox()
        #expect(box.producerHasFinished == false)
        let waiter = Task {
            await box.waitForProducerTermination()
            return true
        }
        await Task.yield()
        #expect(box.producerHasFinished == false)
        box.recordProducerFinished()
        box.recordProducerFinished()
        #expect(await waiter.value)
        #expect(box.producerHasFinished)
    }

    @Test func surfaceErrorClosesPromptlyButProducerReceiptWaitsForCoreEOF() async {
        let errorYielded = ScopedWaiter()
        let allowCoreEOF = ScopedWaiter()
        let core = AsyncThrowingStream<TurnStreamEvent, Error> { continuation in
            Task {
                continuation.yield(.error("cancelled"))
                errorYielded.resume()
                await allowCoreEOF.park()
                continuation.finish()
            }
        }
        let identity = route(session: "session-a", turn: "turn-a")
        let meta = NativeClient.MetaBox()
        let surface = AsyncThrowingStream<String, Error> { continuation in
            Task {
                defer { meta.recordProducerFinished() }
                await NativeClient.bridgeChatStreamEvents(
                    core,
                    sessionId: identity.sessionId,
                    activityIdentity: identity,
                    metaBox: meta,
                    firstToken: NativeClient.FirstTokenFlag(),
                    cancelSlowWatch: {},
                    onTurnActivity: { _ in },
                    continuation: continuation
                )
            }
        }
        let consumer = Task {
            do {
                for try await _ in surface {}
                return false
            } catch {
                return true
            }
        }

        await errorYielded.park()
        #expect(await consumer.value)
        // The core yielded the untyped "cancelled" marker, so the adapter
        // records ambiguity — the canonical receipt, not this string, decides.
        #expect(meta.terminalEvidence() == .ambiguousTermination)
        #expect(meta.producerHasFinished == false)

        allowCoreEOF.resume()
        await meta.waitForProducerTermination()
        #expect(meta.producerHasFinished)
    }

    @Test func restartRepairUsesProofAndPreservesClosedRecords() throws {
        let identity = route(session: "session-a", turn: "turn-a")
        let activeState = reduce(
            MacChatTurnLifecycleState(identity: identity, startedAt: time(0)),
            .working(action: "Working"),
            at: 1
        )
        let activeRecord = try persisted(activeState)

        let completed = try #require(MacChatTurnLifecycleRestartRepair.repair(
            record: activeRecord,
            transcriptProof: .completed,
            at: time(10)
        ))
        let failed = try #require(MacChatTurnLifecycleRestartRepair.repair(
            record: activeRecord,
            transcriptProof: .failed,
            at: time(10)
        ))
        let canceled = try #require(MacChatTurnLifecycleRestartRepair.repair(
            record: activeRecord,
            transcriptProof: .canceled,
            at: time(10)
        ))
        let ambiguous = try #require(MacChatTurnLifecycleRestartRepair.repair(
            record: activeRecord,
            transcriptProof: .absent,
            at: time(10)
        ))

        #expect(completed.presentation.phase == .completed)
        #expect(completed.terminalEvidence == .finalResponsePersisted)
        #expect(failed.presentation.phase == .failed)
        #expect(failed.terminalEvidence == .explicitTypedFailure)
        #expect(canceled.presentation.phase == .canceled)
        #expect(canceled.terminalEvidence == .cancellationAcknowledged)
        #expect(ambiguous.presentation.phase == .outcomeUnknown)
        #expect(ambiguous.terminalEvidence == .interruptedOutcomeUnknown)

        let terminalRecord = try persisted(failed)
        let preserved = try #require(MacChatTurnLifecycleRestartRepair.repair(
            record: terminalRecord,
            transcriptProof: .completed,
            at: time(20)
        ))
        #expect(preserved.presentation.phase == .failed)
        #expect(preserved.presentation.endedAt == failed.presentation.endedAt)
        #expect(preserved.terminalEvidence == .explicitTypedFailure)
    }

    @Test @MainActor func appModelRestartRepairIsSessionScopedAndRetriesUnindexedRecords() async throws {
        let a = reduce(
            MacChatTurnLifecycleState(
                identity: route(session: "session-a", turn: "turn-a"),
                startedAt: time(0)
            ),
            .working(action: "Working"),
            at: 1
        )
        let b = reduce(
            MacChatTurnLifecycleState(
                identity: route(session: "session-b", turn: "turn-b"),
                startedAt: time(0)
            ),
            .waiting(action: "Waiting"),
            at: 1
        )
        let c = reduce(
            MacChatTurnLifecycleState(
                identity: route(session: "session-c", turn: "turn-c"),
                startedAt: time(0)
            ),
            .working(action: "Detached turn is live"),
            at: 1
        )
        let storage = LifecycleMemoryStorage([
            try persisted(a), try persisted(b), try persisted(c),
        ])
        let model = AppModel()
        model.chatTurnLifecycleStore = MacChatTurnLifecycleStore(
            storage: storage,
            maximumRecords: 4
        )
        _ = model.beginChatTurnLifecycle(
            sessionId: c.identity.sessionId,
            turnId: c.identity.turnId,
            at: time(0)
        )
        _ = model.applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: c.identity,
            kind: .working(action: "Detached turn is live"),
            occurredAt: time(1)
        ))

        await model.repairChatTurnLifecyclesIfNeeded(
            knownSessionIds: ["session-a"],
            at: time(10)
        ) { identity in
            identity.sessionId == "session-a" ? .completed : .absent
        }
        #expect(model.chatTurnLifecycle(for: "session-a")?.presentation.phase == .completed)
        #expect(model.chatTurnLifecycle(for: "session-b") == nil)
        // Repair is still pending for exactly ONE reason: session-c is unindexed
        // AND has a live turn this process still owns, so its outcome is not yet
        // decidable. session-b is unindexed too, but it was just settled from
        // canonical evidence and therefore must NOT contribute to the pending
        // state — see settledTombstoneForDeletedSessionDoesNotPinRepairForever.
        #expect(model.chatTurnLifecycleRepairCompleted == false)
        #expect(model.activeChatTurnLifecycleIDsBySession["session-c"] == "turn-c")
        #expect(try await model.chatTurnLifecycleStore.records().first(where: {
            $0.sessionId == "session-b"
        })?.phase == .outcomeUnknown)
        #expect(try await model.chatTurnLifecycleStore.records().first(where: {
            $0.sessionId == "session-c"
        })?.phase == .working)
        #expect(model.chatTurnLifecycle(for: "session-c")?.presentation.phase == .working)

        await model.repairChatTurnLifecyclesIfNeeded(
            knownSessionIds: ["session-a", "session-b", "session-c"],
            at: time(20)
        ) { _ in
            Issue.record("Terminal restart records must not be re-probed")
            return .absent
        }
        #expect(model.chatTurnLifecycle(for: "session-b")?.presentation.phase == .outcomeUnknown)
        #expect(model.chatTurnLifecycleRepairCompleted)
    }

    /// Repair writes the per-session projection directly, bypassing the reducer
    /// and store guards that elsewhere enforce terminal immutability. A turn the
    /// user already saw resolve must not be downgraded to outcome-unknown just
    /// because its durable row lagged behind or the transcript briefly could not
    /// be read.
    @Test @MainActor func repairNeverDowngradesAnAlreadyTerminalInMemoryTurn() async throws {
        let identity = route(session: "session-a", turn: "turn-a")
        let working = reduce(
            MacChatTurnLifecycleState(identity: identity, startedAt: time(0)),
            .working(action: "Working"),
            at: 1
        )
        // Disk still holds the NON-terminal row: the terminal write failed.
        let storage = LifecycleMemoryStorage([try persisted(working)])
        let model = AppModel()
        model.chatTurnLifecycleStore = MacChatTurnLifecycleStore(
            storage: storage,
            maximumRecords: 4
        )
        // Memory holds the settled truth the user already saw.
        let completed = MacChatTurnLifecycleReducer.reduce(
            working,
            input: MacChatTurnLifecycleInput(
                identity: identity,
                kind: .completed,
                occurredAt: time(2)
            )
        )
        #expect(completed.presentation.phase == .completed)
        model.chatTurnLifecycleBySession[identity.sessionId] = completed

        // A transient transcript read failure must not rewrite that outcome.
        await model.repairChatTurnLifecyclesIfNeeded(
            knownSessionIds: [identity.sessionId],
            at: time(10)
        ) { _ in .unavailable }

        #expect(model.chatTurnLifecycle(for: identity.sessionId)?.presentation.phase == .completed)
        #expect(
            model.chatTurnLifecycle(for: identity.sessionId)?.terminalEvidence
                == .finalResponsePersisted
        )
        // The lagging durable row is reconciled UP to the proven terminal,
        // never down to outcome-unknown.
        let stored = try await model.chatTurnLifecycleStore.records()
        #expect(stored.first?.phase == .completed)
        #expect(stored.first?.terminalEvidence == .finalResponsePersisted)
    }

    /// A session the user DELETED never returns to the index, so its lifecycle
    /// row is a permanent tombstone. Once repair has settled that row there is
    /// no outcome work left in it, and it must not pin repair "incomplete" for
    /// the remaining life of the process — otherwise the one bounded launch
    /// repair silently becomes an unbounded per-send repair forever.
    @Test @MainActor func settledTombstoneForDeletedSessionDoesNotPinRepairForever() async throws {
        let orphan = reduce(
            MacChatTurnLifecycleState(
                identity: route(session: "session-deleted", turn: "turn-deleted"),
                startedAt: time(0)
            ),
            .working(action: "Working"),
            at: 1
        )
        let storage = LifecycleMemoryStorage([try persisted(orphan)])
        let model = AppModel()
        model.chatTurnLifecycleStore = MacChatTurnLifecycleStore(
            storage: storage,
            maximumRecords: 4
        )

        var probes = 0
        // The session is gone from the index and no turn is live for it.
        let first = await model.repairChatTurnLifecyclesIfNeeded(
            knownSessionIds: ["session-live"],
            at: time(10)
        ) { _ in
            probes += 1
            return .absent
        }
        #expect(first)
        #expect(probes == 1)
        #expect(try await model.chatTurnLifecycleStore.records().first?.phase == .outcomeUnknown)
        // The row was settled from canonical evidence; nothing is still pending.
        #expect(model.chatTurnLifecycleRepairCompleted)

        // The short-circuit now actually holds: no reload, no re-probe.
        let second = await model.repairChatTurnLifecyclesIfNeeded(
            knownSessionIds: ["session-live"],
            at: time(20)
        ) { _ in
            Issue.record("A settled tombstone must never be probed again")
            return .absent
        }
        #expect(second)
        #expect(probes == 1)
        // Terminal evidence survives; the tombstone is not silently discarded.
        let remaining = try await model.chatTurnLifecycleStore.records()
        #expect(remaining.count == 1)
        #expect(remaining.first?.terminalEvidence == .interruptedOutcomeUnknown)
    }

    @Test @MainActor func durableAdmissionFailureRejectsAndDoesNotStrandQueuedWork() async throws {
        let storage = GatedFailingLifecycleStorage()
        let model = AppModel()
        model.chatTurnLifecycleStore = MacChatTurnLifecycleStore(
            storage: storage,
            maximumRecords: 4
        )
        model.chatSessions = [try JSONDecoder().decode(ChatSession.self, from: Data("""
        {
          "id": "session-a",
          "title": "Lifecycle admission test",
          "createdAt": "2026-08-19T00:00:00Z"
        }
        """.utf8))]

        let first = Task { @MainActor in
            await model.startChatTurnForSession("first", sessionId: "session-a")
        }
        await storage.waitForFirstSave()
        let queued = await model.startChatTurnForSession("second", sessionId: "session-a")
        guard case .queued(let sessionId, _) = queued else {
            Issue.record("A turn arriving during durable admission must queue")
            await storage.releaseFirstSave()
            _ = await first.value
            return
        }
        #expect(sessionId == "session-a")
        await storage.releaseFirstSave()

        guard case .rejected = await first.value else {
            Issue.record("A failed lifecycle receipt must reject provider admission")
            return
        }
        #expect(model.chatTasks["session-a"] == nil)
        #expect(!model.busySessions.contains("session-a"))
        #expect(!model.streamingSessions.contains("session-a"))
        #expect(model.chatTurnLifecycle(for: "session-a") == nil)
        #expect(model.queuedChatTurnsBySession["session-a"]?.map(\.text) == ["second"])
        #expect(model.pausedChatQueueSessions.contains("session-a"))
    }

    @Test @MainActor func detachedSendRejectsAStaleSessionBeforeDurableAdmission() async {
        let storage = LifecycleMemoryStorage()
        let model = AppModel()
        model.chatTurnLifecycleStore = MacChatTurnLifecycleStore(storage: storage)
        model.chatSessions = []

        let acceptance = await model.startChatTurnForSession(
            "must not run",
            sessionId: "deleted-session"
        )
        guard case .rejected = acceptance else {
            Issue.record("A stale detached session was admitted")
            return
        }
        #expect(model.chatTasks.isEmpty)
        #expect(model.chatTurnLifecycle(for: "deleted-session") == nil)
        #expect((try? await model.chatTurnLifecycleStore.records())?.isEmpty == true)
    }

    @Test @MainActor func failedTerminalWritesInvalidateRepairAndRecoverFromCanonicalProof() async throws {
        let storage = FailSelectedLifecycleSavesStorage(failingSaves: [2, 3])
        let model = AppModel()
        model.chatTurnLifecycleStore = MacChatTurnLifecycleStore(storage: storage)
        let identity = route(session: "session-a", turn: "turn-a")
        _ = model.beginChatTurnLifecycle(
            sessionId: identity.sessionId,
            turnId: identity.turnId,
            at: time(0)
        )
        #expect(await model.persistChatTurnLifecycleBegin(identity: identity))
        model.chatTurnLifecycleRepairCompleted = true

        let settled = await model.settleChatTurnLifecycle(
            identity: identity,
            kind: .completed,
            at: time(1)
        )
        #expect(settled?.presentation.phase == .completed)
        #expect(model.chatTurnLifecycleRepairCompleted == false)
        let closed = try #require(model.closeChatTurnLifecycleIntake(
            sessionId: identity.sessionId,
            turnId: identity.turnId,
            at: time(2)
        ))
        #expect(await model.persistChatTurnLifecycleUpdate(identity: closed.identity) == false)
        #expect(model.chatTurnLifecycleRepairCompleted == false)

        let repaired = await model.repairChatTurnLifecyclesIfNeeded(
            knownSessionIds: [identity.sessionId],
            at: time(3)
        ) { repairedIdentity in
            #expect(repairedIdentity == identity)
            return .completed
        }
        #expect(repaired)
        #expect(model.chatTurnLifecycleRepairCompleted)
        #expect(try await model.chatTurnLifecycleStore.records().first?.phase == .completed)
    }

    @Test func retrySnapshotRefusesChangedHistoryAndAttachmentReplay() throws {
        let older = ChatMessage(id: "assistant-old", sessionId: "session-a", role: "assistant", content: "Old")
        let user = ChatMessage(id: "user-a", sessionId: "session-a", role: "user", content: "Try this")
        let target = ChatMessage(id: "assistant-a", sessionId: "session-a", role: "assistant", content: "Answer")
        let messages = [older, user, target]
        let snapshot = try #require(MacChatRetrySnapshot.capture(
            target: target,
            messages: messages,
            sessionId: "session-a",
            isSyntheticNotice: false
        ))

        #expect(snapshot.stillMatchesLocal(messages))
        #expect(snapshot.matchesCanonical(messages))
        #expect(!snapshot.matchesCanonical(messages + [
            ChatMessage(id: "user-b", sessionId: "session-a", role: "user", content: "New turn"),
        ]))
        #expect(!snapshot.stillMatchesLocal(messages + [
            ChatMessage(id: "assistant-b", sessionId: "session-a", role: "assistant", content: "New answer"),
        ]))

        let synthetic = ChatMessage(
            id: "na-synthetic-error-a",
            sessionId: "session-a",
            role: "assistant",
            content: "Use Try again",
            metadata: .syntheticError(
                "route unavailable",
                userRowPersisted: false,
                inputHadAttachments: true
            )
        )
        let syntheticMessages = [older, user, synthetic]
        let syntheticSnapshot = try #require(MacChatRetrySnapshot.capture(
            target: synthetic,
            messages: syntheticMessages,
            sessionId: "session-a",
            isSyntheticNotice: true
        ))
        #expect(syntheticSnapshot.inputHadAttachments)
        #expect(syntheticSnapshot.matchesCanonical([older]))
        #expect(!syntheticSnapshot.matchesCanonical([older, user]))
    }

    @Test func persistenceProjectionRedactsTruncatesAndRoundTripsWithoutPayloads() throws {
        let identity = route(session: "session-a", turn: "turn-a")
        let secret = "sk-proj-" + String(repeating: "A", count: 36)
        let rawAction = "Working with \(secret) " + String(repeating: "bounded ", count: 80)
        let state = reduce(
            MacChatTurnLifecycleState(identity: identity, startedAt: time(0)),
            .working(action: rawAction),
            at: 1
        )
        let record = try persisted(state)
        let data = try JSONEncoder().encode(record)
        let serialized = try #require(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(MacChatPersistedTurnLifecycle.self, from: data)
        let restored = try #require(decoded.restoredState())

        #expect(record.currentAction?.count == TurnPresentationReducer.textLimit)
        #expect(!(record.currentAction ?? "").contains(secret))
        #expect(!serialized.contains(secret))
        #expect(!serialized.contains("activities"))
        #expect(!serialized.contains("streamedText"))
        #expect(decoded == record)
        #expect(restored.identity == identity)
        #expect(restored.presentation.phase == .working)
        #expect(restored.presentation.currentAction == record.currentAction)
        let pathological = "e" + String(repeating: "\u{0301}", count: 2_000)
        let pathologicalState = reduce(
            MacChatTurnLifecycleState(identity: identity, startedAt: time(0)),
            .working(action: pathological),
            at: 1
        )
        let boundedPathological = try persisted(pathologicalState)
        #expect((boundedPathological.currentAction?.unicodeScalars.count ?? 0)
            <= TurnPresentationReducer.textLimit)
        #expect((boundedPathological.currentAction?.utf8.count ?? 0)
            <= TurnPresentationReducer.textLimit * 4)
        #expect(MacChatPersistedTurnLifecycle(state: MacChatTurnLifecycleState(
            identity: route(session: " padded ", turn: "turn-a"),
            startedAt: time(0)
        )) == nil)
        #expect(MacChatPersistedTurnLifecycle(state: MacChatTurnLifecycleState(
            identity: route(session: "bad\nidentity", turn: "turn-a"),
            startedAt: time(0)
        )) == nil)
        #expect(MacChatPersistedTurnLifecycle(state: MacChatTurnLifecycleState(
            identity: route(session: String(repeating: "s", count: 160), turn: "turn-a"),
            startedAt: time(0)
        )) != nil)
        #expect(MacChatPersistedTurnLifecycle(state: MacChatTurnLifecycleState(
            identity: route(session: String(repeating: "s", count: 161), turn: "turn-a"),
            startedAt: time(0)
        )) == nil)
    }

    @Test func persistenceRejectsInconsistentTerminalTimestamps() throws {
        let state = reduce(
            MacChatTurnLifecycleState(
                identity: route(session: "session-a", turn: "turn-a"),
                startedAt: time(0)
            ),
            .completed,
            at: 1
        )
        let record = try persisted(state)
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let movement = try #require(object["lastMovementAt"] as? NSNumber)
        object["endedAt"] = movement.doubleValue + 1
        let malformed = try JSONDecoder().decode(
            MacChatPersistedTurnLifecycle.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(malformed.restoredState() == nil)
    }

    @Test func terminalTimestampCannotPrecedeCancellationRequest() throws {
        let identity = route(session: "session-a", turn: "turn-a")
        let initial = MacChatTurnLifecycleState(identity: identity, startedAt: time(0))
        let requested = reduce(initial, .cancellationRequested, at: 10)
        let canceled = reduce(requested, .cancellationConfirmed, at: 5)

        #expect(canceled.presentation.endedAt == time(10))
        let record = try persisted(canceled)
        #expect(record.cancellationRequestedAt == time(10))
        #expect(record.restoredState() == canceled)
    }

    @Test func actorStoreNeverEvictsActiveRecordsAndEvictsOnlyTerminalHistory() async throws {
        let storage = LifecycleMemoryStorage()
        let store = MacChatTurnLifecycleStore(storage: storage, maximumRecords: 2)
        let a = MacChatTurnLifecycleState(
            identity: route(session: "a", turn: "ta"),
            startedAt: time(0)
        )
        let b = MacChatTurnLifecycleState(
            identity: route(session: "b", turn: "tb"),
            startedAt: time(1)
        )
        let c = MacChatTurnLifecycleState(
            identity: route(session: "c", turn: "tc"),
            startedAt: time(2)
        )
        try await store.begin(a)
        try await store.begin(b)

        do {
            try await store.begin(c)
            Issue.record("A full store of unresolved turns must reject a new record")
        } catch let error as MacChatTurnLifecycleStoreError {
            #expect(error == .capacityExceeded(2))
        }
        #expect(Set(try await store.records().map(\.sessionId)) == ["a", "b"])

        let completedA = reduce(a, .completed, at: 3)
        #expect(try await store.update(completedA))
        try await store.begin(c)
        #expect(Set(try await store.records().map(\.sessionId)) == ["b", "c"])
    }

    @Test func actorStoreRequiresExactTurnForUpdatesAndMigrations() async throws {
        let storage = LifecycleMemoryStorage()
        let store = MacChatTurnLifecycleStore(storage: storage, maximumRecords: 4)
        let old = MacChatTurnLifecycleState(
            identity: route(session: "same", turn: "old"),
            startedAt: time(0)
        )
        let current = MacChatTurnLifecycleState(
            identity: route(session: "same", turn: "current"),
            startedAt: time(1)
        )
        try await store.begin(old)
        try await store.begin(current)
        #expect(try await store.update(reduce(old, .working(action: "stale"), at: 2)) == false)
        #expect(try await store.records().first?.turnId == "current")

        let placeholder = reduce(
            MacChatTurnLifecycleState(
                identity: route(session: "placeholder", turn: "move-me"),
                startedAt: time(3)
            ),
            .working(action: "Moving"),
            at: 4
        )
        try await store.begin(placeholder)
        let rebound = MacChatTurnLifecycleState(
            identity: route(session: "canonical", turn: "move-me"),
            presentation: placeholder.presentation,
            cancellationRequestedAt: nil,
            terminalEvidence: nil
        )
        #expect(try await store.migrate(state: rebound, from: "placeholder"))
        let afterMigration = try await store.records()
        #expect(afterMigration.contains { $0.sessionId == "canonical" && $0.turnId == "move-me" })
        #expect(!afterMigration.contains { $0.sessionId == "placeholder" })

        let closed = reduce(rebound, .failed(reason: "typed"), at: 5)
        #expect(try await store.update(closed))
        #expect(try await store.update(reduce(closed, .completed, at: 6)))
        let conflictingTerminal = reduce(
            MacChatTurnLifecycleState(identity: rebound.identity, startedAt: time(3)),
            .completed,
            at: 6
        )
        #expect(try await store.update(conflictingTerminal) == false)

        let wrongGeneration = MacChatTurnLifecycleState(
            identity: route(session: "elsewhere", turn: "not-present"),
            presentation: placeholder.presentation,
            cancellationRequestedAt: nil,
            terminalEvidence: nil
        )
        #expect(try await store.migrate(
            state: wrongGeneration,
            from: "missing-placeholder"
        ) == false)
    }

    @Test func actorStoreSerializesConcurrentDetachedMutations() async throws {
        let storage = GatedLifecycleStorage()
        let store = MacChatTurnLifecycleStore(storage: storage, maximumRecords: 4)
        let a = MacChatTurnLifecycleState(
            identity: route(session: "detached-a", turn: "turn-a"),
            startedAt: time(0)
        )
        let b = MacChatTurnLifecycleState(
            identity: route(session: "detached-b", turn: "turn-b"),
            startedAt: time(1)
        )

        let first = Task { try await store.begin(a) }
        await storage.waitForFirstSave()
        let second = Task { try await store.begin(b) }
        await storage.releaseFirstSave()
        try await first.value
        try await second.value

        #expect(Set(try await store.records().map(\.sessionId)) == ["detached-a", "detached-b"])
    }

    @Test func migrationSupersedesBoundedDestinationHistory() async throws {
        let destinationHistory = reduce(
            MacChatTurnLifecycleState(
                identity: route(session: "canonical", turn: "prior-turn"),
                startedAt: time(0)
            ),
            .completed,
            at: 1
        )
        let placeholder = reduce(
            MacChatTurnLifecycleState(
                identity: route(session: "placeholder", turn: "current-turn"),
                startedAt: time(2)
            ),
            .working(action: "Working"),
            at: 3
        )
        let storage = LifecycleMemoryStorage([
            try persisted(destinationHistory),
            try persisted(placeholder),
        ])
        let store = MacChatTurnLifecycleStore(storage: storage, maximumRecords: 4)
        let rebound = MacChatTurnLifecycleState(
            identity: route(session: "canonical", turn: "current-turn"),
            presentation: placeholder.presentation,
            cancellationRequestedAt: nil,
            terminalEvidence: nil
        )

        #expect(try await store.migrate(state: rebound, from: "placeholder"))
        let records = try await store.records()
        #expect(records.count == 1)
        #expect(records.first?.identity == rebound.identity)
        #expect(records.first?.phase == .working)
    }

    @Test func fileStorageUsesVersionedCodableEnvelope() async throws {
        let root = try temporaryRoot("lifecycle-file-storage")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("nested/lifecycle.json")
        let storage = MacChatTurnLifecycleFileStorage(fileURL: fileURL)
        let state = reduce(
            MacChatTurnLifecycleState(
                identity: route(session: "session-a", turn: "turn-a"),
                startedAt: time(0)
            ),
            .waiting(action: "Waiting"),
            at: 1
        )
        let record = try persisted(state)

        try await storage.save([record])
        #expect(try await storage.load() == [record])
        let bytes = try Data(contentsOf: fileURL)
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(text.contains("\"turns\""))
    }

    @Test func fileStorageRejectsUnboundedOrIndirectPersistence() async throws {
        let root = try temporaryRoot("lifecycle-file-storage-invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        let oversizedURL = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: MacChatTurnLifecycleFileStorage.maximumBytes + 1)
            .write(to: oversizedURL)
        let oversized = MacChatTurnLifecycleFileStorage(fileURL: oversizedURL)
        await #expect(throws: MacChatTurnLifecycleStoreError.invalidRecord) {
            _ = try await oversized.load()
        }

        let targetURL = root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: targetURL)
        let symlinkURL = root.appendingPathComponent("lifecycle.json")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: targetURL
        )
        let indirect = MacChatTurnLifecycleFileStorage(fileURL: symlinkURL)
        await #expect(throws: MacChatTurnLifecycleStoreError.invalidRecord) {
            _ = try await indirect.load()
        }

        let danglingURL = root.appendingPathComponent("dangling-lifecycle.json")
        try FileManager.default.createSymbolicLink(
            at: danglingURL,
            withDestinationURL: root.appendingPathComponent("missing-target.json")
        )
        await #expect(throws: MacChatTurnLifecycleStoreError.invalidRecord) {
            _ = try await MacChatTurnLifecycleFileStorage(fileURL: danglingURL).load()
        }

        let valid = try persisted(MacChatTurnLifecycleState(
            identity: route(session: "session-a", turn: "turn-a"),
            startedAt: time(0)
        ))
        await #expect(throws: MacChatTurnLifecycleStoreError.invalidRecord) {
            try await MacChatTurnLifecycleFileStorage(
                fileURL: root.appendingPathComponent("too-large-to-save.json")
            ).save(Array(repeating: valid, count: 5_000))
        }
    }

    @Test func transcriptProofReaderAcceptsOnlyExactCanonicalTerminalReceipts() async throws {
        let root = try temporaryRoot("lifecycle-transcript")
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = MacChatTurnTranscriptProofReader(dataRoot: root)

        try writeTranscript([
            transcriptRow(session: "session-a", turn: "other", persistence: "persisted"),
            transcriptRow(session: "session-a", turn: "turn-a", persistence: "persisted"),
            transcriptRow(session: "session-a", turn: "later-other", persistence: "failed"),
        ], session: "session-a", root: root)
        #expect(try await reader.proof(for: route(session: "session-a", turn: "turn-a")) == .completed)
        #expect(try await reader.proof(for: route(session: "session-a", turn: "missing")) == .absent)

        try writeTranscript([
            transcriptRow(session: "failed-session", turn: "failed-turn", persistence: "failed"),
        ], session: "failed-session", root: root)
        #expect(try await reader.proof(
            for: route(session: "failed-session", turn: "failed-turn")
        ) == .failed)

        try writeTranscript([
            transcriptRow(
                session: "canceled-session",
                turn: "canceled-turn",
                persistence: "cancelled",
                partial: true,
                canceled: true
            ),
        ], session: "canceled-session", root: root)
        #expect(try await reader.proof(
            for: route(session: "canceled-session", turn: "canceled-turn")
        ) == .canceled)
    }

    @Test func transcriptProofReaderRejectsPartialMismatchMalformedAndSymlinkEvidence() async throws {
        let root = try temporaryRoot("lifecycle-transcript-invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = MacChatTurnTranscriptProofReader(dataRoot: root)

        try writeTranscript([
            transcriptRow(
                session: "partial-session",
                turn: "partial-turn",
                persistence: "persisted",
                partial: true
            ),
        ], session: "partial-session", root: root)
        #expect(try await reader.proof(
            for: route(session: "partial-session", turn: "partial-turn")
        ) == .absent)

        var mismatch = transcriptRow(
            session: "mismatch-session",
            turn: "mismatch-turn",
            persistence: "persisted"
        )
        var mismatchMetadata = try #require(mismatch["metadata"] as? [String: Any])
        var mismatchObservation = try #require(
            mismatchMetadata["outcomeObservation"] as? [String: Any]
        )
        mismatchObservation["sessionID"] = "different-session"
        mismatchMetadata["outcomeObservation"] = mismatchObservation
        mismatch["metadata"] = mismatchMetadata
        try writeTranscript([mismatch], session: "mismatch-session", root: root)
        await #expect(throws: MacChatTurnTranscriptProofReaderError.invalidEvidence) {
            _ = try await reader.proof(
                for: route(session: "mismatch-session", turn: "mismatch-turn")
            )
        }

        var wrongTypedFlag = transcriptRow(
            session: "wrong-flag-session",
            turn: "wrong-flag-turn",
            persistence: "persisted"
        )
        var wrongFlagMetadata = try #require(
            wrongTypedFlag["metadata"] as? [String: Any]
        )
        wrongFlagMetadata["partial"] = "true"
        wrongTypedFlag["metadata"] = wrongFlagMetadata
        try writeTranscript(
            [wrongTypedFlag],
            session: "wrong-flag-session",
            root: root
        )
        await #expect(throws: MacChatTurnTranscriptProofReaderError.invalidEvidence) {
            _ = try await reader.proof(
                for: route(session: "wrong-flag-session", turn: "wrong-flag-turn")
            )
        }

        var incompleteReceipt = transcriptRow(
            session: "incomplete-session",
            turn: "incomplete-turn",
            persistence: "persisted"
        )
        var incompleteMetadata = try #require(
            incompleteReceipt["metadata"] as? [String: Any]
        )
        incompleteMetadata["outcomeObservation"] = [
            "schema": ResponseOutcomeObservationV2.schema,
            "turnID": "incomplete-turn",
            "sessionID": "incomplete-session",
            "responsePersistence": "persisted",
        ]
        incompleteReceipt["metadata"] = incompleteMetadata
        try writeTranscript(
            [incompleteReceipt],
            session: "incomplete-session",
            root: root
        )
        await #expect(throws: MacChatTurnTranscriptProofReaderError.invalidEvidence) {
            _ = try await reader.proof(
                for: route(session: "incomplete-session", turn: "incomplete-turn")
            )
        }

        let malformedPath = transcriptPath(session: "malformed-session", root: root)
        try FileManager.default.createDirectory(
            at: malformedPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not-json}\n".utf8).write(to: malformedPath)
        await #expect(throws: (any Error).self) {
            try await reader.proof(for: route(session: "malformed-session", turn: "turn-a"))
        }

        let target = root.appendingPathComponent("actual.jsonl")
        try Data("\n".utf8).write(to: target)
        let symlink = transcriptPath(session: "symlink-session", root: root)
        try FileManager.default.createDirectory(
            at: symlink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        await #expect(throws: (any Error).self) {
            try await reader.proof(for: route(session: "symlink-session", turn: "turn-a"))
        }

        let dangling = transcriptPath(session: "dangling-session", root: root)
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: root.appendingPathComponent("missing-transcript.jsonl")
        )
        await #expect(throws: (any Error).self) {
            try await reader.proof(for: route(session: "dangling-session", turn: "turn-a"))
        }

        await #expect(throws: (any Error).self) {
            try await reader.proof(for: route(session: "../escape", turn: "turn-a"))
        }
    }

    @Test func architectureHasNoTelegramDependencyOrCardUIImplementation() throws {
        let lifecycleSource = try AppSourceScraping.appSource("MacChatTurnLifecycle.swift")
        let stateSource = try AppSourceScraping.appSource("AppModel+ChatState.swift")
        let chatSource = try AppSourceScraping.appSource("ChatView.swift")

        #expect(lifecycleSource.contains("import NativeAgentCore"))
        #expect(!lifecycleSource.contains("import TelegramBot"))
        #expect(!lifecycleSource.contains("import SwiftUI"))
        #expect(!lifecycleSource.contains("replyMarkup"))
        #expect(!lifecycleSource.contains("InlineKeyboard"))
        #expect(stateSource.contains("MacChatTurnLifecycleReducer"))
        #expect(!stateSource.contains("nativeAgentTurnLifecycleEvent"))
        #expect(!chatSource.contains("MacChatTurnLifecycle"))
        #expect(!chatSource.contains("MacChatWorkCard"))
    }

    @Test func acceptedAndRetryTurnsBindOneExactIdentityThroughOrchestration() throws {
        let root = try AppSourceScraping.repositoryRoot()
        let actions = try AppSourceScraping.appSource("AppModel+ChatActions.swift")
        let runtime = try AppSourceScraping.appSource("NativeClient+ChatRuntime.swift")
        let facade = try String(
            contentsOf: root.appendingPathComponent(
                "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+StreamFacade.swift"
            ),
            encoding: .utf8
        )
        let compatibility = try String(
            contentsOf: root.appendingPathComponent(
                "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+TextCompatibility.swift"
            ),
            encoding: .utf8
        )

        #expect(actions.contains("turnId: TurnTraceContext.mintTurnId()"))
        #expect(actions.contains("TurnTraceContext.$turnId.withValue(lifecycleIdentity.turnId)"))
        #expect(runtime.contains("TurnTraceContext.$turnId.withValue(activityIdentity.turnId)"))
        #expect(facade.contains("TurnTraceContext.turnId ?? TurnTraceContext.mintTurnId()"))
        #expect(compatibility.contains("TurnTraceContext.turnId ?? TurnTraceContext.mintTurnId()"))
        let markerClear = try #require(compatibility.range(of: "removeItem(at: cancelFlagPath)"))
        let userAppend = try #require(compatibility.range(of: "if !suppressUserAppend"))
        #expect(markerClear.lowerBound < userAppend.lowerBound)
    }

    private func route(session: String, turn: String) -> MacChatTurnIdentity {
        MacChatTurnIdentity(sessionId: session, turnId: turn)
    }

    private func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func reduce(
        _ state: MacChatTurnLifecycleState,
        _ kind: MacChatTurnLifecycleInput.Kind,
        at seconds: TimeInterval
    ) -> MacChatTurnLifecycleState {
        MacChatTurnLifecycleReducer.reduce(
            state,
            input: MacChatTurnLifecycleInput(
                identity: state.identity,
                kind: kind,
                occurredAt: time(seconds)
            )
        )
    }

    private func activity(
        identity: MacChatTurnIdentity,
        phase: TurnPresentationPhase,
        action: String,
        delegate: String? = nil,
        at seconds: TimeInterval
    ) -> MacChatTurnActivity {
        MacChatTurnActivity(
            identity: identity,
            source: .notice(kind: "test"),
            phase: phase,
            toolDisplayName: phase == .tool ? "read_file" : nil,
            actionSummary: action,
            userVisibleNoticeText: nil,
            delegateDisplayName: delegate,
            occurredAt: time(seconds)
        )
    }

    private func persisted(
        _ state: MacChatTurnLifecycleState
    ) throws -> MacChatPersistedTurnLifecycle {
        try #require(MacChatPersistedTurnLifecycle(state: state))
    }

    private func temporaryRoot(_ prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func transcriptPath(session: String, root: URL) -> URL {
        root.appendingPathComponent("chat/messages/\(session).jsonl")
    }

    private func writeTranscript(
        _ rows: [[String: Any]],
        session: String,
        root: URL
    ) throws {
        let path = transcriptPath(session: session, root: root)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: path, options: .atomic)
    }

    private func transcriptRow(
        session: String,
        turn: String,
        persistence: String,
        partial: Bool = false,
        canceled: Bool = false
    ) -> [String: Any] {
        let messageId = "message-\(turn)"
        return [
            "id": messageId,
            "sessionId": session,
            "role": "assistant",
            "source": "app",
            "content": "discarded by proof reader",
            "metadata": [
                "turnTraceId": turn,
                "partial": partial,
                "cancelled": canceled,
                "outcomeObservation": [
                    "schema": ResponseOutcomeObservationV2.schema,
                    "turnID": turn,
                    "messageID": messageId,
                    "sessionID": session,
                    "surface": "app",
                    "observedAt": "1970-01-01T00:00:01Z",
                    "responsePersistence": persistence,
                    "tools": [],
                    "motorActions": [],
                    "dimensionStates": [:],
                ],
            ],
        ]
    }
}

private actor LifecycleMemoryStorage: MacChatTurnLifecycleStorage {
    private var stored: [MacChatPersistedTurnLifecycle]

    init(_ initial: [MacChatPersistedTurnLifecycle] = []) {
        stored = initial
    }

    func load() async throws -> [MacChatPersistedTurnLifecycle] {
        stored
    }

    func save(_ records: [MacChatPersistedTurnLifecycle]) async throws {
        stored = records
    }
}

private actor GatedLifecycleStorage: MacChatTurnLifecycleStorage {
    private let firstSaveStarted = ScopedWaiter()
    private let allowFirstSave = ScopedWaiter()
    private var saveCount = 0
    private var stored: [MacChatPersistedTurnLifecycle] = []

    func load() async throws -> [MacChatPersistedTurnLifecycle] { stored }

    func save(_ records: [MacChatPersistedTurnLifecycle]) async throws {
        saveCount += 1
        if saveCount == 1 {
            firstSaveStarted.resume()
            await allowFirstSave.park()
        }
        stored = records
    }

    func waitForFirstSave() async { await firstSaveStarted.park() }
    func releaseFirstSave() { allowFirstSave.resume() }
}

private enum GatedLifecycleStorageFailure: Error {
    case unavailable
}

private actor GatedFailingLifecycleStorage: MacChatTurnLifecycleStorage {
    private let firstSaveStarted = ScopedWaiter()
    private let allowFirstSave = ScopedWaiter()
    private var saveCount = 0

    func load() async throws -> [MacChatPersistedTurnLifecycle] { [] }

    func save(_ records: [MacChatPersistedTurnLifecycle]) async throws {
        _ = records
        saveCount += 1
        if saveCount == 1 {
            firstSaveStarted.resume()
            await allowFirstSave.park()
        }
        throw GatedLifecycleStorageFailure.unavailable
    }

    func waitForFirstSave() async { await firstSaveStarted.park() }
    func releaseFirstSave() { allowFirstSave.resume() }
}

private actor FailSelectedLifecycleSavesStorage: MacChatTurnLifecycleStorage {
    private var stored: [MacChatPersistedTurnLifecycle] = []
    private let failingSaves: Set<Int>
    private var saveCount = 0

    init(failingSaves: Set<Int>) {
        self.failingSaves = failingSaves
    }

    func load() async throws -> [MacChatPersistedTurnLifecycle] { stored }

    func save(_ records: [MacChatPersistedTurnLifecycle]) async throws {
        saveCount += 1
        if failingSaves.contains(saveCount) {
            throw GatedLifecycleStorageFailure.unavailable
        }
        stored = records
    }
}

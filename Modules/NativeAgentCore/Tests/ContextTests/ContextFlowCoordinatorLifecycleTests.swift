import Foundation
import NativeAgentCore
import Testing
@testable import Context

extension ContextFlowCoordinatorTests {
    // MARK: - Coverage-ledger fence core.context: wiring the store tests can't see
    //
    // The three tests below share a shape: the UNIT underneath is already well
    // covered (store.prune, the prewarm planner, ContextArena leases), and the
    // thing that has no coverage is whether the coordinator actually CALLS it.
    // Unwire any of them and every existing green check stays green.

    /// 2026-07-21 audit fix, re-armed. `store.prune()` shipped with ZERO
    /// production callers and context.sqlite grew without bound; the fix was to
    /// call it opportunistically after a successful commit. The store-level
    /// prune/vacuum tests (ContextFlowStoreTests) prove prune WORKS — none of
    /// them proves the coordinator invokes it, so deleting the call site
    /// reintroduces the original bug with a fully green suite and no symptom
    /// except a disk number nobody reads.
    ///
    /// Envelope, not exact values: history published before the retention
    /// window must be unreachable after a commit, and the active generation
    /// must still load. Nothing here pins the retention constant itself — that
    /// belongs to the store.
    @Test
    func aSuccessfulReconcileCommitPrunesTheStoreSoHistoryStaysBounded() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Identity\nAgent is one mind.")
        defer { fixture.cleanup() }

        // A history deeper than the default retention window (8), published
        // straight into the store so the coordinator's own commit is the only
        // thing that can bound it.
        for edit in 1...12 {
            _ = try await fixture.store.publish(ContextGenerationDraft(
                reason: "seeded edit \(edit)",
                changedSources: [compiledSource(
                    id: "seed",
                    owner: "seed",
                    locator: "SEED.md",
                    kind: .fact,
                    body: "Seeded body \(edit).",
                    authority: .external,
                    policy: .adaptive
                )],
                createdAt: Date(timeIntervalSince1970: Double(edit))
            ))
        }
        // Precondition: the oldest generation is present BEFORE the commit, so a
        // pass below is about pruning and not about it never having existed.
        #expect(try await fixture.store.loadGeneration(id: 1).generation.id == 1)

        // One successful reconcile+commit. This is the only action under test.
        await fixture.coordinator.start()

        let health = await fixture.coordinator.health()
        let activeID = try #require(health.activeStoreGenerationID)
        #expect(activeID > 12, "the launch reconcile did not commit a new generation")
        // The active generation survives the prune — bounding history must
        // never cost the generation the app is serving.
        #expect(try await fixture.store.loadGeneration(id: activeID).generation.id == activeID)

        do {
            _ = try await fixture.store.loadGeneration(id: 1)
            Issue.record("""
            generation 1 survived a successful commit — pruneStoreIfDue is no longer wired, \
            and context.sqlite grows without bound again
            """)
        } catch let error as ContextFlowStoreError {
            #expect(error == .generationNotFound(1))
        }
    }

    /// The app-facing prewarm overload — the one chat, cognition and the
    /// organism call. It owns token matching and its own fail-closed guard that
    /// returns an EMPTY receipt, and the app throws the receipt away
    /// (`NativeContextFlowRuntime.prewarm` is `async -> Void`). So if the
    /// tokenizer breaks or the guard trips, every prewarm silently plans
    /// nothing and nobody ever sees the `.empty`. The event-shaped overload and
    /// the planner are covered elsewhere; this overload's own logic was not.
    @Test
    func appFacingPrewarmPlansMatchingAtomsAndFailsClosedVisibly() async throws {
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Identity\nAgent coordinates the cobalt garden rollout."
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        // A term that genuinely appears in the published atom body.
        let planned = await fixture.coordinator.submitPrewarm(
            kind: .session,
            id: "session-a",
            terms: ["cobalt"]
        )
        #expect(planned.outcome == .planned)
        let plan = try #require(planned.plan, "a matching term planned nothing — the token match is dead")
        #expect(!plan.items.isEmpty)
        #expect(plan.items.allSatisfy { $0.cause.kind == .session && $0.cause.id == "session-a" })
        // Prewarm is advisory only; it must never be able to alter selection or
        // grant authority, whatever it planned.
        #expect(!plan.canAlterSelection)
        #expect(!plan.canGrantAuthority)

        // The fail-closed guard: an empty/whitespace id can never plan.
        let blankID = await fixture.coordinator.submitPrewarm(
            kind: .session,
            id: "   ",
            terms: ["cobalt"]
        )
        #expect(blankID.outcome == .empty)
        #expect(blankID.plan == nil)

        // A term matching nothing plans nothing — and says so, rather than
        // planning the whole generation.
        let unmatched = await fixture.coordinator.submitPrewarm(
            kind: .session,
            id: "session-b",
            terms: ["zzzznotawordinanyatom"]
        )
        #expect(unmatched.plan?.items.isEmpty ?? true)

        // And every submission that reaches the planner is DURABLE: the receipt
        // lands in the store even though the app-side caller discards the
        // return value (`NativeContextFlowRuntime.prewarm` is `async -> Void`),
        // and a zero-result planning is recorded as such rather than skipped.
        // The write is a detached background task, so poll under a deadline.
        //
        // NOTE, deliberately not asserted: the EARLY guard above (blank id / no
        // active generation) returns its `.empty` receipt before any store
        // write, so that failure mode is durable nowhere. Closing it needs a
        // production change (record a receipt on the guard path), which is out
        // of fence for this wave — it is reported as a needed seam instead of
        // being asserted here, so this test cannot pass by describing a bug.
        var planningReceipts: [ContextStoreReceipt] = []
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            planningReceipts = try await fixture.store.recentReceipts(limit: 50).filter {
                $0.kind == .prewarm && $0.summary == "context prewarm planning"
            }
            if planningReceipts.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            planningReceipts.count >= 2,
            "only \(planningReceipts.count) planning receipts landed — planner outcomes are no longer durable"
        )
        let recordedOutcomes = Set(planningReceipts.compactMap { $0.details["outcome"] })
        #expect(
            recordedOutcomes.contains("planned"),
            "no receipt recorded a planned outcome: \(recordedOutcomes.sorted())"
        )
        #expect(
            recordedOutcomes.contains("empty"),
            "a zero-result planning left no receipt — a prewarm lane that plans nothing is invisible: \(recordedOutcomes.sorted())"
        )
    }

    /// Lease RAII. `ContextPreparedTurn`'s ONLY release is its `deinit`, and
    /// `acquireSnapshot()` hands a raw lease to any caller with no wrapper at
    /// all. A lease that outlives its turn pins its generation in the arena
    /// forever — memory-pressure trims explicitly protect active leases, so
    /// those bytes can never be reclaimed and the only symptom is arena bytes
    /// that never come down. ContextArenaTests proves `release()` works when
    /// CALLED; nothing proved either vended object releases on scope exit.
    @Test
    func vendedLeasesReleaseWhenTheirScopeExitsSoNoGenerationStaysPinned() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Identity\nAgent is one mind.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let baseline = fixture.arena.metrics().activeLeaseCount

        // (a) the wrapped path: prepareTurn -> ContextPreparedTurn.deinit
        func prepareAndDrop() async throws -> Int64 {
            let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
                surface: .chat,
                origin: .localAuthenticated,
                userMessage: "What is the state of things?",
                personaIDHint: "Agent",
                characterBudget: 6_000
            ))
            let generationID = prepared.packet.generationID
            let during = withExtendedLifetime(prepared) { fixture.arena.metrics() }
            #expect(during.activeLeaseCount == baseline + 1)
            #expect(during.pinnedGenerations[generationID] != nil)
            return generationID
        }
        let preparedGeneration = try await prepareAndDrop()
        let afterPreparedTurn = fixture.arena.metrics()
        #expect(
            afterPreparedTurn.activeLeaseCount == baseline,
            "a prepared turn that went out of scope left its lease active — its generation is pinned forever"
        )
        #expect(afterPreparedTurn.pinnedGenerations[preparedGeneration] == nil)

        // (b) the UNWRAPPED path: acquireSnapshot vends a bare lease.
        func acquireAndDrop() async throws -> Int64 {
            let lease = try await fixture.coordinator.acquireSnapshot()
            let generationID = lease.snapshot.generationID
            let during = withExtendedLifetime(lease) { fixture.arena.metrics() }
            #expect(during.activeLeaseCount == baseline + 1)
            return generationID
        }
        let snapshotGeneration = try await acquireAndDrop()
        let afterSnapshot = fixture.arena.metrics()
        #expect(
            afterSnapshot.activeLeaseCount == baseline,
            "acquireSnapshot's raw lease did not release on deinit — a caller that forgets release() pins the arena"
        )
        #expect(afterSnapshot.pinnedGenerations[snapshotGeneration] == nil)
    }

    // REPORTS-ONLY -> executable boundary checks (Wave 1):
    //   core.context / context.coordinator.prepareTurn
    //   core.context / context.coordinator.prewarmPlans.residency
    // These use the real coordinator, SQLite store, arena, and prepared-turn
    // callback rather than source inspection; both the refusing and accepting
    // sides matter because a permissive fallback would look healthy in a trace.
    @Test
    func reportOnlyPrepareTurnRefusesBeforeStartAndWithoutASurfaceKernelThenServesThePublishedGeneration() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Identity\nCobalt garden continuity.")
        defer { fixture.cleanup() }
        let request = ContextTurnRequest(
            surface: .chat, origin: .localAuthenticated, userMessage: "cobalt garden",
            personaIDHint: "Agent", sessionID: "report-only-session"
        )

        await #expect(throws: ContextTurnPreparationError.self) {
            _ = try await fixture.coordinator.prepareTurn(request)
        }

        await fixture.coordinator.start()
        let unsupportedSurface = ContextTurnRequest(
            surface: .bridge, origin: .localAuthenticated, userMessage: "cobalt garden",
            personaIDHint: "Agent", sessionID: "report-only-session"
        )
        await #expect(throws: ContextTurnPreparationError.self) {
            _ = try await fixture.coordinator.prepareTurn(unsupportedSurface)
        }

        let prepared = try await fixture.coordinator.prepareTurn(request)
        let activeGenerationID = await fixture.coordinator.health().activeStoreGenerationID
        #expect(prepared.packet.generationID == activeGenerationID)
        #expect(!prepared.packet.receipt.selectedAtomIDs.isEmpty)
        #expect(prepared.kernel.key.personaID.rawValue == "Agent")
    }

    @Test
    func reportOnlySessionPrewarmIsConsumedOnlyByItsMatchingTurn() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Identity\nCobalt garden continuity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let planning = await fixture.coordinator.submitPrewarm(
            kind: .session, id: "session-a", terms: ["cobalt"], revision: 7
        )
        #expect(planning.outcome == .planned)
        #expect(!(planning.plan?.items.isEmpty ?? true))
        #expect(await fixture.coordinator.health().trackedPrewarmPlanCount == 1)

        // The same session receives a newer hint before it turns. It replaces
        // its retained plan instead of growing one dictionary entry per hint.
        let replacement = await fixture.coordinator.submitPrewarm(
            kind: .session, id: "session-a", terms: ["cobalt"], revision: 8
        )
        #expect(replacement.outcome == .planned)
        #expect(await fixture.coordinator.health().trackedPrewarmPlanCount == 1)

        _ = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat, origin: .localAuthenticated, userMessage: "cobalt garden",
            personaIDHint: "Agent", sessionID: "session-b"
        ))
        let unrelatedDeadline = ContinuousClock.now + .seconds(3)
        var unrelatedHealth = await fixture.coordinator.health()
        while unrelatedHealth.trackedPrewarmPlanCount != 2,
              ContinuousClock.now < unrelatedDeadline {
            try await Task.sleep(for: .milliseconds(10))
            unrelatedHealth = await fixture.coordinator.health()
        }
        #expect(
            unrelatedHealth.prewarmUsefulnessReceipts == 0,
            "a session-a warm plan was consumed by unrelated session-b"
        )
        #expect(
            unrelatedHealth.trackedPrewarmPlanCount == 2,
            "the unrelated next-turn plan must coexist with the retained session-a plan"
        )

        _ = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat, origin: .localAuthenticated, userMessage: "cobalt garden",
            personaIDHint: "Agent", sessionID: "session-a"
        ))
        let deadline = ContinuousClock.now + .seconds(3)
        var health = await fixture.coordinator.health()
        while (health.prewarmUsefulnessReceipts == 0 || health.trackedPrewarmPlanCount != 1),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            health = await fixture.coordinator.health()
        }
        #expect(health.prewarmUsefulnessReceipts == 1)
        #expect(
            health.trackedPrewarmPlanCount == 1,
            "matching session-a did not remove its resident plan; only session-b should remain"
        )
    }

    @Test
    func feedbackLearningSurvivesCoordinatorRestartAndKeepsAdvancing() async throws {
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Identity\nCobalt garden continuity."
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let first = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "What is the cobalt garden state?",
            personaIDHint: "Agent"
        ))
        let selectedID = try #require(first.packet.receipt.selectedAtomIDs.first)
        #expect((first.need.feedbackUtilityOverrides[selectedID] ?? 0) == 0)
        #expect(await fixture.coordinator.health().feedbackEventCount == 1)

        // A new coordinator models the process restart that previously reset
        // FC7 to an empty in-memory array. It uses the same derived store but
        // rehydrates no user facts or authority from Context.
        let databaseURL = await fixture.store.databaseURL
        await fixture.coordinator.stop()
        let reopenedStore = try ContextSQLiteStore(databaseURL: databaseURL)
        let restarted = ContextFlowCoordinator(
            mode: .active,
            store: reopenedStore,
            arena: try ContextArena(budget: .mib32),
            registry: fixture.registry,
            compiler: ContextMarkdownCompiler(embeddingProvider: CoordinatorEmbeddingProvider()),
            mirrorProvider: CoordinatorMirrorProvider(mirror: fixture.mirror),
            diagnostics: { [log = fixture.diagnostics] message in log.record(message) }
        )
        await restarted.start()
        defer { Task { await restarted.stop() } }

        #expect(await restarted.health().feedbackEventCount == 1)
        let resumed = try await restarted.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "What is the cobalt garden state?",
            personaIDHint: "Agent"
        ))
        #expect(
            (resumed.need.feedbackUtilityOverrides[selectedID] ?? 0) > 0,
            "a restart erased the prior selection's derived utility"
        )
        #expect(await restarted.health().feedbackEventCount == 2)
    }

    @Test
    func coordinatorFeedbackCapEvictsOldestAndReportsTheNewestRetainedEvent() async throws {
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Identity\nCobalt garden continuity."
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        func driveSelection(_ index: Int) async throws {
            let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
                surface: .chat,
                origin: .localAuthenticated,
                userMessage: "cobalt garden continuity \(index)",
                personaIDHint: "Agent",
                sessionID: "feedback-cap-\(index)"
            ))
            #expect(!prepared.packet.receipt.selectedAtomIDs.isEmpty)
        }

        try await driveSelection(0)
        let firstHealth = await fixture.coordinator.health()
        let evictedID = try #require(firstHealth.newestFeedbackEventID)

        for index in 1 ... 4_096 {
            try await driveSelection(index)
        }

        let beforeFinal = await fixture.coordinator.health()
        let beforeFinalID = try #require(beforeFinal.newestFeedbackEventID)
        try await driveSelection(4_097)
        let health = await fixture.coordinator.health()
        let newestID = try #require(health.newestFeedbackEventID)
        #expect(health.feedbackEventCount == 4_096)
        #expect(newestID != beforeFinalID)

        let retained = try await fixture.store.recentFeedbackEvents()
        #expect(retained.count == 4_096)
        #expect(retained.contains(where: { $0.id == evictedID }) == false)
        #expect(retained.last?.id == newestID)
    }

}

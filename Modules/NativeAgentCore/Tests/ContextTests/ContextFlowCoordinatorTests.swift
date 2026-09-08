import Foundation
import NativeAgentCore
import Testing
@testable import Context

@Suite(.serialized)
struct ContextFlowCoordinatorTests {
    // EVAL FENCE: core.context
    // Ledger row: context.coordinator.refreshDiscoveredSources
    @Test
    func startRefreshesDiscoveredRegistrationsBeforePublishingTheGeneration() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        let personaRoot = fixture.root.appendingPathComponent("persona", isDirectory: true)
        let owner = "fixture.discovered"
        let staleFile = personaRoot.appendingPathComponent("STALE.md")
        let currentFile = personaRoot.appendingPathComponent("CURRENT.md")
        try "# Discovered\nRetired registration.".write(
            to: staleFile,
            atomically: true,
            encoding: .utf8
        )
        try "# Discovered\nRefreshed registration reaches the generation.".write(
            to: currentFile,
            atomically: true,
            encoding: .utf8
        )

        func registration(file: URL, locator: String) -> ContextSourceRegistration {
            let descriptor = ContextSourceDescriptor(
                id: ContextStableID.source(owner: owner, locator: locator),
                owner: owner,
                kind: .project,
                canonicalLocator: file.path,
                authority: .external,
                privacy: .localPrivate,
                permittedSurfaces: [.chat, .bridge],
                injectionPolicy: .adaptive
            )
            return ContextSourceRegistration(
                descriptor: descriptor,
                fileURL: file,
                allowedRoot: personaRoot
            )
        }

        let stale = registration(file: staleFile, locator: "discovered/STALE.md")
        let current = registration(file: currentFile, locator: "discovered/CURRENT.md")
        try await fixture.registry.register(stale)
        await fixture.refreshingMirrorProvider.replaceRegistrations([current])

        #expect(await fixture.registry.registration(for: stale.descriptor.id) != nil)
        #expect(await fixture.registry.registration(for: current.descriptor.id) == nil)

        await fixture.coordinator.start()

        #expect(await fixture.registry.registration(for: stale.descriptor.id) == nil)
        #expect(await fixture.registry.registration(for: current.descriptor.id) == current)
        let health = await fixture.coordinator.health()
        #expect(health.registeredSourceCount == 2)
        #expect(health.lastError == nil)

        let lease = try await fixture.coordinator.acquireSnapshot()
        defer { lease.release() }
        let entries = lease.snapshot.hotEntries + lease.snapshot.warmEntries
        #expect(entries.contains { $0.text.contains("Refreshed registration reaches") })
        #expect(entries.allSatisfy { !$0.text.contains("Retired registration") })
    }

    @Test
    func projectionInvalidationRebuildsOnlyTheOwningDerivedView() async throws {
        let memory = CoordinatorControllableProjectionProvider(
            identifier: "memory",
            namespaces: ["memory-v2"]
        )
        let residentWork = CoordinatorControllableProjectionProvider(
            identifier: "resident-work",
            namespaces: ["resident-work"]
        )
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nOne mind.",
            projectionProviders: [memory, residentWork]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        #expect(await memory.invocationCount() == 1)
        #expect(await residentWork.invocationCount() == 1)

        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "resident-work",
            stableID: "canonical",
            operation: .reconcile,
            reason: "Workshop terminal edge"
        ))
        #expect(await memory.invocationCount() == 1)
        #expect(await residentWork.invocationCount() == 2)

        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "memory-v2",
            stableID: "canonical",
            operation: .reconcile,
            reason: "memory write"
        ))
        #expect(await memory.invocationCount() == 2)
        #expect(await residentWork.invocationCount() == 2)
    }

    @Test
    func memoryInvalidationIgnoresCandidateRootWithoutRefreshingLiveSources() async throws {
        let livePath = URL(fileURLWithPath: "/fixture/live/memory/memory.sqlite")
        let memory = CoordinatorControllableProjectionProvider(
            identifier: "memory", namespaces: ["memory-v2"], sourceURL: livePath
        )
        let fixture = try await makeFixture(
            mode: .shadow, body: "# Core\nOne continuous mind.", projectionProviders: [memory]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let initialHealth = await fixture.coordinator.health()
        #expect(await memory.invocationCount() == 1)
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 1)

        let center = DerivedStateInvalidationCenter(coalescingNanoseconds: 60_000_000_000)
        await center.install(fixture.coordinator)
        let candidate = DerivedSourceChange(
            namespace: "memory-v2", stableID: "backed-up-row", operation: .removed,
            canonicalLocator: "/fixture/live/memory/consolidation/candidates/run/memory/memory.sqlite",
            reason: "candidate-only consolidation"
        )
        await center.publish(candidate)
        await center.flush()
        #expect(await memory.invocationCount() == 1)
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 1)
        #expect(await fixture.coordinator.health().lastReconciledAt == initialHealth.lastReconciledAt)

        // A later candidate event with the same row ID cannot swallow the
        // live event in the coalescer. The actual live owner still runs once.
        await center.publish(DerivedSourceChange(
            namespace: "memory-v2", stableID: "backed-up-row", operation: .changed,
            canonicalLocator: "/fixture/live/memory/../memory/memory.sqlite", reason: "live write"
        ))
        await center.publish(candidate)
        await center.flush()
        #expect(await memory.invocationCount() == 2)
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 1)

        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "memory-v2", stableID: "legacy", operation: .reconcile,
            reason: "legacy unlocated write"
        ))
        #expect(await memory.invocationCount() == 3)
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona-picker", stableID: "chat", operation: .reconcile,
            reason: "ordinary full refresh"
        ))
        #expect(await memory.invocationCount() == 4)
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 2)
        await center.install(nil)
    }

    @Test
    func fullDirectInvalidationRefreshesSourcesOnceAndRebuildsEveryProjection() async throws {
        let memory = CoordinatorControllableProjectionProvider(
            identifier: "memory",
            namespaces: ["memory-v2"]
        )
        let residentWork = CoordinatorControllableProjectionProvider(
            identifier: "resident-work",
            namespaces: ["resident-work"]
        )
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nOne mind.",
            projectionProviders: [memory, residentWork]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 1)

        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona-picker",
            stableID: "chat",
            operation: .reconcile,
            reason: "picker changed"
        ))
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 2)
        #expect(await memory.invocationCount() == 2)
        #expect(await residentWork.invocationCount() == 2)

        // An unlocatable source change also requests the complete registry.
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: "not-registered",
            operation: .changed,
            reason: "unlocatable change"
        ))
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 3)
        #expect(await memory.invocationCount() == 3)
        #expect(await residentWork.invocationCount() == 3)
        #expect(await fixture.coordinator.health().lastError == nil)
    }

    @Test
    func retiredDiscoveredSourcesLeaveTheGenerationWithoutRemovingOtherOwners() async throws {
        let projected = compiledSource(
            id: "projected", owner: "fixture.projected", locator: "projected/item",
            kind: .memory, body: "Projected memory remains.",
            authority: .external, policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .shadow, body: "# Core\nStable identity.", projectedSources: [projected]
        )
        defer { fixture.cleanup() }
        let root = fixture.sourceFile.deletingLastPathComponent()
        let file = root.appendingPathComponent("RETIRED.md")
        try "# Retired\nThis source is no longer admitted.".write(
            to: file, atomically: true, encoding: .utf8
        )
        let owner = "fixture.discovered"
        let sourceID = ContextStableID.source(owner: owner, locator: "retired")
        let registration = ContextSourceRegistration(
            descriptor: ContextSourceDescriptor(
                id: sourceID, owner: owner, kind: .project, canonicalLocator: file.path,
                authority: .external, privacy: .localPrivate,
                permittedSurfaces: [.chat], injectionPolicy: .adaptive
            ),
            fileURL: file, allowedRoot: root
        )
        await fixture.refreshingMirrorProvider.replaceRegistrations([registration])
        await fixture.coordinator.start()
        let oldLease = try await fixture.coordinator.acquireSnapshot()
        defer { oldLease.release() }
        #expect(try await fixture.store.loadActiveGeneration()?.sources.contains {
            $0.descriptor.id == sourceID
        } == true)

        await fixture.refreshingMirrorProvider.replaceRegistrations([])
        await fixture.coordinator.reconcileAfterWake()

        let active = try #require(try await fixture.store.loadActiveGeneration())
        #expect(!active.sources.contains { $0.descriptor.id == sourceID })
        #expect(active.sources.contains { $0.descriptor.id == fixture.sourceID })
        #expect(active.sources.contains { $0.descriptor.id == projected.descriptor.id })
        // Retirement affects derived availability, not canonical file bytes or
        // an already-frozen generation lease.
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect((oldLease.snapshot.hotEntries + oldLease.snapshot.warmEntries).contains {
            $0.text.contains("no longer admitted")
        })
        #expect(await fixture.coordinator.health().lastError == nil)
    }

    @Test
    func emptyAuthoritativeInventoryRetiresPersistedSourcesAfterRestart() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nRetired persona source.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        await fixture.coordinator.stop()
        #expect(try await fixture.store.loadActiveGeneration()?.sources.count == 1)

        let registry = try ContextSourceRegistry()
        try await registry.replaceOwned(owner: "persona", with: [])
        let restarted = ContextFlowCoordinator(
            mode: .shadow, store: fixture.store, arena: try ContextArena(budget: .mib32),
            registry: registry,
            compiler: ContextMarkdownCompiler(embeddingProvider: CoordinatorEmbeddingProvider()),
            mirrorProvider: CoordinatorMirrorProvider(mirror: fixture.mirror)
        )
        await restarted.start()
        let active = try #require(try await fixture.store.loadActiveGeneration())
        #expect(active.sources.isEmpty)
        #expect(active.atoms.isEmpty)
        #expect(await restarted.health().lastError == nil)
        await restarted.stop()
    }

    @Test
    func cancelledDiscoveryDoesNotReportCompletionAndRemainsRetryable() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nInitial source.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let initialGeneration = await fixture.coordinator.health().activeArenaGenerationID
        try "# Core\nRepaired source.".write(
            to: fixture.sourceFile, atomically: true, encoding: .utf8
        )
        let changes = [DerivedSourceChange(
            namespace: "persona-picker", stableID: "chat", operation: .reconcile,
            reason: "picker changed"
        )]
        // A collaborator can throw CancellationError even when this parent
        // task has not been canceled. Health must stay honest, but cannot be
        // used as evidence that this request completed.
        await fixture.refreshingMirrorProvider.setRefreshCancellation(true)
        #expect(!Task.isCancelled)
        #expect(await fixture.coordinator.reconcileSourceChanges(changes) == false)
        #expect(await fixture.coordinator.health().lastError == nil)
        #expect(await fixture.coordinator.health().activeArenaGenerationID == initialGeneration)

        await fixture.refreshingMirrorProvider.setRefreshCancellation(false)
        #expect(await fixture.coordinator.reconcileSourceChanges(changes) == true)
        #expect(await fixture.coordinator.health().activeArenaGenerationID != initialGeneration)
        let active = try #require(try await fixture.store.loadActiveGeneration())
        #expect(active.atoms.contains { $0.draft.body.contains("Repaired source") })
    }

    @Test
    func startCompilesRegisteredSourcePublishesMirrorAndArena() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nAgent is one mind.")
        defer { fixture.cleanup() }

        await fixture.coordinator.start()
        let health = await fixture.coordinator.health()
        let lease = try await fixture.coordinator.acquireSnapshot()
        defer { lease.release() }

        #expect(health.started)
        #expect(health.activeStoreGenerationID == 1)
        #expect(health.activeArenaGenerationID == 1)
        #expect(health.registeredSourceCount == 1)
        #expect(health.lastError == nil)
        #expect(lease.snapshot.requiredDocumentMirrors.count == 1)
        #expect(lease.snapshot.hotEntries.contains(where: { $0.text.contains("Agent is one mind") }))
    }

    @Test
    func directChangePublishesNextGenerationWhileOldLeaseRemainsStable() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nOriginal identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let oldLease = try await fixture.coordinator.acquireSnapshot()

        try "# Core\nUpdated identity.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "test edit"
        ))

        let current = try await fixture.coordinator.acquireSnapshot()
        defer {
            oldLease.release()
            current.release()
        }
        #expect(oldLease.snapshot.generationID == 1)
        #expect(oldLease.snapshot.hotEntries.contains(where: { $0.text.contains("Original") }))
        #expect(current.snapshot.generationID == 2)
        #expect(current.snapshot.hotEntries.contains(where: { $0.text.contains("Updated") }))
        #expect(fixture.arena.metrics().pinnedGenerations == [1: 1, 2: 1])
    }

    @Test
    func cancelledReconciliationIsControlFlowAndLaterOwnerEdgeRetries() async throws {
        let compiler = CoordinatorCancellationCompiler()
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nInitial identity.",
            compiler: compiler
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        await compiler.cancelNextCompilation(containing: "Cancelled revision")
        try "# Core\nCancelled revision.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        let cancelled = Task {
            await fixture.coordinator.sourceDidChange(DerivedSourceChange(
                namespace: "persona",
                stableID: fixture.sourceID.rawValue,
                operation: .changed,
                canonicalLocator: fixture.sourceFile.path,
                reason: "cancelled owner edge"
            ))
        }
        await compiler.waitUntilBlocked()
        cancelled.cancel()
        await cancelled.value

        let afterCancellation = await fixture.coordinator.health()
        let cancellationReceipts = try await fixture.store.recentReceipts(limit: 100)
        #expect(afterCancellation.lastError == nil)
        #expect(afterCancellation.degradedSourceCount == 0)
        #expect(!cancellationReceipts.contains {
            $0.kind == .degraded && $0.summary == "context reconciliation failed"
        })

        try "# Core\nRecovered revision.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "later owner edge"
        ))

        let recovered = await fixture.coordinator.health()
        let generation = try #require(await fixture.store.loadActiveGeneration())
        #expect(recovered.lastError == nil)
        #expect(recovered.degradedSourceCount == 0)
        #expect(generation.generation.id == 2)
        #expect(generation.atoms.contains { $0.draft.body.contains("Recovered revision") })
    }

    @Test
    func failedCompileRetainsLastGoodGenerationAndReportsDegradedSource() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nSafe identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        try "# Core\napi_key = sk-this-must-not-enter-context".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "secret-like edit"
        ))

        let health = await fixture.coordinator.health()
        let snapshot = try await fixture.coordinator.acquireSnapshot()
        defer { snapshot.release() }
        #expect(health.activeStoreGenerationID == 1)
        #expect(health.activeArenaGenerationID == 1)
        #expect(health.degradedSourceCount == 1)
        #expect(snapshot.snapshot.hotEntries.contains(where: { $0.text.contains("Safe identity") }))
        #expect(snapshot.snapshot.hotEntries.allSatisfy { !$0.text.contains("sk-this") })
    }

    @Test
    func olderSuspendedReconciliationCannotReplaceNewerPublishedContent() async throws {
        let compiler = CoordinatorControllableCompiler()
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nInitial identity.",
            compiler: compiler
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.reconcileAfterWake()

        await compiler.blockNextCompilation(containing: "Blocked A")
        try "# Core\nBlocked A identity.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        let older = Task {
            await fixture.coordinator.sourceDidChange(DerivedSourceChange(
                namespace: "persona",
                stableID: fixture.sourceID.rawValue,
                operation: .changed,
                canonicalLocator: fixture.sourceFile.path,
                reason: "blocked A"
            ))
        }
        await compiler.waitUntilBlocked()

        try "# Core\nPublished B identity.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "publish B"
        ))

        let publishedB = try await fixture.coordinator.acquireSnapshot()
        #expect(publishedB.snapshot.generationID == 2)
        #expect(publishedB.snapshot.hotEntries.contains { $0.text.contains("Published B") })
        publishedB.release()

        await compiler.releaseBlockedCompilation()
        await older.value

        let final = try await fixture.coordinator.acquireSnapshot()
        defer { final.release() }
        let stored = try #require(await fixture.store.loadActiveGeneration())
        #expect(final.snapshot.generationID == 2)
        #expect(final.snapshot.hotEntries.contains { $0.text.contains("Published B") })
        #expect(final.snapshot.hotEntries.allSatisfy { !$0.text.contains("Blocked A") })
        #expect(stored.generation.id == 2)
        #expect(stored.atoms.contains { $0.draft.body.contains("Published B") })
        #expect(stored.atoms.allSatisfy { !$0.draft.body.contains("Blocked A") })
    }

    @Test
    func concurrentDistinctSourceRequestsCoalesceWithoutLoss() async throws {
        let compiler = CoordinatorControllableCompiler()
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nSource A initial.",
            compiler: compiler
        )
        defer { fixture.cleanup() }
        let sourceBFile = fixture.sourceFile.deletingLastPathComponent()
            .appendingPathComponent("PROJECT.md")
        try "# Project\nSource B initial.".write(
            to: sourceBFile,
            atomically: true,
            encoding: .utf8
        )
        let sourceBID = ContextStableID.source(owner: "project", locator: "PROJECT.md")
        try await fixture.registry.register(ContextSourceRegistration(
            descriptor: ContextSourceDescriptor(
                id: sourceBID,
                owner: "project",
                kind: .project,
                canonicalLocator: sourceBFile.path,
                authority: .external,
                privacy: .localPrivate,
                permittedSurfaces: [.chat, .bridge],
                injectionPolicy: .adaptive
            ),
            fileURL: sourceBFile,
            allowedRoot: sourceBFile.deletingLastPathComponent()
        ))
        await fixture.coordinator.reconcileAfterWake()

        await compiler.blockNextCompilation(containing: "Source A revised")
        try "# Core\nSource A revised.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        let sourceARequest = Task {
            await fixture.coordinator.sourceDidChange(DerivedSourceChange(
                namespace: "persona",
                stableID: fixture.sourceID.rawValue,
                operation: .changed,
                canonicalLocator: fixture.sourceFile.path,
                reason: "source A"
            ))
        }
        await compiler.waitUntilBlocked()

        try "# Project\nSource B revised.".write(
            to: sourceBFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.reconcileAfterWake()
        await compiler.releaseBlockedCompilation()
        await sourceARequest.value

        let stored = try #require(await fixture.store.loadActiveGeneration())
        let bodies = stored.atoms.map(\.draft.body)
        #expect(stored.generation.id == 2)
        #expect(bodies.contains { $0.contains("Source A revised") })
        #expect(bodies.contains { $0.contains("Source B revised") })
        let snapshot = try await fixture.coordinator.acquireSnapshot()
        defer { snapshot.release() }
        #expect(snapshot.snapshot.generationID == 2)
    }

    @Test
    func identicalContentRecoveryClearsDegradedSourceHealth() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nSafe identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.reconcileAfterWake()

        try "# Core\napi_key = sk-this-must-not-enter-context".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "degrade source"
        ))
        #expect(await fixture.coordinator.health().degradedSourceCount == 1)

        try "# Core\nSafe identity.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        let recoveredArena = try ContextArena(budget: .mib32)
        let recoveredCoordinator = ContextFlowCoordinator(
            mode: .shadow,
            store: fixture.store,
            arena: recoveredArena,
            registry: fixture.registry,
            compiler: ContextMarkdownCompiler(embeddingProvider: CoordinatorEmbeddingProvider()),
            mirrorProvider: CoordinatorMirrorProvider(mirror: fixture.mirror)
        )
        await recoveredCoordinator.reconcileAfterWake()

        let health = await recoveredCoordinator.health()
        let stored = try #require(await fixture.store.loadActiveGeneration())
        #expect(health.degradedSourceCount == 0)
        #expect(health.activeStoreGenerationID == 2)
        #expect(health.activeArenaGenerationID == 2)
        #expect(stored.atoms.contains { $0.draft.body.contains("Safe identity") })
    }

    @Test
    func failedBatchRemainsPendingUntilLaterUnrelatedReconciliation() async throws {
        let projectionProvider = CoordinatorControllableProjectionProvider()
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nSource A initial.",
            warmBody: "# Project\nSource B initial.",
            projectionProviders: [projectionProvider]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.reconcileAfterWake()
        #expect(await projectionProvider.invocationCount() == 1)

        await projectionProvider.failNextProjection()
        try "# Core\nSource A pending after failure.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.reconcileAfterWake()

        for _ in 0..<10 { await Task.yield() }
        let failedHealth = await fixture.coordinator.health()
        #expect(await projectionProvider.invocationCount() == 2)
        #expect(failedHealth.activeStoreGenerationID == 1)
        #expect(failedHealth.activeArenaGenerationID == 1)
        #expect(failedHealth.lastError != nil)

        let sourceBFile = fixture.sourceFile.deletingLastPathComponent()
            .appendingPathComponent("PROJECT.md")
        let sourceBID = ContextStableID.source(owner: "project", locator: "PROJECT.md")
        try "# Project\nSource B unrelated update.".write(
            to: sourceBFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "project",
            stableID: sourceBID.rawValue,
            operation: .changed,
            canonicalLocator: sourceBFile.path,
            reason: "unrelated source B"
        ))

        let stored = try #require(await fixture.store.loadActiveGeneration())
        let health = await fixture.coordinator.health()
        let bodies = stored.atoms.map(\.draft.body)
        #expect(await projectionProvider.invocationCount() == 3)
        #expect(stored.generation.id == 2)
        #expect(bodies.contains { $0.contains("Source A pending after failure") })
        #expect(bodies.contains { $0.contains("Source B unrelated update") })
        #expect(health.activeStoreGenerationID == 2)
        #expect(health.activeArenaGenerationID == 2)
        #expect(health.lastError == nil)
    }

    @Test
    func unchangedReconciliationDoesNotMintGenerationOrDegradeArena() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        await fixture.coordinator.reconcileAfterWake()

        let health = await fixture.coordinator.health()
        #expect(health.activeStoreGenerationID == 1)
        #expect(health.activeArenaGenerationID == 1)
        #expect(health.lastError == nil)
    }

    @Test
    func descriptorOnlyPolicyChangePublishesNextGeneration() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let adaptiveDescriptor = ContextSourceDescriptor(
            id: fixture.sourceID,
            owner: "persona",
            kind: .persona,
            canonicalLocator: fixture.sourceFile.path,
            authority: .identity,
            privacy: .localPrivate,
            permittedSurfaces: [.chat, .bridge],
            injectionPolicy: .adaptive
        )
        try await fixture.registry.replace(ContextSourceRegistration(
            descriptor: adaptiveDescriptor,
            fileURL: fixture.sourceFile,
            allowedRoot: fixture.sourceFile.deletingLastPathComponent(),
            requiredPersonaDocument: .soul,
            personaID: ContextPersonaID(rawValue: "Agent")
        ))
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "test policy change"
        ))

        let generation = try #require(await fixture.store.loadActiveGeneration())
        let source = try #require(generation.sources.first {
            $0.descriptor.id == fixture.sourceID
        })
        let atom = try #require(generation.atoms.first {
            $0.draft.sourceID == fixture.sourceID
        })
        #expect(generation.generation.id == 2)
        #expect(source.descriptor.injectionPolicy == .adaptive)
        #expect(atom.draft.injectionPolicy == .adaptive)
    }

}
